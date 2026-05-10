import json
import re
from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlparse, urlunparse

from openai import OpenAI

from app.schemas import (
    MeetingChatMessageResponse,
    MeetingChatResponse,
    MeetingOutlineItem,
    MeetingResponse,
    SummaryResponse,
    TranscriptSegment,
)
from app.services.meeting_contents import (
    RAW_SPEAKER_LABEL_RE,
    build_outline_from_segments,
    format_transcript_for_summary,
    make_outline_title,
)
from app.settings import Settings


class SummaryService:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.client = self._make_client(settings)

    def summarize(
        self,
        transcript: str,
        segments: list[TranscriptSegment] | None = None,
    ) -> SummaryResponse:
        if not self.client:
            raise SummaryUnavailableError("AI summary is not configured.")

        response = self.client.chat.completions.create(
            model=self.settings.openai_summary_model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You summarize meeting transcripts for a personal AI assistant. "
                        "Return only valid JSON. Preserve names, decisions, owners, "
                        "dates, risks, and follow-up questions. If an array has no evidence, "
                        "return an empty array. JSON shape: "
                        '{"title": string, "overview": string, "keyTopics": string[], "decisions": string[], '
                        '"actionItems": string[], "followUps": string[], '
                        '"outline": [{"start": number, "title": string}]}. '
                        "The outline should be a compact chronological table of contents. "
                        "Use the timestamps supplied in the transcript input. Do not translate text. "
                        "Speaker labels such as SPEAKER_00, Speaker 1, and Participant 1 are machine labels, "
                        "not real names or topics. Never use those labels in the title, key topics, "
                        "overview, or outline titles unless the transcript explicitly gives a real person name. "
                        "The title must describe what was discussed, not who the diarization label was."
                    ),
                },
                {
                    "role": "user",
                    "content": format_transcript_for_summary(transcript, segments),
                },
            ],
        )

        content = response.choices[0].message.content
        formatted_transcript = format_transcript_for_summary(transcript, segments)
        payload = parse_summary_payload(content or "", formatted_transcript)
        outline = payload["outline"] or build_outline_from_segments(transcript, segments)
        return SummaryResponse(
            title=payload["title"],
            overview=payload["overview"],
            keyTopics=payload["keyTopics"],
            decisions=payload["decisions"],
            actionItems=payload["actionItems"],
            followUps=payload["followUps"],
            outline=outline,
            generatedAt=datetime.now(UTC),
            summaryStatus="generated",
        )

    def answer_question(
        self,
        meeting: MeetingResponse,
        question: str,
        history: list[MeetingChatMessageResponse] | None = None,
    ) -> MeetingChatResponse:
        clean_question = question.strip()
        if not clean_question:
            raise ValueError("Question is required.")

        if not self.client:
            return MeetingChatResponse(
                answer=answer_question_locally(meeting, clean_question),
                generatedAt=datetime.now(UTC),
            )

        response = self.client.chat.completions.create(
            model=self.settings.openai_summary_model,
            messages=meeting_chat_messages(meeting, clean_question, history),
        )
        answer = (response.choices[0].message.content or "").strip()
        return MeetingChatResponse(
            answer=answer or "I could not find an answer in this conversation.",
            generatedAt=datetime.now(UTC),
        )

    def stream_answer_question(
        self,
        meeting: MeetingResponse,
        question: str,
        history: list[MeetingChatMessageResponse] | None = None,
    ) -> Iterator[str]:
        clean_question = question.strip()
        if not clean_question:
            raise ValueError("Question is required.")

        if not self.client:
            yield answer_question_locally(meeting, clean_question)
            return

        stream = self.client.chat.completions.create(
            model=self.settings.openai_summary_model,
            messages=meeting_chat_messages(meeting, clean_question, history),
            stream=True,
        )
        yielded = False
        for chunk in stream:
            if not chunk.choices:
                continue
            content = chunk.choices[0].delta.content
            if content:
                yielded = True
                yield content
        if not yielded:
            yield "I could not find an answer in this conversation."

    @staticmethod
    def _make_client(settings: Settings) -> OpenAI | None:
        api_key = settings.llm_api_key
        if not api_key:
            return None

        kwargs: dict[str, str] = {"api_key": api_key}
        if settings.llm_base_url:
            kwargs["base_url"] = normalize_openai_base_url(settings.llm_base_url)
        return OpenAI(**kwargs)


class SummaryUnavailableError(RuntimeError):
    pass


def normalize_openai_base_url(raw_url: str) -> str:
    parsed = urlparse(raw_url.strip().rstrip("/"))
    path = parsed.path.rstrip("/")
    for suffix in ("/chat/completions", "/v1/chat/completions"):
        if path.endswith(suffix):
            path = path[: -len("/chat/completions")]
            break

    return urlunparse(parsed._replace(path=path or ""))


