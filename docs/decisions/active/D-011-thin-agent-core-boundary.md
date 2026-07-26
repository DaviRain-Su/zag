---
status: active
id: D-011
title: Keep zag-agent-core as a thin loop kernel
date: 2026-07-26
---

# D-011 — Keep `zag-agent-core` as a thin loop kernel

## Decision

`zag-agent-core` owns the generic single-agent loop and only the contracts required to run it. Product policy,
persistence, redaction, provider/model composition, and run-level lifecycle belong to `zag-coding-agent`.

This corrects the current implementation, where `loop.zig` directly imports concrete context, permission, workspace,
shell, Observer logging, and Trace implementations. Passing the package dependency rule (`zag-agent-core` depends only
on `zag-types`) is necessary but not sufficient: a package can obey its import direction and still contain the wrong
responsibilities.

## Reference finding

At Pi snapshot `5bc1c2c0a6f07e00e8c240304182f213ab8d311f`, the low-level path consists primarily of
`packages/agent/src/agent-loop.ts`, `agent.ts`, and `types.ts`. It owns model/Tool iteration, in-memory state, cancellation,
and source events through injected `StreamFn`, Tool, context-transform, and event-sink contracts. Pi's coding product
owns `AgentSession`, model/provider runtime, concrete Tools, persistence, extensions, trust, prompts, and UI modes.

The same Pi package now also exports a higher-level `src/harness/`, but that directory depends one-way on the low-level
loop and Pi's coding-agent does not use it. NPM package membership is therefore not evidence that those responsibilities
belong in Zag's loop kernel.

Zag follows the responsibility split, not Pi's TypeScript API or package granularity.

## Kernel contract

`zag-agent-core` retains:

1. canonical message aliases and the authoritative in-memory `Transcript`;
2. the pure `Provider.chat` port and request-control propagation;
3. generic Tool registration, validation, lookup, argument validation, execution, and stable soft-error shape;
4. model → Tool → model ordering, turn limits, retry ownership, cancellation, and resume-safe Tool-result backfill;
5. protocol-history validation required before a provider call;
6. one canonical, synchronous, borrowed, fallible `LoopEventSink` for facts witnessed by the loop;
7. the following explicit loop dependencies: `ToolPolicy`, `Jail`, `ShellPolicy`, `ContextView`, and `LoopEventSink`.

The loop owns the invocation order:

```text
validate Toolset and protocol history
  → ContextView
  → Provider.chat
  → for each accepted Tool call
       validate arguments
       → ToolPolicy
       → Jail
       → ShellPolicy
       → execute
       → append exactly one Tool result
  → emit source-backed LoopEvent facts in program order
```

The ports do not make safety optional. `ToolPolicy`, `Jail`, and `ShellPolicy` are required dependencies with no implicit
allow/yolo fallback. A low-level caller that intentionally wants `allow_all` must select it explicitly. The supported
`zag-coding-agent.Agent` path always installs product defaults equivalent to `ask + workspace jail + shell protect`.

`ContextView` and `LoopEventSink` are also explicit. A low-level caller may explicitly select an identity view or discard
sink; missing required state is not silently normalized to either behavior.

## Product-harness contract

`zag-coding-agent` owns:

- the `Agent`/`Session` facade and every run-level preflight/start/terminal path;
- model/provider runtime composition and `WireProvider`;
- permission/HITL policy and remembered decisions;
- workspace containment and shell-protection implementations;
- context layers, compaction, and session compaction projection;
- session persistence, Trace persistence/transactional terminal behavior, and redaction;
- Observer logging/fan-out and public SDK/headless adapters;
- default and caller-supplied coding Toolsets plus concrete filesystem/edit/shell handlers.

