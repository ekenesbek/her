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

Subscription enforcement is backend-owned. The free plan allows 60 recording minutes per authenticated user per calendar month. The plus plan allows 1200 recording minutes and enables the meeting Ask AI chat endpoints. Users default to free until the backend validates an active Apple StoreKit subscription transaction for `APPLE_SUBSCRIPTION_PRODUCT_ID`. The old `PATCH /v1/subscription` local entitlement switch is disabled unless `LOCAL_SUBSCRIPTION_OVERRIDES_ENABLED=true`.

For StoreKit validation, install `app-store-server-library`, create the auto-renewable subscription product in App Store Connect, set the same product id in the iOS `PlusSubscriptionProductID`, and configure the backend with Apple root certificate files from the Apple PKI site:

```text
APPLE_SUBSCRIPTION_PRODUCT_ID=com.ekenesbek.her.plus.monthly
APP_STORE_BUNDLE_ID=com.ekenesbek.her
APP_STORE_ENVIRONMENT=sandbox
APP_STORE_ROOT_CERTIFICATES_DIR=/etc/meta-ios-app-store-roots
APP_STORE_APP_APPLE_ID=
```

`APP_STORE_APP_APPLE_ID` is required by Apple's verifier when `APP_STORE_ENVIRONMENT=production`.

The transcription backend is selected with `TRANSCRIPTION_PROVIDER`:

- `local`: run `faster-whisper` or WhisperX inside this FastAPI process. This remains the default and fallback.
- `deepgram`: send the completed audio file to Deepgram pre-recorded STT with diarization enabled. Set `DEEPGRAM_API_KEY`, and optionally `DEEPGRAM_MODEL`, `DEEPGRAM_LANGUAGE`, and `DEEPGRAM_TIMEOUT_SECONDS`. The default `DEEPGRAM_LANGUAGE=multi` keeps Nova-3 out of English-only mode for mixed-language recordings.
- `external`: send the completed audio file to a separate GPU STT service at `EXTERNAL_TRANSCRIPTION_URL`, for example `http://127.0.0.1:8000`. See `her-ios/stt-service/README.md`.

## Endpoints

- `GET /health`
- `GET /v1/subscription`
- `POST /v1/subscription/apple-transaction` with JSON `{ "signedTransaction": "..." }` from StoreKit 2.
- `PATCH /v1/subscription` with JSON `{ "plan": "free" | "plus" }` only when `LOCAL_SUBSCRIPTION_OVERRIDES_ENABLED=true`. The backend still accepts legacy `"paid"` as a plus alias for local testing.
- `POST /v1/transcriptions` with multipart field `audio`
- `POST /v1/summaries` with JSON `{ "transcript": "..." }`
- `POST /v1/meetings/process` with multipart field `audio`
- `POST /v1/meetings/jobs` with multipart field `audio`
- `GET /v1/meetings/jobs/{job_id}`
- `GET /v1/meetings`
- `GET /v1/meetings/{id}`
- `PATCH /v1/meetings/{id}` with JSON `{ "title": "..." }`
- `DELETE /v1/meetings/{id}`
- `GET /v1/meetings/{id}/audio`
- `POST /v1/meetings/{id}/summary`
- `GET /v1/meetings/{id}/chat`
- `POST /v1/meetings/{id}/chat` with JSON `{ "question": "..." }`
- `POST /v1/meetings/{id}/chat/stream` with JSON `{ "question": "..." }`, returning SSE `data: {"delta": "..."}`
- `GET /v1/voice-profiles`
- `PATCH /v1/voice-profiles/{profile_id}` with JSON `{ "name": "..." }`
- `GET /v1/voice-profiles/{profile_id}/samples`
- `GET /v1/voice-profiles/{profile_id}/samples/{sample_id}/audio`

## Database

The backend stores data in `DATA_DIR/meetings.sqlite3` with normalized tables:

- `meetings`: transcript, title, overview, language, duration, source/device/location metadata, and the backend path to original meeting audio when available.
- `user_subscriptions`: optional local override entitlement per authenticated user, disabled by default outside controlled testing.
- `apple_subscription_transactions`: Apple-signed StoreKit subscription transactions used to derive active plus entitlement.
- `meetings.outline_json`: chronological contents outline generated from timestamped transcript segments.
- `meetings.segments_json`: timestamped transcript segments with optional speaker labels.
- `meeting_chat_messages`: ordered per-meeting chat turns for the meeting Q&A thread.
- `summary_items`: decisions, action items, and follow-ups linked to a meeting.
- `meeting_memory_candidates`: reviewable per-meeting/per-call facts extracted from summaries for later promotion into the user memory wiki.
- `voice_profiles`: user-scoped saved speaker identities, including automatically created `Speaker N` profiles.
- `voice_profile_samples`: confirmed voice samples linked to a profile, optional source meeting, original speaker label, and embedding.
- `user_speaker_counters`: per-user next unknown-speaker index so generated `Speaker 1`, `Speaker 2`, and later names are not reused after rename or delete.

