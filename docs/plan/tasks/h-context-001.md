---
id: h-context-001
scope: phase-h/context-compaction
status: in-progress
priority: P1
depends-on: [h-session-001, h-trace-001]
---

# objective

Make compaction accounting describe the final model view after every trimming stage, and persist/trace the same complete dropped set or explicit summary lineage.

# context

- `docs/modules/context-compaction.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-agent-core/src/context.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/trace.zig` (`cap_compaction_summary` = 800)
- `packages/zag-coding-agent/src/agent.zig`
- `docs/modules/context-compaction.md`
- `docs/maturity.md`
- `chapters/02-session-context/`

# implementation note (local)

- Fixed-point `viewForModel`: count trim → char trim → build summary (+ prior lineage) → re-cost layers → further Tool-aligned trim → rebuild until stable; bound `body.len+1`.
- `event.dropped` = final omitted body prefix; summary header count + highlights name that set; prior session text under `Prior session context`.
- Soft budget / `min_tail`: honest stop when no legal further trim.
- Loop: `on_compaction` returns `error{OutOfMemory}`; session sink before trace emit.
- `Session.noteCompaction` no longer swallows OOM; gen increments once per success.
- Fixtures: two-stage, multi-iteration, multi-tool, min_tail, lineage/UTF-8, agent session+trace+provider view, OOM sink, noteCompaction OOM.
- Status left **in-progress** for orchestrator close-out.

# verification

- [x] a fixture that triggers both initial trimming and post-summary trimming reports the exact final omitted set;
- [x] the summary/lineage accounts for messages removed in the second stage;
- [x] tool call/result boundaries remain valid;
- [x] authoritative transcript bytes/messages remain unchanged;
- [x] persisted compaction metadata and trace describe the returned view;
- [x] `zig build test --summary all`.
