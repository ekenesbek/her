# Her iOS Backend

Local API for the iOS app. It receives meeting audio, transcribes it with local Whisper, summarizes the transcript with an OpenAI-compatible chat endpoint when an OpenAI/Alem key is configured, and persists meetings in SQLite.

## Run

```bash
cd her-ios/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8787 --reload
```

For a physical iPhone, keep the phone and Mac on the same network and set the iOS `BackendAPIURL` to the Mac hostname, for example:

```text
http://Yerasyls-MacBook-Pro.local:8787
```

The default summary/chat model is `gpt-oss`. Set `ALEM_OSS_API_KEY` for the platform-managed Alem OSS provider, or set `OPENAI_API_KEY`, `OPENAI_BASE_URL`, and `OPENAI_SUMMARY_MODEL` in `.env` to use another OpenAI-compatible provider.

## Endpoints

- `GET /health`
- `POST /v1/transcriptions` with multipart field `audio`
- `POST /v1/summaries` with JSON `{ "transcript": "..." }`
- `POST /v1/meetings/process` with multipart field `audio`
- `POST /v1/meetings/jobs` with multipart field `audio`
- `GET /v1/meetings/jobs/{job_id}`
- `GET /v1/meetings`
- `GET /v1/meetings/{id}`
- `GET /v1/meetings/{id}/audio`
- `POST /v1/meetings/{id}/summary`
- `GET /v1/meetings/{id}/chat`
- `POST /v1/meetings/{id}/chat` with JSON `{ "question": "..." }`
- `POST /v1/meetings/{id}/chat/stream` with JSON `{ "question": "..." }`, returning SSE `data: {"delta": "..."}`

## Database

The backend stores data in `DATA_DIR/meetings.sqlite3` with normalized tables:

- `meetings`: transcript, title, overview, language, duration, source/device/location metadata, and the backend path to original meeting audio when available.
- `meetings.outline_json`: chronological contents outline generated from timestamped transcript segments.
- `meetings.segments_json`: timestamped transcript segments with optional speaker labels.
- `meeting_chat_messages`: ordered per-meeting chat turns for the meeting Q&A thread.
- `summary_items`: decisions, action items, and follow-ups linked to a meeting.

Older JSON-blob databases are migrated automatically on startup.

## Notes

`faster-whisper` runs locally and downloads the configured model on first use. `turbo` is the practical free default for this MVP because it is close to `large-v3` quality while being much faster. Use `base` or `small` for weaker CPU-only machines, and `large-v3` when quality matters more than speed.

For the current platform-managed Alem OSS summary/chat model, keep secrets in `.env`:

```bash
ALEM_OSS_API_KEY=<your key>
ALEM_OSS_BASE_URL=https://llm.alem.ai/v1
OPENAI_SUMMARY_MODEL=gpt-oss
```

`POST /v1/meetings/jobs` is the preferred iOS flow. It stores the uploaded audio under `DATA_DIR`, returns a job id, and lets the backend worker finish transcription plus summary even if the iOS app leaves the recording screen after upload. When the job completes, the original audio is moved to `DATA_DIR/meeting-audio/{user_id}/{meeting_id}.*`, linked to that meeting, and can be downloaded through `GET /v1/meetings/{id}/audio` by the owning user. `MEETING_JOB_WORKERS` controls how many meeting jobs can run at once; keep it conservative on local machines because Whisper/WhisperX can consume significant memory.

For multilingual transcription, leave `WHISPER_LANGUAGE` empty. The backend keeps Whisper in `transcribe` mode, enables multilingual decoding for `faster-whisper`, and uses short overlapping chunks by default so English, Russian, Kazakh, and other spoken languages are preserved instead of forcing the whole recording into one detected language. `TRANSCRIPTION_CHUNKING_ENABLED=true` splits recordings into overlapping WAV chunks with `ffmpeg`, transcribes chunks in parallel with `TRANSCRIPTION_CHUNK_WORKERS`, then merges the transcript by timestamp. Tune `TRANSCRIPTION_CHUNK_SECONDS`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS`, and `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS` for the server. `WHISPER_CPU_THREADS` and `WHISPER_NUM_WORKERS` are passed to `faster-whisper`, while `WHISPERX_BATCH_SIZE` controls WhisperX batch size when diarization is enabled. When `DIARIZATION_ENABLED=true`, WhisperX uses full-file diarization context instead of external chunk-level diarization so speaker labels remain more stable across the recording. Use `DIARIZATION_MIN_SPEAKERS` / `DIARIZATION_MAX_SPEAKERS` only when you know the expected speaker count.

Saved meetings include a contents outline and the original timestamped transcript segments. When the AI summary endpoint is unavailable, the backend still saves the transcript and names the meeting from the submitted location, adding numeric suffixes such as `Кошек батыр 14 1` for repeated recordings at the same place. `POST /v1/meetings/{id}/summary` can later generate the AI summary and retitle the saved meeting from the AI summary title.
