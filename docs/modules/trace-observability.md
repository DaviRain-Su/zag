# Module: trace-observability

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{trace,observer}.zig`; run facade in coding-agent `agent.zig` |
| Current maturity | **L2** (lifecycle/schema/atomic persistence + redaction before serialize) |
| Target | L2 (H) → L3 dashboard (C9) |
| Reference | Hyper telemetry/dashboard; SECURITY audit |

## Purpose

Trace is a versioned audit channel for reconstructing run decisions. Observer is an in-process event side channel. Neither is a debug-print substitute, and neither may report a successful terminal state for a failed run.

## Lifecycle invariants

1. Every **started** run (`run_start` succeeded) has exactly one committed terminal event (`run_end`) for ordinary post-start failures and normal Results.
2. Terminal state is derived from the actual result/error; `Agent.deinit` / `Trace.deinit` only release memory.
3. Stable `stop_reason` values: `completed | max_turns | cancelled | timeout | unsupported_control | provider_error | session_error | trace_error | out_of_memory | invalid_toolset | invalid_context`.
4. `run_end.ok=false` for harness failures, **deadline `timeout`**, and **`unsupported_control`**; clean cooperative `cancelled` and normal `max_turns` / `completed` use `ok=true`.
5. Explicit path persistence is fail-closed: typed `TraceIoFailed` / `InvalidPath` (never OOM-mapped filesystem errors).
6. **One reply = one run.** Explicit path atomically holds the **latest completed reply** only (not a lifetime accumulation).
7. Redaction before serialize/persist (`h-redact-001`): when `Trace.redactor` is set (product Agent attaches for the reply and **clears on every exit**), every arbitrary string field is redacted **before** JSON serialization. Public `stop_reason` is redacted; Agent-controlled vocabulary is allocation-free. Redaction OOM → `OutOfMemory` (fail closed; terminal path falls back to minimal internal reason). **Low-level bypass:** `Trace.redactor == null` / unbound (product Agent always binds for the reply). See also session `*Unredacted` APIs and `Observer.stderrLogUnredacted()`.

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

### Persist / terminal error categories (`emitRunEnd`)

`emitRunEnd` is transactional across **both** terminal serialization and persistence. Snapshot is restored on any intended-terminal failure.

| Failure | In-memory result | Returned |
|---------|------------------|----------|
| Intended terminal `TraceSerializationFailed` | minimal ASCII `ok=false, stop_reason=trace_error`; persist when path set | `TraceSerializationFailed` |
| `TraceIoFailed` after intended ser | minimal `trace_error` terminal | `TraceIoFailed` |
| Guard `OutOfMemory` | minimal `out_of_memory` terminal | `OutOfMemory` |
| `InvalidPath` final recheck | minimal `trace_error` terminal | `InvalidPath` |

Minimal failure terminals use only ASCII literals (no user strings / no USD) so they always fit `terminal_reserve`.

Guard is re-checked at persist entry **and** immediately before `atomic.replace`. Residual TOCTOU after the last check remains (trusted-host).

### String / number policy

- **UTF-8:** every traced string must be valid UTF-8 before write; invalid bytes → `TraceSerializationFailed` (transactional; not OOM). Truncation respects codepoint boundaries. (Zig default stringify would emit invalid UTF-8 as a number array — we fail closed so fields stay JSON strings.)
- **`estimated_usd`:** NaN / ±Inf are **omitted** (never written). Finite values only. Prevents invalid JSON (`inf`) from Zig's f64 stringify.

## Schema (L2)

Exported: `trace.current_schema_version` (**1**).

Every `run_start` includes `schema_version`, Zag `version`, `permission`, `shell_policy`, optional `session`.

### Compatibility

- Additive optional fields within a version: OK; strict readers ignore unknown fields.
- Unknown `schema_version`: fail in strict readers.
- Breaking renames require a new schema version.

Event kinds: `run_start` · `turn` · `assistant` · `usage` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `provider_retry` · `compaction` · `run_end`.

### Shell result projection (`h-shell-001` open)

Shell policy denial emits `shell_deny` and a matching Tool result without invoking the handler. Synchronous runtime outcomes emit ordinary `tool_result`; the stable `shell-v1` classification is the first line of its bounded body so it survives trace body capping. Runtime `shell_timeout` is a recoverable Tool soft result and does **not** change the Agent terminal to provider `stop_reason=timeout`.

The shell module owns outcome codes, capture limits, and direct-child cleanup claims. Trace owns only truthful projection and the unique run terminal. Agent composition fixtures must parse the trace and bind the expected policy/runtime result to exactly one same-object `run_end`; they must not infer process-tree cleanup or mid-flight Tool cancellation from trace presence.

### Compaction event (h-context-001)

| Field | Cap / rule |
|-------|------------|
| `dropped` | Final omitted body-prefix count (same as session event) |
| `summary` | Bounded UTF-8; `cap_compaction_summary` = `context.summary_cap` (**800**). Prefer `emitCompactionEvent(CompactionEvent)`. |

Loop order: session `on_compaction` sink first; on sink OOM the run fails with `OutOfMemory` and **no** compaction line is written. Success-path session meta and trace summary are byte-equal. Note-then-trace-emit failure is a visible run error (not silent success). Do not weaken exact-terminal / error behavior for other kinds.

`invalid_context` is a truthful terminal when history tool bundles fail closed before the provider call.

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
- [x] secret redaction before write (`h-redact-001`).
- [x] SECURITY links to this contract.

## L3

- local usage/timing dashboard; CI artifact conventions; subagent correlation after C6.

## Non-goals for H

- Mandatory cloud telemetry; TUI/dashboard rendering.
