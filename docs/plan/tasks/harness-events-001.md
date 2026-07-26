---
id: harness-events-001
scope: sdk/lifecycle-observation
status: pending
priority: P1
depends-on:
  - cli-sigint-001
---

# objective

Add a source-backed `lifecycle-v1` callback contract for trusted Zig SDK consumers: run start/terminal, complete
assistant messages, and correlated Tool start/end events. Preserve the existing Observer, Trace v1, and `headless-v1`
contracts.

Binding specification: [Harness lifecycle events](../../modules/harness-events.md).
Analysis: [2026-07-26 harness events contract](../analysis/2026-07-26-harness-events-contract.md).

# context

- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-010-extension-tiers-and-process-protocol.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/trace-observability.md`
- `docs/modules/headless-contract.md`
- `docs/plan/tasks/cli-sigint-001.md`
- `docs/plan/tasks/sdk-contract-001.md` (closed SDK Gate; preserve compatibility)
- `docs/plan/tasks/headless-001.md` (closed process Gate; preserve schema/terminal behavior)

# path

- `packages/zag-agent-core/src/lifecycle.zig` (new)
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig` (only if public re-export is required)
- `tests/sdk-consumer-fixture/`
- `docs/modules/harness-events.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/README.md`
- `docs/plan/README.md`
- `docs/plan/tasks/harness-events-001.md`
- `docs/maturity.md` and `docs/roadmap.md` only at verified closeout

`packages/zag-cli/src/headless_writer.zig`, Trace schema, session schema, and provider stream plumbing are out of scope
unless implementation proves a small mapping regression that cannot be fixed elsewhere.

# contract

1. Add a separate `LifecycleObserver`/`LifecycleEvent`; do not rename or expand the current low-level Observer in M1.
2. Event payloads are callback-borrowed, synchronous, allocation-free at emission, and trusted E0-only.
3. Emit only `run_start`, `assistant_message`, `tool_start`, `tool_end`, and `run_terminal`.
4. Message events contain complete validated assistant text and turn correlation; they are not called deltas and do
   not duplicate the Tool-call list.
5. Tool events contain turn, the Loop's serial call index, call id, name, and arguments/body. Loop execution and finish
   helpers receive this correlation explicitly for every soft/cancel path.
6. Agent facade owns `run_start` and exactly one final `run_terminal`; Loop owns message and Tool source facts.
7. `lifecycle.StopReason` is the canonical in-memory enum and `loop.StopReason` remains a public alias. The Agent's Trace
   mapping stays exhaustive, preventing silent reason drift.
8. Existing Observer, Trace v1, `headless-v1`, and CLI SIGINT behavior remain unchanged.

# verification

1. **Completed run:** `run_start → assistant_message → run_terminal(completed)`; terminal is last and unique.
2. **Tool run:** each `tool_start` has one matching `tool_end` by turn/call-index/id before the next provider turn.
3. **Soft Tool outcomes:** unknown Tool, permission deny, invalid arguments, jail deny, shell deny, and handler failure still
   end with a correlated `tool_end` body.
4. **Cancel:** pending accepted Tool calls backfilled as cancelled receive matching `tool_end`; terminal is `cancelled`.
5. **Failure terminals:** provider, session save, trace, OOM, invalid toolset/context, timeout, and unsupported-control
   paths emit one truthful terminal after a start.
6. **Preflight failure:** a failure before `run_start` emits no lifecycle terminal.
7. **Ordering:** no lifecycle callback follows `run_terminal`; callback program order matches transcript Tool order.
8. **Ownership:** the external SDK fixture installs `LifecycleObserver`, observes a completed Tool run, copies borrowed
   message/Tool bytes, and retains those copies safely after callback return.
9. **Golden sequences:** deterministic lifecycle goldens live with `lifecycle.zig` tests and cover completed, Tool,
   cancel, provider/session/trace error, OOM, invalid-toolset/context, timeout, and unsupported-control terminals.
10. **Compatibility:** existing low-level Observer tests and all prior SDK consumer cases remain green.
11. **Isolation:** parsed `headless-v1` output and Trace v1 fixtures are byte/schema compatible; no duplicate terminal.
12. **Docs:** `sdk-contract.md` gains the lifecycle-v1 ownership/event section and `loop-turn.md` closes its lifecycle gap.
13. **No fake phases:** source and docs contain no emitted `message_delta`/`tool_update` claim.
14. **Gate:** package tests, SDK fixture, headless process fixture, and root std/curl full suites pass on merged main.

# non-goals

- provider token/content stream integration;
- Tool progress/update callbacks;
- steering, follow-up queues, or deny hooks;
- session fork;
- Trace/session/headless schema changes;
- async delivery, queueing, retry, or backpressure;
- run ids for concurrent Agents;
- RPC, E2/E3 extensions, TUI, Graph, or subagents.
