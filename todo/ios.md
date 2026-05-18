# iOS Tasks

Active `IOS-N` tasks and iOS-scoped `BUG-N` tasks live here.

# IOS-19: Remove DAT Pairing From iOS Audio Route UX

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-17

## Goal

Remove the misleading Meta DAT pairing/session surface from the stage-1 iOS recorder and keep only the useful Bluetooth/iOS audio-route behavior.

## Context

Ray-Ban Meta audio works for the recorder the same way it works for Telegram calls: iOS exposes the glasses as a Bluetooth HFP audio route. The current DAT registration/session UI suggests a deeper glasses integration, but the stage-1 meeting recorder does not use a DAT microphone API and does not use camera POV streaming.

## Scope

In scope:
- Replace visible DAT/pairing copy with audio-route status and refresh/scan actions.
- Remove the onboarding Ray-Ban pairing step.
- Remove the unused DAT SDK wiring from the iOS target and Info.plist.
- Keep Bluetooth HFP route detection and recording fallback behavior.
- Update docs to clarify DAT is future camera/control work, not required for audio recording.

Out of scope:
- Adding camera POV streaming or a VisionClaw-style live agent.
- Changing the recording engine or Bluetooth HFP selection logic.
- Physical-device validation on paired glasses from this environment.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Inspect current iOS wearables bridge, onboarding, settings, and route status UI.
- [x] Simplify `WearablesBridge` to iOS audio-route detection only.
- [x] Remove DAT registration/session controls and Ray-Ban pairing from visible onboarding/settings copy.
- [x] Remove the DAT package/product, Info.plist DAT keys, external accessory background mode, and unused glasses image asset.
- [x] Update docs and run verification.

## Verification

- `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`
- `plutil -lint her-ios/frontend/ConversationSummarizer.xcodeproj/project.pbxproj`
- `find her-ios/frontend -path '*/Build/*' -prune -o -path '*/DerivedData/*' -prune -o -type f \( -name '*.swift' -o -name '*.pbxproj' -o -name 'Info.plist' -o -name 'Package.resolved' -o -name 'Contents.json' \) -print | xargs rg -n "meta-wearables|MWDAT|MetaAppID|CLIENT_TOKEN|META_APP_ID|Ray-Ban|RayBanMeta|NSBluetoothAlways|external-accessory|UISupportedExternalAccessory|Start DAT"`
- `git diff --check`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`

## Result

The iOS app no longer links `MWDATCore`, carries DAT credentials, declares DAT/ExternalAccessory plist keys, or shows DAT registration/session controls. Onboarding now finishes after permissions instead of asking the user to pair Ray-Ban glasses. The remaining route UI is framed as the active iOS audio route: iPhone microphone, Bluetooth mic ready/active, or output-only.

Docs now state that DAT is future camera/control work and is not required for the stage-1 audio recorder.

Latest signed Debug build was installed and launched on `iPhone (Yerasyl)`.

Known limitation: physical validation with paired glasses was not run from this environment.

## Next

Result is ready for human review on the installed iPhone app. Human review: confirm onboarding no longer includes a Ray-Ban pairing step, open the audio route control from Home, and verify it reports iPhone mic / Bluetooth mic / output-only honestly. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or review the existing `IOS-18` settings cleanup result.

# IOS-18: Clean Settings And Add Recording Management Actions

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-15

## Goal

Remove confusing Settings rows and let the user rename/delete saved recordings from the conversations list and recording detail screen.

## Context

The subscription card already shows recording usage above the subscription section, so duplicate rows in Settings create noise. Saved recordings can be opened, edited at the transcript/speaker level, and summarized, but there is no obvious user-facing way to rename or delete whole recordings.

## Scope

In scope:
- Simplify the Settings subscription and memory sections.
- Add backend meeting title update and deletion endpoints.
- Add iOS service/store support for renaming and deleting meetings.
- Add swipe/context actions on the conversations list.
- Add a three-dot menu in recording detail with title editing.

Out of scope:
- Bulk delete, archival, or retention policy.
- Reprocessing deleted recordings.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Add backend schemas/storage/routes for meeting rename and delete.
- [x] Wire iOS meeting service/store rename/delete methods.
- [x] Clean up Settings rows.
- [x] Add conversation list swipe/context actions and detail menu rename.
- [x] Run backend and iOS verification, deploy backend if endpoints changed, and install the app if requested or needed for review.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-rename-delete-smoke python3 - <<'PY' ...` verified meeting title update, missing-meeting rename, delete, and repeated delete behavior against SQLite.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Remote deploy to `51.195.200.207`: backed up previous backend at `/home/ubuntu/meta-ios-deploy-backups/backend-20260515-071133-ios18-recording-management.tgz`, copied `app/main.py`, `app/schemas.py`, and `app/services/storage.py`, removed macOS AppleDouble `._*` tar artifacts, compiled remote backend, restarted `meta-ios-backend.service`, verified `/health`, and verified OpenAPI exposes `GET`, `PATCH`, and `DELETE` on `/v1/meetings/{meeting_id}`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `/usr/libexec/PlistBuddy -c 'Print :BackendAPIURL' -c 'Print :PlusSubscriptionProductID' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`

## Result

Settings subscription now shows a single `Billing` row instead of duplicate recording-minute and Ask AI rows. The `memory & data` section no longer shows `Conversations`, `Auto-delete after`, or `Clear by topic`.

The backend now supports authenticated `PATCH /v1/meetings/{meeting_id}` with `{ "title": "..." }` and authenticated `DELETE /v1/meetings/{meeting_id}`. Delete removes the meeting row and linked server audio when present.

iOS now supports meeting rename/delete through `MeetingsStore`. The conversations list has long-press context menu actions plus swipe actions: leading swipe for rename and trailing destructive swipe for delete. The recording detail screen has a top-right three-dot menu with rename and delete actions; rename opens a title editor and persists through the backend.

Follow-up polish: the recording detail three-dot menu icon is smaller and no longer has a visible circular outline.

The updated backend is live on `51.195.200.207`, and the updated iOS build was installed and launched on `iPhone (Yerasyl)`.

## Next

Result is ready for human review on the installed iPhone app. Human review: open Settings and confirm the removed rows are gone; open Conversations and long-press or swipe a recording to confirm rename/delete; open a recording detail and use the top-right three-dot menu to rename the title. After approval: commit, push/PR only if requested, then archive/update task state.

# IOS-17: Add StoreKit Plus Subscription Purchase Flow

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-14

## Goal

Replace the temporary default-plus entitlement with a real StoreKit-backed plus subscription flow: unpaid users remain free, paid users get 600 recording minutes and Ask AI.

## Context

`IOS-16` added subscription limits and Ask AI gating, but intentionally kept StoreKit, App Store receipt/JWS validation, and real payment capture out of scope. The user noticed the gap because new users defaulted to plus before any payment. This task brings payment validation into scope.

## Scope

In scope:
- Make default backend entitlement `free`, not plus.
- Add a StoreKit 2 plus purchase and restore flow in the iOS app.
- Send verified StoreKit signed transactions to the backend.
- Validate Apple-signed transactions on the backend using Apple App Store Server verification.
- Persist Apple subscription transaction data and grant plus only while the transaction is active.
- Keep the old manual entitlement switch out of normal iOS UI.
- Document App Store Connect product ID and backend certificate setup.

Out of scope:
- Creating the App Store Connect subscription product from the agent.
- App Store Server Notifications V2 webhook handling.
- Production App Store API private keys/history lookups beyond device-submitted signed transactions.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Verify current Apple StoreKit/App Store Server validation guidance from official sources.
- [x] Add backend Apple transaction validation, storage, and active-entitlement derivation.
- [x] Change backend/iOS defaults to free until a paid entitlement is validated.
- [x] Add iOS StoreKit product loading, purchase, and restore paths.
- [x] Replace the Settings plus action with purchase/restore controls.
- [x] Add a visible Billing sheet so Recordings/Settings purchase actions always surface plan state, errors, and restore.
- [x] Run backend/iOS verification and deploy the backend.
- [x] Install the updated app on the iPhone after CoreDevice reconnects.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-storekit-subscription-smoke python3 - <<'PY' ...` verified default free, manual override source, active Apple transaction source, and active plus derivation from stored Apple transaction expiry.
- `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `/usr/libexec/PlistBuddy -c 'Print :PlusSubscriptionProductID' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- Remote deploy to `51.195.200.207`: backed up previous backend at `/home/ubuntu/meta-ios-deploy-backups/backend-20260514-183854-ios17-storekit.tgz`, installed `app-store-server-library`, downloaded Apple root certificates to `/etc/meta-ios-app-store-roots`, updated `/etc/meta-ios-backend.env`, compiled backend, verified `/v1/subscription/apple-transaction` route import, restarted `meta-ios-backend.service`, and verified public `GET /health`.
- `curl -i http://51.195.200.207:8787/v1/subscription` returns `401 Missing bearer token`, and OpenAPI includes `/v1/subscription/apple-transaction`.
- `git diff --check`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app` installed the updated app on `iPhone (Yerasyl)`.
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` launched the updated app.
- Follow-up StoreKit product-preload polish: `python3 -m compileall her-ios/backend/app`, `git diff --check`, `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`, `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`, `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`, and `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :PlusSubscriptionProductID' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`.
- Follow-up device install attempt failed because CoreDevice listed `iPhone (Yerasyl)` as `unavailable`: `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`.
- Follow-up country price-list fallback: parsed `/Users/ekenesbek/Downloads/Starting Subscription Price.csv` into `PlusSubscriptionPriceList`, verified 175 country-code prices with `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist` and a plist smoke check (`KZ KZT 9990`, `US USD 17.99`, `GB GBP 17.99`, `TR TRY 999.99`, `JP JPY 3000`), then ran `python3 -m compileall her-ios/backend/app`, `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`, `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`, `/usr/libexec/PlistBuddy -c 'Print :PlusSubscriptionProductID' -c 'Print :PlusSubscriptionPriceList' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`, `git diff --check`, and `xcrun devicectl list devices` showed `iPhone (Yerasyl)` still `unavailable`.
- Follow-up StoreKit unavailable copy: `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`, `python3 -m compileall her-ios/backend/app`, `git diff --check`, `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`, `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`, plist smoke for bundle/product/175 prices, `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`, and `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`.
- First App Store Connect build upload: changed iOS marketing version to `1.0` to match the App Store Connect version page, ran `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Release -destination 'generic/platform=iOS' -archivePath her-ios/frontend/Build/Archives/Her.xcarchive -allowProvisioningUpdates archive`, then uploaded with `xcodebuild -exportArchive -archivePath her-ios/frontend/Build/Archives/Her.xcarchive -exportPath her-ios/frontend/Build/AppStoreExport -exportOptionsPlist /tmp/HerExportOptions.plist -allowProvisioningUpdates`. Upload succeeded and App Store Connect reported the package is processing. Warning: symbol upload failed for `MWDATCore.framework` because the archive did not include that framework's dSYM.

