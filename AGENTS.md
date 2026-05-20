# Coding Agent Guide

This repository powers Her — a personal agent: an iOS meetings recorder with memory, a Skyvern-style web task agent, a local FastAPI backend for transcription/summary, and the long-term substrate for a wearables-driven assistant.

Read this file first, then use the linked docs for deeper context.

## Runtime Access

Everything runs locally for now. Cloud-only operation is **stage 4** of the roadmap — non-goal until earlier stages are stable.

```text
web app (Next.js):    http://localhost:3000
iOS backend (FastAPI): http://localhost:8787    (also http://Yerasyls-MacBook-Pro.local:8787 from device)
Chrome MCP endpoint:  http://127.0.0.1:12306/mcp
```

Do not commit plaintext passwords, API keys, OpenAI/Anthropic credentials, OAuth tokens, MWDAT client tokens, signing secrets, or any `.env` contents. Local secrets stay in `.env` files; never copy them into chat, commits, or shared docs.

If a credential is needed for a workflow, prefer the existing local mechanisms (passkey-PRF vault for browser creds, `.env` for service keys) over hard-coding or stuffing into a new file.

## Runtime Stack

| Surface | Location | Command | Port |
| --- | --- | --- | --- |
| Web app (Next.js) | `app/` | `cd app && pnpm launch` (or `./launch` from repo root) | `3000` |
| iOS app (Swift) | `her-ios/frontend/` | `open her-ios/frontend/ConversationSummarizer.xcodeproj` | n/a |
| iOS backend (FastAPI) | `her-ios/backend/` | `uvicorn app.main:app --host 0.0.0.0 --port 8787 --reload` | `8787` |
| Chrome MCP bridge | extension in user's Chrome | `pnpm browser:setup` then click Connect in extension | `12306` |

Quick checks:

```bash
curl -sS http://localhost:8787/health
cd app && pnpm browser:doctor
```

The Chrome MCP extension is the **only** user-mediated browser step. Chrome blocks programmatic install/enable, so if `browser:doctor` reports the endpoint as not connected, ask the user to click Connect rather than retrying.

## System Map

Important areas:

| Area | Files |
| --- | --- |
| Web app routes and pages | `app/src/app/` |
| Web UI components | `app/src/ui/` |
| Web server logic (auth, DB, agent runtime, browser policy) | `app/src/server/` |
| Browser agent + Chrome MCP integration | `app/src/server/browser*.ts`, `app/src/server/browser-workflows.mjs`, `app/src/server/web-mcp/` |
| Service registry / credentials / passkeys | `app/src/server/service-registry.ts`, `app/src/server/passkeys.ts`, `app/src/server/policies.ts` |
| Shared contracts / schemas | `app/src/shared/` |
| Web tests | `app/test/` |
| iOS app | `her-ios/frontend/` (Xcode project `ConversationSummarizer`) |
| iOS backend (Whisper + OpenAI summary, SQLite) | `her-ios/backend/app/` |
| iOS docs | `her-ios/docs/`, `her-ios/ROADMAP.md` |
| Repo-wide docs | `docs/runtime/`, `app/docs/` |
| Task tracking | `todo/tasks.md`, `todo/{ios,web,back}.md`, `todo/done/{ios,web,back}/` |

Layering rule inside `app/src/`: `ui` and `client` may import `shared`; `server` is backend-only and must not be imported from `ui`. UI calls API routes; API routes call `server`. See `app/src/README.md`.

## Agent Knowledge Model

This file is the repo-level schema for coding agents. Treat it as the
instructions for how to navigate and maintain project knowledge, not as a
scratchpad or task transcript.

The useful adaptation of Karpathy's LLM-wiki pattern is:

```text
raw project sources -> maintained repo docs/task state -> concise context for the next agent
```

Reference: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f

### Knowledge Layers

