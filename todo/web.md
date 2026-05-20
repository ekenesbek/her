# Web Tasks

Active `WEB-N` tasks and web-scoped `BUG-N` tasks live here.

# WEB-1: Rename Project To Her

Status: approved
Priority: P1
Owner: agent
Stream: web
Branch: web/WEB-1/rename-her
Created: 2026-05-07

## Goal

Rename the internal project/product identity from `meta`/`Meta` to `Her`.

## Context

The repository contains both internal project naming and external Meta Wearables DAT references. Internal product, package, storage, and documentation names should move to `Her`; external Meta/Facebook SDK names, keys, package URLs, and user-facing glasses integration labels should remain accurate.

## Scope

In scope:
- Update web app product copy, metadata, storage namespaces, and runtime paths.
- Update iOS/backend project names, bundle identifiers, display names, and task/docs references where they describe the internal project.
- Update repo docs and workflow maps to use Her naming.

Out of scope:
- Rename the GitHub repository/remote before review approval.
- Change external Meta Wearables DAT names, SDK URLs, Info.plist keys, or Facebook package identities.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect internal and external `meta`/`Meta` occurrences.
- [x] Rename internal web project identifiers and copy.
- [x] Rename internal iOS/backend identifiers and docs.
- [x] Run targeted verification and record results.

## Verification

- `pnpm lint`
- `pnpm test`
- `pnpm build`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO clean build`
- `rg -n "\[META-T|meta-ios|metaagent|meta\.app|Meta App|meta_credentials|mcp__meta_credentials|meta\.lang|meta\.exact|meta\.keys|meta-pulse|~/.meta|META_HOME|ensureMetaHome" -g '!app/.next/**' -g '!app/node_modules/**' -g '!her-ios/frontend/DerivedData/**' -g '!**/.venv/**' -g '!**/*.sqlite3'`

## Result

Renamed the internal project identity to Her across the web app, runtime namespaces, repo docs, iOS/backend folder path, iOS bundle/display/product names, AppIntent labels, backend package/title defaults, and browser workflow test labels.

Preserved external Meta Wearables DAT naming, SDK package references, Info.plist `MetaAppID`/`META_APP_ID` keys, and Ray-Ban Meta device copy/detection. The web database now uses `.data/her.db` and copies existing `.data/meta.db` into the new file on first startup when needed.

## Next

Human approved the implemented result. Next: commit, push, open draft PR, then wait for merge before archival.

# WEB-2: Add Terms And Privacy Pages

Status: review
Priority: P2
Owner: agent
Stream: web
Branch: web/WEB-2/terms-privacy
Created: 2026-05-07

## Goal

Add public `/terms` and `/privacy` pages for Her with on-brand placeholder copy.

## Context

The app needs basic legal entry points before the final legal text is ready. The copy should be clearly framed as a working draft and should match the current quiet, editorial Her visual style.

## Scope

In scope:
- Add `/terms` and `/privacy` App Router pages.
- Add shared legal page presentation if useful.
- Link to the pages from the public login surface.
- Run focused web verification.

Out of scope:
- Final legal review or jurisdiction-specific terms.
- Changes to auth, backend, iOS, or browser-agent behavior.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect public page styling and routing.
- [x] Add shared legal page UI and copy.
- [x] Add public links from login.
- [x] Run lint/build checks and record result.

## Verification

- `sed -n '1,220p' app/node_modules/next/dist/docs/01-app/01-getting-started/03-layouts-and-pages.md`
- `sed -n '1,180p' app/node_modules/next/dist/docs/01-app/01-getting-started/14-metadata-and-og-images.md`
- `pnpm lint`
- `pnpm build`
- `pnpm exec next start --port 3004`
- `curl -I --max-time 10 http://localhost:3004/terms`
- `curl -I --max-time 10 http://localhost:3004/privacy`
- `curl -s --max-time 10 http://localhost:3004/terms | rg -n "Условия использования|terms|Her"`
- `curl -s --max-time 10 http://localhost:3004/privacy | rg -n "Конфиденциальность|privacy|Her"`

## Result

Added public `/terms` and `/privacy` App Router pages with shared Her legal-page styling, static metadata, and working-draft Russian copy. Added Terms and Privacy links to the login footer so the pages are discoverable before authentication.

The pages are intentionally draft legal copy, not final reviewed legal terms. Production server checks returned `200 OK` for both pages. Existing unrelated iOS worktree changes were left untouched.

## Next

Result is ready for human review. After approval: commit, push, open PR, then archive/update task state.

# WEB-3: Add Local Wiki-Style User Memory

Status: review
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Adapt the existing local identity memory into a Karpathy-style, inspectable user memory wiki with safer write rules and a clear provider stance for future Stage 3 memory work.

## Context

