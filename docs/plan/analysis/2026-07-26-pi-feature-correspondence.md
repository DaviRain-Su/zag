# Pi feature correspondence for Zag

> Date: 2026-07-26
> Core question: Which user-visible customization and programmatic capabilities from current Pi should Zag correspond to, and what Zig-native carrier should implement each capability without copying TypeScript runtime mechanics?
> Exploration: 2 rounds complete; fresh post-Round-2 verifier PASS (11/11 dimensions COVERED, no blockers)

## Fixed sources

| Source | Snapshot | Role |
|--------|----------|------|
| Pi latest documentation | `https://pi.dev/docs/latest` on 2026-07-26 | documented user-facing contract |
| `earendil-works/pi` | `5bc1c2c0a6f07e00e8c240304182f213ab8d311f` | current source behavior; remote HEAD verified on 2026-07-26 |
| `DaviRain-Su/pi-mono-zig` | `9d1f78c509d10907e3dcf1e88f83fed4408db36e` | historical Zig design/fixture archive |
| Zag | `3eed657` plus `task/pi-alignment-001` docs | current contracts and planned direction |

External repositories were treated as untrusted, read-only data. Their code was not executed.

Supporting audits:

- [Round 1 Model/Provider](./2026-07-26-pi-feature-correspondence-round1-model-provider.md)
- [Round 2 Model/Provider closure](./2026-07-26-pi-feature-correspondence-round2-model-provider-closure.md)

## Decision frame

The correspondence target is **user capability**, not TypeScript API or implementation parity.

```text
Pi feature surface
  Extension / Skill / Prompt Template / Theme / Package
  Custom Model / Custom Provider
  SDK / RPC / JSON / TUI + extension UI
                                  ×
Zag carrier and trust
  host built-in / E0 static Zig / E1 passive resource
  E2 supervised process / E3 WASM Component
```

These axes are orthogonal:

- a Package is a bundle and trust unit, not an execution tier;
- a Custom Model is data, while a Custom Provider contains executable behavior;
- SDK, RPC, JSON, and TUI are different product/programmatic entrances;
- WASM is the preferred eventual portable executable carrier, not a container for every passive resource or OS integration.

## Feature correspondence matrix

| Pi feature | Pi user outcome | Zag functional target | Carrier | Current truth / Gate | Deliberate difference |
|------------|-----------------|-----------------------|---------|----------------------|-----------------------|
| Extension | Register Tools, lifecycle handlers, commands, flags, shortcuts, providers, session actions, messages, and UI | A common feature vocabulary delivered incrementally; host policy/session/trace authority remains mandatory | E0, E2, E3 | E0 Tool/Provider/Observer composition L2; runtime extensions L0 | No `jiti`, arbitrary TS execution, dynamic Zig ABI, or host-memory mutation |
| Skill | Discover reusable instructions, expose summaries, load `SKILL.md` on demand, optionally invoke manually | Bounded E1 discovery, precedence, trust, budget, disable/manual-only behavior, and downstream Tool enforcement | E1 + host Tool gates | `skills-001` planned | The loader never executes code, but Skill content may induce normal Tool/shell execution |
| Prompt Template | Expand `/name args` into reusable prompts | Explicit passive prompt resource with deterministic discovery, collision, and non-recursive substitution | E1 + host command router | Missing binding task; planned after shared E1 loader | Syntax may be smaller than Pi, but cannot be accidental or recursively substituted |
| Theme | Install/select presentation data, adapt to terminal capabilities, reload | Passive theme data plus host-owned terminal renderer | E1-style data + host shell | After minimal TUI | No ANSI/renderer capability crosses E2/E3 |
| Package | Install one bundle containing several extension resources and enable/disable them | Local runtime bundle manifest declaring E1 resources and optional E2/E3 artifacts; digest/provenance/trust/quarantine | Bundle layer above E1/E2/E3 | Schema/package Gates not started | E0 Zig source dependencies are build-time and never runtime-installed; no npm parity/marketplace |
| Custom Model | Add/override model metadata for a known API shape without code | Validated runtime model catalog/configuration, with auth stored separately | Host configuration / passive data | Current catalog is static E0; runtime catalog unplanned | Pure data does not require WASM; shell-command secret lookup may be omitted or isolated |
| Custom Provider | Add transport, streaming, auth, model discovery, and normalization | E0 custom Zig Provider; later runtime registration for portable/system integrations | E0; E2; E3 with narrow host imports | E0 custom Provider L2; runtime registration L0 | OAuth browser/keychain/ambient cloud credentials stay host/E2; E3 never gets broad raw OS access |
| SDK | Embed the Harness in-process and compose tools/providers/events/session/control | Zig source-composition SDK enriched by public lifecycle/control contracts | E0 | SDK-ready L2; events/steering/fork planned | Functional composition, not Node API or semver parity |
| RPC mode | Drive a long-lived child with correlated commands, responses, and events | Independent Zag-native `rpc-v1` after public events/control/session contracts | Product process protocol | Planned capability, not part of `headless-v1` | Minimal command set first; no Pi/TS-RPC byte or command parity |
| JSON mode | Run one prompt and consume structured result/events | Existing `headless-v1` `--json` and `--json-stream` | Product process output | Headless/Process L2 at `a1a1e0f` | Independent public schema; internal Observer/Trace unions are not serialized |
| TUI + extension UI | Reuse terminal components; show dialogs/status/widgets/tool views; build richer interactive views | Host TUI plus staged extension UI: basic intents, render descriptors, then optional stateful declarative view/action protocol | Host/E0; E2/E3 requests | Minimal TUI planned; extension UI L0 | No raw terminal, arbitrary ANSI, renderer pointer, or untrusted native component factory across E2/E3 |

