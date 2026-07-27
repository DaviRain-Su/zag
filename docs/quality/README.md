# Quality docs

| Artifact | Source |
|----------|--------|
| [evals.md](./evals.md) | Hand-written eval / security bar |
| [contracts.md](./contracts.md) | Provider / API contracts |
| [http-backend-bakeoff.md](./http-backend-bakeoff.md) | D-005 Phase 3 live std vs curl |
| [readability-report.md](./readability-report.md) | **Generated** by `scripts/score_docs.py` |
| [security-report.md](./security-report.md) | **Generated** by `scripts/score_docs.py` |
| **CI safety fuses** (this file) | Binding workflow timeout + concurrency contract (`ci-hang-ci-fuses-001`) |

Layout gate: `python3 scripts/lint_docs.py`  
Score + thresholds: `python3 scripts/score_docs.py --check`  
Also: `zig build docs-lint` / `zig build test`

---

# CI safety fuses contract

> Host rails for GitHub Actions: cancel superseded runs and bound job wall
> clock. **Not** product SIGINT/errno proof. Timeouts and cancellations are
> visible failures/cancellations — never soft success.

**Task:** [ci-hang-ci-fuses-001](../plan/tasks/ci-hang-ci-fuses-001.md)

**Status:** **done/closed** at reviewed tip `97f43de` (workflow fuses landed
in `.github/workflows/ci.yml`; independent review + ff-only local merge
complete; **no push**; process-idle residual later **done** via separate
Phase B; final remote Linux Gate still open; maturity unchanged).

**Depends on:** [ci-hang-sigint-linux-errno-001](../plan/tasks/ci-hang-sigint-linux-errno-001.md)
(done @ `bc737025`).

**Does not close:** final merged-path Linux dual-backend Gate, remote GitHub
Actions fuse-enforcement evidence, or any maturity row. Process-idle residual
[ci-hang-sigint-process-idle-001](../plan/tasks/ci-hang-sigint-process-idle-001.md)
is **done** separately via Phase B on Actions
[30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) at
tip `8a93ec6` (not by fuses alone; fuses did **not** fire on that run).

Target workflow: `.github/workflows/ci.yml` — exact fuses:
`concurrency.group: ${{ github.workflow }}-${{ github.ref }}`,
`cancel-in-progress: true`, `jobs.test.timeout-minutes: 30` per matrix OS
job; full ubuntu/macos + std/curl steps retained; no `continue-on-error`.

## Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `.github/workflows/ci.yml` | Top-level concurrency group + `cancel-in-progress`; job-level `timeout-minutes` on `jobs.test`; matrix OS + mandatory step sequence | Product hang root-cause claims; SIGINT/errno decode; idle process-fixture bounds |
| This quality contract | Exact keys, placement, visible-failure semantics, static verification | Runtime product behavior |
| Product packages (`zag-cli`, etc.) | Unchanged by fuses task | Using CI timeout as substitute for product fixes |
| GitHub Actions | Enforce cancel/timeout platform semantics | Zag process exit codes / maturity |

## Exact implementation shape

### 1. Top-level concurrency

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

| Key | Required value | Placement |
|-----|----------------|-----------|
| `concurrency` | mapping | **Top-level** workflow key (sibling of `name` / `on` / `jobs`) |
| `concurrency.group` | `${{ github.workflow }}-${{ github.ref }}` | Exact expression string |
| `concurrency.cancel-in-progress` | `true` | Boolean true |

Semantics: one active in-progress run per workflow+ref group; a newer run
cancels the older in-progress run. Cancellation must appear as **cancelled**,
not success.

### 2. Job-level timeout on matrix test job

```yaml
jobs:
  test:
    timeout-minutes: 30
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
```

| Key | Required value | Placement |
|-----|----------------|-----------|
| `jobs.test.timeout-minutes` | `30` | **Job-level** on `test` (applies to each matrix instance) |

Each of `ubuntu-latest` and `macos-latest` gets an independent 30-minute wall
clock. Timeout → job **failure** (visible), never green.

## Defaults preserved (mandatory)

| Surface | Must remain |
|---------|-------------|
| Triggers | `push` + `pull_request` to `main` and `master` |
| Matrix | `os: [ubuntu-latest, macos-latest]` both required |
| `strategy.fail-fast` | `false` |
| Std tests | `zig build test --summary all` |
| Curl install (Linux) | `sudo apt-get … libcurl4-openssl-dev` with `if: runner.os == 'Linux'` |
| Curl tests | `zig build test -Dhttp_backend=curl --summary all` |
| Later steps | `zig build` install; openai-zig package tests; openai-zig examples |
| Secrets / permissions | No new secrets; no permissions expansion |

## Transaction order (implementation)

1. Insert top-level `concurrency` without changing `on:`.
2. Set `jobs.test.timeout-minutes: 30` without dropping matrix/strategy/steps.
3. Keep full sequential std → (Linux curl install) → curl → install → package
   tests → examples.
4. No `continue-on-error`, no reduced matrix, no optional dual-backend.
5. No product Zig under `packages/` or `src/`; no maturity edits.

