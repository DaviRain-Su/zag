# Module: context-compaction

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/context.zig`; `zag-coding-agent/src/project.zig`; session sink in `agent.zig` |
| Current maturity | **L2** — final-view accounting, lineage, session/trace same event (h-context-001) |
| Target | L3 repo map/intelligent selection (C5) |
| Reference | Pi session/compaction; Aider repo map; Hyper compaction |

## Purpose and boundary

Transcript is authoritative. Context view is a per-provider-call projection assembled from stable prompt layers and selected transcript history. Compaction shapes the view; it does not delete transcript rows.

## Invariants

1. **Transcript ≠ view.** Loop never truncates authoritative transcript to satisfy a model budget.
2. system/project instructions remain reachable after compaction.
3. Tool call/result boundaries remain valid in every selected tail.
4. A `CompactionEvent` describes the **final returned view**, not an intermediate trim.
5. `event.dropped` equals the number of non-system body messages excluded by that projection (exactly the omitted prefix length after count trim, char trim, summary/layer re-cost, and Tool-boundary alignment).
6. The summary (with prior-session lineage when applicable) accounts for the same omitted set; session and trace receive that same final event on the success path.
7. Soft `max_chars` may still be exceeded when further legal trim would violate `min_tail_messages` or Tool-boundary rules; accounting still matches the returned view.

## Four prompt layers

| Layer | Content | Lifetime |
|-------|---------|----------|
| system | identity, safety, Tool policy | process/config |
| project | AGENTS.md/project rules | workspace |
| session | compaction summary/session context | session |
| ephemeral | turn-only hints/doctor/Oracle advice | one turn |

`viewForModel` assembles non-empty layers, skips duplicate leading transcript system rows, aligns history to valid Tool boundaries, and applies message/character budgets.

## L2 compaction algorithm (fixed-point)

1. Select a tail by message count and align its start to a Tool boundary.
2. Soft-trim by character budget under current layer cost (prior session layer if any), respecting `min_tail_messages`.
3. Build a UTF-8-safe summary for the omitted body prefix. When a prior session summary exists, retain it under **Prior session context** (lineage) before message highlights.
4. Recalculate layer cost with that summary as the session layer.
5. If summary/layer growth requires another trim, advance the absolute body start by a valid Tool-aligned step, rebuild summary/accounting, and repeat until stable.
6. Emit **one** final `CompactionEvent` (`dropped` + `summary`) to the session sink, then to trace.

### Bounds and soft budget

- Iteration is bounded by `body.len + 1`; each successful advance increases the absolute start by ≥1 (no hidden unbounded restart).
- Per-step work is a linear scan of the remaining tail for char estimates — overall O(n) body walks, not unbounded O(n²) restarts.
- When no further legal Tool-aligned trim exists or the tail is at `min_tail_messages`, the loop **terminates honestly** even if still over `max_chars`.

### Generation and lineage

| Concept | Semantics |
|---------|-----------|
| `Session.compaction_gen` | Increments **exactly once** per successfully applied final event (`noteCompaction` success). Unchanged on OOM. |
| `Session.compaction_summary` | Latest final summary (arena-owned); replaced on each successful event; includes prior lineage text when a previous session layer was present. |
| Resume/save | Header fields `compaction_gen` + `compaction_summary` round-trip with the session file. |
| Trace `compaction` event | Same `dropped` and the same bounded summary bytes (cap = `context.default_summary_max_chars` = `trace.cap_compaction_summary` = 800). |

### Failure semantics (no silent divergence)

1. Loop invokes the session `on_compaction` sink **before** `trace.emitCompaction`.
2. Sink OOM → run returns `OutOfMemory`; **no** compaction line is written to trace; gen/summary stay prior values.
3. Successful sink + trace emit failure → run fails with mapped trace error; session already holds the final event (visible; not a silent ok path).
4. `noteCompaction` never swallows OOM: it returns `error.OutOfMemory` without bumping gen.

L2 permits deterministic heuristic summaries. LLM summarization remains optional/default-off capability work.

## L2 acceptance

- [x] four layers are assembled and project rules are re-injected per turn.
- [x] authoritative transcript remains unchanged.
- [x] a two-stage trim fixture reports the exact final omitted set.
- [x] summary/lineage covers messages removed in every stage.
- [x] Tool call/result boundaries remain valid at the selected start (including multi-tool sequences).
- [x] persisted metadata and trace use the same final event.
- [x] repeated compaction has a documented generation/lineage meaning.
- [x] soft-budget / min-tail terminates honestly without infinite loop.
- [x] allocator/error path does not silently claim session+trace consistency.

## L3 (C5)

- repo map and task-aware file selection;
- session fork/branch;
- optional LLM summary with quality fixtures;
- default-off Memory Repo injection through a defined layer.

## Non-goals for H

- Perfect semantic compression
- Cross-session Memory Repo
- Cloud knowledge store
