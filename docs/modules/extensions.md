# Module: extensions

| Item | Content |
|------|---------|
| Status | runtime extensions L0; E0 trusted static Zig composition is SDK L2 |
| Stage | [C8](../phases/C8-extensions.md) |
| Decision | [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Feature research | [Pi feature correspondence](../plan/analysis/2026-07-26-pi-feature-correspondence.md) |
| Reference | Current Pi semantics; historical `pi-mono-zig` process host/WIT as read-only archive |

## Two orthogonal axes

Pi names user-facing customization/programmatic features. Zag's E0-E3 tiers name execution and trust boundaries. They are not the same taxonomy.

```text
feature surface
  Extension / Skill / Prompt Template / Theme / Package
  Custom Model / Custom Provider
  SDK / RPC / JSON / TUI + UI
                                  ×
carrier and trust
  host built-in / E0 static Zig / E1 passive resource
  E2 supervised process / E3 WASM Component
```

A feature may use several carriers. A Package is a bundle above E1/E2/E3, not another tier.

## Functional correspondence

| Pi surface | Zag outcome | Carrier / state |
|------------|-------------|-----------------|
| Extension | selected Tools/events/commands/flags/shortcuts/providers/session/UI through a common vocabulary | E0 available in part; E2/E3 planned incrementally |
| Skill | bounded `SKILL.md` discovery, prompt summary/on-demand load, disable/manual-only behavior | E1 **done** `skills-001` @ `caafef5` — binding [skills.md](./skills.md); maturity still L0 |
| Prompt Template | deterministic `/name` prompt expansion with explicit non-recursive substitution | E1 **done** `prompt-templates-001` @ `61326ae` — binding [prompt-templates.md](./prompt-templates.md); maturity still L0 |
| Theme | passive theme data rendered by the host product shell | binding [theme.md](./theme.md) / [theme-001](../plan/tasks/theme-001.md) (**contract PASS** @ `9e1b9f9`; `status: ready`; dual re-reviews zero blockers; **no** implementation; owner `zag-tui` only) |
| Package | local manifest bundling E1 resources and optional E2/E3 artifacts | package schema/trust Gates planned |
| Custom Model | validated model metadata/configuration without executable behavior | static catalog exists; runtime catalog unplanned |
| Custom Provider | trusted Zig Provider plus later process/WASM runtime registration | E0 SDK L2; E2/E3 L0 |
| SDK | same-process Zig composition | L2 closed |
| JSON | `headless-v1` one-shot result/event output | L2 closed at `a1a1e0f` |
| RPC | long-lived bidirectional Zag-native process control | **implemented** @ `0eeef5d` (`--rpc`); closeout pending; independent of `headless-v1` |
| TUI/UI | host TUI plus host-rendered runtime extension UI | minimal TUI **done** @ `f8f7f55` ([tui-minimal.md](./tui-minimal.md)); runtime extension UI L0 |

This is functional correspondence, not Pi API/schema/CLI/package-manager parity.

## Extension tiers

| Tier | Surface | Current |
|------|---------|---------|
| E0 trusted static Zig | compile-time Provider/Toolset/Observer/policy and later native host UI | **available in part** through SDK-ready contract |
| E1 passive resource | `SKILL.md`, Prompt Templates, later theme data | `skills-001` E1 Skills slice done @ `caafef5` ([skills.md](./skills.md)); `prompt-templates-001` E1 Prompt Templates slice done @ `61326ae` ([prompt-templates.md](./prompt-templates.md)); Theme **contract PASS** @ `9e1b9f9` ([theme.md](./theme.md) / `theme-001` ready; host-shell owner; **no** implementation); maturity still L0 |
| E2 process adapter | `zag-ext-v1` semantics over NDJSON | planned after C7.1 + real process consumer |
| E3 WASM Component | `zag-ext-v1` semantics over Zag WIT | **planned preferred portable third-party executable tier** |

Dynamic Zig/C shared-library ABI and embedded Lua/QuickJS/Bun runtimes are non-goals.

## Common invariants

1. Imported Tools use D-007 descriptors and the same permission/containment/trace path as built-ins.
2. Missing/unknown capability metadata fails closed; Tool names never infer risk.
3. Manifest capabilities are requests/claims, not enforcement.
4. Hooks may deny but cannot weaken permission, containment, shell, sandbox, redaction, or terminal truth.
5. Extensions cannot directly mutate canonical transcript/session/trace or private Agent memory.
6. Runtime UI is host-rendered; no raw terminal, arbitrary ANSI, renderer/component pointer, allocator, or Host pointer crosses E2/E3.
7. Runtime failure becomes a bounded structured outcome and cannot invent success.
8. No stable Zig dynamic plugin ABI is promised.
9. Passive resources have no loader execution privilege, but their content can induce normal Tool execution; host Tool gates still apply.
10. Credentials, OAuth tokens, ambient auth, and raw secrets are host-owned and are never distributable package content.

## Common `zag-ext-v1` model

`zag-ext-v1` is a language-neutral feature vocabulary, not one wire format and not a promise that every binding supports every feature in its first release.

Core entities:

- versioned manifest and extension identity;
- Tool definitions + runtime capabilities;
- invoke ID, arguments, progress, exactly one result/error;
- cancellation and shutdown/lifecycle;
- diagnostics, quotas, redaction, and opaque state namespace.

Optional entities, each requiring its own host contract and Gate:

- lifecycle notification and middleware hooks;
- commands, flags, and shortcuts;
- Provider registration;
- session/message requests;
- declarative UI requests, render descriptions, and later view/action state.

E2 NDJSON and E3 WIT need semantic correspondence, not identical bytes.

## E0 trusted static Zig

E0 is source-level composition, not runtime plugin loading.

- The SDK already composes stateful custom Tools, Providers, Observer, policy, cancellation, and sessions.
- Future trusted lifecycle hooks follow the public event contract.
- A future host TUI may expose a native Zig component API to trusted product code.
- Adding/changing E0 code requires a rebuild and places that code in the same trust/crash/allocator domain as Zag.

E0 is not installed by a runtime extension package.

## E1 passive resources

### Skills

The first runtime-discoverable resource is `SKILL.md`. Binding product contract:
**[skills.md](./skills.md)** (`skills-001`, done @ `caafef5`; Runtime Extensions L0). Summary:

- Agent Skills v1 roots: user `$HOME/.agents/skills/<name>/SKILL.md` (CLI HOME /
  SDK host-owned user-root) and project `<workspace>/.agents/skills/...` only with
  explicit trust; default skills on, project untrusted; `--no-skills` disables both;
- project resources gated by explicit project trust (independent of `--no-project`);
- realpath/symlink-aware containment at discovery; no recursive walk; byte-sorted
  direct children; project overrides user by exact name;
- line-oriented frontmatter subset; per-file and aggregate budgets; path-free soft
  diagnostics; OOM hard-fail before durable create;
- Session-owned in-memory catalog (never persisted); resume re-discovers; fork
  deep-copies; model-invocable summaries only in a view-only Skills system layer;
- `read_skill` + manual `/skill:<name>` activation; no loader execute privilege.

A passive Skill can still instruct the model to invoke shell/edit/read Tools against bundled scripts or assets. Those calls use the ordinary permission, workspace containment, shell-policy, and redaction path. Content review is a trust concern; the resource loader is not a sandbox.

### Prompt Templates

Prompt Templates are a separate E1 resource, not a synonym for Skills.
Binding product contract: **[prompt-templates.md](./prompt-templates.md)**
(`prompt-templates-001` **done** at `61326ae`; Runtime Extensions L0).
Summary:

- deterministic non-recursive discovery of direct `*.md` files under user and
  optional trusted project `.agents/prompts/`;
- after valid parse, **project overrides user** by exact command name (replaces
  any earlier first-wins sketch across roots);
- explicit one-pass non-recursive substitution (`$ARGUMENTS` / `$$` only);
- `/name` expansion owned by the product command/input layer via public coding-agent
  API; CLI is thin explicit routing only; no TUI/autocomplete in this slice;
- no execution privilege; no model summary; no catalog/read Tool.

Exact budgets, routing precedence with `/skill:`, and fixtures are binding in
the module doc — not accidental.

### Theme and model data

- Theme data is passive; ANSI generation, terminal capability detection, focus, invalidation, and hot reload are host-shell behavior.
- Binding: **[theme.md](./theme.md)** (`theme-001` **contract PASS** @ `9e1b9f9`; `status: ready`; dual re-reviews zero blockers; **no** implementation; **no** maturity raise). Unique owner **`packages/zag-tui`**; Core/coding-agent must not gain Theme types/ports/state/discovery. Fail closed to built-in host Theme; Theme documents must not contain raw ANSI/escape or executable content. Orthogonal to post-TUI remote Gate (TARGET `f352b60…`; Phase A; no Phase B grant/run/green).
- Custom Model metadata is validated host configuration. Auth material is stored separately. A runtime model catalog is not required for E1 Skills/Prompt delivery and does not require WASM.

## Runtime package bundle vs. E0 source distribution

| Property | E0 Zig source dependency | Runtime extension bundle |
|----------|--------------------------|--------------------------|
| Trust point | compile time | install/enable time |
| Distribution | Zig source / `build.zig.zon` / monorepo | manifest + content + digest/provenance |
| Execution | same-process trusted Host | E1 data; E2 process; E3 capability-mediated component |
| Hot install | no; rebuild required | possible only after the tier Gate |
| Contents | E0 only | E1 resources plus optional E2/E3 artifacts; never E0 |
| Lifecycle owner | build system / SDK consumer | host trust/enable/disable/quarantine |

Initial runtime packages are explicit local paths only. Remote registry, signing, reproducible acquisition, dependency resolution, and updater policy require a separate supply-chain Gate.

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
- D-007 shim composition into a stable Toolset before run.

Process isolation is not a sandbox. Trusted local E2 may ship after C7.1 with that honest claim. Downloaded/untrusted native E2 additionally requires C7.2 required OS enforcement.

E2 is the preferred compatibility path for MCP, existing programs, OAuth/browser/keychain/cloud integrations, and other OS behavior that cannot or should not be expressed through narrow WASM host imports.

## E3 WASM Component binding

E3 is a formal target, not optional research. It is the preferred eventual portable executable format. The first host is deliberately smaller than the final platform.

### Staged surface

```text
E3.1 manifest + Tool metadata + invoke/result
  → E3.2 progress/cancel/metering + host-mediated workspace capabilities
  → E3.3 optional hooks/commands/declarative UI after common contracts stabilize
  → E3.4 local package/trust/disable/quarantine
```

Provider behavior and stateful UI are later worlds/tasks. The compute-only Tool Gate is the starting point, not the permanent E3 ceiling.

### Contract

A Zag-owned WIT world maps the common model into component exports/imports. V1 starts narrow:

- manifest/Tool metadata;
- invoke → result/error;
- bounded progress and cancellation checks;
- structured diagnostics.

No unrestricted WASI filesystem/network/environment/process capability exists by default.

### Host capabilities

Future imports are added one capability at a time:

- workspace read/list/write through Zag guard/policy;
- progress/log/notify through bounded redacted host APIs;
- monotonic deadline/cancel observation;
- optional network/model/secret-use only after dedicated policy and adversarial Gates.

Requested capability absent from the host grant → the guest cannot call it. Broad preopened directories, inherited environment, raw sockets, full WASI, keychain access, and process spawn are forbidden defaults.

### Resource and failure contract

- checked component/package/manifest size;
- memory/table/stack/fuel or epoch/time budget;
- bounded output and invocation concurrency;
- trap/invalid UTF-8/invalid result/OOM/timeout/cancel → structured Tool failure;
- no Host pointer/allocator/session path/trace writer/renderer/secret;
- unsafe/heavy runtime may run behind a supervised helper.

### Engine Gate

`extension-wasm-runtime-001` selects an engine only after measuring/checking:

- Component Model/WIT support and conformance;
- Zig 0.16 build/link and macOS/Linux support;
- license, maintenance, and security-update path;
- deterministic resource limits and interruption;
- binary-size/startup/RSS impact;
- trap isolation and C/unsafe boundary;
- in-process versus supervised-helper quarantine.

No engine is selected by this spec, and no WASM performance/security claim exists before that Gate.

## Tool and Provider shims

For E2/E3, a Tool enters the active registry only after:

1. parse/version/size checks;
2. `ToolDefinition` + `ToolCapabilities` validation;
3. duplicate/behavior-version policy;
4. binding-specific shim construction;
5. stable Toolset insertion before run.

The shim maps invocation/results into canonical bounded outcomes while `loop.run` retains host authority.

Custom Provider correspondence is split:

- E0: current trusted Zig Provider/WireAdapter composition;
- data-only Custom Model: host configuration/passive metadata;
- E2: OS/network/auth/provider integrations;
- E3: future portable Provider behavior only through a separately gated WIT world with host-mediated network/model/secret-use capabilities.

Runtime Provider registration never imports wire types into Kernel.

## Hook authority

| Hook result | Host result |
|-------------|-------------|
| deny | deny |
| allow + host allow | allow |
| allow + host deny | deny |
| permitted modification | revalidate, then run mandatory host gates |
| timeout/trap/crash/invalid response | fail closed per hook contract |

Trusted static hooks may follow lifecycle events after that event contract stabilizes. Runtime hooks use E2/E3 and require their tier plus hook-specific ordering, timeout, mutation, and fallback Gates.

## Extension UI

Host-rendered does not mean non-extensible. Runtime code can control behavior and describe UI while the host owns terminal safety.

### UI v1

- notify/status/progress;
- select/confirm/input;
- markdown/diff/list/table/tree Tool or message views;
- deterministic plain/headless fallback.

### Later stateful view/action protocol

A separate Gate may let E2/E3 code:

- keep extension-private UI state;
- return a bounded declarative view tree;
- receive sanitized action IDs and approved focus requests;
- return a new tree/state after an action.

The host still owns rendering, redaction, layout, terminal input, focus, accessibility, cancellation, and availability.

### Never across E2/E3

- raw stdin/terminal bytes;
- arbitrary ANSI/escape sequences;
- renderer/widget/allocator pointers;
- untrusted native component factories;
- direct replacement of permission/session/trace truth.

E0 trusted product code may provide native components at compile time. Pi's arbitrary in-process TypeScript component mechanism is not copied.

## Programmatic boundaries

| Entrance | Contract |
|----------|----------|
| Zig SDK | same-process source composition; L2 closed |
| `headless-v1` JSON | one-shot result/event output; L2 closed; not bidirectional RPC |
| future `rpc-v1` | long-lived correlated commands/responses/events; separate protocol and Gate |
| TUI | host product shell over public events/control; no Kernel UI dependency |

Runtime extension UI may project over TUI and future RPC, but it never changes `headless-v1` terminal truth.

## Acceptance ladder

### E0 (closed scope)

- external consumer composes stateful custom Tools/Provider/Observer/policy/session.

### E1 Skills

Binding checklist lives in [skills.md §11](./skills.md#11-verification--exact-fixture-matrix-14).
Implementation fixtures green (`skills_tests.zig` + SDK smoke); maturity still L0:

- [x] discovery/budget/conflict/disable/manual-only/symlink fixtures;
- [x] project trust ordering;
- [x] no loader execution path;
- [x] downstream Tool calls still pass permission/containment/shell/redaction;
- [x] catalog lifetimes (start OOM, fork, resume) + `read_skill` + activation.

### E1 Prompt Templates

Exact matrix: [prompt-templates.md §11](./prompt-templates.md#11-verification--exact-fixture-matrix).
Implementation fixtures green (`prompt_templates_tests.zig` + SDK smoke); maturity still L0:

- [x] non-recursive discovery and one-pass substitution (`$ARGUMENTS` / `$$`);
- [x] project-override collision (not first-wins across roots);
- [x] `/skill:` precedence + known `/name` expand + unknown slash raw;
- [x] no-execute neutrality; induced Tools still gated;
- [x] start OOM / fork catalog / resume rediscovery / CLI+SDK routes.

### E2

- supervisor lifecycle/output/cancel/reap;
- protocol negotiation and one invoke terminal;
- D-007/permission/containment/redaction/trace composition;
- untrusted mode refuses missing sandbox.

### E3

- WIT/component conformance fixtures independent of engine;
- engine Gate with measured footprint/support/security evidence;
- no-WASI-default escape fixtures;
- memory/fuel/time/output/cancel/trap matrix;
- host-mediated capability denial and path containment;
- package digest/provenance/disable/quarantine;
- plain/headless/TUI correctness equivalence for each exposed feature.

### Runtime UI

- malformed/oversized views rejected;
- action/focus IDs cannot capture raw input or bypass redaction;
- unavailable UI has deterministic plain/JSON/RPC fallback;
- UI failure cannot invent Tool/run success.

## Non-goals

- Pi/npm package-manager compatibility or marketplace;
- Bun/TS host or Pi RPC byte/API parity;
- dynamic shared-library ABI;
- raw-terminal extension access across E2/E3;
- unrestricted WASI defaults;
- executable extensions before process/runtime ownership Gates;
- claiming every Pi extension event/UI method in the first protocol version.
