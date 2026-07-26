# Module: extensions

| Item | Content |
|------|---------|
| Status | runtime extensions L0 / not implemented; trusted static Zig composition is SDK L2 |
| Stage | [C8](../phases/C8-extensions.md) |
| Decision | [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Reference | Current Pi semantics; historical `pi-mono-zig` process host/WIT as read-only design archive |

## Extension tiers

| Tier | Surface | Current |
|------|---------|---------|
| E0 trusted static Zig | compile-time Provider/Toolset/Observer/policy composition | **available** through SDK-ready contract |
| E1 passive package | `SKILL.md` and later prompt metadata | planned `skills-001` |
| E2 runtime executable | long-lived child over `zag-ext-v1` | deferred until process-supervisor Gate + real consumer |
| Research | capability-gated WASM/component host | no commitment |

Dynamic `.so`/`.dylib` Zig/C ABI and embedded Lua/QuickJS/Bun runtimes are non-goals.

## Invariants

1. Imported Tools use [D-007](../decisions/active/D-007-tool-runtime-descriptor.md) descriptors and the same permission/containment/trace path as built-ins.
2. Missing/unknown capability metadata fails closed; tool names never infer risk.
3. Manifest capabilities are claims. Only host/OS/WASM enforcement can bound executable behavior.
4. Hooks may deny but cannot weaken permission, containment, shell, sandbox, redaction, or terminal truth.
5. Static Zig extension code is trusted same-process code; SDK construction does not imply sandboxing.
6. Executable children are group/job owned, output-bounded, cancelled, killed, and reaped by a process supervisor.
7. Process isolation is not an OS sandbox. Untrusted native code requires a required enforcement profile.
8. Extensions cannot directly mutate canonical transcript/session/trace or private Agent memory.
9. UI is declarative data rendered by the host; no extension renderer/component pointer enters the process.
10. No stable Zig dynamic plugin ABI is promised.

## E1 passive package

The first runtime-discoverable surface is `SKILL.md` only:

- documented global/project roots and deterministic precedence;
- lexical + realpath/symlink-aware containment at discovery;
- validated frontmatter/name/description;
- per-file and aggregate prompt budget;
- deterministic conflict diagnostics;
- explicit disable; disabled/no-Skill mode behavior-neutral;
- no executable, environment, provider, hook, UI, or network privilege。

## E2 `zag-ext-v1`

Independent versioned stdio NDJSON protocol. Minimum frames:

```text
handshake → manifest → ready

tool_invoke → tool_delta* → exactly one tool_result | error
cancel
shutdown → shutdown_complete
```

Protocol properties:

- explicit version/feature negotiation;
- bounded manifest/frame/body/stderr;
- stdout protocol purity;
- structured diagnostics/errors;
- call ID correlation and one terminal per invoke;
- cooperative cancel followed by supervisor escalation;
- redaction before host persistence/output。

Hooks/commands/declarative UI are later negotiated capabilities, not minimum v1 requirements.

## Tool shim

An extension Tool becomes an ordinary product `Tool` only after:

1. parse/version/size checks;
2. `ToolDefinition` + `ToolCapabilities` validation;
3. duplicate/behavior-version policy;
4. construction of an in-process shim handler;
5. insertion into a stable Toolset before the run starts。

The shim serializes invocation, waits for the bounded terminal, maps errors to canonical soft Tool results, and lets `loop.run` retain host authority.

## Hook authority

| Hook result | Host result |
|-------------|-------------|
| deny | deny |
| allow + host allow | allow |
| allow + host deny | deny |
| permitted data modification | revalidate, then run mandatory host gates |
| timeout/crash/invalid response | fail closed per hook contract |

Runtime-installed hooks are E2 executable extensions and require the supervisor. Trusted static hooks may be designed after lifecycle events without C7.

## Declarative UI

Allowed future intents: notify/status/progress/select/confirm/input/markdown/diff/list. The host controls rendering, focus, redaction, cancellation, and availability. UI messages are side channels; they cannot replace Tool or run terminals.

Pi-style arbitrary custom components, message renderers, terminal input handlers, header/footer factories, and host-memory mutation are intentionally unsupported.

## Process and sandbox boundary

Before E2:

- process group/job ownership;
- bounded stdout/stderr and frame parsing;
- ready/tool/hook/shutdown deadlines;
- cancel → TERM → KILL → reap;
- minimal explicit environment; no inherited secret map;
- crash/timeout backfill preserving truthful Agent/session/trace outcome。

Before untrusted native E2:

- required OS sandbox profile;
- constructive filesystem/network/env escape tests;
- no enforcement downgrade。

WASM, if ever selected, has a separate Gate for runtime, host imports, memory/CPU budget, trap handling, and provenance. “WASM” alone is not a security claim.

## Acceptance ladder

### E0 (closed)

- external consumer composes stateful custom Tools/Provider/Observer/policy/session;
- ownership and fail-closed descriptor tests pass。

### E1

- Skill discovery/budget/conflict/disable/symlink fixtures pass;
- no executable path exists。

### E2 (future)

- manifest lacking capabilities rejected before run;
- extension Tool follows permission/jail/shell/trace path;
- crash, malformed frame, OOM, output overflow, timeout and cancel have bounded structured outcomes;
- child and descendants are reaped;
- untrusted mode fails closed when sandbox is unavailable;
- plain/headless/TUI correctness remains equivalent。

## Non-goals

- Pi/npm package-manager compatibility or marketplace;
- Bun/TypeScript compatibility host;
- TS-RPC wire compatibility;
- dynamic shared-library ABI;
- arbitrary extension-rendered TUI components;
- full WASM platform without a concrete use case;
- executable extensions before process ownership。
