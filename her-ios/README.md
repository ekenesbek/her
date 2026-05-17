# Her iOS

This folder is split into the mobile frontend and the local backend for the Her personal AI MVP.

```text
her-ios/
  frontend/   iOS app
  backend/    FastAPI, local Whisper, OpenAI summaries
  docs/       wearable audio notes and consent notes
```

## MVP behavior

- Start recording from the iOS app.
- Record from the current iOS input route. If Ray-Ban Meta glasses are paired as a Bluetooth HFP input, iOS can route microphone audio through the glasses.
- Stop recording and send the `.m4a` file to the local backend.
- Backend transcribes audio with `faster-whisper`.
- Backend summarizes with OpenAI when `OPENAI_API_KEY` is configured, otherwise it uses a local heuristic fallback.
- Backend stores processed meetings in local SQLite.
- The iOS app does not require Meta DAT for recording. The wearables surface only reports the active iOS audio route and refreshes Bluetooth HFP detection.

## Frontend

Open the iOS project in Xcode:

```bash
open her-ios/frontend/ConversationSummarizer.xcodeproj
```

The target is `ConversationSummarizer`, deployment target is iOS 15.2, bundle identifier is `com.ekenesbek.her`, and Team ID is `6UNHXUUR5T`.

`ConversationSummarizer/Resources/Info.plist` has:

- `BackendAPIURL`: `http://Yerasyls-MacBook-Pro.local:8787`
- local network permission for the MVP backend.

## Backend

Run the backend from the repo root:

```bash
cd her-ios/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8787 --reload
```

Health check:

```bash
curl http://localhost:8787/health
```

Main iOS endpoint:

```http
POST /v1/meetings/process
Content-Type: multipart/form-data

audio=<meeting.m4a>
```

## Local verification

```bash
xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj \
  -scheme ConversationSummarizer \
  -destination 'generic/platform=iOS' \
  -derivedDataPath her-ios/frontend/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

python3 -m compileall her-ios/backend/app
```
