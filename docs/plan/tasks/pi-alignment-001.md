---
id: pi-alignment-001
scope: product/vision-roadmap
status: done
evidence: docs-only commits 9258dc4/cb2497e/8a3250f/4f315c9; two-round Pi docs+source research with fresh verifier PASS 11/11; independent product + extension-security reviews PASS; ff-only merge to main at 4f315c9; merged-main std 452/452 curl 451/451 coding 139/139 SDK fixture 7/7 headless fixture 4/4 docs lint readability 91/100 security 70/100 OpenAPI 287/287 catalog 40; no push
priority: P1
depends-on: [headless-001]
---

# objective

Replace the unbounded “All-in-One” positioning with a Pi-inspired, Zig-native Harness boundary and a reduced evidence-driven delivery DAG, while retaining all closed Phase H, SDK, and Headless contracts.

# context

- `docs/plan/analysis/2026-07-26-pi-zig-alignment.md`
- `docs/plan/analysis/2026-07-26-pi-feature-correspondence.md`
- `docs/plan/analysis/2026-07-26-extension-architecture.md`
- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/vision.md`
- `docs/roadmap.md`
- `docs/maturity.md`

# path

- `README.md`
- `docs/vision.md`
- `docs/architecture.md`
- `docs/packaging.md`
- `docs/roadmap.md`
- `docs/phases/C4-edit-sharpness.md`
- `docs/phases/C5-context.md`
- `docs/phases/C6-orchestration.md`
- `docs/phases/C7-sandbox.md`
- `docs/phases/C8-extensions.md`
- `docs/phases/C9-product-shell.md`
- `docs/modules/cli-interaction.md`
- `docs/modules/extensions.md`
- `docs/modules/headless-contract.md`
- `docs/maturity.md`
- `docs/references.md`
- `docs/decisions/`
- `docs/plan/`

# verification

- Product docs consistently name Zag a Pi-inspired Zig-native Harness, not an all-in-one parity project.
- Current Pi, the historical Zig port, and Zag each have a distinct role; no external source dependency/submodule is introduced.
- Pi's 11 user-facing dimensions (Extension, Skill, Prompt Template, Theme, Package, Custom Model, Custom Provider, SDK, RPC, JSON, TUI/UI) have explicit Zag outcomes without TypeScript/API parity.
- The near-term DAG is Ctrl+C → events → steering/follow-up + session fork → Skills → Prompt Templates + edit → minimal TUI.
- Provider/OAuth breadth, Bun/TS compatibility, npm package manager, Pi RPC schema parity, Graph, Memory, and dashboard are not near-term obligations; Zag-native RPC and E3 WASM are separately gated formal targets.
- Existing Phase H L2, SDK-ready L2, and Headless L2 evidence remains unchanged.
- Zig performance/size/startup claims remain prohibited without benchmarks.
- D-010 keeps feature categories orthogonal to carriers: E0 static SDK, E1 passive resources, E2 process after C7.1, and planned E3 WASM Component with WIT/runtime/capability/package Gates.
- Package is a bundle above E1/E2/E3 and never hot-installs E0; Custom Model data is distinct from executable Provider behavior.
- Runtime UI is host-rendered intent/view/action data; raw terminal/ANSI/Host component pointers do not cross E2/E3; stateful views require a separate Gate.
- No dynamic ABI/script VM or current WASM/RPC/TUI maturity claim is introduced.
- Docs lint and independent review pass before ff-only merge.

# closeout

## chronology

- `9258dc4 docs: align Zag with Pi harness semantics` established D-009, the reduced Harness DAG, and Ctrl+C contract.
- `cb2497e docs: make WASM a planned extension tier` promoted E3 from optional research to a formal target.
- `8a3250f docs: map Pi feature surfaces to Zag carriers` added the two-round code/docs research, 11-dimension feature matrix, runtime bundle/model/Provider/RPC/UI boundaries, and staged E3 platform.
- `4f315c9 docs: fix analysis markdown spacing` closed the only concrete review nit.
- Fresh research verifier: **PASS** — 11/11 dimensions COVERED, major findings DEEP, no blockers.
- Independent product/route review: **PASS**; F-1 whitespace finding resolved at `4f315c9`.
- Independent extension-security review: **PASS**, no blocking findings.
- FF-only merge `task/pi-alignment-001` → local `main` at `4f315c9`. No push.

## merged-main gate

- Root default backend: **452/452**.
- Root curl backend: **451/451**.
- `zag-coding-agent`: **139/139**.
- SDK external consumer: **7/7**.
- Headless process fixture: **4/4**.
- Docs lint: PASS.
- Readability: **91/100** (47 files).
- Security: **70/100** (47 files).
- OpenAPI path coverage: **287/287**.
- Catalog: **40** models, up to date.

The std/curl 452 vs 451 differential is the existing backend-specific fixture, not a new failure. Test output includes expected negative-fixture `failed command` diagnostics while the Zig Build summaries are fully successful.

## scope landed

- Zag is explicitly a Pi-inspired Zig-native Harness, not a parity fork or all-in-one product.
- Current Pi supplies functional/behavior reference; the historical Zig port remains a read-only design/fixture archive and is not a dependency.
- Pi's Extension, Skill, Prompt Template, Theme, Package, Custom Model, Custom Provider, SDK, RPC, JSON, and TUI/UI dimensions each map to a Zag outcome, carrier, current maturity, Gate, and deliberate difference.
- D-010 separates user features from E0 static Zig, E1 passive resources, E2 supervised process, and formal E3 WASM Component carriers.
- Package is a runtime bundle over E1/E2/E3 and never hot-installs E0; model metadata, executable Provider behavior, and credentials are separate.
- `headless-v1` remains closed/output-only; Zag-native `rpc-v1` is a separate planned Gate.
- Extension UI starts with host-rendered intents, may later add stateful view/actions, and never grants raw terminal/ANSI/Host pointers across E2/E3.
- E3 starts with compute-only Tools and may add hooks/commands/Provider/UI only through separate WIT/capability/fallback Gates.

## non-goals retained

- Pi release/API/schema/CLI/provider-count parity.
- Bun/TypeScript compatibility host or npm package-manager/marketplace parity.
- Dynamic Zig/C plugin ABI or embedded script runtime.
- Current WASM engine/platform, RPC, TUI, runtime package/model/Provider/UI implementation claims.
- Unrestricted WASI, process-as-sandbox claims, or supply-chain/registry promises before their Gates.
- Unmeasured Zig performance/size/startup claims.
