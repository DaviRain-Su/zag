---
id: ci-hang-ci-fuses-001
scope: quality/ci-fuses
status: in-progress
priority: P0
depends-on:
  - ci-hang-sigint-linux-errno-001
---

# objective

Add **bounded GitHub Actions safety fuses** to the existing mandatory
`ubuntu-latest` + `macos-latest` std+curl CI matrix so runaway or
superseded runs cannot hang indefinitely and stack on the same ref.

Exact implementation shape (implementation node only; this commit is
**docs-first** and does **not** edit `.github`):

1. Top-level `concurrency` on `.github/workflows/ci.yml`:
   - `group: ${{ github.workflow }}-${{ github.ref }}`
   - `cancel-in-progress: true`
2. Job-level `timeout-minutes: 30` on `jobs.test`, applying independently
   to each matrix OS job (`ubuntu-latest` and `macos-latest`).

Preserve all triggers, both OS entries, `strategy.fail-fast: false`,
full sequential std and curl test steps, Linux libcurl install, install
build, package tests, and examples. Timeouts and cancellation must remain
**visible failures/cancellations**, never soft success.

Binding quality contract: [CI safety fuses](../../quality/README.md).

Depends on completed `ci-hang-sigint-linux-errno-001` (done @ `bc737025`).
Does **not** close process-idle fixture work or the final merged-path
Linux dual-backend Gate. No remote Linux run and **no push** in this
docs node. Maturity unchanged.

# context

## Why

The mandatory dual-OS dual-backend matrix can hang or pile up when:

- a step never terminates (e.g. historical curl-linked Linux SIGINT drain hang);
- successive pushes/PR updates on the same ref queue full matrices without canceling superseded runs.

CI fuses are **host safety rails**, not product correctness proof. A job
timeout or concurrency cancellation is a **visible failure/cancellation**
of the run; it must never be treated as evidence that product SIGINT,
errno decode, or idle fixtures are correct.

## Dependency and adjacent work

| Node | Status | Relationship |
|------|--------|--------------|
| [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md) | **done** @ `bc737025` | Required predecessor; raw Linux errno decode under `link_libc` |
| `ci-hang-sigint-process-idle-001` | planned (no task file yet) | Separate idle process-fixture reliability; **not** this node |
| **ci-hang-ci-fuses-001** (this) | **in-progress** (docs contract) | Workflow concurrency + per-job timeout only |
| final merged-path Linux dual-backend Gate | planned | Fresh remote Linux runner after idle + fuses; still required before prompt-templates |

## Out of path (hard)

- `packages/zag-cli/src/sigint.zig` and `sigint_process_fixture.zig`
- Product SIGINT/errno behavior, idle fixture bounds, maturity rows
- Prompt templates, unrelated canonical `.gitignore`
- Secrets, permissions, branch trigger changes
- Softening coverage via reduced matrix, `continue-on-error`, or
  treating timeout as green product evidence
- Remote Linux runner execution or `git push` in this docs node

## References

- Binding: [docs/quality/README.md](../../quality/README.md) (CI safety fuses)
- Workflow target: `.github/workflows/ci.yml` (implementation node only)
- Predecessor: [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md)
- CLI product contract (unchanged by fuses): [cli-interaction](../../modules/cli-interaction.md)
- Dual-backend truth: [zag-ai-provider](../../modules/zag-ai-provider.md),
  [http-backend-bakeoff](../../quality/http-backend-bakeoff.md)

# path

## Docs (this node — contract + status truth)

- `docs/plan/tasks/ci-hang-ci-fuses-001.md` — this task
- `docs/quality/README.md` — binding CI-quality contract (safety fuses)
- status truth only: `docs/plan/README.md`, `docs/roadmap.md`
  (optional light cross-links in modules/cli-interaction if needed for
  “task file authored” honesty; **no** maturity change)

## Implementation (later node — not this commit)

- `.github/workflows/ci.yml` **only** for:
  - top-level `concurrency` block
  - `jobs.test.timeout-minutes: 30`
- **no** product source under `packages/` or `src/`
- **no** `sigint.zig` / `sigint_process_fixture.zig`
- **no** maturity / prompt-templates / `.gitignore` / secrets / permissions

# contract

The quality README is authoritative. Summary of binding rules for this node:

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `.github/workflows/ci.yml` | Workflow concurrency group, job wall-clock timeout, matrix OS runners, step sequence for monorepo Gates | Product SIGINT/errno, idle fixture bounds, maturity claims |
| `docs/quality/README.md` | Binding CI fuse contract and static verification keys | Runtime product behavior |
| `zag-cli` / product packages | Unchanged by this task | CI workflow knobs as a substitute for product fixes |
| GitHub Actions platform | Enforcing timeout cancel and concurrency cancel-in-progress | Zag process exit codes |

