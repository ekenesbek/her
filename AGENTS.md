# Agent Workflow Guide

This repository uses a task-first agent workflow. Read this file before doing any work, then keep task state current from intake through implementation, review, PR, and archival.

## Core Rules

- Do not commit, push, open PRs, close tasks, archive tasks, or mark work done unless the human explicitly approves the actual result.
- Keep changes focused. Do not mix unrelated docs, UI, backend, iOS, infra, and business logic unless the task explicitly requires it.
- Never delete production data, credentials, logs, datasets, or user files unless explicitly instructed.
- Do not commit secrets, API keys, passwords, private keys, `.env` contents, tokens, or credentials.
- Prefer existing project patterns over new abstractions.
- Before changing behavior, inspect the relevant code and tests.
- After implementation, run the narrowest useful verification first, then broader tests if risk requires it.
- Preserve unrelated worktree changes. If the worktree is dirty, do not revert or overwrite changes you did not make.

## Project Map

```text
app/                         web app and browser-agent product code
app/AGENTS.md                additional Next.js rules for app/ changes
app/src/                     web application source
app/test/                    web tests
meta-ios/frontend/           iOS application
meta-ios/backend/            backend service for the iOS app
meta-ios/docs/               iOS/backend-specific docs
docs/runtime/                runtime handoff notes
todo/tasks.md                canonical task index
todo/ios.md                  active iOS task stream
todo/web.md                  active web task stream
todo/back.md                 active backend task stream
todo/done/ios/               archived completed iOS tasks
todo/done/web/               archived completed web tasks
todo/done/back/              archived completed backend tasks
```

Adjust this map when the project structure changes.

## Task IDs

Every durable task must have an ID. This repo does not use a `research` stream or `RESEARCH-N` IDs.

Use these namespaces:

- `IOS-N`: iOS app work.
- `WEB-N`: web app, browser-agent, and Next.js work.
- `BACK-N`: backend/API/service work.
- `BUG-N`: defects or regressions. Track the task in the most affected stream.
- `DOC-N`: documentation-only or workflow work. Track repo-wide docs tasks in `todo/tasks.md`; track area-specific docs in the matching stream.

Do not create a new task ID for a tiny follow-up to an existing task. Reuse the closest task ID and add a new branch slug.

## Task Intake

When asked to do work:

1. Read `todo/tasks.md`.
2. Search active and done tasks for similar work.
3. If a matching task exists, extend or continue it.
4. If no matching task exists and the work is durable, create a new task entry.
5. If the work is tiny and does not need tracking, do it directly without creating a task.

Before creating a task, search relevant docs and task files:

```bash
rg -n "keyword|feature|bug|area" todo docs app/docs meta-ios/docs
```

Do not pick next work directly from a strategy doc or loose todo note. Route durable work through `todo/tasks.md`.

## Task Format

Each durable task entry should include:

```text
# TASK-ID: Short Title

Status: planned | in_progress | review | approved | done | blocked
Priority: P0 | P1 | P2 | P3
Owner: agent | human | mixed
Stream: ios | web | back | repo
Branch: ios/IOS-N/short-slug | web/WEB-N/short-slug | back/BACK-N/short-slug | fix/BUG-N/short-slug | docs/DOC-N/short-slug
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
- [ ] Step 3

## Verification

Commands, manual checks, screenshots, metrics, or review criteria.

## Result

Filled after implementation.

## Next

Immediate review gate, follow-up action after approval, and next task candidate.
```

## Sorting And Priority

Sort work by this order:

- `P0`: production broken, data loss, security, deploy blocker.
- `P1`: blocks current milestone or core user workflow.
- `P2`: important improvement, not blocking.
- `P3`: cleanup, polish, nice-to-have.

When choosing next work, prefer blocked dependencies, then production risk, milestone impact, user value, and low effort.

## Branch Rules

Use one branch per task.

Branch naming:

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

Do not use personal prefixes unless the human explicitly asks.

## Implementation Flow

For every non-trivial task:

1. Confirm task ID and branch.
2. Inspect relevant files.
3. Write a short plan.
4. Implement the smallest coherent change.
5. Add or update tests when behavior changes.
6. Run verification.
7. Update the task entry with result, commands, and known risks.
8. Stop for human review.

Do not continue into commit, push, PR, archive, or done-state updates until approval.

## Testing Rules

Use risk-based verification:

- Small isolated change: run targeted tests.
- Shared logic change: run affected test file/module.
- API or UI change: run tests plus manual endpoint/browser check if relevant.
- Migration or data change: verify on a copy or staging first.

If tests cannot run, explain why and list what was checked instead. Record verification commands in the task result.

## PR Flow

After the human approves the implemented result:

1. Check git status.
2. Stage only files related to the task.
3. Commit with a focused message.
4. Push the task branch.
5. Open a draft PR unless the human asks for a ready PR.
6. Include the task ID in the PR title.

Commit format:

```text
TASK-ID: short imperative summary
```

Examples:

```text
WEB-8: add browser service registry
BACK-5: add summary cache refresh
BUG-7: fix token refresh retry handling
DOC-3: add deployment runbook
```

PR body format:

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
- push
- open PR
- archive/update task
```

## Completion And Archive

A task is complete only after human approval and the PR/merge workflow is handled.

When completed:

1. Update the task result.
2. Move completed stream task details to `todo/done/<stream>/`.
3. Link the PR, docs, metrics, and verification.
4. Update `todo/tasks.md`.
5. Update relevant docs if behavior or architecture changed.
6. Add a short handoff note in `docs/runtime/agent_handoff.md` when useful.

Do not leave completed task entries active in stream files.

## Agent Collaboration

When multiple agents are used:

- One agent is the coordinator.
- The coordinator owns task state, branch naming, final integration, and review summary.
- Worker agents may inspect or implement scoped parts.
- Workers must not revert changes they did not make.
- Workers must report changed files, verification, and risks.
- The coordinator reviews and integrates worker output before final response.

Use parallel agents only for independent work, for example:

- Agent A: inspect backend API impact.
- Agent B: inspect frontend/UI impact.
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
- commit, push, PR, archive/update task.
```

Keep final answers concise and factual.
