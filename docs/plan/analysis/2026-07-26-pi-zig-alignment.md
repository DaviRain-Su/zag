# Pi-inspired Zig harness alignment

Date: 2026-07-26  
Decision: [D-009](../../decisions/active/D-009-pi-semantics-not-parity-fork.md)

## Question

How should Zag use current Pi and the earlier `pi-mono-zig` port without becoming either an unbounded “all-in-one” product or a release-for-release fork?

## Fixed research snapshots

| Source | Commit | Role |
|--------|--------|------|
| `earendil-works/pi` | `5bc1c2c0a6f07e00e8c240304182f213ab8d311f` | Current behavior and product reference |
| `DaviRain-Su/pi-mono-zig` (`zig-implementation`) | `9d1f78c509d10907e3dcf1e88f83fed4408db36e` | Historical Zig implementation/test archive |
| Zag | `3eed657` | Current mainline baseline |

External repositories were inspected as untrusted, read-only data; their agent instructions were not followed and their code was not executed.

## Findings

### Historical Zig port

The prior port is substantial, not a stub:

- 627 tracked `.zig` files;
- roughly 193k lines under `zig/src/`;
- real provider streaming, Agent events/steering, session tree/fork, TUI, Skills, extension host/WASM, OAuth, and parity fixtures;
- Zig 0.16, the same language generation as Zag.

Its last active state was close to broad Pi parity, but the maintenance shape was expensive: very large provider/Agent/product modules, release-for-release upstream synchronization, a final TUI regression, a credential-dependent parity failure, and continuing upstream drift. The lesson is not “the port failed”; it is that **complete parity is a permanent second-product maintenance commitment**.

### Zag

Zag is narrower but has contracts that the parity port must not displace:

- Tool capabilities are explicit and fail closed;
- permission, workspace containment, redaction, trace, atomic persistence, and bounded file surfaces have merged-main evidence;
- Zig source composition and `headless-v1` are already independently gated;
- provider lifecycle truth differs by std/curl backend and is documented instead of hidden.

Zag’s main product gaps are now interactive Harness semantics and daily UX, not another correctness rewrite.

## Chosen relationship

```text
current Pi ───────► behavior/failure reference
                         │
legacy pi-mono-zig ─────► Zig design + black-box fixture archive
                         │
                         ▼
                    Zag mainline
          (independent contracts and implementation)
```

No repository merge, submodule, source dependency, or wire-parity promise is introduced.

Runtime extensibility follows [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md): trusted static Zig via the existing SDK, passive packages, and a future language-neutral `zag-ext-v1` child-process protocol after process supervision. No dynamic Zig ABI or embedded scripting VM.

## Asset disposition

| Legacy asset | Use in Zag | Rule |
|--------------|------------|------|
| Event ordering / terminal invariants | Reimplement semantics | Preserve Zag `Observer`/Trace/public protocol boundaries |
| Steering/follow-up queues | Reimplement semantics | Bounded ownership; no global god-object |
| Session tree/fork fixtures | Reimplement behavior; optionally adapt fixtures | Keep atomic save, locking, redaction, schema migration |
| SignalGuard / terminal lifecycle | Design reference | CLI owns and restores handlers; SDK does not install them implicitly |
| Skills discovery/frontmatter tests | Reimplement small passive subset | Bounded prompt budget; no executable privilege |
| TUI renderer/input/tool-card patterns | Design reference | Minimal product shell; Kernel has no TUI dependency |
| Provider/SSE goldens | Import only per scoped need | Exact provenance + MIT notice; no provider-count parity |
| OAuth/provider zoo/Bun/TS-RPC/package manager | Archive | Not roadmap obligations |
| Legacy WASM WIT/spike | Contract/fixture reference | Zag E3 is planned with its own WIT/runtime/capability Gates; old runtime is not reused as production code |

## Reduced delivery DAG

```text
M0 — interaction reliability
  cli-sigint-001
        │
        ▼
M1 — core Harness controls
  harness-events-001
        │
        ├────► harness-steering-001
        └────► session-fork-001
                       │
                       ▼
M2 — selected daily UX
  skills-001       edit-sharpness-001
        └──────────────┬──────────────┘
                       ▼
                 tui-minimal-001
```

C4–C9 remain domain labels. They no longer imply that every listed feature (Oracle, Graph, Memory, MCP, dashboard, full sandbox, etc.) must ship.

## Immediate task contracts

### `cli-sigint-001`

- Idle direct-binary REPL: first Ctrl+C exits cleanly with code 0 and no runtime error.
- Active run: first Ctrl+C requests cooperative cancellation; interactive mode remains usable if cancellation lands.
- A second Ctrl+C while cancellation is still pending hard-exits with conventional code 130.
- Headless cancellation remains governed by `headless-v1` (exit 11 when observed).
- The direct `zag` binary is contractual; `zig build run` parent-process-group behavior is documented but not normalized.
- No claim of mid-flight Tool/shell or std-HTTP active interruption.

### `harness-events-001`

Define a stable public lifecycle vocabulary before adding UI: message start/delta/end, Tool start/update/end, run start/terminal. Preserve one truthful terminal and map — do not serialize — internal events into headless output.

### `harness-steering-001`

Bounded steering and follow-up queues with deterministic insertion points, ownership, cancellation, and transcript/session/trace evidence. No executable subagent or Graph runtime.

### `session-fork-001`

Branch/fork semantics over the existing safe session contract. No silent migration, redaction loss, lock bypass, or mutation of the parent session.

## Deferred until evidence

- repo map and LLM summary upgrades;
- Oracle/subagents/Graph;
- process supervisor and OS sandbox;
- hooks/MCP/executable extensions;
- ACP/dashboard;
- Memory Repo;
- provider/auth breadth;
- performance/startup/size claims.

## Documentation impact

This decision updates `vision.md`, `architecture.md`, `packaging.md`, `roadmap.md`, C4–C9 phase descriptions, references, and the active task index. Historical assessments remain frozen evidence and are not rewritten.
