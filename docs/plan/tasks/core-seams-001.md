---
id: core-seams-001
scope: agent-core/kernel-seams
status: done
priority: P0
depends-on:
  - core-boundary-001
---

# objective

Introduce the thin-kernel seams required by D-011 without moving concrete implementations yet. Route `loop.run` through
explicit `ToolPolicy`, `Jail`, `ShellPolicy`, `ContextView`, and fallible canonical `LoopEventSink` contracts while using
adapters over current behavior.

Remove implicit allow/yolo composition from the low-level loop. Preserve Tool validation, fixed pre-execution order,
Trace/session behavior, public terminals, and all existing schemas.

# context

- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/tool-runtime.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/trace-observability.md`

# path

- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-agent-core/src/observer.zig`
- new Core port/event modules selected by the implementation
- current Core policy/context/trace modules only for adapters and tests
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- `tests/sdk-consumer-fixture/`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/tasks/core-seams-001.md`
- `docs/maturity.md` only to record verified migration status, not raise maturity
- generated quality reports

# contract

1. `loop.run` owns Toolset/history validation and ToolPolicy → Jail → ShellPolicy → execute order.
2. All five seams are explicit dependencies. Missing ToolPolicy/Jail/ShellPolicy never becomes allow/yolo; identity/discard
   context/event behavior is selected explicitly.
3. Policy/jail/shell decisions remain soft Tool results; host/OOM/sink failures remain typed run failures.
4. The same extracted path is shared by policy and jail; handler count remains zero on every deny.
5. Canonical Loop events are source-backed, synchronous, borrowed, ordered, and fallible. They contain no product
   `run_start`/`run_terminal`.
6. Existing implementations remain adapters in this task; no durable state or policy file moves yet.
7. Existing Observer, Trace v1, session v1, `headless-v1`, and facade terminal behavior remain compatible.

# verification

- Core package tests cover missing/explicit permissive/explicit deny composition and fixed gate order.
- Unknown Tool and invalid arguments soft-fail before policy/handler.
- Jail and shell denial execute no handler and emit one correlated source result.
- Durable Trace adapter failure maps to the existing typed run/facade terminal category; verbose adapter remains
  best-effort without raw fallback.
- Completed, Tool, cancellation, provider failure, OOM, invalid Toolset/context, timeout, and unsupported-control paths
  preserve exactly one facade terminal.
- external SDK consumer composes both low-level Core and high-level Agent using only module imports.
- package tests, root std/curl suites, headless process fixture, docs lint, and quality score checks pass.

# non-goals

- moving session/Trace/redaction/policy/context files;
- adding public lifecycle-v1, provider deltas, Tool progress, steering, or async events;
- changing schema versions or product defaults.
