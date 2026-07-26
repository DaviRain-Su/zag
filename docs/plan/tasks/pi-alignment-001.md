---
id: pi-alignment-001
scope: product/vision-roadmap
status: in-progress
priority: P1
depends-on: [headless-001]
---

# objective

Replace the unbounded “All-in-One” positioning with a Pi-inspired, Zig-native Harness boundary and a reduced evidence-driven delivery DAG, while retaining all closed Phase H, SDK, and Headless contracts.

# context

- `docs/plan/analysis/2026-07-26-pi-zig-alignment.md`
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
