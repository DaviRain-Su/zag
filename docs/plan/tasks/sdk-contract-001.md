---
id: sdk-contract-001
scope: sdk/source-contract
status: in-progress
evidence: public injection landed, external consumer fixture passes locally, docs updated; pending independent verification and main Gate
priority: P1
depends-on: [h-integration-001]
---

# objective

Close the Zig SDK-ready gate without freezing a dynamic ABI: supported high-level injection, documented ownership/error/event/cancellation contracts, and a repository-owned external consumer test.

The binding implementation plan is [2026-07-25-sdk-contract-plan](../analysis/2026-07-25-sdk-contract-plan.md). Its docs-first finding: `zag-types` and `zag-agent-core` already import cleanly, but `zag-coding-agent` `Agent.Options` lacks public `Toolset`/`Observer` injection fields — a small public-surface closeout must land before a consumer fixture that avoids internal files is possible.

# context

- `docs/plan/analysis/2026-07-25-sdk-contract-plan.md` (binding analysis)
- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `docs/packaging.md`
- `docs/architecture.md`
- `docs/modules/tool-runtime.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-coding-agent/src/agent.zig` (`Options.toolset`/`Options.observer` + `effectiveToolset`/`deps`)
- `packages/zag-coding-agent/src/root.zig` (top-level `Toolset`/`Observer` re-export)
- `packages/zag-types/` and `packages/zag-agent-core/` only if a real boundary defect appears
- `tests/sdk-consumer-fixture/` (new: `build.zig`, `build.zig.zon`, `src/`)
- root `build.zig` / `build.zig.zon` (fixture dependency + test step)
- `docs/modules/sdk-contract.md` (new public contract)
- `docs/packaging.md`
- `docs/architecture.md`
- `docs/maturity.md`
- `docs/plan/tasks/sdk-contract-001.md`

Note: depending on `zag-coding-agent` transitively pulls `zag-ai`/`openai-zig`; the fixture must wire the root `http_backend` option through.

# verification

1. **Public-surface precondition:** `Agent.Options` gains optional `toolset` and `observer` injection; defaults (CLI/one-shot, internal usage/cost observer) are unchanged when unset; `zag-coding-agent` root re-exports the injected types.
2. An external package (`tests/sdk-consumer-fixture/`) imports supported modules by package name only — no private monorepo source paths.
3. Its high-level composition injects a stateful custom Toolset, Provider, Observer, and policy and proves state accumulation, event sequence, and ask/deny policy behavior.
4. Cancellation (between-Tool/provider, not mid-flight Tool preemption) and session create/resume/save-error paths are exercised in the fixture.
5. Ownership/lifetime, error, event, cancel, and compatibility rules are documented in `docs/modules/sdk-contract.md` per the analysis §3 rules, each traceable to existing code semantics; `docs/packaging.md#sdk-ready-gate`, `docs/architecture.md`, and `docs/maturity.md` are synchronized.
6. The gate does not claim C ABI, dynamic plugin ABI, semver publication, headless protocol, OS sandbox, or mid-flight Tool/shell preemption.
7. All package tests plus the external consumer run via the root `test` step: `zig build test --summary all` and `zig build test -Dhttp_backend=curl --summary all`, plus docs lint/score; independent worktree review and merged-main dual-backend Gate pass before status becomes `done`.
