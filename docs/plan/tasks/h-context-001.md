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

- Fixed-point `viewForModel`: validate tool bundles → count trim → legal align → char trim by atomic units → build summary (+ lineage) → re-cost → rebuild until stable; bound `body.len+1`; worst-case **O(n²)** documented.
- Tool bundles: nonempty unique IDs; contiguous results in call order; orphan/unknown/duplicate/missing/ooo/incomplete → `InvalidContext` → terminal `invalid_context` (provider not called).
- Atomic boundary: start inside results → carrier assistant; further trim skips assistant+all results together.
- Lineage: exact prior when fit; else truncated record with full digest; floor uses **sanitized** prior length (U+FFFD) so decimal width matches writeLineage; tiny budgets keep prior_bytes/digest/marker without assert-only safety.
- Shared `context.summary_cap` = 800; Options clamped; `trace.cap_compaction_summary` aliases it; `emitCompactionEvent`.
- Invalid UTF-8 → U+FFFD sanitize (not OOM).
- Soft budget / `min_tail`: honest stop; two-stage fixture requires final > intermediate.
- Loop: sink before trace; Agent `fail_next_note_compaction` fixture for OOM terminal.
- Status left **in-progress** for orchestrator close-out.

# verification

- [x] a fixture that triggers both initial trimming and post-summary trimming reports the exact final omitted set;
- [x] the summary/lineage accounts for messages removed in the second stage;
- [x] tool call/result boundaries remain valid;
- [x] authoritative transcript bytes/messages remain unchanged;
- [x] persisted compaction metadata and trace describe the returned view;
- [x] `zig build test --summary all`.
