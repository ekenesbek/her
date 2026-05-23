from __future__ import annotations


def format_duration(seconds: float | None) -> str | None:
    if seconds is None:
        return None
    total = max(0, int(round(seconds)))
    minutes, secs = divmod(total, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def format_transcript_reply(
    transcript: str,
    *,
    language: str | None = None,
    duration_seconds: float | None = None,
) -> str:
    text = transcript.strip()
    if not text:
        text = "(empty transcript)"

    metadata: list[str] = []
    if language:
        metadata.append(language)
    duration = format_duration(duration_seconds)
    if duration:
        metadata.append(duration)

    if not metadata:
        return text
    return f"Transcript ({', '.join(metadata)}):\n\n{text}"


def split_reply(text: str, *, limit: int) -> list[str]:
    if limit <= 0:
        raise ValueError("limit must be positive")
    if len(text) <= limit:
        return [text]

    chunks: list[str] = []
    remaining = text
    while len(remaining) > limit:
        split_at = remaining.rfind("\n", 0, limit)
        if split_at < limit // 2:
            split_at = remaining.rfind(" ", 0, limit)
        if split_at < limit // 2:
            split_at = limit
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks
