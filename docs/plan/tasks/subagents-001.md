---
id: subagents-001
scope: product/subagents (D-012 item 5 first slice; zag-coding-agent owner)
status: implemented
priority: P1
---

# objective

Record the **in-process** typed subagent slice that already landed: model tool
`task` with types `task` / `scout` / `reviewer`, depth 1, ephemeral child
Session, filtered toolset, TUI tasks pane. This is not Oracle, not Graph, and
not process isolation.

**Binding:** [subagents-oracle.md](../../modules/subagents-oracle.md)

**Status:** **`implemented`** @ `1dabd25` (async background follow-on @
`7f058ce`). Wave 2 closeout: dual review still open; maturity row stays **L0**.

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented as written** in `subagent.zig` header + module split; dual review open |
| Implementation | **done** @ `1dabd25` — `packages/zag-coding-agent/src/subagent.zig` + `task` tool |
| TUI | tasks pane @ `38148de` / `7f058ce` |
| Maturity | **unchanged** — Subagents/Oracle row stays L0 |
| Process isolation | **not claimed** — parent blocks; child is in-process |
| Oracle / Graph | **absent** |

# non-goals (this slice)

- process-backed / worktree children (Wave 3c after supervisor long-lived slots)
- Oracle, Graph/DAG, IrcBus, dashboard
- Core types

# related

- [subagents-oracle.md](../../modules/subagents-oracle.md)
- [process-supervisor-001](./process-supervisor-001.md)
- [2026-08-13 next delivery plan](../analysis/2026-08-13-next-delivery-plan.md) Wave 2
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
