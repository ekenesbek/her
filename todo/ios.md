# iOS Tasks

Active `IOS-N` tasks and iOS-scoped `BUG-N` tasks live here.

# IOS-10: Persist Meeting Audio And Improve Transcript Playback

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Keep uploaded meeting audio on the backend per authenticated user, improve speaker diarization/relabeling quality, and let the iOS contents transcript play grouped timestamp chunks while following the active text.

## Context

The current job worker deletes uploaded audio after transcription, so another device cannot download the original recording and contents playback only works on the recording iPhone. WhisperX diarization currently runs inside each transcription chunk, which can collapse or destabilize speaker labels across the full meeting. The iOS transcript also renders every raw sentence-level segment instead of reviewer-friendly speaker chunks.

## Scope

In scope:
- Persist original job/process audio under backend `DATA_DIR` and link it to the owning user/meeting.
- Add an authenticated meeting audio download endpoint.
- Improve WhisperX diarization by using full-file speaker context and profile matching against transcript speaker labels.
- Group transcript rows into 3-5 sentence speaker-prioritized chunks.
- Add chunk playback from the contents transcript, with remote audio download when local audio is missing.

Out of scope:
- Cloud sync beyond the current backend server.
- Reprocessing old meetings to recover audio already deleted by earlier backend versions.
- Perfect diarization for every acoustic environment; this still depends on pyannote/WhisperX model quality and voice enrollment quality.

## Implementation Plan

- [x] Add backend audio columns, storage helpers, and audio download route.
- [x] Preserve uploaded audio when meeting jobs/process endpoint complete.
- [x] Adjust diarization/profile matching for full-meeting speaker consistency.
- [x] Add iOS audio download/playback controller and grouped transcript chunks.
- [x] Run backend/iOS verification and update docs.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-ios10-audio-storage python3 - <<'PY' ...` storage smoke verified `hasAudio`, attached audio path lookup, and summary/save updates preserving attached audio.
- `python3 -m compileall her-ios/backend/app/services/voice_profiles.py`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `git diff --check`
- Secret scan over tracked project paths found no pasted API key.
- Deployed backend to `51.195.200.207`; previous backend files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-085321-ios10-audio.tgz`.
- Remote backend compile in `/opt/meta-ios/backend/.venv`, `systemctl restart meta-ios-backend.service`, `GET /health`, and route import smoke for `/v1/meetings/{meeting_id}/audio`.
- Signed iOS device build succeeded.
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`

Not run:
- Real multi-speaker recording review after deployment.
- Cross-device audio download playback, because only one physical iPhone is connected here.

## Result

Backend meetings now keep original uploaded audio for completed `/v1/meetings/jobs` and `/v1/meetings/process` flows instead of deleting it. Completed audio is moved to `DATA_DIR/meeting-audio/{user_id}/{meeting_id}.*`, linked to the authenticated meeting row, exposed as `hasAudio=true`, and downloadable by the owning user at `GET /v1/meetings/{id}/audio`.

WhisperX no longer runs external chunk-level diarization when diarization is enabled; it transcribes the full file so pyannote/WhisperX has full-meeting speaker context. Added optional `DIARIZATION_MIN_SPEAKERS` and `DIARIZATION_MAX_SPEAKERS` knobs. Voice profile matching now first extracts embeddings from the actual transcript speaker time ranges, so enrolled-user matching aligns with the same speaker labels shown in the transcript. The pyannote fallback pipeline token argument was also fixed for the installed server version.

iOS contents now groups transcript display rows into speaker-prioritized chunks instead of rendering every raw sentence. A speaker change always starts a new chunk; same-speaker text is grouped up to roughly 3-5 sentences or a time/pause boundary. Tapping a chunk plays only that time range. While audio is playing, the active chunk is highlighted and the scroll view follows it. If the local recording file is missing but the backend has audio, iOS downloads the meeting audio through the authenticated backend endpoint, saves it locally, and then plays it.

Docs/env guidance now mention persisted meeting audio and diarization speaker-count knobs. Backend code is deployed to `51.195.200.207`, and the updated iOS app is installed/launched on `iPhone (Yerasyl)`.

Known limitations: older meetings whose audio was deleted by previous backend versions cannot be recovered unless re-uploaded/reprocessed. Diarization quality still depends on WhisperX/pyannote and recording acoustics; if the model collapses multiple similar voices, set `DIARIZATION_MIN_SPEAKERS=2` or a known speaker count on the server and retest.

## Next

Result is ready for human review. Review gate: record a new multi-speaker meeting, open contents, verify speaker chunks, tap a chunk to play only that range, and confirm the active text follows playback. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue review of the IOS-7/8/9 meeting-processing stack after this real recording test.

# IOS-9: Wire Alem OSS Summaries And Meeting Chat

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Use the platform-managed Alem OSS LLM for meeting summaries and conversation chat instead of local heuristic summary and mocked chat.

## Context

OpenClaw configures Alem OSS as a platform-managed provider using `ALEM_OSS_API_KEY`, base URL `https://llm.alem.ai/v1`, and model `gpt-oss`. The Her backend currently only checks `OPENAI_API_KEY`, so `/health` reports `openaiConfigured=false` and summaries fall back to the local first-sentences heuristic. iOS meeting chat is currently a local keyword mock in `ConversationChatPanel`.

