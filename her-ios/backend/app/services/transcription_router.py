from __future__ import annotations

from pathlib import Path
from typing import Protocol

from app.schemas import TranscriptResponse
from app.settings import Settings


class Transcriber(Protocol):
    def transcribe(self, audio_path: Path) -> TranscriptResponse: ...


def build_transcriber(settings: Settings) -> Transcriber:
    if settings.transcription_provider == "deepgram":
        from app.services.deepgram_transcriber import DeepgramTranscriber

        return DeepgramTranscriber(settings)

    if settings.transcription_provider == "external":
        from app.services.external_transcriber import ExternalTranscriber

        return ExternalTranscriber(settings)

    if settings.diarization_enabled:
        from app.services.diarizer import WhisperXTranscriber

        return WhisperXTranscriber(settings)

    from app.services.transcriber import WhisperTranscriber

    return WhisperTranscriber(settings)
