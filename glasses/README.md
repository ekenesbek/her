# Conversation Summarizer for Meta AI Glasses

This folder contains the first iOS MVP for recording a meeting and producing a short summary.

## MVP behavior

- Start recording from the iOS app.
- Record from the current iOS input route. If Ray-Ban Meta glasses are paired as a Bluetooth HFP input, iOS can route microphone audio through the glasses.
- Stop recording and transcribe with Apple Speech.
- Generate a basic local summary with decisions, action items, and follow-ups.
- Keep Meta Wearables Device Access Toolkit integration isolated behind `WearablesBridge` so it can be completed once project credentials and test glasses are available.

## Project

Open this project in Xcode:

```bash
open glasses/ConversationSummarizer.xcodeproj
```

The target is `ConversationSummarizer` and the deployment target is iOS 15.2, matching Meta DAT's minimum iOS requirement.

## Required setup in Xcode

1. Set a real bundle identifier.
2. Set your Apple Developer Team ID.
3. In `ConversationSummarizer/Resources/Info.plist`, replace:
   - `$(META_APP_ID)`
   - `$(CLIENT_TOKEN)`
   - `com.example.conversationsummarizer://`
4. Add the optional Swift Package dependency before testing glasses registration:
   - `https://github.com/facebook/meta-wearables-dat-ios`
   - exact version `0.6.0`
   - link product `MWDATCore` to the app target
5. Run on a physical iPhone for microphone, Bluetooth route, and Meta AI app callback testing.

The checked-in Xcode project intentionally runs without the Meta package so the app can launch locally while credentials and test glasses are not configured. `WearablesBridge` uses `canImport(MWDATCore)`, so the same code enables DAT paths when the package is linked.

## Backend summary path

The MVP includes a local heuristic summary so the app runs without secrets. For production, do not put an LLM API key in the iOS app. Set the optional `SummaryAPIURL` Info.plist value to your backend endpoint, then have the backend call the summarization model.

Expected backend endpoint:

```http
POST /summarize
Content-Type: application/json

{
  "transcript": "Full meeting transcript..."
}
```

Expected response:

```json
{
  "title": "Weekly planning",
  "overview": "Short summary paragraph.",
  "decisions": ["Ship the beta next Friday."],
  "actionItems": ["Alex will prepare TestFlight notes."],
  "followUps": ["Confirm legal consent copy."]
}
```

## Meta DAT notes

Meta DAT is currently a developer preview. The public iOS SDK is added via Swift Package Manager and exposes `MWDATCore`, `MWDATCamera`, and `MWDATMockDevice`. Device microphone and speaker access is handled through iOS Bluetooth audio routing, specifically HFP for two-way voice. HFP is 8 kHz mono, so it is useful for the wearer's voice but not high-quality room audio.

See `docs/meta-wearables-dat.md` for source notes and integration constraints.

## Local verification

This environment has Swift command line tools but not full Xcode selected, so `xcodebuild` cannot run here. On a Mac with Xcode selected:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -project glasses/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'platform=iOS Simulator,name=iPhone 16' build
```