| Layer | What it is | Agent rule |
| --- | --- | --- |
| Raw sources | Code, tests, schemas, migrations, local runtime behavior, browser/iOS observations, uploaded artifacts, and external references. | Inspect before editing. Do not summarize by memory when the file or runtime can be checked directly. |
| Product docs | `README.md`, `TEST_PLAN_BROWSER_WORKFLOWS.md`, `app/docs/`, `her-ios/docs/`, and roadmaps. | Keep these current when behavior, architecture, or product scope changes. Prefer one clear source of truth over duplicated notes. |
| Task state | `todo/tasks.md`, `todo/{ios,web,back}.md`, `todo/done/`, and `docs/runtime/agent_handoff.md`. | This is the work log and review gate. Update it after implementation, but do not treat task notes as product architecture unless linked docs/code agree. |
| User memory wiki | `.data/identity/users/<user_id>/wiki/` as described in `app/docs/user-memory-wiki.md`. | This is runtime memory about the user, not repo documentation. Never copy secrets into it; use reviewable candidates for sensitive facts. |
| Agent schemas | Root `AGENTS.md`, nested `AGENTS.md`, `app/src/README.md`, and runtime workflow docs. | These define how agents operate. Update them only when the agent workflow or repo conventions change. |

### Operating The Knowledge Base

Use the repo like a maintained wiki with code as the ultimate source of truth:

1. **Orient**: read this file, `todo/tasks.md`, current branch/status, and the relevant area docs before changing behavior.
2. **Ingest**: when a new source matters, extract the durable facts into the right maintained doc or task result. Link the source instead of pasting large raw material.
3. **Query**: answer questions from current files and runtime checks. If the answer becomes durable architecture or workflow, file it in docs rather than leaving it only in chat.
4. **Lint**: when touching docs, look for stale claims, orphan references, contradictions, and duplicated guidance. Fix the closest source of truth first.
5. **Log**: record implementation results and verification in the task entry, then leave a concise handoff note only when it helps the next agent resume safely.

## Read Next

Start here in this order:

- **`README.md`** — repo overview, `./launch` flow, Chrome MCP expectations.
- **`TEST_PLAN_BROWSER_WORKFLOWS.md`** — the source of truth for what the web/browser agent must do end-to-end.
- **`app/AGENTS.md`** — Next.js–specific rules (this is **not** the Next.js you trained on; check `node_modules/next/dist/docs/` before writing app code).
- **`app/src/README.md`** — `src/` layering rules (`ui` ↔ `shared` ↔ `server`).
- **`app/docs/browser-agent-memory-roadmap.md`**, **`app/docs/user-memory-wiki.md`**, **`app/docs/credential-broker.md`**, **`app/docs/her-sessions.md`**, **`app/docs/memory-landscape.md`**, **`app/docs/web-mcp-focus.md`** — design notes for the browser agent and memory layer.
- **`her-ios/README.md`** and **`her-ios/ROADMAP.md`** — iOS app and backend setup, Meta DAT wiring.
- **`her-ios/docs/meta-wearables-dat.md`**, **`her-ios/docs/privacy-and-consent.md`** — DAT and consent reference for iOS work.
- **`docs/runtime/commit.md`** — current commit and optional PR rules.
- **`docs/runtime/agent_handoff.md`** — persistent end-of-task context and next-todo log.
- **`todo/tasks.md`** — canonical task index with `IOS-N` / `WEB-N` / `BACK-N` / `BUG-N` / `DOC-N` IDs.
- **`todo/{ios,web,back}.md`** — active task streams.

## Core Thesis (one paragraph)

Her is a personal agent built in five stages. **Stage 1 (current)** runs two parallel tracks: an **iOS meetings recorder with memory** (voice recognition, custom wake-word, MWDAT bridge for Ray-Ban Meta audio routing, local Whisper + OpenAI summary) and a **Skyvern-style web task agent** under one rule — **1 session = 1 task** — that must reliably handle blunt instructions like *order, write, book, buy, view*. **Stage 2** introduces schedules and a credential vault (Apple/Google Passwords, passkey-PRF) so the agent silently collects user data on a recurring basis. **Stage 3** is a real memory layer (two-tier site-scoped + global knowledge, see `app/docs/browser-agent-memory-roadmap.md`). **Stage 4** lifts the system into cloud-only operation; until then, local is the deployment target. **Stage 5** marries the agent with Meta Ray-Ban glasses and other wearables for scale. Do not pull stage 2+ functionality into a stage 1 task — finish the current stage first.

## Product Roadmap

The whole product is gated by these five stages. Every feature, scope decision, and "is this in scope?" question must be checked against **what stage we are in right now**. Don't pull functionality forward — finishing the current stage cleanly is the point.

