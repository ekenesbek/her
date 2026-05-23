from __future__ import annotations

import mimetypes
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx

from telegram_transcriber_bot.config import Settings


@dataclass(frozen=True)
class TranscriptionResult:
    transcript: str
    language: str | None = None
    duration_seconds: float | None = None
    segments: list[dict[str, Any]] | None = None


class TranscriptionError(RuntimeError):
    pass


class TranscriptionClient:
    def __init__(self, settings: Settings):
        self.settings = settings

    async def transcribe(self, audio_path: Path) -> TranscriptionResult:
        content_type = mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream"
        headers = self._headers()

        try:
            async with httpx.AsyncClient(
                timeout=self.settings.transcription_timeout_seconds
            ) as client:
                with audio_path.open("rb") as audio:
                    response = await client.post(
                        self.settings.transcription_url,
                        headers=headers,
                        files={
                            self.settings.transcription_field_name: (
                                audio_path.name,
                                audio,
                                content_type,
                            )
                        },
                    )
                response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            body = exc.response.text.strip().replace("\n", " ")[:500]
            raise TranscriptionError(
                f"Transcription endpoint returned HTTP {exc.response.status_code}: {body}"
            ) from exc
        except httpx.HTTPError as exc:
            raise TranscriptionError(f"Transcription request failed: {exc}") from exc

        return parse_transcription_response(response.json())

    def _headers(self) -> dict[str, str]:
        if not self.settings.transcription_bearer_token:
            return {}
        return {"Authorization": f"Bearer {self.settings.transcription_bearer_token}"}


def parse_transcription_response(payload: dict[str, Any]) -> TranscriptionResult:
    transcript = payload.get("transcript")
    if not isinstance(transcript, str):
        raise TranscriptionError("Transcription response did not include a string transcript.")

    duration = payload.get("durationSeconds")
    if duration is not None:
        try:
            duration = float(duration)
        except (TypeError, ValueError):
            duration = None

    language = payload.get("language")
    if language is not None and not isinstance(language, str):
        language = None

    segments = payload.get("segments")
    if segments is not None and not isinstance(segments, list):
        segments = None

    return TranscriptionResult(
        transcript=transcript,
        language=language,
        duration_seconds=duration,
        segments=segments,
    )
