---
id: harness-steering-001
scope: sdk/session-control + core-control-input
status: in-progress
priority: P1
depends-on:
  - harness-events-001
---

# objective

Add bounded, truthful steering and follow-up to the in-process Zig SDK. Coding-agent Session owns two preallocated,
thread-safe enqueue queues. Core owns only a borrowed `ControlInput` seam and the protocol-safe insertion points inside
one synchronous `loop.run`.

The binding specification is [Harness steering and follow-up](../../modules/harness-steering.md). Preserve the D-011
thin-Core boundary and the one-start/one-terminal lifecycle closed by `harness-events-001`.

# context

- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/harness-steering.md`
- `docs/modules/harness-events.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/phases/C6-orchestration.md`
- `docs/plan/tasks/harness-events-001.md`

# path

- `packages/zag-agent-core/src/control_input.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/loop_event.zig`
- `packages/zag-agent-core/src/tool_error.zig`
- `packages/zag-agent-core/src/transcript.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-coding-agent/src/control_queue.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/golden_tests.zig`
- `packages/zag-coding-agent/src/lifecycle.zig`
- `packages/zag-coding-agent/src/wire_provider.zig`
- `packages/zag-coding-agent/src/root.zig`
- every repository-owned low-level `loop.Deps` composer, including Core/Agent test fixtures
- `tests/sdk-consumer-fixture/src/root.zig`
- `docs/INDEX.md`
- `docs/architecture.md`
- `docs/modules/harness-steering.md`
- `docs/modules/harness-events.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/modules/README.md`
- `docs/phases/C6-orchestration.md`
- `docs/plan/README.md`
- `docs/plan/tasks/harness-steering-001.md`
- active/closeout status in `docs/roadmap.md` and `docs/maturity.md` (no level change before verified closeout)
- generated quality reports

Trace v1, session v1, `headless-v1`, CLI SIGINT behavior, provider streaming, and Tool-handler cancellation plumbing are
out of scope.

# contract

1. **Session ownership:** steering/follow-up queues live in `zag-coding-agent.Session`. `Agent` does not retain a queue
   or cache a Session pointer across replies.
2. **Fixed bounded storage:** Session start preallocates four 4096-byte slots per kind before create/resume I/O or
   writer-lease acquisition, with errdefer cleanup on every later failure. Enqueue copies non-empty valid UTF-8 without
   allocation and returns `QueueFull`, `MessageTooLong`, `EmptyMessage`, or `InvalidUtf8` without mutation. Non-empty
   whitespace is accepted unchanged; no trim, truncation, or overwrite is allowed.
3. **Thread claim is narrow:** enqueue and pending-count reads share the queue mutex and may run on one foreign thread
   while one reply consumes. Concurrent replies, clear/deinit during active queue/reply operations, Agent re-entry, and
   signal-handler enqueue remain unsupported; clear/deinit require external idle synchronization.
4. **Explicit Core seam:** every `loop.Deps` provides `ControlInput`; low-level no-control composition selects
   `.none()` explicitly. `peek(boundary)` atomically chooses one `Item { kind, text }` under product lock (including
   steering-over-follow-up priority), and infallible `commit(kind)` removes only a matching current head. Core owns no
   queue/mutex/capacity/persistence; wrong commit is a Debug-asserted programming error.
5. **Apply transaction:** ordinary apply is append user → commit → source-backed `LoopEvent.control_applied`. Mid-batch
   apply first pre-copies text and reserves transcript capacity for all remaining Tool rows + user, then writes
   `steered` rows and appends the prepared user without allocation before commit/event. Preparation OOM occurs before
   any `steered` side effect. Sink failure after commit is visible and leaves the applied row in memory.
6. **One-at-a-time insertion:** at most one control item feeds one provider turn. Pre-turn steering, between-Tool
   steering, and would-complete steering/follow-up are the only v1 insertion points. One atomic would-complete peek gives
   steering priority over follow-up.
7. **No mid-flight preemption:** steering does not cancel Provider.chat or an entered Tool handler. Cancellation is
   rechecked before **every** apply boundary, including would-complete; when observed it wins and consumes no item.
8. **Protocol legality:** before mid-batch steering inserts a user row, every remaining accepted/not-started Tool gets
   one end-only result with the original id/name and stable body
   `error: code=steered message=steering selected; pending tool did not execute.`; no synthetic `tool_start`. Real
   cancellation keeps `code=cancelled`.
9. **Turn budget:** control never extends `max_turns`. If no provider turn remains, no message is consumed; pending
   control yields/retains `max_turns` rather than appending an unanswered user row.
10. **Retention:** unapplied items survive every run terminal, including cancel/error/max-turn. Only successful commit,
    explicit idle clear, or Session deinit removes them. Pending queues are process-only and are not serialized.
11. **Run truth:** all injected turns remain inside one `Agent.reply`, one lifecycle `run_start`, one Trace run, one
    Session save boundary, and one final `run_terminal`; usage/turns accumulate and final text is the last assistant.
12. **Observation:** Core extends the existing `LoopEvent` source union; coding-agent projects borrowed
    `LifecycleEvent.control_applied { kind, next_turn, text }`, where `next_turn = turns + 1` after proving another turn
    is available. Product fan-out is lifecycle-only. Observer, Trace v1 twelve-kind schema, `headless-v1`, and CLI output
    remain unchanged.
13. **Safety defaults:** injected messages are ordinary user input. Any model-requested Tool still passes
    `ToolPolicy → Jail → ShellPolicy → execution`; no control path selects yolo or bypasses product defaults.
14. **No maturity inflation:** this task enriches the existing SDK/Loop surface. It does not upgrade Phase H, claim TUI
    or RPC readiness, or implement Graph/subagents/parallel Tools.

# verification

## Core fixtures

1. `.control_input = .none()` preserves completed, Tool, cancel, timeout, unsupported-control, and error behavior.
2. Pre-turn steering appends one user row before the next `turn_start`; one-at-a-time prevents a second control item
   from feeding the same provider turn; lifecycle reports `next_turn = turns + 1`.
3. Provider returns two Tools; steering before Tool 2 prepares text/capacity before side effects, then yields Tool 1
   start/end, Tool 2 end-only exact `code=steered` body, one infallibly appended prepared user, and the next provider
   turn. The projected view remains protocol legal.
4. One atomic would-complete peek gives steering priority over follow-up under concurrent enqueue; follow-up alone
   continues the same run. Both retain per-kind FIFO order.
5. Cancel observed before pre-turn, between-Tool, or would-complete apply emits no control event and leaves queue state
   uncommitted.
6. Ordinary append OOM does not commit. Mid-batch preparation OOM occurs before any `steered` result; injected hard
   failure during backfill has the documented partial-evidence/hidden-prepared-row behavior. Source-sink failure after
   commit returns the existing visible sink/trace error mapping without requeue.
7. Last-turn pending control is not appended and produces `max_turns`; last-turn Tools finish normally and pending-count
   APIs still expose retained work.
8. Existing accepted multi-Tool cancel fixtures still use end-only `code=cancelled`, never `steered`.

## Coding-agent and SDK fixtures

9. Capacity, max bytes, zero-length/whitespace/UTF-8, FIFO, mutex-protected pending counts, idle clear, and
   Session-start preallocation OOM-before-create/resume/writer are deterministic; every later start failure frees queue
   storage and writer lease.
10. Session A queue cannot be consumed by Session B. A Session move while idle remains valid; active operations require
    stable address.
11. A barrier-based foreign thread enqueue/pending read during `reply` is observed at the next eligible boundary without
    allocation races or deadlock; clear/deinit are exercised only after reply/enqueue quiesce.
12. Cancel/provider/Trace/session/OOM/max-turn terminals retain unapplied items; a later reply on the same Session can
    consume them. Explicit clear/deinit drops them.
13. Applied steering/follow-up user rows save/resume with existing redaction and atomicity; pending slots never appear
    in session v1 bytes.
14. Lifecycle ordering includes borrowed `control_applied` and still exactly one terminal. Mid-batch steered Tool ends
    preserve turn/call-index/id correlation. No callback follows terminal.
15. Trace has no new kind but records subsequent turns and `tool_result(code=steered)` where applicable; parsed Trace v1
    and `headless-v1` fixtures remain compatible.
16. External SDK fixture imports only package roots, exercises Session enqueue/copy ownership, and selects
    `ControlInput.none()` in low-level composition.
17. Default ask-deny write, yolo escaping-symlink jail, and shell-protect fixtures remain green after injected messages.
18. Core, coding-agent, CLI/process, SDK fixture, root std/curl, docs lint, and quality checks pass.

# non-goals

- full/all drain mode, dynamic queue capacity, or messages larger than 4096 bytes;
- provider-stream deltas, Provider cancellation on steer, or running Tool interruption;
- durable pending queues, cross-process replay, RPC input, ACP, or TUI implementation;
- Trace/session/headless schema version changes;
- Core queue storage/mutex/policy/persistence or a separate Core lifecycle observer;
- Agent-owned cross-Session control state;
- Graph, Oracle, executable subagents, background jobs, or parallel Tool scheduling.