## Result

Backend users now default to `free`, not plus. Plus entitlement is derived from an active, non-revoked Apple subscription transaction stored in `apple_subscription_transactions`, or from an explicit manual override only when `LOCAL_SUBSCRIPTION_OVERRIDES_ENABLED=true`. The normal backend override endpoint is disabled on the deployed server.

iOS now uses StoreKit 2 for plus: Settings loads the plus product from `PlusSubscriptionProductID`, shows a buy action, handles purchase success/cancel/pending states, sends StoreKit's signed transaction JWS from the `VerificationResult` to `/v1/subscription/apple-transaction`, and offers `Restore purchase` using `Transaction.currentEntitlements`. Ask AI's free paywall now starts the same purchase path instead of silently switching entitlement.

iOS now opens a visible Billing sheet from both the Ask AI paywall and Settings. Settings shows one `Billing` row under subscription instead of separate buy/restore rows; the sheet shows the current Free plan, the Plus plan with 600 minutes/month and Ask AI, purchase/restore actions, and any StoreKit/backend error message.

Follow-up polish: Settings no longer surfaces background StoreKit product-preload failures as a transient red error banner; StoreKit availability errors remain visible when the user explicitly taps the Plus purchase action.

Follow-up pricing fallback: Billing now uses StoreKit's real `Product.displayPrice` when available, and otherwise falls back to `PlusSubscriptionPriceList` from `Info.plist`, keyed by App Store storefront country code first and device locale country second. The fallback list is generated from the user's App Store Connect CSV price list and currently contains 175 country-code prices, including `KZ = KZT 9990`, `US = USD 17.99`, `GB = GBP 17.99`, `TR = TRY 999.99`, and `JP = JPY 3000`.

Follow-up StoreKit unavailable copy: the app no longer tells the user to create the App Store Connect product after StoreKit returns no product. The purchase error now says StoreKit returned no product for the configured ID and points to first-version attachment or sandbox propagation.

The first App Store Connect build upload for iOS version `1.0` succeeded. The build is processing in App Store Connect and should be selectable on the version page once processing finishes.

The deployed backend on `51.195.200.207` has the StoreKit endpoint, Apple root certificates, and the Apple App Store Server Library installed. Real purchases still require the matching App Store Connect auto-renewable subscription product `com.ekenesbek.her.plus.monthly` to exist for the app.

## Next

Result is ready for human review on the installed iPhone app. Human review: open a recording's chat tab and tap `view billing`; confirm the Billing sheet opens. Then open Settings → subscription → `Billing`; confirm it shows Free as current, Plus with 600 min/mo and Ask AI, and purchase/restore actions. Tap the Plus purchase action and confirm StoreKit either shows the configured sandbox product or reports a visible error if App Store Connect has not propagated the product. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

# IOS-16: Add Subscription Limits And Ask AI Entitlement

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-14

## Goal

Add subscription behavior for the iOS recorder: free users get 60 recording minutes, plus users get 600 recording minutes and Ask AI.

## Context

The app already has authenticated users, saved meetings with durations, recording jobs, summaries, and a meeting chat tab that functions as Ask AI. There is no StoreKit product setup or paid subscription backend yet, so this task should add local entitlement and usage enforcement without pretending a real App Store purchase flow exists.

## Scope

In scope:
- Add a backend subscription/entitlement model with `free` and `plus` plans.
- Count monthly recording usage from saved meetings and expose remaining minutes.
- Enforce the free 60-minute and plus 600-minute recording limits on backend recording ingestion.
- Gate meeting Ask AI/chat to plus users.
- Show the plan and minutes in iOS settings.
- Block the Ask AI UI on free with an upgrade prompt.

