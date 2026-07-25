---
id: sdk-contract-001
scope: sdk/source-contract
status: done
evidence: Agent.Options public toolset/observer injection merged; root re-export; external consumer fixture 7/7; merged-main std 440/440, curl 439/439, coding 139/139, docs lint, readability 91/100, security 66/100 (43 files), OpenAPI 287/287, catalog 40; per-run cancel semantics documented; SDK-ready Gate closed at ebdd7ab
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

# closeout (`ebdd7ab`)

## chronology

- review-01 PASS on the public-injection + external-consumer changes.
- Panel review BLOCKed on a set of findings; fixes landed in `ebdd7ab`.
- review-02 PASS after the fixes.
- Reship panel **SHIP**.

FF-only merge to `main`; no code changes are part of this docs-only closeout.

## merged-main gate

- `tests/sdk-consumer-fixture/`: **7/7**.
- `zag-coding-agent`: **139/139**.
- Root default backend: **440/440**.
- Root curl backend: **439/439**.
- Docs lint: PASS.
- Readability: **91/100**.
- Security: **66/100** (43 files).
- OpenAPI: **287/287**.
- Catalog: **40**.

Required summaries showed no explicit skips. The single curl differential (440 vs 439) is the existing `zag-ai` backend-specific fixture, not a new failure.

## scope landed

- `Agent.Options.toolset`/`observer` injection with unchanged default behavior.
- `Agent.requestCancel()` and per-run cancel semantics: stale flags are cleared at the start of each reply, so one `requestCancel()` only affects the current run; the run-in-progress bit still applies.
- `packages/zag-coding-agent/src/root.zig` re-exports the public composition types.
- `tests/sdk-consumer-fixture/` — 7 tests covering low-level composition, stateful Tool/Provider/Observer, ask/yolo allow-deny, between-Tool cancel, and session create/resume/save-error.
- `docs/modules/sdk-contract.md` public contract.
- Root `build.zig` / `build.zig.zon` include the fixture in `.paths` / test steps.

## non-goals (still excluded)

- Semver publication / repo mirror (still waits for a second real consumer + release channel).
- Stable C ABI or Zig dynamic plugin ABI.
- Headless/process JSON protocol.
- OS sandbox.
- Mid-flight Tool/shell preemption.
