from telegram_transcriber_bot.messages import format_duration, format_transcript_reply, split_reply


def test_format_duration() -> None:
    assert format_duration(17.4) == "0:17"
    assert format_duration(65) == "1:05"
    assert format_duration(3661) == "1:01:01"


def test_format_transcript_reply_with_metadata() -> None:
    assert (
        format_transcript_reply("hello", language="en", duration_seconds=65)
        == "Transcript (en, 1:05):\n\nhello"
    )


def test_split_reply_prefers_word_boundary() -> None:
    assert split_reply("one two three", limit=8) == ["one two", "three"]