Out of scope:
- StoreKit product IDs, App Store receipt validation, server-to-server notifications, or real payment capture.
- Stage 2 scheduled/background runs or credential-vault behavior.
- Cloud subscription sync; the local backend remains the stage 1 source of truth.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Inspect existing auth, recording job, meeting duration, and chat paths.
- [x] Add backend subscription schemas/storage helpers/endpoints.
- [x] Enforce recording-minute and Ask AI entitlements in backend endpoints.
- [x] Add iOS subscription service/store and surface usage in Settings.
- [x] Gate recording and Ask AI affordances in the iOS UI.
- [x] Run backend and iOS verification.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-subscription-storage-smoke python3 - <<'PY' ...` storage smoke verified default plus plan, plus plan update, and monthly recording usage from saved meetings.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `lsof -nP -iTCP:8787 -sTCP:LISTEN || true` showed no local backend listening on port 8787 during verification.
- Attempted a full FastAPI `TestClient` subscription smoke, but the ambient pyenv Python is missing `jwt`/PyJWT, so importing `app.main` failed before the app could start.
- `curl -i http://51.195.200.207:8787/v1/subscription` initially returned `404 Not Found`, explaining the installed app's `Subscription backend returned an error.` banner.
- Deployed `app/main.py`, `app/schemas.py`, and `app/services/storage.py` to `51.195.200.207`; previous backend files were backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260514-182020-ios16-subscription.tgz`.
- Remote verification on `51.195.200.207`: `.venv/bin/python -m compileall app`, FastAPI route import check for `/v1/subscription`, `systemctl restart meta-ios-backend.service`, `GET /health`, unauthenticated `GET /v1/subscription` returns `401 Missing bearer token` instead of `404`, OpenAPI includes `/v1/subscription`, and production SQLite contains `user_subscriptions`.

## Result

Added a local backend subscription contract for authenticated users. `GET /v1/subscription` returns plan, monthly recording limit, used/remaining seconds, Ask AI entitlement, and the active calendar-month window. `PATCH /v1/subscription` switches the local entitlement between `free` and `plus` until real StoreKit purchase/receipt validation is wired. Free is 60 recording minutes per month. Plus is 600 recording minutes per month and enables Ask AI. New users default to plus while the MVP is being tested.

Backend recording ingestion now checks remaining monthly minutes for `/v1/transcriptions`, `/v1/meetings/process`, `/v1/meetings/jobs`, and direct `/v1/meetings` saves. Ask AI meeting chat endpoints now require the plus entitlement. The backend README documents the temporary local entitlement switch and limits.

iOS now has a `SubscriptionStore` backed by `/v1/subscription`. Settings shows the current plan, recording usage, remaining minutes, and Ask AI status. The recording entrypoint blocks when no minutes remain. The conversation chat tab shows an Ask AI plus prompt for free users and keeps the chat UI available only when plus is enabled. If the subscription endpoint is stale or unavailable, Settings shows the backend error and falls back to plus with local usage computed from loaded meetings.

The updated backend is deployed on `51.195.200.207`. The installed iPhone build points to that server, so the previous Settings error was caused by the remote backend still returning `404` for the new subscription endpoint.

Known limitation: this does not implement StoreKit products, payment capture, receipt validation, or App Store server notifications. The current `Switch to plus` action switches the local backend entitlement for MVP testing.

## Next

Result is ready for human review. Review gate: reopen Settings on the installed iPhone app and confirm the subscription banner is gone, the default plan is plus with 600 min/mo and Ask AI on, and the recorded-meeting usage is reflected in the remaining minutes. Record a short meeting and confirm usage increments from loaded meetings; force a free plan only for testing and confirm the chat tab shows the plus prompt. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

# IOS-15: Make Recording Jobs Transcript-First And Add People Settings

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-14

## Goal

Keep the post-recording flow on the recording screen while transcription runs, save the transcript as soon as it is ready, and make summary generation a separate user action. Add People to settings with a dedicated page for the current user and recognized speakers.

## Context

The iOS recording screen already has a transcribing/loading state and a `Generate summary` action after transcript readiness, but backend meeting jobs still generated summaries during job completion. That made the user wait for summary work before the recording job finished. Settings already listed voice profiles, but the section was framed narrowly as `voice profile` instead of a People area.

## Scope

In scope:
- Let meeting jobs accept `generate_summary=false`.
- Have the iOS recording job submit transcript-first jobs.
- Keep/open the recording screen while current recording processing is transcribing or summarizing.
- Keep the recording screen open while transcription/summary work is loading, then open the saved recording detail when the processed meeting is available.
- Show a street-level recording location when Core Location returns address details.
- Rename the voice-profile settings section to People and keep voice profiles there.
- Open People from Settings into a dedicated page with the current user shown as `(you)` and recognized voice profiles / transcript speaker labels listed separately.
- Remove the Add/Update your voice action from Settings and the People page.
- Remove the separate Glasses settings block.
- Clarify the profile-card storage status so it does not imply storage is unavailable.
- Document the transcript-first job flag.

Out of scope:
- Full contact/person management beyond the current user plus recognized speaker profiles.
- Stage 3 memory graph behavior.
- Removing the existing generated-summary endpoint.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Inspect the existing recording, job polling, summary generation, and settings People/voice-profile surfaces.
- [x] Add a backend `generate_summary` job flag with a storage migration/default.
- [x] Send `generate_summary=false` from iOS recording jobs.
- [x] Route current recording processing back to the recording screen for loading.
- [x] Open the saved recording detail after transcript-ready/completed processing instead of leaving users on the processing screen.
- [x] Increase location precision and format recording locations as street address plus city.
- [x] Update settings copy/layout so voice profiles live under People.
- [x] Add a dedicated Settings People page with the current user, recognized voice profiles, and saved transcript speaker labels.
- [x] Remove Add/Update your voice from Settings and the People page.
- [x] Run backend and iOS verification.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-job-summary-smoke python3 - <<'PY' ...` storage smoke verified `create_meeting_job(..., generate_summary=False)` persists `generate_summary=0`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` failed because the iPhone was locked; install succeeded.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `git diff --check`

## Result

Backend meeting jobs now accept `generate_summary=false`; old clients keep the previous default `true`. When false, the job saves the transcript, outline, audio link, and an unavailable summary placeholder, so the existing `POST /v1/meetings/{id}/summary` endpoint can generate the real summary later.

iOS recording jobs now submit `generate_summary=false`, so stopping a recording should finish once transcription is saved instead of waiting for summary generation. Stop Recording now immediately keeps the user on the recording screen while transcribing/summarizing work is loading. Once the backend returns the saved meeting id and the session reaches transcript-ready or completed, the app refreshes saved meetings, selects that meeting, and opens the normal recording detail page instead of leaving users on the processing screen with `Summary ready`. Settings now has a People section backed by saved voice profiles and saved transcript speaker labels. Tapping People opens a dedicated page that shows the current user as `Name (you)` and lists recognized speakers separately. The Add/Update your voice action was removed from Settings and the People page. The separate Glasses settings block was removed, and the profile-card storage status now reads `local backend` / `active` instead of `storage unavailable`.

Recording location lookup now asks for nearer-ten-meter accuracy and formats available address components as street/house plus city, for example `Koshek Batyr 14, Almaty`, falling back to named place or city when iOS does not return street details.

Known limitation: the updated app was installed and launched on the paired iPhone, but a real end-to-end recording was not exercised from this environment.

## Next

Result is ready for human review. Review gate: run a real recording, stop it, confirm the Recording screen shows transcription loading, and confirm that when processing finishes it opens the saved recording detail page rather than staying on the `Summary ready` processing screen. Confirm the location label is street-level when precise location is available, and that Summary is generated only after pressing the button. Also open Settings -> People and confirm the page shows `Username (you)` first, recognized speakers below, no Add/Update your voice button, the Glasses block is gone, and storage reads as local backend active. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

# IOS-14: Connect Sign In With Apple Entitlement

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-14

## Goal

Make the existing iOS Apple sign-in code usable by ensuring the app target is signed with the Sign in with Apple entitlement and the backend auth audience is documented.

## Context

The app already has `AppleSignInService`, an Apple provider button on the onboarding account screen, an entitlements plist containing `com.apple.developer.applesignin`, and a FastAPI `POST /v1/auth/apple` endpoint that validates Apple identity tokens. The missing project wiring was that the target build settings did not point at the entitlements file, so the app could build without the capability being included in the signed target.

## Scope

In scope:
- Attach `ConversationSummarizer.entitlements` to the iOS app target for Debug and Release.
- Mark Sign in with Apple as an enabled target capability in the Xcode project.
- Document backend auth env values needed for Apple token validation.

Out of scope:
- Stage 2 credential-vault behavior or Apple Passwords integration.
- Changing the Apple/Google auth API contract.
- Verifying a live Apple account prompt on a physical device when the device is unavailable.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Inspect the existing iOS Apple sign-in service, auth client, entitlement plist, and backend auth endpoint.
- [x] Wire the entitlement plist into target build settings.
- [x] Add backend auth env examples for `APPLE_CLIENT_ID` and session token signing.
- [x] Run iOS/backend verification and record limitations.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -showBuildSettings | rg -n "CODE_SIGN_ENTITLEMENTS|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM"`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=00008140-00114D90227B001C' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build` attempted for iPhone install and failed because the provisioning profile does not include Sign in with Apple.
- Reattempted after Apple Developer/Xcode account work. The old cached profile was backed up out of Xcode's active profile directory; `xcodebuild` still reports `No Accounts` and cannot download a new `com.ekenesbek.her` development profile.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build` later succeeded with Apple Development signing and `com.apple.developer.applesignin` in the built app entitlements.
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app` failed because the iPhone was offline/unavailable to CoreDevice.
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app` succeeded after the iPhone returned to `available (paired)`.
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` succeeded.
- `git diff --check`

## Result

The Xcode target now uses `ConversationSummarizer/Resources/ConversationSummarizer.entitlements` for Debug and Release, and target attributes show Sign in with Apple enabled. The backend env example now documents `AUTH_JWT_SECRET`, `APPLE_CLIENT_ID=com.ekenesbek.her`, and `GOOGLE_CLIENT_IDS`.

Known limitation: the app is installed and launched on the iPhone, but live Apple sign-in flow still needs human review on-device.

## Next

Result is ready for human review. Review gate: on the installed iPhone build, tap Continue with Apple and verify the session reaches onboarding/app, then check Settings for the People section and local backend storage status. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

# IOS-12: Add Omi-Style Transcription Providers And GPU Service

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Make Her's Stage 1 meeting backend able to use a paid diarizing STT provider or a separate GPU-hosted transcription service while preserving the current local WhisperX path as the fallback.

## Context

Omi's backend separates real-time/pre-recorded STT, diarization, and speaker embedding into provider-backed services. Her currently runs transcription and diarization inside the iOS FastAPI backend, which is slow on CPU and makes it harder to swap in a paid API or GPU worker.

## Scope

In scope:
- Add a backend transcription provider switch for `local`, `deepgram`, and `external`.
- Add a Deepgram pre-recorded transcription adapter with diarization output mapped to Her transcript segments.
- Add an external HTTP transcription adapter for a GPU service running on port 8000.
- Add a minimal standalone GPU STT service with Omi-like health, transcription, diarization, and embedding endpoints.
- Add an adaptive single-speaker retry so auto diarization stays the default but suspicious one-speaker long recordings get one validation pass.
- Keep the existing file-upload and meeting-job API contracts.

Out of scope:
- Stage 2 scheduled/background runs or credential vault behavior.
- Stage 3 cross-meeting/global memory.
- Removing local WhisperX before the external provider is proven on real recordings.

## Implementation Plan

- [x] Inspect current transcription, diarization, settings, and task state.
- [x] Add provider settings and health visibility.
- [x] Add Deepgram and external transcriber adapters.
- [x] Add standalone GPU service skeleton.
- [x] Add adaptive single-speaker diarization retry for auto mode.
- [x] Update docs/env examples.
- [x] Run backend compile and adapter smoke tests.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `python3 -m compileall her-ios/stt-service`
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` Deepgram response parser smoke using representative diarized `utterances`, word-level payloads, and multilingual `languages` output.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` external adapter smoke using a mocked `httpx.Client`.
- `PYTHONPATH=her-ios/backend TRANSCRIPTION_PROVIDER=external EXTERNAL_TRANSCRIPTION_URL=http://127.0.0.1:8000 python3 - <<'PY' ...` verified provider selection builds `ExternalTranscriber`.
- `PYTHONPATH=her-ios/stt-service python3 - <<'PY' ...` verified GPU service import and `/health` shape. The ambient pyenv printed its existing `hashlib` blake2 warnings, but assertions passed.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `git diff --check`
- Deployed `her-ios/stt-service` and backend code to `82.200.144.228` under `/opt/her-stt-service`, installed Python/CUDA dependencies in a venv, copied the existing Hugging Face token from the old backend server without printing it, created and enabled `her-stt.service`, and verified public `GET http://82.200.144.228:8000/health`.
- GPU smoke on `82.200.144.228`: full `/Users/ekenesbek/Downloads/Кошек_батыра_улица_50.mp3` returned in one request with `durationSeconds=912.2333125`, `segmentCount=218`, speakers `SPEAKER_00` and `SPEAKER_01`, and segment counts `SPEAKER_00=140`, `SPEAKER_01=78`.
- Deployed the provider-router backend update to `51.195.200.207`; previous backend files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-215916-external-stt.tgz`.
- Set the main backend runtime env to `TRANSCRIPTION_PROVIDER=external`, `EXTERNAL_TRANSCRIPTION_URL=http://82.200.144.228:8000`, restarted `meta-ios-backend.service`, and verified `GET /health` returns `transcriptionProvider=external`.
- Main backend smoke on `51.195.200.207`: building `Settings()` from `/etc/meta-ios-backend.env` creates `ExternalTranscriber`, and a 30-second excerpt transcribed through the GPU service with language `ru`.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` adaptive diarization helper smoke verified one-speaker auto results trigger retry, durable two-speaker retries are accepted, tiny false speakers are rejected, and explicit min/max settings disable the retry.
- `python3 -m compileall her-ios/backend/app her-ios/stt-service`
- `PYTHONPATH=her-ios/stt-service python3 - <<'PY' ...` verified `/health` shape exposes diarization min/max and retry status. The ambient pyenv printed its existing `hashlib` blake2 warnings, but assertions passed.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` verified the new retry settings load from `Settings()`.
- `git diff --check`
- Not deployed: SSH to `82.200.144.228` was denied for available local keys and from the main backend host, so the live GPU STT service still needs this code copied/restarted before new device recordings use it.

## Result

Added `TRANSCRIPTION_PROVIDER=local|deepgram|external`. The existing iOS backend endpoints keep their file-upload/job contracts, but transcriber construction now routes through a provider factory. `/health` now exposes the active `transcriptionProvider`.

Added a Deepgram pre-recorded STT adapter. It posts completed audio to `/v1/listen` with `nova-3`, diarization, utterances, punctuation, and smart formatting enabled; Deepgram speaker ids are normalized into Her's `SPEAKER_00` format and materialized as `TranscriptSegment` rows. The default `DEEPGRAM_LANGUAGE=multi` avoids English-only behavior for mixed-language recordings.

Added an external GPU adapter. The main backend can now delegate transcription to `EXTERNAL_TRANSCRIPTION_URL/v1/transcribe` and parse the same `TranscriptResponse` shape it already uses locally.

Added `her-ios/stt-service`, a standalone FastAPI service intended for a GPU host on port 8000. It exposes `GET /health`, `POST /v1/transcribe`, `POST /v1/diarization`, `POST /v1/embedding`, and `POST /v2/embedding`, reusing the backend WhisperX transcriber for full transcription and pyannote endpoints for diarization/embeddings.

Added adaptive one-speaker retry inside the shared WhisperX transcriber. The first diarization pass remains auto speaker-count mode. If a long recording returns no durable second speaker, the backend runs one validation diarization pass with `min_speakers=2` and the configured retry max, then accepts it only when it produces at least two durable speakers without losing most speech coverage. This keeps `Design Discussion`-style successful auto results unchanged while giving collapsed iPhone recordings a recovery path.

Docs and env examples now describe local, Deepgram, and external GPU modes. `httpx` was added to backend dependencies for the paid/external adapters.

Deployed the GPU STT service to `82.200.144.228:8000` and switched the main iOS backend on `51.195.200.207` to use it through `TRANSCRIPTION_PROVIDER=external`. The SSH host key fingerprint `SHA256:WwT06DiGy0GLlKpGP0qeNZOiIhKsleyylDWZe1nqlKQ` was confirmed by the human before updating `known_hosts`.

