# User Memory Wiki

Design note for adapting Andrej Karpathy's LLM Wiki pattern to `Her` user memory.

Status: first local implementation slice exists in `app/src/server/identity/storage.ts`. It hardens the existing `.data/identity` memory layer by creating a user-scoped markdown wiki, append-only log, and safer write rules. This is not the full Stage 3 memory graph.

## Thesis

Use a compiled local wiki for durable user and agent memory, not raw chat replay and not a hosted memory provider as the primary source of truth.

The useful pattern from Karpathy's gist is:

```text
raw sources -> LLM-maintained wiki -> concise runtime context
```

For `Her`, the mapping is:

- Raw sources: chat turns, browser task traces, Web MCP observations, meeting transcripts/summaries, explicit user corrections.
- Wiki: local markdown pages under `.data/identity/users/<user_id>/wiki/`.
- Runtime context: the app injects only the compact user-memory wiki plus the agent's `soul.md`.
- Schema: `wiki/schema.md` states what may be written, what must never be written, and how stale/candidate memories are treated.

The wiki should compound. A new task should update the relevant page once, so future tasks do not re-infer the same preference from old raw traces.

## Current Local Layout

The first implementation slice creates:

```text
.data/identity/users/<user_id>/
  user.md                  # compatibility summary/inbox
  agents/<agent_id>/soul.md
  wiki/
    schema.md              # write/read policy
    index.md               # page catalog
    log.md                 # append-only maintenance log
    profile.md
    preferences.md
    people.md
    places.md
    projects.md
    decisions.md
    corrections.md
    inbox.md
```

Agent-visible memory is compiled from `wiki/index.md` and the core pages, not from every raw source. `user.md` remains for compatibility with existing local data.

## What To Remember

Remember only durable, user-specific, actionable information:

- explicit preferences and defaults
- repeated choices that reduce future friction
- corrections and "do not do X" instructions
- confirmed places such as home/work when the user makes them relevant
- important people and project context when useful for future tasks
- decisions, rejected options, and task outcomes

Do not remember:

- plaintext passwords, tokens, cookies, MFA codes, recovery codes, payment cards, private keys
- raw credential material from browser flows
- one-off task chatter
- assumptions that were not stated or corroborated
- sensitive medical, legal, financial, biometric, or location-history details unless the user explicitly asks and the memory is necessary

Sensitive context should still be remembered when useful, but not as plaintext prompt-readable values. Store a redacted note, vault reference, source pointer, or review candidate instead. For example, remember that a credential exists for a service, not the credential value.

Memory is guidance, not permission. It can rank options, prefill harmless context, and reduce clarification questions. It cannot authorize sending, deleting, buying, booking, ordering, revealing secrets, or changing account security.

## Write Pipeline

V1 behavior:

1. The runtime injects the local wiki and tells the agent to emit hidden `<remember-user>` blocks only for durable memory.
2. The app strips those blocks from the user-visible answer.
3. The storage layer redacts obvious secret values before writing prompt-readable memory.
4. The note is classified into a wiki page such as `preferences.md`, `places.md`, `projects.md`, `decisions.md`, `corrections.md`, or `inbox.md`.
5. The note is appended as a candidate and recorded in `log.md`.

Agent memory follows the same principle through per-agent `soul.md`: remember stable lessons, behavior corrections, and useful operating style. Do not store raw user secrets there either.

Next Stage 3 behavior should add a real curator:

1. Read final answer, latest user message, task trace, and relevant raw source.
2. Extract candidate memory as structured JSON.
3. Score durability, sensitivity, confidence, scope, and expiry.
4. Dedupe against existing wiki pages and structured rows.
5. Supersede contradicted memories instead of appending forever.
6. Require user review for sensitive, identity-level, or high-impact memories.

## Retrieval Logic

Runtime context should stay small:

- Always read `index.md`.
- Read only relevant pages for the current task when the wiki grows.
- Inject confirmed/repeated facts first.
- Inject candidate notes only as weak context.
- Prefer the latest user message and current browser/app evidence over memory.
- Ask or verify when memory is stale, contradicted, or risky.

This means memory helps with prompts like "закажи такси домой" only if "home" has been explicitly confirmed or is visible in the relevant logged-in service. It should not hallucinate a destination from an old tab or a weak inference.

## Relationship To Web MCP

Keep two memory types separate:

- User memory: cross-site durable facts and preferences about the user.
- Web MCP memory: site-scoped page patterns, semantic actions, forms, blockers, and observed flow edges.

Web MCP may mirror a cross-site fact into user memory only when it is a durable preference or correction. Site-specific implementation details stay in Web MCP.

## Relationship To iOS Calls And Meetings

