# Module: subagents / Oracle / optional Graph

| Item | Content |
|------|---------|
| Status | **in-process `task` slice landed** @ `1dabd25` (`packages/zag-coding-agent/src/subagent.zig`); Oracle / Graph / process-backed children still **L0** |
| Stage | [C6](../phases/C6-orchestration.md) |
| Prerequisite | truthful lifecycle, safe session, cancellation, SDK/headless events; *process-isolated* agents still need [process-supervisor](./process-supervisor.md) long-lived/job slots |
| Reference | Amp Oracle; Hyper design-oracle; omp typed subagents; grok-build `SubagentCoordinator` (semantic only, D-009) |

## What exists on HEAD

In-process synchronous delegation (not a Graph, not an Oracle):

- model tool `task` with types `task` / `scout` / `reviewer`;
- depth cap `MAX_SUBAGENT_DEPTH = 1`;
- ephemeral child Session (no durable path); parent blocks until the child returns;
- filtered toolset by type (scout/reviewer read-only; task inherits parent);
- TUI tasks pane for registry display (Grok-style): auto-opens tall while
  a child runs (unfocused so Enter still sends) and stays after
  completion so the live log is reviewable. `Ctrl+K` show/focus/hide;
  `Space` expands the tool/turn log; `+`/`-` resizes (3-row chip …
  20-row tall; another `-` on the chip hides). Child lifecycle events
  append progress lines (`→ tool`, `✓ tool`, `· text`) — no raw args.
  Final `output` still lands on completion.

This slice does **not** raise the Subagents/Oracle maturity row. It does not
claim process-tree isolation, worktree children, inter-agent messaging, or
background spawn.

## Loop/Graph boundary

```text
optional Graph/DAG          ← still L0 / not implemented
  node = read-only Oracle | bounded subagent | deterministic gate
  agentic node execution = the normal Agent Core Loop

in-process task tool        ← landed
  parent Agent.reply blocks on child Agent.reply
```

- Default coding runs without Graph.
- Graph never replaces Tool-loop semantics.
- Do not add empty Graph/Memory hooks to the H or SDK minimum API.

## Delivery order

1. **Done:** in-process typed `task`/`scout`/`reviewer` with depth 1 and filtered tools.
2. Read-only Oracle over stable event/session/cancel contracts (still deferred).
3. Process-backed / worktree-isolated children after supervisor long-lived slots (Wave 3c).
4. Optional Graph only after repeated real handoff/join patterns justify it.

## Invariants

1. Oracle is read-only and pinned/configured as a genuinely stronger model; same-model fallback is visible.
2. User dialogue can explicitly require Oracle; no `/oracle` command requirement.
3. Subagents have bounded turns/time/tokens/Tools and typed result options.
4. All agents use canonical Provider and Tool runtime contracts.
5. Executable child cancellation/process cleanup is owned and traceable (process-backed only; in-process uses Agent cancel).
6. Parent/child sessions do not silently share writers or corrupt transcript state.

## Acceptance (C6)

In-process slice (landed; not a maturity raise):

- `task`/`scout`/`reviewer` dispatch and depth=1 fail-closed;
- child uses an ephemeral Session; parent writer is not shared;
- scout/reviewer cannot run mutating tools.

Still required for a future L2/L3 row:

- explicit Oracle request invokes a read-only Oracle fixture;
- same-model configuration warns without inventing success;
- typed result and budget termination are deterministic;
- child cancellation/process cleanup/session isolation are tested;
- Graph remains optional and the plain Loop suite stays green.

## Non-goals

- Phase H implementation (historical)
- Amp effort-mode bundle
- Mandatory per-turn advisor
- Distributed workflow engine
- Treating the in-process slice as process isolation or an Oracle
