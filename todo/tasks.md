# Task Index

Canonical index for durable work. Active stream details live in `todo/ios.md`, `todo/web.md`, and `todo/back.md`. Repo-wide documentation/workflow tasks may live directly in this file.

## Active

| ID | Status | Priority | Stream | Branch | Title | Location |
| --- | --- | --- | --- | --- | --- | --- |
| DOC-1 | review | P2 | repo | docs/DOC-1/task-workflow | Set up task-first agent workflow | `todo/tasks.md` |
| WEB-1 | approved | P1 | web | web/WEB-1/rename-her | Rename project to Her | `todo/web.md` |
| WEB-2 | review | P2 | web | web/WEB-2/terms-privacy | Add Terms and Privacy pages | `todo/web.md` |
| IOS-2 | review | P1 | ios | ios/IOS-2/skip-setup-existing-account | Skip iOS setup for existing accounts | `todo/ios.md` |
| IOS-3 | planned | P2 | ios | ios/IOS-3/server-setup-state | Store iOS setup state on backend | `todo/ios.md` |
| IOS-1 | review | P1 | ios | ios/IOS-1/her-ios-smoke-test | Her iOS smoke test | `todo/ios.md` |
| IOS-4 | planned | P1 | ios | ios/IOS-4/voice-enrollment-wake-word | Improve voice enrollment and wake-word setup | `todo/ios.md` |
| IOS-5 | approved | P3 | ios | ios/IOS-5/onboarding-agent-before-voice | Put agent name before voice enrollment | `todo/ios.md` |
| BUG-1 | review | P1 | ios | fix/BUG-1/voice-enrollment-audio-fallback | Fall back from Bluetooth voice enrollment recorder | `todo/ios.md` |
| IOS-6 | approved | P2 | ios | ios/IOS-6/auth-screen-polish | Polish iOS auth screen | `todo/ios.md` |
| IOS-7 | review | P1 | ios | current worktree | Add background meeting processing jobs | `todo/ios.md` |
| IOS-8 | review | P1 | ios | current worktree | Add meeting contents outline and speaker transcript | `todo/ios.md` |
| IOS-9 | review | P1 | ios | current worktree | Wire Alem OSS summaries and meeting chat | `todo/ios.md` |
| IOS-10 | review | P1 | ios | current worktree | Persist meeting audio and improve transcript playback | `todo/ios.md` |
| IOS-11 | planned | P1 | ios | current worktree | Add streaming audio processing for faster transcription | `todo/ios.md` |
| BUG-2 | blocked | P1 | ios | current worktree | Clean AI summaries and add audio scrubber | `todo/ios.md` |

## DOC-1: Set Up Task-First Agent Workflow

Status: review
Priority: P2
Owner: agent
Stream: repo
Branch: docs/DOC-1/task-workflow
Created: 2026-05-04

### Goal

Create a repo-level task-first workflow that matches this repository's actual streams: `ios`, `web`, and `back`.

### Context

The requested workflow guide included `research` and `dev` streams, but this repo uses iOS, web, and backend areas instead.

### Scope

In scope:
- Add a root `AGENTS.md` workflow guide.
- Add canonical task and stream files under `todo/`.
- Add a runtime handoff note file under `docs/runtime/`.

Out of scope:
- Commit, push, PR, archival, or marking the task done before human review.
- Changes to product code.

### Implementation Plan

- [x] Inspect existing workflow docs and project layout.
- [x] Create root workflow and task tracking files.
- [x] Record verification and stop for human review.

### Verification

- `rg --files -g 'AGENTS.md' -g 'todo/**' -g 'docs/runtime/agent_handoff.md'`
- `sed -n '1,260p' AGENTS.md`
- `sed -n '1,220p' todo/tasks.md`

### Result

Created repo-level workflow docs and task tracking structure adapted to `ios`, `web`, and `back`. Existing unrelated `her-ios/*` worktree changes were left untouched.

### Next

Needs human review. After approval: commit, push, open PR, then archive/update task state.

## Stream Files

- `todo/ios.md`: active iOS task stream.
- `todo/web.md`: active web task stream.
- `todo/back.md`: active backend task stream.

## Done Archive

- `todo/done/ios/`
- `todo/done/web/`
- `todo/done/back/`

## Notes

- `app/docs/todo.md` is an existing loose product note. Promote durable work from it into this index before implementation.
- This repository intentionally has no `research` stream.
