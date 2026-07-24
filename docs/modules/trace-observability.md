# Module: trace-observability

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{trace,observer}.zig`; run facade in coding-agent `agent.zig` |
| Current maturity | **L2** (lifecycle/schema/persistence) — redaction still P1 (`h-redact-001`) |
| Target | L2 (H) → L3 dashboard (C9) |
| Reference | Hyper telemetry/dashboard; SECURITY audit |

## Purpose

Trace is a versioned audit channel for reconstructing run decisions. Observer is an in-process event side channel. Neither is a debug-print substitute, and neither may report a successful terminal state for a failed run.

## Lifecycle invariants

1. Every started run has exactly one terminal event (`run_end`).
2. Terminal state is derived from the actual result/error, never from destructor fallback assumptions.
3. `completed`, `max_turns`, `cancelled`, `provider_error`, `session_error`, and `trace_error` are distinguishable stop reasons.
4. `run_end.ok=false` for every failed run (provider/session/trace failures; not for cooperative `cancelled` / normal `max_turns` / `completed`).
5. `Agent.deinit` may release resources but must not invent `ok=true/completed`.
6. If an explicit trace path cannot be persisted, the caller receives `error.TraceIoFailed` (or `InvalidPath`); silent audit loss is forbidden.
7. Redaction occurs before event serialization/persistence (P1 `h-redact-001`).

## Lifecycle owner

The **coding-agent facade** (`Agent.reply` / `completeWithSession`) owns terminals because it sees:

- loop `Result` / `RunError`;
- session save;
- trace preflight + final flush.

The loop emits mid-run events only; it does not scatter `run_end`. Duplicate `emitRunEnd` is a no-op (single terminal guard).

### Order on success

1. preflight explicit path (if any);
2. `run_start`;
3. loop;
4. **session save**;
5. `run_end` + flush.

Save failure cannot leave `ok=true/completed`: save runs before the success terminal is committed.

### Failure terminals

| Path | API error | `ok` | `stop_reason` |
|------|-----------|:----:|---------------|
| Provider/auth | `ProviderFailed` | false | `provider_error` |
| Session save | `IoFailed` (session) | false | `session_error` |
| Explicit path preflight/flush | `TraceIoFailed` / `InvalidPath` | — / false | preflight: no run; flush after success: error; flush after failure: original error kept |
| Cancelled Result | (none) | true | `cancelled` |
| Max turns Result | (none) | true | `max_turns` |
| Completed Result | (none) | true | `completed` |

### Flush / preflight precedence

- **Preflight** (explicit path): validate relative workspace-safe path, create parents, probe write. Failure → typed error **before** provider work. No `run_start` when preflight fails first.
- **Final flush after successful loop+save**: `TraceIoFailed` is returned (cannot report audited success without durable write). In-memory buffer still holds the truthful terminal.
- **Final flush after provider/session failure**: original typed error is preserved; terminal is best-effort in memory. Trace I/O was secondary.
- **Memory-only** (`path=null`): no filesystem; events stay in `Trace.buf` for tests/SDK.

### Path policy

Trace paths use the same lexical relative/workspace rules as session paths (`workspace.checkToolPath`). Absolute, `..` escape, empty, and NUL paths → `InvalidPath`. This is **not** an OS sandbox and does not claim TOCTOU immunity (trusted-host model).

## Schema (L2)

Exported constant: `trace.current_schema_version` (**1**).

Every `run_start` includes:

- `schema_version` (integer);
- `version` (Zag package version string);
- `permission`, `shell_policy`, optional `session`.

### Compatibility policy

- **Additive** optional fields within a schema version are allowed; strict readers ignore unknown fields.
- **Unknown `schema_version`** must fail explicitly in strict readers (this package is a writer; readers are consumer-side).
- Breaking field renames/removals require a new schema version.

Minimum event kinds:

`run_start` · `turn` · `assistant` · `usage` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `provider_retry` · `compaction` · `run_end`

`run_end` contains:

- `turns`;
- `ok`;
- stable `stop_reason`;
- available usage/cost totals (`prompt_tokens`, `completion_tokens`, `total_tokens`, optional `estimated_usd`).

## Public errors

```text
trace.Error = OutOfMemory | TraceIoFailed | InvalidPath
```

- `TraceIoFailed` — create/write/flush/preflight filesystem failure (not mapped to OOM).
- `InvalidPath` — non-relative / escape path.
- Facade `ReplyError` includes `trace.Error` so CLI/SDK can distinguish session `IoFailed` from trace I/O.

## Observer contract

Observer already supports an opaque `ptr`; high-level Agent injection and lifecycle compatibility are part of the SDK gate. H stabilizes run/turn/tool terminal semantics before adding a broader event surface.

Callbacks must not own borrowed event slices after the callback returns unless they copy them.

## L2 acceptance

- [x] provider/auth failure produces exactly one `ok=false`, `provider_error` terminal event.
- [x] complete/max-turns/cancel/save failure each produce one truthful terminal state.
- [x] schema version and compatibility are contract-tested.
- [x] permission, jail, shell, usage, compaction, and Tool results are replayable (events exist; redaction P1).
- [x] explicit trace-path I/O failure is observable (`TraceIoFailed` / preflight).
- [ ] secret fixtures are redacted before write (`h-redact-001`).
- [x] SECURITY links to this schema/limitation.

## L3

- local usage/timing dashboard;
- CI artifact conventions;
- subagent correlation after C6.

## Non-goals for H

- Mandatory cloud telemetry
- TUI/dashboard rendering
