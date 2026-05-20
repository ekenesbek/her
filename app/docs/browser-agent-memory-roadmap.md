# Browser Agent Memory Roadmap

Plan for making `Her` agents better at repeated browser work, credential-gated flows, scheduled browser jobs, and long-term user preference learning.

This plan connects existing notes:

- [Web MCP Focus](./web-mcp-focus.md)
- [Credential Broker](./credential-broker.md)
- [Her Sessions](./her-sessions.md)
- [Memory Landscape](./memory-landscape.md)
- [User Memory Wiki](./user-memory-wiki.md)

## Thesis

The agent should improve first through better runtime context, not model fine-tuning.

The practical loop is:

```text
browser task -> observed pages/actions/outcomes -> Web MCP graph
browser task -> user decisions/corrections -> user memory/preferences
browser task -> task trace/session summary -> searchable history
repeated task -> retrieve relevant graph/memory/history -> fewer steps and safer choices
```

LoRA or RL can come later, after we have enough clean trajectories and evals. The immediate product value comes from reliable local memory and reusable browser knowledge.

## Product Goals

1. Agents complete browser tasks with fewer failed clicks, less rediscovery, and clearer blockers.
2. Agents use existing logged-in sessions and credential approvals safely without exposing secrets to the model.
3. Scheduled browser jobs can run with scoped grants and stop before irreversible actions.
4. Agents extract durable user preferences, decisions, addresses, service choices, recurring constraints, and workflow habits.
5. Web MCP makes repeated visits faster by storing site-specific page patterns, semantic actions, flows, blockers, and freshness.

## Golden Workflow: Taxi / Ride-Hailing

Taxi is the first production-quality browser workflow because it forces the core product loop: user location, logged-in browser session, service choice, saved places, credential/passkey handling, price/ETA comparison, and a strict stop before the final irreversible order.

Target flow:

1. Use exact browser location as pickup when permission is available.
2. Resolve destination from the latest message, confirmed user memory, or saved places visible in the logged-in taxi/maps surface.
3. Open Chrome through the app-managed MCP connection automatically.
4. Discover the provider from Web MCP memory, open logged-in tabs, service registry, and local browser/web evidence instead of assuming one fixed site.
5. Open the provider website/PWA, prepare the ride, compare class/price/ETA, and recommend the best option.
6. Stop at the final confirmation screen and ask before clicking the order/payment button.
7. Record the provider, successful page flow, blockers, selected class, and user corrections into Web MCP/user memory for faster repeats.

MVP acceptance criteria:

- A request like "Закажи такси домой" does not ask for current location when exact browser location is present.
- If home is not known, the agent first checks confirmed memory and saved places in the provider/browser surface; only then asks for the missing destination.
- The first run may discover a provider; repeated runs should reuse remembered provider/flow hints and spend fewer browser steps/tokens.
- The agent never sees raw passwords/passkeys and never places the final order without chat confirmation.

This workflow should remain a template for local transactional services, not a one-off hardcode. The same shape later applies to delivery, reservations, shopping, travel, and local appointments.

## Non-Negotiable Safety Rules

- Never put passwords, tokens, cookies, MFA codes, passkey material, payment card data, or recovery codes into prompts, memory, traces, or Web MCP.
- Credential use is origin-bound, approval-driven, auditable, and revocable.
- Scheduled jobs are read-only by default.
- Sending, deleting, archiving, purchasing, ordering, granting access, revealing tokens, or changing account security must stop at confirmation and ask the user.
- Memory is contextual guidance, not permission. A remembered preference cannot authorize an irreversible action.

## Architecture Shape

### 1. Browser Execution Layer

The browser runtime should enforce a repeatable loop:

1. Set a short milestone.
2. Observe current state with screenshot when useful and compact interactive page read.
3. Query Web MCP for known page pattern, actions, and flow hints.
4. Choose the action that best advances the milestone.
5. Execute with browser MCP.
6. Verify the resulting state.
7. Record page/action/edge/outcome.

The agent should not keep continuing from an old open tab unless the latest user message asks for that same flow. Open tabs are starting points, not truth.

### 2. Credential Broker Layer

Credential broker stays outside the model.

MVP behavior:

- Model can request credential approval with origin, URL, reason, account hint, and requested action.
- UI pauses the task and lets the user approve or deny.
- Model receives only non-secret approval status.
- User-mediated login continues in the live browser.

Next layer:

