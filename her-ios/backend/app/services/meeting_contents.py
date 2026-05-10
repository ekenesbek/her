from __future__ import annotations

import re

from app.schemas import MeetingOutlineItem, TranscriptSegment


SENTENCE_ENDINGS = (".", "!", "?", "。", "！", "？")


def format_time(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def format_transcript_for_summary(
    transcript: str,
    segments: list[TranscriptSegment] | None = None,
) -> str:
    usable_segments = [segment for segment in segments or [] if segment.text.strip()]
    if not usable_segments:
        return transcript

    lines = []
    for segment in usable_segments:
        speaker = segment.speaker or "Speaker"
        lines.append(f"[{format_time(segment.start)}] {speaker}: {segment.text.strip()}")
    return "\n".join(lines)


def build_outline_from_segments(
    transcript: str,
    segments: list[TranscriptSegment] | None = None,
    max_items: int = 8,
) -> list[MeetingOutlineItem]:
    usable_segments = sorted(
        (segment for segment in segments or [] if segment.text.strip()),
        key=lambda segment: segment.start,
    )
    if not usable_segments:
        title = make_outline_title(transcript)
        return [MeetingOutlineItem(start=0.0, title=title)] if title else []

    groups: list[list[TranscriptSegment]] = []
    current: list[TranscriptSegment] = []

    for segment in usable_segments:
        if not current:
            current = [segment]
            continue

        previous = current[-1]
        group_start = current[0].start
        gap = segment.start - previous.end
        group_duration = max(previous.end, segment.end) - group_start
        previous_ended_sentence = previous.text.strip().endswith(SENTENCE_ENDINGS)

        should_break = gap >= 12 or group_duration >= 140 or (
            group_duration >= 75 and previous_ended_sentence
        )
        if should_break:
            groups.append(current)
            current = [segment]
        else:
            current.append(segment)

    if current:
        groups.append(current)

    if len(groups) > max_items:
        groups = merge_smallest_neighbor_groups(groups, max_items=max_items)

    outline: list[MeetingOutlineItem] = []
    for group in groups[:max_items]:
        title = make_outline_title(" ".join(segment.text for segment in group))
        if title:
            outline.append(MeetingOutlineItem(start=max(0.0, group[0].start), title=title))
    return outline


def merge_smallest_neighbor_groups(
    groups: list[list[TranscriptSegment]],
    max_items: int,
) -> list[list[TranscriptSegment]]:
    merged = [list(group) for group in groups]
    while len(merged) > max_items:
        merge_index = min(
            range(len(merged) - 1),
            key=lambda index: len(" ".join(segment.text for segment in merged[index])),
        )
        merged[merge_index].extend(merged.pop(merge_index + 1))
    return merged


def make_outline_title(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", text).strip()
    cleaned = re.sub(r"^(SPEAKER[_\s-]*\d+|Speaker\s*\d+|Speaker):\s*", "", cleaned, flags=re.I)
    if not cleaned:
        return ""

    first_sentence = re.split(r"(?<=[.!?])\s+", cleaned, maxsplit=1)[0].strip(" .!?")
    words = first_sentence.split()
    title = " ".join(words[:12]).strip(" ,;:-")
    if len(title) > 88:
        title = title[:85].rstrip(" ,;:-") + "..."
    return title or cleaned[:88]
