# Module: loop-turn

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/loop.zig` |
| Layer | Thin Agent Core Kernel; ownership contract [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) |
| Current maturity | **L2** — core loop/goldens + truthful terminals + provider control + accepted multi-Tool between-call Agent composition passed independent/main Gate |
| Target | L2 (H) → L3 steer/read-only parallelism (C6) |
| Reference | Pi agent loop; Nanocodex Turn |

## Purpose

Run one generic agent loop: poll an explicit `ControlInput` only at protocol-safe boundaries, obtain a model view through `ContextView`, request one assistant turn, execute requested Tools through required policy/jail/shell ports, append results, emit source facts, and return a typed loop outcome. Product queues, persistence, and run terminals are facade responsibilities. The control seam is the in-progress `harness-steering-001` target; current closed behavior remains the no-control composition.

## Invariants

1. The model chooses Tool calls; the harness validates, executes, and returns results.
2. Expected Tool failures are machine-readable soft results, not process crashes.
3. Provider input is a context view; transcript remains authoritative.
4. Loop source facts are emitted once in program order; product run preflight/start/terminal remain facade-owned. Core `LoopEvent.assistant_message` carries `{ text, has_tools }` (mandatory, no default false); `LoopEvent.tool_end` carries a borrowed `id` (mandatory, no `""` fallback).
5. Required `ToolPolicy → Jail → ShellPolicy → execution` remains ordered; no missing safety port becomes allow/yolo.
6. Cancellation and steering never leave unmatched accepted Tool calls in transcript; pending cancel is `code=cancelled`, while pending steering interruption is `code=steered`.
7. A control queue item is committed only after its user row is copied into the authoritative transcript; no-answer turn budget never consumes it.
8. Core owns Toolset/protocol-history validation, safe insertion points, and execution ordering—not concrete queues, product policy, compaction, persistence, redaction, or logging.

## Public result/error contract

`run(deps, transcript)` returns a Result for normal completion, max turns, and clean cancellation. Provider/host failures may remain typed errors, but their Observer/trace terminal category must be `provider_error` or the corresponding stable failure—not `completed`.

Stable stop categories include:

`completed | max_turns | cancelled | timeout | unsupported_control | provider_error | session_error | trace_error | out_of_memory | invalid_toolset | invalid_context`

- Loop returns Result for `completed` / `max_turns` / `cancelled` / **`timeout`** / **`unsupported_control`**.
- Loop returns `error.ProviderFailed` for provider/auth failures (facade → `ok=false`, `provider_error`).
- **Timeout** → `timeout` (ok=false); **Cancelled** → `cancelled` (ok=true); **UnsupportedControl** → `unsupported_control` (ok=false).
- Loop returns `error.InvalidToolset` / `error.InvalidContext` / `error.OutOfMemory` / visible port/sink failures as typed errors (facade maps them exhaustively — **never** misclassified as provider success). During D-011 migration, the existing Trace adapter preserves `TraceFailed` / `trace_error`.
- `session_error` / `trace_error` terminals are committed by the **facade** only.
- Mid-run durable observation failures are never swallowed: the fallible product `LoopEventSink` preserves `OutOfMemory` versus audit/sink failure and the facade's truthful terminal mapping.

## Tool error shape

Expected Tool mistakes return:

```text
error: code=<CODE> message=<human>
```

Minimum codes:

`unknown_tool | invalid_arguments | permission_denied | jail_deny | shell_deny | tool_failed | cancelled | steered`

Malformed host registration is not an `unknown_tool` soft result; it fails before running. See [tool-runtime](./tool-runtime.md).

## Cancellation/deadline and control boundaries

- Cooperative cancel flag checks run before provider turns, Tool calls, and queued-control application; an observed cancel wins without consuming a queued message.
- `harness-steering-001` polls one Session-owned item at pre-turn, between-Tool, or would-complete boundaries only. It never interrupts `Provider.chat` or an entered Tool handler.
- Mid-batch steering first pre-copies/reserves the future user row, then closes every remaining accepted call with the stable end-only body `error: code=steered message=steering selected; pending tool did not execute.`, appends without allocation, and continues the same run.
- One atomic would-complete peek gives steering priority over follow-up; that boundary rechecks cancel before selection.
- Control is one-at-a-time and does not extend `max_turns`; without budget for an answering provider turn, the item remains pending and the run reports `max_turns`.
- **In-flight provider path** (h-provider-001): cancel flag + optional end-to-end `provider_timeout_ms` → `RequestControl`.
- **curl** actively enforces deadline/cancel; **std** fails closed with `unsupported_control` when a deadline is configured (ordinary no-timeout std remains usable).
- Loop is sole retry/backoff owner (overflow-safe ≤25ms slices); Timeout/Cancelled/UnsupportedControl are not retried.
- Only a complete validated `AssistantTurn` is appended; partial streamed tool-call fragments are discarded on cancel/timeout.
- Pending **accepted** tool calls still get cancelled bodies for transcript consistency when cancel fires between tools. These pending-cancel calls emit `tool_end` **only** (no fabricated `tool_start`); the call index is derived from program order so consumers can correlate by turn + call index + id.
- Tool handlers that declare `.cooperative` cancel metadata do not yet receive mid-flight preemption. This is post-H shell/process ownership work, not part of h-provider-001 or the between-Tool H fixture.

## Execution strategy

L2 executes a Tool-call batch serially in call order. Parallel read-only batches remain L3 and require descriptor-based risk/concurrency capabilities.

## Current gaps

- The D-011 ownership migration is complete: `loop.run` routes through explicit `ToolPolicy`, `Jail`, `ShellPolicy`, `ContextView`, and fallible canonical `LoopEventSink`; session, observation, concrete policy, and product context ownership now live in `zag-coding-agent`. See [core-boundary](./core-boundary.md).
- Mid-flight Tool-handler cancel (shell/process ownership and cleanup) remains explicit post-H work and is not an H L2 requirement.
- High-level SDK lifecycle is **done** (`harness-events-001` at `aecf402`) as a product adapter in `zag-coding-agent`; Core still has no `lifecycle.zig`. `harness-steering-001` is **in-progress** and may add only a generic `ControlInput` seam plus a source-backed `control_applied` fact; concrete Session queues remain in coding-agent. Streaming deltas and Tool progress remain outside this surface.

## L2 acceptance

- [x] stable machine-readable Tool errors for built-in paths.
- [x] serial Tool order is tested.
- [x] module-level cancel between calls fills pending Tool results and remains resume-safe.
- [x] Agent-level accepted multi-Tool cancel preserves IDs and agrees across persisted resume + one parsed terminal (h-integration-001; independent review + main std/curl passed).
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

- bounded steering/follow-up semantics (`harness-steering-001`, in-progress; no mid-flight provider/Tool preemption);
- descriptor-governed parallel read-only Tools;
- subagent lifecycle correlation.

## Non-goals for H

- Distributed workflow engine
- Multi-tenant scheduler
- Graph replacing the normal coding loop
