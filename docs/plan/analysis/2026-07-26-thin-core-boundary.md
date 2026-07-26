# Thin `zag-agent-core` boundary analysis — 2026-07-26

## Question

How should Zag realign `zag-agent-core` with Pi's deliberately small low-level loop while preserving Zag's stronger
fail-closed Tool, persistence, redaction, cancellation, and terminal contracts?

## Sources and method

| Source | Commit | Use |
|---|---|---|
| Zag | `01e330aa379619bb1e48698cc5af265de0f02b57` | Current Product Spec and implementation baseline |
| Pi | `5bc1c2c0a6f07e00e8c240304182f213ab8d311f` | Read-only responsibility and call-chain reference |

The Pi snapshot was inspected as untrusted read-only data and was not executed. Three parallel source inventories, two
focused gap rounds, and a fresh final verifier compared the low-level loop, coding product, dependency directions,
safety ordering, events, persistence, and every current Zag Core file. The final verifier returned PASS with the
required clarification that policy, jail, shell, context-view, and event-sink seams must all be explicit.

## Finding 1: Pi's low-level boundary is narrower than its package tree

The low-level Pi path is primarily:

- `packages/agent/src/agent-loop.ts` — provider/Tool iteration and source event emission;
- `packages/agent/src/types.ts` — `StreamFn`, `AgentTool`, `AgentEventSink`, and hook contracts;
- `packages/agent/src/agent.ts` — in-memory state, cancellation, queues, and event reduction.

Those three files total about 1.8k lines in the pinned snapshot. Concrete product work is concentrated in
`packages/coding-agent/src/core/`: `AgentSession`, model/provider runtime, session manager, concrete Tools, trust,
extensions, resources, system prompt, settings, and UI-mode composition. Its top-level `core/*.ts` alone is about
17.5k lines before nested Tools/extensions/UI code.

The Pi agent package now also exports a higher-level `src/harness/` containing session, compaction, Skills, templates,
and Tool implementations. That code depends one-way on the low-level loop, and Pi's coding-agent chooses its own
`AgentSession` rather than using `AgentHarness`. Therefore package membership and public re-export flattening are not a
valid ownership model for Zag.

## Finding 2: Zag Core currently contains roughly half the product implementation

At the baseline, `packages/zag-agent-core/src/*.zig` is about 11k lines including colocated tests, close to the size of
`zag-coding-agent/src`. `loop.zig` directly imports or calls Provider, Tool, Transcript, Observer, permissions, context,
workspace, shell policy, Trace, Tool errors, and cancellation.

The issue is not raw line count. The issue is that a generic loop currently knows concrete product concepts:

- prompt layers and compaction policy;
- HITL mode and remembered approvals;
- filesystem root/realpath containment implementation;
- shell deny-list implementation;
- durable Trace serialization/persistence;
- verbose stderr formatting and redaction;
- session file format and writer ownership through Core exports.

The package still passes its formal import rule (`zag-agent-core → zag-types only`), demonstrating that dependency
direction alone does not prove responsibility placement.

## Finding 3: ports are not overgrowth

Provider, Tool, cancellation, and event interfaces are part of a loop. Concrete implementations are not.

| Surface | Correct owner |
|---|---|
| `Provider.chat` vtable | Core |
| `WireProvider`, model resolution, auth/headers | Coding-agent / `zag-ai` |
| generic Tool registry/validation/execution | Core |
| filesystem/edit/shell handlers and default Toolset | Coding-agent |
| source event type/sink | Core |
| verbose logger, durable Trace, SDK/headless mapping | Coding-agent / CLI |
| authoritative in-memory Transcript | Core caller / coding Session |
| durable session file/writer | Coding-agent |

Removing Provider or Tool ports would make Core unable to run. Moving only `session_store.zig` would leave the main
responsibility problem intact.

## Finding 4: safety can remain fail-closed without embedding product policy

Two bad extremes were rejected:

1. keep every concrete policy in Core merely because safety matters;
2. copy Pi's optional `beforeToolCall` hook and silently allow when absent.

The selected design keeps **ordering** in Core and makes **implementations** explicit dependencies:

```text
ToolPolicy → Jail → ShellPolicy → execute
```

All three ports are required and have no implicit allow default. `ContextView` and `LoopEventSink` are likewise explicit;
identity/discard are named implementations selected by a low-level caller, not missing-state fallbacks.

A direct Core caller is trusted because it already supplies arbitrary Provider and Tool function pointers and can call
raw Tool dispatch. Core protects against accidental omission, not a hostile host controlling its vtables. The supported
coding Agent remains the strict product boundary and always installs ask/jail/protect unless the caller explicitly
selects another product mode.

Tool descriptor/capability validation remains Core-owned and occurs before the first provider call. The same extracted
path is passed to policy and jail. Unknown tools and malformed arguments remain soft results before product policy.

## Finding 5: context must split by protocol versus product policy

`context.zig` currently mixes:

