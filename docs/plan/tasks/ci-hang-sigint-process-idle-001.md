---
id: ci-hang-sigint-process-idle-001
scope: product/cli-interaction
status: done
priority: P0
depends-on:
  - cli-sigint-001
  - ci-hang-sigint-linux-errno-001
  - ci-hang-ci-fuses-001
---

# objective

Close the **residual Linux idle SIGINT process-fixture reliability** question
on a **fresh, explicitly approved Linux runner / remote action**, after the
errno hotfix and host CI fuses are already done.

This residual closed via **Phase B (Pass path)**: fresh post-errno/fuses remote
Linux evidence showed the **existing** idle oracle already passes. **No**
product, fixture, build, or CI-YAML edit was required or authorized for this
closeout.

Binding product behavior remains
[CLI interaction](../../modules/cli-interaction.md). Host CI fuses remain
rails only ([quality/README](../../quality/README.md)); timeout/cancel never
counts as product pass.

Depends on:

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [cli-sigint-001](./cli-sigint-001.md) | **done** @ `d542332` | Idle/active SIGINT lifecycle + process fixture existence |
| [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md) | **done** @ `bc737025` | Raw Linux errno decode so curl-linked `drainWake` terminates |
| [ci-hang-ci-fuses-001](./ci-hang-ci-fuses-001.md) | **done/closed** @ `97f43de` | Host concurrency + 30m/job rails (not product proof) |

Does **not** own Core boundary, prompt templates, maturity raise, final
merged-path Linux dual-backend Gate as a whole, or push without fresh
authorization.

# context

## Why this residual existed

1. M0 (`cli-sigint-001`) established the idle process fixture: real direct
   `zag` binary, isolated cwd, synthetic credentials, observe `you>`, first
   SIGINT, bounded exit `0` without stderr `error:` / stack / `ReadFailed`.
2. `ci-hang-sigint-linux-errno-001` fixed raw-Linux errno decode under
   curl-linked `link_libc` so self-pipe drain terminates. Closeout used local
   macOS dual-backend Gates; **no fresh post-fix remote Linux runner** at
   that time.
3. `ci-hang-ci-fuses-001` added workflow concurrency + 30m job timeout. Those
   are **visible failures/cancellations**, never product hang proof.
4. Residual question: whether the **existing** idle process fixture passes on
   fresh post-errno/fuses **Linux** without product/fixture change.

## Adjacent work (not this node)

| Node | Relationship |
|------|--------------|
| final merged-path Linux dual-backend Gate | **Still open / separate next docs node** — full remote Linux dual-backend Gate remains required before prompt-templates; **not** claimed closed by this residual even when the same Actions run is candidate evidence |
| prompt-templates-001 | **Still blocked** until that final Linux Gate node closes |
| Core ownership / D-011 | Unchanged; CLI owns SIGINT |

## References

- Binding product: [cli-interaction](../../modules/cli-interaction.md)
- Quality / CI fuses: [quality/README](../../quality/README.md)
- Predecessors: [cli-sigint-001](./cli-sigint-001.md),
  [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md),
  [ci-hang-ci-fuses-001](./ci-hang-ci-fuses-001.md)
- Live fixture: `packages/zag-cli/src/sigint_process_fixture.zig`
- Live product signal: `packages/zag-cli/src/sigint.zig`
- Build targets: `zig build sigint-process-fixture`, root `zig build test`

# path

## Docs (this closeout)

- `docs/plan/tasks/ci-hang-sigint-process-idle-001.md` — this task
- status / cross-link truth only:
  - `docs/plan/README.md`
  - `docs/roadmap.md`
  - `docs/modules/cli-interaction.md`
  - `docs/modules/README.md`
  - `docs/quality/README.md`

## Implementation path

**None.** Phase B Pass path: existing code already green on approved Linux
evidence. No product or fixture edit authorized or performed.

