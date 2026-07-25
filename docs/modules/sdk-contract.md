# Zag SDK Public Contract

> Status: **SDK-ready Gate in progress**. This document records the supported
> in-process Zig source-composition contract for `zag-types`, `zag-agent-core`,
> and `zag-coding-agent`. It does **not** promise C ABI, dynamic plugin ABI,
> semver publication, headless protocol, OS sandbox, or mid-flight Tool/shell
> preemption. See [D-008](../decisions/active/D-008-sdk-and-process-boundaries.md).

## 1. What is covered

This contract covers the following supported import surface:

| Package | Module name | Public root |
|---|---|---|
| `zag-types` | `zag-types` | `packages/zag-types/src/root.zig` |
| `zag-agent-core` | `zag-agent-core` | `packages/zag-agent-core/src/root.zig` |
| `zag-coding-agent` | `zag-coding-agent` | `packages/zag-coding-agent/src/root.zig` |

Consumers must import **only** by module name. Importing sibling package source
paths such as `@import("../packages/zag-agent-core/src/agent.zig")` is
unsupported and may break without notice.

The high-level composition entry point is `zag-coding-agent.Agent`:

```zig
const coding = @import("zag-coding-agent");

var agent = try coding.Agent.init(gpa, io, provider, .{
    .permission_mode = .ask,
    .toolset = &[_]coding.tool.Tool{ my_tool },
    .observer = my_observer,
});
```

## 2. Ownership and lifetime

All rules below are caller-borrowed unless explicitly stated otherwise.

| Object | Owner | Borrow rule |
|---|---|---|
| `Tool`, descriptor strings, `instance` pointer | caller | Must outlive every copy of the `Tool`/`Toolset` and every `handler` invocation. `Tool` is copyable and shares the same borrowed instance pointer. Source: [`packages/zag-agent-core/src/tool.zig:20-30`](../../packages/zag-agent-core/src/tool.zig). |
| `Provider` (`ptr` + `vtable`) | caller | Must outlive the `Agent` and every `loop.run` call. Provider receives a scratch arena per `chat`; returned `AssistantTurn` contents belong to that arena. Source: [`packages/zag-agent-core/src/provider.zig:30-45`](../../packages/zag-agent-core/src/provider.zig). |
| `Observer` event slices | callback | Slices inside `Observer.Event` are valid only for the duration of the callback. Copy if needed. |
| `Session` | caller | Must outlive every `Agent.reply(&session, ...)` call. Holds transcript arena and writer lock. |
| `Agent` | caller | `deinit` releases resources only; it never invents a successful `run_end`. |
| `Trace.path` | caller | `Trace` stores the pointer/bytes; the path slice must outlive the `Trace`. |
| `CancelFlag` | caller/host | Must outlive the entire run; provider borrows `*CancelFlag` in-flight. |
| `Redactor` | `Agent`/`Session` | `clone` produces an independent copy. No cryptographic zeroization is promised. |
| `RequestControl.deadline_mono_ns` | value | Immutable after construction; compares only process-local monotonic time. |

## 3. Error contract

### 3.1 Facade error mapping

| Runtime condition | `loop.run` | `Agent.reply` | Terminal `stop_reason` | `ok` |
|---|---|---|---|---|
| Normal completion | `Result{ .stop_reason = .completed }` | `Result` | `completed` | true |
| Max turns | `Result{ .stop_reason = .max_turns }` | `Result` | `max_turns` | true |
| Clean cancel | `Result{ .stop_reason = .cancelled }` | `Result` | `cancelled` | true |
| Deadline | `Result{ .stop_reason = .timeout }` | `Result` | `timeout` | false |
| Unsupported control | `Result{ .stop_reason = .unsupported_control }` | `Result` | `unsupported_control` | false |
| Provider/auth failure | `error.ProviderFailed` | `ReplyError` | `provider_error` | false |
| Invalid toolset | `error.InvalidToolset` | `ReplyError` | `invalid_toolset` | false |
| Out of memory | `error.OutOfMemory` | `ReplyError` | `out_of_memory` | false |
| Mid-run trace failure | `error.TraceFailed` | `ReplyError` | `trace_error` | false |
| Invalid context | `error.InvalidContext` | `ReplyError` | `invalid_context` | false |
| Session save failure | — | `session_store.Error` | `session_error` | false |
| Trace persist failure | — | `trace.Error` | `trace_error` | false |

Sources: [`packages/zag-agent-core/src/loop.zig:70-120`](../../packages/zag-agent-core/src/loop.zig), [`packages/zag-coding-agent/src/agent.zig:630-640`](../../packages/zag-coding-agent/src/agent.zig).

### 3.2 Retry policy

`Timeout`, `Cancelled`, `NotSupported`, and `UnsupportedControl` are **never**
retried. Loop-level retries apply only to `RateLimited`, `ServerError`, and
`HttpFailed`.

## 4. Event contract

`Observer.Event` is emitted by the loop:

