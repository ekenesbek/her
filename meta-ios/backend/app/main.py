from datetime import UTC, datetime
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from app.schemas import (
    AuthAppleRequest,
    AuthGoogleRequest,
    AuthResponse,
    HealthResponse,
    MeetingListResponse,
    MeetingResponse,
    MeetingSaveRequest,
    SummaryRequest,
    SummaryResponse,
    TranscriptResponse,
    UserResponse,
    VoiceProfileListResponse,
    VoiceProfileResponse,
)
from app.services.auth import (
    AuthError,
    create_session_token,
    decode_session_token,
    verify_apple_id_token,
    verify_google_id_token,
)
from app.services.diarizer import WhisperXTranscriber
from app.services.storage import MeetingStore
from app.services.summarizer import SummaryService
from app.services.transcriber import WhisperTranscriber
from app.services.voice_profiles import VoiceEmbedder
from app.settings import get_settings

settings = get_settings()
transcriber: object = WhisperXTranscriber(settings) if settings.diarization_enabled else WhisperTranscriber(settings)
summarizer = SummaryService(settings)
store = MeetingStore(settings.data_dir)
voice_embedder = VoiceEmbedder(settings)


def current_user(authorization: str | None = Header(default=None)) -> UserResponse:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        payload = decode_session_token(token, settings.auth_jwt_secret)
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc))

    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=401, detail="Session token missing subject.")
    user = store.get_user(user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="User no longer exists.")
    return user

app = FastAPI(title="Meta iOS Backend", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


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


@app.post("/v1/auth/apple", response_model=AuthResponse)
def auth_apple(payload: AuthAppleRequest) -> AuthResponse:
    try:
        claims = verify_apple_id_token(payload.identityToken, settings.apple_client_id)
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc))

    provider_user_id = claims["sub"]
    email = payload.email or claims.get("email")
    user = store.find_or_create_user(
        provider="apple",
        provider_user_id=provider_user_id,
        email=email,
        name=payload.fullName,
    )
    token, expires_at = create_session_token(user.id, settings.auth_jwt_secret)
    return AuthResponse(token=token, expiresAt=expires_at, user=user)


@app.post("/v1/auth/google", response_model=AuthResponse)
def auth_google(payload: AuthGoogleRequest) -> AuthResponse:
    audiences = settings.google_client_id_list
    if not audiences:
        raise HTTPException(
            status_code=503,
            detail="Google sign-in is not configured (GOOGLE_CLIENT_IDS unset).",
        )
    try:
        claims = verify_google_id_token(payload.idToken, audiences)
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc))

    provider_user_id = claims["sub"]
    email = claims.get("email")
    name = claims.get("name") or claims.get("given_name")
    user = store.find_or_create_user(
        provider="google",
        provider_user_id=provider_user_id,
        email=email,
        name=name,
    )
    token, expires_at = create_session_token(user.id, settings.auth_jwt_secret)
    return AuthResponse(token=token, expiresAt=expires_at, user=user)


@app.get("/v1/auth/me", response_model=UserResponse)
def auth_me(user: UserResponse = Depends(current_user)) -> UserResponse:
    return user


@app.post("/v1/transcriptions", response_model=TranscriptResponse)
async def create_transcription(
    audio: UploadFile = File(...),
    user: UserResponse = Depends(current_user),
) -> TranscriptResponse:
    path = await persist_upload(audio)
    try:
        result = transcriber.transcribe(path)
        return relabel_transcript(result, user.id, audio_path=path)
    finally:
        path.unlink(missing_ok=True)


def relabel_transcript(
    result: TranscriptResponse,
    user_id: str,
    audio_path: Path,
) -> TranscriptResponse:
    """Replace 'SPEAKER_00' / 'SPEAKER_01' with enrolled voice profile names where possible."""
    if not result.segments:
        return result

    profiles = store.list_voice_profile_embeddings(user_id)
    if not profiles:
        return result

    speakers = {seg.speaker for seg in result.segments if seg.speaker}
    if not speakers:
        return result

    import numpy as np

    per_speaker_embeddings = voice_embedder.extract_per_speaker(audio_path)
    if not per_speaker_embeddings:
        return result

    threshold = settings.voice_profile_match_threshold
    profile_vectors = [
        (profile, voice_embedder.deserialize(blob))
        for profile, blob in profiles
    ]

    speaker_to_name: dict[str, str] = {}
    for speaker_id, embedding in per_speaker_embeddings.items():
        best_score = -1.0
        best_name: str | None = None
        for profile, profile_vec in profile_vectors:
            score = voice_embedder.cosine_similarity(embedding, profile_vec)
            if score > best_score:
                best_score = score
                best_name = profile.name
        if best_name and best_score >= threshold:
            speaker_to_name[speaker_id] = best_name

    if not speaker_to_name:
        return result

    new_segments = [
        seg.model_copy(update={"speaker": speaker_to_name.get(seg.speaker, seg.speaker)})
        for seg in result.segments
    ]
    transcript_text = _format_transcript(new_segments)
    return result.model_copy(update={"segments": new_segments, "transcript": transcript_text})