## Errors and non-masking

| Event | Required visibility |
|-------|---------------------|
| Job wall clock > 30m | Failed (timeout) |
| Superseded run | Cancelled |
| Step/test failure | Failed (existing); other OS matrix job may continue (`fail-fast: false`) |
| Any of the above | **Never** remapped to success; **never** cited as product hang fixed |

Forbidden masking:

- `continue-on-error: true` on workflow, job, or step for these Gates;
- shrinking OS or backend coverage to hide hangs;
- treating timeout or cancel as evidence of product correctness.

## Safety

- Product defaults (ask, workspace jail, shell protect) untouched.
- No credentials in workflow or logs by this task.
- Fuses are host bounds only; product fixes remain product tasks
  (errno done; process-idle residual
  [ci-hang-sigint-process-idle-001](../plan/tasks/ci-hang-sigint-process-idle-001.md)
  **done** via Phase B Pass path on tip `8a93ec6` / run
  [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) —
  not by fuses; that run completed normally so fuses did **not** fire).
- No push required for the docs contract node; implementation node also
  must not claim a fresh remote Linux Gate unless that Gate task runs it.
  Final merged-path Linux dual-backend Gate remains a separate open node.

## Budgets

| Budget | Bound |
|--------|-------|
| Per matrix job | 30 minutes wall clock |
| Concurrency | Cancel prior in-progress run for same `workflow+ref` |
| Coverage | Full dual-OS dual-backend mandatory steps |
| Docs-only node | docs-lint + diff-check; no remote Actions run required |

## Compatibility

- Zig 0.16.0 setup action version pin retained.
- std vs curl capability truth unchanged.
- CLI SIGINT/errno, headless, SDK, Session, Skills contracts unchanged.
- Maturity rows unchanged by fuses alone.
- Unrelated canonical `.gitignore` and non-`ci.yml` workflows out of path.

## Non-goals

- Process-idle fixture reliability
  ([ci-hang-sigint-process-idle-001](../plan/tasks/ci-hang-sigint-process-idle-001.md);
  closed separately via Phase B evidence — not a fuses claim).
- Final merged-path remote Linux dual-backend Gate (still open; separate node).
- Product SIGINT/errno or fixture bound changes.
- Prompt templates; maturity raise; secrets/permissions/trigger changes.
- Soft success via timeout/cancel; reduced matrix; `continue-on-error`.
- Push from the task worktree as part of docs-first.

## Executable fixtures

### Docs Gate (contract node) — complete @ `f0ccca6`

1. Task file + this contract define exact keys/placement/non-goals.
2. Status truth marks fuses task with binding links.
3. `zig build docs-lint` and `git diff --check` pass.
4. Docs-only commit had no `.github` edit (implementation is separate).

### Static workflow Gate (implementation) — required shape

1. Top-level `concurrency.group` is exactly
   `${{ github.workflow }}-${{ github.ref }}`.
2. `concurrency.cancel-in-progress` is `true`.
3. `jobs.test.timeout-minutes` is `30`.
4. `fail-fast: false`; matrix both OSes; both std and curl full test steps;
   Linux libcurl install retained; later build/package/example steps retained.
5. No `continue-on-error` masking; triggers unchanged; no secrets/permissions
   expansion.

### Local product Gate (implementation closeout) — complete

1. Candidate + merged-main local macOS: std **40/40 · 611/611**, curl
   **42/42 · 610/610**; OpenAPI **287/287**; catalog **40**.
2. Docs lint + score (readability **91** / security **73**) + committed-range
   `git diff --check` clean.
3. Independent review (`zag-task-delivery-4` → `candidate_for_coordinator`);
   coordinator ff-only local main `af293b0` → `97f43de` preserving unrelated
   canonical `.gitignore`; **no push**.
4. Explicit record: process-idle residual later closed separately via Phase B
   ([ci-hang-sigint-process-idle-001](../plan/tasks/ci-hang-sigint-process-idle-001.md)
   **done** @ tip `8a93ec6` / run
   [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011);
   fuses did **not** fire on that success run) + final remote Linux Gate still
   pending as a separate node; timeout/cancel not used as product correctness
   evidence; remote Actions fuse enforcement **not** claimed exercised.

Commits: contract `f0ccca6` · implementation `1d3abaa` · reviewed tip
`97f43de`.

## Related

- Task: [ci-hang-ci-fuses-001](../plan/tasks/ci-hang-ci-fuses-001.md)
- Predecessor: [ci-hang-sigint-linux-errno-001](../plan/tasks/ci-hang-sigint-linux-errno-001.md)
- Process-idle residual (**done** Phase B): [ci-hang-sigint-process-idle-001](../plan/tasks/ci-hang-sigint-process-idle-001.md)
- Product CLI (unchanged by fuses): [cli-interaction](../modules/cli-interaction.md)
- Provider contracts: [contracts.md](./contracts.md)
- Dual-backend bake-off: [http-backend-bakeoff.md](./http-backend-bakeoff.md)
- Plan status: [plan/README](../plan/README.md) · [roadmap](../roadmap.md)