Older JSON-blob databases are migrated automatically on startup.

## Notes

`faster-whisper` runs locally and downloads the configured model on first use when `TRANSCRIPTION_PROVIDER=local`. `turbo` is the practical free default for this MVP because it is close to `large-v3` quality while being much faster. Use `base` or `small` for weaker CPU-only machines, and `large-v3` when quality matters more than speed. For faster and more stable speaker diarization on long recordings, use `TRANSCRIPTION_PROVIDER=deepgram` with a paid STT key or run `her-ios/stt-service` on a GPU host and set `TRANSCRIPTION_PROVIDER=external`.

For the current platform-managed Alem OSS summary/chat model, keep secrets in `.env`:

```bash
ALEM_OSS_API_KEY=<your key>
ALEM_OSS_BASE_URL=https://llm.alem.ai/v1
OPENAI_SUMMARY_MODEL=gpt-oss
```

`POST /v1/meetings/jobs` is the preferred iOS flow. It stores the uploaded audio under `DATA_DIR`, returns a job id, and lets the backend worker finish transcription even if the iOS app leaves the recording screen after upload. Send `generate_summary=false` when the client should save the transcript first and let the user generate a summary later through `POST /v1/meetings/{id}/summary`; omit it or send `true` for the older transcript-plus-summary job behavior. When the job completes, the original audio is moved to `DATA_DIR/meeting-audio/{user_id}/{meeting_id}.*`, linked to that meeting, and can be downloaded through `GET /v1/meetings/{id}/audio` by the owning user. `MEETING_JOB_WORKERS` controls how many meeting jobs can run at once; keep it conservative on local machines because Whisper/WhisperX can consume significant memory.

For multilingual transcription, leave `WHISPER_LANGUAGE` empty. The backend keeps Whisper in `transcribe` mode, enables multilingual decoding for `faster-whisper`, and uses short overlapping chunks by default so English, Russian, Kazakh, and other spoken languages are preserved instead of forcing the whole recording into one detected language. `TRANSCRIPTION_CHUNKING_ENABLED=true` splits recordings into overlapping WAV chunks with `ffmpeg`, transcribes chunks in parallel with `TRANSCRIPTION_CHUNK_WORKERS`, then merges the transcript by timestamp. Tune `TRANSCRIPTION_CHUNK_SECONDS`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS`, and `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS` for the server. `WHISPER_CPU_THREADS` and `WHISPER_NUM_WORKERS` are passed to `faster-whisper`, while `WHISPERX_BATCH_SIZE` controls WhisperX batch size when diarization is enabled. When `DIARIZATION_ENABLED=true`, WhisperX uses full-file diarization context instead of external chunk-level diarization so speaker labels remain more stable across the recording. Use `DIARIZATION_MIN_SPEAKERS` / `DIARIZATION_MAX_SPEAKERS` only when you know the expected speaker count. `VOICE_PROFILE_MATCH_THRESHOLD` is the normal strict speaker-profile threshold; when a user has exactly one saved voice profile, `VOICE_PROFILE_SINGLE_PROFILE_MATCH_THRESHOLD` and `VOICE_PROFILE_SINGLE_PROFILE_MATCH_MARGIN` allow a slightly lower match only for the clearly best diarized speaker in that recording.

After known voice profiles are relabeled, remaining generated diarization labels are saved as user-scoped `Speaker N` profiles and the meeting transcript is rewritten to those stable profile names. The counter is per user and only moves forward, so renaming `Speaker 1` to a real name such as `Samole` does not allow a later unknown voice to reuse `Speaker 1`. Profile samples can be listed or downloaded for People settings playback, and profile rename rewrites saved meeting segment labels for that user.

Saved meetings include a contents outline and the original timestamped transcript segments. When the AI summary endpoint is unavailable, the backend still saves the transcript and names the meeting from the submitted location, adding numeric suffixes such as `Кошек батыр 14 1` for repeated recordings at the same place. `PATCH /v1/meetings/{id}` lets the owning user rename a recording, `DELETE /v1/meetings/{id}` removes the recording and linked server audio, and `POST /v1/meetings/{id}/summary` can later generate the AI summary and retitle the saved meeting from the AI summary title.

Meeting responses also include `memoryCandidates`. These are not global memory yet. They are local, reviewable candidates generated from the meeting summary's decisions, action items, follow-ups, topics, and call-note overview. Obvious secret values are redacted before prompt-readable persistence, and address/contact/payment-like candidates are remembered with `sensitivity=review` so the app can confirm them before global promotion or high-impact use. A later Stage 3 curator can promote confirmed candidates into the shared user memory wiki described in `app/docs/user-memory-wiki.md`.
