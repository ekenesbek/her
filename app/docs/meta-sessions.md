# Meta Sessions

Concept note for a one-window agent experience where the user talks to one agent, while the system manages topic-scoped sessions behind the scenes.

This is an exploration, not a committed implementation.

## Product idea

Instead of making the user manually create and switch between chats, `meta` can keep a higher-level **meta session** around the user's ongoing work.

The visible UX stays simple:

- one chat window with the agent
- one current task/status timeline
- the agent can say what it is doing now
- older work is still recoverable by topic, project, entity, or goal

Behind the scenes, the agent runtime can create and route messages into multiple **topic sessions**.

Example:

```text
Meta session: "Personal operations"

- Topic session: "Taxi and local errands"
- Topic session: "Travel planning"
- Topic session: "Gmail follow-ups"
- Topic session: "Research on memory providers"
```

The user still writes in one place. The system decides whether the next message should continue the current topic, resume an older topic, or create a new topic session.

## Core loop

1. User sends a message in the one-window chat.
2. A session router classifies the message:
   - continue active topic
   - resume existing topic
   - create new topic
   - link to multiple topics
3. The agent runs inside the selected topic session.
4. Browser/task traces are attached to that session.
5. A memory writer extracts durable facts, decisions, entities, links, and task outcomes.
6. The meta session index is updated so future routing can find the right context.

## Session router

The router should produce structured output:

```ts
type SessionRouteDecision = {
  action: "continue" | "resume" | "create" | "link";
  confidence: number;
  targetSessionIds: string[];
  proposedTitle?: string;
  topics: string[];
  entities: string[];
  reason: string;
};
```

MVP behavior should be conservative:

- continue the active session when confidence is low
- create a new topic only above a high confidence threshold
- keep a visible audit event when routing happens
- allow manual correction later

## Data model sketch

```text
meta_sessions
  id
  user_id
  title
  status
  created_at
  updated_at

topic_sessions
  id
  meta_session_id
  title
  summary
  status
  created_by: user | agent | system
  confidence
  created_at
  updated_at

topic_session_tags
  topic_session_id
  tag

topic_session_entities
  topic_session_id
  entity_type
  entity_value

topic_session_links
  source_topic_session_id
  target_topic_session_id
  relation

memory_entries
  id
  user_id
  meta_session_id
  topic_session_id
  kind: fact | preference | decision | credential_ref | task_result | summary
  content
  source_event_id
  confidence
  created_at
  expires_at
```

The current `task_runs`, `task_events`, and `task_artifacts` tracing layer can attach naturally to `topic_session_id` later.

## UI shape

The first version should avoid forcing users to think in folders.

Recommended UI:

- main chat remains the primary surface
- small status area shows current topic
- timeline shows task execution and routing events
- topic drawer can show auto-created sessions
- each topic has summary, last activity, important memories, and linked tasks

The important UX rule: topic sessions should help recovery and context, not interrupt the conversation.

## Agent behavior

The agent should be allowed to create topic sessions, but with constraints:

- no silent split for low-confidence routing
- no session creation from a single vague message unless it clearly starts a new goal
- user-visible audit entry: `Created topic session: Travel planning`
- merge/split tools for cleanup
- retention and privacy rules per topic

For irreversible browser actions, the approval gate remains outside the memory/session system. Session routing must not imply permission to order, pay, send, delete, or expose secrets.

## MVP

1. Add `meta_sessions` and `topic_sessions`.
2. Add a router call after each user message.
3. Attach every chat message and task run to a topic session.
4. Show current topic and routing events in the chat timeline.
5. Store topic summaries and tags.
6. Add manual "move message/task to another topic".

Do not start with fully autonomous session management. Start with routing + observability + correction.

## Provider landscape

Checked: 2026-04-23.

No memory provider appears to offer this exact one-window meta-session product pattern out of the box. Several providers cover important parts of it:

- [Letta](https://docs.letta.com/guides/agents/conversations)
  Closest conceptually for stateful agents. It supports persistent agents, conversations, message history, shared memory, and multi-conversation patterns. Good reference if we want the agent itself to manage structured memory and long-running state.

- [Zep](https://help.getzep.com/)
  Strong reference for session/thread memory and temporal knowledge graph context. Useful if we want automatic extraction, graph context, and retrieval around users and threads.

- [Mem0](https://docs.mem0.ai/)
  Useful as a production memory layer with user/session-style scoping and memory extraction. Good candidate for durable facts/preferences across sessions, but the meta-session router and UI model would still be ours.

- [Supermemory](https://docs.supermemory.ai/)
  Useful as context infrastructure: profiles, memory graph, retrieval, extractors, and connectors. More of a context/memory substrate than an opinionated session orchestration UX.

## Open questions

- Should meta sessions be user-visible objects or mostly hidden?
- Should routing run synchronously before the agent answers or asynchronously after each turn?
- How aggressive should automatic session creation be?
- Do we want provider-backed memory first, or local tables + optional provider adapters?
- How do we expose corrections: merge topic, rename topic, move task, forget topic?
