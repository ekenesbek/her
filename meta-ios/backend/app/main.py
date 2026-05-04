from datetime import UTC, datetime
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

from fastapi import FastAPI, File, HTTPException, UploadFile

from app.schemas import (
    HealthResponse,
    MeetingListResponse,
    MeetingResponse,
    SummaryRequest,
    SummaryResponse,
    TranscriptResponse,
)
from app.services.storage import MeetingStore
from app.services.summarizer import SummaryService
from app.services.transcriber import WhisperTranscriber
from app.settings import get_settings

settings = get_settings()
transcriber = WhisperTranscriber(settings)
summarizer = SummaryService(settings)
store = MeetingStore(settings.data_dir)

app = FastAPI(title="Meta iOS Backend", version="0.2.0")


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        version=app.version,
        database=str(store.db_path),
        whisperModel=settings.whisper_model,
        summaryModel=settings.openai_summary_model,
        openaiConfigured=bool(settings.openai_api_key),
    )


@app.post("/v1/transcriptions", response_model=TranscriptResponse)
async def create_transcription(audio: UploadFile = File(...)) -> TranscriptResponse:
    path = await persist_upload(audio)
    try:
        return transcriber.transcribe(path)
    finally:
        path.unlink(missing_ok=True)


@app.post("/v1/summaries", response_model=SummaryResponse)
def create_summary(request: SummaryRequest) -> SummaryResponse:
    return summarizer.summarize(request.transcript)


@app.post("/v1/meetings/process", response_model=MeetingResponse)
async def process_meeting(audio: UploadFile = File(...)) -> MeetingResponse:
    path = await persist_upload(audio)
    try:
        transcript = transcriber.transcribe(path)
        if not transcript.transcript:
            raise HTTPException(status_code=422, detail="Whisper produced an empty transcript.")

        summary = summarizer.summarize(transcript.transcript)
        now = datetime.now(UTC)
        meeting = MeetingResponse(
            id=str(uuid4()),
            transcript=transcript.transcript,
            language=transcript.language,
            durationSeconds=transcript.durationSeconds,
            title=summary.title,
            overview=summary.overview,
            keyTopics=summary.keyTopics,
            decisions=summary.decisions,
            actionItems=summary.actionItems,
            followUps=summary.followUps,
            generatedAt=summary.generatedAt,
            createdAt=now,
        )
        store.save(meeting)
        return meeting
    finally:
        path.unlink(missing_ok=True)


@app.get("/v1/meetings", response_model=MeetingListResponse)
def list_meetings(limit: int = 50) -> MeetingListResponse:
    return MeetingListResponse(meetings=store.list(limit=limit))


@app.get("/v1/meetings/{meeting_id}", response_model=MeetingResponse)
def get_meeting(meeting_id: str) -> MeetingResponse:
    meeting = store.get(meeting_id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    return meeting


async def persist_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "meeting.m4a").suffix or ".m4a"
    with NamedTemporaryFile(delete=False, suffix=suffix) as target:
        while chunk := await upload.read(1024 * 1024):
            target.write(chunk)
        return Path(target.name)
