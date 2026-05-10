"""WhisperX-based transcription with optional speaker diarization."""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Lock
from typing import Any

from app.schemas import TranscriptResponse, TranscriptSegment
from app.services.audio_chunks import AudioChunk, should_chunk_audio, split_audio_chunks
from app.settings import Settings

logger = logging.getLogger(__name__)


class WhisperXTranscriber:
    """Loads whisperx + pyannote lazily so the FastAPI worker stays light at boot."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._lock = Lock()
        self._model: Any = None
        self._align_models: dict[str, tuple[Any, Any]] = {}
        self._diarize_model: Any = None
        self._diarize_attempted = False

    def transcribe(self, audio_path: Path) -> TranscriptResponse:
        should_chunk, duration = should_chunk_audio(audio_path, self.settings)
        if should_chunk and duration is not None and not self.settings.diarization_enabled:
            return self._transcribe_chunks(audio_path, duration)
        if should_chunk and duration is not None:
            logger.info(
                "Skipping external audio chunking because diarization needs full-file speaker context."
            )
        return self._transcribe_file(audio_path)

    def _transcribe_file(self, audio_path: Path) -> TranscriptResponse:
        import whisperx

        model = self._get_model()
        audio = whisperx.load_audio(str(audio_path))

        result = model.transcribe(
            audio,
            batch_size=max(1, self.settings.whisperx_batch_size),
            language=self.settings.whisper_language or None,
            task="transcribe",
            chunk_size=max(5, self.settings.transcription_chunk_seconds),
        )
        language = result.get("language") or self.settings.whisper_language

        try:
            align_model, metadata = self._get_align_model(language)
            result = whisperx.align(
                result["segments"],
                align_model,
                metadata,
                audio,
                self.settings.whisper_device,
                return_char_alignments=False,
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("whisperx alignment skipped: %s", exc)

        diarize_segments = self._diarize(audio)
        if diarize_segments is not None:
            result = whisperx.assign_word_speakers(diarize_segments, result)

        segments = self._materialize_segments(result.get("segments", []))
        transcript_text = self._format_transcript(segments)
        duration = float(audio.shape[-1]) / 16_000 if hasattr(audio, "shape") else None

        return TranscriptResponse(
            transcript=transcript_text,
            language=language,
            durationSeconds=duration,
            segments=segments,
        )

    def _transcribe_chunks(self, audio_path: Path, duration_seconds: float) -> TranscriptResponse:
        with split_audio_chunks(audio_path, self.settings, duration_seconds) as chunks:
            if len(chunks) <= 1:
                return self._transcribe_file(audio_path)

            max_workers = max(1, self.settings.transcription_chunk_workers)
            with ThreadPoolExecutor(
                max_workers=max_workers,
                thread_name_prefix="whisperx-chunk",
            ) as executor:
                results = list(executor.map(self._transcribe_chunk, chunks))

        segments: list[TranscriptSegment] = []
        fallback_text: list[str] = []
        languages: list[str] = []
        overlap = max(0.0, float(self.settings.transcription_chunk_overlap_seconds))
        for chunk, result in sorted(results, key=lambda item: item[0].index):
            if result.language:
                languages.append(result.language)
            keep_after = chunk.start + overlap if chunk.index > 0 else chunk.start
            if result.segments:
                for segment in result.segments:
                    shifted = segment.model_copy(
                        update={
                            "start": segment.start + chunk.start,
                            "end": segment.end + chunk.start,
                        }
                    )
                    if shifted.start + 0.05 >= keep_after:
                        segments.append(shifted)
            elif result.transcript:
                fallback_text.append(result.transcript)

        transcript = (
            self._format_transcript(segments)
            if segments
            else " ".join(fallback_text).strip()
        )
        return TranscriptResponse(
            transcript=transcript,
            language=languages[0] if languages else self.settings.whisper_language,
            durationSeconds=duration_seconds,
            segments=segments,
        )

    def _transcribe_chunk(self, chunk: AudioChunk) -> tuple[AudioChunk, TranscriptResponse]:
        return chunk, self._transcribe_file(chunk.path)

    def _materialize_segments(self, raw_segments: list[dict]) -> list[TranscriptSegment]:
        out: list[TranscriptSegment] = []
        for segment in raw_segments:
            text = (segment.get("text") or "").strip()
            if not text:
                continue
            out.append(
                TranscriptSegment(
                    start=float(segment.get("start", 0.0)),
                    end=float(segment.get("end", 0.0)),
                    text=text,
                    speaker=segment.get("speaker"),
                )
            )
        return out

    def _format_transcript(self, segments: list[TranscriptSegment]) -> str:
        if not segments:
            return ""
        lines: list[str] = []
        last_speaker: str | None = None
        buffer: list[str] = []
        for segment in segments:
            speaker = segment.speaker or "Speaker"
            if speaker != last_speaker:
                if buffer:
                    lines.append(f"{last_speaker}: " + " ".join(buffer))
                    buffer = []
                last_speaker = speaker
            buffer.append(segment.text)
        if buffer:
            lines.append(f"{last_speaker}: " + " ".join(buffer))
        return "\n".join(lines)

    def _get_model(self):
        with self._lock:
            if self._model is None:
                import whisperx

                self._model = whisperx.load_model(
                    self.settings.whisper_model,
                    device=self.settings.whisper_device,
                    compute_type=self.settings.whisper_compute_type,
                )
            return self._model

    def _get_align_model(self, language_code: str | None):
        if not language_code:
            raise RuntimeError("Cannot align without a known language.")
        with self._lock:
            cached = self._align_models.get(language_code)
            if cached is None:
                import whisperx

                cached = whisperx.load_align_model(
                    language_code=language_code,
                    device=self.settings.whisper_device,
                )
                self._align_models[language_code] = cached
            return cached

    def _diarize(self, audio):
        if not self.settings.diarization_enabled:
            return None
        diarize_model = self._get_diarize_model()
        if diarize_model is None:
            return None
        try:
            kwargs: dict[str, int] = {}
            if self.settings.diarization_min_speakers > 0:
                kwargs["min_speakers"] = self.settings.diarization_min_speakers
            if self.settings.diarization_max_speakers > 0:
                kwargs["max_speakers"] = self.settings.diarization_max_speakers
            return diarize_model(audio, **kwargs)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Diarization failed: %s", exc)
            return None

    def _get_diarize_model(self):
        with self._lock:
            if self._diarize_model is not None:
                return self._diarize_model
            if self._diarize_attempted:
                return None
            self._diarize_attempted = True

            token = self.settings.huggingface_token
            if not token:
                logger.warning("HUGGINGFACE_TOKEN not set; diarization disabled.")
                return None

            try:
                from whisperx.diarize import DiarizationPipeline

                self._diarize_model = DiarizationPipeline(
                    model_name="pyannote/speaker-diarization-3.1",
                    token=token,
                    device=self.settings.whisper_device,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to load diarization pipeline: %s", exc)
                self._diarize_model = None
            return self._diarize_model
