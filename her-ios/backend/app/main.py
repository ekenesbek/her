import json
import logging
import mimetypes
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse

from app.schemas import (
    AppleSubscriptionTransactionRequest,
    AuthAppleRequest,
    AuthGoogleRequest,
    AuthResponse,
    HealthResponse,
    MeetingChatListResponse,
    MeetingChatRequest,
    MeetingChatResponse,
    MeetingJobResponse,
    MeetingListResponse,
    MeetingResponse,
    MeetingSaveRequest,
    MeetingTitleUpdateRequest,
    MeetingTranscriptUpdateRequest,
    SpeakerAssignmentRequest,
    SpeakerAssignmentResponse,
    SubscriptionPlanUpdateRequest,
    SubscriptionResponse,
    SummaryMode,
    SummaryModeRequest,
    SummaryRequest,
    SummaryResponse,
    TranscriptResponse,
    UserResponse,
    VoiceProfileListResponse,
    VoiceProfileResponse,
)
from app.services.app_store import AppStoreTransactionValidator, AppStoreValidationError
from app.services.auth import (
    AuthError,
    create_session_token,
    decode_session_token,
    verify_apple_id_token,
    verify_google_id_token,
)
from app.services.audio_chunks import audio_duration_seconds as probe_audio_duration_seconds
from app.services.meeting_contents import build_outline_from_segments
from app.services.storage import MeetingStore
from app.services.summarizer import (
    SummaryService,
    SummaryUnavailableError,
    fallback_overview_from_transcript,
    meeting_chat_messages,
)
from app.services.transcription_router import build_transcriber
from app.services.voice_profiles import VoiceEmbedder
from app.settings import get_settings

logger = logging.getLogger(__name__)

settings = get_settings()
transcriber = build_transcriber(settings)
summarizer = SummaryService(settings)
store = MeetingStore(settings.data_dir)
app_store_validator = AppStoreTransactionValidator(settings)
voice_embedder = VoiceEmbedder(settings)
meeting_job_executor = ThreadPoolExecutor(
    max_workers=max(1, settings.meeting_job_workers),
    thread_name_prefix="meeting-job",
)

FREE_RECORDING_LIMIT_SECONDS = 60 * 60
PAID_RECORDING_LIMIT_SECONDS = 1200 * 60


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


def subscription_period(now: datetime | None = None) -> tuple[datetime, datetime]:
    now = now or datetime.now(UTC)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1)
    else:
        end = start.replace(month=start.month + 1)
    return start, end


def normalize_subscription_plan(plan: str | None) -> str:
    return "plus" if plan in {"plus", "paid"} else "free"


def subscription_limit_seconds(plan: str) -> int:
    return PAID_RECORDING_LIMIT_SECONDS if normalize_subscription_plan(plan) == "plus" else FREE_RECORDING_LIMIT_SECONDS


def subscription_response(user_id: str) -> SubscriptionResponse:
    period_start, period_end = subscription_period()
    plan = normalize_subscription_plan(store.get_user_subscription_plan(user_id))
    source = store.get_user_subscription_source(user_id)
    used = int(round(store.recording_usage_seconds(user_id, period_start, period_end)))
    limit = subscription_limit_seconds(plan)
    return SubscriptionResponse(
        plan=plan,
        recordingLimitSeconds=limit,
        recordingUsedSeconds=used,
        recordingRemainingSeconds=max(0, limit - used),
        askAiEnabled=plan == "plus",
        periodStartedAt=period_start,
        periodEndsAt=period_end,
        source=source,
    )


def ensure_recording_quota(user_id: str, requested_seconds: float | None) -> None:
    if requested_seconds is None or requested_seconds <= 0:
        return
    subscription = subscription_response(user_id)
    requested = int(round(requested_seconds))
    if requested <= subscription.recordingRemainingSeconds:
        return
    remaining_minutes = subscription.recordingRemainingSeconds // 60
    plan_minutes = subscription.recordingLimitSeconds // 60
    raise HTTPException(
        status_code=402,
        detail=(
            f"Recording limit reached. Your {subscription.plan} plan includes "
            f"{plan_minutes} minutes per month and has {remaining_minutes} minutes remaining."
        ),
    )


