# C8 — Extensions

| Item | Content |
|------|---------|
| Prerequisite | Phase H + SDK/process contracts ✅；E2 needs C7.1；E3 needs its runtime/capability Gates |
| Near-term slice | M2 `skills-001` — E1 passive Skills |
| Long-term target | E3 WASM Component extension platform |
| Decision | [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Module | [extensions](../modules/extensions.md) |

## Tier model

| Tier | Mechanism | Delivery |
|------|-----------|----------|
| E0 | trusted static Zig composition | SDK L2 closed |
| E1 | passive packages | `skills-001` in M2 |
| E2 | native process binding | after C7.1 + concrete process integration |
| E3 | WASM Component/WIT binding | planned extension target after common semantics |

No dynamic Zig shared-library ABI and no embedded Lua/QuickJS/Bun runtime.

## E1 passive Skills

- jailed `SKILL.md` discovery;
- frontmatter/name/description validation;
- bounded prompt injection;
- deterministic precedence/conflicts;
- explicit disable/no-execute neutrality。

## Common extension semantics

Before E2/E3, define engine/transport-neutral `zag-ext-v1` entities: manifest, Tool capabilities, invoke/progress/result/error, cancel/lifecycle, diagnostics, optional hooks/commands/declarative UI.

Tool definitions always pass D-007 validation and normal host permission/jail/shell/trace composition.

## E2 native process

Compatibility path for MCP, existing programs, and OS integrations that cannot compile to WASM:

1. C7.1 process supervisor;
2. NDJSON handshake/manifest/Tool binding;
3. bounded I/O/deadline/cancel/reap;
4. minimal environment and structured failure;
5. C7.2 required OS enforcement before untrusted/downloaded native code。

## E3 WASM Component

Preferred long-term installable third-party extension format:

1. `extension-wasm-contract-001`: Zag WIT world, package manifest, conformance goldens;
2. `extension-wasm-runtime-001`: engine evaluation/measurement, quarantine decision, compute-only Tool;
3. `extension-wasm-capabilities-001`: host-mediated workspace/progress/cancel, metering and adversarial tests;
4. packaging/trust: local digest/provenance/enable/disable/quarantine; remote registry only after supply-chain Gate。

Default guest receives no unrestricted filesystem/network/environment/process access. WASM safety is the runtime + narrow host capability surface + resource limits, not the file suffix.

## Hooks and UI

Trusted static deny-only hooks may follow stable lifecycle events. Runtime hooks use E2/E3.

UI is declarative host-rendered data only. No arbitrary component factories, renderers, terminal input callbacks, or Host pointers.

## Invariants

- metadata missing/invalid → fail closed;
- manifest request != host grant/enforcement;
- hook allow cannot override host deny;
- extension cannot mutate canonical session/trace/private Agent state;
- runtime/trap/crash cannot create false success;
- process != sandbox; WASM != automatically safe;
- no stable C/Zig dynamic plugin ABI。

## Acceptance

### E1

- [ ] roots/order/conflicts deterministic;
- [ ] symlink/escape invalid;
- [ ] invalid/oversized content bounded;
- [ ] disabled path behavior-neutral;
- [ ] no executable path。

### E2

- [ ] supervisor and protocol Gates;
- [ ] D-007/security composition;
- [ ] sandbox-required mode refuses downgrade。

### E3

- [ ] WIT semantic conformance independent from engine;
- [ ] selected runtime has measured footprint/support/security evidence;
- [ ] no-WASI defaults and denied imports proven;
- [ ] memory/fuel/time/output/cancel/trap matrix;
- [ ] host workspace capabilities preserve permission/containment;
- [ ] package provenance/disable/quarantine deterministic。

## Non-goals

- npm/Pi package parity/marketplace in initial tiers;
- Bun/TS or TS-RPC compatibility;
- arbitrary extension UI code;
- unrestricted WASI;
- choosing a WASM engine before the runtime Gate。
