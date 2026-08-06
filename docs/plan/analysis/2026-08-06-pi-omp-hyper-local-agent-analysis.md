# Pi / OMP / Hyper → Zag local coding-agent analysis

> Date: 2026-08-06
> Scope: local source snapshots only
> Decision output: [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
> Delivery route: [roadmap](../../roadmap.md#d-012-capability-route)

## Question

How should Zag become a complete local coding agent while preserving its
Zig-native ownership, safety, and thin-Core constraints?

This is a capability and architecture comparison, not a request for source,
API, protocol, or product parity.

## Local evidence

| Project | Local snapshot | Used as |
|---------|----------------|---------|
| Pi | `/Users/davirian/orca/pi` | harness structure, session/extension/RPC/TUI semantics |
| OMP | `/Users/davirian/orca/oh-my-pi` | coding-workflow feature ceiling: editing, LSP/DAP, subagents, memory |
| Hyper / Grok Build | `/Users/davirian/orca/hyper-grok-build` | native process/workspace/sandbox services, ACP/MCP/WASM, PTY/TUI validation |
| Zag | `/Users/davirian/orca/zag` | current implementation, package law, maturity and safety contracts |

No external repository was executed or modified for this analysis.

## What each reference contributes

### Pi: structural model

- thin agent loop and explicit host seams;
- session/resource ownership outside presentation;
- extension points and long-lived RPC as harness capabilities;
- a product shell that consumes stable events instead of owning policy.

Zag should preserve the shape, not Pi's TypeScript APIs, package manager,
provider count, wire schema, or release cadence.

### OMP: local coding-workflow ceiling

- stale-resistant, reviewable multi-file editing;
- repository navigation backed by symbols/LSP rather than prompt-only search;
- typed subagents with bounded roles and result handoff;
- optional memory and richer developer feedback surfaces.

These are product capabilities. They belong in `zag-coding-agent` or dedicated
services, not in `zag-agent-core`.

### Hyper: runtime and safety reference

- owned process lifecycle and workspace services;
- ACP/MCP integration behind explicit protocols;
- sandbox/capability separation;
- native extension/runtime boundaries;
- PTY/TUI validation that tests the real shell surface.

Hyper's cloud, desktop, browser, media, and broad product shell are not Zag
scope.

## Zag gap matrix

| Capability | Current Zag status | Selected direction |
|------------|--------------------|--------------------|
| Thin loop, permissions, workspace jail, sessions, headless | L2 floor exists | preserve as invariant |
| Session/context sharpness | M3 landed at `31523b6` | extend later with tree/runtime model data; no schema claim yet |
| TUI | minimal + streaming + layout landed | finish Vaxis first, then adapt Theme candidate |
| Edit | `apply_hunk` + `apply_transaction` **done** @ `e086df8` | keep format evolution separate; no L3 claim |
| Repo intelligence | search/context only | bounded repo map plus LSP service (after supervisor) |
| Process ownership | no supervisor; contract **draft** | [process-supervisor-001](../tasks/process-supervisor-001.md) before LSP/MCP/subagents |
| Long-lived clients | one-shot headless only | define Zag-native correlated `rpc-v1`, then ACP adapter |
| Delegation | steering/follow-up only | typed bounded subagents after supervisor |
| Runtime extensions | E0/E1 only | MCP/E2 after supervisor; E3 WASM remains separately gated |
| Memory | no production claim | default-off, auditable, deletable retrieval only after measured need |

## Dependency order

1. **Multi-file edit transaction** gives later tools one reliable write path.
2. **Process supervisor** establishes cancellation, output, timeout, and child
   ownership for every executable service.
3. **Repo map/LSP** uses the supervisor and edit transaction.
4. **`rpc-v1`** exposes correlated long-lived control/events without changing
   `headless-v1`.
5. **ACP adapter** maps editor semantics onto stable RPC/lifecycle contracts.
6. **Typed subagents** reuse supervisor, sessions, permissions, and lifecycle.
7. **MCP/E2** reuses the same process/capability boundary.
8. **Session tree/runtime model data/default-off memory** follow their own
   schema and maturity Gates.

This order is a roadmap dependency, not a batch implementation plan. Each item
still needs a binding module contract, task sheet, negative fixtures,
independent review, and merged-main evidence.

## Explicit non-goals

- Pi, OMP, or Hyper source/API/wire compatibility;
- provider/OAuth parity or npm/Bun compatibility;
- cloud collaboration, relay, remote session hosting, marketplace operation;
- browser/desktop takeover, voice, image, or video products;
- unrestricted native plugins or unsafe terminal access;
- pushing product policy, durable state, LSP, orchestration, or process
  ownership into `zag-agent-core`;
- claiming L2/L3 from a green happy-path test alone.

## Result

Zag should use Pi for **architecture**, OMP for **coding capability
expectations**, and Hyper for **native runtime/process safety**. D-012 records
that target while D-009, D-010, and D-011 continue to constrain how it is
implemented.