def require_ask_ai(user_id: str) -> None:
    if subscription_response(user_id).askAiEnabled:
        return
    raise HTTPException(
        status_code=402,
        detail="Ask AI is included in the plus plan.",
    )


def chat_generation_runtime() -> tuple[str, str]:
    if settings.llm_configured:
        return settings.openai_summary_model, "llm"
    return "local-fallback", "local_fallback"


def chat_prompt_metrics(prompt_messages: list[dict[str, str]]) -> tuple[int, int]:
    prompt_character_count = sum(len(item.get("content", "")) for item in prompt_messages)
    return len(prompt_messages), prompt_character_count


def chat_run_error_message(exc: Exception) -> str:
    return str(exc).replace("\n", " ").strip()[:500] or exc.__class__.__name__

app = FastAPI(title="Her iOS Backend", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def resume_meeting_jobs() -> None:
    for job_id in store.list_active_meeting_job_ids():
        submit_meeting_job(job_id)


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        version=app.version,
        database=str(store.db_path),
        transcriptionProvider=settings.transcription_provider,
        whisperModel=settings.whisper_model,
        summaryModel=settings.openai_summary_model,
        openaiConfigured=settings.llm_configured,
    )


@app.post("/v1/auth/apple", response_model=AuthResponse)
def auth_apple(payload: AuthAppleRequest) -> AuthResponse:
    try:
        claims = verify_apple_id_token(payload.identityToken, settings.apple_client_id)
    except AuthError as exc:
        raise HTTPException(status_code=401, detail=str(exc))

    provider_user_id = claims["sub"]
    email = payload.email or claims.get("email")
    user, is_new_user = store.find_or_create_user_with_status(
        provider="apple",
        provider_user_id=provider_user_id,
        email=email,
        name=payload.fullName,
    )
    token, expires_at = create_session_token(user.id, settings.auth_jwt_secret)
    return AuthResponse(token=token, expiresAt=expires_at, user=user, isNewUser=is_new_user)


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
    user, is_new_user = store.find_or_create_user_with_status(
        provider="google",
        provider_user_id=provider_user_id,
        email=email,
        name=name,
    )
    token, expires_at = create_session_token(user.id, settings.auth_jwt_secret)
    return AuthResponse(token=token, expiresAt=expires_at, user=user, isNewUser=is_new_user)


@app.get("/v1/auth/me", response_model=UserResponse)
def auth_me(user: UserResponse = Depends(current_user)) -> UserResponse:
    return user


@app.get("/v1/subscription", response_model=SubscriptionResponse)
def get_subscription(user: UserResponse = Depends(current_user)) -> SubscriptionResponse:
    return subscription_response(user.id)


@app.patch("/v1/subscription", response_model=SubscriptionResponse)
def update_subscription(
    payload: SubscriptionPlanUpdateRequest,
    user: UserResponse = Depends(current_user),
) -> SubscriptionResponse:
    if not settings.local_subscription_overrides_enabled:
        raise HTTPException(
            status_code=403,
            detail="Local subscription overrides are disabled. Use StoreKit purchase validation.",
        )
    store.set_user_subscription_plan(user.id, payload.plan)
    return subscription_response(user.id)


@app.post("/v1/subscription/apple-transaction", response_model=SubscriptionResponse)
def validate_apple_subscription_transaction(
    payload: AppleSubscriptionTransactionRequest,
    user: UserResponse = Depends(current_user),
) -> SubscriptionResponse:
    try:
        transaction = app_store_validator.verify_subscription_transaction(payload.signedTransaction)
    except AppStoreValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    store.save_apple_subscription_transaction(
        user_id=user.id,
        transaction_id=transaction.transaction_id,
        original_transaction_id=transaction.original_transaction_id,
        product_id=transaction.product_id,
        environment=transaction.environment,
        purchase_date=transaction.purchase_date,
        expires_date=transaction.expires_date,
        revocation_date=transaction.revocation_date,
        signed_transaction=payload.signedTransaction,
    )
    return subscription_response(user.id)


