from __future__ import annotations

import mimetypes
from pathlib import Path
from typing import Any

from app.schemas import TranscriptResponse
from app.settings import Settings


class ExternalTranscriber:
    """HTTP adapter for a separate GPU STT service."""

    def __init__(self, settings: Settings):
        if not settings.external_transcription_url:
            raise RuntimeError(
                "EXTERNAL_TRANSCRIPTION_URL is required when TRANSCRIPTION_PROVIDER=external."
            )
        self.settings = settings
        self._base_url = settings.external_transcription_url.rstrip("/")

    def transcribe(self, audio_path: Path) -> TranscriptResponse:
        import httpx

        content_type = mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream"
        with httpx.Client(timeout=self.settings.external_transcription_timeout_seconds) as client:
            with audio_path.open("rb") as audio:
                response = client.post(
                    f"{self._base_url}/v1/transcribe",
                    files={"audio": (audio_path.name, audio, content_type)},
                )
        response.raise_for_status()
        return self.parse_response(response.json())

    def parse_response(self, payload: dict[str, Any]) -> TranscriptResponse:
        return TranscriptResponse.model_validate(payload)