## Next

Result is ready for human review. Review gate: deploy the updated shared backend code to the GPU STT host, restart `her-stt.service`, then record or upload a new multi-speaker meeting through the iOS app and confirm the saved transcript alternates speakers and finishes much faster than the old CPU path. After approval: commit, push/PR only if requested, then archive/update task state.

# IOS-11: Add Streaming Audio Processing For Faster Transcription

Status: planned
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Reduce meeting processing latency by streaming audio chunks from the iOS app to the local backend during or immediately after capture, instead of waiting for one full `.m4a` upload before transcription starts.

## Context

The current Stage 1 recorder path captures a meeting on-device, stops recording, uploads the completed audio file, then the backend transcribes it with `faster-whisper` and summarizes the final transcript. This is simple but slow for longer meetings because no backend work begins until recording ends and upload completes.

`her-ios/ROADMAP.md` already calls out an eventual `/v1/transcribe/stream` path with `AVAudioEngine` -> WebSocket -> backend streaming. This task promotes the Stage 1 portion into the active todo stream: speed up local transcription while preserving the current file-upload flow as a fallback.

## Scope

In scope:
- Add a local backend streaming transcription endpoint, likely WebSocket-based, for chunked audio ingestion.
- Add an iOS streaming sender path using `AVAudioEngine` or another route-compatible capture pipeline.
- Start backend decoding/transcription work before the full recording is complete.
- Preserve the existing `.m4a` upload endpoint as a fallback and compatibility path.
- Store the final transcript, summary, audio metadata, and errors in the existing meeting storage model.
- Measure and log latency improvements such as time-to-first-transcript and total processing time.

Out of scope:
- Cloud-only transcription or hosted streaming infrastructure.
- Scheduled/background autonomous runs or vault-driven credentials.
- Real-time wearable voice-agent playback through glasses.
- Requiring a paid external streaming provider before the local path is evaluated.
- Removing the existing file upload path before the streaming path is stable.

## Implementation Plan

- [ ] Inspect the current iOS recorder, upload client, backend transcription endpoint, and meeting storage flow.
- [ ] Choose the local streaming strategy: true incremental Whisper streaming, chunked local transcription with overlap, or a staged adapter that can later swap in `whisper-streaming`.
- [ ] Add the backend streaming endpoint and chunk/session lifecycle handling.
- [ ] Add the iOS capture/sender implementation with fallback to full-file upload.
- [ ] Wire partial/final transcript state into the existing meeting result flow.
- [ ] Add latency logging and focused backend/iOS smoke checks.
- [ ] Validate on simulator where possible and on a physical iPhone for real audio-route behavior.

## Verification

- `python3 -m compileall her-ios/backend/app`
- Backend smoke: stream a fixture or short generated audio sample through the new endpoint and verify final transcript/session persistence.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Manual device smoke: record a short meeting, confirm transcription starts before recording/upload completion, and verify fallback upload still works.

## Result

Not started.

## Next

Needs human review of the task scope. After approval: implement the smallest coherent local streaming path in the current worktree, then stop again for result review before commit/push/PR/archive.

# BUG-2: Clean AI Summaries And Add Audio Scrubber

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-10

## Goal

Stop AI summaries from treating machine speaker labels as real meeting topics, improve default multi-speaker diarization on the deployed backend, and add a draggable audio track in the contents view.

## Context

A real 3-speaker recording produced mostly `Speaker 1` rows and an AI title/key topic like `Interview with SPEAKER_00`. The raw diarization labels are implementation details, not semantic content, and the contents audio row currently only has a play button plus duration instead of a scrubber.

## Scope

In scope:
- Remove raw `SPEAKER_00` / `Speaker 1` labels from summary prompt inputs and sanitize LLM summary output.
- Make summary titles fall back to transcript content when the AI returns a speaker-label-based title.
- Tune deployed diarization speaker-count settings for multi-person meetings.
- Add a draggable audio scrubber/progress track in the iOS contents audio row.
- Clean up the recording/transcribing page duplicate processing dock and make the contents audio controls compact/collapsible.
- Fix speaker assignment so backend transcript segments preserve pyannote speaker turns without relying on fixed `DIARIZATION_MIN_SPEAKERS` / `DIARIZATION_MAX_SPEAKERS` values.

Out of scope:
- Reprocessing old meetings automatically.
- Guaranteed exact speaker count for every recording without a user-provided expected speaker count.

## Implementation Plan

- [x] Patch backend summary formatting/prompt/output normalization.
- [x] Patch local fallback titles to ignore speaker labels.
- [x] Add iOS scrubber seek UI and playback controller seek support.
- [x] Replace the plain scrubber with a waveform-style seek control backed by audio-file amplitude peaks.
- [x] Restyle the contents audio row toward the Sources-style player: top elapsed/total time, unboxed waveform, and transport controls below it.
- [x] Remove duplicated transcribing status, collapse duplicate expand controls into one toggle, shrink audio transport controls, and restore iOS playback session setup.
- [x] Verify backend/iOS builds and deploy backend.
- [x] Patch WhisperX/pyannote assignment to assign speakers at word level and split transcript segments when the speaker changes inside one Whisper segment.
- [x] Add double-tap transcript text editing with persisted meeting segment updates.
- [x] Replace speaker double-tap rename with a single-tap bottom-sheet rename flow.
- [x] Compact the speaker rename popup, keep keyboard Done from saving, and use the signed-in username chip.
- [x] Add word-by-word blue playback progress inside the active transcript chunk.
- [x] Add a small readable lead to transcript word highlighting so it does not feel behind audio.
- [x] Preserve chat message line breaks when rendering markdown-formatted answers.
- [x] Install iOS app after the physical iPhone is available to CoreDevice.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` summary sanitizer smoke: `SPEAKER_00` is hidden from summary input and `Interview with SPEAKER_00` falls back to transcript content.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the waveform scrubber update.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the Sources-style audio row update.
- Deployed backend to `51.195.200.207`; previous backend files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-155126-bug2-summary-scrubber.tgz`.
- Remote backend compile, `systemctl restart meta-ios-backend.service`, `GET /health`, and remote summary sanitizer smoke.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` word-level diarization assignment smoke verified one Whisper segment is split into `SPEAKER_00` and `SPEAKER_01` turns by diarization overlap.
- `python3 -m compileall her-ios/backend/app/services/diarizer.py`
- Server smoke on `/Users/ekenesbek/Downloads/Кошек_батыра_улица_50.mp3` copied to `/tmp/koshek_batyra_50.mp3`: a 180-second excerpt with `DIARIZATION_MIN_SPEAKERS=0` and `DIARIZATION_MAX_SPEAKERS=0` produced pyannote speakers `SPEAKER_00` and `SPEAKER_01`; patched assignment was run 3 times and consistently returned 57 transcript segments split across both speakers (`SPEAKER_00`: 30, `SPEAKER_01`: 27).
- Deployed `app/services/diarizer.py` to `51.195.200.207`, backed up the previous file at `/home/ubuntu/meta-ios-deploy-backups/diarizer-20260510-183913.py`, compiled it on the server, restarted `meta-ios-backend.service`, and verified `GET /health`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the recording/transcribing and audio control cleanup.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after adding word-by-word blue playback progress inside the active transcript chunk.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after preserving chat markdown line breaks.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build` after preserving chat markdown line breaks.
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after adding a readable lead to transcript word highlighting.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after compacting the speaker rename popup, changing keyboard Done to dismiss focus only, applying a 75% sheet detent, and replacing the hardcoded self-name chip with the current username.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after switching speaker rename to single tap with a bottom-sheet style popup.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after making repeat single-tap on the active transcript text pause playback.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after switching playback to interrupt other audio and reapplying speed after play.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `python3 -m compileall her-ios/backend/app` after the transcript edit endpoint update.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` storage smoke verified `update_meeting_transcript` updates transcript/segments for the correct user and returns `None` for a missing meeting.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the double-tap transcript editor update.
- Deployed `app/main.py`, `app/schemas.py`, and `app/services/storage.py` to `51.195.200.207`; backup created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260511-170746-transcript-edit.tgz`.
- Remote backend compile, `systemctl restart meta-ios-backend.service`, `GET /health`, `systemctl is-active meta-ios-backend.service`, and OpenAPI route check verified `PATCH /v1/meetings/{meeting_id}/transcript`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after switching transcript text edits to inline keyboard editing, speaker renaming to popup, and timestamp playback to continuous mode.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`

Blocked:
- Full 15-minute mp3 diagnostic on the VPS was stopped after roughly 16 minutes because it was still in WhisperX ASR/VAD on CPU and produced no additional speaker-assignment signal beyond the completed excerpt run.
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` failed because the iPhone was locked. The updated app was installed successfully.

## Result

Backend summary input no longer exposes raw `SPEAKER_00` labels to the LLM; raw diarization labels are normalized to participant labels before summary generation. The summary prompt now explicitly forbids using machine speaker labels as titles, topics, overview content, or outline titles. The parser also sanitizes LLM output and replaces speaker-label-based titles like `Interview with SPEAKER_00` with transcript-derived content. Local fallback titles/key topics also ignore raw speaker labels.

The deployed server now has `DIARIZATION_MIN_SPEAKERS=2` and `DIARIZATION_MAX_SPEAKERS=6` in `/etc/meta-ios-backend.env` to reduce one-speaker collapse on multi-person meetings. This is a server default for new recordings, not a reprocessing of old meetings.

iOS contents audio row now has a draggable waveform scrubber instead of the plain system slider. The row renders an audio-shaped waveform, overlays played progress, supports tap/drag seeking to a precise timestamp, and computes real waveform peaks from the local or downloaded audio file when available. Playback still supports full audio, chunk playback, highlighted active transcript chunks, and backend download when local audio is missing.

The contents audio row was restyled toward the expected Sources/Transcript player: elapsed and total time are shown above the waveform, the waveform is no longer inside a bordered capsule, and playback controls now sit underneath with play/pause, 15-second seek backward/forward, speed cycling, and a waveform reload/expand-style icon.

The recording/transcribing screen no longer shows the duplicate bottom `Transcribing...` dock while the main transcribing card is visible. The contents audio row now has one compact chevron toggle that hides/shows the waveform and playback controls; the duplicate expand glyph was removed, and the play, ±15-second, and speed controls were reduced. Playback now explicitly activates an iOS `.playback` audio session before creating `AVAudioPlayer`, and local audio lookup falls back to discovering files under location-based `MeetingAudio/*/{meetingId}.*` folders when the stored UserDefaults path is stale.

