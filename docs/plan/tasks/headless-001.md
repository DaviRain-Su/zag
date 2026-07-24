---
id: headless-001
scope: product/headless-process-contract
status: pending
priority: P1
depends-on: [h-integration-001]
---

# objective

Split headless automation from late TUI work and provide a versioned machine interface with clean JSON/streaming output, stable errors, and stable exit codes.

# context

- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `docs/phases/C9-product-shell.md`
- `docs/modules/trace-observability.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-cli/src/cli.zig`
- `packages/zag-coding-agent/src/agent.zig`
- process-level fixtures
- `docs/phases/C9-product-shell.md`
- `docs/roadmap.md`
- `README.md`

# verification

- stdout in JSON modes contains only protocol output;
- auth, invalid/missing session, save conflict/failure, cancellation, timeout, and required-sandbox-unavailable have documented structured errors and exit codes;
- streaming events are versioned and terminal exactly once;
- a CI fixture uses headless mode end-to-end;
- TUI remains optional and cannot contain loop business logic.
