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
    SummaryMode,
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
        mode: SummaryMode = "reasoning",
    ) -> SummaryResponse:
        if mode == "full_transcript":
            return full_transcript_summary(transcript, segments)

        if not self.client:
            raise SummaryUnavailableError("AI summary is not configured.")

        response = self.client.chat.completions.create(
            model=self.settings.openai_summary_model,
            messages=[
                {
                    "role": "system",
                    "content": summary_system_prompt(mode),
                },
                {
                    "role": "user",
                    "content": format_transcript_for_summary(transcript, segments),
                },
            ],
        )

        content = response.choices[0].message.content
        formatted_transcript = format_transcript_for_summary(transcript, segments)
        payload = parse_summary_payload(
            content or "",
            formatted_transcript,
            requested_mode=mode,
        )
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
            summaryMode=payload["summaryMode"],
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


SUMMARY_MODE_NAMES: dict[SummaryMode, str] = {
    "reasoning": "Reasoning Summary",
    "full_transcript": "Full Transcript",
    "clean_detailed": "Clean Detailed Summary",
    "meeting_note": "Meeting Note",
    "call_note": "Call Note",
    "strategic_meeting": "Strategic Meeting Summary and Speaker Profiling",
    "concise_rewrite": "Simple Clear Concise Rewrite",
}


SUMMARY_MODE_INSTRUCTIONS: dict[SummaryMode, str] = {
    "reasoning": (
        "Act as an autopilot. Inspect the transcript, infer the content type and user value, "
        "choose the most suitable output mode, and then generate that output. Choose one of: "
        "meeting_note for team discussions and internal notes; call_note for sales, support, "
        "service, or phone-call style conversations; clean_detailed for operational extraction "
        "with tasks, contacts, tags, addresses, or scheduling; strategic_meeting for minutes-ready "
        "strategic discussions with speaker/group-dynamics analysis; concise_rewrite for drafts "
        "or monologues that mainly need polished prose; full_transcript only when a faithful "
        "external-use transcript is clearly the best output. Return the chosen mode in summaryMode."
    ),
    "full_transcript": (
        "Return a faithful chronological transcript without summarizing or interpreting. Preserve "
        "speaker changes when available. Put the complete transcript in overview, keep decision, "
        "actionItems, and followUps empty unless they are explicit transcript lines, and use the "
        "outline only as timestamp navigation."
    ),
    "clean_detailed": (
        "Produce a clean and highly detailed operational summary. Extract tasks, promises, names, "
        "contact details, addresses, scheduling details, service requests, and critical tags such "
        "as [URGENT], [QUOTE], [FOLLOW-UP], [CALLBACK], [SCHEDULING], [COMPLETED], and [ISSUE] "
        "when the transcript supports them."
    ),
    "meeting_note": (
        "Create structured meeting notes for a team. Include meeting information if present, main "
        "topics, subtopics, conclusions, decisions, open questions, and next arrangements. Keep the "
        "tone concise and reusable for internal notes."
    ),
    "call_note": (
        "Create a call note for sales or support. Capture call information, a concise conversation "
        "summary, customer or counterpart needs, commitments, next steps, owners, follow-up timing, "
        "and key details such as names, contact data, addresses, and references."
    ),
    "strategic_meeting": (
        "Create minutes-ready strategic notes. Include context, purpose, main topics, decisions, "
        "follow-up actions, open questions, speaker interaction profiling based only on transcript "
        "evidence, group dynamics, risks, and concrete suggestions for unresolved issues."
    ),
    "concise_rewrite": (
        "Rewrite the transcript into polished, simple, clear, and concise prose. Remove filler, "
        "redundancy, and loose phrasing while preserving essential facts, intent, names, decisions, "
        "and action items."
    ),
}


def summary_system_prompt(mode: SummaryMode) -> str:
    return (
        "You summarize meeting transcripts for a personal AI assistant. "
        f"Summary mode: {SUMMARY_MODE_NAMES[mode]}. {SUMMARY_MODE_INSTRUCTIONS[mode]} "
        "Return only valid JSON. Preserve names, decisions, owners, dates, risks, and "
        "follow-up questions. If an array has no evidence, return an empty array. JSON shape: "
        '{"summaryMode": string, "title": string, "overview": string, "keyTopics": string[], "decisions": string[], '
        '"actionItems": string[], "followUps": string[], '
        '"outline": [{"start": number, "title": string}]}. '
        "summaryMode must be one of reasoning, full_transcript, clean_detailed, meeting_note, "
        "call_note, strategic_meeting, or concise_rewrite. If the requested mode is not Reasoning "
        "Summary, set summaryMode to the requested mode. If the requested mode is Reasoning "
        "Summary, set summaryMode to the mode you selected for the transcript. "
        "The outline should be a compact chronological table of contents unless the selected mode "
        "requires a transcript-like output. Use the timestamps supplied in the transcript input. "
        "Do not translate text. Speaker labels such as SPEAKER_00, Speaker 1, and Participant 1 "
        "are machine labels, not real names or topics. Never use those labels in the title, key "
        "topics, overview, or outline titles unless the transcript explicitly gives a real person "
        "name. The title must describe what was discussed, not who the diarization label was."
    )


def full_transcript_summary(
    transcript: str,
    segments: list[TranscriptSegment] | None = None,
) -> SummaryResponse:
    formatted = format_transcript_for_summary(transcript, segments).strip()
    outline = build_outline_from_segments(transcript, segments)
    return SummaryResponse(
        title="Full transcript",
        overview=formatted or transcript,
        keyTopics=["Full transcript"],
        decisions=[],
        actionItems=[],
        followUps=[],
        outline=outline,
        generatedAt=datetime.now(UTC),
        summaryStatus="generated",
        summaryMode="full_transcript",
    )


def normalize_openai_base_url(raw_url: str) -> str:
    parsed = urlparse(raw_url.strip().rstrip("/"))
    path = parsed.path.rstrip("/")
    for suffix in ("/chat/completions", "/v1/chat/completions"):
        if path.endswith(suffix):
            path = path[: -len("/chat/completions")]
            break

    return urlunparse(parsed._replace(path=path or ""))


def parse_summary_payload(
    content: str,
    transcript: str = "",
    requested_mode: SummaryMode = "reasoning",
) -> dict[str, Any]:
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

    normalized: dict[str, Any] = {
        "summaryMode": selected_summary_mode(payload, requested_mode),
    }
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


def selected_summary_mode(payload: dict[str, Any], requested_mode: SummaryMode) -> SummaryMode:
    if requested_mode != "reasoning":
        return requested_mode
    raw_mode = str(payload.get("summaryMode", payload.get("mode", ""))).strip()
    if raw_mode in SUMMARY_MODE_NAMES:
        return raw_mode  # type: ignore[return-value]
    return "reasoning"


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