## What Pi implements, and what transfers

### Extension core

Pi loads trusted TypeScript factories and populates an `ExtensionRunner`. The transferable part is the feature vocabulary and lifecycle:

- Tool definitions, progress, result/error terminality;
- ordered notification and middleware events;
- commands, flags, shortcuts, and provider registration;
- session operations and stale-context rules;
- dialogs, status, widgets, renderers, and richer TUI components.

Primary anchors:

- docs: `https://pi.dev/docs/latest/extensions`;
- types: `.references/pi/packages/coding-agent/src/core/extensions/types.ts`;
- loader: `.../extensions/loader.ts`;
- middleware/dispatch: `.../extensions/runner.ts:787-1220`;
- Tool interception: `.../core/agent-session.ts:460-517`;
- Provider request integration: `.../core/sdk.ts:303-348`.

Verified middleware examples:

- `tool_call` runs handlers in order; input mutations feed later handlers; the first block stops execution (`runner.ts:919-939`).
- `tool_result` accumulates partial patches through the chain (`runner.ts:864-916`).
- `context`, `before_provider_request`, `before_agent_start`, `message_end`, and `input` each have distinct replacement/transform rules (`runner.ts:972-1220`).

Zag should not promise this complete vocabulary in one release. `zag-ext-v1` is the common semantic namespace; each event/registration becomes supported only when its own host contract and binding tests exist.

### Passive resources

Pi Skills and Prompt Templates are passive files with different outcomes:

- Skill summaries enter context; full `SKILL.md` is read on demand; `/skill:name` can be manual.
- Prompt Templates expand slash commands with a specified non-recursive argument language.

Primary anchors:

- docs: `https://pi.dev/docs/latest/skills`, `https://pi.dev/docs/latest/prompt-templates`;
- Skills: `.references/pi/packages/coding-agent/src/core/skills.ts:160-365,384-484` and `agent-session.ts:1300-1322`;
- prompts: `.../core/prompt-templates.ts:55-100,105-170,188-285`.

"Passive" describes the loader. It does not make content harmless: Skill instructions may direct the model to run bundled scripts or mutate files through normal Tools. Zag's permission, containment, shell policy, and redaction remain the enforcement boundary for those downstream calls.

### Theme and Package

Pi Theme files are data; the host creates ANSI and owns invalidation/terminal capability detection. Pi Packages bundle executable extensions and passive resources. These are separate concepts.

Primary anchors:

- docs: `https://pi.dev/docs/latest/themes`, `https://pi.dev/docs/latest/packages`;
- theme: `.references/pi/packages/coding-agent/src/modes/interactive/theme/theme.ts:24-105,262-435,599-955`;
- package: `.../core/package-manager.ts:901-955,2084-2240`.

