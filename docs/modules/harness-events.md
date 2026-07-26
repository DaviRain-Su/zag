---
status: proposed
scope: in-process Zig SDK lifecycle events
---

# Harness lifecycle events

This module defines the proposed `lifecycle-v1` vocabulary for trusted in-process Zig consumers. It closes the gap
between the low-level loop `Observer`, durable Trace events, and future UI/control consumers without merging those
surfaces or changing `headless-v1`.

## Boundary

```text
Provider / Tool runtime
        │
        ▼
Loop source facts ──► LifecycleObserver (borrowed, synchronous, in-process)
        │
        ├────────────► existing Observer (verbose + current headless mapping)
        └────────────► Trace v1 (durable audit)

CLI owns headless-v1 envelopes; it maps source facts and never serializes a Zig union.
```

`lifecycle-v1` is:

- an E0 trusted-static Zig SDK contract;
- synchronous and callback-based;
- allocation-free at emission time;
- source-backed: every emitted phase corresponds to state the harness already owns;
- not a process protocol, extension protocol, trace schema, or TUI implementation.

## Event vocabulary

```zig
pub const Event = union(enum) {
    run_start: RunStart,
    assistant_message: AssistantMessage,
    tool_start: ToolStart,
    tool_end: ToolEnd,
    run_terminal: RunTerminal,
};
```

| Event | Owner | Required payload | Source fact |
|-------|-------|------------------|-------------|
| `run_start` | Agent facade | session configured flag | run preflight and trace start succeeded |
| `assistant_message` | Loop | turn, complete text, has-tools | validated `AssistantTurn` appended |
| `tool_start` | Loop | turn, call index, id, name, arguments | accepted Tool call selected for serial execution |
| `tool_end` | Loop | turn, call index, id, name, body | result body exists, including soft deny/error/cancel bodies |
| `run_terminal` | Agent facade | turns, ok, controlled stop reason, cumulative usage | final Result/ReplyError truth is known |

`run_terminal.stop_reason` uses a lifecycle-owned controlled enum. `loop.zig` imports the lifecycle module and
re-exports that same type as `loop.StopReason`; the lifecycle module imports only `message.zig`, never `loop.zig`.
This keeps one in-memory stop enum and avoids a fourth hand-maintained mapping. The Agent facade retains an exhaustive
mapping from that enum to Trace's independently versioned controlled terminal values.

## Ordering

For every emitted `run_start`:

```text
run_start
  → zero or more assistant_message
  → for each accepted Tool call: tool_start → zero or more permission events elsewhere → tool_end
  → exactly one run_terminal
```

Invariants:

1. `run_start` is emitted only after fallible run preflight succeeds. A failure before it is not a started lifecycle run.
2. `assistant_message` is emitted only after a complete validated assistant turn is appended to the transcript. It
   carries no duplicate Tool-call list; consumers correlate subsequent `tool_start` events by turn and program order.
3. Every emitted `tool_start` has exactly one matching `tool_end` with the same turn, call index, and call id. The Loop
   passes its existing `turns` and `call_index` values through Tool execution/finish helpers; correlation is not guessed.
4. Pending accepted calls filled with `code=cancelled` still receive truthful `tool_end` events.
5. `run_terminal` is the final lifecycle event and is emitted exactly once for every lifecycle-started run.
6. A trace/session persistence error produces a failed lifecycle terminal; it cannot preserve an earlier success claim.
7. Callback order is program order. Zag does not queue or reorder lifecycle events in M1.

## Ownership and callback behavior

- Payload slices are borrowed and valid only during the callback. Consumers copy what they retain.
- The callback returns `void`; it cannot alter control flow or replace Tool/run truth.
- The callback runs synchronously and may delay the harness. M1 adds no queue, thread, retry, or backpressure mechanism.
- Re-entering the same `Agent` from its callback is unsupported.
- A callback panic is a host failure; Zag does not catch or convert it into a successful terminal.
- Raw model text, Tool arguments, and Tool bodies are visible only to this trusted E0 consumer. Future E2/E3/RPC mappings
  require explicit redaction/capability contracts and do not inherit this access.

