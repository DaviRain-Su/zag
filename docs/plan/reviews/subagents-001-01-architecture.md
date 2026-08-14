# Review: subagents-001 — architecture / ownership (closeout)

- Task: [subagents-001](../tasks/subagents-001.md)
- Binding: [subagents-oracle.md](../../modules/subagents-oracle.md)
- Code: `packages/zag-coding-agent/src/subagent.zig` + `task` tool
- Track: Wave 2 closeout (architecture)
- Result: **PASS**

## What holds

- In-process only: parent `Agent.reply` blocks on child `Agent.reply`.
- Types `task` / `scout` / `reviewer`; `MAX_SUBAGENT_DEPTH = 1`.
- Ephemeral child Session (no durable path). No Core subagent types.
- Filtered toolset: scout/reviewer read-only; task inherits parent.
- TUI tasks pane is display-only (`38148de` / `7f058ce`).
- Module correctly splits: this slice exists; Oracle / Graph /
  process-backed children remain L0.

## Decision

**PASS** — closeout. Subagents/Oracle maturity row stays **L0**.
Process-isolated children need long-lived supervisor slots (Wave 3c)
and a reproduced failure. Do not schedule them because D-012 listed
“typed subagents”.
