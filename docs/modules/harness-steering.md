---
status: in-progress
scope: in-process bounded steering and follow-up
prerequisite: harness-events-001
task: harness-steering-001
---

# Harness steering and follow-up

This module is the binding contract for `harness-steering-001`. It adds the smallest useful interactive-control
semantics after the lifecycle adapter: a host may queue a steering message for the next safe model/Tool boundary or a
follow-up message for the next would-complete boundary. The implementation is Zig-native and synchronous; it does not
copy Pi's Agent object or introduce a background runtime.

## Boundary

```text
host / UI thread
  │
  │ Session.enqueueSteering / enqueueFollowUp
  ▼
zag-coding-agent Session
  · owns two bounded, preallocated queues
  · owns message bytes, capacity, mutex, retention, clear/deinit
  · does not persist pending queue slots
          │
          │ borrowed ControlInput (peek → append → commit)
          ▼
zag-agent-core loop
  · polls only at documented safe boundaries
  · appends accepted control as a normal user transcript row
  · closes accepted Tool bundles before inserting user input
  · emits one existing LoopEventSink source fact when control is applied
          │
          ▼
RunBridge
  ├─ public LifecycleEvent.control_applied
  ├─ existing Tool/assistant lifecycle projection
  └─ existing Trace/session/terminal adapters
```

Core owns the insertion point and protocol-history legality because only the loop witnesses open accepted Tool calls.
Coding-agent owns the concrete queue because capacity, threading, retention, Session association, and public control API
are product concerns. Core must not own a ring buffer, mutex, durable control state, permission policy, or a separate
lifecycle channel.

## Product API and ownership

Control messages belong to the `Session`, not the `Agent`:

```zig
pub const control_queue_capacity: usize = 4;
pub const control_message_max_bytes: usize = 4096;

pub const ControlError = error{
    QueueFull,
    MessageTooLong,
    EmptyMessage,
    InvalidUtf8,
};

pub fn enqueueSteering(self: *Session, text: []const u8) ControlError!void;
pub fn enqueueFollowUp(self: *Session, text: []const u8) ControlError!void;
pub fn steeringPending(self: *const Session) usize;
pub fn followUpPending(self: *const Session) usize;
pub fn clearControlQueues(self: *Session) void;
```

`Agent.reply` accepts an arbitrary `*Session`; an Agent-owned queue could therefore inject a message into the wrong
conversation. A Session-owned queue follows the transcript it will modify and cannot bleed from Session A into Session
B.

### Queue storage

Each Session preallocates four 4096-byte slots for steering and four for follow-up: **32 KiB total text backing**.
Allocation happens in `Session.start` before any durable session create/write. A preallocation OOM fails start without
creating a new session file. Enqueue performs no allocation and therefore has no enqueue-path `OutOfMemory`.

- Input is copied; caller bytes may be released after enqueue returns.
- Empty input and invalid UTF-8 are rejected.
- More than 4096 bytes returns `MessageTooLong`; no truncation occurs.
- The fifth pending item of one kind returns `QueueFull`; FIFO state is unchanged.
- Steering and follow-up have independent capacity and FIFO order.
- v1 delivery is **one-at-a-time**: at most one queued item is applied before one provider turn.

### Threading and movement

Only queue methods are thread-safe. One thread may call `enqueueSteering` / `enqueueFollowUp` while another thread is
inside one `Agent.reply` for the same Session. `Agent.reply` itself remains single-flight; concurrent replies using the
same Agent or Session are unsupported. Queue methods are not async-signal-safe; SIGINT continues to touch only
`CancelFlag`.

A Session may be moved while idle, but its address must remain stable while `reply` or any queue operation is in flight.
`clearControlQueues` and `Session.deinit` require no concurrent reply/enqueue. Lifecycle callbacks may enqueue for the
same Session, but may not re-enter `reply`, clear, deinit, or otherwise mutate the running Agent/Session.

## Core `ControlInput` seam

Core adds a thin, borrowed `ptr + vtable` contract. It is a required `loop.Deps` composition field, but it is not a
safety policy and owns no queue:

