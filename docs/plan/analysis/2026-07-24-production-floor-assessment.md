# Phase H production-floor assessment — 2026-07-24

| Item | Result |
|------|--------|
| Status | **Accepted planning baseline** |
| Scope | Design, roadmap, current implementation, Kernel SDK boundary, product shell |
| Baseline | Local `main` on 2026-07-24 |
| Delivery rule | Correctness before capability breadth |

> **Historical snapshot:** findings below describe the accepted pre-task baseline. Current completion truth lives in [the task index](../README.md) and [maturity](../../maturity.md); completed items are not reopened by this preserved assessment record.

## Verdict

Zag should keep **Zig 0.16** and the **All-in-One product × reusable Kernel** direction. The package layering is real and the implementation has a strong tutorial/engineering baseline, but the current product is **not production-ready and not SDK-ready**.

The accurate maturity statement is:

> Phase H has landed substantial loop, edit/search, built-in permission, context/session schema, provider, and trace foundations. Production-floor exit is still blocked by fail-open tool policy, workspace symlink escape, unsafe session recovery/persistence, false-success trace state, incomplete compaction accounting, redaction, timeout/cancellation, and public SDK contract gaps.

Passing existing tests proves the checked baseline is stable; it does not prove failure-path correctness.

## Evidence record

Validated locally before this document was accepted:

- `zig build test --summary all`: 26/26 build steps, 111/111 tests.
- `zig build test -Dhttp_backend=curl --summary all`: passed.
- Every package's independent tests and the root build passed.
- An external temporary Zig consumer compiled and ran `zag-agent-core` with a custom Provider, stateless Tool, and Observer.
- Focused fault fixtures reproduced session overwrite, swallowed save failure, false-success trace finalization, a mutating custom tool bypassing the deny gate, workspace symlink escape, and incomplete second-stage compaction accounting.

Evidence boundaries:

- No claim is made about Zig binary size, startup time, cross-compilation advantage, or migration cost to another language.
- No paid/live provider call was used as production evidence.
- Oh My Pi and Hyper/Grok Build were inspected from local primary-source snapshots. Their mechanisms are references, not requirements to copy wholesale.

## Priority meanings

These are **delivery priorities**, not vulnerability severity labels.

| Priority | Meaning |
|----------|---------|
| **P0** | Blocks Phase H correctness now; can lose data, cross a declared boundary, bypass approval, or make audit state false. No capability work should pass this queue. |
| **P1** | Required before Phase H or the immediately following SDK/headless gates can close; sequence after P0. |
| **P2** | Capability, optimization, packaging, or ecosystem work that must not destabilize P0/P1 contracts. |

## P0 — correctness and boundary blockers

| ID | Boundary | Failure | Current evidence | Exit sentence |
|----|----------|---------|------------------|---------------|
| **P0-SESSION** | Session open/save | `continue_existing` converts I/O, invalid data, and unsupported schema into a new transcript that retains the same path; save can overwrite the prior file. Save is an in-place truncate and `Agent.reply` hides failure. | `zag-coding-agent/src/agent.zig`; `zag-agent-core/src/session_store.zig` | Explicit create and resume modes fail deterministically; a failed save preserves the prior file and is observable; a second writer receives a conflict/busy error. |
| **P0-TOOL** | Tool registration/permission | Risk is inferred from built-in names. A registered mutating custom tool with an unknown name defaults to `read` and bypasses dangerous-tool denial. | `zag-agent-core/src/permissions.zig` | Every registered tool carries mandatory runtime capabilities; policy consumes the descriptor; missing capability fails closed. |
| **P0-WORKSPACE** | File-tool containment | Jail validation is lexical. A workspace symlink can resolve outside the workspace and built-in file tools follow it. | `zag-agent-core/src/workspace.zig`; coding-agent file tools | Read/write/search through an escaping symlink is denied by real filesystem containment checks. |
| **P0-TRACE** | Run lifecycle/audit | Provider failure returns `ProviderFailed`, but `Agent.deinit` can finalize the open trace as `ok=true`, `completed`; trace flush errors are also hidden. | `zag-coding-agent/src/agent.zig`; `zag-agent-core/src/trace.zig` | Every started run has exactly one truthful terminal event; provider/save/trace failures are structured and observable. |

