from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv


DEFAULT_TRANSCRIPTION_URL = "http://127.0.0.1:8000/v1/transcribe"


@dataclass(frozen=True)
class Settings:
    telegram_bot_token: str
    transcription_url: str = DEFAULT_TRANSCRIPTION_URL
    transcription_field_name: str = "audio"
    transcription_bearer_token: str | None = None
    transcription_timeout_seconds: float = 600
    max_audio_bytes: int = 20 * 1024 * 1024
    max_reply_chars: int = 3900
    allowed_telegram_user_ids: frozenset[int] | None = None


def load_settings() -> Settings:
    load_dotenv()

    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is required.")

    bearer_token = (
        os.environ.get("TRANSCRIPTION_BEARER_TOKEN")
        or os.environ.get("HER_AUTH_TOKEN")
        or ""
    ).strip()

    return Settings(
        telegram_bot_token=token,
        transcription_url=os.environ.get("TRANSCRIPTION_URL", DEFAULT_TRANSCRIPTION_URL).strip(),
        transcription_field_name=os.environ.get("TRANSCRIPTION_FIELD_NAME", "audio").strip()
        or "audio",
        transcription_bearer_token=bearer_token or None,
        transcription_timeout_seconds=_read_float("TRANSCRIPTION_TIMEOUT_SECONDS", 600),
        max_audio_bytes=_read_int("MAX_AUDIO_BYTES", 20 * 1024 * 1024),
        max_reply_chars=_read_int("MAX_REPLY_CHARS", 3900),
        allowed_telegram_user_ids=_read_user_ids("ALLOWED_TELEGRAM_USER_IDS"),
    )


def _read_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer.") from exc


def _read_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be a number.") from exc


def _read_user_ids(name: str) -> frozenset[int] | None:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    ids: set[int] = set()
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            ids.add(int(item))
        except ValueError as exc:
            raise RuntimeError(f"{name} must contain comma-separated Telegram numeric ids.") from exc
    return frozenset(ids) if ids else None