Playback now uses `.playback` with no mix/duck options so other audio is interrupted while Her audio plays. Pause, stop, chunk end, and normal finish deactivate the session with `.notifyOthersOnDeactivation`. Playback speed is applied before `prepareToPlay()` and again immediately after `play()` so the selected rate takes effect on initial play, resume, chunk play, and scrub-resume.

Backend diarization assignment no longer depends on fixed speaker-count settings to preserve speaker turns. After `pyannote/speaker-diarization-3.1` returns intervals, the backend now reapplies those intervals to aligned WhisperX words by overlap/nearest interval and materializes separate transcript segments whenever the word-level speaker changes inside one Whisper segment. This prevents long Whisper segments from being saved as a single dominant `SPEAKER_00` when pyannote already found multiple speakers.

Transcript chunks can now be edited inline from the contents transcript. Single tap on transcript text plays audio from that timestamp continuously instead of stopping at the chunk end. Double tap replaces the text in place with a focused editor and opens the keyboard without a separate sheet. Saving updates the affected transcript segment range, rebuilds the meeting transcript text, updates local state, and persists the edit through the new authenticated `PATCH /v1/meetings/{meeting_id}/transcript` backend endpoint. The endpoint is deployed on `51.195.200.207`.

Speaker labels now open a bottom-sheet rename popup on single tap so a person's name can be entered for `Speaker 1`, `Speaker 2`, and similar labels. The popup uses a compact 75% sheet on supported iOS versions, includes an inline name field, a quick current-username chip, recent name suggestions, and an option to apply the name either only to the selected segment or to all segments from that speaker. Pressing Done on the keyboard now only dismisses the keyboard; saving still requires the Save button. The small timestamp play button and transcript text now start continuous playback from that timestamp; pressing either again while its row is active pauses audio at the current playback time. While audio is playing, the active transcript chunk now highlights elapsed words in blue based on playback progress with a small readable lead, and returns previous chunks to black when playback moves forward. Chat answers now render markdown lines explicitly so headings, numbered items, and paragraph breaks do not collapse into one unreadable block.

## Next

Result is ready for human review. Record or upload a new multi-speaker meeting through the server and verify the contents transcript shows alternating speaker turns instead of one speaker for the whole meeting; on the installed iPhone build, verify double-tap inline text editing saves and survives a conversation refresh, and single-tap speaker renaming opens the new popup. After approval: commit, push/PR only if requested, then archive/update task state.

# BUG-3: Recover Recording After Phone Interruptions

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-12

## Goal

When a phone call or iOS audio interruption stops microphone capture, Her must preserve the captured audio, stop showing fake elapsed recording time, and let the user either continue recording into the same meeting or finish and transcribe the captured audio.

## Context

A real meeting was interrupted by incoming calls. The recording UI later showed roughly 26-50 minutes, but the actual saved audio only contained the first ~2 minutes before the call. The current iOS recorder uses a wall-clock timer while recording and does not surface `AVAudioSession` interruption state, so the UI can imply audio exists after iOS has stopped microphone capture.

## Scope

In scope:
- Listen for iOS audio session interruptions while recording.
- Finalize the current audio segment when interruption begins.
- Show an interrupted/paused state with `Continue recording` and `Finish` actions.
- Resume into a new segment when the user chooses continue.
- Ensure elapsed time reflects real recorded audio duration, not wall-clock time.
- Transcribe the captured audio when the user chooses finish.

Out of scope:
- Blocking all incoming phone calls at the system level.
- Recording phone call audio.
- Cloud/background synchronization of interrupted recording state.

## Implementation Plan

- [x] Inspect current recorder, timer, and recording screen state.
- [x] Add recorder support for finalizing interrupted segments and measuring actual captured duration.
- [x] Add view-model interruption handling plus continue/finish actions.
- [x] Update recording UI copy and controls for the interrupted state.
- [x] Run iOS build, sign/install on the connected iPhone, and report risks.

## Verification

- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `git diff --check`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `python3 -m compileall her-ios/backend/app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` was attempted but iOS rejected the launch because the iPhone was locked. The updated app was installed successfully.
- 2026-05-17 recording stability follow-up: `git diff --check`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`; `python3 -m compileall her-ios/backend/app`.
- 2026-05-18 call/background-processing follow-up: `python3 -m compileall her-ios/backend/app`; `git diff --check`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`; `xcrun devicectl list devices`.
- 2026-05-18 iPhone install: `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`; `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`.
- 2026-05-18 independent background-processing UX follow-up: `git diff --check`; `python3 -m compileall her-ios/backend/app`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`; `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl list devices`.
- 2026-05-18 transcript-first detail/background follow-up: `rm -rf /tmp/her-ios-job-progress-smoke && mkdir -p /tmp/her-ios-job-progress-smoke && PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-ios-job-progress-smoke DIARIZATION_ENABLED=false python3 - <<'PY' ...`; `python3 -m compileall her-ios/backend/app`; `git diff --check`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`; `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`; `xcrun devicectl list devices`; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`.
- 2026-05-18 remote backend deploy to `51.195.200.207`: backed up previous files at `/home/ubuntu/meta-ios-deploy-backups/backend-20260518-142928-bug3-transcript-first.tgz`, copied `app/main.py` and `app/services/storage.py`, compiled remote backend, ran remote job-progress storage smoke, imported FastAPI routes for `/v1/meetings/jobs/{job_id}`, restarted `meta-ios-backend.service`, verified service `active`, and verified `GET /health` returns `200 OK` with `transcriptionProvider=external`, `summaryModel=gpt-oss`, and `openaiConfigured=true`.
- 2026-05-18 latest iPhone install after reconnect: `xcrun devicectl list devices` showed `iPhone (Yerasyl)` as `connected`; `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`; `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`.
- 2026-05-18 latest iPhone launch after unlock: `xcrun devicectl list devices` showed `iPhone (Yerasyl)` as `connected`; `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her` launched `com.ekenesbek.her`.

Not run:
- 2026-05-17 device install and real >8-minute recording smoke; `xcrun devicectl list devices` reported `iPhone (Yerasyl)` as `unavailable`.
- 2026-05-18 real phone-call interruption and real background upload/summary smoke on the installed iPhone build.
- 2026-05-18 reinstall after independent background-processing UX follow-up; `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app` failed because CoreDevice could not locate `iPhone (Yerasyl)`, and `xcrun devicectl list devices` showed it as `unavailable`.
- 2026-05-18 reinstall after the transcript-first detail/background follow-up; the signed app artifact is valid, but `xcrun devicectl list devices` still shows `iPhone (Yerasyl)` as `unavailable`, and install fails with CoreDevice error 1011.
- 2026-05-18 latest launch after successful install; iOS rejected the `devicectl` launch because `iPhone (Yerasyl)` was locked.

## Result

Implemented interruption recovery for the iOS recorder. `MeetingRecorder` now tracks completed recording segments, reports elapsed time from actual recorded audio duration, preserves interrupted segment paths for local recovery, and combines multiple segments into one `.m4a` before transcription. `ConversationSessionViewModel` listens for `AVAudioSession.interruptionNotification`; when iOS interrupts microphone capture, it finalizes the current segment, stops the real-duration timer, and moves the session into an `interrupted` phase. The recording screen now shows a paused/interrupted state with `Continue recording` and `Finish and transcribe` actions. Continuing starts a new segment in the same meeting; finishing transcribes the captured audio instead of relying on wall-clock time.

2026-05-17 follow-up: the wake-command Speech listener no longer starts a parallel stop-listener while `AVAudioRecorder` is recording. Wake commands can still start recording, but active meetings now keep the recorder as the sole microphone owner and require the on-screen Stop button. This avoids the likely failure mode where iOS Speech recognition ends or restarts during a long meeting and disrupts microphone capture around the 7-minute mark.

2026-05-18 follow-up: recovered pending uploads/jobs now retry in the background instead of taking over the current recording session as `transcribing`, and pending processing state now stores multiple recordings instead of a single slot. If a previous recording is still uploading or polling after the app is reopened, Her can start another recording while the previous backend job continues; when the previous job completes, the conversation list refreshes. Recording jobs now send `generate_summary=true`, restoring backend-owned summary generation for stopped recordings. The recorder also reconciles actual `AVAudioRecorder.isRecording` state on timer ticks and foreground return, so if iOS stops microphone capture without delivering the interruption notification in the active UI, the session moves into the interrupted state with Continue/Finish actions instead of continuing to show a fake active recording.

The updated Debug iOS build was signed, installed, and launched on `iPhone (Yerasyl)` on 2026-05-18. The installed bundle is `com.ekenesbek.her` and points to `http://51.195.200.207:8787`.

Follow-up behavior adjustment: stopping or finishing a recording now saves a pending background-processing entry, clears the recording flow to idle, and opens the recording detail screen immediately instead of a separate transcribing page. Pending entries also appear in Recent and Conversations with time, address/location, and upload/transcript/summary status, and another recording can start without waiting for upload, transcription, summary generation, or job polling. Tapping a pending row retries/resumes that background job if it is not already running.

Transcript-first detail follow-up: backend meeting jobs now publish progress in two phases. After transcription finishes, the worker creates the meeting, attaches audio, stores the transcript, and updates the job with `meeting_id` while the job remains `processing`; summary/title generation then continues against that saved meeting and marks the job `completed` only after the AI summary is written. The iOS job poller now fetches in-progress job snapshots, stores the `meetingId` as soon as transcript is available, and refreshes the selected detail screen on every processing update, including the later summary-ready update where the meeting id does not change.

The recording detail screen now handles all processing states in-place: Contents shows `Transcribing...` until transcript exists; Summary shows `Waiting for transcript` and then `Summarizing...`; Ask AI shows a disabled waiting card until the transcript-backed meeting exists. Once transcript arrives, Contents and Ask AI become available while Summary keeps loading. When AI summary/title/action items/follow-ups are ready, the same detail screen refreshes to the generated title and summary.

The backend side of this transcript-first job flow is deployed on `51.195.200.207`, which is the BackendAPIURL baked into the signed iOS build.

The latest Debug iOS build was installed on `iPhone (Yerasyl)` after the device reconnected. The first app launch command was rejected because the phone was locked; after unlock, `com.ekenesbek.her` launched successfully through `devicectl`.

## Next