## Scope

In scope:
- Add Alem OSS env support to the backend without committing secrets.
- Make health/config reflect either OpenAI-compatible or Alem OSS key availability.
- Add a backend meeting chat endpoint powered by the same OpenAI-compatible client.
- Wire the iOS chat tab to the backend endpoint with a local fallback only for failures.
- Stream chat answers into the active assistant bubble and keep the chat input readable in iOS dark mode.
- Persist meeting chat messages per meeting and include prior turns in the next chat context.
- Use a location-based meeting title when AI summary is unavailable, then retitle from AI summary when it succeeds.
- Deploy backend env/code and install the updated iOS build.

Out of scope:
- Storing API keys in source control or task docs.
- Cross-meeting/global memory chat.

## Implementation Plan

- [x] Add `ALEM_OSS_API_KEY`/base URL settings and fallback client selection.
- [x] Add meeting chat request/response schemas and backend endpoint.
- [x] Replace mocked iOS chat send path with backend chat calls.
- [x] Verify locally, deploy backend, install iOS build.
- [x] Add streaming meeting chat responses and force readable chat input text in dark mode.
- [x] Persist chat messages and hydrate them in the iOS chat tab.
- [x] Add location fallback titles and summary retitle behavior.

## Verification

- Inspected OpenClaw Alem OSS config under `/Users/ekenesbek/VSCodeProjects/openclaw/private`: provider uses `ALEM_OSS_API_KEY`, base URL `https://llm.alem.ai/v1`, and model `gpt-oss`.
- `python3 -m compileall her-ios/backend/app`
- Local settings smoke with `ALEM_OSS_API_KEY` confirmed `llm_configured=true`, Alem base URL selection, and chat fallback behavior.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Signed device build for `iPhone (Yerasyl)` succeeded.
- Deployed backend code to `51.195.200.207`; previous backend files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-075158.tgz`.
- Runtime env on `51.195.200.207` now uses Alem OSS without storing secrets in tracked files; `GET /health` returns `summaryModel=gpt-oss` and `openaiConfigured=true`.
- Remote Alem summary smoke returned a summary with decisions, action items, and outline items.
- Remote Alem meeting chat smoke answered from the meeting context.
- Deployed streaming chat backend update to `51.195.200.207`; backup created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-081406-stream-chat.tgz`.
- Remote isolated FastAPI stream smoke against Alem OSS returned status 200, 13 delta chunks, `done=true`, and no error event.
- Chat input `TextField` now uses explicit black foreground/tint/prompt colors so iOS dark mode does not turn typed text white.
- Updated signed iOS build installed and launched on `iPhone (Yerasyl)`.
- Deployed chat persistence/offline-title backend update to `51.195.200.207`; backup created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-083623-chat-persist.tgz`.
- Remote isolated FastAPI smoke on a temporary SQLite database verified: repeated location titles become `Кошек батыр 14` then `Кошек батыр 14 1`; `GET /chat` returns persisted user/assistant messages; the second chat response receives previous turns in context; `POST /summary` retitles the meeting to the AI summary title without deleting chat history.
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `git diff --check`
- Secret scan over tracked project paths found no pasted API key.

## Result

Backend settings now support platform-managed Alem OSS through `ALEM_OSS_API_KEY` and `ALEM_OSS_BASE_URL`, while keeping the existing OpenAI-compatible path. Summary generation uses the configured LLM when available, so it no longer falls back to the first transcript lines. If AI summary is unavailable, the backend still saves the transcript/meeting with `summaryStatus=unavailable` and a location-based title. Added authenticated `GET /v1/meetings/{meeting_id}/chat`, `POST /v1/meetings/{meeting_id}/chat`, streaming `POST /v1/meetings/{meeting_id}/chat/stream`, and `POST /v1/meetings/{meeting_id}/summary`. Chat messages are persisted in SQLite per meeting, prior turns are included in the next LLM call, and regenerating a summary retitles the saved meeting without deleting chat history. iOS hydrates saved chat messages, streams new deltas into the active assistant bubble, exposes summary generation for unsummarized saved meetings, and keeps chat input text readable in dark mode. Backend code and runtime env are deployed to `51.195.200.207`, and the updated iOS build was installed and launched on the connected iPhone.

## Next

Ready for human review: open a meeting, ask two chat questions, leave and reopen it, and confirm the thread is still there and the second answer can refer to the first. Also verify a meeting saved without AI summary gets a location-based title and that pressing Generate summary later retitles it from the AI summary. After approval: commit, push/PR only if requested, then archive/update the task. Next task candidate from `todo/tasks.md`: review/approve the current `IOS-7` and `IOS-8` meeting-processing changes.

# IOS-8: Add Meeting Contents Outline And Speaker Transcript

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Replace the flat transcript card in conversation detail with a contents-style review surface: audio duration row, logical outline with timestamps, and timestamped transcript segments grouped by speaker labels that can be renamed.

## Context

The current detail screen shows `summary`, `transcript`, and `chat` tabs. The transcript tab renders one plain text blob, so it does not expose timestamps, segment boundaries, speaker chunks, or editable speaker labels. The backend already receives transcript segments from Whisper/WhisperX but saved meetings do not persist those structured segments.

## Scope

In scope:
- Persist transcript segments and generated outline entries with saved meetings.
- Generate a heuristic logical outline from timestamped transcript segments, with AI-compatible summary shape ready for richer outlines.
- Decode structured meeting contents in iOS.
- Replace the detail transcript tab with a `contents` tab containing audio duration, outline, and segment transcript.
- Let the user tap `Speaker N` labels and rename them locally in the detail view.

Out of scope:
- Cloud sync for renamed speaker labels.
- Guaranteed audio playback from older meetings, because existing backend processing deletes uploaded audio after transcription.
- Reprocessing old meetings to recover missing timestamps.

## Implementation Plan

- [x] Add backend schemas/storage fields for outline and transcript segments.
- [x] Generate outline entries during meeting processing and save them with jobs.
- [x] Decode outline/segments in iOS models and processing responses.
- [x] Build the contents UI with timestamped outline and speaker transcript rows.
- [x] Run backend and iOS build verification.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-ios8-data DIARIZATION_ENABLED=false python3 - <<'PY' ...` storage smoke for saving/loading `segments` and `outline`, including legacy JSON-blob migration.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Remote deploy verification on `51.195.200.207`: backend compile in `/opt/meta-ios/backend/.venv`, storage/import smoke for `segments` and `outline`, `systemctl restart meta-ios-backend.service`, `GET /health`.
- iPhone deploy: `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`.