- native helper, browser extension, or OS credential-provider bridge
- origin-bound fill into the browser surface
- no plaintext return path to LLM or server logs
- credential usage audit log
- scheduled read grants with expiry and revoke

### 3. Web MCP Memory Layer

Web MCP is the site/workflow memory, not the general user memory.

Store per user and site:

- canonical page pattern
- compact page summary
- semantic actions and forms
- observed edges between pages/states
- required inputs
- auth mode
- blockers
- confidence
- freshness
- task outcomes

The retrieval path should answer:

- "What page/state am I on?"
- "What known actions exist here?"
- "What path got us to billing settings last time?"
- "Which edge is stale or blocked?"
- "Does this flow require login, user presence, broker approval, or final confirmation?"

### 4. User Preference Memory Layer

General user memory should store durable facts and preferences that apply across sites.

Examples:

- home/work address only when explicitly stated or confirmed
- preferred taxi class or delivery service
- meal constraints, travel constraints, budget preferences
- "do not ask verbose clarification unless needed"
- "for flights, prioritize direct routes over cheapest option"
- recurring account/service choices

This should be separate from Web MCP site memory. Web MCP can mirror durable cross-site facts into user memory, but site-specific details stay under the site.

The first local implementation follows the LLM-wiki pattern instead of provider-first memory:

- raw sources remain task traces, chat turns, browser observations, and meeting outputs
- compiled memory lives under `.data/identity/users/<user_id>/wiki/`
- `index.md` catalogs memory pages
- `schema.md` defines what may be written and what must never be written
- `log.md` records memory maintenance events
- candidate notes are weak context until corroborated or confirmed

This is a bridge toward Stage 3, not the full memory graph. The next production version should add structured `memory_entries` rows and regenerate wiki pages from structured state instead of appending markdown forever.

### 5. Session Search Layer

Add FTS/search over chat messages and task traces.

Use it when:

- the user says "last time", "we already did", "remember when"
- a task references an old browser workflow
- Web MCP has weak graph memory but the raw task trace may explain what happened

Do not put all past conversations into every prompt. Retrieve only when needed.

### 6. Curator Layer

After each completed task, a background curator should extract:

- durable user facts
- preferences and corrections
- task outcomes
- reusable site flow facts
- blockers and stale assumptions
- possible eval examples

The curator should write structured records, not just append prose forever.

## Proposed Data Model

Start local-first in SQLite/files. Add hosted providers later only behind adapters.

```text
memory_entries
  id
  user_id
  agent_id nullable
  scope: user | agent | site | topic | task
  site_key nullable
  topic_session_id nullable
  kind: fact | preference | decision | correction | task_result | blocker | summary
  content
  confidence
  source_message_id nullable
  source_task_run_id nullable
  created_at
  updated_at
  expires_at nullable

browser_page_patterns
  id
  user_id
  site_key
  canonical_url_pattern
  title
  page_kind
  summary
  auth_state
  created_at
  updated_at

browser_actions
  id
  page_pattern_id
  label
  role
  selector_hint nullable
  href nullable
  input_requirements json
  sensitivity: safe | user_presence | irreversible
  confidence
  updated_at

browser_flow_edges
  id
  user_id
  site_key
  source_page_pattern_id
  target_page_pattern_id nullable
  action_id nullable
  goal_tags json
  observed_outcome
  blocker nullable
  auth_mode
  confidence
  freshness
  success_count
  failure_count
  last_observed_at

scheduled_browser_jobs
  id
  user_id
  agent_id
  title
  prompt
  schedule
  allowed_sites json
  allowed_actions json
  credential_grant_policy
  status
  created_at
  updated_at

credential_grants
  id
  user_id
  origin
  action
  scope
  expires_at
  revoked_at nullable
  created_at
```

## Phased Plan

### Phase 0: Instrumentation Baseline

Goal: know whether browser memory improves anything.

Tasks:

- Track browser tool call count per task.
- Track failed clicks/retries/recovery steps.
- Track time to completion.
- Track whether Web MCP was queried and whether a remembered edge was used.
- Add repeated-task test cases to the browser workflow test plan.

Done when we can compare a repeated browser task with and without memory.

### Phase 1: Better Browser Runtime Loop

Goal: make every browser task follow observe -> plan -> act -> verify -> record.

Tasks:

- Tighten runtime prompt around milestone loop and verification.
- Add structured task trace fields for page observations, actions, outcomes, and blockers.
- Ensure public-page observations feed Web MCP automatically.
- For logged-in/private pages, record compact metadata only and avoid sensitive content by default.

