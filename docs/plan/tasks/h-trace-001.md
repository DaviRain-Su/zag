---
id: h-trace-001
scope: phase-h/trace-lifecycle
status: done
priority: P0
depends-on: []
---

# objective

Make trace/run lifecycle truthful: exactly one terminal event, correct failure stop reasons, versioned schema, and observable trace persistence errors when tracing is explicitly enabled.

> Completion: merged to `main`; facade-owned single terminal, schema v1, Guard jail, typed serialization/I/O failures, UTF-8 fail-closed handling, atomic persistence, and allocation-reserved fallback terminals pass under both HTTP backends.

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
