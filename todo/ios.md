# iOS Tasks

Active `IOS-N` tasks and iOS-scoped `BUG-N` tasks live here.

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