The app already had `.data/identity/users/<id>/user.md` and per-agent `soul.md`, with hidden `<remember-user>` / `<remember-self>` tags appended after agent replies. The user asked whether the LLM-wiki principle can become Her's user wiki/memory, and whether existing OSS memory projects should be adopted.

Roadmap constraint: full cross-session memory and knowledge graph behavior is Stage 3. This task is a narrow hardening of existing local memory, not scheduled autonomy, provider-backed memory, or a full graph.

## Scope

In scope:
- Add a local user-scoped wiki layout under `.data/identity/users/<user_id>/wiki/`.
- Add wiki `index.md`, `schema.md`, `log.md`, and core pages for profile, preferences, people, places, projects, decisions, corrections, and inbox.
- Categorize existing `<remember-user>` notes into wiki pages.
- Redact obvious secret values before writing prompt-readable memory.
- Update runtime instructions so memory is evidence, not permission.
- Document the Her-specific memory architecture and OSS provider stance.

Out of scope:
- Hosted/cloud memory.
- Scheduled jobs or autonomous memory writes outside the existing reply flow.
- A full temporal graph or embeddings/RAG integration.
- User-visible memory settings UI.
- Commit, push, PR, archival, or marking done before human review.

## Implementation Plan

- [x] Inspect current memory docs and local identity storage.
- [x] Implement local wiki files and safer append logic.
- [x] Update runtime memory instructions.
- [x] Document the wiki-memory architecture and provider comparison.
- [x] Run verification and record results.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`

## Result

Implemented a local wiki-style layer on top of existing identity memory. New users now get `.data/identity/users/<id>/wiki/` with `schema.md`, `index.md`, `log.md`, and scoped pages. `<remember-user>` notes are normalized, obvious credential/secret values are redacted before prompt-readable persistence, classified into relevant pages, appended as candidate notes, and logged. Runtime prompt copy now treats memory as source-bound evidence rather than ground truth or permission.

Added `app/docs/user-memory-wiki.md`, updated `app/docs/memory-landscape.md`, and linked the wiki-memory approach from `app/docs/browser-agent-memory-roadmap.md`.

Verification passed with lint, node tests, and production build.

## Next

Result is ready for human review. After approval: commit only this task's files; push/PR only if requested; then archive/update task state. Next task candidate: add structured `memory_entries` rows and a curator that regenerates wiki pages from structured state instead of appending markdown forever.

# WEB-4: Add Structured Memory Entries Store

Status: planned
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Make structured local memory rows the source of truth for Her user, agent, site, task, and meeting memory.

## Context

`WEB-3` created a local LLM-wiki layer and append-only candidate notes. The next step is a typed SQLite substrate that can support review, dedupe, supersession, expiry, source links, and later compilation into wiki pages.

## Scope

In scope:
- Add `memory_entries` and related TypeScript types to the web app local DB.
- Track `scope`, `kind`, `text`, `confidence`, `sensitivity`, `status`, source type/id/span, `supersedes_id`, `expires_at`, and timestamps.
- Add read/write/update helpers with secret redaction and status transitions.
- Keep existing `.data/identity` wiki compatible while rows become the canonical source.

Out of scope:
- Full curator extraction.
- Review UI.
- OSS provider adapters.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Inspect current `app/src/server/db.ts` and identity storage.
- [ ] Add memory schemas, migrations, and helpers.
- [ ] Add tests for redaction, status transitions, source refs, and supersession.
- [ ] Update docs and task result.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`

## Result

Not started.

## Next

After review/approval: continue `WEB-5` curator pipeline.

# WEB-5: Add Post-Task Memory Curator Pipeline

Status: planned
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Add a post-task/post-chat curator that extracts durable memory candidates into structured `memory_entries`.

## Context

Current hidden `<remember-user>` blocks are useful but too dependent on the final answer. A curator should read sources after the task finishes and write structured candidates with confidence and provenance.

## Scope

In scope:
- Curate from latest user message, assistant answer, task trace, browser run metadata, and Web MCP updates.
- Extract preferences, places, people, projects, decisions, corrections, blockers, and task outcomes.
- Redact secret values and mark sensitive/review candidates.
- Dedupe against existing memory and supersede contradictions.
- Keep writes as `candidate` unless explicit user instruction supports auto-confirm.