Not run:
- Real recording content review with a new mixed-language meeting.
- Audio playback from saved meetings; existing backend processing still deletes uploaded audio after transcription.

## Result

Added structured meeting contents. Backend `TranscriptSegment` data is now persisted on saved meetings as `segments_json`, and meetings include an `outline_json` chronological table of contents. Existing SQLite databases migrate in place by adding the two JSON columns with empty-array defaults. Job-based processing and `/v1/meetings/process` now save both transcript segments and outline entries on the completed meeting response.

Added outline generation. The local fallback groups timestamped transcript segments using pause/duration boundaries and produces timestamped outline items. The OpenAI-compatible summary prompt now also requests a chronological `outline` array when an API key is configured, while still preserving the original transcript language.

Updated iOS meeting models and detail UI. `StoredMeeting` now decodes `segments`, and `MeetingSummary` decodes `outline`. The detail tabs are now `contents`, `summary`, and `chat`. The `contents` view shows an audio duration row, an `Outline` list with timestamp links, and a `Transcript` list with per-segment timestamps and speaker labels. Tapping a speaker label opens a rename dialog and stores renamed labels locally per meeting in `UserDefaults`. For newly recorded meetings on the same iPhone, the app also links the returned meeting id to the local recording file and the audio row can play/pause that local audio.