### P0 contract decisions

- Session: [D-006](../../decisions/active/D-006-session-open-and-durability.md)
- Tool runtime descriptor: [D-007](../../decisions/active/D-007-tool-runtime-descriptor.md)
- SDK/process boundaries: [D-008](../../decisions/active/D-008-sdk-and-process-boundaries.md)

## P1 — production-floor and SDK/headless gates

| ID | Boundary | Gap | Exit sentence |
|----|----------|-----|---------------|
| **P1-CONTEXT** | Context/view | A second trim after summary/layer growth does not update `CompactionEvent.dropped` or rebuild the summary, so the event cannot explain the final model view. | Returned accounting covers every message excluded from that view and transcript remains unchanged. |
| **P1-REDACT** | Sensitive output | Systematic secret redaction is absent from verbose, trace, and session paths. | Secret fixtures never appear in verbose output, trace, or session output. |
| **P1-DEADLINE** | Provider/tool lifecycle | std HTTP stores but does not enforce `timeout_ms`; cancellation is checked between turns/tools and cannot stop an in-flight provider/stream/tool call. | Configured deadlines are enforced or explicitly rejected; cancellation reaches provider and cancellable tools; incomplete tool calls never execute. |
| **P1-TRACE-SCHEMA** | Observability | Trace has no schema version and Observer lacks a stable run/turn lifecycle contract. | Trace schema is versioned and terminal/error semantics are fixed by contract tests. |
| **P1-SDK** | Zig source SDK | Low-level composition works, but Tool handlers lack instance state and high-level Agent cannot accept caller toolset/observer. Ownership and compatibility commitments are not documented. | An external consumer test uses a stateful custom Tool, Provider, Observer, policy, cancellation, and session path through supported APIs. |
| **P1-HEADLESS** | Process SDK/automation | One-shot CLI exists, but structured JSON/events, stable errors, and stable exit codes do not. | JSON stdout is machine-clean and auth/session/save/cancel failures have documented structured errors and exit codes. |

### 2026-07-25 planning corrections

Post-module composition and exit audits found three planning omissions without changing the original assessment evidence:

1. H5 already required a doctor/readiness report, but the task DAG had no owner. [h-doctor-001](../tasks/h-doctor-001.md) now owns a provider/API-key-independent, fixed/path-free control report and is complete.
2. h-provider-001 delivered provider deadline/active cancellation and partial-stream Tool safety. It does **not** implement preemption of an already running Tool/shell handler. H integration verifies cancellation **between** accepted Tools; mid-flight handler/process ownership and process-tree cleanup remain explicit post-H process-supervisor work.
3. After the original h-integration composition evidence passed independent review and both main backend suites, the sentence-by-sentence H exit audit found that synchronous shell timeout/output-limit/process outcomes, total result budget, direct-child cleanup evidence, and shell trace reconstruction still had no task owner. [h-shell-001](../tasks/h-shell-001.md) now owns that P1 gate. Integration retains its verified evidence but remains blocked for final closeout until shell lands.

P1 does not authorize semver publication. SDK publication requires the independent gate in [packaging.md](../../packaging.md).

## P2 — capability and deferred work

| ID | Work | Constraint |
|----|------|------------|
| **P2-SANDBOX** | OS sandbox + process supervisor | Product/runtime capability, not Kernel ABI. It must precede claims of higher autonomy and any background/untrusted executable extension. Unsupported enforcement must be visible and fail closed for modes that require it. |
| **P2-EDIT** | C4 edit sharpness/change review | May start after H correctness; does not depend on Memory or Graph. |
| **P2-CONTEXT** | C5.1 repo map/fork | May proceed after session/compaction contracts; Memory Repo remains later and default-off. |
| **P2-ORCHESTRATION** | C6 Oracle/subagents/Graph | Read-only Oracle can follow stable event/cancel/session contracts; full executable subagents require process ownership and safety policy. |
| **P2-EXTENSIONS** | Skills/hooks/MCP | Passive Skills may arrive earlier; executable hooks/MCP require ToolCapabilities, process protocol, and permission/sandbox policy. |
| **P2-PRODUCT** | TUI/dashboard | Headless is an earlier gate; TUI remains late and must not move loop logic into product UI. |
| **P2-PACKAGING** | Repo split/C ABI/dynamic plugin ABI | Do not start until there is a second consumer, independent tests, a release channel, and a stable source contract. Cross-language use prefers a versioned process protocol. |
| **P2-BENCH** | Performance/cross-build evidence | Measure before making Zig performance, startup, size, or cross-compilation claims. |