## 2. API / lifetimes (workflow surface)

### Concurrency (workflow top-level)

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

- **Placement:** top-level key of `ci.yml` (sibling of `name` / `on` / `jobs`),
  **not** nested under `jobs.test` or a step.
- **Group expression:** exactly
  `${{ github.workflow }}-${{ github.ref }}` (workflow name + ref).
- **cancel-in-progress:** exactly `true` (boolean), so a newer run on the
  same group cancels the older in-progress run.
- **Lifetime:** applies to the whole workflow run; superseding runs cancel
  prior runs still in progress for that group.

### Job timeout (matrix test job)

```yaml
jobs:
  test:
    timeout-minutes: 30
```

- **Placement:** under `jobs.test` (job-level), **not** only under individual
  steps, and not as a workflow-level substitute that omits job coverage.
- **Value:** exactly `30` (integer minutes).
- **Matrix semantics:** with `strategy.matrix.os: [ubuntu-latest, macos-latest]`,
  each matrix job instance gets its **own** 30-minute wall clock.
- **Lifetime:** wall-clock from job start; GitHub marks the job failed on
  timeout (visible failure, not soft success).

## 3. Defaults (preserved)

| Item | Required default |
|------|------------------|
| Triggers | `push` + `pull_request` on `main` and `master` only (unchanged) |
| Job `test` | `runs-on: ${{ matrix.os }}` |
| `strategy.fail-fast` | `false` |
| Matrix `os` | `[ubuntu-latest, macos-latest]` (both mandatory) |
| Zig | `0.16.0` via existing setup action |
| Test sequence | Full sequential `zig build test --summary all` then curl install (Linux) then `zig build test -Dhttp_backend=curl --summary all` |
| Later steps | `zig build` install, openai-zig package tests, openai-zig examples |
| Permissions / secrets | No new permissions block; no new secrets; no GITHUB_TOKEN scope changes |

## 4. Transaction order (implementation edit)

When the implementation node edits `.github/workflows/ci.yml`:

1. Add top-level `concurrency` with exact `group` and `cancel-in-progress: true`
   without altering `on:` triggers.
2. Add `timeout-minutes: 30` under `jobs.test` without removing or reordering
   existing job keys that preserve matrix/strategy/steps.
3. Leave every existing step intact (catalog, docs score/lint, OpenAPI path
   coverage, std test, Linux libcurl install, curl test, install build,
   package tests, examples).
4. Do not add `continue-on-error: true` on any job or step.
5. Do not shrink the matrix or split dual-backend into optional paths.
6. Commit workflow + any residual docs; no product Zig sources.

## 5. Errors / visible failure semantics

| Condition | Required outcome |
|-----------|------------------|
| Job exceeds 30 minutes | Job **fails** (timeout); run is not green |
| Superseded run canceled by concurrency | Prior run shows **cancelled**; not rewritten to success |
| Step failure (test/lint/etc.) | Existing fail-closed behavior; `fail-fast: false` still lets other matrix OS continue |
| Timeout or cancel | **Never** used as evidence of product SIGINT/errno/idle correctness |

No `continue-on-error` masking. No “timeout = pass” mapping. No soft
success from cancellation.

## 6. Safety

- Preserve ask + workspace jail + shell protect product defaults (untouched).
- No secrets, tokens, or credential material in workflow or fixtures.
- No expansion of workflow permissions.
- CI fuses do not replace product hang fixes (errno node remains separate;
  process-idle remains separate).
- Do not push from this worktree; do not claim remote Linux Gate in this node.

## 7. Budgets

| Budget | Bound |
|--------|-------|
| Job wall clock | 30 minutes per matrix OS job |
| Concurrency | One active in-progress run per `workflow+ref` group (older canceled) |
| Matrix size | Exactly two OS entries; no reduction |
| Dual-backend steps | Both full `zig build test` paths mandatory with `--summary all` |
| Docs Gate (this node) | `zig build docs-lint` + `git diff --check`; no full product suite required for docs-only commit |

## 8. Compatibility

- Zig 0.16 CI install version unchanged.
- Dual-backend capability truth unchanged (std vs curl).
- Product CLI SIGINT/errno contracts unchanged.
- Headless / SDK / Session / Skills maturity rows unchanged.
- Unrelated workflows (e.g. review-fix) out of path unless a separate task
  requires them.
- Canonical unrelated `.gitignore` untouched.

## 9. Non-goals

