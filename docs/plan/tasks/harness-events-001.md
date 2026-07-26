---
id: harness-events-001
scope: sdk/product-lifecycle-observation
status: ready
priority: P1
depends-on:
  - core-context-ownership-001
---

# objective

After the D-011 thin-Core migration, add a source-backed in-process SDK lifecycle adapter in `zag-coding-agent`.
Project Core `LoopEvent` facts and coding-agent facade run facts into complete assistant, correlated Tool start/end, and
one truthful run start/terminal vocabulary.

Do not add `packages/zag-agent-core/src/lifecycle.zig`, a separate Core lifecycle observer, or a third source channel.

Binding specification: [Harness lifecycle events](../../modules/harness-events.md).
Boundary analysis: [Thin Core boundary](../analysis/2026-07-26-thin-core-boundary.md).
Historical superseded analysis: [2026-07-26 harness events contract](../analysis/2026-07-26-harness-events-contract.md).

# context

- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/trace-observability.md`
- `docs/modules/headless-contract.md`
- `docs/plan/tasks/core-context-ownership-001.md`
- `docs/plan/tasks/sdk-contract-001.md`
- `docs/plan/tasks/headless-001.md`

# path

- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- product event adapter module(s) under `packages/zag-coding-agent/src/`
- existing Core event types only if a source-fact correlation defect is proven
- `tests/sdk-consumer-fixture/`
- `docs/modules/harness-events.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/loop-turn.md`
- `docs/modules/README.md`
- `docs/plan/README.md`
- `docs/plan/tasks/harness-events-001.md`
- `docs/maturity.md` and `docs/roadmap.md` only at verified closeout
- generated quality reports

`packages/zag-agent-core/src/lifecycle.zig`, Trace/session/headless schemas, and provider stream plumbing are out of scope.

# contract

1. Coding-agent owns the public lifecycle callback union and combines two sources without duplicating execution:
   Core Loop facts plus facade run facts.
2. Event payloads are callback-borrowed, synchronous, and trusted E0-only.
3. Emit only `run_start`, complete `assistant_message`, correlated `tool_start`/`tool_end`, and `run_terminal`.
4. No fake `message_delta` or `tool_update`.
5. Core owns assistant/Tool source facts; facade owns preflight/start/session/Trace/final terminal truth.
6. Every started public lifecycle has exactly one final terminal; preflight failure before start has none.
7. Trace v1, session v1, `headless-v1`, Core `LoopEvent`, and CLI SIGINT behavior remain unchanged.
8. No internal Zig union is serialized directly into a process protocol.

# verification

1. Completed run: `run_start → assistant_message → run_terminal(completed)`.
2. Tool run: every Tool start has one end by turn/call-index/id before the next provider turn.
3. Unknown Tool, invalid arguments, permission/jail/shell deny, handler failure, and pending cancel remain correlated.
4. Provider/session/Trace/OOM/invalid-toolset/context/timeout/unsupported-control paths have one truthful post-start terminal.
5. Preflight failure emits no lifecycle start/terminal.
6. No callback follows terminal.
7. External SDK fixture copies message/Tool bytes and safely retains them after return.
8. Trace v1 and `headless-v1` parsed fixtures remain schema/terminal compatible with no duplicates.
9. Source and docs contain no emitted delta/update claim or Core `lifecycle.zig`.
10. Package tests, SDK fixture, process fixture, root std/curl suites, docs lint, and quality checks pass.

# non-goals

- provider deltas, Tool progress, steering/follow-up, session fork;
- Trace/session/headless schema changes;
- async delivery, queueing, retry, or backpressure;
- RPC, E2/E3 extensions, TUI, Graph, or subagents.

# superseded implementation

The existing `task/harness-events-001` branch (`1ffdcb7` committed baseline plus any local follow-up edits) targets a
Core `lifecycle.zig` and is not eligible for merge. Start implementation from updated main only after all dependencies
above are done.
