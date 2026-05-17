# Meta Wearables DAT Notes

Source links:

- Meta blog: https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/
- iOS SDK: https://github.com/facebook/meta-wearables-dat-ios
- DAT docs llms endpoint: https://wearables.developer.meta.com/llms.txt?full=true

## Current state

- The toolkit is in developer preview.
- Her no longer links the DAT SDK in the stage-1 iOS recorder. The active app records through standard iOS audio routing only.
- iOS support is through Swift Package Manager.
- Latest public tag checked during setup: `0.6.0`.
- Public package products:
  - `MWDATCore`
  - `MWDATCamera`
  - `MWDATMockDevice`
- Supported app runtime starts at iOS 15.2.
- Full App Store publishing is not currently supported for this SDK preview because of ExternalAccessory/MFi constraints; test distribution should use Meta release channels while in preview.

## Audio implication for meeting summaries

The DAT session model can integrate a mobile app with supported glasses, but device microphone and speaker access is through platform Bluetooth audio routing rather than a DAT microphone API. On iOS this means:

- Configure `AVAudioSession` with `.playAndRecord` and `.allowBluetooth`.
- Pair the glasses normally and select them as an audio input route.
- HFP audio is 8 kHz mono.
- Beamforming prioritizes the wearer, so it may miss other meeting participants in a room.

For the stage-1 meeting summarizer, DAT registration/session UI is unnecessary. Bluetooth HFP is enough for a wearer-centric assistant, and the app should stay honest about whether it is using a Bluetooth mic or the iPhone mic. For full-room meeting capture, the app should support an iPhone microphone or external meeting microphone as the primary input.

## Integration stages

1. App-only MVP:
   - Record through iOS audio session.
   - Transcribe after stop with Apple Speech.
   - Summarize locally or through backend.
2. Future camera/controls experiment:
   - Reintroduce DAT only when Her needs camera POV streaming, photo capture, or real glasses controls.
   - Keep that work separate from the audio recorder; do not add DAT registration to the main onboarding for audio-only recording.
3. Production:
   - Add consent UX before recording.
   - Move LLM summarization to a backend service.
   - Add persistent meeting history and secure deletion.
