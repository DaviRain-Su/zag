---
status: active
id: D-010
title: Extensions use static Zig, passive resources, process adapters, and a planned WASM component tier
date: 2026-07-26
---

# D-010 — Extension tiers and bindings

## Decision

Zag supports extensibility through four deliberately different tiers:

| Tier | Mechanism | Role |
|------|-----------|------|
| E0 | **Trusted static Zig composition** via existing SDK (`Toolset`, Provider, Observer, policy) | built-in/embedded extensions; same process; compile-time composition |
| E1 | **Passive resources** (`SKILL.md`, Prompt Templates, later theme data) | runtime discovery without loader execution privilege |
| E2 | **Native process adapter** using a versioned stdio binding | compatibility with MCP/existing executables/system integrations; trusted local code after process supervision |
| E3 | **WASM Component extension** using a versioned WIT binding | planned preferred format for portable installable third-party Zag extensions |

These tiers classify **execution and trust**, not user features. The user-facing correspondence surface is orthogonal: Extension, Skill, Prompt Template, Theme, Package, Custom Model, Custom Provider, SDK, RPC, JSON, and TUI/UI. A Package is a bundle above E1/E2/E3, not another tier; Custom Model data is distinct from executable Custom Provider behavior; SDK, RPC, JSON, and TUI remain separate product entrances.

Zag will not provide a `.so`/`.dylib` Zig plugin ABI or embed Lua/QuickJS/Bun merely to load extensions.

E3 is a roadmap commitment, not a current implementation/maturity claim. Runtime selection and capability-host implementation remain gated tasks.

## Why

Pi’s TypeScript extension experience depends on in-process runtime loading (`jiti`), JavaScript closures, npm dependencies, and arbitrary UI component factories. Copying that mechanism would reintroduce a script VM and host-memory mutation.

The four tiers preserve Pi-like extensibility while matching each trust/use case:

- E0 keeps maximum Zig type/ownership power for trusted embedders;
- E1 makes common prompt workflows drop-in and safe;
- E2 connects ecosystems that cannot or should not compile to WASM;
- E3 gives Zag a portable, capability-mediated distribution target without freezing a native ABI。

Process and WASM remain separate bindings. Not every MCP/server/OS integration can become WASM, and WASM should not inherit unrestricted OS access merely to imitate a process.

## Current coverage

E0 is already covered by `sdk-contract-001`: stateful custom Toolset, Provider, Observer, policy, cancellation, and session composition.

E1 begins with `skills-001` (binding module [skills.md](../../modules/skills.md); **done** at `caafef5`; Runtime Extensions remains L0), then a separately specified Prompt Template surface. Theme data follows the host TUI; a runtime Custom Model catalog is a distinct validated configuration task, not executable extension code. Passive resources carry no loader execution privilege, but their content may still induce ordinary Tool/shell calls, which remain subject to permission, containment, shell policy, and redaction.

E2 begins only after a real process-extension consumer and C7.1 process-supervisor Gate.

E3 is planned after the common extension semantic contract exists. It has its own contract, runtime-selection, capability, resource, packaging, and adversarial Gates.

## Common `zag-ext-v1` semantics

`zag-ext-v1` names the language-neutral **semantic model**, not one wire format. It defines:

- extension identity/version and manifest bounds;
- Tool definitions + D-007 capabilities;
- invoke/progress/result/error correlation;
- cancellation and lifecycle;
- optional hooks, commands, flags, shortcuts, Provider registration, session/message requests, and declarative UI;
- diagnostics, redaction, state namespace, and resource outcomes。

This is a vocabulary, not a promise that every binding supports every feature in v1. Each optional surface requires an owning host contract, capability grant, fallback behavior, and binding conformance Gate.

Bindings:

| Binding | Representation |
|---------|----------------|
| E2 process | versioned stdio NDJSON (`zag-ext-process-v1`) |
| E3 WASM | versioned Component Model/WIT world (`zag:extension@1`) |

Both map into the same host Tool/event contracts. They need semantic parity, not byte parity.

## E2 process binding

Minimum lifecycle:

```text
host → handshake
ext  → manifest
ext  → ready

host → tool_invoke
ext  → tool_delta *
ext  → exactly one tool_result | error

host → cancel
host → shutdown
ext  → shutdown_complete
```

Process stdout is protocol-only; diagnostics use bounded stderr. The supervisor owns group/job, frame/output bounds, deadlines, cancel, TERM→KILL, and reap.

Process isolation gives crash/allocator isolation but **is not an OS sandbox**. Downloaded/untrusted native extensions additionally require C7.2 required OS enforcement with no downgrade.

## E3 WASM Component binding

The planned WASM tier uses a Zag-owned WIT contract rather than the old Pi WIT unchanged.

V1 design constraints:

- component exports manifest/ready and Tool invoke/result operations;
- progress and cancellation use bounded host functions/resources defined by the WIT task;
- no unrestricted WASI filesystem, network, environment, clocks, or process spawn by default;
- workspace operations, if added, are host-mediated capabilities and re-use Zag path/permission enforcement;
- memory, table, stack, fuel/epoch/time, output, and concurrent-invoke limits are explicit;
- guest trap/invalid result becomes structured Tool failure and cannot invent run success;
- guest never receives Host allocator pointers, session paths, trace writers, renderer objects, or raw secrets。

WASM is not automatically safe. The runtime, WIT imports, WASI configuration, resource metering, and host implementation form the trusted computing base.