# contract

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-cli` (`sigint.zig`) | SIGINT Guard, self-pipe, interruptible read, process exit UX | Agent cancel semantics beyond binding `*Flag`; HTTP backends |
| Process fixture (`sigint_process_fixture.zig`) | Host-native spawn/wait/kill, idle oracle, leak checks | Product Linux non-libc claim; CI workflow knobs |
| `zag-agent-core` | atomic `CancelFlag` only | signal handlers, exit codes, fixtures |
| CI workflow / fuses | Host timeout + concurrency (already closed) | Product correctness claims |
| This task | Evidence protocol + residual close criteria | Final full monorepo Linux Gate; prompt-templates |

## 2. Preserved idle oracle (binding)

After the child reaches the idle REPL prompt, the fixture must preserve:

| Step | Binding assertion |
|------|-------------------|
| Readiness | Observe real prompt marker `you>` (or `you> `) from child stdout **before** SIGINT; no blind sleep injection |
| Signal | First SIGINT delivered to the direct child |
| Wait | `waitBounded(io, pid, 4000)` returns **non-null** (child exits within 4000 ms) |
| Exit class | `WIFEXITED` (exited, not signal-killed as the sole “pass”) |
| Exit code | **0** |
| stderr | No `error:`, no stack trace (`stack trace`), no `ReadFailed` |
| Leaks | No secret fixture material; no absolute path leaks (e.g. `/Users/`, `sk-`) |

Active-backend honesty remains:

- **std** hard-escape path still exits **130** (active second-signal fixture);
- **curl** cooperative/active cancel path still exits **11** with cancelled
  terminal honesty.

Do **not** silently lengthen `waitBounded(…, 4000)` without a contract-level
necessity proven by unique root-cause evidence. **Preserved** through this
Pass-path closeout.

## 3. CI fuses and non-masking

| Event | Allowed as product pass? |
|-------|---------------------------|
| Job `timeout-minutes` fire | **No** — visible failure only |
| Concurrency cancel-in-progress | **No** — cancelled, not success |
| Fixture `waitBounded` null / timeout | **No** — fixture failure, not product pass |
| `continue-on-error`, skip, soft green | **Forbidden** |

Fuses remain exact as closed by `ci-hang-ci-fuses-001`:
`group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: true`,
`jobs.test.timeout-minutes: 30`.

**This closeout run completed normally.** Job/step success is product/test
green; fuses were configured/accepted on the workflow but **did not fire**.
Do **not** claim timeout or cancel was exercised.

## 4. Binding phases

### Phase A — Evidence acquisition only — **complete**

**Prerequisite tip:** post-errno (`bc737025` lineage) **and** post-fuses
(`97f43de` lineage) code. Evidence tip:
`8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (pushed merged main after fuses
closeout).

**Authorization:** fresh explicitly approved remote GitHub Actions run on that
tip (see delivery evidence).

**Evidence collected:** full dual-OS dual-backend root suites plus embedded
process-level SIGINT fixture (2 tests) under both std and curl on Ubuntu;
macOS job also success. See §delivery evidence.

**Phase A did not edit product or fixture code.**

### Phase B — Pass path (no product/fixture change) — **taken**

Fresh Linux evidence shows **existing code already passes** the preserved
idle oracle (and active std 130 / curl 11 remain green inside the 2-test
fixture where retained):

1. Made **no** product or fixture change.
2. Recorded host / backend / tip / run citation in delivery evidence.
3. Residual marked **closed** (status → `done`).
4. Left the **final merged-path Linux dual-backend Gate** as a **separate
   open next docs node** — not claimed closed by this residual.

### Phase C — Fail path — **not taken**

No unique failure root; no product/fixture edit.

## 5. Defaults and safety

- Permission default **ask**, workspace jail, shell protect unchanged.
- No secrets, real API keys, or external network services in fixtures.
- Synthetic credentials only; isolated tmp cwd.
- Product Linux signal path stays raw syscalls (errno already fixed); fixture
  may keep host-native libc for `waitpid`/`kill` only.
- No Core ownership change.

## 6. Budgets

