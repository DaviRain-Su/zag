---
id: h-trace-001
scope: phase-h/trace-lifecycle
status: in-progress
priority: P0
depends-on: []
---

# objective

Make trace/run lifecycle truthful: exactly one terminal event, correct failure stop reasons, versioned schema, and observable trace persistence errors when tracing is explicitly enabled.

> Implementation note (local worktree): facade-owned single terminal; `schema_version=1`; non-destructive preflight + atomic replace; per-reply latest-run; transactional writeObj; fail-closed terminal precedence; truthful stop_reason map (incl. `out_of_memory` / `invalid_toolset`); deinit release-only. **Keep status `in-progress`** — orchestrator marks done only after merge.

# context

- `docs/modules/loop-turn.md`
- `docs/modules/trace-observability.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/trace.zig`
- `packages/zag-agent-core/src/observer.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-cli/src/cli.zig`
- `docs/modules/loop-turn.md`
- `docs/modules/trace-observability.md`
- `docs/maturity.md`
- `chapters/03-production/`

# verification

- authentication/provider failure emits exactly one `ok=false`, `provider_error` terminal event;
- completed, max-turns, cancelled, and persistence/trace failure paths have one truthful terminal state;
- trace schema version is present and contract-tested;
- an unwritable explicit trace path cannot silently produce a successful audited run;
- `zig build test --summary all`.