- protocol-history legality: Tool-call/result ID completeness and ordering;
- product projection: prompt layers, budget, fixed-point compaction, summary/lineage.

The former remains in Core because malformed provider history must fail before `Provider.chat`. The latter moves to
coding-agent behind `ContextView`. The port keeps turn-arena borrowing explicit, and product fan-out preserves
Session-then-Trace compaction ordering and byte equality.

## Finding 6: a third Core lifecycle channel is the wrong next node

The proposed `harness-events-001` design adds `lifecycle.zig` beside existing Observer and Trace. That increases Core
responsibility and creates duplicate source projections.

The selected event ownership is:

- Core `LoopEvent`: complete assistant, usage, correlated Tool start/end, policy decisions, retry, compaction, loop stop;
- coding-agent run lifecycle: preflight, run start, session save, Trace terminal, one truthful final terminal;
- adapters: durable Trace, verbose logging, in-process SDK events, and `headless-v1`.

Trace remains fail-closed by using a fallible product fan-out sink. Verbose logging may remain best-effort inside that
fan-out. A common source event does not force subscribers to share failure behavior. Run terminal stays out of Core and
retains the existing transactional Trace owner.

`harness-events-001` is therefore re-queued after the boundary migration and must not merge its existing branch.

## File classification

| Current file | Class | Target |
|---|---|---|
| `loop.zig` | kernel invariant | Keep and narrow imports. |
| `message.zig` | canonical alias | Keep. |
| `provider.zig` | loop port | Keep unchanged in purpose. |
| `tool.zig` | generic runtime/validation | Keep. |
| `tool_error.zig` | generic soft-error contract | Keep. |
| `transcript.zig` | in-memory loop state | Keep. |
| `cancel.zig` | cancel token | Keep; process signal already moved to CLI. |
| `observer.zig` | mixed port + product logger | Split. |
| `context.zig` | mixed protocol validator + product projection | Split. |
| `permissions.zig` | product policy | Move implementation; Core keeps `ToolPolicy` port. |
| `workspace.zig` | product/runtime containment | Move implementation; Core keeps required `Jail` port. |
| `shell_policy.zig` | product shell policy | Move implementation; Core keeps required `ShellPolicy` port. |
| `session_store.zig` | durable product state | Move. |
| `trace.zig` | durable product audit | Move; consume loop facts through product fan-out. |
| `redact.zig` | product output/persistence boundary | Move with observation/persistence owners. |
| `root.zig` | package export | Reduce after migrations. |

No file is deleted solely to reduce a metric. No new Zig package is created.

## Integration enumeration

The migration must preserve these real chains:

1. CLI flags → coding `Agent.Options` → required Core ports;
2. coding `WireProvider` → Core `Provider.chat` → `zag-ai.WireAdapter`;
3. custom Toolset → Core validation/Registry → product policy/jail/shell → handler;
4. loop source fact → coding fan-out → durable Trace and best-effort Observer;
5. context projection → Session compaction copy → Trace compaction → provider view;
6. loop result/error → session save → transactional Trace terminal → SDK/headless terminal;
7. CLI SIGINT Guard → Agent cancel token → Core checks/Provider `RequestControl`;
8. external SDK fixture → supported module imports → coding facade and low-level Core composition.

A module test alone cannot close any task that changes one of these chains.

## Delivery DAG

```text
core-boundary-001
  Product Spec + decision + task DAG; supersede core lifecycle design
        │
        ▼
core-seams-001
  required ToolPolicy/Jail/ShellPolicy/ContextView/LoopEventSink
  current implementations remain adapters; fixed ordering and no implicit allow
        │
        ▼
core-session-ownership-001
  move durable session store to coding-agent; keep Transcript in Core
        │
        ▼
core-observation-ownership-001
  move Trace/redaction/verbose logger; coding fan-out consumes LoopEvent
        │
        ▼
core-policy-ownership-001
  move permission/workspace/shell implementations; preserve product defaults and handler-count-zero gates
        │
        ▼
core-context-ownership-001
  split protocol history validation from product layers/compaction
        │
        ▼
harness-events-001
  redesign as coding-agent SDK lifecycle adapter; no core lifecycle.zig
```

The tasks are serialized because their paths overlap and each depends on the updated public/ownership contract from the
previous node.

## Completion criteria

The migration is complete only when:

- Core exports no durable session, Trace/redaction, concrete policy, workspace, shell, prompt, or CLI implementation;
- `loop.zig` imports only kernel contracts and `zag-types`-backed data;
- missing policy/jail/shell composition cannot become allow by default;
- product Agent default ask/jail/protect remains proven;
- Trace/session/headless schemas and terminal matrices remain compatible;
- SDK fixture documents source migration and remains module-import-only;
- std/curl root suites and all closed L2 regressions pass;
- `harness-events-001` is implemented only after the new boundary exists.

## Decision

Adopt [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md) and begin with the docs-only
`core-boundary-001` node. Do not resume or merge the existing `task/harness-events-001` implementation.