| Budget | Bound |
|--------|-------|
| Idle post-SIGINT wait | `waitBounded(..., 4000)` ms (contract-preserved) |
| Prompt readiness wait | existing fixture marker bound (e.g. 8000 ms class) — not weakened |
| CI job wall (host fuse) | 30 minutes per matrix job (unchanged; **not fired** this run) |
| Docs-only Pass-path closeout | docs-lint + score-check + diff-check; no product commit |

## 7. Compatibility

- std vs curl capability truth unchanged.
- headless cancel exit `11` / hard escape `130` unchanged (active paths
  retained in fixture).
- Maturity rows unchanged by this residual alone.
- Unrelated `.gitignore`, packaging, prompt templates out of path.

## 8. Non-goals

- Inventing or co-rooting a historical failure without fresh Linux repro.
- Changing `waitBounded(4000)` without contract necessity proven by unique
  root cause.
- Product or fixture edits (Phase B: none).
- Removing, softening, or claiming CI fuses as product hang proof.
- Claiming timeout/cancel was exercised (this run completed normally).
- Changing Core ownership (D-011).
- **Final remote Linux dual-backend Gate** as this node’s sole closeout —
  remains a **separate next docs node**, not closed here even if the same
  Actions run is candidate evidence for that later node.
- Prompt templates; maturity raise; quality generated body hand-edits.
- Push without fresh authorization.
- Unrelated `.gitignore` or secrets/external services.
- Treating local macOS-only gates as Linux proof (this closeout uses remote
  Ubuntu evidence).
- Claiming a **universal future** Linux idle guarantee beyond the exact
  tip/run recorded in delivery evidence.

## 9. Executable fixtures / verification

### F0 — Docs contract Gate

| # | Check | Binding assertion |
|---|-------|-------------------|
| F0a | Task authored | Phases A/B/C, idle oracle, non-goals defined |
| F0b | Status truth | plan/roadmap/modules/quality link this task; status **done** after Phase B evidence |
| F0c | `zig build docs-lint` | Pass from task worktree |
| F0d | Score check | `python3 scripts/score_docs.py --check` (or `zig` equivalent); restore report timestamps from HEAD if tooling rewrites only timestamps |
| F0e | `git diff --check` | Clean on intended range |
| F0f | Scope | No product/fixture/build/CI-YAML/maturity/prompt-template edits |

### F1 — Phase A Linux evidence — **complete**