Done when task traces consistently explain which page/action led to which outcome.

### Phase 2: Web MCP Flow Graph Retrieval

Goal: repeated site visits start from known page/action/flow hints.

Tasks:

- Persist browser page patterns and flow edges.
- Add retrieval helpers:
  - known site index
  - current page pattern match
  - actions for current page
  - flows by goal terms
  - blockers by path
- Inject concise Web MCP hints into browser task runtime context.
- Update an edge when a remembered action is stale or wrong.

Done when repeated tasks on the same site use fewer navigation/tool steps.

### Phase 3: Credential Broker V2

Goal: make credential-gated browser work safer and more autonomous.

Tasks:

- Keep current approval UI and task pause path.
- Add richer request metadata: sensitivity, current page type, intended next step.
- Add credential usage audit events.
- Design native/browser-extension credential bridge interface.
- Add scheduled read-only grant model with expiry/revoke.

Done when an agent can request credential use cleanly, continue after approval, and leave a complete audit trail without seeing secrets.

### Phase 4: Memory Curator

Goal: extract durable preferences and reusable facts without polluting context.

Tasks:

- Add a post-task curator that reads final answer, user message, task trace, and Web MCP updates.
- Write structured `memory_entries`.
- Keep user-wide memory separate from site memory.
- Add dedupe and replacement logic.
- Add "forget" and "edit memory" primitives before making memory aggressive.

Done when the agent can reuse confirmed preferences without asking again, while the user can inspect and correct them.

### Phase 5: Scheduled Browser Jobs

Goal: safe recurring browser tasks.

Tasks:

- Define schedules with allowed sites, allowed actions, max runtime, and output destination.
- Default to read-only.
- Use Web MCP flows to reduce navigation.
- Use credential grants only when active, scoped, and unexpired.
- Stop before irreversible actions and create an approval request.
- Save job outcome into task trace, session search, and memory curator.

Done when read-only jobs can run repeatedly and produce useful summaries with auditable browser traces.

### Phase 5.5: Proactive Suggestions

Goal: every app open should surface useful, low-risk next actions.

Tasks:

- Build a suggestion feed from scheduled job outputs, recent browser observations, user memory, and stale/expiring tasks.
- Rank suggestions by user context, time, location, urgency, confidence, and reversibility.
- Keep suggestions explainable: why now, source, expected action, risk level.
- Suggestions that require external action become drafts or approval cards, not silent actions.

Done when the app home/chat can show a few useful suggestions without the user prompting first.

### Phase 7: Mobile and Wearables

Goal: make browser-agent memory useful outside desktop.

Tasks:

- Add an iOS companion for voice, notifications, approvals, location grants, and quick confirmation flows.
- Treat glasses such as Meta Ray-Ban and other wearables as lightweight capture/command surfaces.
- Keep irreversible actions confirmation-backed on phone/watch/glasses.
- Sync only structured memory, approvals, and task state; do not sync raw secrets.

Done when a user can initiate or approve a browser task from mobile/wearables while the actual web execution remains auditable.

### Phase 6: Evals and Training Data

Goal: turn successful/failed browser runs into measurable improvement.

Tasks:

- Build eval suites for Gmail/search/settings/taxi/calendar/shopping read-only flows.
- Score success, steps, recovery, safety stops, and answer quality.
- Save clean trajectories for future SFT/RL/LoRA experiments.
- Only consider model training after runtime memory has stable schemas and eval coverage.

Done when we can say whether a runtime or model change made the agent better.

## What To Build First

Recommended first implementation slice:

1. Add browser trace fields for observed page/action/outcome/blocker.
2. Persist Web MCP flow edges from those trace fields.
3. Retrieve known flow hints into browser runtime context.
4. Add a tiny post-task curator for durable preferences and corrections.
5. Extend browser workflow tests with repeated-run cases.

This gives the fastest product feedback without taking on OS credential bridging or model training too early.

## Open Decisions

- Should Web MCP record logged-in page content, or only semantic metadata unless user opts in?
- Should scheduled jobs use the same agent prompt, or a stricter scheduled-agent profile?
- Should memory extraction run synchronously before the user sees the final answer or asynchronously after?
- How visible should memory edits be in the UI: timeline events, separate memory page, or both?
- Do we need per-memory confidence/expiry from day one, or can v1 use append-only notes with review UI?
