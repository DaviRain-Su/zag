---
id: headless-001
scope: product/headless-process-contract
status: ready
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