Deployed backend update to `51.195.200.207` on 2026-05-10. Backups of the previous backend files were created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-072636.tgz` and `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-073012.tgz`. The updated Debug iOS app was built, installed, and launched on `iPhone (Yerasyl)`.

Known limitations: older meetings do not have saved segments/outline unless they are reprocessed, so the UI falls back to a single transcript block. Speaker renames are local to this device and are not synced to backend yet. Audio playback is local-only for meetings recorded on the same iPhone; backend-hosted playback for older/cross-device meetings still requires keeping uploaded audio or adding a playback endpoint.

## Next

Result is ready for human review. Review gate: record a new meeting, open its `contents` tab, verify outline timestamps, segment transcript, and speaker rename behavior. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: decide whether audio playback should persist original recordings as a follow-up, or continue `IOS-3` setup state backend work.

# IOS-7: Add Background Meeting Processing Jobs

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-08

## Goal

Move post-recording meeting processing to a backend-owned job so transcription and AI summary can finish after the iOS app leaves the recording screen or is closed after upload.

## Context

Meeting transcription currently happens through the synchronous `/v1/transcriptions` endpoint. The iOS view model waits for that request to finish, then the user must tap a separate summary button. The backend already has OpenAI-compatible summary support and Alem env guidance, but the running backend reports `openaiConfigured=false`, so AI summaries are not active until the runtime `.env` is configured.

## Scope

In scope:
- Add backend job state for uploaded meeting audio.
- Process meeting jobs in a backend worker thread pool and persist completed meetings to SQLite.
- Split long audio into chunks and transcribe chunks in parallel when enabled by runtime settings.
- Expose job submit/status endpoints for iOS.
- Update iOS recording flow to submit audio once, poll job status, and show transcript/summary when complete.
- Keep Alem/OpenAI-compatible summary configured through `.env`, not committed credentials.

Out of scope:
- Storing plaintext API keys in source control or task docs.
- Guaranteed upload completion if the app is force-killed before the recording file reaches the backend.
- Cloud deployment or stage 2 scheduled/background autonomous runs.

## Implementation Plan

- [x] Add backend schemas and SQLite job table.
- [x] Add job submission/status endpoints and worker execution.
- [x] Add chunk-level parallel transcription for long recordings.
- [x] Wire iOS meeting processing service to submit/poll jobs.
- [x] Update docs/env guidance and result notes.
- [x] Run backend compile and iOS build verification.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-ios7-data DIARIZATION_ENABLED=false python3 - <<'PY' ...` storage smoke for meeting job create/get/list/update/completed meeting hydration.
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-chunks-smoke DIARIZATION_ENABLED=false TRANSCRIPTION_CHUNK_SECONDS=3 TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=1 TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=4 python3 - <<'PY' ...` ffmpeg/ffprobe audio chunk split smoke.
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-chunks-merge DIARIZATION_ENABLED=false TRANSCRIPTION_CHUNK_SECONDS=3 TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=1 TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=4 TRANSCRIPTION_CHUNK_WORKERS=2 python3 - <<'PY' ...` chunk merge smoke with a fake transcriber.
- `PYTHONPATH=her-ios/backend WHISPER_LANGUAGE= python3 - <<'PY' ...` settings smoke proving empty `WHISPER_LANGUAGE` normalizes to auto-detect.
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-multilingual-chunks DIARIZATION_ENABLED=false TRANSCRIPTION_CHUNK_SECONDS=30 TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=3 TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=30 python3 - <<'PY' ...` multilingual chunk split smoke.
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-multilingual-merge DIARIZATION_ENABLED=false TRANSCRIPTION_CHUNK_SECONDS=30 TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=3 TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=30 TRANSCRIPTION_CHUNK_WORKERS=2 python3 - <<'PY' ...` multilingual chunk merge smoke with a fake transcriber.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Secret scan across tracked project/docs files.
- Remote deploy verification on `51.195.200.207`: backend compile in `/opt/meta-ios/backend/.venv`, app import/routes smoke, `systemctl restart meta-ios-backend.service`, `GET /health`, OpenAPI route check for `/v1/meetings/jobs`.
- Remote multilingual deploy verification on `51.195.200.207`: settings smoke for `WHISPER_LANGUAGE=None`, 30-second chunk runtime config, ffmpeg/ffprobe chunk split smoke, `systemctl restart meta-ios-backend.service`, `GET /health`, protected job route returns `401`.
- iPhone deploy: `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`.

Not run:
- Full `app.main` import/route smoke in the ambient `python3`; it failed before app import because `jwt`/`pyjwt` is not installed in that interpreter.
- Real audio transcription and on-device upload/polling smoke.
- Real mixed English/Russian/Kazakh recording was not exercised; the deployed change was verified through settings, chunking, and merge smoke checks.

## Result

Added backend-owned meeting processing jobs. `POST /v1/meetings/jobs` persists uploaded audio under `DATA_DIR`, stores a queued job in SQLite, and submits processing to a backend `ThreadPoolExecutor`. The worker transcribes audio, relabels enrolled speakers, summarizes through the existing OpenAI-compatible `SummaryService`, saves the completed meeting, marks the job completed, and removes the uploaded audio file. `GET /v1/meetings/jobs/{job_id}` returns job state and hydrates the completed meeting when ready. Active queued/processing jobs are resubmitted on backend startup.

