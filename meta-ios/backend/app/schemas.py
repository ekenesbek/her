from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: Literal["ok"]
    version: str
    database: str
    whisperModel: str
    summaryModel: str
    openaiConfigured: bool


class TranscriptResponse(BaseModel):
    transcript: str
    language: str | None = None
    durationSeconds: float | None = None


class SummaryRequest(BaseModel):
    transcript: str = Field(min_length=1)


class SummaryResponse(BaseModel):
    title: str
    overview: str
    decisions: list[str]
    actionItems: list[str]
    followUps: list[str]
    generatedAt: datetime


class MeetingResponse(SummaryResponse):
    id: str
    transcript: str
    language: str | None = None
    durationSeconds: float | None = None
    source: str | None = None
    deviceName: str | None = None
    locationName: str | None = None
    createdAt: datetime


class MeetingListResponse(BaseModel):
    meetings: list[MeetingResponse]
