import pytest

from telegram_transcriber_bot.config import Settings
from telegram_transcriber_bot.transcription_client import (
    TranscriptionClient,
    TranscriptionError,
    parse_transcription_response,
)


def test_parse_transcription_response() -> None:
    result = parse_transcription_response(
        {
            "transcript": "hello",
            "language": "en",
            "durationSeconds": "3.5",
            "segments": [{"start": 0, "end": 3.5, "text": "hello"}],
        }
    )

    assert result.transcript == "hello"
    assert result.language == "en"
    assert result.duration_seconds == 3.5
    assert result.segments == [{"start": 0, "end": 3.5, "text": "hello"}]


def test_parse_transcription_response_requires_transcript() -> None:
    with pytest.raises(TranscriptionError):
        parse_transcription_response({"text": "hello"})


def test_transcription_client_adds_bearer_header() -> None:
    settings = Settings(
        telegram_bot_token="token",
        transcription_bearer_token="secret",
    )

    assert TranscriptionClient(settings)._headers() == {"Authorization": "Bearer secret"}
