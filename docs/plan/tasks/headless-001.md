---
id: headless-001
scope: product/headless-process-contract
status: done
evidence: headless-v1 --json/--json-stream + exit matrix + process fixture 4/4; independent review APPROVE_WITH_NITS + F-1 fix a1a1e0f; ship panel SHIP; merged-main Gate std 452/452 curl 451/451 coding 139/139 docs lint readability 91/100 security 66/100 (44 files) OpenAPI 287/287 catalog 40; Headless/Process SDK L2 closed at a1a1e0f
priority: P1
depends-on: [h-integration-001]
---

# objective

Split headless automation from late TUI work and provide a versioned machine interface with clean JSON/streaming output, stable errors, and stable exit codes.

The binding implementation plan is [2026-07-25-headless-plan](../analysis/2026-07-25-headless-plan.md). Its docs-first finding: the default CLI already keeps stdout clean (final text only; logs on stderr), but one-shot currently exits **0** for `timeout`/`unsupported_control`/`max_turns`/`cancelled`, which headless automation would misread as success. The gate therefore adds explicit `--json` / `--json-stream` modes with an independent `headless-v1` public protocol and a headless-only exit-code matrix, leaving default-mode behavior unchanged.

# context

- `docs/plan/analysis/2026-07-25-headless-plan.md` (binding analysis)
- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `docs/phases/C9-product-shell.md`
- `docs/modules/trace-observability.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-cli/src/cli.zig` (flag parsing, headless dispatch, error mapping, REPL/doctor/help handling)
- `packages/zag-cli/src/headless_writer.zig` (new: JSON envelope / NDJSON events / redaction / exit-code computation)
- `packages/zag-cli/src/headless_process_fixture.zig` (new process-level fixture)
- `packages/zag-coding-agent/src/agent.zig` only if observer/Result consumption needs adjustment
- `build.zig` (fixture step + `-Dtui` option) / `build.zig.zon` if needed
- `docs/modules/headless-contract.md` (new public protocol)
- `docs/phases/C9-product-shell.md`
- `docs/packaging.md`
- `docs/architecture.md`
- `docs/maturity.md`
- `docs/roadmap.md`
- `docs/plan/tasks/headless-001.md`

# verification

1. **stdout purity:** in `--json` / `--json-stream` modes stdout contains only protocol output (single result/error envelope, or NDJSON events ending in exactly one terminal); logs/diagnostics stay on stderr; `--help`/`--doctor`/REPL do not pollute protocol stdout (REPL + headless flag → exit 2).
2. **Versioned protocol:** every envelope/event carries `protocol_version: "headless-v1"`, an independent public schema that maps to — but does not serialize — internal Observer/Trace types.
3. **Structured errors + exit matrix (headless mode only):** auth/provider configuration, runtime provider, invalid/missing session, save conflict/failure, cancellation, timeout, unsupported_control, and `required_sandbox_unavailable` (reserved code for a future required-sandbox mode) each have documented structured error codes and exit codes per the analysis §3 matrix; default mode keeps existing 0/1/2 behavior.
4. **Streaming terminal uniqueness:** `--json-stream` emits versioned events and exactly one terminal (`run_end` or `error`).
5. **CI fixture:** `headless_process_fixture` runs the real `zag` binary end-to-end with empty env, isolated cwd, and a mock provider, asserting JSON validity, terminal uniqueness, exit-code mapping, and no secret/absolute-path leakage; it is wired into the root `test` step for both backends.
6. **TUI optional:** `-Dtui` build option exists (default false), default `zig build test` does not depend on TUI, and a static check proves Kernel packages do not import any TUI package; TUI never contains loop business logic.
7. Full gates: fixture + focused CLI tests, `zig build test --summary all`, `zig build test -Dhttp_backend=curl --summary all`, docs lint/score; independent worktree review and merged-main dual-backend Gate pass before status becomes `done`.

# closeout (`a1a1e0f`)

## chronology

- docs-first plan landed at `9fd5648`.
- Implement: `30aa6ed feat: add headless json protocol`.
- Independent review: **APPROVE_WITH_NITS** (major F-1: halted json-stream + successful agent could emit zero terminals).
- Fix: `a1a1e0f fix: emit terminal on halted headless stream success` (+ regression unit test).
- Adversarial ship panel: **SHIP** (F-1 closed; residual nits only).
- FF-only merge `task/headless-001` → `main` at `a1a1e0f`. No push.

## merged-main gate

- Root default backend: **452/452**.
- Root curl backend: **451/451**.
- `zag-coding-agent`: **139/139**.
- Headless process fixture: **4/4** (real `zag` binary + mock HTTP server).
- Docs lint: PASS.
- Readability: **91/100** (44 files).
- Security: **66/100** (44 files).
- OpenAPI: **287/287**.
- Catalog: **40**.

Required summaries showed no explicit skips. The curl differential (452 vs 451) is the existing `zag-ai` backend-specific fixture, not a new failure.

## scope landed

- `headless-v1` public protocol (`docs/modules/headless-contract.md`).
- CLI `--json` / `--json-stream` mutually exclusive; REPL + headless → exit 2; help/doctor headless-safe.
- `packages/zag-cli/src/headless_writer.zig` — envelopes, NDJSON events, redaction, exit-code matrix, halt-then-success terminal guarantee.
- Process fixture + loopback mock provider wired into root `test` for both HTTP backends.
- `-Dtui` build option (default false) + Kernel-no-TUI static scan test.
- Default one-shot mode unchanged (timeout/cancelled/max_turns still exit 0 without headless flags).

## non-goals (still excluded)

- ACP / editor protocol integration (follows this process contract).
- TUI / dashboard as business logic hosts.
- OS sandbox or required-sandbox enforcement (exit 22 reserved only).
- Stable C ABI / Zig dynamic plugin ABI.
- Mid-flight Tool/shell preemption / process-tree ownership.
- Default-mode exit-code redesign (headless-only matrix).