```zig
pub const Kind = enum { steering, follow_up };

pub const ControlInput = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub fn peek(self: ControlInput, kind: Kind) ?[]const u8;
    pub fn commit(self: ControlInput, kind: Kind) void;
    pub fn none() ControlInput;
};
```

`peek` is non-destructive. Its borrowed head slice remains immutable until the single loop consumer calls `commit`.
Core first copies the bytes into the authoritative Transcript; only a successful append permits `commit`. This prevents
append OOM from silently consuming a queued message. `commit` is infallible and removes exactly the item previously
peeked for that kind.

Low-level composers must write `.control_input = .none()` when no control source exists. Product `Agent.reply` always
installs an adapter bound to the exact `*Session` argument of that call; Agent must not cache a Session pointer across
replies.

## Application state machine

The loop checks cancellation before each control boundary. Cancellation observed before application wins and leaves all
unapplied queue entries pending. Steering never cancels an in-flight Provider request or a running Tool handler.

```text
outer loop while another provider turn is available
  cancel? → cancelled terminal path; queues unchanged

  pre-turn boundary
    unless the previous boundary already injected one item for this turn:
      peek one steering → append user → commit → control_applied

  turn_start → ContextView → Provider.chat → append complete assistant

  assistant has no Tool calls (would complete)
    if another provider turn is available:
      first steering, else follow-up
      append one user → commit → control_applied → continue outer loop
    else if steering/follow-up remains:
      return max_turns without consuming it
    else:
      return completed

  assistant has accepted Tool calls
    before each not-yet-started Tool, if another provider turn is available:
      cancel? → existing cancelled backfill + cancelled result
      steering pending?
        finish every remaining accepted call with end-only code=steered
        append one steering user → commit → control_applied
        continue outer loop
      otherwise execute the Tool normally

  after a normal Tool batch
    return to the outer pre-turn boundary
```

A boundary that injects steering/follow-up suppresses the immediately following pre-turn poll. This is the v1
one-at-a-time rule: one control message, then one provider turn. At a would-complete boundary, steering has priority over
follow-up; remaining items keep FIFO order for later turns.

### Max-turn behavior

Control does not increase `Options.max_turns`. The loop never consumes a message if no provider turn remains to answer
it. Pending control at the last would-complete boundary changes the result to `max_turns`; the message remains queued.
At the last turn's Tool boundary, the loop finishes the Tool batch normally and leaves steering queued rather than
appending an unanswered user message.

## Tool protocol legality

Steering may interrupt only calls that have not entered serial execution. Before appending its user row, Core closes the
assistant Tool bundle in call-list order:

```text
already executed call       tool_start → tool_end
remaining accepted call                  tool_end(code=steered)
steering input                           user
next model turn                         assistant ...
```

`tool_error.Code.steered` is distinct from `cancelled`. A steering interruption continues the run; a cancellation ends
it. Reusing `cancelled` would make machine-readable transcript/Trace evidence lie about the terminal condition.

End-only `steered` results carry the original call id/name and advance lifecycle call indexes exactly like end-only
cancelled results. No synthetic `tool_start` is emitted. A hard failure after a real `tool_start` but before a result
still does not fabricate `tool_end`.

## Apply transaction and source fact

One item is applied in this order:

```text
peek borrowed queue head
  → Transcript.appendUser (owned Session arena copy)
  → commit queue head
  → LoopEvent.control_applied { kind, next_turn, text=transcript-owned bytes }
```

If append returns OOM, no commit/event occurs and the message remains queued. If the fallible event sink fails after
append+commit, the run fails visibly; the authoritative in-memory transcript already contains the applied message and
it is not queued twice.

Core `LoopEvent.control_applied` is an existing-channel source fact, not a product run terminal or third Core lifecycle
observer. Coding-agent projects it to:

```zig
LifecycleEvent.control_applied: struct {
    kind: ControlKind,
    next_turn: u32,
    text: []const u8,
}
```

The payload is synchronous and borrowed. `next_turn` is the provider-turn number the control is intended to feed. The
event may still be followed by cancellation or another hard terminal before an assistant message; it records
application, not guaranteed model completion.

## Terminal, retention, and persistence

