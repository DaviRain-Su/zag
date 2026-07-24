# Module: trace-observability

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{trace,observer}.zig`; run facade in coding-agent `agent.zig` |
| Current maturity | **L2** (lifecycle/schema/atomic persistence) — redaction still P1 (`h-redact-001`) |
| Target | L2 (H) → L3 dashboard (C9) |
| Reference | Hyper telemetry/dashboard; SECURITY audit |

## Purpose

Trace is a versioned audit channel for reconstructing run decisions. Observer is an in-process event side channel. Neither is a debug-print substitute, and neither may report a successful terminal state for a failed run.

## Lifecycle invariants

1. Every **started** run (`run_start` succeeded) has exactly one committed terminal event (`run_end`) for ordinary post-start failures and normal Results.
2. Terminal state is derived from the actual result/error; `Agent.deinit` / `Trace.deinit` only release memory.
3. Stable `stop_reason` values: `completed | max_turns | cancelled | provider_error | session_error | trace_error | out_of_memory | invalid_toolset`.
4. `run_end.ok=false` for harness failures; clean cooperative `cancelled` and normal `max_turns` / `completed` use `ok=true`.
5. Explicit path persistence is fail-closed: typed `TraceIoFailed` / `InvalidPath` (never OOM-mapped filesystem errors).
6. **One reply = one run.** Explicit path atomically holds the **latest completed reply** only (not a lifetime accumulation).
7. Redaction before serialize/persist is P1 (`h-redact-001`).

## Lifecycle owner

The **coding-agent facade** (`Agent.reply` / `completeWithSession`) owns terminals:

1. Reset run-local ledger + trace buffer; non-destructive preflight; reserve buffer capacity.
2. `run_start` (run is started).
3. `appendUser` / loop / session save — each caught; no terminal gaps on ordinary errors.
4. Session save **before** a successful terminal is committed.
5. Exactly one `run_end` with truthful `ok` / `stop_reason`.

The loop emits mid-run events only and propagates emit errors (`TraceFailed` / `OutOfMemory`); it does not scatter `run_end`.

### Stop-reason mapping (facade)

| Primary error | `stop_reason` |
|---------------|---------------|
| `ProviderFailed` | `provider_error` |
| `OutOfMemory` (incl. appendUser) | `out_of_memory` |
| `InvalidToolset` | `invalid_toolset` |
| Session save `IoFailed` | `session_error` |
| Trace preflight/persist | `trace_error` (or no run if preflight before start) |
| Mid-run emit `TraceFailed` | `trace_error` |

Never map OOM / invalid toolset to `provider_error`.

### Fail-closed error precedence

If committing the **failure** terminal itself fails (serialization OOM or explicit-path `TraceIoFailed`), the **trace** error is returned rather than silently keeping only the primary. Documented so callers can distinguish “primary failed and audit also failed.”

### Flush / preflight / atomic design

| Step | Behavior |
|------|----------|
| **Preflight** | Validate relative workspace-safe path; `createFileAtomic(..., replace=true)` then **deinit without replace**. Destination bytes unchanged. |
| **Final persist** | Serialize full buffer → atomic temp (`replace=true`) → write → file-writer flush → optional test fault → `atomic.replace`. Failure → `TraceIoFailed`; prior destination unchanged. |
| **Success persist fail** | Roll back in-memory `ok=true` line; keep one in-memory `ok=false, stop_reason=trace_error` when capacity allows; return `TraceIoFailed`. |
| **Memory-only** (`path=null`) | No filesystem; events in `Trace.buf` for tests/SDK. |

**Unavoidable limit:** an unwritable filesystem cannot durably record its own failure. Prior durable content is preserved; the failure terminal is best-effort in memory only.

### Transactional `writeObj`

Serialize a complete JSON line first, then `ensureUnusedCapacity`, then append and increment `event_count`. On any failure, buffer length and seq are unchanged (no sequence gap). Terminal commit does **not** mark finished/closed/count until serialization and (for explicit paths) atomic persistence succeed—or until the rolled-back in-memory failure terminal is committed after a persist fault.

### Path policy (symlink-aware)

- Lexical: relative, no `..` escape, no absolute (same as session paths).
- **Create containment:** before preflight and before final replace, `workspace.Guard.checkCreate` on the workspace `cwd` (typically process cwd). Parent symlink/alias escape and dangling links → `InvalidPath` (fail-closed). OOM from Guard is preserved as `OutOfMemory`.
- Atomic create/write uses the same workspace `cwd` handle.
- **Not an OS sandbox.** Residual TOCTOU between Guard check and `createFileAtomic` is trusted-host only (same honesty as file tools).

### Allocator / terminal reserve (real post-start guarantee)

- Event JSON is serialized on a **stack fixed buffer** (`event_stack_size` = 8 KiB) sized for worst-case JSON escaping of public truncation caps (e.g. 800-byte tool args).
- Fixed-writer / event-too-large / terminal-reserve invariant failures → **`TraceSerializationFailed`** (never OOM).
- Only real allocator failures (`Trace.buf` grow, Guard allocator) return **`OutOfMemory`**.
- Nonterminal appends: `ensureUnusedCapacity(line.len + terminal_reserve)` (`terminal_reserve` = 1 KiB).
- Terminal appends use only pre-reserved free capacity; `stop_reason` truncated to 48 bytes.
- **Contract-tested:** max control-byte fields parse strictly under stack bound; post-start nonterminal OOM still commits `out_of_memory` terminal; intentional uncapped oversize → `TraceSerializationFailed` then `trace_error` terminal.

### Persist error categories (`emitRunEnd`)

| `persistAtomic` error | In-memory terminal after rollback | Returned error |
|----------------------|-----------------------------------|----------------|
| `TraceIoFailed` | `ok=false, stop_reason=trace_error` if intended was ok; else keep failure reason | `TraceIoFailed` |
| `OutOfMemory` (Guard) | `ok=false, out_of_memory` | `OutOfMemory` |
| `InvalidPath` (final recheck) | `ok=false, trace_error` if intended was ok | `InvalidPath` |
| `TraceSerializationFailed` | as above / keep category | `TraceSerializationFailed` |

Guard is re-checked at persist entry **and** immediately before `atomic.replace`. Residual TOCTOU after the last check remains (trusted-host).

## Schema (L2)

Exported: `trace.current_schema_version` (**1**).

Every `run_start` includes `schema_version`, Zag `version`, `permission`, `shell_policy`, optional `session`.

### Compatibility

- Additive optional fields within a version: OK; strict readers ignore unknown fields.
- Unknown `schema_version`: fail in strict readers.
- Breaking renames require a new schema version.

Event kinds: `run_start` · `turn` · `assistant` · `usage` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `provider_retry` · `compaction` · `run_end`.

## Public errors

```text
trace.Error = OutOfMemory | TraceIoFailed | InvalidPath | TraceSerializationFailed
```

Facade `ReplyError` includes `trace.Error`. Loop maps mid-run `TraceSerializationFailed` / I/O / path to `TraceFailed` (terminal `trace_error`); pure `OutOfMemory` stays `OutOfMemory`.

## Observer contract

Callbacks must not own borrowed event slices after return unless they copy them.

## L2 acceptance

- [x] provider/auth failure → one `ok=false`, `provider_error`.
- [x] complete / max_turns / cancel / session save / trace persist paths truthful.
- [x] schema version contract-tested.
- [x] non-destructive preflight + atomic replace; prior bytes preserved on fault.
- [x] per-reply latest-run file/buffer semantics + run-local ledger.
- [x] transactional writeObj under allocator failure.
- [x] fail-closed precedence when failure-terminal persist fails.
- [ ] secret redaction before write (`h-redact-001`).
- [x] SECURITY links to this contract.

## L3

- local usage/timing dashboard; CI artifact conventions; subagent correlation after C6.

## Non-goals for H

- Mandatory cloud telemetry; TUI/dashboard rendering.