@app.post("/v1/transcriptions", response_model=TranscriptResponse)
async def create_transcription(
    audio: UploadFile = File(...),
    user: UserResponse = Depends(current_user),
) -> TranscriptResponse:
    path = await persist_upload(audio)
    try:
        ensure_recording_quota(user.id, recording_duration_seconds(path))
        result = transcriber.transcribe(path)
        ensure_recording_quota(user.id, result.durationSeconds)
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

    per_speaker_embeddings = voice_embedder.extract_for_labeled_segments(
        audio_path,
        result.segments,
    ) or voice_embedder.extract_per_speaker(audio_path)
    if not per_speaker_embeddings:
        return result

    threshold = settings.voice_profile_match_threshold
    profile_vectors = [
        (profile, voice_embedder.deserialize(blob))
        for profile, blob in profiles
    ]

    speaker_to_name = _speaker_profile_matches(
        per_speaker_embeddings,
        profile_vectors,
        threshold,
    )

    if not speaker_to_name:
        return result

    new_segments = [
        seg.model_copy(update={"speaker": speaker_to_name.get(seg.speaker, seg.speaker)})
        for seg in result.segments
    ]
    transcript_text = _format_transcript(new_segments)
    return result.model_copy(update={"segments": new_segments, "transcript": transcript_text})


def _speaker_profile_matches(
    per_speaker_embeddings,
    profile_vectors,
    threshold: float,
) -> dict[str, str]:
    candidates: list[tuple[float, str, str]] = []
    if len(profile_vectors) == 1:
        profile, profile_vec = profile_vectors[0]
        scores = [
            (
                voice_embedder.cosine_similarity(embedding, profile_vec),
                speaker_id,
            )
            for speaker_id, embedding in per_speaker_embeddings.items()
        ]
        scores.sort(reverse=True)
        if not scores:
            return {}

        best_score, best_speaker = scores[0]
        next_score = scores[1][0] if len(scores) > 1 else -1.0
        min_score = min(threshold, settings.voice_profile_single_profile_match_threshold)
        min_margin = max(0.0, settings.voice_profile_single_profile_match_margin)
        if best_score >= min_score and best_score - next_score >= min_margin:
            return {best_speaker: profile.name}
        return {}

    for speaker_id, embedding in per_speaker_embeddings.items():
        for profile, profile_vec in profile_vectors:
            score = voice_embedder.cosine_similarity(embedding, profile_vec)
            if score >= threshold:
                candidates.append((score, speaker_id, profile.name))

    speaker_to_name: dict[str, str] = {}
    used_names: set[str] = set()
    for _, speaker_id, profile_name in sorted(candidates, reverse=True):
        if speaker_id in speaker_to_name or profile_name in used_names:
            continue
        speaker_to_name[speaker_id] = profile_name
        used_names.add(profile_name)
    return speaker_to_name


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


