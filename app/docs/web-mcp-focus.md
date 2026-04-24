# Web MCP Focus

Product focus note for Web MCP as a website memory and navigation layer for agents.

## Thesis

Web MCP should help agents orient faster on websites by storing an observed, reusable model of how a site works.

The main value is not another browser automation wrapper. The value is a compact semantic map that lets an agent understand:

- what is visible on the current page
- what actions are available
- where each action is likely to lead
- which paths were already explored
- which paths are blocked, stale, or require user state

Page snapshots help the agent orient on one page. The graph/flow layer helps the agent orient across the site.

## Core Bet

The product should prioritize a site graph with flow semantics.

Nodes represent pages or meaningful browser states:

- public pages
- authenticated pages
- search results
- checkout or onboarding steps
- settings subsections
- modal states when they change the flow
- error, blocked, and success states

Edges represent observed transitions:

- link clicks
- button clicks
- form submissions
- redirects
- tab or route changes caused by client-side navigation

Each edge should preserve enough context for future agents to choose it intentionally:

- source node
- destination node
- action label
- triggering element or stable ref
- required inputs, if any
- observed outcome
- confidence
- freshness
- blockers such as auth, captcha, paywall, missing form fields, or irreversible action
- auth mode: existing session, user-presence passkey, broker-approved password, scheduled grant, or blocked

## Agent Behavior

Before rediscovering a website, the agent should ask Web MCP for the known site index and graph.

For goal-directed tasks, Web MCP should support queries like:

- shortest known path to a page or state
- known flows for account settings, checkout, search, cancellation, or support
- pages matching a semantic label
- stale or unverified edges that need confirmation
- blockers on the path

When following an existing edge, the agent should still verify the current page state. Web MCP stores observed flows, not absolute truth.

If the site has changed, the agent should update the graph instead of treating the old path as authoritative.

## Data Principles

Web MCP memory should be scoped by user and site.

The graph must handle variants:

- logged out vs logged in
- user role or account type
- desktop vs mobile
- locale
- experiment or A/B state
- scheduled vs interactive execution
- user-presence requirements for credential flows

Stored data should favor compact, structured artifacts:

- semantic page snapshot
- visible text summary
- interactive element refs
- forms and required fields
- links and actions
- graph edges
- notes and task outcomes

Raw HTML or long page dumps can be kept as artifacts, but the agent-facing retrieval path should be concise.

## Success Metrics

Web MCP is useful if it reduces agent work on real browser tasks.

Track at least:

- task success rate
- time to complete
- number of browser/tool calls
- token usage
- number of failed clicks or recovery steps
- repeated rediscovery of already known pages

A strong signal would be a 30-50% reduction in navigation and recovery steps on repeated tasks for the same site.

## Non-Goals

Web MCP should not become only a static sitemap.

It should not claim certainty for old observations without freshness and confidence.

It should not bypass user approval for irreversible actions such as send, delete, archive, purchase, payment, or order confirmation.

## MVP Direction

Keep the first implementation practical:

1. Continue recording page snapshots and discovered links.
2. Add stronger edge metadata: action label, source state, destination state, confidence, freshness, blocker.
3. Expose graph queries to the agent runtime before and during browser tasks.
4. Update edges when observed flows differ from stored flows.
5. Measure repeated tasks against a no-graph baseline.

The focus is a navigable, self-correcting flow graph that lets agents reuse website knowledge instead of probing from scratch every time.
