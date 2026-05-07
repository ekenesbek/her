# Memory Landscape

Reference list for future work on long-term memory in `Her`.

This is not a commitment to a specific implementation yet. The goal is to keep the most relevant systems, benchmarks, and products in one place so we can revisit them when we design the app's memory layer.

Related product concept: [Her Sessions](./her-sessions.md).

## Benchmarks and evals

- [LongMemEval](https://xiaowu0162.github.io/long-mem-eval/)
  Benchmark for long-term interactive memory in chat assistants.

- [LoCoMo](https://snap-research.github.io/locomo/)
  Evaluation framework and dataset for very long-term conversational memory.

## Memory systems and products

- [MemPalace](https://github.com/milla-jovovich/mempalace)
  Local-first open-source memory system with strong benchmark results and a retrieval-first design.

- [EverMemOS / EverOS](https://github.com/EverMind-AI/EverMemOS)
  Repository that combines long-term memory methods, benchmarks, and use cases for self-evolving agents.

- [Mem0](https://mem0.ai/)
  Production-oriented memory layer for LLM apps and agents, with managed and self-hosted paths.

- [Supermemory](https://supermemory.ai/)
  Context infrastructure product with profiles, memory graph, retrieval, extractors, and connectors.

## Current stance

- Keep these as references for future architecture work.
- When we revisit memory, compare at least:
  - benchmark coverage: LongMemEval, LoCoMo
  - storage model: verbatim retrieval vs extracted facts vs graph memory
  - deployment model: local-first vs hosted
  - integration cost: SDK/API vs self-hosted components