If the chosen runtime introduces a large/unsafe dependency, it should be quarantined behind an adapter or supervised helper. `extension-wasm-runtime-001` decides in-process versus helper-process placement from measured/security evidence; Kernel remains independent of the engine.

## Manifest and Tool enforcement

Every registered Tool supplies:

- model-visible `ToolDefinition`;
- runtime-only D-007 `ToolCapabilities`;
- behavior/protocol version and requested extension capabilities。

The host validates the manifest and constructs an ordinary Zag Tool shim. `loop.run` still performs permission → workspace → shell-policy → execution. Missing/invalid descriptors reject registration.

A manifest is only a **request/claim**:

- E2 native processes can exceed it unless OS enforcement constrains them;
- E3 guests can exercise only granted WIT/WASI host imports, but a broad import surface would defeat the model;
- hook `allow` never overrides host denial。

## Hooks

Trusted static hooks may follow stable lifecycle events without C7. Runtime-loaded hooks use E2 or E3 and require their tier Gate.

A hook may deny or perform an explicitly permitted data transformation. It may never weaken risk, permission, workspace, shell, sandbox, redaction, or terminal truth. Modified data is revalidated.

## UI boundary

Zag intentionally does not copy Pi’s arbitrary extension-authored renderer/component API.

Runtime UI is staged:

1. UI v1: notify/status/progress, select/confirm/input, and markdown/diff/list/table/tree Tool or message views;
2. a later separately gated stateful view/action protocol may let E2/E3 code keep UI state, receive sanitized action IDs, and return a new declarative view tree;
3. E0 trusted static Zig product code may supply native host components at compile time.

The host always owns rendering, redaction, terminal input, focus, layout, accessibility, and availability. Raw terminal bytes, arbitrary ANSI, renderer pointers, and untrusted native component factories never cross E2/E3. This is full correspondence for host-rendered interaction scenarios, not Pi's in-process TypeScript component mechanism. UI side channels cannot replace Tool or run terminals.

## State, packaging, and secrets

- Extensions cannot directly mutate transcript/session/trace/private Agent memory.
- Host events expose documented redacted data only.
- E2 children inherit a minimal explicit environment, not the full host environment.
- E3 receives no environment/secrets except named host grants.
- Initial E2 accepts explicit local manifests/paths only.
- E0 Zig source distribution is a compile-time dependency and never a runtime-installed bundle artifact.
- A runtime package manifest may declare E1 resources plus optional E2/E3 artifacts; it never installs E0 code.
- E3 package format is planned as manifest + component + deterministic hash/provenance; signing/remote registry requires a later supply-chain Gate.
- Model metadata may be packaged as validated data, but credentials, OAuth tokens, and ambient auth are host-owned and never distributable package content.
- No marketplace, silent updater, or npm parity is implied。

## Legacy reference

The historical `pi-mono-zig@9d1f78c` process-JSONL host, manifest/diagnostics, `pi-tool-v0.wit`, and fixtures are design references. Its Bun host is not a Zag dependency; native C ABI was draft/unimplemented; general WASM runtime was not production-complete.

Zag writes its own versioned process/WIT contracts. Imported fixtures follow D-009 provenance rules.

## Release ladder

1. **E0 (closed):** trusted static Zig source composition.
2. **E1:** passive Skills, then Prompt Templates (jail/budget/conflict/disable/no loader execution).
3. **Common semantics:** lifecycle events plus `zag-ext-v1` manifest/capability model.
4. **C7.1:** process supervisor.
5. **E2:** trusted local process binding; C7.2 additionally gates untrusted native code.
6. **E3.1 `extension-wasm-contract-001`:** WIT/component/package contract and conformance fixtures.
7. **E3.2 `extension-wasm-runtime-001`:** measured engine selection + quarantined minimal host + compute-only Tool.
8. **E3.3 `extension-wasm-capabilities-001`:** host-mediated workspace/progress/cancel capabilities, metering, adversarial escape/trap tests.
9. **E3.4 packaging:** local install/trust/disable/quarantine/provenance; remote distribution only after supply-chain Gate.
10. **Later E3 feature worlds:** hooks, commands, Provider behavior, and stateful declarative UI only through separate semantic/capability/fallback Gates; the Tools-only first host is not the permanent E3 ceiling。

## Consequences

- Pi-like user capabilities are mapped independently from TypeScript-specific loading mechanics.
- Process is the compatibility/system-integration path; WASM is the planned portable third-party executable path.
- Passive resources, runtime bundles, model data, executable Providers, SDK/RPC/JSON, and TUI/UI remain distinct contracts.
- Extension UI is host-rendered; later stateful declarative views do not grant raw terminal ownership.
- WASM runtime code remains quarantined from Kernel types and cannot become a premature performance/security claim.
- Extensions never weaken closed Phase H, SDK, or Headless contracts.

## Related

- [D-007 Tool runtime descriptor](./D-007-tool-runtime-descriptor.md)
- [D-008 SDK/process boundaries](./D-008-sdk-and-process-boundaries.md)
- [D-009 Pi semantics, not parity](./D-009-pi-semantics-not-parity-fork.md)
- [extensions module](../../modules/extensions.md)
- [C7](../../phases/C7-sandbox.md)
- [C8](../../phases/C8-extensions.md)
- [extension architecture analysis](../../plan/analysis/2026-07-26-extension-architecture.md)
- [Pi feature correspondence](../../plan/analysis/2026-07-26-pi-feature-correspondence.md)