Added chunk-level parallel transcription for long recordings. When `TRANSCRIPTION_CHUNKING_ENABLED=true` and the audio duration is at least `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS`, the backend uses `ffprobe`/`ffmpeg` to split audio into overlapping WAV chunks, transcribes chunks in a `ThreadPoolExecutor` capped by `TRANSCRIPTION_CHUNK_WORKERS`, offsets segment timestamps back into the original recording, drops duplicate overlap segments, and merges the transcript. Runtime knobs now include `TRANSCRIPTION_CHUNK_SECONDS`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS`, `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS`, and `TRANSCRIPTION_CHUNK_WORKERS`.

Updated transcription defaults for mixed-language meetings. Empty `WHISPER_LANGUAGE` now normalizes to `None`, faster-whisper and WhisperX run with `task="transcribe"` instead of translation, and runtime chunking defaults to 30-second chunks with 3-second overlap and 2 chunk workers. This lets language detection happen per short chunk instead of forcing a whole meeting into the first detected language, so English, Russian, and Kazakh speech should stay in their original languages instead of being rewritten into one language.

Updated iOS recording processing to submit the recording to the job endpoint and poll until completion. When the backend supports jobs, the transcript and summary arrive together and the meeting is already stored server-side. If the backend does not have the job endpoint yet, iOS falls back to the old synchronous `/v1/transcriptions` flow so existing deployments do not hard-break.

AI summary support was already present through OpenAI-compatible env vars; docs now call out the `gpt-oss` default, Alem-compatible `OPENAI_BASE_URL`, `MEETING_JOB_WORKERS`, `WHISPER_CPU_THREADS`, `WHISPER_NUM_WORKERS`, and `WHISPERX_BATCH_SIZE`. The provided secret was not written to tracked files. Current checked health responses for the running local/remote backends still report `openaiConfigured=false`, so runtime `.env` must be configured before real AI summaries are active.

Known limitations: chunk-wise WhisperX diarization can make raw `SPEAKER_NN` labels less stable across chunk boundaries; disable chunking if full-file diarization quality matters more than throughput. A job survives app navigation/closure after upload reaches the backend; it does not yet guarantee recovery if iOS is force-killed before the upload completes.

Deployed to `51.195.200.207` on 2026-05-10. Backups of previous backend files were created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-064921.tgz` and `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-071010.tgz`. The active systemd service is `meta-ios-backend.service`, running from `/opt/meta-ios/backend` on port `8787`. Runtime config now has `summaryModel=gpt-oss`, Alem base URL configured, `WHISPER_LANGUAGE=` normalized to auto-detect, `TRANSCRIPTION_CHUNKING_ENABLED=true`, `TRANSCRIPTION_CHUNK_SECONDS=30`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=3`, `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=30`, `TRANSCRIPTION_CHUNK_WORKERS=2`, and `MEETING_JOB_WORKERS=1`. `ffmpeg` and `ffprobe` are installed on the server. `OPENAI_API_KEY` is still missing from `/etc/meta-ios-backend.env`, so `/health` reports `openaiConfigured=false`; AI summaries will use local fallback until a non-exposed key is added and the service is restarted. The updated Debug iOS app was also built, installed, and launched on `iPhone (Yerasyl)` so the client uses the new job polling endpoint.

## Next

Result is ready for human review. Review gate: add a rotated `OPENAI_API_KEY` to `/etc/meta-ios-backend.env`, restart `meta-ios-backend.service`, run one real recording from the iPhone, then close or leave the recording screen after upload starts and verify the completed meeting appears in Conversations. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

# IOS-6: Polish iOS Auth Screen

Status: approved
Priority: P2
Owner: agent
Stream: ios
Branch: ios/IOS-6/auth-screen-polish
Created: 2026-05-07

## Goal

Remove the extra square/card feeling from the registration/sign-in screen and move the "One mind. Every conversation." headline lower.

## Context

The current first-run auth screen shows a large feature card below the headline and uses `ASWebAuthenticationSession` for Google sign-in, which can trigger the iOS pre-authentication consent dialog.

## Scope

In scope:
- Adjust the iOS onboarding account screen layout.
- Request an ephemeral Google web auth session to avoid the iOS shared-browser consent dialog where supported.
- Install the updated Debug build on the connected iPhone for review.

Out of scope:
- Replacing the OAuth implementation with a new Google SDK.
- Changing backend auth contracts.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect the current auth screen and Google sign-in flow.
- [x] Remove the extra auth-screen card treatment and lower the headline.
- [x] Build, compile backend, install on the connected iPhone.
- [x] Record verification and stop for human review.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `python3 -m compileall her-ios/backend/app`
- `xcrun devicectl device install app --device 00008140-00114D90227B001C her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 00008140-00114D90227B001C com.ekenesbek.her`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'platform=iOS Simulator,id=F233F4D5-BF3B-4CF5-9DB1-39BF34869797' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcrun simctl uninstall booted com.ekenesbek.her`
- `xcrun simctl install booted her-ios/frontend/DerivedData/Build/Products/Debug-iphonesimulator/Her.app`
- `xcrun simctl launch booted com.ekenesbek.her`
- `xcrun simctl io booted screenshot /tmp/her-auth-screen-polish.png`