Source of truth: this section. If it conflicts with a design memo, this section wins; update the memo.

### Stage 1 — current

Two parallel tracks. Both must reach "works reliably for the user, every time" before anything from later stages is added.

**Track A — iOS meetings recorder with memory** (`her-ios/`)
- Voice recognition (`faster-whisper` local; OpenAI summaries when key present, heuristic fallback otherwise).
- Custom wake-word.
- MWDAT bridge so Ray-Ban Meta glasses can act as a Bluetooth HFP audio input route.
- Local SQLite as the meeting store.
- Reference: `her-ios/README.md`, `her-ios/ROADMAP.md`, `her-ios/docs/meta-wearables-dat.md`.

**Track B — Skyvern-style web task agent** (`app/`)
- Reference: https://github.com/Skyvern-AI/skyvern.
- Goal: reliably execute blunt, direct prompts: *order, write, book, buy, view*.
- Hard rule for stage 1: **1 session = 1 task**. No persistent agent loop, no cross-task carry-over yet.
- Runs in the user's real Chrome session via the Chrome MCP — not headless.
- Reference: `TEST_PLAN_BROWSER_WORKFLOWS.md`, `app/docs/web-mcp-focus.md`, `app/docs/her-sessions.md`.

**Exit criteria for stage 1.** The web agent completes one-shot real-world tasks end-to-end in the user's browser without hand-holding, and the iOS recorder reliably captures, transcribes, and summarises a meeting. Anything that needs persistent identity, scheduled runs, or cross-task memory belongs in stage 2 or 3.

### Stage 2 — schedules and credential vault

Begins only after stage 1 is reliably working.

- Agent receives credentials from a vault: Apple Passwords, Google Passwords, browser keyvaults, and a passkey-PRF–derived local key (see `app/docs/credential-broker.md`).
- Schedules drive autonomous runs — the agent collects data about the user from their existing services on a recurring basis (calendar state, recent orders, subscriptions, account balances when read-only, etc.) without per-run user clicks.
- This is the first stage where actions happen **without** the user actively prompting; consent and audit guarantees from `her-ios/docs/privacy-and-consent.md` apply repo-wide here.
- Out of scope until stage 2 is open: scheduled background browser runs, vault-driven autofill in production flows, multi-step orchestration spanning sessions.

### Stage 3 — memory

- Two-tier knowledge graph: site-scoped facts and global facts promoted from repeated observations.
- Promotion rules, supersession, and embeddings as outlined in `app/docs/browser-agent-memory-roadmap.md` and `app/docs/memory-landscape.md`.
- iOS meeting summaries feed the same memory layer once it exists.
- Out of scope until stage 3 is open: relying on "the agent remembers X" in stage 1/2 flows. Stage 1/2 must work statelessly per session.

### Stage 4 — cloud

- Until this stage is reached, **local is the only deployment target**. Everything in `Runtime Access` and `Runtime Stack` is local on purpose.
- Stage 4 introduces a cloud-hosted runtime that mirrors the local one and makes the agent reachable when the user's machine is off.
- Out of scope until stage 4 is open: shared servers, hosted databases, cross-device sync via cloud, cloud-only credential storage.

### Stage 5 — wearables and scale

- Marry the agent with Meta Ray-Ban glasses and other wearables.
- Realtime voice agent through the glasses; Meta Wearables Device Access Toolkit (MWDAT) audio path lights up fully when Meta opens the audio API (see existing iOS roadmap in memory).
- Scale the product surface through wearable form factors, not browser tabs.
- Out of scope until stage 5 is open: shipping wearable-first flows, hardware-specific UX, multi-device fan-out.

### How to apply the roadmap to a task

When picking up or scoping a task:

1. Identify which stage the task belongs to.
2. If it's stage 1: ship it; this is where current work lives.
3. If it's stage 2+: confirm with the human that we're consciously pulling it forward, or defer it. **Do not silently ship stage 2+ work inside a stage 1 task.**
4. If a task spans stages, split it: land the stage 1 portion now, file the rest as separate tasks scoped to the right stage.

## Operating Rules