```zig
pub const Event = union(enum) {
    assistant_text: []const u8,
    usage: message.Usage,
    tool_call: message.ToolCall,
    tool_result: struct { name: []const u8, body: []const u8 },
    permission: struct { tool_name: []const u8, allowed: bool, remembered: bool = false, risk: ?[]const u8 = null },
};
```

Source: [`packages/zag-agent-core/src/observer.zig:10-25`](../../packages/zag-agent-core/src/observer.zig).

When an external observer is supplied to `Agent.Options.observer`, it is
invoked **before** the Agent's internal usage/verbose handler. A `null`
`on_event` is silently ignored. Events received by the callback are borrowed;
copy any needed slices before returning.

Trace schema v1 event kinds:

```zig
run_start, turn, assistant, usage, tool_call,
permission, jail_deny, shell_deny, tool_result,
provider_retry, compaction, run_end
```

Source: [`packages/zag-agent-core/src/trace.zig:67-75`](../../packages/zag-agent-core/src/trace.zig).

### 4.1 Event invariants

- One started run produces exactly one `run_end` event.
- `run_end.ok` reflects the true outcome; `deinit` does not fabricate success.
- Trace writes redaction **before** serialization. Redaction OOM returns
  `OutOfMemory`, never raw output.
- Session compaction is applied before trace compaction; if the session sink
  OOMs, no trace compaction line is written, preventing silent metadata drift.

## 5. Cancellation and deadline

Two supported cancellation mechanisms:

1. **Deadline**: set `Options.provider_timeout_ms`. A zero value means immediate
   `Timeout`. Source: [`packages/zag-types/src/root.zig:95-190`](../../packages/zag-types/src/root.zig).
2. **Explicit cancel**: call `Agent.requestCancel()` (sets the internal
   `CancelFlag`). The flag is checked between turns and between tools, **not**
   inside a running Tool handler.

`Agent.reply` defines **per-run cancel semantics**: at the start of each reply
any stale flag from a previous run is cleared, so a single `requestCancel()`
affects only the current run. A flag that is set during the current run — either
between Tools or while the provider request is in flight — is still observed and
produces `stop_reason=cancelled`. The CLI installs a single SIGINT handler
against `agent.cancel`; per-run clearing prevents one Ctrl-C from permanently
cancelling every future REPL turn.

When both cancel and deadline fire, **cancel wins**. The curl backend performs
active in-flight cancellation; the std backend returns `UnsupportedControl` for
configured deadlines.

If an accepted multi-tool turn is cancelled between tools, the remaining tool
results are backfilled with `code=cancelled`, keeping the transcript resume-safe.
Source: [`packages/zag-agent-core/src/loop.zig:280-290`](../../packages/zag-agent-core/src/loop.zig).

## 6. Session persistence

`Session.start` semantics:

| Open mode | Behavior |
|---|---|
| `create_new` | Fail with `SessionAlreadyExists` if the path exists; never overwrite. |
| `resume_existing` | Fail with distinct errors for missing/invalid/unsupported/busy; never fall back to creation. |
| `open_or_create` | Create only on `SessionNotFound`; all other errors propagate unchanged. |

Save semantics:

- Atomic: write to a temporary file, then replace.
- Failure preserves the original file bytes.
- Single writer: advisory exclusive lock via `{path}.lock`.
- No fsync/power-loss guarantee.
- Session paths are validated lexically (relative, no `..`, not absolute); this
  is **not** symlink containment.

Source: [`packages/zag-agent-core/src/session_store.zig:37-46`](../../packages/zag-agent-core/src/session_store.zig).

## 7. Compatibility

- Trace schema version: `trace.current_schema_version = 1`
  ([`packages/zag-agent-core/src/trace.zig:35`](../../packages/zag-agent-core/src/trace.zig)).
- Session schema version: `session_store.current_schema_version = 1`
  ([`packages/zag-agent-core/src/session_store.zig:49`](../../packages/zag-agent-core/src/session_store.zig)).
- Within a major schema version, only optional fields may be added. Strict
  readers fail on unknown versions.
- Destructive renames require a new schema version plus migration or explicit
  rejection.
- **No semver promise** until the SDK-ready Gate closes and a second real consumer
  plus release channel exist (see [packaging.md](../packaging.md)).

## 8. Non-goals

The following are explicitly **not** covered by this contract:

| Out of scope | Reason |
|---|---|
| C ABI | Use the future process/headless contract. |
| Zig dynamic plugin ABI | Same as C ABI; plugin loading is post-H. |
| Semver publication | Requires second consumer + release channel. |
| Headless protocol / JSON-RPC | Covered by `headless-001`, not this task. |
| OS sandbox | Process-supervisor work (C7). |
| Mid-flight Tool/shell preemption | `.cooperative` is metadata only; real preemption is post-H process work. |

## 9. Related

- [packaging.md](../packaging.md#sdk-ready-gate)
- [architecture.md](../architecture.md)
- [D-008](../decisions/active/D-008-sdk-and-process-boundaries.md)
- [D-007](../decisions/active/D-007-tool-runtime-descriptor.md)
- Consumer fixture: [`tests/sdk-consumer-fixture/`](../../tests/sdk-consumer-fixture/)
