# Module: context-compaction

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/context.zig`; `zag-coding-agent/src/project.zig` |
| Current maturity | **L1+** — layers/view compaction exist; final-view accounting is P1 |
| Target | L2 (H) → L3 repo map/intelligent selection (C5) |
| Reference | Pi session/compaction; Aider repo map; Hyper compaction |

## Purpose and boundary

Transcript is authoritative. Context view is a per-provider-call projection assembled from stable prompt layers and selected transcript history. Compaction shapes the view; it does not delete transcript rows.

## Invariants

1. **Transcript ≠ view.** Loop never truncates authoritative transcript to satisfy a model budget.
2. system/project instructions remain reachable after compaction.
3. Tool call/result boundaries remain valid in every selected tail.
4. A `CompactionEvent` describes the **final returned view**, not an intermediate trim.
5. `event.dropped` equals the number of history messages excluded by that projection.
6. The summary or explicit lineage accounts for the same omitted set; session and trace receive that same event.

## Four prompt layers

| Layer | Content | Lifetime |
|-------|---------|----------|
| system | identity, safety, Tool policy | process/config |
| project | AGENTS.md/project rules | workspace |
| session | compaction summary/session context | session |
| ephemeral | turn-only hints/doctor/Oracle advice | one turn |

`viewForModel` assembles non-empty layers, skips duplicate leading transcript system rows, aligns history to valid Tool boundaries, and applies message/character budgets.

## L2 compaction algorithm

1. Select a tail by message count and align its start to a Tool boundary.
2. Trim to the initial character budget while respecting `min_tail_messages`.
3. Build a summary for the omitted set.
4. Recalculate layer cost with that summary.
5. If summary/layer growth requires another trim, extend the omitted set, realign boundaries, and rebuild accounting/summary before returning.
6. Emit one final `CompactionEvent` to session and trace.

L2 permits deterministic heuristic summaries. LLM summarization remains optional/default-off capability work.

## Current gap

The current second trimming loop can remove additional selected messages after the summary is built without increasing `dropped` or rebuilding the summary. The returned event can therefore omit history not represented in its accounting. Four layers and a schema field alone do not satisfy L2.

## L2 acceptance

- [x] four layers are assembled and project rules are re-injected per turn.
- [x] authoritative transcript remains unchanged.
- [ ] a two-stage trim fixture reports the exact final omitted set.
- [ ] summary/lineage covers messages removed in every stage.
- [ ] Tool call/result boundaries remain valid at the selected start.
- [ ] persisted metadata and trace use the same final event.
- [ ] repeated compaction has a documented generation/lineage meaning.

## L3 (C5)

- repo map and task-aware file selection;
- session fork/branch;
- optional LLM summary with quality fixtures;
- default-off Memory Repo injection through a defined layer.

## Non-goals for H

- Perfect semantic compression
- Cross-session Memory Repo
- Cloud knowledge store
