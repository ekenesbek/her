from __future__ import annotations

import os
import sys
from functools import lru_cache
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

_DEFAULT_BACKEND_PATH = Path(__file__).resolve().parents[2] / "backend"
_BACKEND_PATH = Path(os.getenv("HER_BACKEND_PATH", str(_DEFAULT_BACKEND_PATH))).resolve()
if str(_BACKEND_PATH) not in sys.path:
    sys.path.insert(0, str(_BACKEND_PATH))

from app.schemas import TranscriptResponse  # noqa: E402
from app.services.diarizer import WhisperXTranscriber  # noqa: E402
from app.settings import Settings  # noqa: E402

app = FastAPI(title="Her GPU STT Service", version="0.1.0")


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    settings.diarization_enabled = True
    return settings


@lru_cache
def get_transcriber() -> WhisperXTranscriber:
    return WhisperXTranscriber(get_settings())


@app.get("/health")
def health() -> dict[str, Any]:
    settings = get_settings()
    return {
        "status": "ok",
        "version": app.version,
        "backendPath": str(_BACKEND_PATH),
        "whisperModel": settings.whisper_model,
        "whisperDevice": settings.whisper_device,
        "diarizationEnabled": settings.diarization_enabled,
        "diarizationMinSpeakers": settings.diarization_min_speakers,
        "diarizationMaxSpeakers": settings.diarization_max_speakers,
        "singleSpeakerRetryEnabled": settings.diarization_single_speaker_retry_enabled,
        "huggingFaceConfigured": bool(settings.huggingface_token),
    }


@app.post("/v1/transcribe", response_model=TranscriptResponse)
async def transcribe(audio: UploadFile = File(...)) -> TranscriptResponse:
    path = await _persist_upload(audio)
    try:
        result = get_transcriber().transcribe(path)
        if not result.transcript:
            raise HTTPException(status_code=422, detail="Transcription produced an empty result.")
        return result
    finally:
        path.unlink(missing_ok=True)


@app.post("/v1/diarization")
async def diarization(
    audio: UploadFile = File(...),
    min_speakers: int = Form(default=0),
    max_speakers: int = Form(default=0),
) -> dict[str, Any]:
    settings = get_settings()
    if not settings.huggingface_token:
        raise HTTPException(status_code=503, detail="HUGGINGFACE_TOKEN is required.")

    path = await _persist_upload(audio)
    try:
        pipeline = _diarization_pipeline()
        kwargs: dict[str, int] = {}
        if min_speakers > 0:
            kwargs["min_speakers"] = min_speakers
        if max_speakers > 0:
            kwargs["max_speakers"] = max_speakers
        annotation = pipeline(str(path), **kwargs)
        return {"segments": _annotation_segments(annotation)}
    finally:
        path.unlink(missing_ok=True)


@app.post("/v1/embedding")
async def embedding(audio: UploadFile = File(...)) -> dict[str, Any]:
    return await _embedding_response(audio, model_version="v1")


@app.post("/v2/embedding")
async def embedding_v2(audio: UploadFile = File(...)) -> dict[str, Any]:
    return await _embedding_response(audio, model_version="v2")


async def _embedding_response(audio: UploadFile, model_version: str) -> dict[str, Any]:
    settings = get_settings()
    if not settings.huggingface_token:
        raise HTTPException(status_code=503, detail="HUGGINGFACE_TOKEN is required.")

    path = await _persist_upload(audio)
    try:
        inference = _embedding_inference(model_version)
        raw_embedding = inference(str(path))
        vector = _vector(raw_embedding)
        return {
            "modelVersion": model_version,
            "dimension": len(vector),
            "embedding": vector,
        }
    finally:
        path.unlink(missing_ok=True)


@lru_cache
def _diarization_pipeline():
    from pyannote.audio import Pipeline

    settings = get_settings()
    model_name = os.getenv("DIARIZATION_MODEL", "pyannote/speaker-diarization-community-1")
    try:
        pipeline = Pipeline.from_pretrained(model_name, token=settings.huggingface_token)
    except TypeError:
        pipeline = Pipeline.from_pretrained(model_name, use_auth_token=settings.huggingface_token)
    _move_to_cuda_if_available(pipeline)
    return pipeline


@lru_cache
def _embedding_inference(model_version: str):
    from pyannote.audio import Inference

    settings = get_settings()
    model_name = (
        os.getenv("SPEAKER_EMBEDDING_MODEL_V2", "pyannote/wespeaker-voxceleb-resnet34-LM")
        if model_version == "v2"
        else os.getenv("SPEAKER_EMBEDDING_MODEL", "pyannote/embedding")
    )
    try:
        inference = Inference(model_name, window="whole", token=settings.huggingface_token)
    except TypeError:
        inference = Inference(
            model_name,
            window="whole",
            use_auth_token=settings.huggingface_token,
        )
    _move_to_cuda_if_available(inference)
    return inference


def _move_to_cuda_if_available(model: Any) -> None:
    try:
        import torch

        if torch.cuda.is_available() and hasattr(model, "to"):
            model.to(torch.device("cuda"))
    except Exception:  # noqa: BLE001
        return


def _annotation_segments(annotation: Any) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        segments.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": str(speaker),
            }
        )
    return segments


def _vector(raw_embedding: Any) -> list[float]:
    import numpy as np

    array = np.asarray(raw_embedding, dtype=float)
    if array.ndim > 1:
        array = array.mean(axis=0)
    return [float(value) for value in array.reshape(-1)]


async def _persist_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "audio.wav").suffix or ".wav"
    with NamedTemporaryFile(delete=False, suffix=suffix) as target:
        while chunk := await upload.read(1024 * 1024):
            target.write(chunk)
        return Path(target.name)
