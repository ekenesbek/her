# Her GPU STT Service

Standalone FastAPI service for GPU-backed transcription, diarization, and speaker embeddings. It is intentionally separate from the iOS backend so the main app can keep using the same upload/job API while delegating heavy audio work to a GPU host.

## Run

```bash
cd her-ios/stt-service
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp ../backend/.env.example .env
uvicorn stt_service.main:app --host 0.0.0.0 --port 8000
```

Set these values in `.env` on the GPU host:

```bash
WHISPER_MODEL=large-v3
WHISPER_DEVICE=cuda
WHISPER_COMPUTE_TYPE=float16
HUGGINGFACE_TOKEN=<token>
DIARIZATION_ENABLED=true
DIARIZATION_MIN_SPEAKERS=0
DIARIZATION_MAX_SPEAKERS=0
DIARIZATION_SINGLE_SPEAKER_RETRY_ENABLED=true
```

The main iOS backend can then delegate transcription to this service:

```bash
TRANSCRIPTION_PROVIDER=external
EXTERNAL_TRANSCRIPTION_URL=http://127.0.0.1:8000
```

## Endpoints

- `GET /health`
- `POST /v1/transcribe` with multipart field `audio`, returning the same `TranscriptResponse` shape as the main backend.
- `POST /v1/diarization` with multipart field `audio` and optional `min_speakers` / `max_speakers` form fields.
- `POST /v1/embedding` with multipart field `audio`, using `pyannote/embedding`.
- `POST /v2/embedding` with multipart field `audio`, using `pyannote/wespeaker-voxceleb-resnet34-LM`.

Use `DIARIZATION_MIN_SPEAKERS=0` and `DIARIZATION_MAX_SPEAKERS=0` by default so pyannote auto-detects speaker count. Pin those only for a known meeting format. With `DIARIZATION_SINGLE_SPEAKER_RETRY_ENABLED=true`, long recordings that auto-detect as one speaker get one validation retry with speaker-count hints; the retry is accepted only when it produces multiple durable speakers without losing most speech coverage.
