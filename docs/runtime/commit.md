# Branch, Commit, And PR Rules

This repo uses task-ID branches and conventional commit messages with task
trailers. Add detail lines when they clarify the change; do not pad commits
with empty description.

## Branch Names

Use the exact task branch format from `AGENTS.md`:

```text
ios/IOS-N/short-slug
web/WEB-N/short-slug
back/BACK-N/short-slug
fix/BUG-N/short-slug
docs/DOC-N/short-slug
```

Rules:

- The task ID must exist in `todo/tasks.md` unless the work is tiny and does
  not need tracking.
- Use lowercase kebab-case for the final slug.
- Keep branch names task-focused, not person-focused.
- Worktree scratch branches like `codex/...` must be renamed before push.

## Commit Messages

Only commit after the human has approved the actual result for the task.

Format:

```text
<type>: <what was done>

[details: what changed and why, if useful]

Closes #TASK-ID
```

Use `feat:` for normal product/code/doc task work unless another type is more
accurate:

```text
feat: add voice enrollment wake-word task

Add IOS-4 to the task index and iOS stream.
Document guided Your Voice reading/Q&A, consent states, and wake-word samples.

Closes #IOS-4
```

Other valid types:

```text
fix: retry token refresh failures
docs: add runtime commit rules
test: cover browser service registry
chore: update task handoff notes
refactor: split voice enrollment helpers
```

Rules:

- Keep the first line under 72 characters when practical.
- Use the subject to say what was done, not only which file changed.
- Add a blank line after the subject.
- Include implementation details, behavior changes, tests, metrics, and
  task/doc links only when they add useful context beyond the subject.
- End with `Closes #TASK-ID` when the PR is meant to close the issue/task.
- Use `Refs TASK-ID` when there is no GitHub issue or issue-style alias to
  close.
- Do not include secrets, passwords, API keys, OAuth tokens, signing secrets,
  `.env` values, or local credential material.

## PR Descriptions

PRs must include a real description; do not leave the body empty.

Use this shape:

```text
## Summary
- What changed
- Why it changed

## Verification
- Command/check 1
- Command/check 2

## Task
Closes #TASK-ID

## Notes
Risks, follow-ups, deploy notes, or "None".
```

If PR creation is blocked and the user must open it manually, provide the title
and full Markdown body in the final response.
