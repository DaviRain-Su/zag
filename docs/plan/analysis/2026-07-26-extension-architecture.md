# Zig-native extension architecture

Date: 2026-07-26

Decision: [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md)

## Question

How can Zag offer Pi-like extensibility without embedding JavaScript, promising an unstable native ABI, or losing a portable third-party extension target?

## Pi behavior reference

Current Pi dynamically loads TypeScript/JavaScript through `jiti`. Extensions register Tools, lifecycle handlers, commands, shortcuts, flags, providers, session operations, and arbitrary TUI components/renderers. npm/git/local packages bundle extensions, Skills, prompts, and themes.

The transferable value is the semantic surface and drop-in ergonomics. jiti/npm/closure/renderer execution is TypeScript-specific trusted in-process code.

## Historical Zig reference

`DaviRain-Su/pi-mono-zig@9d1f78c` explored:

| Shape | State | Zag use |
|-------|-------|---------|
| Bun/TS child + process JSONL | implemented/exercised | process lifecycle/protocol fixture reference |
| generic process JSONL | implemented host path | E2 design reference; fix bounds/security/complexity |
| native Zig/C ABI | template/draft, no complete host | reject |
| WASM/WIT | manifest/WIT + spike, no production general runtime | E3 contract/fixture starting reference, not implementation |

## Options

| Mechanism | Strength | Material cost | Decision |
|-----------|----------|---------------|----------|
| Build-time static Zig | type/ownership clarity; existing SDK | recompile; trusted same-process | **E0** |
| `.so`/`.dylib` | runtime loading/low call overhead | unstable ABI/layout/allocator; host crash/platform drift | **reject** |
| Long-lived child | any language; allocator/crash isolation; OS integration | IPC/supervisor; not sandbox | **E2 compatibility binding** |
| WASM Component/WIT | portable package; host-mediated capabilities; no Host pointers | runtime/toolchain/TCB/size/debug | **E3 planned preferred third-party binding** |
| Embedded script VM | script ergonomics/hot reload | VM/GC/dependency/language lock-in; duplicate mechanism | **reject** |

## Chosen architecture

```text
user feature surface
  Extension / Skill / Prompt / Theme / Package / Model / Provider / SDK / RPC / JSON / UI
                                      ×
common zag-ext-v1 executable semantics
  ├─ E0 static Zig (SDK-native types)
  ├─ E2 process binding (NDJSON)
  └─ E3 WASM binding (WIT Component)

E1 Skills/Prompt Templates/theme data are passive resources.
Runtime Package is a bundle over E1/E2/E3; E0 source distribution remains build-time only.
```

E2 and E3 share manifest/Tool/capability/result meanings, not wire bytes. Optional hooks/commands/Provider/UI require separate host contracts and need not appear in the first binding version.

## Common semantics

- extension ID/version/behavior version;
- bounded manifest;
- `ToolDefinition` + D-007 `ToolCapabilities`;
- invoke ID + args + optional progress + exactly one result/error;
- cancel/lifecycle/diagnostics;
- optional hook/command/resource/declarative UI capabilities;
- opaque session/run namespace and private-state policy。

Host validation protects the Zag path. Manifest claims do not constrain E2 native behavior; E3 constraints exist only through denied/mediated host imports.

## E2 process binding

```text
handshake → manifest → ready

tool_invoke → tool_delta* → result|error
cancel
shutdown → shutdown_complete
```

Prerequisite C7.1: process group/job, checked stdout/stderr/frame bounds, startup/invoke/shutdown deadline, cancel→TERM→KILL→reap, minimal environment, structured crash/backfill.

E2 is for MCP/existing native programs/system integration. Trusted local use does not claim sandbox. Untrusted/downloaded native use requires C7.2 OS enforcement.

## E3 WASM binding

### Common WIT shape

`extension-wasm-contract-001` defines a Zag-owned `zag:extension@1` world. It starts with manifest and Tool invoke/result; progress/cancel are bounded host calls/resources. JSON may remain inside Tool arguments/results initially, but lifecycle and errors are typed/versioned at the component boundary.

