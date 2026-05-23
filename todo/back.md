# Backend Tasks

Active `BACK-N` tasks and backend-scoped `BUG-N` tasks live here.

# BACK-3: Add Telegram Audio Transcription Bot

Status: review
Priority: P1
Owner: agent
Stream: back
Branch: current worktree
Created: 2026-05-21

## Goal

Add a separate local Telegram bot folder that accepts forwarded Telegram voice/audio messages and replies with a transcription.

## Context

The user wants to connect their Telegram bot token to a small transcription bot. Secrets must stay out of code, docs, commits, and task notes, so the bot must read `TELEGRAM_BOT_TOKEN` from local environment configuration.

This is a Stage 1 local utility around the existing completed-audio transcription path. It should not add scheduled background runs, credential vault behavior, or cross-session memory.

## Scope

In scope:
- Add a standalone bot folder.
- Support Telegram voice messages, audio files, video notes, and audio documents.
- Post downloaded audio to a configurable Her-compatible transcription HTTP endpoint.
- Reply with transcript text and basic metadata.
- Keep audio in temporary local storage only during processing.
- Document local setup without storing the bot token.

Out of scope:
- Persisting transcripts into Her memory or meeting storage.
- Running Whisper inside the bot process.
- Deployment automation.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [x] Add standalone Python package under `telegram-transcriber-bot/`.
- [x] Add environment-based configuration and docs.
- [x] Add Telegram handlers for voice/audio/document input.
- [x] Add HTTP transcription client for Her-compatible `TranscriptResponse`.
- [x] Run focused verification and update result.

## Verification

- `python3 -m compileall telegram-transcriber-bot/telegram_transcriber_bot`
- `cd telegram-transcriber-bot && python3 -m pytest`
- `cd telegram-transcriber-bot && python3 -m pip install -e .[dev]`
- `git diff --check`

## Result

Added `telegram-transcriber-bot/`, a standalone Python Telegram bot package. It reads `TELEGRAM_BOT_TOKEN` and transcription settings from local environment, handles Telegram voice/audio/video-note/audio-document messages, downloads audio into a temporary directory, posts it to a Her-compatible transcription endpoint, and replies with the transcript. The bot supports optional `ALLOWED_TELEGRAM_USER_IDS` restriction and optional `TRANSCRIPTION_BEARER_TOKEN` for the authenticated iOS backend.

Added setup docs, `env.example`, package metadata, and focused tests for transcript formatting and response parsing. No Telegram token was written to repo files.

2026-05-21 deploy: deployed the bot to `ubuntu@51.195.200.207` under `/opt/telegram-transcriber-bot`, installed dependencies in `/opt/telegram-transcriber-bot/.venv`, created `/etc/systemd/system/telegram-transcriber-bot.service`, and enabled/started it. Runtime env lives in `/etc/telegram-transcriber-bot.env` with root-owned `600` permissions and points transcription to `http://82.200.144.228:8000/v1/transcribe`.

2026-05-21 deploy fix: suppressed `httpx`/`httpcore` INFO logging in the bot so Telegram Bot API URLs are not written to future service logs, restarted the service, and rotated/vacuumed journald after the first startup had logged Telegram API URLs. The pasted token should still be rotated in BotFather because it appeared in chat and in the initial systemd journal before cleanup.

Verification:
- `python3 -m compileall telegram-transcriber-bot/telegram_transcriber_bot`
- `cd telegram-transcriber-bot && python3 -m venv .venv && .venv/bin/python -m pip install -e '.[dev]' && .venv/bin/python -m pytest`
- `cd telegram-transcriber-bot && .venv/bin/python -m ruff check .`
- `cd telegram-transcriber-bot && TELEGRAM_BOT_TOKEN=dummy .venv/bin/python - <<'PY' ...`
- `git diff --check`
- trailing-whitespace scan over new untracked bot files
- Remote deploy verification: `systemctl is-active telegram-transcriber-bot.service` returned `active`; `systemctl status` showed the bot running from `/opt/telegram-transcriber-bot/.venv/bin/python -m telegram_transcriber_bot`; `/etc/telegram-transcriber-bot.env` is `root:root 600`; remote curl to the GPU STT `/health` returned ok.
- Secret scan: `rg` over `telegram-transcriber-bot`, `todo/back.md`, and `todo/tasks.md` found no Telegram token or Bot API URL.

Known limitation: real forwarded-audio smoke was not performed by the agent. The service is polling Telegram on the server; the human should forward a new voice/audio message to verify the end-to-end reply.

## Next

Result is ready for human review. Review gate: forward a new voice/audio message to the Telegram bot and confirm it replies with a transcript. Rotate the Telegram bot token in BotFather, then update `/etc/telegram-transcriber-bot.env` and restart `telegram-transcriber-bot.service`. After approval: commit if requested, push/PR only if requested, then archive/update task state. Next task candidate from `todo/tasks.md`: continue `BACK-1` memory graph or `BACK-2` local agent memory share tool after the Stage 1 bot review gate.

# BACK-1: Add Memory Graph And Query API

Status: planned
Priority: P1
Owner: mixed
Stream: back
Branch: current worktree
Created: 2026-05-21

## Goal

