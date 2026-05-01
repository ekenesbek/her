from datetime import UTC, datetime

from app.schemas import SummaryResponse


ACTION_KEYWORDS = [
    "action",
    "todo",
    "owner",
    "need to",
    "should",
    "must",
    "next step",
    "нужно",
    "надо",
    "сделать",
    "ответственный",
]
DECISION_KEYWORDS = [
    "decided",
    "agreed",
    "approved",
    "confirmed",
    "decision",
    "решили",
    "договорились",
    "подтвердили",
]
FOLLOW_UP_KEYWORDS = [
    "follow up",
    "next meeting",
    "later",
    "check",
    "confirm",
    "следующий",
    "проверить",
    "уточнить",
    "созвон",
]


def summarize_locally(transcript: str) -> SummaryResponse:
    sentences = split_sentences(transcript)
    overview = ". ".join(sentences[:3])

    return SummaryResponse(
        title=make_title(transcript),
        overview=overview or "No transcript content was available to summarize.",
        decisions=extract(sentences, DECISION_KEYWORDS) or ["No explicit decisions detected."],
        actionItems=extract(sentences, ACTION_KEYWORDS) or ["No explicit action items detected."],
        followUps=extract(sentences, FOLLOW_UP_KEYWORDS) or ["No follow-ups detected."],
        generatedAt=datetime.now(UTC),
    )


def split_sentences(text: str) -> list[str]:
    normalized = text.replace("\n", ". ")
    parts: list[str] = []
    current: list[str] = []
    for char in normalized:
        current.append(char)
        if char in ".!?":
            sentence = "".join(current).strip(" \t\r\n.!?")
            if sentence:
                parts.append(sentence)
            current = []
    tail = "".join(current).strip(" \t\r\n.!?")
    if tail:
        parts.append(tail)
    return parts


def extract(sentences: list[str], keywords: list[str]) -> list[str]:
    matches: list[str] = []
    for sentence in sentences:
        lower = sentence.lower()
        if any(keyword in lower for keyword in keywords):
            matches.append(sentence)
        if len(matches) >= 5:
            break
    return matches


def make_title(transcript: str) -> str:
    words = transcript.split()
    return " ".join(words[:6]) if words else "Meeting summary"

