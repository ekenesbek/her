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
