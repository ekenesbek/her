# voice agent — phased roadmap

Honest estimates assume one focused developer, no team coordination overhead.

## Phase 0 — proof of life (1 day)
- [ ] LiveKit Cloud account, API key
- [ ] `voice_agent/main.py`: minimal agent that joins a room, transcribes via Deepgram, responds via Claude streaming, speaks via Cartesia
- [ ] Test from LiveKit's web playground — full voice conversation works in browser
- [ ] Measure end-to-end latency

**Exit criterion:** "Hello, what's the weather?" → spoken reply in under 1.5 s on first try.

## Phase 1 — Sesame-comparable UX (3–5 days)
- [ ] Semantic turn detector enabled, tuned to 600 ms silence floor
- [ ] Barge-in works (user can interrupt mid-response)
- [ ] System prompt with persona, sleep words, tool descriptions
- [ ] 30-sec silence → graceful close
- [ ] Cartesia voice cloned to a target voice (or one of their stock voices picked)
- [ ] Tool: `end_conversation()` — closes the LiveKit room cleanly

**Exit criterion:** A 5-minute conversation with two interruptions and a sleep word feels natural. Latency 700–900 ms p50.

## Phase 2 — iOS integration (3–4 days)
- [ ] Add `LiveKit` Swift SDK to `Her` iOS project
- [ ] `VoiceAgentSession.swift` — open room, route mic/speaker through existing audio session
- [ ] AppIntent "Talk to Her" → invokes from Siri
- [ ] UI: mic button in main view; speaking indicator
- [ ] Reuse `WakeCommandController` to hand off from wake-word to live session
- [ ] Handle backgrounding (audio session keeps room alive)

**Exit criterion:** "Hey Siri, talk to Her" → conversation starts on iPhone with Ray-Ban Meta connected.

## Phase 3 — tools that matter (3–4 days)

Each tool is a separate ~half-day task. Pick whichever has highest user value first.

- [ ] `search_meetings(query)` — RAG over user's recorded meetings (backend already has this)
- [ ] `recall_memory(query)` — long-term across sessions
- [ ] `get_weather(loc)`
- [ ] `draft_taxi(from, to)` — opens Yandex Taxi / Uber deep link
- [ ] `set_reminder(text, when)` — EventKit bridge in iOS
- [ ] `save_note(text)` — Apple Notes / our own store

**Exit criterion:** Three tools work end-to-end with voice ("schedule a reminder to call mom at 6"; agent confirms; reminder appears).

## Phase 4 — production polish (1 week)
- [ ] Conversation persistence: each call saved as a meeting with diarization (single speaker = agent, other = user)
- [ ] Cost dashboard: per-conversation $ tally
- [ ] Error recovery: STT/TTS provider fallback chain
- [ ] User-visible voice picker (settings)
- [ ] Telemetry: latency p50/p95/p99, interruption count, sleep-word usage

## Phase 5 — self-hosted TTS (optional, 1 week)
Only worth doing once daily cost > $5/day or privacy becomes a hard requirement.

- [ ] GPU box (A10 or L4) running CSM-1B FastAPI wrapper
- [ ] `voice_agent/tts/csm.py` adapter that streams from the local server
- [ ] A/B compare with Cartesia on the same prompts; document quality gap
- [ ] Fallback to Cartesia if CSM service unhealthy

## Phase 6 — wake word on iOS (optional, 2–3 days)
Already documented in `her-ios/ROADMAP.md` — same Picovoice plan applies. Activates a LiveKit session instead of OpenAI Realtime.

---

## Cost model (rough)

Assuming 10 minutes/day of conversation:

| Stack | $/min | $/month (300 min) |
|---|---|---|
| OpenAI Realtime (everything) | $0.30 | $90 |
| Deepgram + Claude + Cartesia | $0.13 | $39 |
| Deepgram + Claude + CSM-1B (self-host) | $0.05 + GPU | GPU rental ~$300/mo or one-time |
| LiveKit Cloud transport | $0.0006 | $0.18 |

Self-hosting CSM-1B only makes sense above ~30 active users.

## Risks & non-obvious gotchas

1. **Russian voice quality** — Cartesia's Russian voices are fewer and less expressive than English. Validate before committing the persona to a language.
2. **Glasses A2DP latency** — measured before; the current recording flow already battles this. Voice agent inherits the same constraints.
3. **Sleep-word reliability** — fast STT can mishear "bye" mid-sentence and end calls. Need a high-confidence threshold + a confirmation prompt for ambiguous matches.
4. **LiveKit Cloud lock-in** — the API is open (LiveKit is OSS), but migrating to self-hosted SFU is a project. Stick with Cloud until usage justifies the move.
5. **CSM-1B licensing** — Apache 2.0, OK for commercial. But voice cloning from real people has consent implications; build a flow that requires explicit opt-in audio sample.
