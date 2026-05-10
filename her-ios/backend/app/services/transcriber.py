from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Lock

from faster_whisper import WhisperModel

from app.schemas import TranscriptResponse, TranscriptSegment
from app.services.audio_chunks import AudioChunk, should_chunk_audio, split_audio_chunks
from app.settings import Settings


class WhisperTranscriber:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._model: WhisperModel | None = None
        self._lock = Lock()

    def transcribe(self, audio_path: Path) -> TranscriptResponse:
        should_chunk, duration = should_chunk_audio(audio_path, self.settings)
        if should_chunk and duration is not None:
            return self._transcribe_chunks(audio_path, duration)
        return self._transcribe_file(audio_path)

    def _transcribe_file(self, audio_path: Path) -> TranscriptResponse:
        model = self._get_model()
        segments, info = model.transcribe(
            str(audio_path),
            language=self.settings.whisper_language or None,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 500},
            beam_size=5,
            condition_on_previous_text=True,
            temperature=[0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
            no_speech_threshold=0.6,
            compression_ratio_threshold=2.4,
            log_prob_threshold=-1.0,
            multilingual=self.settings.whisper_language is None,
            task="transcribe",
        )
        materialized_segments = [
            TranscriptSegment(
                start=float(segment.start or 0.0),
                end=float(segment.end or 0.0),
                text=segment.text.strip(),
            )
            for segment in segments
            if segment.text.strip()
        ]
        transcript = self._format_plain_transcript(materialized_segments)
        return TranscriptResponse(
            transcript=transcript,
            language=getattr(info, "language", None),
            durationSeconds=getattr(info, "duration", None),
            segments=materialized_segments,
        )

    def _transcribe_chunks(self, audio_path: Path, duration_seconds: float) -> TranscriptResponse:
        with split_audio_chunks(audio_path, self.settings, duration_seconds) as chunks:
            if len(chunks) <= 1:
                return self._transcribe_file(audio_path)

            max_workers = max(1, self.settings.transcription_chunk_workers)
            with ThreadPoolExecutor(
                max_workers=max_workers,
                thread_name_prefix="whisper-chunk",
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
            self._format_plain_transcript(segments)
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

    def _format_plain_transcript(self, segments: list[TranscriptSegment]) -> str:
        return " ".join(
            segment.text.strip() for segment in segments if segment.text.strip()
        ).strip()

    def _get_model(self) -> WhisperModel:
        with self._lock:
            if self._model is None:
                kwargs: dict[str, int] = {}
                if self.settings.whisper_cpu_threads > 0:
                    kwargs["cpu_threads"] = self.settings.whisper_cpu_threads
                if self.settings.whisper_num_workers > 1:
                    kwargs["num_workers"] = self.settings.whisper_num_workers
                self._model = WhisperModel(
                    self.settings.whisper_model,
                    device=self.settings.whisper_device,
                    compute_type=self.settings.whisper_compute_type,
                    **kwargs,
                )
            return self._model