- Treat the user's local machine as the runtime source of truth. There is no shared deployed environment yet — stage 4 will introduce one.
- Before changing behavior, inspect the relevant local file (and tests if present); do not work from memory of how an area used to look.
- Do not delete recordings, SQLite databases, `.env` files, vault data, MCP token storage, or user-uploaded artifacts unless explicitly instructed.
- Keep PRs focused. Do not mix iOS, web, backend, infra, and docs unless the task explicitly requires it.
- For UI / browser-agent work, exercise the feature in a real browser through the Chrome MCP before claiming success — type checks and unit tests do not validate end-to-end browser flows. If the browser cannot be exercised in the current environment, say so explicitly.
- For iOS work, run the local `xcodebuild` smoke verification (see `her-ios/README.md`) and `python3 -m compileall her-ios/backend/app` before declaring done.
- Before creating a new `todo/` entry, follow the intake rules below: search active and done streams, and extend the closest matching task when possible.
- Every durable task must have an ID from one of the namespaces below. Branch creation and branch switching are paused for agents: work in the current worktree, normally on `main`, unless the human explicitly asks for a branch.
- Do not create a new task ID for a tiny follow-up — reuse the existing ID and current worktree.
- After executing a task, **stop for human review**. Do not commit, push, open a PR, archive a task, or mark it done until the human explicitly approves the actual result.
- The post-execution `Next` block must keep the human oriented: include the immediate review gate, what happens after approval, and the next task candidate from `todo/tasks.md`.
- Use `app/docs/` and `her-ios/docs/` for design and reference; use `todo/` for execution state. Do not pick "next work" directly from a design doc — route through `todo/tasks.md`.
- This repo intentionally has no `research` stream. Do not invent `RESEARCH-N` or `ML-N` IDs.

## Task IDs

| Namespace | Use |
| --- | --- |
| `IOS-N` | iOS app and `her-ios/` backend work |
| `WEB-N` | web app, browser-agent, Next.js work |
| `BACK-N` | non-iOS backend / API / service work |
| `BUG-N` | defects and regressions; track in the most affected stream |
| `DOC-N` | docs-only or workflow work; repo-wide in `todo/tasks.md`, area-specific in the stream |

## Task Intake

When asked to do work:

1. Read `todo/tasks.md`.
2. Search active and done tasks for similar work:
   ```bash
   rg -n "keyword|feature|bug|area" todo docs app/docs her-ios/docs
   ```
3. If a matching task exists, extend or continue it — do not duplicate.
4. If no match exists and the work is durable, create a new task entry in the right stream.
5. If the work is tiny and does not need tracking, just do it.

Do not pick next work directly from a strategy/design doc or a loose `app/docs/todo.md` note. Promote durable work into `todo/tasks.md` first.

## Task Format

Each durable task entry should include:

```text
# TASK-ID: Short Title

Status: planned | in_progress | review | approved | done | blocked
Priority: P0 | P1 | P2 | P3
Owner: agent | human | mixed
Stream: ios | web | back | repo
Branch: main (branch rules paused; use the current worktree unless the human explicitly asks for a branch)
Created: YYYY-MM-DD

## Goal
What outcome this task must produce.

## Context
Relevant background, links, decisions, constraints.

## Scope
In scope:
- ...
Out of scope:
- ...

## Implementation Plan
- [ ] Step 1
- [ ] Step 2

## Verification
Commands, manual checks, screenshots, metrics, or review criteria.

## Result
Filled after implementation.

## Next
Immediate review gate, follow-up after approval, next task candidate.
```

## Sorting and Priority

- `P0`: production broken, data loss, security, deploy blocker.
- `P1`: blocks current stage 1 milestone or core user workflow.
- `P2`: important improvement, not blocking.
- `P3`: cleanup, polish, nice-to-have.

When choosing next work, prefer blocked dependencies, then production risk, milestone impact, user value, low effort.

## Branch Policy

Branch creation, switching, and renaming are temporarily disabled for agents.
Development happens in the current worktree, normally on `main`.

Do not create or switch branches during task execution unless the human
explicitly asks. Existing task entries may still contain historical `Branch:`
values; do not rewrite them just to match this temporary policy.

If the human explicitly asks for a task branch, use the strict format:

```text
ios/IOS-N/short-slug
web/WEB-N/short-slug
back/BACK-N/short-slug
fix/BUG-N/short-slug
docs/DOC-N/short-slug
```