The old `pi-tool-v0.wit` is a provenance-tracked behavior fixture, not the public Zag WIT.

### Default capability surface

No unrestricted WASI by default:

- no preopened workspace/home;
- no inherited environment/secrets;
- no network/socket;
- no process spawn;
- no wall clock/random unless explicitly justified。

Initial imports are narrow: cancellation check, bounded progress/log, and later host-mediated workspace operations. Workspace imports accept relative paths and execute through Zag guard/policy; the guest never gets a raw directory handle that bypasses the contract.

### Resource model

Mandatory regardless of engine:

- component/module/manifest limits;
- memory/table/stack bounds;
- fuel or epoch/time interruption;
- output/progress/concurrency bounds;
- deterministic trap/OOM/timeout/cancel mapping;
- no raw Host pointer/allocator/session path/renderer/secret。

### Runtime selection Gate

Do not pick an engine in the architecture decision. `extension-wasm-runtime-001` compares candidates with reproducible evidence:

- Component Model/WIT support/conformance;
- Zig 0.16 integration and macOS/Linux builds;
- license/maintenance/security updates;
- deterministic metering/interruption;
- binary-size/startup/RSS cost;
- trap and unsafe/C-boundary behavior;
- in-process versus supervised-helper quarantine。

A heavy or unsafe runtime belongs behind an adapter/helper so `zag-agent-core` never imports engine types. No performance/size claim before measurement.

### Packaging/trust

Initial E3 artifact: bounded manifest + component + deterministic digest/source provenance. A runtime bundle may combine that artifact with E1 resources and optional E2 entries; it never contains E0 source composition as a hot-installable tier. Local explicit install only. Enable/disable/quarantine is host-owned. Signature, remote registry, updater, and supply-chain policy form a later independent Gate. Credentials are never package content.

## Tool and hook authority

E2/E3 shims enter a stable Toolset only after parse/version/size/D-007/duplicate checks. `loop.run` remains the permission/jail/shell/trace owner.

```text
hook deny              → deny
hook allow + host deny → deny
hook modify            → revalidate + mandatory host gates
runtime failure        → fail closed / structured Tool result
```

Runtime-installed hooks use E2/E3. Trusted static hooks can arrive after lifecycle events without C7.

## UI compatibility

Runtime UI starts with declarative intents (notify/status/progress/select/confirm/input/markdown/diff/list/table/tree). A later separately gated view/action protocol may let E2/E3 code retain private state, receive sanitized actions, and return bounded view trees. Host owns renderer, raw terminal input, focus, layout, accessibility, redaction, cancellation, and availability. No arbitrary ANSI, native component factory, renderer pointer, or terminal writer crosses E2/E3. E0 trusted product code may add native host components at compile time.

## Delivery map

```text
M0–M2 Harness route
  events → Skills → Prompt Templates → minimal TUI

Programmatic surface
  public events/control/session → rpc-v1

Extension foundation
  extension-schema-001
  process-supervisor-001
  extension-process-001
  extension-ui-schema-001 (basic intents first)

WASM platform (planned)
  extension-wasm-contract-001
  extension-wasm-runtime-001
  extension-wasm-capabilities-001
  extension-wasm-package-001
  later feature worlds (hooks/commands/Provider/UI) by separate Gates
```

The extension track follows M0–M2 sequencing; it is a formal target but does not inflate current L0 maturity.

## Security summary

- E0 static code is trusted Host code.
- E1 is data-only but still prompt-injection/path/budget sensitive.
- E2 process is crash isolation, not sandbox.
- E3 is safer only with narrow host imports and enforced quotas.
- Native untrusted code needs OS enforcement; WASM runtime/host are part of the TCB.

## Documentation impact

D-010 updates vision, architecture, packaging, C7/C8, extensions, roadmap, maturity, and task verification. No engine/package/code is added by this docs task.
