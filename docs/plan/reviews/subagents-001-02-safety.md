# Review: subagents-001 — safety / lifecycle (closeout)

- Task: [subagents-001](../tasks/subagents-001.md)
- Binding: [subagents-oracle.md](../../modules/subagents-oracle.md)
- Track: Wave 2 closeout (safety)
- Result: **PASS**

## What holds

- Depth cap 1: a child cannot spawn another child.
- Child uses the parent's permission / jail / shell policy; no bypass.
- Ephemeral Session: no second durable writer, no `parent_id` schema.
- Parent blocks: no background process leak from this slice.
- Async TUI pane (`7f058ce`) is a display/registry follow-on, not
  process isolation.

## Non-blocking

- **N1 (P3).** A runaway in-process child still shares the parent's
  address space and cancel flag. That is why process-backed children
  are a different Goal.

## Decision

**PASS** — closeout. No Oracle, Graph, or worktree claim.
