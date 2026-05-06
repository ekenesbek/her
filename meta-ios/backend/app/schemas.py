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


class TranscriptSegment(BaseModel):
    start: float
    end: float
    text: str
    speaker: str | None = None


class TranscriptResponse(BaseModel):
    transcript: str
    language: str | None = None
    durationSeconds: float | None = None
    segments: list[TranscriptSegment] = []


class VoiceProfileResponse(BaseModel):
    id: str
    name: str
    durationSeconds: float | None = None
    createdAt: datetime


class VoiceProfileListResponse(BaseModel):
    profiles: list[VoiceProfileResponse]


class SummaryRequest(BaseModel):
    transcript: str = Field(min_length=1)


class SummaryResponse(BaseModel):
    title: str
    overview: str
    keyTopics: list[str] = []
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


class MeetingSaveRequest(BaseModel):
    transcript: str = Field(min_length=1)
    language: str | None = None
    durationSeconds: float | None = None
    source: str | None = None
    deviceName: str | None = None
    locationName: str | None = None
    title: str
    overview: str
    keyTopics: list[str] = []
    decisions: list[str] = []
    actionItems: list[str] = []
    followUps: list[str] = []
    generatedAt: datetime


class MeetingListResponse(BaseModel):
    meetings: list[MeetingResponse]


class UserResponse(BaseModel):
    id: str
    provider: Literal["apple", "google"]
    email: str | None = None
    name: str | None = None
    createdAt: datetime


class AuthAppleRequest(BaseModel):
    identityToken: str = Field(min_length=1)
    fullName: str | None = None
    email: str | None = None


class AuthGoogleRequest(BaseModel):
    idToken: str = Field(min_length=1)


class AuthResponse(BaseModel):
    token: str
    expiresAt: datetime
    user: UserResponse