A queued item is removed only by successful apply/commit, explicit idle `clearControlQueues`, or `Session.deinit`.
`cancelled`, `timeout`, `unsupported_control`, `provider_error`, `out_of_memory`, `trace_error`, `session_error`, and
`max_turns` do **not** clear unapplied entries. The next `reply` on that same Session may apply them. The new reply's
explicit `user_text` is appended before any retained steering is polled.

Pending queue slots are process-memory state and are **not serialized** in session v1. Restart/resume starts with empty
queues. Once applied, the normal user transcript row is persisted by the existing redacted, atomic Session save path.
A save failure leaves the applied row in the in-memory transcript and returns `session_error`; it does not resurrect the
already committed queue item.

One `Agent.reply` still owns exactly one public `run_start` and one final `run_terminal`, regardless of how many control
messages extend the loop. Turns and usage accumulate normally; `final_text` is the final assistant text.

## Trace, Observer, headless, and CLI compatibility

- Trace schema v1 keeps its twelve event kinds. It records resulting turns and `tool_result(code=steered)` where
  applicable, but not a new control-text kind. Session/transcript and trusted lifecycle are the full-text evidence.
- `Observer.Event` is unchanged.
- `headless-v1` is unchanged and has no bidirectional control input. A one-shot invocation with empty queues is byte- and
  terminal-compatible with the existing path.
- CLI SIGINT remains cancellation only; it never enqueues steering.
- `control_applied` is trusted in-process E0 data and is not serialized directly into Trace/headless/RPC.

## Failure modes

| Failure | Required behavior |
|---|---|
| Session control preallocation OOM | `Session.start` fails before durable create/write |
| invalid/empty/oversized enqueue | typed error; no queue mutation |
| queue full | `QueueFull`; no overwrite/drop |
| transcript append OOM | no commit/event; item remains pending; truthful OOM terminal |
| source sink failure after commit | applied row stays in memory; item remains consumed; truthful terminal |
| cancel observed before boundary | no apply; pending entries remain |
| max turns leaves no answer turn | no apply; `max_turns`; pending entries remain |
| explicit clear/deinit | pending process-memory items are discarded by explicit host action |
| concurrent reply/clear/deinit | unsupported host misuse; no thread-safety claim |

## Acceptance

1. `ControlInput.none()` preserves existing Core behavior; every low-level composer selects it explicitly.
2. Session A's queue is never consumed by `reply` on Session B.
3. Pre-turn steering is appended after the current reply's explicit user text and before turn 1.
4. Steering queued during Provider execution applies only after the complete turn, at would-complete or before the next
   not-yet-started Tool; it never aborts the in-flight request.
5. Mid-batch steering produces normal start/end for executed calls and end-only `code=steered` for all remaining calls,
   then one user row and a new model turn.
6. Follow-up applies only at would-complete and stays in the same run with one terminal.
7. One-at-a-time FIFO, steering-before-follow-up, max-turn retention, cancel retention, and explicit clear are fixture
   pinned.
8. Enqueue from another thread while one reply runs is race-free, allocation-free, bounded, and deterministic.
9. Session save/resume contains applied redacted user rows but never pending queue slots.
10. Lifecycle exposes borrowed source-backed `control_applied`; Trace v1, Observer, session v1, headless-v1, and CLI
    SIGINT schemas/behavior remain compatible.
11. Existing ask + workspace jail + shell protect Gates still govern any Tool calls caused by injected messages.
12. Core/coding/SDK fixtures and root std/curl suites pass; no Core queue, mutex, persistence, or lifecycle terminal is
    introduced.

## Non-goals

- full/all drain mode or configurable queue sizes in v1;
- provider or Tool-handler mid-flight preemption;
- durable pending control queues or restart replay;
- Trace/headless schema changes, RPC input, or TUI implementation;
- Graph, subagents, Oracle, background jobs, or parallel Tools;
- Core-owned queue/policy/persistence, Agent-owned cross-Session queue, or hidden missing-to-none fallback;
- using lifecycle callback re-entry as a nested Agent run.

## Related

- [Loop/turn](./loop-turn.md)
- [Harness lifecycle events](./harness-events.md)
- [Thin Core boundary](./core-boundary.md)
- [SDK contract](./sdk-contract.md)
- [Session store](./session-store.md)
- [C6 interactive control](../phases/C6-orchestration.md)
- [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
