from __future__ import annotations

import re

from app.schemas import TranscriptSegment

_SPEAKER_NUMBER_RE = re.compile(r"^(?:speaker[_ -]?)?(\d+)$", re.IGNORECASE)


def normalize_speaker_label(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, int):
        return f"SPEAKER_{value:02d}"

    label = str(value).strip()
    if not label:
        return None

    match = _SPEAKER_NUMBER_RE.match(label)
    if match:
        return f"SPEAKER_{int(match.group(1)):02d}"

    if label.upper().startswith("SPEAKER_"):
        suffix = label.split("_", 1)[1]
        if suffix.isdigit():
            return f"SPEAKER_{int(suffix):02d}"
        return f"SPEAKER_{suffix}"

    return label


def join_words(words: list[str]) -> str:
    text = " ".join(word.strip() for word in words if word.strip())
    replacements = {
        " ,": ",",
        " .": ".",
        " !": "!",
        " ?": "?",
        " :": ":",
        " ;": ";",
        " )": ")",
        "( ": "(",
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    return text.strip()


def format_speaker_transcript(segments: list[TranscriptSegment]) -> str:
    if not segments:
        return ""

    lines: list[str] = []
    last_speaker: str | None = None
    buffer: list[str] = []
    for segment in segments:
        speaker = segment.speaker or "Speaker"
        if speaker != last_speaker:
            if buffer:
                lines.append(f"{last_speaker}: " + " ".join(buffer))
                buffer = []
            last_speaker = speaker
        buffer.append(segment.text)
    if buffer:
        lines.append(f"{last_speaker}: " + " ".join(buffer))
    return "\n".join(lines)


def format_plain_transcript(segments: list[TranscriptSegment]) -> str:
    return " ".join(
        segment.text.strip() for segment in segments if segment.text.strip()
    ).strip()
