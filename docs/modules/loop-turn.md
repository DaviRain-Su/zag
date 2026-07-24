# Module: loop-turn

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/loop.zig` |
| Layer | Agent Core Kernel |
| Current maturity | **L1+** — core loop/goldens + truthful failure terminals via facade; in-flight cancel still open |
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

`completed | max_turns | cancelled | provider_error | session_error | trace_error`

- Loop returns Result for `completed` / `max_turns` / `cancelled`.
- Loop returns `error.ProviderFailed` for provider/auth failures (facade commits `ok=false`, `provider_error`).
- `session_error` / `trace_error` terminals are committed by the **facade** (session save / trace persistence), not scattered across loop return sites.
- Mid-run trace emit failures surface as `error.TraceFailed` (never swallowed); they are distinct from explicit-path `TraceIoFailed`.

Deadline/transport distinctions may be structured error details while preserving a stable top-level category.

## Tool error shape

Expected Tool mistakes return:

```text
error: code=<CODE> message=<human>
```

Minimum codes:

`unknown_tool | invalid_arguments | permission_denied | jail_deny | shell_deny | tool_failed | cancelled`

Malformed host registration is not an `unknown_tool` soft result; it fails before running. See [tool-runtime](./tool-runtime.md).

## Cancellation/deadline boundary

- Current cooperative flag checks between provider turns and Tool calls.
- L2 provider path propagates cancellation/deadline into in-flight provider/stream operations.
- A Tool that declares cancellation support receives the run cancellation/deadline context.
- Pending accepted calls receive cancelled results when needed for transcript consistency.
- Partial streamed Tool-call arguments are never executed.

## Execution strategy

L2 executes a Tool-call batch serially in call order. Parallel read-only batches remain L3 and require descriptor-based risk/concurrency capabilities.

## Current gaps

- In-flight provider/stream/tool cancellation is not supported.
- High-level Observer event lifecycle is not yet an SDK contract.

## L2 acceptance

- [x] stable machine-readable Tool errors for built-in paths.
- [x] serial Tool order is tested.
- [x] cancel between calls fills pending Tool results and remains resume-safe.
- [x] at least two golden transcripts exist.
- [x] every normal/error path has one matching terminal state across API and trace (facade owner; h-trace-001).
- [ ] in-flight provider cancellation/deadline is contract-tested.
- [ ] partial Tool calls never execute after stream cancellation.
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