| # | Check | Binding assertion |
|---|-------|-------------------|
| F1a | Tip | `8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (post-errno + post-fuses) |
| F1b | Minimum | process fixture green under curl on Ubuntu (2/2 inside root curl suite) |
| F1c | Preferred | std + curl process fixture on same tip; both 2/2 |
| F1d | Oracle | readiness + `waitBounded(4000)` + exit 0 + stderr/leak assertions inside 2-test fixture |
| F1e | Active honesty | std 130 / curl 11 contract retained (active cases in fixture) |
| F1f | Fuses | Timeout/cancel **not** counted as product pass; this run did **not** fire them |

### F2 — Phase B closeout — **complete**

| # | Check | Binding assertion |
|---|-------|-------------------|
| F2a | No code change | Product/fixture untouched for residual close |
| F2b | Evidence table | host, backend(s), tip, run citation filled |
| F2c | Residual closed | This task `done`; final Linux Gate still separate |

### F3 — Phase C closeout — **N/A**

# verification

## Docs Gate (Pass-path closeout commit)

- [x] Binding task + status truth among plan/roadmap/cli-interaction/modules/quality
- [x] Status **done** via Phase B after fresh approved Linux Actions evidence
- [x] Dependencies listed: cli-sigint-001, ci-hang-sigint-linux-errno-001, ci-hang-ci-fuses-001
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] Score check; report timestamps restored from HEAD if only timestamps rewrote
- [x] `git diff --check`
- [x] Explicit `git add` of allowed docs only
- [x] One local docs commit on `task/ci-hang-sigint-process-idle-001`
- [x] No product Zig, no fixture, no CI YAML, no maturity raise, no push

## Implementation Gate

- [x] Phase A completed on approved Linux runner with citation
- [x] Phase B path followed (no product/fixture change)
- [x] Idle oracle preserved (`waitBounded(4000)`); active std 130 / curl 11 retained
- [x] Fuses exact; timeout/cancel not used as pass; fuses did not fire this run
- [x] Final merged-path Linux Gate still tracked separately (not claimed closed)

# delivery evidence

## Phase B Pass-path evidence (auditable)

| Field | Value |
|-------|--------|
| Path | **Phase B (Pass path)** — no product/fixture change |
| Status | **done** |
| Evidence tip (pushed merged main) | `8a93ec6efb7256413ed3d36e2034bb8fb8a343da` |
| Evidence tip short | `8a93ec6` |
| GitHub Actions run | https://github.com/DaviRain-Su/zag/actions/runs/30273762011 |
| Run created | `2026-07-27T14:10:10Z` |
| Run completed | `2026-07-27T14:12:09Z` (success) |
| Workflow outcome | **success** — both matrix jobs success |
| Ubuntu job name | `Zig ubuntu-latest` |
| Ubuntu job | **success** |
| Ubuntu std step | `Build Summary: 40/40 steps succeeded; 611/611 tests passed` |
| Ubuntu std process-level SIGINT artifact | `run test 2 pass (2 total) 126ms` |
| Ubuntu curl / libcurl | Linux libcurl install **success**; curl step **success** |
| Ubuntu curl step | `42/42 steps succeeded; 610/610 tests passed` |
| Ubuntu curl process-level SIGINT artifact | `run test 2 pass (2 total) 126ms` |
| macOS job name | `Zig macos-latest` |
| macOS job | **success** (std + curl steps success) |
| Idle oracle in fixture | readiness (`you>`) + `waitBounded(4000)` + direct exit **0** + stderr/leak assertions — all inside the **2-test** process fixture |
| Active honesty retained | std **130** / curl **11** contract preserved; active std/curl cases retained in fixture |
| `waitBounded` | **4000** ms — **not** lengthened |
| CI fuses this run | Configured/accepted; **did not fire** (run completed normally) — **not** claimed exercised |
| Product/fixture/build/CI-YAML change | **none** for this residual closeout |
| Maturity | **unchanged** |
| Current Linux idle status | **PASS** at exact tip `8a93ec6` / run `30273762011` — **not** a universal future guarantee |
| Final merged-path Linux dual-backend Gate | **Still open** as separate next docs node — **not** claimed closed by this task (same run may be **candidate** evidence for that later node only) |
| prompt-templates-001 | **Still blocked** until that final Linux Gate node closes |

## Non-claims

- Universal/permanent Linux idle reliability beyond this tip/run.
- Timeout or cancel fuse exercise (neither fired).
- Final merged-path Linux dual-backend Gate closed.
- prompt-templates unblocked.
- Maturity raise.
- Product/fixture code change as part of residual close.
- Historical hang co-root invention.

# non-goals (task boundary)

See §8. This Pass-path closeout records pure-evidence success and status truth
only. No product/fixture implementation was authorized or shipped.

# closeout

**Closed via Phase B (Pass path).** Status **`done`**.

Fresh explicitly approved remote Linux evidence at tip
`8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (Actions run
`30273762011`, created `2026-07-27T14:10:10Z`, completed success
`2026-07-27T14:12:09Z`) shows the existing idle process fixture already
passes on Ubuntu under both std and curl (process-level SIGINT
`2 pass (2 total)` each; root suites **611/611** / **610/610**). macOS job
also success. No product or fixture change.

**Preserved:** `waitBounded(4000)`; active std **130** / curl **11**.

**Closed predecessors (context):**

- `cli-sigint-001` @ `d542332`
- `ci-hang-sigint-linux-errno-001` @ `bc737025`
- `ci-hang-ci-fuses-001` @ `97f43de` (host rails only)

**Still open after this residual (not claimed closed here):**

- **final merged-path remote Linux dual-backend Gate** (separate next docs
  node; this Actions run is at most **candidate** evidence for that node)
- then `prompt-templates-001` may unstall only after that Gate closes

**Current Linux idle status:** **PASS** at exact tip `8a93ec6` / run
`30273762011` — not a universal future guarantee.
