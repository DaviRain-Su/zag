# Module: thin Agent Core boundary

| Item | Content |
|---|---|
| Decision | [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) |
| Current code | `packages/zag-agent-core/src/` plus product facade in `packages/zag-coding-agent/src/agent.zig` |
| Target | Thin loop kernel with explicit required ports; product policy/state in coding-agent |
| Migration status | **Done through `harness-events-001` at `aecf402`.** Required seams and canonical `LoopEvent` remain in Core; durable session, Trace/redaction/Observer, concrete permission/workspace/shell policy, and product context/compaction ownership live in coding-agent. Protocol-history validation and the single authoritative `CompactionEvent`/`ContextView.View` definitions remain in Core. The product lifecycle adapter projects Core source facts plus facade facts without a Core lifecycle channel. Merged-main std **530/530** and curl **529/529** passed; no existing L2 row was raised or lowered. |
| Reference | Pi low-level `agent-loop.ts` / `agent.ts` / `types.ts`, semantics only |

## Purpose

Define the ownership line between the generic agent loop and the coding product. The boundary is based on who witnesses
and owns a failure, not on whether code is reusable or whether two files currently share a Zig package.

## Target dependency and ownership

```text
zag (bin)
  └─ zag-cli
       process signals · stdin/terminal · args · plain/headless output
       └─ zag-coding-agent
            Agent/Session facade · run lifecycle · product policies
            context/compaction · session/trace/redaction · concrete Tools
            provider/model wiring · product event fan-out
            ├─ zag-agent-core
            │    loop · transcript · Provider/Tool/Cancel ports
            │    protocol-history validation · LoopEventSink
            │    required ToolPolicy/Jail/ShellPolicy/ContextView ports
            └─ zag-ai
                 model resolve · WireAdapter · vendor wire quarantine
```

`zag-agent-core` continues to depend only on `zag-types`. `zag-coding-agent` is the first strict product consumer and may
depend on both Core and `zag-ai`.

## Kernel responsibilities

The kernel owns only behavior that cannot be delegated without changing the meaning of one loop invocation:

1. validate the Toolset and protocol-visible history before any provider request;
2. poll an injected `ControlInput` only at protocol-safe boundaries and commit an item only after its user row is owned
   by the authoritative transcript;
3. project the current transcript through an injected `ContextView`;
4. independently validate the protocol-visible body of the projected view before
   any `Provider.chat` (regardless of how the product built the view);
5. call `Provider.chat` with definitions only and propagate `RequestControl`;
6. process assistant Tool calls in deterministic order;
7. validate arguments, invoke every required pre-execution gate, then execute exactly once or create one soft result;
8. append complete assistant/Tool/control messages exactly once;
9. backfill accepted pending Tool calls with truthful cancellation or steering-interruption results;
10. emit source facts synchronously in program order;
11. return a typed loop `Result` or `RunError` without inventing run-level persistence success.

The kernel does not own Provider configuration, concrete control queues/capacity/threading, filesystem policy
implementation, shell deny lists, compaction policy, durable session/Trace files, secret redaction, CLI output, or a
public process protocol.

## Required ports

Every port is a borrowed, caller-owned value that must outlive `loop.run`. Implementations may use Zig static functions
or the existing `ptr + vtable` pattern. The code task chooses exact names and error sets without weakening this table.

| Port | Minimum input | Required output/failure | Missing behavior |
|---|---|---|---|
| `Provider` | messages, Tool definitions, `RequestControl` | complete `AssistantTurn` or neutral `ChatError` | Already mandatory. |
| `ToolPolicy` | descriptor, validated arguments, extracted path context | allow or structured deny; typed host failure | No implicit allow/yolo. |
| `Jail` | descriptor workspace metadata, extracted path, Tool context | allow or `jail_deny`; typed host failure | No implicit allow. Non-file Tools return explicit not-applicable from the implementation. |
| `ShellPolicy` | descriptor shell metadata, validated command context | allow or `shell_deny`; typed host failure | No implicit allow. Non-shell Tools return explicit not-applicable. |
| `ContextView` | allocator, authoritative transcript | provider message view plus optional borrowed compaction fact | No implicit empty/identity view; identity is an explicit implementation. |
| `LoopEventSink` | one borrowed `LoopEvent` | success, `OutOfMemory`, or visible sink failure | No implicit discard; discard is an explicit implementation. |
| `ControlInput` (`harness-steering-001` target) | safe boundary (`pre_turn`, `between_tools`, `would_complete`) | atomically selected borrowed `{kind,text}` + infallible matching commit after transcript append | No hidden default; low-level no-control composition selects explicit `none()`. Core owns no queue. |

