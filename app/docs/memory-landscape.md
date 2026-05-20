# Memory Landscape

Reference list for future work on long-term memory in `Her`.

This is not a commitment to a specific implementation yet. The goal is to keep the most relevant systems, benchmarks, and products in one place so we can revisit them when we design the app's memory layer.

Related product concept: [Her Sessions](./her-sessions.md).

Current product stance: start with a Her-owned local memory contract, then add provider adapters later. See [User Memory Wiki](./user-memory-wiki.md).

## Benchmarks and evals

- [LongMemEval](https://xiaowu0162.github.io/long-mem-eval/)
  Benchmark for long-term interactive memory in chat assistants.

- [LoCoMo](https://snap-research.github.io/locomo/)
  Evaluation framework and dataset for very long-term conversational memory.

## Memory systems and products

- [Karpathy LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
  Pattern for maintaining a persistent, interlinked markdown wiki between raw sources and runtime retrieval. Good fit for Her's local-first user memory because it keeps the compiled memory inspectable and editable.

- [MemPalace](https://github.com/milla-jovovich/mempalace)
  Local-first open-source memory system with strong benchmark results and a retrieval-first design.

- [EverMemOS / EverOS](https://github.com/EverMind-AI/EverMemOS)
  Repository that combines long-term memory methods, benchmarks, and use cases for self-evolving agents.

- [Graphiti](https://github.com/getzep/graphiti)
  Open-source temporal context graph engine from Zep. Strong fit for later provenance, supersession, relationship queries, and "what was true when?" memory.

- [Letta](https://github.com/letta-ai/letta)
  Open-source stateful-agent platform. Useful reference for persistent agents and memory blocks, but heavier than Her's current stage-1 one-task runtime.

- [Mem0](https://mem0.ai/)
  Production-oriented memory layer for LLM apps and agents, with managed and self-hosted paths.

- [Supermemory](https://supermemory.ai/)
  Context infrastructure product with profiles, memory graph, retrieval, extractors, and connectors.

- [qmd](https://github.com/ehc-io/qmd)
  Hybrid BM25/vector search over markdown knowledge bases via MCP. Useful only after Her's local wiki grows beyond simple index-based navigation.

## Current stance

- Keep these as references for future architecture work.
- Do not replace Her's product memory semantics with a provider-first design yet.
- Use local markdown wiki + SQLite structured rows as the first implementation path.
- Treat Graphiti, Mem0, Letta, MemPalace, EverOS, Supermemory, and qmd as adapters or references once Her's own read/write contracts are stable.
- When we revisit memory, compare at least:
  - benchmark coverage: LongMemEval, LoCoMo
  - storage model: verbatim retrieval vs extracted facts vs graph memory
  - deployment model: local-first vs hosted
  - integration cost: SDK/API vs self-hosted components