def _format_transcript(segments: list) -> str:
    if not segments:
        return ""
    lines: list[str] = []
    last_speaker = None
    buffer: list[str] = []
    for segment in segments:
        speaker = segment.speaker or "Speaker"
        if speaker != last_speaker:
            if buffer:
                lines.append(f"{last_speaker}: " + " ".join(buffer))
                buffer = []
            last_speaker = speaker
        buffer.append(segment.text)
    if buffer:
        lines.append(f"{last_speaker}: " + " ".join(buffer))
    return "\n".join(lines)


@app.post("/v1/voice-profiles", response_model=VoiceProfileResponse)
async def create_voice_profile(
    audio: UploadFile = File(...),
    name: str = Form(...),
    user: UserResponse = Depends(current_user),
) -> VoiceProfileResponse:
    if not name.strip():
        raise HTTPException(status_code=422, detail="Voice profile name is required.")
    path = await persist_upload(audio)
    try:
        embedding = voice_embedder.extract_full_audio(path)
        if embedding is None:
            raise HTTPException(
                status_code=503,
                detail="Voice embedding service is not configured (check HUGGINGFACE_TOKEN).",
            )
        duration = _audio_duration_seconds(path)
        return store.save_voice_profile(
            user_id=user.id,
            name=name.strip(),
            duration_seconds=duration,
            embedding=voice_embedder.serialize(embedding),
        )
    finally:
        path.unlink(missing_ok=True)


@app.get("/v1/voice-profiles", response_model=VoiceProfileListResponse)
def list_voice_profiles(
    user: UserResponse = Depends(current_user),
) -> VoiceProfileListResponse:
    return VoiceProfileListResponse(profiles=store.list_voice_profiles(user.id))


@app.delete("/v1/voice-profiles/{profile_id}")
def delete_voice_profile(
    profile_id: str,
    user: UserResponse = Depends(current_user),
):
    if not store.delete_voice_profile(user.id, profile_id):
        raise HTTPException(status_code=404, detail="Voice profile not found.")
    return {"deleted": profile_id}


def _audio_duration_seconds(path: Path) -> float | None:
    try:
        import wave

        with wave.open(str(path), "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            return frames / float(rate) if rate else None
    except Exception:  # noqa: BLE001
        return None


@app.post("/v1/summaries", response_model=SummaryResponse)
def create_summary(
    request: SummaryRequest,
    _: UserResponse = Depends(current_user),
) -> SummaryResponse:
    return summarizer.summarize(request.transcript)


@app.post("/v1/meetings/process", response_model=MeetingResponse)
async def process_meeting(
    audio: UploadFile = File(...),
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    path = await persist_upload(audio)
    try:
        transcript = transcriber.transcribe(path)
        transcript = relabel_transcript(transcript, user.id, audio_path=path)
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
        store.save(meeting, user_id=user.id)
        return meeting
    finally:
        path.unlink(missing_ok=True)


@app.post("/v1/meetings", response_model=MeetingResponse)
def save_meeting(
    payload: MeetingSaveRequest,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    now = datetime.now(UTC)
    meeting = MeetingResponse(
        id=str(uuid4()),
        createdAt=now,
        **payload.model_dump(),
    )
    store.save(meeting, user_id=user.id)
    return meeting


@app.get("/v1/meetings", response_model=MeetingListResponse)
def list_meetings(
    limit: int = 50,
    user: UserResponse = Depends(current_user),
) -> MeetingListResponse:
    return MeetingListResponse(meetings=store.list(user_id=user.id, limit=limit))


@app.get("/v1/meetings/{meeting_id}", response_model=MeetingResponse)
def get_meeting(
    meeting_id: str,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    return meeting


async def persist_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "meeting.m4a").suffix or ".m4a"
    with NamedTemporaryFile(delete=False, suffix=suffix) as target:
        while chunk := await upload.read(1024 * 1024):
            target.write(chunk)
        return Path(target.name)