## Result

Removed the auth working overlay that dimmed only the padded account view and showed as a large rectangular block behind the system sign-in prompt. Moved the "One mind. Every conversation." headline lower by increasing the top spacer on the account step. Google sign-in now requests an ephemeral `ASWebAuthenticationSession` so iOS does not use the shared Safari browser session for this OAuth flow.

The updated Debug app builds, installs, and launches on the connected iPhone. A fresh iPhone 17 simulator install showed the adjusted auth screen without the rectangular working overlay.

## Next

Approved for PR. After PR review/merge: archive/update task state.

# IOS-1: Her iOS Smoke Test

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: ios/IOS-1/her-ios-smoke-test
Created: 2026-05-07

## Goal

Smoke test the renamed Her iOS app and backend after `WEB-1` moved `meta-ios/` to `her-ios/`.

## Context

`WEB-1` renamed the internal project identity and iOS folder/product names. This task verifies that the iOS project still builds, key bundle/callback settings line up with `com.ekenesbek.her`, and the backend remains importable/runnable where local dependencies allow.

## Scope

In scope:
- Verify Xcode build settings, Info.plist values, product name, bundle identifier, and MWDAT callback scheme.
- Run iOS build checks for generic iOS and simulator if available.
- Verify backend import/health path with the available local Python environment.
- Fix rename fallout found during these checks.

Out of scope:
- Physical-device recording validation if no device is available in this environment.
- Changing external Meta Wearables DAT SDK names, keys, package URLs, or Ray-Ban Meta device labels.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect iOS project and backend config after rename.
- [x] Run build/config smoke checks.
- [x] Run backend import/health checks where local deps permit.
- [x] Fix any rename fallout and record limitations.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -showBuildSettings | rg -n "PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|INFOPLIST_KEY_CFBundleDisplayName|INFOPLIST_FILE|DEVELOPMENT_TEAM|MARKETING_VERSION|META_APP_ID|CLIENT_TOKEN"`
- `/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' -c 'Print :MWDAT:AppLinkURLScheme' -c 'Print :MWDAT:MetaAppID' -c 'Print :BackendAPIURL' her-ios/frontend/ConversationSummarizer/Resources/Info.plist`
- `rg -n "meta-ios|metaagent|meta\.app|PRODUCT_NAME = meta|CFBundleDisplayName = meta|Start meta|Stop meta|Toggle meta|conversation in meta" her-ios -g '!her-ios/frontend/DerivedData/**' -g '!**/.venv/**'`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO clean build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' -c 'Print :MWDAT:AppLinkURLScheme' -c 'Print :MWDAT:MetaAppID' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphonesimulator/Her.app/Info.plist`
- `PYTHONPATH=/tmp/her-ios-smoke-deps DATA_DIR=/tmp/her-ios-smoke-data DIARIZATION_ENABLED=false /Users/ekenesbek/.pyenv/versions/3.11.10/bin/python3 - <<'PY' ...`
- `python3 -m compileall her-ios/backend/app`
- `xcrun simctl install booted her-ios/frontend/DerivedData/Build/Products/Debug-iphonesimulator/Her.app`
- `xcrun simctl launch booted com.ekenesbek.her`

## Result

Smoke checks passed for the renamed Her iOS app. Xcode resolves the app product as `Her.app`, bundle ID and callback scheme as `com.ekenesbek.her`, and compiled simulator plist values match the source plist. Both generic iOS and iPhone 17 simulator builds succeeded, and the simulator app installed and launched as `com.ekenesbek.her`.

The backend health path returned `status: ok` with a temporary smoke data directory when diarization was disabled. During verification, `pyproject.toml` was missing dependencies already required by the backend code and listed in `requirements.txt`, so it now declares `pyjwt[crypto]`, `pyannote.audio`, and `whisperx` as project dependencies.

Known limitations: physical-device recording, Meta Wearables DAT device pairing, real transcription, diarization, and auth provider token validation were not exercised in this local smoke pass.

## Next

Result is ready for human review. After approval: commit, push, open PR, then archive/update task state.

# IOS-2: Skip iOS Setup For Existing Accounts

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: ios/IOS-2/skip-setup-existing-account
Created: 2026-05-07

## Goal

When an iOS user signs in to an already existing account, skip the onboarding/setup flow and enter the app.

## Context

The iOS app currently restores auth sessions but still routes users through the remaining onboarding steps when local `onboardingCompleted` is false. The backend auth response also does not say whether Apple/Google sign-in found an existing user or created a new one, so the frontend cannot distinguish existing accounts from new accounts.