`ControlInput` is an explicit composition seam, not a safety-policy gate. Its concrete Session queue, mutex, fixed
capacity, enqueue errors, retention, and clear/deinit behavior remain coding-agent-owned. Product `Agent.reply` binds
the seam to the exact Session argument for that run. At a mid-batch steering boundary, Core must pre-copy the user text
and reserve transcript message capacity before emitting any `code=steered` result, so a fully closed steered bundle
cannot be stranded by a later append allocation failure.

### Fixed pre-execution order

```text
Registry.find
  → validate/extract arguments once
  → ToolPolicy
  → Jail
  → ShellPolicy
  → Registry.executeTool
  → append Tool result
```

The same extracted path is passed to policy and jail. A product port cannot ask Core to execute first and validate later.
Unknown Tool and malformed arguments soft-fail before product policy. Toolset/descriptor validation remains in Core and
fails before the first provider call.

A low-level host can explicitly provide permissive implementations because it already controls arbitrary Provider and
Tool function pointers. That is an intentional trust boundary, not a product default. `zag-coding-agent.Agent` must
always install ask/jail/protect unless the caller explicitly selects another documented product mode.

## Context split

The former `context.zig` has been split (core-context-ownership-001):

| Category | Target owner | Location |
|---|---|---|
| Message/tool-result bundle legality required by the provider protocol | Core | `protocol_history.zig` (`validateBodyHistory`, `alignToLegalStart`, `unitEnd`, `validateViewBody`) |
| `CompactionEvent` and `ContextView.View` (single authoritative types) | Core | `context_view.zig` |
| Four prompt layers, token/character budget, fixed-point compaction, summary/lineage | Coding-agent | `context.zig` (`Options`, `Layers`, `viewForModel`, summary/lineage) |

The loop independently validates the protocol-visible body of the projected view
**after** the `ContextView` returns and **before** accepting/emitting any compaction fact or calling
`Provider.chat`, regardless of how the product built the view. A hostile `ContextView` that returns a malformed
bundle is rejected with `InvalidContext`; no compaction fact reaches the sink and the provider is never called.

`ContextView` returns a view borrowed from its supplied scratch allocator. Any compaction summary is borrowed for the
callback only. The product Session must copy data it retains.

The product fan-out preserves the existing successful order:

```text
ContextView produces compaction fact
  → Session copies/records fact
  → durable Trace records the same bytes
  → provider receives the final view
```

Session failure remains visible and prevents a Trace compaction claim. A later Trace failure remains a visible run
failure. Moving the algorithm does not weaken `invalid_context`, byte-equality, or terminal behavior.

## Event model

### `LoopEvent` — Core source facts

Core emits only facts it directly witnesses:

- turn start/count;
- complete validated assistant message (`{ text, has_tools }`) and provider usage;
- Tool start and Tool end with turn/call-index/call-id correlation (`tool_end` carries a borrowed `id`);
- applied steering/follow-up kind, intended next turn, and transcript-owned borrowed text (`harness-steering-001` target);
- policy, jail, and shell decisions;
- provider retry;
- context projection/compaction fact;
- loop stop result.

Payload slices are borrowed and valid only during synchronous `emit`. Consumers copy retained data. Emission is fallible
so a configured durable audit adapter can stop the run rather than silently lose required evidence.

`LoopEvent` does not contain product `run_start` or `run_terminal`.

### Run lifecycle — coding-agent facts

The facade exclusively witnesses:

