# Harness events contract analysis — 2026-07-26

> **Superseded boundary:** D-011 rejects the separate Core `lifecycle.zig` selected below. This file remains historical
> analysis. The active target is [thin Core boundary](./2026-07-26-thin-core-boundary.md) and the rewritten
> [harness-events module](../../modules/harness-events.md).

## Question

What is the smallest public lifecycle event contract that truthfully unlocks steering, session fork, and a later TUI
without coupling the Zig SDK to Trace internals or the closed `headless-v1` schema?

## Current state

Zag has three event-like surfaces with different owners:

| Surface | Current owner | Purpose | Important gap |
|---------|---------------|---------|---------------|
| `observer.Event` | Loop | trusted callback, verbose logging, CLI bridge | no run lifecycle; Tool result has no call id |
| Trace v1 | Loop + Agent facade | durable audit | intentionally persistence-shaped |
| `headless-v1` | CLI | public JSON/NDJSON process output | output-only; not an SDK callback type |

Current Loop observer events are `assistant_text`, `usage`, `tool_call`, `tool_result`, and `permission`
(`packages/zag-agent-core/src/observer.zig`). The Loop emits message/Tool source facts, while the Agent facade owns
run start, session/trace persistence, and terminal truth (`packages/zag-coding-agent/src/agent.zig`). The CLI separately
owns public headless envelopes.

Therefore neither "put run events in the Loop" nor "reuse headless JSON types" matches current ownership.

## Product requirement

D-009 requires truthful ordered message/Tool lifecycle events before steering and TUI. D-010 requires common semantics
before runtime extension carriers. The Pi alignment note used the broad phrase "message start/delta/end" and
"Tool start/update/end"; current Zag has no truthful source for two of those phases:

- provider content deltas exist below the Loop but are not consumed as Loop lifecycle state;
- synchronous Tool handlers expose one final body and no progress/update channel.

Capability truth wins over shape parity. M1 must not fabricate phases merely because another harness names them.

## Alternatives

### A. Add only `run_start`, `run_end`, and `error` to the existing Observer

Rejected:

- it leaves message/Tool correlation informal;
- a separate `error` event competes with the one-terminal invariant;
- expanding the existing union breaks exhaustive consumers and risks duplicate headless terminals;
- the Agent facade, not the Loop, owns terminal truth.

### B. Add the full Pi-shaped start/delta/end and start/update/end set now

Rejected:

- `message_delta` and `tool_update` lack current production sources;
- post-hoc text chunks are not provider deltas;
- reserved-but-never-emitted variants create an unverifiable contract;
- plumbing provider streaming and Tool progress would turn M1 into a broad transport/runtime task.

### C. Add a separate source-backed `LifecycleObserver`

Selected:

- preserves the existing Observer and closed headless mapping;
- gives the Agent facade explicit run start/terminal ownership;
- gives the Loop correlated complete message and Tool start/end events;
- uses a one-way dependency (`loop.zig` → `lifecycle.zig` → `message.zig`) with no import cycle;
- permits exact-one-terminal and Tool id invariants without modifying Trace v1;
- leaves real streaming/progress to tasks that own those sources.

## Chosen vocabulary

`lifecycle-v1` contains:

1. `run_start`;
2. `assistant_message` (complete validated message, never called a delta);
3. `tool_start` (turn, call index, id, name, arguments);
4. `tool_end` (same correlation plus result body);
5. `run_terminal` (turn count, truthful `ok`, lifecycle-owned stop reason, cumulative usage).

`loop.StopReason` becomes a public alias of the lifecycle-owned enum. This removes an extra mapping while preserving
existing source imports. The Agent's mapping to Trace controlled stops remains exhaustive, so adding a future reason
fails compilation until persistence mapping is updated.

`usage` and `permission` remain available through the existing Observer in M1. They are not duplicated into the
lifecycle stream unless a later consumer proves that duplication necessary.

## Terminal ownership

The Agent facade emits lifecycle `run_start` only after run preflight succeeds. Every later exit must pass through a
single lifecycle-terminal owner:

```text
beginRun succeeds
    → emit run_start
    → loop / save / trace terminal work
    → normalize final Result or ReplyError
    → emit exactly one run_terminal as the final lifecycle callback
```

`run_terminal` is not emitted by `deinit`. If committing a successful Trace terminal fails, lifecycle terminal truth is
`trace_error`, not the earlier successful Loop result. A failed preflight before `run_start` is not a lifecycle-started
run and needs no synthetic terminal.

## Ordering and correlation

- Assistant events carry the Loop turn number and complete text, but not a duplicate Tool-call list.
- Tool events carry turn, the Loop's existing serial call index, and model Tool call id. `executeOneTool`, soft-result
  helpers, cancel backfill, and `finishTool` must receive that correlation explicitly.
- Every accepted call, including an unknown Tool, denied call, invalid argument, jail/shell denial, or pending-cancel
  backfill, gets one `tool_start` and one `tool_end`.
- `run_terminal` is final. No lifecycle event may follow it for that synchronous reply.
- M1 supports one synchronous reply per Agent call; it adds no global run id or concurrent-run claim.

## Ownership and trust

All slices are callback-borrowed. The callback is synchronous and infallible (`void`), so it can delay but cannot alter
run control. Raw content is acceptable only for a trusted E0 Zig caller already able to inject Tools/Providers. This is
not the redacted payload contract for E2, E3, RPC, or public JSON.

## Compatibility

The existing `Observer` remains supported and unchanged. `Agent.Options` and Loop options gain a separate optional
lifecycle observer defaulting to none. The external SDK fixture installs it, exercises a completed Tool run, and copies
borrowed payloads. This is an additive Zig source change; no Trace/session/headless schema version changes. The SDK
contract Event section and the Loop's current-gap sentence are updated in the implementation closeout.

## Mapping boundary

- Trace keeps its own event kinds and persistence semantics.
- Headless continues mapping existing source facts to `headless-v1` and owning its terminal envelope.
- No internal Zig union is serialized.
- Future `rpc-v1`/`zag-ext-v1` may define a redacted/versioned wire mapping after their own Gate.

## Risks

| Risk | Mitigation |
|------|------------|
| duplicate terminal between Agent and CLI | lifecycle observer is not installed by current headless path |
| terminal gap on ReplyError | facade centralizes all post-start exits and tests each controlled reason |
| callback re-entry | explicitly unsupported for the same Agent |
| borrowed data retained | SDK contract and consumer fixture require copying |
| source/API growth later | add real delta/update only with a source-owning compatibility task |
| lifecycle/Trace drift | golden sequences compare stop reason, turn count, and Tool correlation |

## Decision

Proceed with `harness-events-001` as a source-backed in-process SDK contract. Do not add fabricated deltas, Tool progress,
steering, hooks, wire protocols, or UI. The event contract is a prerequisite for those surfaces, not their implementation.
