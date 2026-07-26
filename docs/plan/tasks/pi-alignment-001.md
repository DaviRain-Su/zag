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
- `docs/references.md`
- `docs/decisions/`
- `docs/plan/`

# verification

- Product docs consistently name Zag a Pi-inspired Zig-native Harness, not an all-in-one parity project.
- Current Pi, the historical Zig port, and Zag each have a distinct role; no external source dependency/submodule is introduced.
- The near-term DAG is Ctrl+C → events → steering/follow-up + session fork → Skills/edit/minimal TUI.
- Provider zoo, OAuth, Bun/TS compatibility, package manager, TS-RPC parity, full WASM, Graph, Memory, MCP, and OS sandbox are not near-term obligations.
- Existing Phase H L2, SDK-ready L2, and Headless L2 evidence remains unchanged.
- Zig performance/size/startup claims remain prohibited without benchmarks.
- D-010 fixes extension tiers: E0 static SDK, E1 passive packages, E2 `zag-ext-v1` after C7.1; no dynamic ABI/script VM; declarative host-rendered UI only.
- Docs lint and independent review pass before ff-only merge.