## Source-backed scope

M1 deliberately does not emit `message_delta` or `tool_update`:

- provider `StreamEvent.content_delta` exists below the Loop but is not currently a Loop-owned lifecycle source;
- Tool handlers are synchronous and have no progress callback or update channel;
- emitting empty, fabricated, or post-hoc "delta/update" events would overstate capability.

A later streaming/progress task may add a new lifecycle version or an explicitly compatible extension after it owns a
real source, cancellation semantics, ordering, and tests. `assistant_message` is a complete message, not a disguised
delta.

## Separation from existing surfaces

### Existing `Observer`

The current low-level `Observer.Event` remains unchanged in `harness-events-001`. It continues to drive verbose logging
and the existing headless event bridge. `LifecycleObserver` is a separate supported SDK field so adding lifecycle
variants does not silently break existing exhaustive switches or duplicate headless terminals. Existing Observer
Tool events and lifecycle Tool events are two projections of the same Loop source decision, not independent execution
or terminal decisions.

### Trace v1

Trace remains the durable audit contract. Lifecycle events do not change Trace schema, persistence, redaction, sequence,
or terminal-reserve behavior. `run_terminal` inherits the Agent facade's final outcome after Trace commit/fallback
precedence; it is not a second truth source. If Trace cannot persist a terminal, the in-process lifecycle still emits
one failed `trace_error` terminal and never preserves an earlier success claim.

### `headless-v1`

`headless-v1` remains output-only and independently versioned. The CLI continues to own `run_start`, `run_end`, and
`error` envelopes. It may map source facts to public JSON, but it never serializes `lifecycle.Event` directly and must
not emit duplicate terminals because a lifecycle observer exists.

### Future control and extensions

`harness-steering-001`, session fork, TUI, `rpc-v1`, and `zag-ext-v1` may consume or map this vocabulary only through
their own Gates. Lifecycle observation grants no mutation, denial, Tool registration, filesystem, terminal, or session
capability.

## Failure modes

| Failure | Required behavior |
|---------|-------------------|
| run preflight fails before `run_start` | no lifecycle events required |
| loop/provider/session failure after start | one failed `run_terminal` |
| trace terminal commit fails | terminal reason becomes `trace_error` |
| callback blocks | harness blocks; documented E0 host responsibility |
| callback panics | host process failure; no false success recovery |
| consumer retains borrowed bytes | consumer bug; copy requirement is explicit |

## Acceptance

- deterministic golden sequences for completed, Tool, cancelled, provider-error, session-error, trace-error, and OOM
  paths;
- matching Tool start/end ids across normal, denied, invalid-argument, jail/shell deny, and pending-cancel results;
- external SDK consumer installs `LifecycleObserver`, observes a completed Tool run, copies borrowed message/Tool data,
  and safely retains those copies after callback return;
- deterministic golden sequences live with the lifecycle module tests and cover every accepted terminal family;
- existing low-level Observer, Trace v1, `headless-v1`, std/curl, and CLI SIGINT Gates remain unchanged;
- no `message_delta`, `tool_update`, steering, hook, RPC, TUI, or runtime-extension claim.

## Non-goals

- provider stream plumbing or token-level rendering;
- Tool progress/update callbacks;
- steering/follow-up queues or deny hooks;
- session fork;
- Trace or `headless-v1` schema changes;
- RPC, E2/E3 extension transport, TUI, Graph, or subagents;
- asynchronous delivery, backpressure, or multi-run correlation.

## Related

- [SDK contract](./sdk-contract.md) — its Event section is updated when `harness-events-001` is implemented
- [Loop/turn](./loop-turn.md)
- [Trace observability](./trace-observability.md)
- [Headless contract](./headless-contract.md)
- [D-009: Pi semantics, not parity](../decisions/active/D-009-pi-semantics-not-parity-fork.md)
- [D-010: extension tiers](../decisions/active/D-010-extension-tiers-and-process-protocol.md)
- [Harness events analysis](../plan/analysis/2026-07-26-harness-events-contract.md)
