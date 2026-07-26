---
status: re-queued
scope: in-process Zig SDK lifecycle events
prerequisite: core-context-ownership-001
---

# Harness lifecycle events

This module records the post-D-011 target for trusted in-process Zig consumers. It supersedes the proposed core
`lifecycle.zig`/separate `LifecycleObserver` design. Implementation is blocked until the thin-Core migration is complete.

## Boundary

```text
Provider / Tool runtime
        │
        ▼
Core Loop source facts ──► required fallible LoopEventSink
                                   │
                                   ▼
                        coding-agent event fan-out
                          ├─ durable Trace adapter
                          ├─ best-effort verbose adapter
                          └─ SDK lifecycle adapter

coding-agent facade facts ─────────┘
  preflight · run start · session save · final terminal

CLI maps product facts to headless-v1; it never serializes a Zig union directly.
```

The public SDK lifecycle is a **coding-agent adapter** over two truthful owners:

- Core owns complete assistant/Tool/turn facts witnessed during `loop.run`;
- the coding-agent facade owns run preflight, start, persistence, and terminal truth.

No third Core event channel is added.

## Planned public vocabulary

Exact Zig type names are selected by `harness-events-001` after the ownership migration. The minimum source-backed
vocabulary remains:

| Event | Owner | Required payload | Source fact |
|---|---|---|---|
| `run_start` | Coding-agent facade | session configured flag | run preflight and durable-start preparation succeeded |
| `assistant_message` | Core Loop fact mapped by coding-agent | turn, complete text, has-tools | validated complete `AssistantTurn` appended |
| `tool_start` | Core Loop fact mapped by coding-agent | turn, call index, id, name, arguments | accepted Tool call selected for serial execution |
| `tool_end` | Core Loop fact mapped by coding-agent | same correlation plus final body | one result exists, including deny/error/cancel bodies |
| `run_terminal` | Coding-agent facade | turns, truthful `ok`, stop reason, cumulative usage | session/Trace precedence and final public outcome are known |

`run_start` and `run_terminal` are not variants of Core `LoopEvent`. The SDK adapter may expose them in one product
callback union because coding-agent witnesses both facade and loop facts.

## Ordering

For every public `run_start`:

```text
run_start
  → zero or more assistant_message
  → for each accepted Tool call: tool_start → tool_end
  → exactly one run_terminal
```

Required invariants:

1. A preflight failure before `run_start` produces no started-run terminal.
2. `assistant_message` is emitted only after a complete validated assistant turn is appended.
3. Every `tool_start` has one matching `tool_end` with identical turn, call index, and call id.
4. Pending accepted calls backfilled with `code=cancelled` receive truthful `tool_end`.
5. `run_terminal` is final and emitted exactly once by coding-agent after session/Trace outcome precedence is known.
6. Trace failure cannot preserve an earlier successful lifecycle claim.
7. Callback order is synchronous program order; no queue/reordering is introduced.

## Ownership and callback behavior

- Payload slices are borrowed and valid only during the callback. Consumers copy retained data.
- The callback is synchronous and observation-only; it cannot replace execution truth.
- Re-entering the same `Agent` from its callback is unsupported.
- Raw model text, Tool arguments, and Tool bodies are visible only to trusted E0 consumers.
- Future E2/E3/RPC mappings require separate redaction/capability/wire contracts.

## Source-backed scope

The first product adapter does not emit `message_delta` or `tool_update`:

- provider content deltas are not yet Core Loop facts;
- synchronous Tool handlers have no progress callback;
- empty or post-hoc fabricated phases are forbidden.

A later source-owning task may add real streaming/progress with explicit ownership, cancellation, and compatibility.

## Separation from durable/public schemas

### Trace v1

Trace remains the durable audit contract and coding-agent terminal owner. The lifecycle adapter does not change Trace
schema, persistence, redaction, terminal reserve, or failure precedence.

### `headless-v1`

`headless-v1` remains independently versioned and output-only. CLI owns its envelopes and exactly-one process terminal.
It maps product facts; it does not dump Core `LoopEvent` or the in-process SDK union.

### Core source events

Core `LoopEvent` may include additional internal facts required by Trace or safety auditing. The public SDK lifecycle is
a deliberate projection, not an alias or serialized representation of that internal union.

## Failure modes

| Failure | Required behavior |
|---|---|
| run preflight fails before start | no public lifecycle events required |
| loop/provider/session failure after start | one failed `run_terminal` |
| Trace terminal commit fails | terminal reason becomes `trace_error` |
| callback blocks | synchronous Agent blocks; documented host responsibility |
| callback panics | host process failure; no false-success recovery |
| consumer retains borrowed bytes | consumer bug; copy requirement is explicit |

## Acceptance

- deterministic completed, Tool, cancel, provider/session/Trace/OOM/invalid-context terminal sequences;
- matching Tool correlation across normal, unknown, invalid arguments, permission/jail/shell deny, handler failure, and
  pending cancellation;
- external SDK consumer copies borrowed bytes and retains them after callback return;
- existing Core `LoopEventSink`, Trace v1, session v1, `headless-v1`, std/curl, and CLI SIGINT Gates remain green;
- no `packages/zag-agent-core/src/lifecycle.zig`, fake delta/update, steering, RPC, TUI, or extension claim.

## Delivery status

`harness-events-001` is `pending` behind:

```text
core-boundary-001
  → core-seams-001
  → core-session-ownership-001
  → core-observation-ownership-001
  → core-policy-ownership-001
  → core-context-ownership-001
  → harness-events-001
```

The existing `task/harness-events-001` implementation branch is not a merge candidate because it implements the
superseded Core lifecycle boundary.

## Related

- [Thin Core boundary](./core-boundary.md)
- [SDK contract](./sdk-contract.md)
- [Loop/turn](./loop-turn.md)
- [Trace observability](./trace-observability.md)
- [Headless contract](./headless-contract.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
- [Thin-Core analysis](../plan/analysis/2026-07-26-thin-core-boundary.md)