`core-observation-ownership-001` completed the Trace/redaction/Observer move: `trace.zig`, `redact.zig`, and
`observer.zig` were moved whole-file from `zag-agent-core` to `zag-coding-agent` via `git mv`. Core no longer
exports or implements any observation surface; its only event port is the canonical borrowed/fallible
`LoopEventSink`. The twelve durable Trace kinds source exactly once from `LoopEvent` facts or the facade
(`run_start`/`run_end` are facade-only; see [core-boundary.md](../../modules/core-boundary.md#trace-vocabulary-source-map-core-observation-ownership-001)).
Behavior, schemas (Trace v1, headless-v1, session v1), byte/sequence/error/terminal precedence, and redaction
OOM fail-closed semantics are unchanged.

`zag-cli` continues to own process signals, stdin permission prompting, terminal logging, arguments, REPL, and process
protocol output.

## Event ownership

The loop emits only source facts it directly witnesses: turn, complete assistant message, usage, Tool start/end,
policy/jail/shell denial, provider retry, context projection/compaction, and the final loop stop result.

Run preflight, `run_start`, session save, Trace terminal commit, and the truthful final run terminal remain owned by the
coding-agent facade. `run_terminal` is not added to the core loop event union.

Trace, verbose Observer output, SDK callbacks, and headless output are adapters over source facts with their own failure,
redaction, ownership, and schema contracts. A product fan-out may make durable Trace emission fail-closed while keeping
verbose logging best-effort; a shared source event does not force all subscribers to share one failure policy.

The proposed core `lifecycle.zig`/separate `LifecycleObserver` is superseded. `harness-events-001` must be redesigned after
the boundary migration and must not add a third core event channel.

## File disposition

| Current core file | Target disposition |
|---|---|
| `loop.zig` | Keep; depend only on generic kernel contracts. |
| `message.zig`, `transcript.zig` | Keep. |
| `provider.zig` | Keep as the pure Provider port. |
| `tool.zig`, `tool_error.zig` | Keep as generic Tool runtime and soft-error contract. |
| `cancel.zig` | Keep the cancel token only; process SIGINT already belongs to CLI. |
| `observer.zig` | Moved to coding-agent (core-observation-ownership-001); the whole module lives in `zag-coding-agent`. Core's only event port is `LoopEventSink`. |
| `context.zig` | Split (core-context-ownership-001): protocol-history validation stays in Core as `protocol_history.zig`; layers/compaction implementation moved to coding-agent `context.zig`; `CompactionEvent`/`View` single authoritative definitions in Core `context_view.zig`. |
| `permissions.zig` | Replace core dependency with `ToolPolicy`; concrete Gate/remember/prompt wiring moves out. |
| `workspace.zig`, `shell_policy.zig` | Replace core dependencies with required ports; implementations move to coding-agent. |
| `session_store.zig` | Moved to coding-agent (core-session-ownership-001); Transcript remains core. |
| `trace.zig`, `redact.zig` | Moved to coding-agent (core-observation-ownership-001); loop emits facts through `LoopEventSink`. |
| `root.zig` | Export the reduced kernel surface; product exports product-owned contracts. |

No new Zig package is required for this migration. A future `zag-workspace` or other domain package still requires real
second-owner/dependency pressure under `packaging.md`.

## Safety and trust boundary

A caller that imports `zag-agent-core` directly is a trusted low-level composer: it can provide arbitrary Provider and
Tool implementations and can call raw Tool dispatch outside `loop.run`. The kernel cannot protect itself from a hostile
host that controls its function pointers.

The kernel must nevertheless prevent accidental fail-open composition:

- all pre-execution ports are explicit;
- no missing port becomes allow/yolo;
- Tool metadata remains mandatory and revalidated before the provider call;
- the loop, not a subscriber, owns policy → jail → shell → execute ordering;
- coding-agent tests prove its default composition is ask/jail/protect;
- existing L2 security, persistence, trace, headless, and SDK evidence remains a permanent regression Gate.

## Migration discipline

The migration is seam-first and behavior-preserving:

1. define ports and adapters while existing implementations remain in place;
2. move independently owned persistence/observation modules;
3. move concrete policy and context implementations;
4. reduce public exports and redesign SDK lifecycle events;
5. preserve every existing L2 behavior and schema unless a separately reviewed contract says otherwise.

Each node is independently reviewable and reversible. No big-bang directory move is allowed.

## Consequences

- Core becomes smaller in responsibility, not merely in line count.
- Provider and Tool ports remain in Core; concrete Provider and Tool behavior remains product-owned.
- Safety is retained through required ports and product composition rather than concrete product policy embedded in the
  generic kernel.
- Trace terminal semantics remain unchanged while their implementation moves to their true owner.
- `harness-events-001` is re-queued behind the boundary migration.
- SDK source compatibility may change during this unpublished pre-semver migration; the external consumer fixture and
  migration notes are mandatory on every affected task.

## Non-goals

- Pi API/package parity;
- weakening default ask, workspace containment, shell protect, redaction, or truthful terminal behavior;
- adding OS sandboxing, Graph, subagents, steering, TUI, RPC, or extensions;
- creating new domain packages solely to make the directory tree look layered;
- changing Trace v1, session v1, or `headless-v1` wire schemas in the boundary migration.

## Related

- [Core boundary module](../../modules/core-boundary.md)
- [D-007 Tool runtime descriptor](./D-007-tool-runtime-descriptor.md)
- [D-008 SDK/process boundaries](./D-008-sdk-and-process-boundaries.md)
- [D-009 Pi semantics, not parity](./D-009-pi-semantics-not-parity-fork.md)
- [Thin-core analysis](../../plan/analysis/2026-07-26-thin-core-boundary.md)
