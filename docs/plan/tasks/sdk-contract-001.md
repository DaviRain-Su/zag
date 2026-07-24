---
id: sdk-contract-001
scope: sdk/source-contract
status: pending
priority: P1
depends-on: [h-integration-001]
---

# objective

Close the Zig SDK-ready gate without freezing a dynamic ABI: supported high-level injection, documented ownership/error/event/cancellation contracts, and a repository-owned external consumer test.

# context

- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `docs/packaging.md`
- `docs/architecture.md`
- `docs/modules/tool-runtime.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-types/`
- `packages/zag-agent-core/`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- SDK consumer fixture under the repository test layout
- `docs/packaging.md`
- `docs/architecture.md`
- `docs/maturity.md`

# verification

- an external package imports supported modules without private monorepo paths;
- its high-level composition injects a stateful custom Toolset, Provider, Observer, and policy;
- cancellation and session persistence/error paths are exercised;
- ownership/lifetime and compatibility rules are documented;
- the gate does not claim C ABI, dynamic plugin ABI, or semver publication before a second consumer/release channel;
- all package tests plus the external consumer run in CI.
