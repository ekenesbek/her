import json
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlparse, urlunparse

from openai import OpenAI

from app.schemas import SummaryResponse
from app.services.local_summary import summarize_locally
from app.settings import Settings


class SummaryService:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.client = self._make_client(settings)

    def summarize(self, transcript: str) -> SummaryResponse:
        if not self.client:
            return summarize_locally(transcript)

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
                        '"actionItems": string[], "followUps": string[]}.'
                    ),
                },
                {"role": "user", "content": transcript},
            ],
        )

        content = response.choices[0].message.content
        payload = parse_summary_payload(content or "")
        return SummaryResponse(
            title=payload["title"],
            overview=payload["overview"],
            keyTopics=payload["keyTopics"],
            decisions=payload["decisions"],
            actionItems=payload["actionItems"],
            followUps=payload["followUps"],
            generatedAt=datetime.now(UTC),
        )

    @staticmethod
    def _make_client(settings: Settings) -> OpenAI | None:
        if not settings.openai_api_key:
            return None

        kwargs: dict[str, str] = {"api_key": settings.openai_api_key}
        if settings.openai_base_url:
            kwargs["base_url"] = normalize_openai_base_url(settings.openai_base_url)
        return OpenAI(**kwargs)


def normalize_openai_base_url(raw_url: str) -> str:
    parsed = urlparse(raw_url.strip().rstrip("/"))
    path = parsed.path.rstrip("/")
    for suffix in ("/chat/completions", "/v1/chat/completions"):
        if path.endswith(suffix):
            path = path[: -len("/chat/completions")]
            break

    return urlunparse(parsed._replace(path=path or ""))


def parse_summary_payload(content: str) -> dict[str, Any]:
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
    }.items():
        value = payload.get(key, fallback)
        if key in {"title", "overview"}:
            normalized[key] = str(value).strip() or fallback
        elif isinstance(value, list):
            normalized[key] = [str(item).strip() for item in value if str(item).strip()]
        else:
            normalized[key] = []

    return normalized
