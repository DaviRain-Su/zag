---
status: done
scope: in-process Zig SDK lifecycle events
prerequisite: core-context-ownership-001
closed-at: aecf402
---

# Harness lifecycle events

This module records the closed post-D-011 contract for trusted in-process Zig consumers. `harness-events-001` closed
at `aecf402`: `zag-coding-agent` owns the public `LifecycleObserver` + `LifecycleEvent` union over Core `LoopEvent`
source facts and facade run facts. The product adapter supersedes the proposed Core `lifecycle.zig`/separate
`LifecycleObserver` design; no Core `lifecycle.zig` exists. The vocabulary is source-backed only, with no emitted
`message_delta` or `tool_update`.

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

## Public vocabulary

Exact Zig type names are defined by `harness-events-001` in `packages/zag-coding-agent/src/lifecycle.zig`. The
source-backed vocabulary is:

| Event | Owner | Required payload | Source fact |
|---|---|---|---|
| `run_start` | Coding-agent facade | session configured flag | run preflight and durable-start preparation succeeded |
| `assistant_message` | Core Loop fact mapped by coding-agent | turn, complete text, has-tools | validated complete `AssistantTurn` appended |
| `tool_start` | Core Loop fact mapped by coding-agent | turn, call index, id, name, arguments | accepted Tool call selected for serial execution |
| `tool_end` | Core Loop fact mapped by coding-agent | same correlation plus final body | one result exists, including deny/error/cancel bodies |
| `run_terminal` | Coding-agent facade | turns, truthful `ok`, stop reason, cumulative usage | session/Trace precedence and final public outcome are known |

`run_start` and `run_terminal` are not variants of Core `LoopEvent`. The SDK adapter exposes them in one product
callback union because coding-agent witnesses both facade and loop facts.

### Steering extension (`harness-steering-001`, closed at `a5ff2b7`)

The steering task added one source-backed product variant without changing run ownership:

| Event | Owner | Required payload | Source fact |
|---|---|---|---|
| `control_applied` | Core append/commit fact mapped by coding-agent | kind (`steering` / `follow_up`), intended next turn, borrowed text | one queued item was copied into Transcript and committed |

`control_applied` records accepted application, not enqueue and not guaranteed model completion. Its
`next_turn = turns + 1` after Core proves another turn is available. It may be followed by cancellation or another hard
terminal before the intended next assistant message. The event is trusted E0-only and is not serialized into Trace v1
or `headless-v1`.

### Source-truth: start vs end-only

A Tool call that **enters serial execution** emits `tool_start` then `tool_end` (ordinary, soft-result, deny, jail,
shell, handler-failure, invalid-arguments, unknown-tool paths). A **pending accepted** Tool call that is cancelled
**between tools** never enters serial execution: it emits `tool_end` only with a `cancelled` body — **no fabricated
`tool_start`**. The call index is still derived from program order (the index the call would have occupied), so
consumers can correlate by turn + call index + id without a synthetic start.

A pending accepted Tool call skipped because steering interrupts the remaining batch follows the same end-only shape but
uses the stable body `error: code=steered message=steering selected; pending tool did not execute.`, not `cancelled`. The run continues after one steering user row; correlation still advances
in program order and no synthetic `tool_start` is emitted.

A hard failure (OOM / sink failure) that occurs **after** `tool_start` but **before** any result exists does **not**
fabricate a `tool_end`: the run terminates with a truthful `run_terminal` (out_of_memory / trace_error) and the
started Tool call has no end event. Consumers must not assume every `tool_start` has a matching `tool_end` when a
hard failure stops the run mid-call.

## Ordering

For every public `run_start`:

```text
run_start
  → zero or more complete assistant_message
  → zero or more source-backed Tool/control facts:
      entered call              tool_start → tool_end
      pending cancellation                  tool_end(code=cancelled) only
      pending steering                      tool_end(code=steered) only
      applied control                       control_applied
      hard mid-call failure     tool_start only
  → exactly one run_terminal
```

Required invariants:

