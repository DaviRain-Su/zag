# Module: loop-turn

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/loop.zig` |
| Layer | Agent Core Kernel |
| Current maturity | **L1+** — core loop/goldens + truthful terminals; provider in-flight cancel/deadline landed; accepted multi-Tool between-call composition Gate pending |
| Target | L2 (H) → L3 steer/read-only parallelism (C6) |
| Reference | Pi agent loop; Nanocodex Turn |

## Purpose

Run one agent loop: build model view, request one assistant turn, execute requested Tools through policy/enforcement, append results, and stop with an auditable outcome.

## Invariants

1. The model chooses Tool calls; the harness validates, executes, and returns results.
2. Expected Tool failures are machine-readable soft results, not process crashes.
3. Provider input is a context view; transcript remains authoritative.
4. Every started run has one truthful terminal lifecycle across Result, error, Observer, and trace.
5. Permission → workspace containment → shell policy → execution remains ordered.
6. Cancellation never leaves unmatched accepted Tool calls in transcript.

## Public result/error contract

`run(deps, transcript)` returns a Result for normal completion, max turns, and clean cancellation. Provider/host failures may remain typed errors, but their Observer/trace terminal category must be `provider_error` or the corresponding stable failure—not `completed`.

Stable stop categories include:

`completed | max_turns | cancelled | timeout | unsupported_control | provider_error | session_error | trace_error | out_of_memory | invalid_toolset | invalid_context`

- Loop returns Result for `completed` / `max_turns` / `cancelled` / **`timeout`** / **`unsupported_control`**.
- Loop returns `error.ProviderFailed` for provider/auth failures (facade → `ok=false`, `provider_error`).
- **Timeout** → `timeout` (ok=false); **Cancelled** → `cancelled` (ok=true); **UnsupportedControl** → `unsupported_control` (ok=false).
- Loop returns `error.InvalidToolset` / `error.OutOfMemory` / `error.TraceFailed` as typed errors (facade maps to `invalid_toolset` / `out_of_memory` / `trace_error` — **never** misclassified as `provider_error`).
- `session_error` / `trace_error` terminals are committed by the **facade** only.
- Mid-run trace emit failures are never swallowed (`mapTraceEmit` → `OutOfMemory` or `TraceFailed`).

## Tool error shape

Expected Tool mistakes return:

```text
error: code=<CODE> message=<human>
```

Minimum codes:

`unknown_tool | invalid_arguments | permission_denied | jail_deny | shell_deny | tool_failed | cancelled`

Malformed host registration is not an `unknown_tool` soft result; it fails before running. See [tool-runtime](./tool-runtime.md).

## Cancellation/deadline boundary

- Cooperative flag checks between provider turns and Tool calls.
- **In-flight provider path** (h-provider-001): cancel flag + optional end-to-end `provider_timeout_ms` → `RequestControl`.
- **curl** actively enforces deadline/cancel; **std** fails closed with `unsupported_control` when a deadline is configured (ordinary no-timeout std remains usable).
- Loop is sole retry/backoff owner (overflow-safe ≤25ms slices); Timeout/Cancelled/UnsupportedControl are not retried.
- Only a complete validated `AssistantTurn` is appended; partial streamed tool-call fragments are discarded on cancel/timeout.
- Pending **accepted** tool calls still get cancelled bodies for transcript consistency when cancel fires between tools.
- Tool handlers that declare `.cooperative` cancel metadata do not yet receive mid-flight preemption. This is post-H shell/process ownership work, not part of h-provider-001 or the between-Tool H fixture.

## Execution strategy

L2 executes a Tool-call batch serially in call order. Parallel read-only batches remain L3 and require descriptor-based risk/concurrency capabilities.

## Current gaps

- h-integration-001 must verify the accepted multi-Tool between-call cancellation chain across Agent/session/trace.
- Mid-flight Tool-handler cancel (shell/process ownership and cleanup) remains explicit post-H work.
- High-level Observer event lifecycle is not yet an SDK contract.

## L2 acceptance

- [x] stable machine-readable Tool errors for built-in paths.
- [x] serial Tool order is tested.
- [x] module-level cancel between calls fills pending Tool results and remains resume-safe.
- [ ] Agent-level accepted multi-Tool cancel preserves IDs and agrees across persisted resume + one terminal (h-integration-001).
- [x] at least two golden transcripts exist.
- [x] every normal/error path has one matching terminal state across API and trace (facade owner; h-trace-001).
- [x] in-flight provider cancellation/deadline is contract-tested (h-provider-001).
- [x] partial Tool calls never execute after stream cancellation (discard + loop fixtures).
- [x] max-turns and failure trace semantics are stable.

## Loop vs Graph

| | Loop (H/default) | Graph (C6+) |
|--|------------------|-------------|
| Purpose | One coding agent Tool loop | Multi-role handoff/fan-out/join |
| State | transcript + context view | shared artifacts/checkpoints |
| Rule | works without Graph | agentic nodes may run this Loop |

H does not introduce a workflow DAG runtime. Graph, Memory, and Oracle hooks are not prerequisites for the L2 loop.

## L3

- steer/interruption semantics;
- descriptor-governed parallel read-only Tools;
- subagent lifecycle correlation.

## Non-goals for H

- Distributed workflow engine
- Multi-tenant scheduler
- Graph replacing the normal coding loop
