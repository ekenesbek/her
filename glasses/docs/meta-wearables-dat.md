# Meta Wearables DAT Notes

Source links:

- Meta blog: https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/
- iOS SDK: https://github.com/facebook/meta-wearables-dat-ios
- DAT docs llms endpoint: https://wearables.developer.meta.com/llms.txt?full=true

## Current state

- The toolkit is in developer preview.
- iOS support is through Swift Package Manager.
- Latest public tag checked during setup: `0.6.0`.
- Public package products:
  - `MWDATCore`
  - `MWDATCamera`
  - `MWDATMockDevice`
- Supported app runtime starts at iOS 15.2.
- Full App Store publishing is not currently supported for this SDK preview because of ExternalAccessory/MFi constraints; test distribution should use Meta release channels while in preview.

## Audio implication for meeting summaries

The DAT session model integrates the mobile app with supported glasses, but device microphone and speaker access is through platform Bluetooth audio routing rather than a DAT microphone API. On iOS this means:

- Configure `AVAudioSession` with `.playAndRecord` and `.allowBluetooth`.
- Pair the glasses normally and select them as an audio input route.
- HFP audio is 8 kHz mono.
- Beamforming prioritizes the wearer, so it may miss other meeting participants in a room.

For a meeting summarizer, this is good enough for a wearer-centric assistant. For full-room meeting capture, the app should support an iPhone microphone or external meeting microphone as the primary input.

## Integration stages

1. App-only MVP:
   - Record through iOS audio session.
   - Transcribe after stop with Apple Speech.
   - Summarize locally or through backend.
2. Meta registration:
   - Add real `MetaAppID`, `ClientToken`, `TeamID`, and callback URL scheme.
   - Call `Wearables.configure()` once at launch.
   - Start registration with `Wearables.shared.startRegistration()`.
   - Forward app callbacks with `Wearables.shared.handleUrl(url)`.
3. Glasses session:
   - Create a session with `AutoDeviceSelector`.
   - Start the session before recording when glasses controls are needed.
   - Observe session state so hinge/tap/wear events pause or stop recording cleanly.
4. Production:
   - Add consent UX before recording.
   - Move LLM summarization to a backend service.
   - Add persistent meeting history and secure deletion.

