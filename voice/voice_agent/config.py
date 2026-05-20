"""Runtime config loaded from environment."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from dotenv import load_dotenv

load_dotenv()


def _req(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(f"Missing required env var: {key}")
    return value


def _opt(key: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(key)
    return value if value else default


@dataclass(frozen=True)
class Config:
    livekit_url: str
    livekit_api_key: str
    livekit_api_secret: str

    deepgram_api_key: str

    anthropic_api_key: str
    anthropic_model: str

    cartesia_api_key: str
    cartesia_voice_id: str

    her_backend_url: Optional[str]
    her_backend_token: Optional[str]

    silence_timeout_seconds: int
    turn_silence_ms: int
    log_level: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            livekit_url=_req("LIVEKIT_URL"),
            livekit_api_key=_req("LIVEKIT_API_KEY"),
            livekit_api_secret=_req("LIVEKIT_API_SECRET"),
            deepgram_api_key=_req("DEEPGRAM_API_KEY"),
            anthropic_api_key=_req("ANTHROPIC_API_KEY"),
            anthropic_model=_opt("ANTHROPIC_MODEL", "claude-sonnet-4-6") or "claude-sonnet-4-6",
            cartesia_api_key=_req("CARTESIA_API_KEY"),
            cartesia_voice_id=_req("CARTESIA_VOICE_ID"),
            her_backend_url=_opt("HER_BACKEND_URL"),
            her_backend_token=_opt("HER_BACKEND_TOKEN"),
            silence_timeout_seconds=int(_opt("SILENCE_TIMEOUT_SECONDS", "30") or 30),
            turn_silence_ms=int(_opt("TURN_SILENCE_MS", "600") or 600),
            log_level=_opt("LOG_LEVEL", "INFO") or "INFO",
        )