```text
preflight
  → run start
  → append user / loop / session save
  → transactional Trace terminal
  → one truthful public run terminal
```

A preflight failure before start has no started-run terminal. Every ordinary post-start path has exactly one terminal.
Trace commit failure takes precedence over an earlier successful loop result. `deinit` never invents a terminal.

### Adapters

| Adapter | Owner | Failure policy |
|---|---|---|
| Durable Trace | coding-agent | Fail closed; preserve current transactional terminal and error precedence. |
| Session persistence | coding-agent | Fail closed; atomic prior-byte preservation. |
| Verbose logger | coding-agent/CLI | May drop a line on redaction OOM; never print raw fallback. |
| In-process SDK lifecycle | coding-agent | Borrowed synchronous callbacks; copy to retain. |
| `headless-v1` | CLI | Independently versioned mapping; exactly one process terminal; never serialize a Zig union directly. |

There is no separate Core `LifecycleObserver`. `harness-events-001` closed at `aecf402` as a product SDK event
adapter (`packages/zag-coding-agent/src/lifecycle.zig`) over Core source facts and facade run facts. The merged-main
Gate passed std **530/530** and curl **529/529**; this adapter does not change Trace/session/headless schemas or any
closed L2 row.

## Product-owned state

| State | Owner | Why |
|---|---|---|
| Transcript arena | Core caller / coding Session | Required by loop; in-memory authority. |
| Permission remember set | Coding-agent | Product policy and user interaction. |
| Workspace root/Guard state | Coding-agent | Product execution policy and Tool runtime. |
| Context layers/compaction generation | Coding Session | Session/product projection. |
| Steering/follow-up queue storage | Coding Session | Conversation-scoped bounded product state; preallocated/mutex-protected and non-durable. |
| Session writer/path/lease | Coding Session | Durable product state, not loop execution. |
| Trace buffer/path/terminal state | Coding Agent/Trace | Run-level audit and persistence. |
| Redactor secrets/policy | Coding Agent/Session | Product output/persistence boundary. |
| Signal handler/terminal state | CLI | Process-global host state. |

## Error ownership

| Failure | Kernel responsibility | Product responsibility |
|---|---|---|
| Invalid Toolset/history | Return typed error before provider call. | Map to truthful run terminal. |
| Provider/cancel/deadline | Return typed error/result with complete transcript semantics. | Map to final run/process contract. |
| Policy/jail/shell deny | Append structured soft Tool result from port decision. | Implement decision and safe product defaults. |
| Port infrastructure failure | Return `OutOfMemory` or visible sink/policy failure. | Map without calling it provider success. |
| Session save/Trace persist/redaction | Not owned by Core. | Preserve prior bytes and commit truthful terminal. |

## Public surface and compatibility

The migration completed before any semver publication promise. Each ownership task updated the external SDK consumer
and documented its source migration; no duplicate authoritative implementation was retained merely to preserve an old
import path. Future source moves remain subject to the same fixture-and-doc migration rule until publication policy
changes.

## Migration DAG

```text
core-boundary-001  (this contract)
        │
        ▼
core-seams-001     required ports + canonical LoopEvent; current behavior via adapters
        │
        ▼
core-session-ownership-001   ✓ done — durable session store moved to coding-agent; Transcript stays Core
        │
        ▼
core-observation-ownership-001   ✓ done — Trace/redaction/Observer moved to coding-agent; Core emits LoopEvent facts only
        │
        ▼
core-policy-ownership-001   ✓ done — concrete permissions/HITL/remember, workspace Guard/Root/realpath/symlink containment, and shell protect/off moved to coding-agent; Core retains required ports + deniedBody renderers + pure lexical `tool_args.checkToolPath`
        │
        ▼
core-context-ownership-001   ✓ done — protocol-history validation stays in Core (`protocol_history.zig`); prompt layers/budget/fixed-point compaction/summary/lineage moved to coding-agent (`context.zig`); `CompactionEvent`/`View` single authoritative definitions in Core `context_view.zig`; loop independently validates projected view body before Provider.chat
        │
        ▼
harness-events-001   ✓ done @ aecf402 — product SDK lifecycle adapter; no Core lifecycle.zig
        │
        ▼
harness-steering-001   in-progress — Session queues + generic Core ControlInput; no Core product queue
```

