# Meta iOS

This folder is split into the mobile frontend and the local backend for the Meta personal AI MVP.

```text
meta-ios/
  frontend/   iOS app
  backend/    FastAPI, local Whisper, OpenAI summaries
  docs/       Meta Wearables DAT notes and consent notes
```

## MVP behavior

- Start recording from the iOS app.
- Record from the current iOS input route. If Ray-Ban Meta glasses are paired as a Bluetooth HFP input, iOS can route microphone audio through the glasses.
- Stop recording and send the `.m4a` file to the local backend.
- Backend transcribes audio with `faster-whisper`.
- Backend summarizes with OpenAI when `OPENAI_API_KEY` is configured, otherwise it uses a local heuristic fallback.
- Backend stores processed meetings in local SQLite.
- Meta Wearables Device Access Toolkit is wired through `WearablesBridge`; Bluetooth audio route remains the fallback for MVP audio.

## Frontend

Open the iOS project in Xcode:

```bash
open meta-ios/frontend/ConversationSummarizer.xcodeproj
```

The target is `ConversationSummarizer`, deployment target is iOS 15.2, bundle identifier is `com.ekenesbek.metaagent`, and Team ID is `6UNHXUUR5T`.

`ConversationSummarizer/Resources/Info.plist` has:

- `BackendAPIURL`: `http://Yerasyls-MacBook-Pro.local:8787`
- `MWDAT`: Meta App ID, Client Token, Team ID, and callback scheme placeholders from Xcode build settings.
- local network permission for the MVP backend.

## Backend

Run the backend from the repo root:

```bash
cd meta-ios/backend
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

## Meta DAT setup

In Meta Wearables Developer Center > App configuration, add iOS app details:

- Team ID: `6UNHXUUR5T`
- Bundle ID: `com.ekenesbek.metaagent`
- Universal link / callback scheme: `com.ekenesbek.metaagent://`

The checked-in Xcode project links `MWDATCore` from `https://github.com/facebook/meta-wearables-dat-ios` at exact version `0.6.0`.

## Local verification

```bash
xcodebuild -project meta-ios/frontend/ConversationSummarizer.xcodeproj \
  -scheme ConversationSummarizer \
  -destination 'generic/platform=iOS' \
  -derivedDataPath meta-ios/frontend/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

python3 -m compileall meta-ios/backend/app
```
