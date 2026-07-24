---
id: h-integration-001
scope: phase-h/integration-e2e
status: ready
priority: P1
depends-on: [h-session-001, h-tool-runtime-001, h-workspace-001, h-trace-001, h-context-001, h-provider-001, h-redact-001]
---

# objective

Close Phase H through real product composition, not isolated module tests: exercise Agent → context/provider → descriptor/policy/containment → Tool → transcript/session/trace across the P0/P1 failure matrix and update the production-floor truth only if every exit condition passes.

# context

- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/quality/contracts.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- integration/golden/fault fixtures under the existing package test layout
- `packages/zag-agent-core/`
- `packages/zag-coding-agent/`
- `packages/zag-ai/`
- `packages/zag-cli/`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/roadmap.md`
- `README.md`
- `SECURITY.md`
- `chapters/H-harden/README.md`

# verification

- all P0/P1 fixtures in `docs/quality/evals.md` execute through real composition where applicable;
- no integration boundary retains a stub/name-based fallback that bypasses the new contracts;
- session/save/trace/provider/cancel failure state agrees across API, transcript, file bytes, and trace;
- root and every package test pass;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- only after all checks pass may maturity/README change Phase H to L2.