These migration tasks were serialized because they overlapped `loop.zig`, `agent.zig`, roots, the SDK fixture, and Product Spec docs.

## Verification contract

Every implementation node must preserve:

- package tests for `zag-agent-core`, `zag-coding-agent`, and `zag-cli`;
- external SDK consumer fixture using module imports only;
- root std and curl suites;
- `headless-v1`, Trace v1, and session v1 schema compatibility;
- completed/error/cancel/timeout/unsupported-control terminal matrices;
- custom write/execute Tool policy tests;
- escaping path and dangerous shell handler-count-zero tests;
- context invalid-history and session/Trace compaction equality tests;
- redaction OOM and durable prior-byte preservation tests.

Additional boundary fixtures must prove:

1. omitting a required ToolPolicy/Jail/ShellPolicy dependency does not compile or fails closed by construction;
2. explicit deny implementations prevent handler execution in the fixed order;
3. explicit permissive low-level composition is visible in source and never selected by product defaults;
4. one loop fact reaches durable Trace and best-effort verbose adapters without duplicate execution;
5. no Core import or public root exposes product persistence/prompt/CLI/observation implementations after closeout;
6. low-level no-control composition selects `ControlInput.none()` explicitly and remains behavior-compatible;
7. Core contains no Session queue storage, capacity, mutex, enqueue policy, or durable pending state;
8. applied control uses the existing `LoopEventSink` source channel and does not add a Trace/headless kind.

## Trace vocabulary source map (core-observation-ownership-001)

The twelve durable Trace kinds each source exactly once from a Core `LoopEvent` fact or the coding-agent facade — never both.
`run_start` and `run_end` are **facade-only**; they are never added to Core `LoopEvent`. The in-progress
`control_applied` source fact has no thirteenth Trace v1 kind: resulting turns and `tool_result(code=steered)` remain
trace-visible, while full control text is available through Session/transcript and trusted lifecycle only.

| Trace kind | Source | Owner |
|---|---|---|
| `run_start` | `Agent.beginRun` (facade preflight + reserve) | coding-agent |
| `run_end` | `Agent.commitTerminal` / `failRun` (facade) | coding-agent |
| `turn` | `LoopEvent.turn_start` | Core |
| `assistant` | `LoopEvent.assistant_message` | Core |
| `usage` | `LoopEvent.usage` | Core |
| `tool_call` | `LoopEvent.tool_start` | Core |
| `tool_result` | `LoopEvent.tool_end` | Core |
| `permission` | `LoopEvent.policy_decision` | Core |
| `jail_deny` | `LoopEvent.jail_decision` | Core |
| `shell_deny` | `LoopEvent.shell_decision` | Core |
| `provider_retry` | `LoopEvent.provider_retry` | Core |
| `compaction` | `LoopEvent.context_compaction` | Core |

Fan-out order is preserved by the `RunBridge` event-sink adapter in `zag-coding-agent`: turn → Trace only; assistant → Observer/internal verbose → Trace; usage → Trace → Observer/ledger/verbose; tool start/end → Observer → Trace; applied control → trusted Lifecycle only (target); policy → Observer → Trace; jail/shell/retry → Trace then **unconditional generic warning**; compaction → session note → Trace. Trace failure maps to `SinkFailed` (`TraceFailed`) and short-circuits subsequent warnings. `run_start` precedes the loop; session save precedes the success terminal. Verbose redaction OOM is drop-only (never raw fallback).

## Non-goals

- changing closed L2 behavior for explicit no-control/empty-queue composition or changing schema versions;
- placing concrete/asynchronous queues, capacity policy, persistence, or mutexes in Core; the follow-on `ControlInput` remains a synchronous generic seam;
- provider deltas, Tool progress, or mid-flight Provider/Tool steering preemption;
- creating new packages during the responsibility migration;
- claiming OS sandboxing or hostile-host protection;
- preserving the paused core lifecycle implementation.
