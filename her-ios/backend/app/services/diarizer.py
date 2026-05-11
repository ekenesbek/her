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

        duration = float(audio.shape[-1]) / 16_000 if hasattr(audio, "shape") else None
        diarize_segments = self._diarize_with_single_speaker_retry(audio, duration)
        if diarize_segments is not None:
            result = whisperx.assign_word_speakers(diarize_segments, result)
            self._assign_diarization_speakers(result, diarize_segments)

        segments = self._materialize_segments(result.get("segments", []))
        transcript_text = self._format_transcript(segments)

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
            word_segments = self._materialize_word_speaker_segments(segment)
            if word_segments:
                out.extend(word_segments)
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

    def _materialize_word_speaker_segments(self, segment: dict) -> list[TranscriptSegment]:
        words = segment.get("words")
        if not isinstance(words, list):
            return []

        groups: list[dict[str, Any]] = []
        for word in words:
            if not isinstance(word, dict):
                continue
            word_text = str(word.get("word") or "").strip()
            if not word_text:
                continue
            speaker = word.get("speaker") or segment.get("speaker")
            start = self._float_or_none(word.get("start"))
            end = self._float_or_none(word.get("end"))
            if start is None:
                start = self._float_or_none(segment.get("start")) or 0.0
            if end is None or end < start:
                end = start

            if groups and groups[-1]["speaker"] == speaker:
                groups[-1]["words"].append(word_text)
                groups[-1]["end"] = max(float(groups[-1]["end"]), end)
            else:
                groups.append(
                    {
                        "speaker": speaker,
                        "start": start,
                        "end": end,
                        "words": [word_text],
                    }
                )

        if not groups:
            return []

        segment_text = (segment.get("text") or "").strip()
        if len(groups) == 1:
            group = groups[0]
            return [
                TranscriptSegment(
                    start=float(segment.get("start", group["start"])),
                    end=float(segment.get("end", group["end"])),
                    text=segment_text,
                    speaker=group["speaker"],
                )
            ]

        return [
            TranscriptSegment(
                start=float(group["start"]),
                end=float(group["end"]),
                text=self._join_words(group["words"]),
                speaker=group["speaker"],
            )
            for group in groups
            if group["words"]
        ]

    def _assign_diarization_speakers(self, result: dict, diarize_segments: Any) -> None:
        intervals = self._diarization_intervals(diarize_segments)
        if not intervals:
            return

        for segment in result.get("segments", []):
            if not isinstance(segment, dict):
                continue
            segment_start = self._float_or_none(segment.get("start")) or 0.0
            segment_end = self._float_or_none(segment.get("end"))
            if segment_end is None or segment_end < segment_start:
                segment_end = segment_start

            word_speaker_seconds: dict[str, float] = {}
            words = segment.get("words")
            if isinstance(words, list):
                for word in words:
                    if not isinstance(word, dict):
                        continue
                    word_start = self._float_or_none(word.get("start"))
                    if word_start is None:
                        continue
                    word_end = self._float_or_none(word.get("end"))
                    if word_end is None or word_end < word_start:
                        word_end = word_start
                    speaker = self._speaker_for_interval(
                        intervals,
                        word_start,
                        word_end,
                        fill_nearest=True,
                    )
                    if speaker:
                        word["speaker"] = speaker
                        word_speaker_seconds[speaker] = (
                            word_speaker_seconds.get(speaker, 0.0)
                            + max(0.01, word_end - word_start)
                        )

            if word_speaker_seconds:
                segment["speaker"] = max(word_speaker_seconds.items(), key=lambda item: item[1])[0]
                continue

            speaker = self._speaker_for_interval(
                intervals,
                segment_start,
                segment_end,
                fill_nearest=True,
            )
            if speaker:
                segment["speaker"] = speaker

    def _diarization_intervals(self, diarize_segments: Any) -> list[tuple[float, float, str]]:
        intervals: list[tuple[float, float, str]] = []
        if hasattr(diarize_segments, "iterrows"):
            for _, row in diarize_segments.iterrows():
                start = self._float_or_none(row.get("start"))
                end = self._float_or_none(row.get("end"))
                speaker = row.get("speaker")
                if start is None or end is None or end <= start or speaker is None:
                    continue
                intervals.append((start, end, str(speaker)))
        elif hasattr(diarize_segments, "itertracks"):
            for turn, _, speaker in diarize_segments.itertracks(yield_label=True):
                start = self._float_or_none(getattr(turn, "start", None))
                end = self._float_or_none(getattr(turn, "end", None))
                if start is None or end is None or end <= start or speaker is None:
                    continue
                intervals.append((start, end, str(speaker)))
        intervals.sort(key=lambda item: item[0])
        return intervals

    def _speaker_for_interval(
        self,
        intervals: list[tuple[float, float, str]],
        start: float,
        end: float,
        *,
        fill_nearest: bool,
    ) -> str | None:
        if end < start:
            end = start

        overlaps: dict[str, float] = {}
        for diarize_start, diarize_end, speaker in intervals:
            if diarize_start > end:
                break
            intersection = min(diarize_end, end) - max(diarize_start, start)
            if intersection > 0:
                overlaps[speaker] = overlaps.get(speaker, 0.0) + intersection
        if overlaps:
            return max(overlaps.items(), key=lambda item: item[1])[0]

        if not fill_nearest:
            return None

        midpoint = (start + end) / 2
        nearest: tuple[float, str] | None = None
        for diarize_start, diarize_end, speaker in intervals:
            if diarize_start <= midpoint <= diarize_end:
                return speaker
            distance = min(abs(midpoint - diarize_start), abs(midpoint - diarize_end))
            if nearest is None or distance < nearest[0]:
                nearest = (distance, speaker)
        return nearest[1] if nearest else None

    def _join_words(self, words: list[str]) -> str:
        text = " ".join(word.strip() for word in words if word.strip())
        replacements = {
            " ,": ",",
            " .": ".",
            " !": "!",
            " ?": "?",
            " :": ":",
            " ;": ";",
            " )": ")",
            "( ": "(",
        }
        for old, new in replacements.items():
            text = text.replace(old, new)
        return text.strip()

    def _float_or_none(self, value: Any) -> float | None:
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

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

    def _diarize_with_single_speaker_retry(self, audio, duration_seconds: float | None):
        diarize_segments = self._diarize(audio)
        if not self._should_retry_single_speaker_diarization(diarize_segments, duration_seconds):
            return diarize_segments

        min_speakers = 2
        max_speakers = max(min_speakers, self.settings.diarization_single_speaker_retry_max_speakers)
        retry_segments = self._diarize(audio, min_speakers=min_speakers, max_speakers=max_speakers)
        if self._retry_diarization_is_usable(
            retry_segments,
            original_segments=diarize_segments,
            duration_seconds=duration_seconds,
        ):
            logger.info(
                "Accepted single-speaker diarization retry with min_speakers=%s max_speakers=%s.",
                min_speakers,
                max_speakers,
            )
            return retry_segments

        logger.info("Rejected single-speaker diarization retry; keeping auto diarization result.")
        return diarize_segments

    def _should_retry_single_speaker_diarization(
        self,
        diarize_segments: Any,
        duration_seconds: float | None,
    ) -> bool:
        if not self.settings.diarization_single_speaker_retry_enabled:
            return False
        if self.settings.diarization_min_speakers > 0 or self.settings.diarization_max_speakers > 0:
            return False
        min_duration = self.settings.diarization_single_speaker_retry_min_duration_seconds
        if duration_seconds is None or duration_seconds < min_duration:
            return False

        speaker_seconds = self._diarization_speaker_seconds(diarize_segments)
        min_speaker_seconds = self._retry_min_speaker_seconds(duration_seconds)
        strong_speakers = [
            speaker for speaker, seconds in speaker_seconds.items() if seconds >= min_speaker_seconds
        ]
        return len(strong_speakers) <= 1

    def _retry_diarization_is_usable(
        self,
        retry_segments: Any,
        *,
        original_segments: Any,
        duration_seconds: float | None,
    ) -> bool:
        retry_seconds = self._diarization_speaker_seconds(retry_segments)
        min_speaker_seconds = self._retry_min_speaker_seconds(duration_seconds)
        strong_speakers = [
            speaker for speaker, seconds in retry_seconds.items() if seconds >= min_speaker_seconds
        ]
        if len(strong_speakers) < 2:
            return False

        original_coverage = sum(self._diarization_speaker_seconds(original_segments).values())
        retry_coverage = sum(retry_seconds.values())
        if original_coverage > 0 and retry_coverage < original_coverage * 0.75:
            return False
        return retry_coverage > 0

    def _retry_min_speaker_seconds(self, duration_seconds: float | None) -> float:
        configured = max(0.0, self.settings.diarization_single_speaker_retry_min_speaker_seconds)
        if duration_seconds is None:
            return configured
        return max(configured, duration_seconds * 0.01)

    def _diarization_speaker_seconds(self, diarize_segments: Any) -> dict[str, float]:
        speaker_seconds: dict[str, float] = {}
        for start, end, speaker in self._diarization_intervals(diarize_segments):
            speaker_seconds[speaker] = speaker_seconds.get(speaker, 0.0) + max(0.0, end - start)
        return speaker_seconds

    def _diarize(
        self,
        audio,
        *,
        min_speakers: int | None = None,
        max_speakers: int | None = None,
    ):
        if not self.settings.diarization_enabled:
            return None
        diarize_model = self._get_diarize_model()
        if diarize_model is None:
            return None
        try:
            kwargs: dict[str, int] = {}
            resolved_min_speakers = (
                min_speakers if min_speakers is not None else self.settings.diarization_min_speakers
            )
            resolved_max_speakers = (
                max_speakers if max_speakers is not None else self.settings.diarization_max_speakers
            )
            if resolved_min_speakers > 0:
                kwargs["min_speakers"] = resolved_min_speakers
            if resolved_max_speakers > 0:
                kwargs["max_speakers"] = resolved_max_speakers
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