- Implementing or softening `ci-hang-sigint-process-idle-001`.
- Remote Linux dual-backend Gate or any `git push`.
- Changing product SIGINT/errno code or process fixtures.
- `continue-on-error`, reduced matrix, optional curl, or single-OS CI.
- Using timeout/cancel as product correctness evidence.
- Trigger branch set changes; secrets/permissions changes.
- Maturity raise; prompt-templates implementation; quality score body hand-edits
  (regenerated reports only if tooling rewrites them).
- Editing `packages/zag-cli/src/sigint.zig` or `sigint_process_fixture.zig`.

## 10. Executable fixtures / verification (Gates)

### F0 — Docs contract Gate (this node)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F0a | Task + quality contract authored | This file + [quality/README.md](../../quality/README.md) define ownership, shape, non-goals, fixtures |
| F0b | Status truth | plan/roadmap list `ci-hang-ci-fuses-001` as **in-progress** with task link; process-idle + final Linux Gate remain pending |
| F0c | `zig build docs-lint` | Pass from task worktree |
| F0d | `git diff --check` | Clean on intended docs range |
| F0e | Scope | No `.github` edit, no product Zig, no maturity raise, no push |

### F1 — Static workflow shape (implementation node)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F1a | Top-level concurrency | YAML has top-level `concurrency.group` exactly equal to the string form of `${{ github.workflow }}-${{ github.ref }}` (expression preserved) |
| F1b | cancel-in-progress | `concurrency.cancel-in-progress` is boolean `true` |
| F1c | Job timeout | `jobs.test.timeout-minutes` is integer `30` |
| F1d | Placement | `concurrency` is not only under a step; `timeout-minutes` is job-level on `test` |
| F1e | Matrix preserved | `strategy.fail-fast: false`; `matrix.os` includes both `ubuntu-latest` and `macos-latest` only as today |
| F1f | Steps preserved | Both `zig build test --summary all` and `zig build test -Dhttp_backend=curl --summary all` present; Linux libcurl install step retained with Linux `if`; install + package + examples retained |
| F1g | No masking | No `continue-on-error: true` on workflow/job/step; no new always-green path |
| F1h | Triggers | `on.push.branches` / `on.pull_request.branches` still `[main, master]` (or equivalent current pair); no secret/permission blocks added |

Static verification may be a focused script, `rg`/YAML assertions in review,
or documented checklist — but F1 keys are **mandatory** before `done`.

### F2 — Local dual-backend + docs Gate (implementation closeout)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F2a | std | `zig build test -Dhttp_backend=std --summary all` (or default std path) green on implementer host |
| F2b | curl | `zig build test -Dhttp_backend=curl --summary all` green on implementer host |
| F2c | docs | `zig build docs-lint`; readability/security thresholds still hold |
| F2d | diff | `git diff --check` on committed range clean |
| F2e | Honesty | Timeout/cancel **not** cited as product hang fixed; process-idle + final Linux Gate still open |

### F3 — Explicitly **not** in this node

| Item | Status |
|------|--------|
| Remote `ubuntu-latest` GitHub Actions run after merge | **Pending** final Linux dual-backend Gate |
| `ci-hang-sigint-process-idle-001` | **Pending** (separate task file not yet authored) |
| Push to origin | **Forbidden** in this docs node; not required for fuses docs |

# verification

## Docs Gate (this commit)

- [x] Binding quality contract + task authored before `.github` edit
- [x] Status truth → in-progress for `ci-hang-ci-fuses-001`
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] `git diff --check`
- [x] Explicit `git add` of intended docs/quality/plan files only
- [x] One local docs commit on `task/ci-hang-ci-fuses-001`
- [x] No `.github` change; no product Zig; no maturity raise; no push

## Implementation Gate (later)

- [ ] F1a–F1h static shape pass
- [ ] F2a–F2e local std/curl/docs/diff pass
- [ ] Independent review; ff-only merge path; no soft-success masking
- [ ] Record that process-idle + final remote Linux Gate remain open

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | `docs/quality/README.md` (CI safety fuses section) |
| Task | this file `in-progress` (docs-first) |
| Implementation | **not yet** — `.github/workflows/ci.yml` reserved for implementer |
| Fixtures F0 | this docs commit |
| Fixtures F1–F2 | pending implementation node |
| Maturity | **unchanged** |
| Not claimed | remote Linux runner; process-idle; product hang closed by timeout alone; push |

# non-goals (task boundary)

See §9. Docs node only: no workflow YAML, no product code, no remote run,
no push. Broader Linux reliability still requires process-idle + final
merged-path Linux dual-backend Gate before prompt-templates.

# closeout

_Not closed._ Docs-first contract open for implementation. Predecessor
`ci-hang-sigint-linux-errno-001` remains done @ `bc737025`. Maturity
unchanged.
