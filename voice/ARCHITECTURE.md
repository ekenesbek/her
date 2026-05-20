# Architecture — voice agent

## Component map

```
┌────────────────────────────────────────────────────────────────────────┐
│ Client (iPhone, eventually Ray-Ban Meta via HFP/A2DP through iPhone)   │
│   • LiveKit iOS SDK                                                    │
│   • AVAudioEngine for mic capture / speaker playback                   │
│   • AppIntent "Talk to Her" (Siri-activated)                           │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │ WebRTC (Opus, 48 kHz)
                               ▼
┌────────────────────────────────────────────────────────────────────────┐
│ LiveKit SFU (Cloud or self-hosted)                                     │
│   Handles: NAT traversal, jitter buffer, echo cancel, packet loss      │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │ Raw PCM 16 kHz mono
                               ▼
┌────────────────────────────────────────────────────────────────────────┐
│ voice_agent (this service)                                             │
│                                                                        │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐             │
│   │ VAD (Silero) │──▶ │ STT          │──▶ │ Turn         │             │
│   │              │    │ (Deepgram    │    │ Detector     │             │
│   │              │    │  Nova-3      │    │ (semantic +  │             │
│   │              │    │  streaming)  │    │  silence)    │             │
│   └──────────────┘    └──────────────┘    └──────┬───────┘             │
│                                                  │                     │
│                          ┌───────────────────────┘                     │
│                          ▼                                             │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │ LLM (Claude Sonnet 4.6, streaming)                             │   │
│   │   Tools:                                                       │   │
│   │     • search_meetings(query)   → her-ios/backend               │   │
│   │     • recall_memory(query)     → memory store                  │   │
│   │     • get_weather(loc)         → external API                  │   │
│   │     • draft_taxi(from, to)     → deep-link to Yandex Taxi      │   │
│   │     • set_reminder(text, when) → Apple Reminders (iOS bridge)  │   │
│   │     • end_conversation()       → graceful close                │   │
│   └────────────────────────┬───────────────────────────────────────┘   │
│                            │ streamed text chunks                      │
│                            ▼                                           │
│   ┌────────────────────────────────────────────────────────────────┐   │
│   │ TTS (default: Cartesia Sonic-2)                                │   │
│   │   • Streaming WebSocket, ~40-80ms TTFB                         │   │
│   │   • Voice clone of user's choice                               │   │
│   │   Alternate adapters:                                          │   │
│   │     • CSM-1B (self-hosted on GPU, ~100-300ms TTFB)             │   │
│   │     • ElevenLabs Turbo v2.5                                    │   │
│   │     • OpenAI tts-1-hd                                          │   │
│   └────────────────────────┬───────────────────────────────────────┘   │
│                            │ Opus frames                               │
│                            ▼                                           │
│                          back to LiveKit → client                      │
└────────────────────────────────────────────────────────────────────────┘
```

## Latency budget (target: 800 ms end-to-end)

| Stage | Budget | Notes |
|---|---|---|
| Network in (mic → server) | 50 ms | LiveKit edge |
| VAD trigger to STT partial | 80 ms | Silero VAD ~30ms + first STT chunk |
| Final transcript on end-of-turn | 200 ms | Deepgram endpointing |
| Claude first token | 250 ms | streaming, prompt cached |
| Cartesia first audio byte | 80 ms | streaming, after first LLM tokens |
| Network out (server → speaker) | 50 ms | |
| Audio buffering | 90 ms | typical playout |
| **Total** | **~800 ms** | |

OpenAI Realtime API gets to ~600 ms but at the cost of voice quality and flexibility.

## Turn detection

Pure VAD silence (e.g. 700ms of silence = end-of-turn) fails on:
- Hesitations mid-sentence ("uh… let me think…")
- Trailing words after a thought
- Background speakers

LiveKit Agents has a **semantic turn detector** that uses a small classifier on the last STT output to decide if the user is "done thinking". We use that on top of a 600ms silence floor.

Sleep words (`bye`, `до свидания`, `хватит`, `finish`) bypass the detector — they call `end_conversation()` directly.

## Memory & long context

Each session injects:
1. System prompt (persona, capabilities, sleep words)
2. User profile snippet (from `her-ios/backend`'s user store)
3. Last 3 meeting summaries (RAG over the user's transcripts)
4. Conversation history (truncated to last 8 turns)

The 1-hour "memory" Sesame markets is mostly conversation history + prompt caching. Claude with prompt caching handles this natively.

## Self-hosted CSM-1B path

For full data sovereignty, swap Cartesia → CSM-1B:

- One A10 / L4 GPU runs CSM-1B at real-time on a single concurrent call.
- Run it as a separate service (`voice_agent/tts/csm_server.py`) co-located with the existing `her-ios/stt-service` GPU box.
- Triton inference server is overkill; a simple FastAPI wrapper over the `csm` repo is enough for MVP.
- Quality gap vs Cartesia: CSM-1B sounds good but is less expressive on emotions, and voice consistency drifts on long responses. Fine for personal assistant, not for "wow demo".

## Where iOS integration goes

Reuse the existing `Her` app:

- `her-ios/frontend/ConversationSummarizer/Features/Voice/VoiceAgentSession.swift` (new)
- Connect to LiveKit room when AppIntent "Talk to Her" is invoked or when user taps a mic button.
- Audio routing follows existing recording logic (HFP for glasses input, A2DP for output).
- Use the existing `WakeCommandController` to hand off from passive wake-word listening to a live LiveKit session.

## Open questions (resolve before phase 2)

1. **LiveKit Cloud vs self-host SFU?** Cloud is $0.0006/min; self-host adds 1 sysadmin role but no per-minute cost. Start Cloud.
2. **Cartesia vs CSM-1B as default?** Cartesia for v1 (faster ship); CSM-1B once we have a GPU and want self-hosting.
3. **Russian voice quality?** Cartesia has Russian support but limited voice clones; CSM-1B is English-first. Test before committing.
4. **Glasses A2DP playback latency?** Existing recording flow already uses A2DP — measure RTT in real conditions before promising sub-second UX.