Out of scope:
- iOS meeting transcript curator, tracked in `IOS-21`.
- Review UI, tracked in `WEB-7`.
- Provider-backed extraction.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Define curator input/output contract.
- [ ] Add local heuristic fallback plus LLM-backed extraction when configured.
- [ ] Add dedupe/supersession logic.
- [ ] Persist candidates through `memory_entries`.
- [ ] Add targeted tests.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`

## Result

Not started.

## Next

After review/approval: continue `WEB-6` wiki compiler.

# WEB-6: Compile Memory Wiki From Structured Entries

Status: planned
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Regenerate the local markdown memory wiki from structured `memory_entries` instead of appending notes forever.

## Context

Karpathy-style LLM wiki works best as compiled memory. The markdown files should be a readable projection of structured state, not the only canonical store.

## Scope

In scope:
- Add a wiki compiler for `profile`, `preferences`, `people`, `places`, `projects`, `decisions`, `corrections`, and `inbox`.
- Include source ids, confidence/status labels, and sensitivity markers.
- Preserve manual edits through explicit review/update paths rather than uncontrolled markdown mutation.
- Keep `soul.md` for agent memory, with future structured agent entries.

Out of scope:
- Semantic search.
- Memory review UI.
- Graph/provider adapters.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Define page templates and grouping rules.
- [ ] Implement compiler from `memory_entries` to wiki pages.
- [ ] Run compiler after relevant memory writes.
- [ ] Add tests for stable output and superseded/rejected filtering.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`

## Result

Not started.

## Next

After review/approval: continue `WEB-7` review UI and `WEB-8` retrieval.

# WEB-7: Add Memory Review API And Web UI

Status: planned
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Let the user inspect, confirm, edit, reject, forget, and export memory from the web app.

## Context

Memory cannot become aggressive without a user-visible correction path. This is required before promoting call/browser candidates into global memory.

## Scope

In scope:
- Add authenticated memory APIs for list/detail/update/confirm/reject/forget/export.
- Add a Settings or `/memory` UI for global user memory, agent memory, and candidates.
- Show source links back to chat/task/meeting when available.
- Keep destructive actions explicit and auditable.

Out of scope:
- iOS call detail UI, tracked in `IOS-22`.
- Cloud sync.
- Provider-backed graph UI.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Design API payloads and status transitions.
- [ ] Build memory list/detail/edit UI.
- [ ] Add confirm/reject/forget/export actions.
- [ ] Add tests and browser smoke where feasible.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`
- Browser smoke against local app if UI is implemented.

## Result

Not started.

## Next

After review/approval: continue `WEB-8` retrieval selector.

# WEB-8: Add Relevant Memory Retrieval Selector

Status: planned
Priority: P1
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Inject only relevant user, agent, Web MCP, and session memory into agent runtime context.

## Context

The app should not stuff the whole wiki into every prompt. Memory retrieval should be scoped by the latest task, agent, site, topic, and sensitivity.

## Scope

In scope:
- Add retrieval helpers over `memory_entries` and compiled wiki pages.
- Select memory by task text, agent id, site/origin, source type, status, confidence, and sensitivity.
- Inject concise memory snippets with source and uncertainty labels.
- Keep candidate/review memory weak and avoid using stale entries without verification.

Out of scope:
- qmd/Graphiti/Mem0 adapters, tracked in `WEB-9`.
- UI for editing memory.
- Scheduled jobs.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Define retrieval policy and budgets.
- [ ] Implement lexical scoring first, with optional vector/search adapter later.
- [ ] Wire retrieval into chat/browser runtime context.
- [ ] Add tests for relevance, sensitivity filtering, and source labels.

## Verification

- `cd app && pnpm lint`
- `cd app && pnpm test`
- `cd app && pnpm build`
- Targeted browser-agent smoke when retrieval affects browser tasks.

## Result

Not started.

## Next

After review/approval: continue `WEB-9` evals/adapters.

# WEB-9: Add Memory Evals And Optional Provider Adapters

Status: planned
Priority: P2
Owner: agent
Stream: web
Branch: current worktree
Created: 2026-05-19

## Goal

Measure whether memory improves Her and add optional adapters only after local contracts are stable.

## Context

OSS memory systems are useful references, but Her should own the product semantics first. Adapters should be replaceable implementation details.

## Scope

In scope:
- Add evals for preference recall, correction handling, call commitments, browser repeated tasks, and safety stops.
- Compare memory-on vs memory-off behavior.
- Prototype optional adapters behind an internal interface: qmd for markdown search, Graphiti/Zep for temporal graph, Mem0 for memory SDK/server.
- Keep local SQLite/wiki as the baseline.

Out of scope:
- Replacing Her memory semantics with an external provider.
- Cloud-only operation.
- Model fine-tuning.
- Commit, push, PR, archive, or marking done before human review.

## Implementation Plan

- [ ] Define product-specific memory eval cases.
- [ ] Add eval runner and metrics.
- [ ] Add adapter interface.
- [ ] Prototype one adapter only if it improves evals without owning product semantics.

## Verification

- `cd app && pnpm test`
- Memory eval run with before/after metrics.
- Adapter smoke if implemented.

## Result

Not started.

## Next

After review/approval: use eval results to decide whether Graphiti/qmd/Mem0 integration is worth implementing.
