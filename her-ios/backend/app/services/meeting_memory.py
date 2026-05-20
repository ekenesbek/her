from __future__ import annotations

import re
from dataclasses import dataclass
from hashlib import sha256

from app.schemas import MeetingResponse, MemoryCandidateSensitivity


MAX_MEMORY_CANDIDATE_CHARS = 500

SECRET_VALUE_REDACTIONS = [
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b", re.I), "[redacted:github_pat]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b", re.I), "[redacted:github_token]"),
    (re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b", re.I), "[redacted:gitlab_token]"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b", re.I), "[redacted:slack_token]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b", re.I), "[redacted:api_key]"),
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b", re.I), "Bearer [redacted]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b", re.I), "[redacted:jwt]"),
    (
        re.compile(
            r"\b(password|passwd|api[_-]?key|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token|mfa|otp|recovery[_-]?code)\b\s*(?:is|=|:)\s*['\"]?[^'\"\s,;]+",
            re.I,
        ),
        r"\1: [redacted]",
    ),
    (
        re.compile(r"\b(card[_-]?number|credit[_-]?card|cvv|cvc)\b\s*(?:is|=|:)\s*['\"]?[^'\"\s,;]+", re.I),
        r"\1: [redacted]",
    ),
]

REVIEW_PATTERNS = [
    re.compile(r"\b(?:address|адрес|home|дом|work|office|офис|локац|location)\b", re.I),
    re.compile(r"\b(?:phone|телефон|email|e-mail|почта|whatsapp|telegram)\b", re.I),
    re.compile(r"\b(?:budget|price|cost|balance|payment|банк|карта|оплат|цена|стоим)\b", re.I),
]


@dataclass(frozen=True)
class MemoryCandidateDraft:
    stable_key: str
    kind: str
    text: str
    confidence: float
    sensitivity: MemoryCandidateSensitivity = "normal"
    source: str = "meeting_summary"


def build_meeting_memory_candidates(meeting: MeetingResponse) -> list[MemoryCandidateDraft]:
    """Extract reviewable memory candidates from a saved call or meeting summary."""
    drafts: list[MemoryCandidateDraft] = []

    for text in meeting.decisions:
        drafts.append(_draft(meeting.id, "decision", text, confidence=0.82))
    for text in meeting.actionItems:
        drafts.append(_draft(meeting.id, "action", text, confidence=0.78))
    for text in meeting.followUps:
        drafts.append(_draft(meeting.id, "follow_up", text, confidence=0.76))

    for topic in meeting.keyTopics:
        drafts.append(_draft(meeting.id, "topic", topic, confidence=0.58))

    if meeting.summaryMode == "call_note" or _looks_like_call_source(meeting.source):
        overview = _first_sentence(meeting.overview)
        if overview:
            drafts.append(_draft(meeting.id, "inbox", overview, confidence=0.52, source="call_summary"))

    seen: set[str] = set()
    result: list[MemoryCandidateDraft] = []
    for item in drafts:
        if item.text in seen or not item.text:
            continue
        seen.add(item.text)
        result.append(item)
    return result


def _draft(
    meeting_id: str,
    kind: str,
    raw_text: str,
    confidence: float,
    source: str = "meeting_summary",
) -> MemoryCandidateDraft:
    text = _clean_memory_text(_redact_secret_values(raw_text))
    sensitivity = _classify_sensitivity(text)
    stable_key = sha256(f"{meeting_id}:{kind}:{text}".encode("utf-8")).hexdigest()
    return MemoryCandidateDraft(
        stable_key=stable_key,
        kind=kind,
        text=text,
        confidence=confidence,
        sensitivity=sensitivity,
        source=source,
    )


def _clean_memory_text(value: str) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip(" \t\r\n-:;")
    if len(text) > MAX_MEMORY_CANDIDATE_CHARS:
        text = text[: MAX_MEMORY_CANDIDATE_CHARS - 1].rstrip(" ,;:-") + "…"
    return text


def _redact_secret_values(value: str) -> str:
    text = str(value or "")
    for pattern, replacement in SECRET_VALUE_REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


def _classify_sensitivity(text: str) -> MemoryCandidateSensitivity:
    if not text:
        return "sensitive"
    if "[redacted:" in text or "[redacted]" in text:
        return "sensitive"
    if any(pattern.search(text) for pattern in REVIEW_PATTERNS):
        return "review"
    return "normal"


def _first_sentence(text: str) -> str:
    clean = _clean_memory_text(text)
    if not clean:
        return ""
    match = re.search(r"(?<=[.!?。！？])\s+", clean)
    if match:
        return clean[: match.start()].strip()
    return clean[:220].rstrip(" ,;:-")


def _looks_like_call_source(source: str | None) -> bool:
    clean = (source or "").strip().lower()
    return any(
        token in clean
        for token in (
            "call",
            "phone",
            "facetime",
            "telegram",
            "whatsapp",
            "googlemeet",
            "google_meet",
            "meet",
        )
    )