## Scope

In scope:
- Return a new/existing account signal from the local iOS backend auth endpoints.
- Persist that signal in the iOS auth session.
- Complete onboarding automatically for existing-account sessions.
- Keep newly created accounts on the setup flow.

Out of scope:
- Redesigning onboarding screens.
- Adding cloud sync, account deletion, or stage 2 credential-vault behavior.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Add `isNewUser` to backend auth responses.
- [x] Decode and persist the flag in iOS auth sessions.
- [x] Skip setup for existing-account sessions while preserving setup for new accounts.
- [x] Run iOS/backend verification and record result.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-ios2-data python3 - <<'PY' ...` contract smoke for `find_or_create_user_with_status` and `AuthResponse.isNewUser`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO clean build`

## Result

Backend auth now returns `isNewUser` for Apple and Google sign-in. The storage layer keeps the existing `find_or_create_user` API and adds `find_or_create_user_with_status` so auth endpoints can distinguish first sign-in from an existing account.

iOS decodes and persists the optional `isNewUser` flag in `AuthSession`. New sessions with `isNewUser == true` continue through setup. Existing sessions with `isNewUser == false`, plus legacy restored sessions where the flag is absent, automatically mark onboarding complete with the current/default Her profile values and enter the app.

## Next

Result is ready for human review. After approval: commit, push, open PR, then archive/update task state.

# IOS-3: Store iOS Setup State On Backend

Status: planned
Priority: P2
Owner: agent
Stream: ios
Branch: ios/IOS-3/server-setup-state
Created: 2026-05-07

## Goal

Persist iOS setup completion and profile settings on the iOS backend instead of relying only on device-local `UserDefaults`.

## Context

`IOS-2` fixes the immediate flow by using the backend identity database to distinguish new accounts from existing accounts. That lets existing accounts skip setup, but the app still stores setup details locally on one device: `onboardingCompleted`, `aiName`, `ownerName`, `signInProvider`, and `glassesSetupSkipped`.

If we want this fully correct, the local iOS backend should expose a `user_profile` or `user_settings` table and API so setup completion lives with the authenticated account. That avoids re-running setup on another device or after local defaults are cleared.

## Scope

In scope:
- Add a backend table for user profile/setup settings keyed by `user_id`.
- Add authenticated endpoints to read and update setup/profile state.
- Update iOS to fetch setup state after auth/session restore.
- Update iOS to write setup completion and profile edits through the backend.
- Keep a local fallback only for backend-unavailable/offline development.

Out of scope:
- Cloud deployment or cross-device sync through a hosted server; local backend remains the stage 1 target.
- Credential vault, scheduled runs, or other stage 2 behavior.
- Reworking Apple/Google auth beyond the setup-state contract.

## Implementation Plan

- [ ] Design the `user_settings`/`user_profile` schema and migration.
- [ ] Add authenticated GET/PATCH endpoints on the iOS backend.
- [ ] Add Swift client methods and wire session restore/sign-in to fetch profile state.
- [ ] Move onboarding/profile saves to backend-backed persistence with local fallback.
- [ ] Add backend contract smoke checks and iOS build verification.

## Verification

Pending.

## Result

Pending.

## Next

Planned follow-up. Pick this after `IOS-2` is reviewed if setup state should be account-backed rather than device-local.

# IOS-4: Improve Voice Enrollment And Wake-Word Setup

Status: planned
Priority: P1
Owner: agent
Stream: ios
Branch: ios/IOS-4/voice-enrollment-wake-word
Created: 2026-05-07

## Goal

Replace the vague `Your Voice` onboarding instruction to "speak for about a minute" with a guided voice collection flow, and add a wake-word creation/training path that captures how the chosen assistant name or wake phrase actually sounds from this user.

## Context

The current `Your Voice` page asks the user to record roughly 60 seconds of natural speech so Her can create a voice profile. The next version should make that minute useful: either ask the user to read prepared text or run a short voice Q&A that also collects useful personalization facts with clear consent.

Wake-word setup should not assume a typed assistant name is enough. The user should pronounce the chosen assistant name / wake phrase several times so the app can validate pronunciation, tune thresholds, and, if the selected wake-word backend needs user-specific examples, use those recordings for training.

## Scope

In scope:
- Update the `Your Voice` onboarding step from generic recording copy to a guided reading mode and/or voice Q&A mode.
- Design prompts that collect enough speech for voice identification while also gathering useful user context.
- Add consent, skip, retry, and re-record states for any personalization facts gathered during the voice Q&A.
- Add a wake-word setup step for choosing the assistant name / wake phrase.
- Require the user to pronounce the chosen name or wake phrase multiple times, including the natural phrasing they expect to use.
- Capture enough metadata to distinguish voice profile enrollment from wake-word calibration/training samples.

