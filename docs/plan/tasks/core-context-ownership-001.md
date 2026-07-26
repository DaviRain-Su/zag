---
id: core-context-ownership-001
scope: coding-agent/context-ownership
status: done
priority: P1
depends-on:
  - core-policy-ownership-001
---

# objective

Split protocol-history validation from product context projection. Keep Tool-call/result bundle legality in Core and move
prompt layers, budget policy, fixed-point compaction, summary/lineage, and Session compaction state to coding-agent behind
the required `ContextView` port.

# context

- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/context-compaction.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/modules/sdk-contract.md`

# path

- `packages/zag-agent-core/src/context.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/project.zig`
- `packages/zag-coding-agent/src/root.zig`
- destination coding-agent context module(s)
- context/session/Trace/SDK fixtures
- `docs/modules/core-boundary.md`
- `docs/modules/context-compaction.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/tasks/core-context-ownership-001.md`
- generated quality reports

# contract

1. Core rejects malformed Tool bundles before `Provider.chat`, independent of the product ContextView implementation.
2. Coding-agent owns four prompt layers, model budgets, fixed-point compaction, summary cap/lineage, and generation state.
3. `ContextView` returns turn-scratch-borrowed messages and an optional borrowed compaction fact; retained data is copied.
4. Transcript remains authoritative and unchanged by projection.
5. Session accepts the final compaction fact before durable Trace sees the same bytes; failure ordering remains visible.
6. `invalid_context`, OOM, and Trace/session terminal mappings remain unchanged.

# verification

- malformed/orphan/duplicate/out-of-order Tool bundles fail before provider call from Core tests.
- final view, dropped count, summary, lineage, session metadata, Trace bytes, and provider session layer remain equal on
  successful compaction.
- sink OOM writes no Trace compaction line and does not advance Session generation.
- note-success/Trace-failure remains a visible run failure.
- identity ContextView is an explicit low-level composition, not a missing-state fallback.
- Core root/source scan contains protocol-history validation but no product layer/compaction implementation.
- package tests, SDK fixture, root std/curl suites, headless fixture, docs lint, and quality checks pass.

# non-goals

- changing compaction algorithm, summary cap, token estimator, schema, repo map, Memory, session fork, or LLM summaries;
- public lifecycle events or steering.