Turn reviewed call/browser memory into a queryable user knowledge graph that can answer "what do we know about this person/project/topic and why?" with provenance.

## Context

The current production backend has `meeting_memory_candidates`: a flat candidate layer linked to meetings. That is useful for review, but not enough for a living graph. The next backend layer should model entities, relationships, temporal updates, source episodes, confidence, sensitivity, and supersession.

This is Stage 3 memory behavior. It can be developed behind explicit user review and internal endpoints, but stage-1 flows must not depend on it to succeed.

## Scope

In scope:
- Add a product-owned local graph schema for entities, edges, episodes, and memory facts.
- Link facts to source meetings, transcripts, summary fields, chat/task sources, and timestamps when available.
- Support entity resolution for people, projects, places, organizations, topics, and commitments.
- Add temporal semantics: observed_at, valid_from, valid_to, supersedes, confidence, sensitivity, status.
- Add query endpoints for memory chat and local-agent tools.
- Keep unconfirmed candidates out of high-impact use unless explicitly requested with source labels.

Out of scope:
- Provider lock-in to Graphiti, Mem0, or any hosted graph as the source of truth.
- Full graph visualization.
- Background cloud sync.
- Silent promotion of sensitive facts.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Reconcile `meeting_memory_candidates` with the shared structured memory contract from `WEB-4` and `IOS-21`.
- [ ] Add graph tables or a graph adapter interface backed by SQLite first.
- [ ] Add candidate-to-graph promotion path for confirmed facts.
- [ ] Add query API that returns compact answers plus source ids/snippets.
- [ ] Add Graphiti/Zep adapter only after local semantics and evals are stable.
- [ ] Add tests for entity merge, temporal supersession, source attribution, and sensitivity filtering.

## Verification

- Backend compile/test commands for the touched service.
- SQLite smoke on a copied production-like database.
- Query smoke: "what are my open actions?", "what projects involve drones?", "what changed since last discussion?"
- `git diff --check`

## Result

Not started.

## Next

After review/approval: continue `BACK-2` local agent share tool and `IOS-24` memory chat.

# BACK-2: Add Local Agent Memory Share Tool

Status: planned
Priority: P1
Owner: mixed
Stream: back
Branch: current worktree
Created: 2026-05-21

## Goal

Let the user grant a local agent scoped endpoint access to Her memory without giving that agent account credentials or raw database access.

## Context

The user wants a "Share to Agent" path: generate a link or local tool capability that lets another local agent retrieve relevant knowledge about the user from Her's graph. This should be an agent-facing API, not a static export.

Shares can be scoped to one concrete call/meeting, or to the user's whole memory. A local agent should be able to call convenient endpoints repeatedly, ask for full context, inspect source provenance, and retrieve graph-linked facts without being handed Her credentials, raw SQLite, or unrestricted history.

## Scope

In scope:
- Add a share-token model with scope, expiry, allowed memory kinds, sensitivity policy, and audit log.
- Add read-only local-agent query endpoints and an MCP-compatible tool wrapper.
- Support call-scoped shares such as one meeting/call with transcript, summary, memory candidates, action items, participants/speakers, source snippets, and graph links.
- Support full-memory shares with profile, projects, people, places, preferences, open actions, decisions, corrections, and source episodes.
- Support "ask Her memory" queries with provenance, source snippets, timestamps, confidence, and uncertainty labels.
- Provide endpoint shapes that are easy for agents to call without browsing UI.
- Support user-visible revoke/expire controls.
- Avoid exposing raw transcripts, secrets, payment details, or sensitive facts unless explicitly scoped and reviewed.
- Document local usage for Codex/Claude-style agents.

Out of scope:
- Public unauthenticated permanent links.
- Write access to memory from external agents.
- Sharing raw SQLite or raw audio by default.
- Full-transcript access for whole-memory shares unless explicitly enabled; call-scoped shares may include transcript when the user shares that call.
- Cloud OAuth/enterprise integrations.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Define share scopes: call, full-memory, actions, profile, projects, people, preferences, sources, transcript, sensitive-review.
- [ ] Add signed or random high-entropy local share tokens with expiry and revoke.
- [ ] Add agent-facing endpoint manifest, for example `GET /v1/agent-shares/{token}/manifest`.
- [ ] Add call context endpoint, for example `GET /v1/agent-shares/{token}/calls/{meeting_id}/context`.
- [ ] Add whole-memory context endpoint, for example `GET /v1/agent-shares/{token}/memory/context`.
- [ ] Add query endpoint, for example `POST /v1/agent-shares/{token}/query`.
- [ ] Add source endpoints for meetings, snippets, candidates, and graph neighborhoods within scope.
- [ ] Add MCP/local tool schema that wraps the same endpoints.
- [ ] Add audit records for every local-agent query.
- [ ] Add docs and smoke tests with a local agent request.

## Verification

- Backend tests for token expiry, revoke, scope filtering, and sensitivity filtering.
- Call-scoped smoke: shared call returns summary, transcript/snippets if allowed, actions, candidates, and source ids.
- Full-memory smoke: shared memory returns action/profile/project summaries and allows graph/retrieval queries without raw DB access.
- Query smoke through the local-agent tool.
- `git diff --check`

## Result

Not started.

## Next

After review/approval: wire the tool into the web/iOS Memory share UI.