1. A preflight failure before `run_start` produces no started-run terminal.
2. `assistant_message` is emitted only after a complete validated assistant turn is appended.
3. Every `tool_start` that is **not** interrupted by a hard failure has one matching `tool_end` with identical turn, call index, and call id.
4. Pending accepted calls interrupted by cancel/steering receive truthful end-only `code=cancelled`/`code=steered` respectively, with no fabricated `tool_start`; call index remains program order.
5. `control_applied` follows successful Transcript append + queue commit and carries transcript-owned borrowed bytes; it does not promise the next provider turn completes.
6. A hard failure (OOM / sink failure) after `tool_start` and before a result does not fabricate `tool_end`; the run ends with a truthful `run_terminal`.
7. `run_terminal` is final and emitted exactly once by coding-agent after session/Trace outcome precedence is known.
8. Trace failure cannot preserve an earlier successful lifecycle claim.
9. Callback order is synchronous program order; no asynchronous delivery/reordering is introduced.

## Ownership and callback behavior

- Payload slices are borrowed and valid only during the callback. Consumers copy retained data.
- The callback is synchronous and observation-only; it cannot replace execution truth.
- Re-entering `Agent.reply`, clearing/deinitializing the Session, or otherwise nesting the same Agent from its callback is unsupported. Queue-only enqueue/pending methods may be used for the same stable Session; application waits for the next eligible boundary.
- Raw model text, Tool arguments, and Tool bodies are visible only to trusted E0 consumers.
- Future E2/E3/RPC mappings require separate redaction/capability/wire contracts.

### Public terminal vs `OwnedResult` presentation

The public lifecycle `run_terminal` describes **`Agent.reply` run truth** only: it is emitted exactly once for
every started run after session/Trace outcome precedence is known. Higher-level helpers such as
`Agent.completeWithSession` may then allocate an owned presentation copy of `Result.final_text` into
`OwnedResult`. That post-terminal allocation is caller-side presentation only: it may return
`error.OutOfMemory` after a successful lifecycle terminal has already been emitted, and it never
rewrites, retracts, or fabricates a second public lifecycle terminal.

## Source-backed scope

The first product adapter does not emit `message_delta` or `tool_update`:

- provider content deltas are not yet Core Loop facts;
- synchronous Tool handlers have no progress callback;
- empty or post-hoc fabricated phases are forbidden.

A later source-owning task may add real streaming/progress with explicit ownership, cancellation, and compatibility.

## Separation from durable/public schemas

### Trace v1

Trace remains the durable audit contract and coding-agent terminal owner. The lifecycle adapter does not change Trace
schema, persistence, redaction, terminal reserve, or failure precedence. The closed `harness-steering-001` surface keeps the Trace v1
twelve-kind schema: resulting turns and `tool_result(code=steered)` are durable, while trusted lifecycle/Session carry
the applied control text.

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
- no `packages/zag-agent-core/src/lifecycle.zig`, fake delta/update, Core-owned product queue, provider/Tool preemption, RPC, TUI, or extension claim.

## Delivery status

`harness-events-001` is **done** at `aecf402`. Independent re-review passed after the no-Trace turn-truth fix, and the
ff-only merged-main Gate passed root std **530/530**, root curl **529/529**, Core **70/70**, Coding **282/282**, and
external SDK fixture **18/18**.

```text
core-boundary-001
  → core-seams-001
  → core-session-ownership-001
  → core-observation-ownership-001
  → core-policy-ownership-001
  → core-context-ownership-001
  → harness-events-001 ✓ done @ aecf402
```

The historical `task/harness-events-001` branch remains ineligible because it implements the superseded Core lifecycle
boundary. Its replacement `task/harness-events-001-v2` was fast-forwarded and supplies the product adapter over Core
source facts and facade run facts. The separate [steering contract](./harness-steering.md) closed at `a5ff2b7`; its
merged-main Gate passed std **567/567**, curl **566/566**, Core **89/89**, Coding **298/298**, and SDK **20/20** while
preserving the historical lifecycle Gate above and every maturity row. The separate
[session-fork contract](./session-fork.md) closed at `0a3087f` with SDK fixture **21/21**, also without changing a
maturity row.

## Related

- [Thin Core boundary](./core-boundary.md)
- [SDK contract](./sdk-contract.md)
- [Loop/turn](./loop-turn.md)
- [Trace observability](./trace-observability.md)
- [Headless contract](./headless-contract.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
- [Thin-Core analysis](../plan/analysis/2026-07-26-thin-core-boundary.md)
