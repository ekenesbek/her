"""WhisperX-based transcription with optional speaker diarization."""

from __future__ import annotations

import logging
from pathlib import Path
from threading import Lock
from typing import Any

from app.schemas import TranscriptResponse, TranscriptSegment
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
        import whisperx

        model = self._get_model()
        audio = whisperx.load_audio(str(audio_path))

        result = model.transcribe(audio, batch_size=4)
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
            return diarize_model(audio)
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