def parse_summary_payload(content: str, transcript: str = "") -> dict[str, Any]:
    trimmed = content.strip()
    if trimmed.startswith("```"):
        lines = trimmed.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].startswith("```"):
            lines = lines[:-1]
        trimmed = "\n".join(lines).strip()

    payload = json.loads(trimmed)
    if not isinstance(payload, dict):
        raise ValueError("Summary response was not a JSON object.")

    normalized: dict[str, Any] = {}
    for key, fallback in {
        "title": "Meeting summary",
        "overview": "",
        "keyTopics": [],
        "decisions": [],
        "actionItems": [],
        "followUps": [],
        "outline": [],
    }.items():
        value = payload.get(key, fallback)
        if key in {"title", "overview"}:
            raw_text = str(value).strip()
            cleaned_text = clean_summary_text(raw_text)
            if key == "title" and (
                not cleaned_text
                or title_uses_machine_label(raw_text)
                or title_uses_machine_label(cleaned_text)
            ):
                cleaned_text = fallback_title_from_transcript(transcript)
            normalized[key] = cleaned_text or fallback
        elif key == "outline" and isinstance(value, list):
            normalized[key] = normalize_outline(value)
        elif isinstance(value, list):
            normalized[key] = clean_summary_list(value)
        else:
            normalized[key] = []

    if title_uses_machine_label(normalized["title"]):
        normalized["title"] = fallback_title_from_transcript(transcript)
    if not normalized["keyTopics"]:
        normalized["keyTopics"] = [normalized["title"]]
    return normalized


def normalize_outline(value: list[Any]) -> list[MeetingOutlineItem]:
    items: list[MeetingOutlineItem] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        raw_start = item.get("start", item.get("startSeconds", item.get("time", 0)))
        try:
            start = float(raw_start)
        except (TypeError, ValueError):
            start = 0.0
        title = clean_summary_text(str(item.get("title", item.get("text", ""))).strip())
        if title:
            items.append(MeetingOutlineItem(start=max(0.0, start), title=title))
    return items


def clean_summary_list(value: list[Any]) -> list[str]:
    items: list[str] = []
    for item in value:
        text = clean_summary_text(str(item).strip())
        if not text or title_uses_machine_label(text):
            continue
        items.append(text)
    return items


def clean_summary_text(text: str) -> str:
    cleaned = RAW_SPEAKER_LABEL_RE.sub("", text)
    cleaned = re.sub(r"\b(?:Interview|Conversation|Meeting)\s+with\s*$", "", cleaned, flags=re.I)
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    cleaned = re.sub(r"\s+([,.;:!?])", r"\1", cleaned)
    return cleaned.strip(" \t\r\n-:;,")


def title_uses_machine_label(text: str) -> bool:
    if RAW_SPEAKER_LABEL_RE.search(text):
        return True
    lowered = text.lower().strip()
    return lowered in {"interview", "conversation", "meeting", "interview with"}


def fallback_title_from_transcript(transcript: str) -> str:
    title = make_outline_title(transcript)
    if title and not title_uses_machine_label(title):
        return title
    return "Meeting summary"


def format_meeting_chat_context(meeting: MeetingResponse) -> str:
    outline = "\n".join(
        f"- {item.start:.0f}s: {item.title}" for item in meeting.outline
    )
    transcript = format_transcript_for_summary(meeting.transcript, meeting.segments)
    return (
        f"Title: {meeting.title}\n"
        f"Overview: {meeting.overview}\n\n"
        f"Outline:\n{outline or '- No outline'}\n\n"
        f"Transcript:\n{transcript}"
    )


def meeting_chat_messages(
    meeting: MeetingResponse,
    question: str,
    history: list[MeetingChatMessageResponse] | None = None,
) -> list[dict[str, str]]:
    messages = [
        {
            "role": "system",
            "content": (
                "You answer questions about one recorded meeting for a personal AI assistant. "
                "Use only the provided meeting transcript, outline, and summary. "
                "If the answer is not present, say that it is not in this conversation. "
                "Preserve the user's language and do not translate quoted transcript text. "
                "Use the prior chat turns only to resolve references and continue the meeting Q&A."
            ),
        },
        {
            "role": "user",
            "content": "Meeting context:\n" + format_meeting_chat_context(meeting),
        },
    ]
    for item in (history or [])[-20:]:
        content = item.content.strip()
        if content:
            messages.append({"role": item.role, "content": content})
    messages.append({"role": "user", "content": question})
    return messages


def answer_question_locally(meeting: MeetingResponse, question: str) -> str:
    lowercased = question.lower()
    if any(token in lowercased for token in ("action", "todo", "зада", "делать")):
        return (
            "\n".join(meeting.actionItems)
            if meeting.actionItems
            else "No action items were found in this conversation."
        )
    if any(token in lowercased for token in ("decision", "реш", "договор")):
        return (
            "\n".join(meeting.decisions)
            if meeting.decisions
            else "No decisions were found in this conversation."
        )
    if any(token in lowercased for token in ("follow", "напом", "след", "уточ")):
        return (
            "\n".join(meeting.followUps)
            if meeting.followUps
            else "No follow-ups were found in this conversation."
        )
    if any(token in lowercased for token in ("outline", "contents", "тайм", "план")):
        return "\n".join(f"{item.start:.0f}s: {item.title}" for item in meeting.outline) or meeting.overview
    if any(token in lowercased for token in ("transcript", "транск")):
        return meeting.transcript
    return meeting.overview
