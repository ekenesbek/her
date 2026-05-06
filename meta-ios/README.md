# Meta iOS

This folder is split into the mobile frontend and the FastAPI backend hosted on a VPS.

```text
meta-ios/
  frontend/   iOS app (SwiftUI)
  backend/    FastAPI, WhisperX, pyannote diarization, voice profiles
  docs/       Meta Wearables DAT notes and consent notes
```

## Behavior

- Apple/Google sign-in in onboarding (Apple requires paid Developer Program for Sign in with Apple capability; Google works with iOS Client ID).
- Optional voice profile enrollment (~60-second sample) during onboarding or in Settings → Voice profile.
- Start recording from the home screen, the recording continues in the background (audio background mode), survives accidental app kills via orphan recovery on relaunch.
- Audio source: Ray-Ban Meta glasses if paired (Bluetooth HFP, 8 kHz mono with beamforming) or built-in iPhone microphone.
- Stop → upload `.m4a` to backend → WhisperX (medium) transcription → pyannote/speaker-diarization-3.1 → segments with `SPEAKER_00 / SPEAKER_01 / ...` labels.
- Voice profile matching: cosine similarity ≥ 0.62 → SPEAKER_NN replaced with the enrolled name.
- Backend stores meetings scoped to the authenticated user; recent / logs lists only the caller's own meetings.
- Siri AppIntents wired (`Start meta recording`, `Stop meta recording`, `Toggle meta recording`) with haptic + system TTS feedback through the active audio output (so glasses A2DP if paired).
- Meta Wearables Device Access Toolkit is wired through `WearablesBridge` for camera/photo capabilities. Audio still flows via standard iOS HFP because the SDK does not expose a microphone API as of 0.6.

## Frontend

Open the iOS project in Xcode:

```bash
open meta-ios/frontend/ConversationSummarizer.xcodeproj
```

Target `ConversationSummarizer`, deployment target iOS 15.2, bundle id `com.ekenesbek.metaagent`, Team ID `6UNHXUUR5T`.

`ConversationSummarizer/Resources/Info.plist` has:

- `BackendAPIURL`: `http://51.195.200.207:8787` — the production VPS (FastAPI service `meta-ios-backend.service`).
- `NSAppTransportSecurity` exception domain for the same host (the production endpoint is plain HTTP for now).
- `UIBackgroundModes` includes `audio` so a recording survives screen lock and app backgrounding.
- `MWDAT` Meta App ID / Client Token / Team ID / callback scheme placeholders from Xcode build settings.
- Microphone, location, notification, and local network usage descriptions.

## Backend

Production deployment lives at `http://51.195.200.207:8787` on an Ubuntu VPS, managed by systemd unit `meta-ios-backend.service`. Configuration is in `/etc/meta-ios-backend.env` (JWT secret, Apple bundle id, Google client ids, HuggingFace token).

To bring up a local copy for development:

```bash
cd meta-ios/backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
# requires:
#   AUTH_JWT_SECRET=<random-hex>
#   APPLE_CLIENT_ID=com.ekenesbek.metaagent
#   GOOGLE_CLIENT_IDS=<your-ios-client-id>.apps.googleusercontent.com
#   HUGGINGFACE_TOKEN=<hf_...>  # for pyannote diarization
uvicorn app.main:app --host 0.0.0.0 --port 8787 --reload
```

Health check:

```bash
curl http://51.195.200.207:8787/health   # production
curl http://localhost:8787/health        # local
```

### Auth-protected endpoints

All require `Authorization: Bearer <jwt>` issued by the auth endpoints below.

```http
POST /v1/auth/apple                # body: {identityToken, fullName?, email?}
POST /v1/auth/google               # body: {idToken}
GET  /v1/auth/me                   # → current user

POST /v1/transcriptions            # multipart audio → transcript with speaker labels
POST /v1/meetings/process          # multipart audio → transcribe + summary + persist
POST /v1/meetings                  # body: meeting payload → save existing transcript+summary
GET  /v1/meetings                  # list user's meetings
GET  /v1/meetings/{id}             # single meeting

POST /v1/voice-profiles            # multipart audio + name → enrollment
GET  /v1/voice-profiles            # list user's profiles
DELETE /v1/voice-profiles/{id}     # delete one
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
