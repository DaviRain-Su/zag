# Module: extensions

| Item | Content |
|------|---------|
| Status | runtime extensions L0; E0 trusted static Zig composition is SDK L2 |
| Stage | [C8](../phases/C8-extensions.md) |
| Decision | [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Reference | Current Pi semantics; historical `pi-mono-zig` process host/WIT as read-only archive |

## Extension tiers

| Tier | Surface | Current |
|------|---------|---------|
| E0 trusted static Zig | compile-time Provider/Toolset/Observer/policy | **available** through SDK-ready contract |
| E1 passive package | `SKILL.md`, later prompt metadata | planned `skills-001` |
| E2 process adapter | `zag-ext-v1` semantics over NDJSON | planned after C7.1 + real process consumer |
| E3 WASM Component | `zag-ext-v1` semantics over Zag WIT | **planned final portable third-party extension tier** |

Dynamic Zig/C shared-library ABI and embedded Lua/QuickJS/Bun runtimes are non-goals.

## Common invariants

1. Imported Tools use D-007 descriptors and the same permission/containment/trace path as built-ins.
2. Missing/unknown capability metadata fails closed; tool names never infer risk.
3. Manifest capabilities are requests/claims, not enforcement.
4. Hooks may deny but cannot weaken permission, containment, shell, sandbox, redaction, or terminal truth.
5. Extensions cannot directly mutate canonical transcript/session/trace or private Agent memory.
6. UI is declarative data rendered by the host; no renderer/component pointer crosses a boundary.
7. Runtime failure becomes a bounded structured outcome and cannot invent success.
8. No stable Zig dynamic plugin ABI is promised.

## Common `zag-ext-v1` model

Both executable bindings expose the same semantic entities:

- versioned manifest and extension identity;
- Tool definitions + runtime capabilities;
- invoke ID, arguments, progress, exactly one result/error;
- cancellation and shutdown/lifecycle;
- optional hooks, commands, resources, and declarative UI;
- diagnostics, quotas, redaction, and opaque state namespace。

E2 NDJSON and E3 WIT need semantic parity, not identical bytes.

## E1 passive package

The first runtime-discoverable surface is `SKILL.md`:

- documented global/project roots and deterministic precedence;
- lexical + realpath/symlink-aware containment at discovery;
- validated frontmatter/name/description;
- per-file and aggregate prompt budget;
- deterministic conflict diagnostics;
- explicit disable; disabled/no-Skill mode behavior-neutral;
- no executable/environment/provider/hook/UI/network privilege。

## E2 process binding

```text
handshake → manifest → ready

tool_invoke → tool_delta* → exactly one tool_result | error
cancel
shutdown → shutdown_complete
```

Before E2:

- process group/job ownership;
- bounded stdout/stderr/frame parsing;
- ready/invoke/shutdown deadlines;
- cancel → TERM → KILL → reap;
- minimal explicit environment;
- crash/timeout/malformed/output-overflow fixtures;
- D-007 shim composition into a stable Toolset before run。

Process isolation is not a sandbox. Trusted local E2 may ship after C7.1 with that honest claim. Downloaded/untrusted native E2 additionally requires C7.2 required OS enforcement.

## E3 WASM Component binding

E3 is planned, not optional research. It is the preferred eventual installable third-party Zag extension format.

### Contract

A Zag-owned WIT world maps the common model into component exports/imports. V1 starts narrow:

- manifest/Tool metadata;
- invoke → result/error;
- bounded progress and cancellation checks;
- structured diagnostics。

No unrestricted WASI filesystem/network/environment/process capability by default.

### Host capabilities

Future host imports are added one capability at a time:

- workspace read/list/write through Zag guard/policy;
- progress/log/notify through bounded redacted host APIs;
- monotonic deadline/cancel observation;
- optional network/model calls only after dedicated policy/Gates。

Requested capability absent from the host grant → guest cannot call it. Broad preopened directories/full WASI environment are forbidden defaults.

### Resource and failure contract

- checked component/package/manifest size;
- memory/table/stack/fuel or epoch/time budget (engine-dependent but mandatory);
- bounded output and invocation concurrency;
- trap/invalid UTF-8/invalid JSON/OOM/timeout/cancel → structured Tool failure;
- no Host pointer/allocator/session path/trace writer/renderer/secret by default;
- runtime panic/bug risk considered in engine placement; unsafe/heavy engine may run behind a supervised helper。

### Engine Gate

`extension-wasm-runtime-001` selects an engine only after measuring/support-checking:

- Component Model/WIT support and conformance;
- Zig 0.16 build/link and macOS/Linux support;
- license, maintenance/security-update path;
- deterministic resource limits and interruption;
- binary-size/startup/RSS impact;
- trap isolation and C/unsafe boundary;
- in-process versus supervised-helper quarantine。

No engine is selected by this spec, and no WASM performance/security claim exists before that Gate.

## Tool shim

For E2/E3, a Tool enters the active registry only after:

1. parse/version/size checks;
2. `ToolDefinition` + `ToolCapabilities` validation;
3. duplicate/behavior-version policy;
4. binding-specific shim construction;
5. stable Toolset insertion before run。

The shim maps invocation/results into canonical soft Tool outcomes while `loop.run` retains host authority.

## Hook authority

| Hook result | Host result |
|-------------|-------------|
| deny | deny |
| allow + host allow | allow |
| allow + host deny | deny |
| permitted modification | revalidate, then run mandatory host gates |
| timeout/trap/crash/invalid response | fail closed per hook contract |

Trusted static hooks may follow lifecycle events without C7. Runtime hooks use E2/E3 and require their tier Gate.

## Declarative UI

Allowed intents: notify/status/progress/select/confirm/input/markdown/diff/list. Host owns rendering, focus, redaction, cancellation, and availability. UI messages never replace Tool/run terminals.

Pi-style arbitrary custom components/renderers/input handlers are intentionally unsupported.

## Packaging

- Initial E2: explicit local manifest/path only; no marketplace/silent updater.
- Initial E3: local manifest + component + deterministic digest/provenance; explicit trust/enable/disable/quarantine.
- Remote registry/signing/reproducible package acquisition requires a separate supply-chain Gate.
- Private extension state needs a documented namespace/quota/lifecycle and cannot use raw session paths。

## Acceptance ladder

### E0 (closed)

- external consumer composes stateful custom Tools/Provider/Observer/policy/session。

### E1

- discovery/budget/conflict/disable/symlink fixtures;
- no executable path。

### E2

- supervisor lifecycle/output/cancel/reap;
- protocol negotiation and one invoke terminal;
- D-007/permission/containment/redaction/trace composition;
- untrusted mode refuses missing sandbox。

### E3

- WIT/component conformance fixtures independent of engine;
- engine Gate with measured footprint/support/security evidence;
- no-WASI-default escape fixtures;
- memory/fuel/time/output/cancel/trap matrix;
- host-mediated capability denial and path containment;
- package digest/provenance/disable/quarantine;
- plain/headless/TUI correctness equivalence。

## Non-goals

- Pi/npm package-manager compatibility or marketplace;
- Bun/TS host or TS-RPC parity;
- dynamic shared-library ABI;
- arbitrary extension-rendered TUI code;
- unrestricted WASI defaults;
- executable extensions before process/runtime ownership Gates。