@app.post(
    "/v1/meetings/{meeting_id}/speakers/assign",
    response_model=SpeakerAssignmentResponse,
)
def assign_meeting_speaker(
    meeting_id: str,
    payload: SpeakerAssignmentRequest,
    user: UserResponse = Depends(current_user),
) -> SpeakerAssignmentResponse:
    speaker_label = payload.speaker.strip()
    if not speaker_label:
        raise HTTPException(status_code=422, detail="Speaker label is required.")

    requested_name = (payload.name or "").strip()
    profile_with_embedding = None
    if payload.profileId:
        profile_with_embedding = store.get_voice_profile_embedding(user.id, payload.profileId)
        if profile_with_embedding is None:
            raise HTTPException(status_code=404, detail="Voice profile not found.")
    elif requested_name:
        profile_with_embedding = store.find_voice_profile_by_name(user.id, requested_name)
    else:
        raise HTTPException(status_code=422, detail="Voice profile name is required.")

    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    if not meeting.segments:
        raise HTTPException(status_code=422, detail="Meeting has no speaker segments.")

    matching_segments = [
        segment for segment in meeting.segments if _same_speaker(segment.speaker, speaker_label)
    ]
    if not matching_segments:
        raise HTTPException(status_code=404, detail="Speaker was not found in this meeting.")

    audio_info = store.get_meeting_audio(meeting_id, user.id)
    if audio_info is None:
        raise HTTPException(status_code=409, detail="Meeting audio is not available.")
    audio_path, _ = audio_info
    if not audio_path.exists():
        raise HTTPException(status_code=409, detail="Meeting audio file is missing.")

    embeddings = voice_embedder.extract_for_labeled_segments(audio_path, matching_segments)
    embedding = embeddings.get(speaker_label) if embeddings else None
    if embedding is None and embeddings:
        embedding = next(iter(embeddings.values()))
    if embedding is None:
        raise HTTPException(status_code=503, detail="Voice embedding is unavailable.")

    sample_duration = _segments_duration_seconds(matching_segments)
    serialized_embedding = voice_embedder.serialize(embedding)
    if profile_with_embedding is None:
        profile = store.save_voice_profile(
            user_id=user.id,
            name=requested_name,
            duration_seconds=sample_duration,
            embedding=serialized_embedding,
            meeting_id=meeting_id,
            speaker_label=speaker_label,
        )
    else:
        existing_profile, existing_embedding = profile_with_embedding
        updated_embedding = voice_embedder.average_embeddings(
            voice_embedder.deserialize(existing_embedding),
            existing_profile.sampleCount,
            embedding,
        )
        profile = store.add_voice_profile_sample(
            user_id=user.id,
            profile_id=existing_profile.id,
            duration_seconds=sample_duration,
            embedding=serialized_embedding,
            updated_embedding=voice_embedder.serialize(updated_embedding),
            meeting_id=meeting_id,
            speaker_label=speaker_label,
        )
        if profile is None:
            raise HTTPException(status_code=404, detail="Voice profile not found.")

    updated_segments = [
        segment.model_copy(update={"speaker": profile.name})
        if _same_speaker(segment.speaker, speaker_label)
        else segment
        for segment in meeting.segments
    ]
    updated_transcript = _format_transcript(updated_segments)
    updated_meeting = store.update_meeting_transcript(
        meeting_id,
        user.id,
        updated_transcript,
        updated_segments,
    )
    if updated_meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")

    return SpeakerAssignmentResponse(
        profile=profile,
        meeting=updated_meeting,
        assignedSegments=len(matching_segments),
        sampleDurationSeconds=sample_duration,
    )


def _same_speaker(left: str | None, right: str | None) -> bool:
    return (left or "").strip() == (right or "").strip()


def _segments_duration_seconds(segments: list) -> float | None:
    total = sum(max(0.0, float(segment.end) - float(segment.start)) for segment in segments)
    return total if total > 0 else None