Result is ready for human review once the latest signed artifact is installed. Reconnect/unlock `iPhone (Yerasyl)`, install the current build, start a recording, stop it, and verify the app opens the recording detail screen with in-place loading states while the main mic flow can start a second recording. Confirm the first recording shows transcript/Ask AI before summary, then refreshes to the backend-generated title, summary, action items, and follow-ups when AI finishes. Also trigger a real call/audio interruption and verify the screen shows `Recording paused` with `Continue recording` / `Finish and transcribe`. After approval: commit, push/PR if requested, then archive/update task state.

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
- Request real location access before recording when needed and store local/server meeting audio under a location bucket.
- Improve WhisperX diarization by using full-file speaker context and profile matching against transcript speaker labels.
- Group transcript rows into 3-5 sentence speaker-prioritized chunks.
- Add chunk playback from the contents transcript, with remote audio download when local audio is missing.
- Stop contents playback when the app leaves the foreground.
- Keep same-chunk playback responsive: immediate single tap, pause/resume at current time, and segment-aware blue progress.

Out of scope:
- Cloud sync beyond the current backend server.
- Reprocessing old meetings to recover audio already deleted by earlier backend versions.
- Perfect diarization for every acoustic environment; this still depends on pyannote/WhisperX model quality and voice enrollment quality.

## Implementation Plan

- [x] Add backend audio columns, storage helpers, and audio download route.
- [x] Preserve uploaded audio when meeting jobs/process endpoint complete.
- [x] Tie recording start to location permission/location refresh and store audio by location.
- [x] Adjust diarization/profile matching for full-meeting speaker consistency.
- [x] Add iOS audio download/playback controller and grouped transcript chunks.
- [x] Stop transcript/audio playback on iOS inactive/background lifecycle.
- [x] Tune transcript playback tap latency, resume behavior, and word progress timing.
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
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after adding lifecycle playback stop.
- `python3 -m compileall her-ios/backend/app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- `python3 -m compileall her-ios/backend/app` after adding location-scoped backend audio storage.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after adding location permission and local audio bucketing.
- Deployed `app/main.py` and `app/services/summarizer.py` to `51.195.200.207`; previous backend files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260511-055950-location-audio.tgz`.
- Remote backend compile, `location_bucket("Кошек батыра улица 50")` smoke, `systemctl restart meta-ios-backend.service`, and `GET /health` verified after deployment.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after same-chunk pause/resume and segment-aware progress changes.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`

Not run:
- Real multi-speaker recording review after deployment.
- Cross-device audio download playback, because only one physical iPhone is connected here.
- Launching the latest same-chunk pause/resume build through `devicectl`; installation succeeded, but CoreDevice lost the device before launch.

## Result

Backend meetings now keep original uploaded audio for completed `/v1/meetings/jobs` and `/v1/meetings/process` flows instead of deleting it. Completed audio is moved to `DATA_DIR/meeting-audio/{user_id}/{meeting_id}.*`, linked to the authenticated meeting row, exposed as `hasAudio=true`, and downloadable by the owning user at `GET /v1/meetings/{id}/audio`.

WhisperX no longer runs external chunk-level diarization when diarization is enabled; it transcribes the full file so pyannote/WhisperX has full-meeting speaker context. Added optional `DIARIZATION_MIN_SPEAKERS` and `DIARIZATION_MAX_SPEAKERS` knobs. Voice profile matching now first extracts embeddings from the actual transcript speaker time ranges, so enrolled-user matching aligns with the same speaker labels shown in the transcript. The pyannote fallback pipeline token argument was also fixed for the installed server version.

iOS contents now groups transcript display rows into speaker-prioritized chunks instead of rendering every raw sentence. A speaker change always starts a new chunk; same-speaker text is grouped into shorter chunks at sentence, pause, or duration boundaries. Tapping a chunk starts playback from that chunk; tapping the same active chunk pauses at the current audio time and keeps the blue progress visible; tapping it again resumes from the paused time. The tap path now preloads local audio and avoids waiting for the double-tap edit recognizer before starting playback. Blue word progress is now calculated against each transcript segment timestamp inside the chunk instead of linearly across the whole chunk. While audio is playing, the active chunk is highlighted and the scroll view follows it. Contents playback now stops when iOS moves Her to inactive/background, including while a playback request is still loading. If the local recording file is missing but the backend has audio, iOS downloads the meeting audio through the authenticated backend endpoint, saves it locally, and then plays it.

Recording start now asks for real iOS location access when authorization has not been decided yet, then refreshes the current city-level location while recording. The recording screen shows pending/unavailable location states instead of silently using no location. Local audio is moved into `Documents/MeetingAudio/{location-bucket}/{meetingId}.*` when a meeting id is known, and downloaded backend audio uses the same location bucket. The deployed backend now stores new uploaded meeting audio under `DATA_DIR/meeting-audio/{user_id}/{location-bucket}/{meeting_id}.*`, while the SQLite `audio_path` keeps old flat-path meetings playable.

The updated Debug iOS app was rebuilt, code-sign verified, and installed on `iPhone (Yerasyl)`. The earlier build launched through `devicectl`; the latest same-chunk pause/resume build installed successfully, but CoreDevice lost the device before launch.

Docs/env guidance now mention persisted meeting audio and diarization speaker-count knobs. Backend code is deployed to `51.195.200.207`, and the updated iOS app is installed on `iPhone (Yerasyl)`.

Known limitations: older meetings whose audio was deleted by previous backend versions cannot be recovered unless re-uploaded/reprocessed. Diarization quality still depends on WhisperX/pyannote and recording acoustics; if the model collapses multiple similar voices, set `DIARIZATION_MIN_SPEAKERS=2` or a known speaker count on the server and retest.

## Next

Result is ready for human review. Review gate: unlock/connect the iPhone, install the latest signed build, then open contents and verify: first tap starts faster, same active chunk tap pauses/resumes from the current time, blue progress stays visible while paused, active text follows playback, and background/close stops audio. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue review of the IOS-7/8/9 meeting-processing stack after this real recording test.

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
- Add autopilot summary generation modes: the LLM chooses among reasoning summary, full transcript, clean detailed, meeting note, call note, strategic meeting with speaker profiling, and concise rewrite based on the transcript contents.
- Keep generated summary and outline text in the primary dialogue language instead of defaulting to English.
- Render markdown/table-like chat answers readably in the iOS chat tab and steer backend chat away from pipe-table output.
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
- [x] Add summary mode contracts/prompts and persist the LLM-selected mode on saved meetings.
- [x] Keep iOS on autopilot generation while decoding and displaying the mode chosen by the backend.
- [x] Add primary-dialogue-language detection to summary generation and force `outline`/summary fields to that language.
- [x] Add a mobile-readable chat renderer for markdown emphasis and pipe-table answers.
- [x] Move meeting chat persistence toward the ChatGPT/Claude backend pattern with a durable default thread, message items, and per-turn generation run records.

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
- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend DATA_DIR=/tmp/her-summary-autopilot-smoke python3 - <<'PY' ...` verified autopilot response parsing, fixed-mode override behavior, full transcript generation without an LLM client, and the autopilot prompt. The ambient pyenv still prints its existing `hashlib` blake2 warnings, but the smoke assertions completed.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `python3 -m compileall her-ios/backend/app` after the chat formatting prompt update.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` verified primary language detection for Russian, Kazakh, English, explicit `language`, the summary prompt language rule, and full-transcript fallback titles. The ambient pyenv still prints its existing `hashlib` blake2 warnings, but the smoke assertions completed.
- `python3 -m compileall her-ios/backend/app` after the primary-dialogue-language summary update.
- `python3 -m compileall her-ios/backend/app` after the backend chat thread/run persistence update.
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` verified the storage path creates a default chat thread, creates a running chat generation run, links user/assistant messages to the same `threadId`/`runId`, and completes the run with `response_message_id`.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the primary-dialogue-language summary update.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build` after the chat renderer update.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build` after the chat renderer update.
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`

Not run:
- FastAPI `TestClient` route smoke in the ambient `python3`; it failed before app import because `jwt` / PyJWT is not installed in that interpreter.
- FastAPI route import smoke after the backend chat thread/run update; it still fails before app import because `jwt` / PyJWT is not installed in the ambient interpreter.
- Real recording generation with LLM-selected modes and visual chat-format review on the physical iPhone.

## Result

Backend settings now support platform-managed Alem OSS through `ALEM_OSS_API_KEY` and `ALEM_OSS_BASE_URL`, while keeping the existing OpenAI-compatible path. Summary generation uses the configured LLM when available, so it no longer falls back to the first transcript lines. If AI summary is unavailable, the backend still saves the transcript/meeting with `summaryStatus=unavailable` and a location-based title. Added authenticated `GET /v1/meetings/{meeting_id}/chat`, `POST /v1/meetings/{meeting_id}/chat`, streaming `POST /v1/meetings/{meeting_id}/chat/stream`, and `POST /v1/meetings/{meeting_id}/summary`. Chat messages are persisted in SQLite per meeting, prior turns are included in the next LLM call, and regenerating a summary retitles the saved meeting without deleting chat history. iOS hydrates saved chat messages, streams new deltas into the active assistant bubble, exposes summary generation for unsummarized saved meetings, and keeps chat input text readable in dark mode. Backend code and runtime env are deployed to `51.195.200.207`, and the updated iOS build was installed and launched on the connected iPhone.

Added autopilot summary modes. The backend contract accepts and returns `summaryMode` for direct summaries, meeting processing jobs, synchronous processing, manual saved-meeting regeneration, and saved meetings. SQLite migrates meetings and jobs with a default `reasoning` mode. In `reasoning` mode, `SummaryService` now asks the LLM to inspect the transcript and choose the best internal output mode among meeting note, call note, clean detailed, strategic meeting/speaker profiling, concise rewrite, and full transcript. The selected mode is parsed from the LLM response and persisted with the meeting. Explicit `full_transcript` remains deterministic without an LLM client for compatibility. iOS no longer shows a manual selector; it sends autopilot generation requests and labels generated summaries with the backend-selected mode.

Summary generation now derives the primary dialogue language from the formatted transcript, with the transcriber language code as a fallback for short or ambiguous text. The LLM prompt explicitly requires `title`, `overview`, `keyTopics`, `decisions`, `actionItems`, `followUps`, and every `outline.title` to be written in that language while keeping JSON keys and `summaryMode` enum values unchanged. Meeting processing, background jobs, and manual summary regeneration pass the saved transcript language into this path. Direct `/v1/summaries` also accepts optional `language`.

iOS chat now renders assistant answers through a display formatter instead of a plain raw text bubble. Markdown emphasis is parsed where possible, inline markers are stripped in fallback text, and markdown pipe tables are converted into readable stacked rows with field labels so long meeting action tables do not overflow or show raw `|---|` syntax. The backend chat system prompt now tells the LLM to avoid markdown tables and code fences in narrow iPhone chat responses, using numbered items with short field labels instead.

Backend meeting chat now has a more ChatGPT/Claude-style shape under the existing endpoints. Each recording gets a durable default chat thread, messages are thread items with optional `runId`, and every assistant generation creates a `meeting_chat_runs` row that records status, model/source, prompt message count, prompt character count, completion timestamp, and the assistant message id. The public API remains backward-compatible for the current iOS client while adding `thread`, `threadId`, `runId`, `messageId`, and `model` metadata for newer clients.

The updated Debug iOS app was rebuilt, installed, and launched on `iPhone (Yerasyl)` after the chat renderer update.

## Next

Ready for human review: record or reuse a few short conversations with different content types, confirm the backend chooses an appropriate mode, and confirm the generated summary shape matches the transcript. Also open a meeting, ask two chat questions including one that produces tasks/action items, leave and reopen it, and confirm the thread is still readable and still there. For the backend chat structure specifically, inspect local SQLite and confirm `meeting_chat_threads`, `meeting_chat_messages.thread_id/run_id`, and `meeting_chat_runs` are populated for new chat turns. After approval: commit, push/PR only if requested, then archive/update the task. Next task candidate from `todo/tasks.md`: review/approve the current `IOS-7` and `IOS-8` meeting-processing changes.

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
- 2026-05-17 processing recovery follow-up: `git diff --check`; `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`; `python3 -m compileall her-ios/backend/app`.

Not run:
- Full `app.main` import/route smoke in the ambient `python3`; it failed before app import because `jwt`/`pyjwt` is not installed in that interpreter.
- Real audio transcription and on-device upload/polling smoke.
- Real mixed English/Russian/Kazakh recording was not exercised; the deployed change was verified through settings, chunking, and merge smoke checks.
- 2026-05-17 device install and real long-recording recovery smoke; `xcrun devicectl list devices` reported `iPhone (Yerasyl)` as `unavailable`.

## Result

Added backend-owned meeting processing jobs. `POST /v1/meetings/jobs` persists uploaded audio under `DATA_DIR`, stores a queued job in SQLite, and submits processing to a backend `ThreadPoolExecutor`. The worker transcribes audio, relabels enrolled speakers, summarizes through the existing OpenAI-compatible `SummaryService`, saves the completed meeting, marks the job completed, and removes the uploaded audio file. `GET /v1/meetings/jobs/{job_id}` returns job state and hydrates the completed meeting when ready. Active queued/processing jobs are resubmitted on backend startup.

Added chunk-level parallel transcription for long recordings. When `TRANSCRIPTION_CHUNKING_ENABLED=true` and the audio duration is at least `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS`, the backend uses `ffprobe`/`ffmpeg` to split audio into overlapping WAV chunks, transcribes chunks in a `ThreadPoolExecutor` capped by `TRANSCRIPTION_CHUNK_WORKERS`, offsets segment timestamps back into the original recording, drops duplicate overlap segments, and merges the transcript. Runtime knobs now include `TRANSCRIPTION_CHUNK_SECONDS`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS`, `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS`, and `TRANSCRIPTION_CHUNK_WORKERS`.

