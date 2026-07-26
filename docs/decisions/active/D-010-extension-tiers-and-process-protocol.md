---
status: active
id: D-010
title: Extensions use static Zig composition, passive packages, and a versioned process protocol
date: 2026-07-26
---

# D-010 — Extension tiers and process protocol

## Decision

Zag supports extensibility through three deliberately different tiers:

| Tier | Mechanism | Trust / lifecycle |
|------|-----------|-------------------|
| E0 | **Trusted static Zig composition** through the existing SDK (`Toolset`, Provider, Observer, policy) | compiled with the host; same process; already covered by the SDK-ready Gate |
| E1 | **Passive packages** (`SKILL.md`, later prompt metadata) | runtime discovery; data only; no executable privilege |
| E2 | **Runtime executable extension** as a long-lived child process speaking versioned `zag-ext-v1` over stdio | language-neutral; process-owned; only after process-supervisor Gate |

WASM/component extensions are a future research option only when an actual untrusted-extension use case justifies a runtime and host-capability surface.

Zag will not provide a `.so`/`.dylib` Zig plugin ABI or embed Lua/QuickJS/Bun merely to load extensions.

## Why

Pi’s TypeScript extension experience depends on in-process runtime loading (`jiti`), JavaScript closures, npm dependencies, and arbitrary UI component factories. Copying that mechanism would reintroduce a script VM and host-memory mutation into a Zig product.

A process protocol preserves the valuable semantics — tools, lifecycle hooks, commands, diagnostics, cancellation, and declarative interaction — while making language runtime, allocator ownership, crashes, and protocol compatibility explicit.

## Current coverage

E0 is not future work: `sdk-contract-001` already proves stateful custom Toolset, Provider, Observer, policy, cancellation, and session composition. It is a trusted source-composition extension surface, not a runtime plugin system.

E1 begins with `skills-001` after the Harness event/control work.

E2 is not scheduled until a real runtime-extension consumer appears and C7’s process-supervisor slice passes.

## `zag-ext-v1` boundary

`zag-ext-v1` is independent from `headless-v1`. They share design discipline — explicit version, NDJSON framing, bounded bodies, stdout protocol purity, structured errors — but serve opposite directions.

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

Hooks/commands/declarative UI are negotiated optional capabilities, not v1 prerequisites.

## Manifest and Tool enforcement

Every registered Tool supplies both:

- model-visible `ToolDefinition`;
- runtime-only D-007 `ToolCapabilities`.

The host validates the manifest and constructs an ordinary Zag `Tool` shim. `loop.run` still performs the normal permission → workspace → shell-policy → execution path. Missing/invalid descriptors reject registration.

A manifest is still only a **claim**. It cannot prevent an executable process from reading files, network, environment, or spawning children by itself. Host-side process/OS enforcement is what turns claims into bounds.

## Trust and sandbox truth

- Process separation gives crash and allocator isolation; it is **not an OS sandbox**.
- Trusted local executable extensions may be considered only after bounded process ownership (group/job, stdout/stderr, deadline, cancel, TERM→KILL, reap).
- Downloaded/untrusted native extensions additionally require a required OS-enforcement profile; no silent downgrade.
- WASM is not automatically safe: safety depends on a small host-import capability surface and resource limits.
- Static Zig extensions share host privileges and memory. They are trusted code, equivalent to the embedding application.

## Hooks

Trusted static hooks may follow the stable lifecycle event contract without C7. Runtime-loaded executable hooks are E2 and require the process supervisor.

A hook may deny or make an explicitly permitted data transformation. It may never weaken Tool risk, permission, workspace, shell, sandbox, redaction, or terminal-truth requirements. `allow` cannot override a host denial.

## UI boundary

Zag intentionally does not copy Pi’s arbitrary extension-authored renderer/component API.

Extensions may request host-rendered declarative interactions such as:

- notify/status/progress;
- select/confirm/input;
- markdown/diff/list payloads.

The host owns rendering, redaction, input focus, and whether the surface is available. UI side-channel messages cannot replace Tool/result or run terminal semantics.

## State and secrets

- Extensions cannot directly mutate the canonical transcript, session file, trace, or private Agent memory.
- Host events expose only the documented, redacted view.
- Private extension state uses a namespaced product-owned root when that contract is designed; no raw session path is required.
- Child processes inherit no full environment by default. Secret/env grants are explicit process-supervisor policy.

## Packaging and discovery

The first E2 delivery, if triggered, accepts explicit local manifests/paths only. It does not include a marketplace, npm-compatible installer, silent auto-update, or package-manager parity.

No `zag-hooks`, `zag-mcp`, `zag-wasm`, or extension-host package is created until code ownership pressure exists. Protocol types belong at L0 only when an implementation task consumes them.

## Legacy reference

The historical `pi-mono-zig@9d1f78c` process-JSONL host, manifest/diagnostics, and process lifecycle are design/fixture references. Its Bun compatibility host is not a Zag dependency. Its native C ABI was draft/unimplemented, and its WASM host was not production-complete.

Any imported source/fixture follows D-009 provenance rules.

## Release ladder

1. **E0 (closed):** trusted static Zig source composition.
2. **E1:** passive Skills with jailed discovery, budget, conflict, disable, and no-execute fixtures.
3. **Events first:** versioned lifecycle events; optional trusted static deny-only hooks may then be designed.
4. **Supervisor:** bounded child lifecycle; still no sandbox claim.
5. **E2:** trusted local `zag-ext-v1` process extension.
6. **Required OS enforcement:** prerequisite for untrusted native extensions.
7. **WASM research:** only after a concrete untrusted portable-extension need and runtime budget.

## Consequences

- Pi-like runtime extensibility is achievable without embedding JavaScript or freezing a Zig ABI.
- Runtime extension breadth is deliberately later than Skills/events and cannot bypass C7.
- Declarative host-rendered UI is an intentional compatibility difference from Pi.
- Extensions never weaken the closed Phase H, SDK, or Headless contracts.

## Related

- [D-007 Tool runtime descriptor](./D-007-tool-runtime-descriptor.md)
- [D-008 SDK/process boundaries](./D-008-sdk-and-process-boundaries.md)
- [D-009 Pi semantics, not parity](./D-009-pi-semantics-not-parity-fork.md)
- [extensions module](../../modules/extensions.md)
- [C7](../../phases/C7-sandbox.md)
- [C8](../../phases/C8-extensions.md)
- [extension architecture analysis](../../plan/analysis/2026-07-26-extension-architecture.md)