Zag must keep two meanings of "package" separate:

| Property | E0 Zig source dependency | Runtime extension bundle |
|----------|--------------------------|--------------------------|
| Trust time | compile time | install/enable time |
| Distribution | Zig source / `build.zig.zon` / monorepo | manifest + content + digest/provenance |
| Execution | same-process trusted host | E1 data; E2 process; E3 capability-mediated component |
| Hot install | no; rebuild required | possible after the tier Gate |
| Manifest membership | not a runtime artifact | may contain E1 plus optional E2/E3 artifacts |

### Custom Model and Custom Provider

Pi separates:

1. data-only model entries and overrides;
2. executable transport/auth/discovery behavior;
3. runtime register/unregister lifecycle.

Primary anchors:

- docs: `https://pi.dev/docs/latest/models`, `https://pi.dev/docs/latest/custom-provider`, `https://pi.dev/docs/latest/providers`;
- composition: `.references/pi/packages/coding-agent/src/core/provider-composer.ts:42-69,130-247,399-466`;
- lifecycle: `.../core/model-registry.ts:117-143`, `.../extensions/runner.ts:347-404`.

Zag already has the E0 equivalent of a trusted custom Provider. Its current model catalog cannot represent Pi's richer `compat`/`thinkingLevelMap` metadata; `generate_catalog.py --from-pi` intentionally projects only Zag's narrow fields. No runtime model file, OAuth, dynamic discovery, or runtime Provider registry is claimed.

E3 Provider support is post-foundation, not part of the initial compute-only Tool host. A future Provider world can expose host-mediated model/network/secret-use capabilities. OAuth browser/device-code flows, keychains, `!command` secret resolution, ambient cloud credentials, and callback listeners remain host/E2 concerns.

### Programmatic surfaces

Pi exposes four distinct projections over its session runtime:

```text
session runtime
  ├─ SDK: same-process ownership
  ├─ JSON: one-shot event output
  ├─ RPC: long-lived bidirectional JSONL control
  └─ TUI: interactive host shell
```

Primary anchors:

- docs: `https://pi.dev/docs/latest/sdk`, `https://pi.dev/docs/latest/rpc`, `https://pi.dev/docs/latest/json`, `https://pi.dev/docs/latest/tui`;
- SDK: `.references/pi/packages/coding-agent/src/core/agent-session.ts` and `agent-session-runtime.ts`;
- RPC: `.../modes/rpc/rpc-mode.ts`, `rpc-types.ts`, `jsonl.ts`;
- JSON: `.references/pi/packages/coding-agent/src/modes/print-mode.ts`;
- TUI: `.references/pi/packages/tui/src/tui.ts`.

Zag's mapping is deliberately not one API:

- Zig SDK-ready is already L2.
- `headless-v1` is already L2 and remains one-shot/output-only.
- `rpc-v1` is a later, separate, long-lived bidirectional protocol.
- TUI is a host product shell over public events/control, not a Kernel dependency.

## UI correspondence boundary

Pi's UI surface itself has two levels:

- RPC UI is already data-oriented: dialogs and fire-and-forget status/widget requests; custom component factories are unavailable.
- TUI UI can run arbitrary trusted TS component factories, render ANSI, replace the editor, and receive terminal input.

Zag should classify correspondence explicitly:

| Coverage | Pi scenarios | Zag mechanism |
|----------|--------------|---------------|
| Full functional target | dialogs, notify/status/progress, Tool/result cards, message/entry views, forms, panels, overlays, bounded actions | E0 native host API or E2/E3 declarative requests/view tree + sanitized action events |
| Safe reduced first release | select/confirm/input, status/progress, markdown/diff/list/table/tree render descriptors | UI v1 host-rendered intents with plain/headless fallbacks |
| Later separately gated | stateful declarative view trees, focus requests, editor-like controls, extension-maintained UI state | E2/E3 executable behavior receives sanitized actions and returns a new tree; host still owns focus/input/redaction |
| Deliberate non-correspondence | raw terminal byte access, arbitrary ANSI, direct renderer pointers, untrusted native component factories | never crosses E2/E3; E0 trusted product code only |

