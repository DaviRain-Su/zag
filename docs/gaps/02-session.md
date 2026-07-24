# Gap: Phase 2 Session + Context → L2

> Teaching chapter is tutorial-complete. Current truth: [maturity](../maturity.md); contracts: [session-store](../modules/session-store.md), [context-compaction](../modules/context-compaction.md).

## Teaching/current foundations

- JSONL save/load and legacy roundtrip;
- AGENTS.md/project injection;
- transcript versus model view;
- four Layers and heuristic view-only compaction;
- schema v1 and compaction metadata fields.

## Remaining L2 gaps

| Gap | Production failure | Delivery |
|-----|--------------------|----------|
| resume catches invalid/unsupported/general I/O and seeds a new transcript on the same path | later save can overwrite the only good/recoverable file | P0 `h-session-001` / [D-006](../decisions/active/D-006-session-open-and-durability.md) — **closed L2** |
| save truncates target and failure is hidden by Agent facade | crash/IO failure can lose state while caller sees success | P0 `h-session-001` — **closed L2** |
| no active-writer conflict contract | concurrent sessions can silently lose updates | P0 `h-session-001` — **closed L2** |
| second-stage trim is absent from `dropped`/summary | session/trace cannot explain the actual model view | P1 `h-context-001` — **closed L2** (fixed-point final-view accounting) |
| fault fixtures missing | schema/roundtrip happy paths do not prove durability | session + context + trace P0/P1 fixtures in CI |
| repo map/fork | medium-repo navigation and side questions | C5 after H contracts |

## Non-goals for H

- Memory Repo
- session tree/fork UI
- mandatory append-only journal/SQLite
- distributed durable execution

## Next

Session (D-006) and context accounting (h-context-001) are L2. C5.1 repo map and fork may start; Memory Repo remains later and default-off.
