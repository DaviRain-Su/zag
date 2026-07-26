# Zig-native extension architecture

Date: 2026-07-26  
Decision: [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md)

## Question

How can Zag offer Pi-like extensibility without embedding a JavaScript runtime, promising an unstable Zig dynamic ABI, or treating manifest declarations as a sandbox?

## Pi behavior reference

Current Pi dynamically loads TypeScript/JavaScript with `jiti`. Its extension API can register Tools, lifecycle handlers, commands, shortcuts, flags, providers, session operations, and arbitrary TUI renderers/components. npm/git/local packages bundle extensions, Skills, prompts, and themes; reload invalidates old runtime contexts.

The transferable value is the **semantic extension surface and ergonomics**. The jiti/npm/in-process renderer mechanism is TypeScript-specific and trusted-host code execution.

## Historical Zig reference

`DaviRain-Su/pi-mono-zig@9d1f78c` explored four shapes:

| Shape | Historical state | Zag disposition |
|-------|------------------|-----------------|
| Bun/TS child + process JSONL | implemented and exercised | simplify as protocol/process-lifecycle reference only |
| generic process JSONL | implemented host path | useful reference; fix output/reap/security gaps |
| native Zig/C ABI | SDK/template/draft, no complete host | reject as Zag direction |
| WASM/WIT | manifest/WIT + spike; no production general runtime | future research only |

The old host already demonstrates handshake, registry frames, Tool request/result, diagnostics, shutdown, timeout, and process-group concepts. It also exposes why it cannot be copied wholesale: broad TS parity, large protocol/registry modules, unbounded stdout risk, partial enforcement, and complex multi-thread/process cleanup.

## Options

| Mechanism | Strength | Fatal or material cost | Decision |
|-----------|----------|------------------------|----------|
| Build-time static Zig | type/ownership clarity, fastest path, existing SDK | recompile; trusted same-process code | **E0 supported now** |
| `.so`/`.dylib` Zig plugin | runtime loading, low call overhead | unstable ABI/layout/allocator; host crash; platform differences | **Do not do** |
| Long-lived child process | language neutral, allocator/crash isolation, versioned protocol | IPC; process lifecycle; not a sandbox | **E2 runtime mechanism** |
| WASM/component/WIT | portable, host-import capability model, traps isolated | runtime/toolchain/size/debug; host surface is security-critical | **research only** |
| Embedded Lua/QuickJS/Bun | easy script authoring, hot reload | VM/GC/dependency/language lock-in; overlapping mechanism | **Do not do** |

## Chosen tiers

```text
E0 trusted static Zig
   existing SDK: Provider + Toolset + Observer + policy

E1 passive runtime package
   SKILL.md / prompt metadata; no code

E2 trusted runtime code
   executable child ⇄ zag-ext-v1 NDJSON ⇄ host Tool/event shims
   requires process supervisor

future untrusted code
   required OS sandbox for native process
   OR separately gated WASM host research
```

## `zag-ext-v1` minimum

### Transport

- long-lived stdio NDJSON;
- stdout is protocol-only; logs use bounded stderr;
- explicit protocol version and negotiated optional capabilities;
- checked maximum line/frame/body sizes;
- extension process owned by a supervisor, not an ad-hoc `Child` handle。

### Required frames

| Direction | Type | Contract |
|-----------|------|----------|
| host→ext | `handshake` | protocol versions, host capabilities, opaque run/session namespace |
| ext→host | `manifest` | extension identity/version + Tool definitions/capabilities |
| ext→host | `ready` | registration complete |
| host→ext | `tool_invoke` | call ID, name, args JSON, deadline/cancel token |
| ext→host | `tool_delta` | optional bounded progress |
| ext→host | `tool_result` | exactly one terminal per invoke |
| ext→host | `error` | exactly one terminal alternative |
| host→ext | `cancel` | cooperative request before process escalation |
| host→ext | `shutdown` | graceful process close |
| ext→host | `shutdown_complete` | close acknowledgment |

Hooks, commands, resources, and declarative UI are later negotiated capabilities. They do not inflate the minimum Tool protocol.

## Tool registration path

```text
extension manifest
  → parse/bound/version check
  → D-007 ToolDefinition + ToolCapabilities validation
  → product Tool shim
  → normal loop permission/jail/shell-policy path
  → IPC invoke
  → checked/redacted Tool body
  → transcript/session/trace
```

Unknown or missing capability rejects the extension registration. No tool-name risk inference.

This protects the host decision path, but does not constrain what the child process can do outside the protocol. A lying manifest remains possible without OS/WASM enforcement.

## UI compatibility choice

Pi permits arbitrary in-process UI factories. Zag intentionally exposes only declarative data:

- notification/status/progress;
- select/confirm/input;
- markdown/diff/list views.

The product shell renders or rejects the request. No extension renderer pointer, terminal writer, focus object, or host allocator crosses the boundary.

## Safety gates

### Before E1 Skills

- jailed/symlink-aware discovery;
- frontmatter/content/total budget;
- deterministic precedence/conflicts;
- disabled mode behavior-neutral;
- no environment/code execution。

### Before any E2 process extension

- process group/job ownership;
- checked stdout/stderr/frame budgets;
- deterministic ready/invoke/shutdown deadlines;
- cancel → TERM → KILL → reap;
- crash backfills pending invokes with structured failure;
- minimal explicit environment; no secret inheritance;
- direct-binary process fixtures on supported hosts。

### Before claiming untrusted native extensions

- required OS-enforcement profile with constructive escape tests;
- no unsupported/failed enforcement downgrade;
- explicit filesystem/network/env grants;
- install/trust/quarantine/update policy。

## Hooks

Static trusted hooks can follow the lifecycle event Gate without C7. Runtime-installed hooks are executable E2 and require the supervisor.

Host policy always has final authority:

```text
hook deny   → deny
hook allow  + host deny → deny
hook modify → revalidate affected data and run mandatory host gates
```

No hook may rewrite a failed/aborted terminal into success.

## State and ownership

- extensions never write canonical transcript/session/trace directly;
- host maps validated extension results/events into its own types;
- protocol payload ownership ends at serialization boundaries;
- opaque namespace replaces raw session path;
- private extension state requires a separately documented root/quota/lifecycle;
- full host environment is not inherited by default。

## Packaging UX

Initial E2, when triggered, should accept explicit local manifests/paths only. No package marketplace, silent updater, npm parity, or arbitrary remote install. Disable/quarantine means the extension is absent from the active registry and cannot receive invocations.

## Recommended sequence

1. retain E0 SDK composition;
2. implement lifecycle events;
3. implement E1 passive Skills;
4. only on a real extension consumer: process-supervisor Gate;
5. define/test minimum `zag-ext-v1` Tool protocol;
6. add hooks/commands/declarative UI one capability at a time;
7. evaluate WASM only from a concrete untrusted portability requirement。

## Documentation impact

D-010 updates vision, architecture, packaging, C7/C8, extensions module, roadmap, maturity wording, and active decisions. It does not create extension code, packages, or maturity claims.
