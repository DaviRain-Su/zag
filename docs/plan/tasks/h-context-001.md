---
id: h-context-001
scope: phase-h/context-compaction
status: ready
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
- `packages/zag-coding-agent/src/agent.zig`
- `docs/modules/context-compaction.md`
- `docs/maturity.md`
- `chapters/02-session-context/`

# verification

- a fixture that triggers both initial trimming and post-summary trimming reports the exact final omitted set;
- the summary/lineage accounts for messages removed in the second stage;
- tool call/result boundaries remain valid;
- authoritative transcript bytes/messages remain unchanged;
- persisted compaction metadata and trace describe the returned view;
- `zig build test --summary all`.