def _audio_duration_seconds(path: Path) -> float | None:
    probed_duration = probe_audio_duration_seconds(path)
    if probed_duration is not None:
        return probed_duration
    try:
        import wave

        with wave.open(str(path), "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            return frames / float(rate) if rate else None
    except Exception:  # noqa: BLE001
        return None


def recording_duration_seconds(path: Path) -> float | None:
    return _audio_duration_seconds(path)


@app.post("/v1/summaries", response_model=SummaryResponse)
def create_summary(
    request: SummaryRequest,
    _: UserResponse = Depends(current_user),
) -> SummaryResponse:
    try:
        return summarizer.summarize(
            request.transcript,
            mode=request.summaryMode,
            language=request.language,
        )
    except SummaryUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Summary generation failed")
        raise HTTPException(status_code=503, detail="AI summary is unavailable.") from exc


@app.post("/v1/meetings/process", response_model=MeetingResponse)
async def process_meeting(
    audio: UploadFile = File(...),
    source: str | None = Form(default=None),
    device_name: str | None = Form(default=None),
    location_name: str | None = Form(default=None),
    summary_mode: SummaryMode = Form(default="reasoning"),
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    path = await persist_upload(audio)
    audio_stored = False
    try:
        ensure_recording_quota(user.id, recording_duration_seconds(path))
        transcript = transcriber.transcribe(path)
        transcript = relabel_transcript(transcript, user.id, audio_path=path)
        if not transcript.transcript:
            raise HTTPException(status_code=422, detail="Whisper produced an empty transcript.")
        ensure_recording_quota(user.id, transcript.durationSeconds)

        summary = summarize_or_make_unavailable(
            user.id,
            transcript.transcript,
            transcript.segments,
            transcript.language,
            location_name,
            summary_mode,
        )
        now = datetime.now(UTC)
        meeting = MeetingResponse(
            id=str(uuid4()),
            transcript=transcript.transcript,
            segments=transcript.segments,
            language=transcript.language,
            durationSeconds=transcript.durationSeconds,
            source=source,
            deviceName=device_name,
            locationName=location_name,
            title=summary.title,
            overview=summary.overview,
            keyTopics=summary.keyTopics,
            decisions=summary.decisions,
            actionItems=summary.actionItems,
            followUps=summary.followUps,
            outline=summary.outline,
            generatedAt=summary.generatedAt,
            summaryStatus=summary.summaryStatus,
            summaryMode=summary.summaryMode,
            createdAt=now,
        )
        store.save(meeting, user_id=user.id)
        stored_audio_path = persist_meeting_audio(path, user.id, meeting.id, location_name)
        audio_stored = True
        content_type = mimetypes.guess_type(stored_audio_path.name)[0] or audio.content_type
        store.attach_meeting_audio(meeting.id, user.id, stored_audio_path, content_type)
        stored_meeting = store.get(meeting.id, user_id=user.id)
        return stored_meeting or meeting.model_copy(update={"hasAudio": True})
    finally:
        if not audio_stored:
            path.unlink(missing_ok=True)


@app.post("/v1/meetings/jobs", response_model=MeetingJobResponse, status_code=202)
async def create_meeting_job(
    audio: UploadFile = File(...),
    source: str | None = Form(default=None),
    device_name: str | None = Form(default=None),
    location_name: str | None = Form(default=None),
    summary_mode: SummaryMode = Form(default="reasoning"),
    generate_summary: bool = Form(default=True),
    user: UserResponse = Depends(current_user),
) -> MeetingJobResponse:
    path = await persist_job_upload(audio)
    try:
        ensure_recording_quota(user.id, recording_duration_seconds(path))
    except Exception:
        path.unlink(missing_ok=True)
        raise
    job = store.create_meeting_job(
        user.id,
        path,
        source=source,
        device_name=device_name,
        location_name=location_name,
        summary_mode=summary_mode,
        generate_summary=generate_summary,
    )
    submit_meeting_job(job.id)
    return job


@app.get("/v1/meetings/jobs/{job_id}", response_model=MeetingJobResponse)
def get_meeting_job(
    job_id: str,
    user: UserResponse = Depends(current_user),
) -> MeetingJobResponse:
    job = store.get_meeting_job(job_id, user_id=user.id)
    if job is None:
        raise HTTPException(status_code=404, detail="Meeting job not found.")
    return job


@app.post("/v1/meetings", response_model=MeetingResponse)
def save_meeting(
    payload: MeetingSaveRequest,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    ensure_recording_quota(user.id, payload.durationSeconds)
    now = datetime.now(UTC)
    meeting = MeetingResponse(
        id=str(uuid4()),
        createdAt=now,
        **payload.model_dump(),
    )
    store.save(meeting, user_id=user.id)
    return store.get(meeting.id, user_id=user.id) or meeting


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


@app.patch("/v1/meetings/{meeting_id}", response_model=MeetingResponse)
def update_meeting_title(
    meeting_id: str,
    payload: MeetingTitleUpdateRequest,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    title = payload.title.strip()
    if not title:
        raise HTTPException(status_code=422, detail="Meeting title cannot be empty.")
    updated = store.update_meeting_title(meeting_id, user.id, title)
    if updated is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    return updated


@app.delete("/v1/meetings/{meeting_id}", status_code=204)
def delete_meeting(
    meeting_id: str,
    user: UserResponse = Depends(current_user),
) -> Response:
    deleted, audio_path = store.delete_meeting(meeting_id, user.id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    if audio_path is not None:
        audio_path.unlink(missing_ok=True)
    return Response(status_code=204)


@app.patch("/v1/meetings/{meeting_id}/transcript", response_model=MeetingResponse)
def update_meeting_transcript(
    meeting_id: str,
    payload: MeetingTranscriptUpdateRequest,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    updated = store.update_meeting_transcript(
        meeting_id,
        user.id,
        payload.transcript,
        payload.segments,
    )
    if updated is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    return updated


@app.get("/v1/meetings/{meeting_id}/audio")
def download_meeting_audio(
    meeting_id: str,
    user: UserResponse = Depends(current_user),
) -> FileResponse:
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    audio = store.get_meeting_audio(meeting_id, user.id)
    if audio is None:
        raise HTTPException(status_code=404, detail="Meeting audio not found.")

    audio_path, content_type = audio
    if not audio_path.exists():
        raise HTTPException(status_code=404, detail="Meeting audio file is missing.")

    media_type = content_type or mimetypes.guess_type(audio_path.name)[0] or "application/octet-stream"
    return FileResponse(
        path=audio_path,
        media_type=media_type,
        filename=audio_path.name,
    )


@app.post("/v1/meetings/{meeting_id}/summary", response_model=MeetingResponse)
def generate_meeting_summary(
    meeting_id: str,
    payload: SummaryModeRequest | None = None,
    user: UserResponse = Depends(current_user),
) -> MeetingResponse:
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    try:
        summary = summarizer.summarize(
            meeting.transcript,
            meeting.segments,
            mode=payload.summaryMode if payload else "reasoning",
            language=meeting.language,
        )
    except SummaryUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Meeting summary generation failed for meeting %s", meeting_id)
        raise HTTPException(status_code=503, detail="AI summary is unavailable.") from exc
    updated = store.update_meeting_summary(meeting_id, user.id, summary)
    if updated is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    return updated


@app.get("/v1/meetings/{meeting_id}/chat", response_model=MeetingChatListResponse)
def list_meeting_chat(
    meeting_id: str,
    user: UserResponse = Depends(current_user),
) -> MeetingChatListResponse:
    require_ask_ai(user.id)
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    thread = store.get_or_create_chat_thread(meeting_id, user.id)
    return MeetingChatListResponse(
        thread=thread,
        messages=store.list_chat_messages(meeting_id, user.id),
    )


@app.post("/v1/meetings/{meeting_id}/chat", response_model=MeetingChatResponse)
def chat_with_meeting(
    meeting_id: str,
    payload: MeetingChatRequest,
    user: UserResponse = Depends(current_user),
) -> MeetingChatResponse:
    require_ask_ai(user.id)
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    question = payload.question.strip()
    if not question:
        raise HTTPException(status_code=422, detail="Question is required.")
    history = store.list_chat_messages(meeting_id, user.id)
    prompt_messages = meeting_chat_messages(meeting, question, history)
    model, source = chat_generation_runtime()
    prompt_message_count, prompt_character_count = chat_prompt_metrics(prompt_messages)
    run = store.create_chat_run(
        meeting_id,
        user.id,
        model=model,
        source=source,
        prompt_message_count=prompt_message_count,
        prompt_character_count=prompt_character_count,
    )
    user_message = store.append_chat_message(
        meeting_id,
        user.id,
        "user",
        question,
        run_id=run.id,
    )
    try:
        response = summarizer.answer_question(meeting, question, history)
        assistant_message = store.append_chat_message(
            meeting_id,
            user.id,
            "assistant",
            response.answer,
            run_id=run.id,
        )
        store.complete_chat_run(run.id, response_message_id=assistant_message.id)
        return response.model_copy(
            update={
                "threadId": user_message.threadId,
                "runId": run.id,
                "messageId": assistant_message.id,
                "model": model,
            }
        )
    except Exception as exc:  # noqa: BLE001
        store.fail_chat_run(run.id, chat_run_error_message(exc))
        raise


@app.post("/v1/meetings/{meeting_id}/chat/stream")
def stream_chat_with_meeting(
    meeting_id: str,
    payload: MeetingChatRequest,
    user: UserResponse = Depends(current_user),
) -> StreamingResponse:
    require_ask_ai(user.id)
    meeting = store.get(meeting_id, user_id=user.id)
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found.")
    question = payload.question.strip()
    if not question:
        raise HTTPException(status_code=422, detail="Question is required.")
    history = store.list_chat_messages(meeting_id, user.id)
    prompt_messages = meeting_chat_messages(meeting, question, history)
    model, source = chat_generation_runtime()
    prompt_message_count, prompt_character_count = chat_prompt_metrics(prompt_messages)
    run = store.create_chat_run(
        meeting_id,
        user.id,
        model=model,
        source=source,
        prompt_message_count=prompt_message_count,
        prompt_character_count=prompt_character_count,
    )
    store.append_chat_message(meeting_id, user.id, "user", question, run_id=run.id)

    def events():
        answer_parts: list[str] = []
        try:
            for delta in summarizer.stream_answer_question(meeting, question, history):
                if delta:
                    answer_parts.append(delta)
                    yield f"data: {json.dumps({'delta': delta}, ensure_ascii=False)}\n\n"
            answer = "".join(answer_parts).strip()
            if answer:
                assistant_message = store.append_chat_message(
                    meeting_id,
                    user.id,
                    "assistant",
                    answer,
                    run_id=run.id,
                )
                store.complete_chat_run(run.id, response_message_id=assistant_message.id)
            else:
                store.complete_chat_run(run.id)
            yield "event: done\ndata: {}\n\n"
        except Exception as exc:  # noqa: BLE001
            store.fail_chat_run(run.id, chat_run_error_message(exc))
            logger.exception("Meeting chat stream failed for meeting %s", meeting_id)
            payload_json = json.dumps({"error": "Chat stream failed."})
            yield f"event: error\ndata: {payload_json}\n\n"

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


def submit_meeting_job(job_id: str) -> None:
    meeting_job_executor.submit(run_meeting_job, job_id)


def run_meeting_job(job_id: str) -> None:
    job = store.get_meeting_job_payload(job_id)
    if job is None:
        return
    if job["status"] == "completed":
        return

    audio_path = Path(job["audio_path"])
    audio_stored = False
    store.update_meeting_job(job_id, status="processing")
    try:
        summary_mode = job.get("summary_mode", "reasoning")
        meeting = None
        if job.get("meeting_id"):
            meeting = store.get(job["meeting_id"], user_id=job["user_id"])

        if meeting is None:
            if not audio_path.exists():
                raise RuntimeError("Uploaded audio file is missing.")

            transcript = transcriber.transcribe(audio_path)
            transcript = relabel_transcript(transcript, job["user_id"], audio_path=audio_path)
            if not transcript.transcript:
                raise RuntimeError("Whisper produced an empty transcript.")
            ensure_recording_quota(job["user_id"], transcript.durationSeconds)

            summary = make_unavailable_summary(
                job["user_id"],
                transcript.transcript,
                transcript.segments,
                job.get("location_name"),
                summary_mode,
            )
            now = datetime.now(UTC)
            meeting = MeetingResponse(
                id=str(uuid4()),
                transcript=transcript.transcript,
                segments=transcript.segments,
                language=transcript.language,
                durationSeconds=transcript.durationSeconds,
                source=job.get("source"),
                deviceName=job.get("device_name"),
                locationName=job.get("location_name"),
                title=summary.title,
                overview=summary.overview,
                keyTopics=summary.keyTopics,
                decisions=summary.decisions,
                actionItems=summary.actionItems,
                followUps=summary.followUps,
                outline=summary.outline,
                generatedAt=summary.generatedAt,
                summaryStatus=summary.summaryStatus,
                summaryMode=summary.summaryMode,
                createdAt=now,
            )
            store.save(meeting, user_id=job["user_id"])
            stored_audio_path = persist_meeting_audio(audio_path, job["user_id"], meeting.id, job.get("location_name"))
            audio_stored = True
            content_type = mimetypes.guess_type(stored_audio_path.name)[0]
            store.attach_meeting_audio(meeting.id, job["user_id"], stored_audio_path, content_type)
            store.update_meeting_job(job_id, status="processing", meeting_id=meeting.id)
        else:
            audio_stored = True

        if bool(job.get("generate_summary", True)):
            summary = summarize_or_make_unavailable(
                job["user_id"],
                meeting.transcript,
                meeting.segments,
                meeting.language,
                job.get("location_name"),
                summary_mode,
            )
        else:
            summary = make_unavailable_summary(
                job["user_id"],
                meeting.transcript,
                meeting.segments,
                job.get("location_name"),
                summary_mode,
            )
        store.update_meeting_summary(meeting.id, job["user_id"], summary)
        store.update_meeting_job(job_id, status="completed", meeting_id=meeting.id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Meeting job %s failed", job_id)
        store.update_meeting_job(job_id, status="failed", error=str(exc))
    finally:
        if not audio_stored:
            audio_path.unlink(missing_ok=True)


async def persist_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "meeting.m4a").suffix or ".m4a"
    with NamedTemporaryFile(delete=False, suffix=suffix) as target:
        while chunk := await upload.read(1024 * 1024):
            target.write(chunk)
        return Path(target.name)


async def persist_job_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "meeting.m4a").suffix or ".m4a"
    upload_dir = settings.data_dir / "meeting-job-uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)
    path = upload_dir / f"{uuid4()}{suffix}"
    with path.open("wb") as target:
        while chunk := await upload.read(1024 * 1024):
            target.write(chunk)
    return path


def persist_meeting_audio(
    audio_path: Path,
    user_id: str,
    meeting_id: str,
    location_name: str | None = None,
) -> Path:
    suffix = audio_path.suffix or ".m4a"
    audio_dir = settings.data_dir / "meeting-audio" / user_id / location_bucket(location_name)
    audio_dir.mkdir(parents=True, exist_ok=True)
    destination = audio_dir / f"{meeting_id}{suffix}"
    if audio_path.resolve() == destination.resolve():
        return destination
    audio_path.replace(destination)
    return destination


def location_bucket(location_name: str | None) -> str:
    clean_location = (location_name or "").strip()
    if not clean_location or clean_location.lower() == "location unavailable":
        return "unknown-location"

    bucket = []
    last_was_separator = False
    for character in clean_location:
        if character.isalnum():
            bucket.append(character)
            last_was_separator = False
        elif not last_was_separator:
            bucket.append("-")
            last_was_separator = True

    value = "".join(bucket).strip("-")
    return (value or "unknown-location")[:80]


def summarize_or_make_unavailable(
    user_id: str,
    transcript: str,
    segments,
    language: str | None,
    location_name: str | None,
    summary_mode: SummaryMode = "reasoning",
) -> SummaryResponse:
    try:
        return summarizer.summarize(
            transcript,
            segments,
            mode=summary_mode,
            language=language,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("AI summary unavailable; saving meeting without summary: %s", exc)
        return make_unavailable_summary(user_id, transcript, segments, location_name, summary_mode)


def make_unavailable_summary(
    user_id: str,
    transcript: str,
    segments,
    location_name: str | None,
    summary_mode: SummaryMode = "reasoning",
) -> SummaryResponse:
    title = store.next_meeting_title(user_id, fallback_meeting_title(location_name))
    overview = fallback_overview_from_transcript(transcript)
    return SummaryResponse(
        title=title,
        overview=overview or title,
        keyTopics=[],
        decisions=[],
        actionItems=[],
        followUps=[],
        outline=build_outline_from_segments(transcript, segments),
        generatedAt=datetime.now(UTC),
        summaryStatus="unavailable",
        summaryMode=summary_mode,
    )


def fallback_meeting_title(location_name: str | None) -> str:
    clean_location = (location_name or "").strip()
    if clean_location and clean_location.lower() != "location unavailable":
        return clean_location
    return "Recording"
