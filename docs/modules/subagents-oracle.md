# Module: subagents-oracle / optional Graph (Capability stub)

| Item | Content |
|------|---------|
| Status | L0 / not implemented |
| Stage | [C6](../phases/C6-orchestration.md) |
| Prerequisite | truthful lifecycle, safe session, cancellation, SDK/headless events; executable agents need process ownership/safety |
| Reference | Amp Oracle; Hyper design-oracle; omp typed subagents |

## Loop/Graph boundary

```text
optional Graph/DAG
  node = read-only Oracle | bounded subagent | deterministic gate
  agentic node execution = the normal Agent Core Loop
```

- Default coding runs without Graph.
- Graph never replaces Tool-loop semantics.
- Do not add empty Graph/Memory hooks to the H or SDK minimum API.

## Delivery order

1. Read-only Oracle over stable event/session/cancel contracts.
2. Typed bounded subagents with explicit model/Tool/budget/process ownership.
3. Optional Graph only after repeated real handoff/join patterns justify it.

## Invariants

1. Oracle is read-only and pinned/configured as a genuinely stronger model; same-model fallback is visible.
2. User dialogue can explicitly require Oracle; no `/oracle` command requirement.
3. Subagents have bounded turns/time/tokens/Tools and typed result options.
4. All agents use canonical Provider and Tool runtime contracts.
5. Executable child cancellation/process cleanup is owned and traceable.
6. Parent/child sessions do not silently share writers or corrupt transcript state.

## Acceptance (C6)

- explicit Oracle request invokes a read-only Oracle fixture;
- same-model configuration warns without inventing success;
- typed result and budget termination are deterministic;
- child cancellation/process cleanup/session isolation are tested;
- Graph remains optional and the plain Loop suite stays green.

## Non-goals

- Phase H implementation
- Amp effort-mode bundle
- Mandatory per-turn advisor
- Distributed workflow engine