Updated transcription defaults for mixed-language meetings. Empty `WHISPER_LANGUAGE` now normalizes to `None`, faster-whisper and WhisperX run with `task="transcribe"` instead of translation, and runtime chunking defaults to 30-second chunks with 3-second overlap and 2 chunk workers. This lets language detection happen per short chunk instead of forcing a whole meeting into the first detected language, so English, Russian, and Kazakh speech should stay in their original languages instead of being rewritten into one language.

Updated iOS recording processing to submit the recording to the job endpoint and poll until completion. When the backend supports jobs, the transcript and summary arrive together and the meeting is already stored server-side. If the backend does not have the job endpoint yet, iOS falls back to the old synchronous `/v1/transcriptions` flow so existing deployments do not hard-break.

2026-05-17 follow-up: iOS now records pending processing state before upload, submits the backend job inside an iOS background task, persists the accepted backend job id, and resumes upload/polling from `recoverIfNeeded()` after the app is reopened. If the user stops a recording and leaves the app, the audio should either reach the backend before suspension or be retried from the saved local file on the next launch; once the job id is accepted, backend processing continues independently of the screen.

AI summary support was already present through OpenAI-compatible env vars; docs now call out the `gpt-oss` default, Alem-compatible `OPENAI_BASE_URL`, `MEETING_JOB_WORKERS`, `WHISPER_CPU_THREADS`, `WHISPER_NUM_WORKERS`, and `WHISPERX_BATCH_SIZE`. The provided secret was not written to tracked files. Current checked health responses for the running local/remote backends still report `openaiConfigured=false`, so runtime `.env` must be configured before real AI summaries are active.

Known limitations: chunk-wise WhisperX diarization can make raw `SPEAKER_NN` labels less stable across chunk boundaries; disable chunking if full-file diarization quality matters more than throughput. Processing recovery depends on the stopped recording file remaining in local app storage; if iOS kills the app before the audio file is finalized, or the user deletes app data before reopening Her, the backend cannot recover that upload.

Deployed to `51.195.200.207` on 2026-05-10. Backups of previous backend files were created at `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-064921.tgz` and `/home/ubuntu/meta-ios-deploy-backups/backend-20260510-071010.tgz`. The active systemd service is `meta-ios-backend.service`, running from `/opt/meta-ios/backend` on port `8787`. Runtime config now has `summaryModel=gpt-oss`, Alem base URL configured, `WHISPER_LANGUAGE=` normalized to auto-detect, `TRANSCRIPTION_CHUNKING_ENABLED=true`, `TRANSCRIPTION_CHUNK_SECONDS=30`, `TRANSCRIPTION_CHUNK_OVERLAP_SECONDS=3`, `TRANSCRIPTION_CHUNK_MIN_DURATION_SECONDS=30`, `TRANSCRIPTION_CHUNK_WORKERS=2`, and `MEETING_JOB_WORKERS=1`. `ffmpeg` and `ffprobe` are installed on the server. `OPENAI_API_KEY` is still missing from `/etc/meta-ios-backend.env`, so `/health` reports `openaiConfigured=false`; AI summaries will use local fallback until a non-exposed key is added and the service is restarted. The updated Debug iOS app was also built, installed, and launched on `iPhone (Yerasyl)` so the client uses the new job polling endpoint.

## Next

Result is ready for human review. Review gate: install the current build, run a real recording from the iPhone, tap Stop, immediately leave Her or lock the phone, then reopen Her and verify the recording either resumes pending upload/processing or appears completed in Conversations. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or `IOS-4` if wake-word/voice enrollment remains the next stage-1 blocker.

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

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-07

## Goal

Make the assistant name double as the wake word, accept `Hey {name}` as a natural alias, and wire the simplest Stage 1 voice commands for starting and stopping recordings.

## Context

The user chose the simpler model: `Assistant Name = Wake Word`. For example, `Alfred` or `Hey Alfred` should wake the app, then `start recording` starts capture, and `stop recording` / `I'm finished` stops and transcribes. This should remain a Stage 1 recorder control, not a VisionClaw-style vision/realtime agent.

The first implementation can use iOS foreground speech recognition as a prototype. A production custom wake-word engine such as Picovoice or OpenWakeWord remains a follow-up after real-device validation.

## Scope

In scope:
- Update assistant-name onboarding so the name is presented as the wake word and `Hey {name}` is accepted as a natural alias.
- Add a foreground wake-command listener that detects the assistant name and maps `start recording` / `stop recording`-style commands to the existing recording flow.
- Add Settings controls and status for wake commands.
- Add the iOS speech-recognition privacy string needed by the listener.

Out of scope:
- Scheduled/background autonomous runs.
- Cross-session memory promotion beyond explicit local onboarding/profile data.
- Vision, realtime conversation, tool-calling, or VisionClaw-style agent behavior.
- Cloud-only wake-word processing or cloud credential storage.
- Shipping a paid wake-word provider decision without human review.

## Implementation Plan

- [x] Inspect current onboarding, settings, AppIntents, and recording start/stop flow.
- [x] Add a foreground wake-command controller using iOS Speech + AVAudioEngine.
- [x] Treat the assistant name as the wake word and accept `Hey {name}` as a natural alias.
- [x] Route wake start/stop notifications through the existing recording screen actions.
- [x] Release the wake-command microphone listener before starting the recorder.
- [x] Pause the normal wake listener while other audio is already playing so opening Her does not force Ray-Ban into the HFP/call route.
- [x] Add focused build and plist/backend smoke checks.

## Verification

- `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- 2026-05-14 Ray-Ban music audio-route fix:
  - `plutil -lint her-ios/frontend/ConversationSummarizer/Resources/Info.plist`
  - `python3 -m compileall her-ios/backend/app`
  - `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
  - `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
  - `git diff --check`
  - `xcrun devicectl list devices` showed `iPhone (Yerasyl)` as `unavailable`.
  - `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app` failed because CoreDevice could not locate the unavailable iPhone.

## Result

Added `WakeCommandController`, a foreground iOS Speech listener that watches for the configured assistant name or `Hey {name}` and dispatches wake start/stop recording notifications when it hears commands such as `start recording`, `stop recording`, `I'm finished`, `начни запись`, or `останови запись`. `ContentView` owns the controller, keeps it tied to the active scene, routes wake start/stop through the existing recording actions, opens the Recording screen as visible feedback when only the wake phrase is heard, and keeps the recording screen open once a voice command starts recording. The wake listener now fully releases its `AVAudioEngine` microphone tap before starting the meeting recorder, so `Hey Friday start recording` and the normal Start Recording button do not compete with the wake listener for the same microphone input.

Updated onboarding so the assistant-name page presents the name as the wake word, suggests stronger names such as `Alfred`, and blocks names shorter than four letters. Settings now shows the wake word as the assistant name with `Hey` optional, adds a `Listen for {name}` toggle, and displays listener status. Added `NSSpeechRecognitionUsageDescription` to the iOS plist and registered the new Swift source in the Xcode project. For Latin wake names such as `Friday`, the listener now prefers the `en_US` recognizer before falling back to the device language.