A declarative tree is not limited to static UI. E2/E3 code can maintain state, receive host-filtered actions, and return a new tree. This can correspond to many Pi custom views without exposing terminal internals. It still does not grant raw stdin, arbitrary escape sequences, or Host widget pointers.

Initial extension UI stops at the safe reduced release. Stateful view/action support needs a separate schema, focus/input/redaction/accessibility tests, and deterministic plain/JSON/RPC fallbacks.

## WASM role

The historical Zig port's WASM v0 was Tools-only. That is feasibility evidence for a small first host, not a permanent Zag product limit.

Zag's staged E3 target is:

```text
E3.1 manifest + Tool metadata + invoke/result
  → E3.2 metering/cancel/progress/host-mediated workspace capabilities
  → E3.3 optional hooks/commands/declarative UI bindings after common semantics stabilize
  → E3.4 local package/trust/quarantine
```

Provider bindings and stateful UI are later worlds/tasks, not implied by E3.1. E2 remains the compatibility and OS-integration path. E3 remains the preferred eventual portable third-party executable format.

## Delivery implications

The near-term Harness route remains focused:

```text
cli-sigint-001
  → harness-events-001
      ├→ harness-steering-001
      └→ session-fork-001
  → skills-001 → prompt-templates-001
  → edit-sharpness-001 + tui-minimal-001
```

Later programmatic and extension tracks:

```text
public events/control/session
  ├→ rpc-v1
  ├→ extension-schema-001
  │    ├→ process-supervisor-001 → extension-process-001 (E2)
  │    └→ extension-wasm-contract-001
  │          → extension-wasm-runtime-001
  │          → extension-wasm-capabilities-001
  │          → extension-wasm-package-001 (E3)
  ├→ runtime-model-catalog-001 (data-only; independent from E2/E3)
  └→ extension-ui-schema-001 (basic intents first; stateful views later)

host shell
  tui-minimal-001 → theme-001
```

These are capability placeholders. They become binding only after their own analysis/task contracts exist.

## Verification record

| Claim | Method | Result |
|-------|--------|--------|
| Pi source snapshot equals remote HEAD | local `rev-parse` + read-only `git ls-remote` | verified at `5bc1c2c` |
| All 11 dimensions exist in current Pi docs | latest index + dimension pages | verified |
| Pi behavior is separated from TS mechanics | two parallel exploration rounds | verified |
| Package is bundle, not tier | docs + `package-manager.ts` | verified |
| Custom Model differs from Custom Provider | docs + `provider-composer.ts` + `model-registry.ts` | verified |
| SDK/RPC/JSON/TUI are distinct | docs + mode/session source | verified |
| Correct Pi JSON source path | source inspection | `packages/coding-agent/src/modes/print-mode.ts` |
| Zag Headless maturity | maturity/headless contract/commit | L2 at `a1a1e0f` |
| Historical port is not a Zag dependency | package path whitelist + dependency search | verified |
| Round 2 Model/Provider unknowns | OAuth types, env map, generator, examples, dependency checks | closed in companion audit |
| Final breadth/depth | fresh post-Round-2 verifier | PASS — 11/11 COVERED, all major findings DEEP, no blocking findings |

## Remaining blind spots

- Exact Agent Skills interoperability and global/project discovery roots remain a task-level product decision.
- `rpc-v1` command vocabulary is not specified; only its boundary and dependencies are fixed.
- Stateful extension UI schema is not designed; only its safety/ownership boundary is fixed.
- No WASM engine or WIT shape is selected beyond the staged contract constraints.
- Provider breadth, OAuth UX, package registry/signing, and remote updates remain trigger-gated.

## Completion criteria

- [x] Every dimension is traced to current Pi documentation and source.
- [x] Feature semantics are separated from TypeScript runtime mechanics.
- [x] Every dimension has a Zag outcome, carrier, current state, Gate, and divergence.
- [x] Package, Model/Provider, SDK/RPC/JSON/TUI, and UI trust boundaries are distinct.
- [x] WASM is a formal portable executable target without absorbing passive assets or OS integrations.
- [x] Known stale Headless and source-path claims are corrected.
- [x] A fresh post-Round-2 verifier returns PASS (11/11 dimensions COVERED; no blockers).