Examples:

```text
ios/IOS-12/recording-permissions
web/WEB-8/browser-service-registry
back/BACK-5/summary-cache
fix/BUG-7/login-token-refresh
docs/DOC-3/deployment-runbook
```

Worktree branches like `claude/<slug>` or `codex/<slug>` are scratch. Do not
push from a scratch branch unless the human explicitly approves renaming or
pushing that branch.

## Implementation Flow

For every non-trivial task:

1. Confirm task ID and current worktree/branch.
2. Inspect relevant files.
3. Write a short plan.
4. Implement the smallest coherent change.
5. Add or update tests when behavior changes.
6. Run verification (see Testing Rules).
7. Update the task entry with result, commands, and known risks.
8. Stop for human review.

Do not continue into commit, push, PR, archive, or done-state updates until approval.

## Testing Rules

Use risk-based verification:

- Small isolated change: run the targeted test or local smoke check.
- Shared logic change: run the affected test file/module.
- API or UI change: run tests **plus** a real browser exercise via Chrome MCP for web, or `xcodebuild` + device/simulator smoke for iOS.
- Migration or data change: verify on a copy or local SQLite snapshot first; never on the user's live data without explicit approval.

If tests cannot run in the current environment, say so explicitly and list what was checked instead. Record verification commands in the task `Result`.

## Commit And PR Flow

After the human approves the implemented result:

1. `git status` — confirm clean scope.
2. Stage only files related to the task.
3. Commit with the standard multi-line format from `docs/runtime/commit.md`.
4. Push only if the human explicitly asks.
5. Open a PR only if the human explicitly asks or if a non-`main` branch was explicitly requested.
6. Include the task ID in the PR title when creating a PR.

Commit format summary:

```text
<type>: <what was done>

[details, if useful]

Closes #TASK-ID
```

Examples:

```text
feat: add browser service registry

Register the browser service runtime and document the local Chrome MCP setup.

Closes #WEB-8

fix: retry token refresh failures

Preserve the original session when refresh fails once and retry with backoff.

Closes #BUG-7
```

Add detail lines only when they clarify what changed or why. Always include the
task trailer. If there is no GitHub issue or issue-style alias for the task,
use `Refs TASK-ID` instead of the `Closes #TASK-ID` trailer.

PR body:

```text
## Summary
- What changed
- Why it changed

## Verification
- Command/check 1
- Command/check 2

## Task
Closes/Refs TASK-ID

## Notes
Risks, follow-ups, deploy notes.
```

## Review Gate

After implementation, always stop with:

```text
Result is ready for human review.

Reviewed changes:
- ...

Verification:
- ...

Known risks:
- ...

Next after approval:
- commit
- push/PR only if requested
- archive/update task
```

## Completion and Archive

A task is complete only after human approval and the requested commit/push/PR
workflow is handled.

When completed:

1. Get explicit human approval for the actual result.
2. Commit the approved work with the standard commit message; push only if requested.
3. Update the task `Result` with outcome, commands, metrics, links.
4. Move completed stream details to `todo/done/<stream>/`.
5. Link the PR, docs, and verification from the moved task.
6. Update `todo/tasks.md` (status / archive entry).
7. Update relevant docs if behavior or architecture changed.
8. Add a concise entry to `docs/runtime/agent_handoff.md` with context and the immediate next todo.

Do not leave completed task entries active in stream files.

## Agent Collaboration

When multiple agents are used:

- One agent is the coordinator. The coordinator owns task state, current-worktree scope, final integration, and review summary.
- Worker agents may inspect or implement scoped parts.
- Workers must not revert changes they did not make.
- Workers must report changed files, verification results, and known risks.
- The coordinator reviews and integrates worker output before the final response.

Use parallel agents only for independent work, e.g.:

- Agent A: inspect backend/API impact.
- Agent B: inspect web/UI impact.
- Agent C: inspect tests and fixtures.

Do not assign overlapping write scopes to multiple agents.

## Final Response Format

When work is implemented but not yet approved:

```text
Implemented TASK-ID.

Changed:
- ...

Verified:
- ...

Not run:
- ...

Needs review:
- ...

Next after approval:
- commit, push/PR if requested, archive/update task.
```

Keep final answers concise and factual.