The recording phase now switches the wake listener into a constrained stop-only mode instead of fully pausing it. During an active recording it accepts `stop recording`, `Hey Friday stop recording`, `I'm finished`, `стоп`, and the existing stop aliases, then routes through the same `stopAndTranscribe` flow as the on-screen Stop button. The on-screen Stop path also shuts down the stop listener before transcribing so the listener does not keep the audio input open during completion.

Follow-up Ray-Ban music fix: the normal foreground wake listener now checks `AVAudioSession.isOtherAudioPlaying` before configuring the `.playAndRecord` / `.voiceChat` / Bluetooth HFP session. If music or other audio is already playing, wake commands move to a paused state instead of taking the microphone route, so opening Her while wearing Ray-Ban glasses should not make music muffled or switch the glasses into the call profile. When the wake listener did own the audio session, stopping it now deactivates with `.notifyOthersOnDeactivation`; the stop-only listener during an active recording reuses the recorder's audio session instead of owning/deactivating it.

Known limitations: this is a foreground iOS Speech prototype, not a trained always-on wake-word model. It needs physical-device validation with Ray-Ban selected as the active Bluetooth input. If iOS still refuses to run `AVAudioRecorder` and the stop listener at the same time on device, the next fix is a shared audio pipeline or real wake-word engine rather than another independent microphone consumer.

The updated Debug iOS build was signed, installed, and launched on `iPhone (Yerasyl)`. The first CoreDevice install attempt failed with `Connection interrupted`, then the retry succeeded. Later builds that release the wake listener before starting recording, display `Yerasyl (you)` labels, and add the recording stop-only listener were also signed, installed, and launched on the same iPhone. The 2026-05-14 Ray-Ban music audio-route fix builds and verifies locally, but was not installed because `iPhone (Yerasyl)` is currently `unavailable` to CoreDevice.

## Next

Result is ready for human review once the latest build is installed on the iPhone. Review gate: reconnect/unlock `iPhone (Yerasyl)`, install the current build, start music through the Ray-Ban glasses, open Her, and confirm the music stays normal while wake commands show paused because other audio is playing. Then stop music, open Her, set assistant name to `Friday`, enable `Listen for Friday` in Settings, accept Speech/Microphone permissions, and test `Hey Friday` as visible wake feedback, `Hey Friday start recording`, and while recording `Hey Friday stop recording` / `stop recording` through the active Ray-Ban/iPhone audio route. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-3` if setup state should move to the backend, or harden `IOS-4` with a real custom wake-word provider after device validation.

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

# IOS-13: Persist Speaker Identities From Meetings

Status: review
Priority: P1
Owner: agent
Stream: ios
Branch: current worktree
Created: 2026-05-13

## Goal

Let the user assign a meeting speaker to an existing or new voice profile so future meetings can automatically identify that person inside this user's account.

## Context

The transcript UI currently stores speaker display names locally and shows a small hard-coded list of example names. The backend already has owner voice profile enrollment and automatic relabeling when a profile matches, but there is no durable flow for "Speaker 1 is Erulan" to create or extend a voice profile from the meeting audio.

## Scope

In scope:
- Store multiple confirmed voice samples per user-scoped voice profile.
- Add a backend endpoint that assigns a meeting speaker to an existing or new profile, extracts a speaker embedding from the meeting audio, updates the profile, and persists the meeting transcript labels.
- Make future automatic relabeling compare against the expanded profile centroid.
- Replace mocked speaker-name suggestions with real saved voice profiles from the backend.
- Mark the current user's speaker label as `(you)` when it displays as `Yerasyl` or the signed-in user name.
- Keep all profiles scoped to the authenticated `user_id`.

Out of scope:
- Cross-user/global speaker identity.
- Automatic profile training from unconfirmed model guesses.
- Full contact-management UI beyond choosing an existing profile or typing a new name from the transcript speaker sheet.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect current speaker rename UI, meetings store, voice profile API, storage, and relabel path.
- [x] Add backend profile sample storage and assignment endpoint.
- [x] Update backend relabeling/enrollment to use expandable profiles and external embedding fallback where needed.
- [x] Wire iOS speaker sheet to saved profiles and backend assignment.
- [x] Decorate current-user speaker labels as `(you)` in live and saved transcript displays.
- [x] Run backend and iOS verification.

## Verification

- `python3 -m compileall her-ios/backend/app`
- `PYTHONPATH=her-ios/backend python3 - <<'PY' ...` storage smoke verified profile sample count/duration updates and case-insensitive profile lookup.
- `PYTHONPATH=her-ios/backend TRANSCRIPTION_PROVIDER=external EXTERNAL_TRANSCRIPTION_URL=http://127.0.0.1:8000 DATA_DIR=/tmp/her-ios-ios13-route-smoke python3 - <<'PY' ...` route smoke verified assigning `SPEAKER_00` creates a profile, relabels meeting segments, and a second assignment extends the same profile to `sampleCount=2`. The ambient pyenv still prints existing `hashlib` blake2 warnings, but assertions completed.
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Deployed backend files to `51.195.200.207`; previous files backed up at `/home/ubuntu/meta-ios-deploy-backups/backend-20260513-135018-ios13-speaker-profiles.tgz`.
- Remote backend compile in `/opt/meta-ios/backend/.venv`, `systemctl restart meta-ios-backend.service`, public `GET /health`, OpenAPI route check for `/v1/meetings/{meeting_id}/speakers/assign`, and SQLite migration check for `voice_profiles.sample_count` plus `voice_profile_samples`.
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -configuration Debug -destination 'platform=iOS,id=05D2DC76-91CA-5F81-9971-FF0C752D8377' -derivedDataPath her-ios/frontend/DerivedData -allowProvisioningUpdates build`
- `codesign --verify --deep --strict --verbose=2 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :BackendAPIURL' her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app/Info.plist`
- `xcrun devicectl device install app --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 her-ios/frontend/DerivedData/Build/Products/Debug-iphoneos/Her.app`
- `xcrun devicectl device process launch --device 05D2DC76-91CA-5F81-9971-FF0C752D8377 com.ekenesbek.her`
- 2026-05-18 voice-match threshold follow-up: inspected production account data for the Apple/private-relay user backing `ekenesbek@icloud.com`; the two latest meetings still had raw `SPEAKER_*` labels, one `Yerasyl` voice profile existed, and dry-run speaker-profile scores were just below the old `0.62` threshold.
- `python3 -m compileall her-ios/backend/app`
- `git diff --check`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Remote deploy to `51.195.200.207`: backed up previous files at `/home/ubuntu/meta-ios-deploy-backups/backend-20260518-145318-ios13-voice-match.tgz`, copied `app/main.py` and `app/settings.py`, compiled remote backend, restarted `meta-ios-backend.service`, verified `GET /health`.
- Remote DB update for the two latest Apple/private-relay meetings: backed up SQLite at `/home/ubuntu/meta-ios-deploy-backups/meetings-20260518-145526-before-voice-relabel.sqlite3`, relabeled meeting `2279c2aa-b302-415f-baee-d6317d5a8390` from `SPEAKER_00` to `Yerasyl` and meeting `cc9d6c19-4b76-4220-9845-c8a414437227` from `SPEAKER_01` to `Yerasyl`, then verified the persisted speaker counts.

Not run:
- Manual UI smoke for assigning a real speaker on production meeting audio.

## Result

Added durable user-scoped speaker identity assignment. Voice profiles now track `sampleCount` and every confirmed sample is stored in `voice_profile_samples` with optional meeting id and original speaker label. Owner enrollment still creates a profile, but now also stores the initial sample. Assigning another meeting speaker either creates a new profile from that speaker's meeting audio or extends an existing profile by adding a confirmed sample and updating the profile centroid.

Added `POST /v1/meetings/{meeting_id}/speakers/assign`. It requires the authenticated user's meeting, persisted meeting audio, and a diarized speaker label. The endpoint extracts an embedding from all matching speaker segments, creates or updates the selected user-scoped profile, rewrites that meeting's matching transcript segments to the profile name, and returns the updated meeting plus profile metadata.

Automatic relabeling now still compares future speakers against profile centroids, but voice embedding extraction can fall back to the external GPU STT service's `/v2/embedding` or `/v1/embedding` endpoint. This keeps the production `TRANSCRIPTION_PROVIDER=external` setup usable even when main backend does not run local pyannote embedding.

iOS transcript speaker rename now loads saved profiles from `/v1/voice-profiles` and shows those real saved voices instead of hard-coded mock names. Selecting a saved profile and applying it to all segments from a speaker calls the backend assignment endpoint. Typing a new name creates a new profile from that speaker. The single-segment scope remains local-only and does not train a profile.

iOS transcript displays now decorate the current user's speaker name as `(you)`. If a live or saved transcript segment is labeled `Yerasyl` or matches the signed-in/current user display name, the recording screen and saved meeting contents show `Yerasyl (you)` without changing the backend speaker label stored for profile matching.

Deployment note: the main backend server had a full root disk. Only Docker builder cache and the failed zero-byte partial backup from this deploy were removed; containers, user data, databases, recordings, and Docker images were not pruned. After freeing cache, backend deployment and restart succeeded.

2026-05-18 follow-up: the production account reached through Apple Sign In uses a private relay address, not the literal `ekenesbek@icloud.com` email. The two latest recordings had a saved `Yerasyl` profile, valid audio, and diarized speakers, but the best matching speakers scored `0.5616` and `0.5839`, below the previous strict `VOICE_PROFILE_MATCH_THRESHOLD=0.62`. Automatic relabeling now uses a safer single-profile path: when a user has exactly one saved voice profile, a clearly best diarized speaker can match at `VOICE_PROFILE_SINGLE_PROFILE_MATCH_THRESHOLD=0.55` if it beats the next speaker by `VOICE_PROFILE_SINGLE_PROFILE_MATCH_MARGIN=0.08`; only one speaker label can be assigned to that profile in a recording. The backend fix is deployed, and the two latest production meetings were relabeled in SQLite so `Yerasyl` appears in their saved segments.

## Next

Result is ready for human review. Review gate: reopen Her, refresh/open the two latest recordings, and confirm the correct speaker rows now show `Yerasyl (you)` while the other speaker rows stay separate. Then record/process another short meeting and confirm the saved `Yerasyl` profile auto-labels when it is the clearly best speaker match. After approval: commit, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `IOS-4` if guided owner voice enrollment/wake-word setup remains the next blocker.
