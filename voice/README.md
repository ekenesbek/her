# meta/voice — realtime voice agent

Sesame-level conversational voice agent for the Her ecosystem (iOS + glasses).

> **TL;DR:** 95% Sesame UX is achievable with a pluggable LiveKit Agents pipeline + Cartesia/Deepgram + Claude. 100% Maya-level expressiveness needs Sesame's proprietary 8B CSM, which isn't released. Their 1B (`CSM-1B`) is open-source and can be plugged in as an alternative TTS once we want full self-hosting.

## What "Sesame level" means here

Sesame's Maya/Miles demo set the bar with:

| Property | Target | Realistic with this repo |
|---|---|---|
| First-token latency | 500–800 ms | 600–900 ms (LiveKit + Deepgram + Claude + Cartesia) |
| Turn-taking | Semantic (knows when you finished a thought) | LiveKit semantic turn detector |
| Interruption | Barge-in cancels playback within ~200 ms | Built into LiveKit Agents |
| Expressive TTS | Laughs, hesitations, sighs | Cartesia Sonic-2 ~85% there; CSM-1B ~70% |
| Long context | "1 hour" memory window | Claude + our existing meeting memory |
| Voice cloning | Maya/Miles personas | Cartesia voice clones or CSM-1B with audio prompt |

The piece we **cannot replicate** is Sesame's proprietary 8B model — it isn't available. Everything else has commodity equivalents.

## Architecture (recommended path)

```
iPhone / glasses
   │  WebRTC (LiveKit iOS SDK)
   ▼
LiveKit Cloud / self-hosted SFU
   │
   ▼
voice_agent (this service, Python)
   ├── STT:  Deepgram Nova-3 streaming (or Whisper streaming)
   ├── VAD + turn detector: Silero + LiveKit semantic
   ├── LLM:  Claude Sonnet 4.6 (streaming)
   ├── Tools: search_meetings, get_weather, draft_taxi, set_reminder,
   │          end_conversation, recall_memory
   └── TTS:  Cartesia Sonic-2  (default, sub-100ms TTFB)
             ├─ swap: CSM-1B (self-host, GPU)
             └─ swap: ElevenLabs Turbo v2.5
```

LiveKit handles the hard part (WebRTC, jitter buffer, echo cancellation, barge-in, turn detection). We plug in STT/LLM/TTS via their `agents` framework.

## Why not just OpenAI Realtime?

It's already in `her-ios/ROADMAP.md` as the cheap path — and it works. The trade-off:

| | OpenAI Realtime | This pipeline |
|---|---|---|
| Voices | 8 fixed, decent but not Sesame-expressive | Cartesia/CSM/ElevenLabs, can clone |
| LLM | gpt-realtime only | Claude/any model |
| Cost | ~$0.30/min | ~$0.10–0.18/min |
| Lock-in | Yes | None |
| Latency | ~600 ms | ~700–900 ms |

Use Realtime as the MVP fallback (`voice_agent/llm/openai_realtime.py`); use the pluggable pipeline as the production path.

## Status

- [x] Scaffolding + architecture doc
- [ ] LiveKit room bootstrap (`voice_agent/main.py`)
- [ ] Deepgram STT adapter
- [ ] Claude streaming LLM with tools
- [ ] Cartesia TTS adapter
- [ ] Tool: `search_meetings` (talks to `her-ios/backend`)
- [ ] Tool: `recall_memory` (long-term memory across sessions)
- [ ] iOS `Her` app: LiveKit SDK integration + AppIntent "Talk to Her"
- [ ] Sleep words / 30-sec silence timeout
- [ ] Self-hosted CSM-1B fallback (GPU box)

See `ROADMAP.md` for the phased plan and `ARCHITECTURE.md` for component-level detail.

## Run (once implemented)

```bash
cd meta/voice
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
cp .env.example .env  # fill in keys
python -m voice_agent.main dev      # local LiveKit dev mode
python -m voice_agent.main start    # production (connects to LiveKit Cloud)
```
