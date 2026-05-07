from pathlib import Path
from threading import Lock

from faster_whisper import WhisperModel

from app.schemas import TranscriptResponse
from app.settings import Settings


class WhisperTranscriber:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._model: WhisperModel | None = None
        self._lock = Lock()

    def transcribe(self, audio_path: Path) -> TranscriptResponse:
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
        )
        transcript = " ".join(segment.text.strip() for segment in segments).strip()
        return TranscriptResponse(
            transcript=transcript,
            language=getattr(info, "language", None),
            durationSeconds=getattr(info, "duration", None),
        )

    def _get_model(self) -> WhisperModel:
        with self._lock:
            if self._model is None:
                self._model = WhisperModel(
                    self.settings.whisper_model,
                    device=self.settings.whisper_device,
                    compute_type=self.settings.whisper_compute_type,
                )
            return self._model