The iOS backend should feed this same memory system, but only through reviewable candidates.

Calls and meetings are high-signal but also high-risk sources: they contain other people's words, possible transcription errors, addresses, phone numbers, payment details, and commitments that may not be personal preferences. The backend therefore remembers them first as `meeting_memory_candidates` tied to the source meeting/call instead of directly writing the global user wiki.

Current iOS backend behavior:

- `MeetingResponse.memoryCandidates` exposes extracted candidates to the app.
- Decisions, action items, follow-ups, and topics become candidates.
- `call_note` summaries and call-like sources may add one compact call overview candidate.
- Obvious secret values are redacted before prompt-readable persistence.
- Address/contact/payment-like candidates are remembered with `sensitivity=review`, meaning they are stored but should be confirmed before global promotion or high-impact use.
- Candidates stay scoped to `meetingId` until a later curator or UI promotes them.

Promotion rule:

```text
meeting/call transcript -> summary -> memoryCandidates -> user review/curator -> wiki page
```

Do not skip the candidate stage for calls. A meeting action item such as "send proposal to Ivan" is useful for task follow-up and should be remembered under the meeting; it should not automatically become a durable global fact about the user.

## Relationship To Speech Corrections And Speaker Identity

The Stage 1 speech source of truth is completed-audio batch transcription through the external H200 STT service, not live streaming:

```text
iOS full recording -> main backend -> H200 WhisperX/diarization -> final transcript
```

This path gives WhisperX and diarization the full meeting context, so it should remain authoritative for saved transcripts. A future streaming path can provide preview text and time-to-first-transcript, but its partial output should be reconciled against the final H200 batch transcript before becoming durable memory.

User transcript edits are memory candidates, not immediate global rewrites. Store them as correction facts with provenance:

- original text, corrected text, language/script when known, nearby transcript context, meeting id, speaker label when relevant, timestamp span, confidence, and edit count
- classify names, Kazakh/Russian/English terms, company/product words, acronyms, and repeated misspellings into `corrections.md` or structured `memory_entries`
- compile confirmed corrections into provider-specific hints later, such as Whisper prompts, Deepgram keyterms, or LLM cleanup rules

Do not blindly apply one correction everywhere. "Diar" can be a person name in one meeting, a project term in another, or a false positive in unrelated speech. Corrections should become stronger only after explicit confirmation or repeated consistent edits.

Speaker assignment is a separate memory type. When the user says `Speaker 1 is Diar`, the backend may create or extend a voice profile from that speaker's audio and store the label as a speaker identity candidate. That should improve future relabeling. It should not by itself teach the text recognizer that every similar sound is the word `Diar`.

For UI behavior, the safe loop is:

```text
user fixes transcript/speaker -> candidate correction/profile sample -> review/confirmation -> provider hints or voice profile -> future transcript relabel/cleanup
```

## OSS Provider Stance

Do not make an external memory system the core of Her yet.

Recommended stance:

- Build the product-owned local schema first: markdown wiki + SQLite structured memory + Web MCP graph.
- Add provider adapters only after we know our read/write contracts.
- Treat providers as replaceable retrieval/graph backends, not as the owner of product semantics.

Shortlist:

- Graphiti/Zep: best fit for later temporal knowledge graph work, provenance, supersession, and relationship queries.
- Mem0: useful if we want a production memory SDK/server quickly, especially with user/session scoping.
- Letta: useful reference for stateful agents, but heavier than the current one-task Her runtime.
- MemPalace: strong local/verbatim retrieval reference, but raw recall alone is not enough for correct user memory.
- EverOS/EverMemOS: useful research/reference point, likely too broad for the first Her integration.
- qmd: good lightweight search over markdown wiki pages if the local wiki grows beyond simple `index.md` navigation.

## Implementation Slices

Stage-1-safe hardening already done:

- Keep memory local under `.data/identity`.
- Add wiki/index/log/schema pages.
- Categorize `<remember-user>` notes.
- Redact obvious secret values before prompt-readable persistence.
- Treat candidate notes as weak context.

Next code slice:

- Add `memory_entries` SQLite rows with `scope`, `kind`, `status`, `confidence`, `sensitivity`, `source_task_run_id`, `source_message_id`, `expires_at`, and `supersedes_id`.
- Add a curator function that writes structured rows first, then regenerates wiki pages from rows.
- Add user-visible "Memory" settings: view, edit, forget, export.
- Add tests for extraction, secret redaction, dedupe, supersession, and runtime prompt injection.

Full Stage 3 slice:

- Add temporal graph support for entities and relationships.
- Add evals against LongMemEval/LoCoMo-style tasks plus product-specific browser workflows.
- Add qmd/Graphiti/Mem0 adapters only behind the Her memory interface.