Out of scope:
- Scheduled/background autonomous runs.
- Cross-session memory promotion beyond explicit local onboarding/profile data.
- Cloud-only wake-word processing or cloud credential storage.
- Shipping a paid wake-word provider decision without human review.

## Implementation Plan

- [ ] Inspect the current onboarding voice profile UI, recorder, backend enrollment endpoint, and voice profile storage.
- [ ] Replace "speak for about a minute" UX with guided reading and/or voice Q&A content.
- [ ] Add explicit consent and review/edit affordances for any Q&A-derived profile facts.
- [ ] Add wake-word setup UX for assistant name / phrase selection.
- [ ] Record multiple pronunciation samples of the chosen name / wake phrase for validation and future model training.
- [ ] Persist voice enrollment and wake-word sample data with separate labels and deletion paths.
- [ ] Add focused iOS/backend tests or smoke checks for the changed enrollment path.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Manual simulator/device smoke: complete `Your Voice` enrollment, retry/delete samples, and verify wake-word pronunciation samples are stored separately from the normal voice profile.

## Result

Not started.

## Next

Needs human review of the task scope. After approval: create/switch to `ios/IOS-4/voice-enrollment-wake-word`, implement the smallest coherent onboarding change, then stop again for result review before commit/push/PR/archive.

# IOS-5: Put Agent Name Before Voice Enrollment

Status: approved
Priority: P3
Owner: agent
Stream: ios
Branch: ios/IOS-5/onboarding-agent-before-voice
Created: 2026-05-07

## Goal

Show the assistant name step before the "Teach Her your voice" step in iOS onboarding.

## Context

The onboarding order should ask for the agent name before voice enrollment.

## Scope

In scope:
- Reorder the iOS onboarding steps so assistant name appears before voice profile enrollment.
- Keep back/continue navigation and visible step numbering aligned with the new order.

Out of scope:
- Redesigning the onboarding screens.
- Changing voice enrollment behavior.

## Implementation Plan

- [x] Inspect the iOS onboarding flow.
- [x] Move the assistant-name step before voice enrollment.
- [x] Run local iOS/backend smoke verification.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `python3 -m compileall her-ios/backend/app`

## Result

Updated the iOS onboarding order to `Your name` -> `Assistant name` -> `Teach Her your voice` -> `Permissions` -> `Pair Ray-Ban`. The agent and voice step counters now match the new order.

## Next

Approved for PR. After PR review/merge: archive/update task state.

# BUG-1: Fall Back From Bluetooth Voice Enrollment Recorder

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: fix/BUG-1/voice-enrollment-audio-fallback
Created: 2026-05-07

## Goal

Voice profile enrollment should try the Bluetooth HFP microphone first when paired, then fall back to the iPhone microphone if the Bluetooth route cannot prepare or start recording.

## Context

On a physical iPhone with `RB Meta 060S` selected, onboarding voice enrollment failed with `Could not prepare recorder (rate=16000Hz, route=RB Meta 060S).` The recorder only falls back to phone when no glasses input is present, not when the Bluetooth route is present but unusable for the selected recorder settings.

## Scope

In scope:
- Fix `VoiceEnrollmentRecorder` route/format fallback for onboarding and settings voice profile recording.
- Keep Bluetooth as the preferred route.
- Keep upload format compatible with existing voice profile backend upload.

Out of scope:
- Changing Meta DAT pairing, Bluetooth permission UX, or backend voice embedding behavior.
- Physical-device verification if no paired device is available in this environment.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Add route attempts: Bluetooth HFP first, built-in mic fallback.
- [x] Try compatible recorder settings per route and continue on prepare/start failure.
- [x] Run iOS build and backend compile verification.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination generic/platform=iOS -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `python3 -m compileall her-ios/backend/app`

## Result

Updated `VoiceEnrollmentRecorder` so voice profile recording now prepares route attempts in order: Bluetooth HFP first, then the built-in iPhone microphone. Each route tries AAC `.m4a` first and PCM `.caf` second before moving to the next route. This fixes the screenshot failure mode where `RB Meta 060S` was present, `prepareToRecord()` failed on that route, and the recorder stopped instead of falling back to phone.

Build and backend compile checks pass. Physical-device recording with paired Ray-Ban Meta glasses was not exercised in this environment and needs human review on the device.

## Next

Result is ready for human review. Review gate: install/run on the iPhone, keep `RB Meta 060S` connected, and try the voice profile recording once with Bluetooth and once after disconnecting Bluetooth. After approval: commit, push, open PR, then archive/update task state. Next task candidate from `todo/tasks.md`: continue the approved `WEB-1` PR flow or review the open `IOS-1` smoke-test result.
