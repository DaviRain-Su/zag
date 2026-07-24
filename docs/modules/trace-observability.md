# Module: trace-observability

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{trace,observer}.zig`; run facade in coding-agent `agent.zig` |
| Current maturity | **L1** — events exist; terminal truth/persistence/schema are P0/P1 |
| Target | L2 (H) → L3 dashboard (C9) |
| Reference | Hyper telemetry/dashboard; SECURITY audit |

## Purpose

Trace is a versioned audit channel for reconstructing run decisions. Observer is an in-process event side channel. Neither is a debug-print substitute, and neither may report a successful terminal state for a failed run.

## Lifecycle invariants

1. Every started run has exactly one terminal event.
2. Terminal state is derived from the actual result/error, never from destructor fallback assumptions.
3. `completed`, `max_turns`, `cancelled`, `provider_error`, timeout, session persistence failure, and trace persistence failure are distinguishable according to the public error policy.
4. `run_end.ok=false` for every failed run.
5. Deinit may release resources but must not invent `ok=true/completed`.
6. If an explicit trace path cannot be persisted, the caller receives a typed/structured failure; silent audit loss is forbidden.
7. Redaction occurs before event serialization/persistence.

## Schema (L2)

A trace starts with a schema-identifying record or a `run_start` containing `schema_version` and Zag version.

Minimum event kinds:

`run_start` · `turn` · `assistant` · `usage` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `provider_retry` · `compaction` · `run_end`

`run_end` contains:

- turns;
- `ok`;
- stable `stop_reason`/error category;
- available usage/cost totals.

Unknown schema versions fail explicitly in strict readers. Additive event fields follow a documented compatibility policy.

## Observer contract

Observer already supports an opaque `ptr`; high-level Agent injection and lifecycle compatibility are part of the SDK gate. H stabilizes run/turn/tool terminal semantics before adding a broader event surface.

Callbacks must not own borrowed event slices after the callback returns unless they copy them.

## Current gaps

- Provider failure can return `ProviderFailed`, then Agent deinit finalizes an unfinished trace as `ok=true/completed`.
- trace directory/file I/O is swallowed.
- schema version is absent.
- event surface does not yet expose a complete versioned run/turn lifecycle for SDK/headless consumers.

## L2 acceptance

- [ ] provider/auth failure produces exactly one `ok=false`, `provider_error` terminal event.
- [ ] complete/max-turns/cancel/timeout/save failure each produce one truthful terminal state.
- [ ] schema version and compatibility are contract-tested.
- [ ] permission, jail, shell, usage, compaction, and Tool results are replayable.
- [ ] explicit trace-path I/O failure is observable.
- [ ] secret fixtures are redacted before write.
- [ ] SECURITY links to this schema/limitation.

## L3

- local usage/timing dashboard;
- CI artifact conventions;
- subagent correlation after C6.

## Non-goals for H

- Mandatory cloud telemetry
- TUI/dashboard rendering