## Dependency DAG

```text
P0 failure fixtures + contracts
  ├─ session open/save/concurrency
  ├─ tool descriptor + fail-closed permission ─► filesystem containment selection
  └─ truthful run/trace terminal state
        │
        ▼
P1 Phase H closeout
  ├─ compaction accounting
  ├─ redaction
  ├─ provider timeout + in-flight cancellation
  ├─ versioned trace/events
  ├─ doctor/readiness
  └─ synchronous shell runtime/observability
        │
        ▼
  real-composition final Gate
        │
        ├────────► SDK-ready gate ─────► source-package publication decision
        ├────────► headless/process protocol gate ─► ACP/editor integration later
        ├────────► C4 edit sharpness
        ├────────► C5.1 repo map/fork (after session/context)
        └────────► sandbox + process supervisor
                              ├────────► background jobs
                              ├────────► executable MCP/hooks
                              └────────► full executable subagents

Later: Memory Repo · Graph · TUI · full LSP/AST · repo split
```

This is a dependency graph, not a mandatory single-thread sequence. C4, C5.1, and sandbox work can overlap after their contracts are stable.

## Implementation task map

| Priority | Task | Objective |
|----------|------|-----------|
| P0 | [h-session-001](../tasks/h-session-001.md) | Safe create/resume, atomic save, visible failure, exclusive writer |
| P0 | [h-tool-runtime-001](../tasks/h-tool-runtime-001.md) | Stateful Tool + mandatory runtime descriptor + fail-closed permission |
| P0 | [h-workspace-001](../tasks/h-workspace-001.md) | Symlink-aware file-tool containment |
| P0 | [h-trace-001](../tasks/h-trace-001.md) | Truthful unique terminal event and trace I/O errors |
| P1 | [h-context-001](../tasks/h-context-001.md) | Complete second-stage compaction accounting |
| P1 | [h-provider-001](../tasks/h-provider-001.md) | Enforced deadlines and in-flight cancellation |
| P1 | [h-redact-001](../tasks/h-redact-001.md) | Shared secret redaction at persistence/log boundaries |
| P1 | [h-doctor-001](../tasks/h-doctor-001.md) | Provider-independent readiness/control truth |
| P1 | [h-shell-001](../tasks/h-shell-001.md) | Stable synchronous shell outcomes, body budget, direct-child cleanup, and trace evidence |
| P1 | [h-integration-001](../tasks/h-integration-001.md) | Retain verified Agent composition chains and perform final Phase H closeout after shell |
| P1 | [sdk-contract-001](../tasks/sdk-contract-001.md) | External stateful consumer and public ownership/event contract |
| P1 | [headless-001](../tasks/headless-001.md) | Stable structured process interface |

## Stop-doing until P0/P1 close

- Do not claim production-ready, Phase H complete, or SDK-ready.
- Do not add Graph, Memory Repo, TUI, full LSP/AST, or background jobs to Kernel contracts.
- Do not add provider/catalog breadth without a current user requirement.
- Do not freeze semver, split repositories, or promise a Zig dynamic ABI.
- Do not treat lexical jail, a green happy-path suite, or package separation as production evidence.

## Benchmark-derived rules

- Borrow Oh My Pi's lifecycle and cancellation semantics, not its entire event/product surface.
- Borrow Hyper's typed runtime capabilities and product-level sandbox/headless boundaries, not its crate count.
- Physical append-only session storage is optional. The required behavior is explicit open semantics, preservation on failure, atomic update, and conflict prevention.
- OS sandbox belongs to a runner/process-supervisor boundary. Kernel contracts express policy and capabilities; platform enforcement stays outside the provider/message ABI.
