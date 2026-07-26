# C8 — Extensions

| Item | Content |
|------|---------|
| Prerequisite | Phase H + SDK/process contracts ✅; E2 needs C7.1; E3 needs its runtime/capability Gates |
| Near-term slice | M2 `skills-001`, then Prompt Templates — E1 passive resources |
| Long-term target | E3 WASM Component extension platform |
| Decision | [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Module | [extensions](../modules/extensions.md) |
| Feature map | [Pi feature correspondence](../plan/analysis/2026-07-26-pi-feature-correspondence.md) |

## Feature surface vs. carrier

C8 delivers the executable/passive extension mechanisms behind a broader product surface. It does not collapse every Pi category into one plugin API.

| Feature | C8 role |
|---------|---------|
| Skills / Prompt Templates | E1 passive discovery and command/input integration |
| Theme | data may reuse passive loading; renderer belongs to C9 host shell |
| Package | runtime bundle manifest over E1/E2/E3; not a tier |
| Custom Model | validated data/configuration; no executable host required |
| Custom Provider | E0 now; E2/E3 runtime registration later |
| SDK / JSON | already closed by their own Gates |
| RPC | separate product protocol after public events/control/session |
| TUI/UI | C9 host plus C8 runtime UI request/view contracts |

## Tier model

| Tier | Mechanism | Delivery |
|------|-----------|----------|
| E0 | trusted static Zig composition | SDK L2 closed in its current scope |
| E1 | passive resources | `skills-001`, then Prompt Templates; theme data later |
| E2 | native process binding | after C7.1 + concrete process integration |
| E3 | WASM Component/WIT binding | formal planned target after common semantics |

No dynamic Zig shared-library ABI and no embedded Lua/QuickJS/Bun runtime.

## E1 passive resources

### Skills

- jailed `SKILL.md` discovery;
- project-trust ordering;
- frontmatter/name/description validation;
- bounded prompt injection;
- deterministic precedence/conflicts;
- explicit disable/manual-only/no-execute neutrality.

"No execute" applies to the loader. Skill text can still direct the model to invoke ordinary Tools against bundled scripts/assets; permission, containment, shell policy, and redaction remain mandatory.

### Prompt Templates

- deterministic non-recursive discovery;
- explicit non-recursive substitution contract;
- first-wins collision diagnostics;
- `/name` expansion owned by the command/input layer;
- no execution privilege.

## Common extension semantics

Before E2/E3, define engine/transport-neutral `zag-ext-v1` entities:

- manifest, Tool capabilities, invoke/progress/result/error, cancel/lifecycle, diagnostics;
- optional hooks/commands/flags/shortcuts/Provider/session/UI entities only after their host contracts exist.

Tool definitions always pass D-007 validation and ordinary host permission/jail/shell/trace composition. The vocabulary is broader than any first binding release.

## E2 native process

Compatibility path for MCP, existing programs, and OS integrations that cannot compile to WASM:

1. C7.1 process supervisor;
2. NDJSON handshake/manifest/Tool binding;
3. bounded I/O/deadline/cancel/reap;
4. minimal environment and structured failure;
5. C7.2 required OS enforcement before untrusted/downloaded native code.

OAuth/browser/keychain/cloud-credential behavior belongs to the host or E2 unless a future capability can be safely mediated.

## E3 WASM Component

Preferred long-term portable executable format, delivered in stages:

1. `extension-wasm-contract-001`: Zag WIT world, package manifest, conformance goldens;
2. `extension-wasm-runtime-001`: measured engine, quarantine decision, compute-only Tool;
3. `extension-wasm-capabilities-001`: host-mediated workspace/progress/cancel, metering, adversarial tests;
4. packaging/trust: local digest/provenance/enable/disable/quarantine; remote registry only after supply-chain Gate;
5. later separately gated worlds may add hooks, commands, Provider behavior, and declarative UI.

The historical Zig port's Tools-only WASM v0 is a starting reference, not Zag's permanent E3 ceiling.

Default guest receives no unrestricted filesystem/network/environment/process access. WASM safety is the runtime + narrow host capability surface + resource limits, not the file suffix.

## Hooks

Trusted static deny-only hooks may follow stable lifecycle events. Runtime hooks use E2/E3 and need explicit:

- event ordering and middleware semantics;
- timeout/cancel/failure fallback;
- mutation revalidation;
- host-deny precedence;
- terminal/session truth.

## Extension UI

Runtime UI starts with host-rendered intents:

- notify/status/progress;
- select/confirm/input;
- markdown/diff/list/table/tree views;
- deterministic plain/headless fallback.

A later stateful view/action Gate may allow E2/E3 code to hold UI state and return bounded view trees after sanitized actions. The host keeps rendering, terminal input, focus, redaction, accessibility, layout, and cancellation.

Raw terminal bytes, arbitrary ANSI, Host pointers, and untrusted native component factories never cross E2/E3. E0 trusted product code may add native components at compile time.

## Runtime bundle

- E0 source dependencies are build-time only and never runtime-installed.
- A runtime bundle may declare E1 resources plus optional E2/E3 artifacts.
- Credentials and OAuth tokens are never package content.
- Initial bundle loading is explicit/local with digest/provenance/trust/disable/quarantine.
- Signing/registry/updater work requires a later supply-chain Gate.

## Invariants

- metadata missing/invalid → fail closed;
- manifest request != host grant/enforcement;
- hook allow cannot override host deny;
- extension cannot mutate canonical session/trace/private Agent state directly;
- runtime/trap/crash cannot create false success;
- process != sandbox; WASM != automatically safe;
- no stable C/Zig dynamic plugin ABI;
- `headless-v1` remains output-only and is not inflated into RPC.

## Acceptance

### E1 Skills

- [ ] roots/order/conflicts deterministic;
- [ ] project trust precedes project-resource discovery;
- [ ] symlink/escape invalid;
- [ ] invalid/oversized content bounded;
- [ ] disabled/manual-only behavior deterministic;
- [ ] no loader execution path;
- [ ] induced Tool calls still pass ordinary security Gates.

### E1 Prompt Templates

- [ ] non-recursive discovery/substitution;
- [ ] collision and command expansion deterministic;
- [ ] no-execute neutrality.

### E2

- [ ] supervisor and protocol Gates;
- [ ] D-007/security composition;
- [ ] sandbox-required mode refuses downgrade;
- [ ] malformed/crashed extension cannot create false success.

### E3

- [ ] WIT semantic conformance independent from engine;
- [ ] selected runtime has measured footprint/support/security evidence;
- [ ] no-WASI defaults and denied imports proven;
- [ ] memory/fuel/time/output/cancel/trap matrix;
- [ ] host workspace capabilities preserve permission/containment;
- [ ] package provenance/disable/quarantine deterministic;
- [ ] each added world has explicit capability/fallback tests.

### Runtime UI

- [ ] malformed/oversized view rejected;
- [ ] action/focus cannot expose raw input or bypass redaction;
- [ ] unavailable UI has deterministic fallback;
- [ ] UI failure cannot replace Tool/run terminal truth.

## Non-goals

- npm/Pi package parity/marketplace in initial tiers;
- Bun/TS or Pi RPC compatibility;
- arbitrary raw-terminal extension code;
- unrestricted WASI;
- choosing a WASM engine before the runtime Gate;
- promising all Pi extension methods in v1.
