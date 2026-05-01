import json
from datetime import UTC, datetime

from openai import OpenAI

from app.schemas import SummaryResponse
from app.services.local_summary import summarize_locally
from app.settings import Settings


SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "overview": {"type": "string"},
        "decisions": {"type": "array", "items": {"type": "string"}},
        "actionItems": {"type": "array", "items": {"type": "string"}},
        "followUps": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["title", "overview", "decisions", "actionItems", "followUps"],
    "additionalProperties": False,
}


class SummaryService:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.client = OpenAI(api_key=settings.openai_api_key) if settings.openai_api_key else None

    def summarize(self, transcript: str) -> SummaryResponse:
        if not self.client:
            return summarize_locally(transcript)

        response = self.client.responses.create(
            model=self.settings.openai_summary_model,
            input=[
                {
                    "role": "system",
                    "content": (
                        "You summarize meeting transcripts for a personal AI assistant. "
                        "Return concise, factual JSON. Preserve names, decisions, owners, "
                        "dates, risks, and follow-up questions. If an array has no evidence, "
                        "return an empty array."
                    ),
                },
                {"role": "user", "content": transcript},
            ],
            text={
                "format": {
                    "type": "json_schema",
                    "name": "meeting_summary",
                    "schema": SUMMARY_SCHEMA,
                    "strict": True,
                }
            },
        )

        payload = json.loads(response.output_text)
        return SummaryResponse(
            title=payload["title"],
            overview=payload["overview"],
            decisions=payload["decisions"],
            actionItems=payload["actionItems"],
            followUps=payload["followUps"],
            generatedAt=datetime.now(UTC),
        )

