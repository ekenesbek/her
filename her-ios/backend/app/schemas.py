from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: Literal["ok"]
    version: str
    database: str
    transcriptionProvider: str
    whisperModel: str
    summaryModel: str
    openaiConfigured: bool


class TranscriptSegment(BaseModel):
    start: float
    end: float
    text: str
    speaker: str | None = None


class MeetingOutlineItem(BaseModel):
    start: float
    title: str


class TranscriptResponse(BaseModel):
    transcript: str
    language: str | None = None
    durationSeconds: float | None = None
    segments: list[TranscriptSegment] = Field(default_factory=list)


class VoiceProfileResponse(BaseModel):
    id: str
    name: str
    durationSeconds: float | None = None
    sampleCount: int = 1
    createdAt: datetime


class VoiceProfileListResponse(BaseModel):
    profiles: list[VoiceProfileResponse]


class SpeakerAssignmentRequest(BaseModel):
    speaker: str = Field(min_length=1)
    profileId: str | None = None
    name: str | None = None


class SpeakerAssignmentResponse(BaseModel):
    profile: VoiceProfileResponse
    meeting: "MeetingResponse"
    assignedSegments: int
    sampleDurationSeconds: float | None = None


SummaryStatus = Literal["generated", "unavailable"]
SummaryMode = Literal[
    "reasoning",
    "full_transcript",
    "clean_detailed",
    "meeting_note",
    "call_note",
    "strategic_meeting",
    "concise_rewrite",
]


class SummaryRequest(BaseModel):
    transcript: str = Field(min_length=1)
    summaryMode: SummaryMode = "reasoning"
    language: str | None = None


class SummaryResponse(BaseModel):
    title: str
    overview: str
    keyTopics: list[str] = Field(default_factory=list)
    decisions: list[str]
    actionItems: list[str]
    followUps: list[str]
    outline: list[MeetingOutlineItem] = Field(default_factory=list)
    generatedAt: datetime
    summaryStatus: SummaryStatus = "generated"
    summaryMode: SummaryMode = "reasoning"


class MeetingResponse(SummaryResponse):
    id: str
    transcript: str
    segments: list[TranscriptSegment] = Field(default_factory=list)
    language: str | None = None
    durationSeconds: float | None = None
    source: str | None = None
    deviceName: str | None = None
    locationName: str | None = None
    hasAudio: bool = False
    createdAt: datetime


class MeetingSaveRequest(BaseModel):
    transcript: str = Field(min_length=1)
    segments: list[TranscriptSegment] = Field(default_factory=list)
    language: str | None = None
    durationSeconds: float | None = None
    source: str | None = None
    deviceName: str | None = None
    locationName: str | None = None
    title: str
    overview: str
    keyTopics: list[str] = Field(default_factory=list)
    decisions: list[str] = Field(default_factory=list)
    actionItems: list[str] = Field(default_factory=list)
    followUps: list[str] = Field(default_factory=list)
    outline: list[MeetingOutlineItem] = Field(default_factory=list)
    generatedAt: datetime
    summaryStatus: SummaryStatus = "generated"
    summaryMode: SummaryMode = "reasoning"


class MeetingTranscriptUpdateRequest(BaseModel):
    transcript: str = Field(min_length=1)
    segments: list[TranscriptSegment] = Field(default_factory=list)


class SummaryModeRequest(BaseModel):
    summaryMode: SummaryMode = "reasoning"


class MeetingListResponse(BaseModel):
    meetings: list[MeetingResponse]


class MeetingChatRequest(BaseModel):
    question: str = Field(min_length=1)


MeetingChatRole = Literal["user", "assistant"]


class MeetingChatMessageResponse(BaseModel):
    id: str
    role: MeetingChatRole
    content: str
    createdAt: datetime


class MeetingChatListResponse(BaseModel):
    messages: list[MeetingChatMessageResponse]


class MeetingChatResponse(BaseModel):
    answer: str
    generatedAt: datetime


MeetingJobStatus = Literal["queued", "processing", "completed", "failed"]


class MeetingJobResponse(BaseModel):
    id: str
    status: MeetingJobStatus
    meetingId: str | None = None
    error: str | None = None
    createdAt: datetime
    updatedAt: datetime
    meeting: MeetingResponse | None = None


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
    isNewUser: bool = False
