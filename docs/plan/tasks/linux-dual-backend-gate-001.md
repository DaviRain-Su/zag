---
id: linux-dual-backend-gate-001
scope: product/cli-interaction
status: done
priority: P0
depends-on:
  - cli-sigint-001
  - ci-hang-sigint-linux-errno-001
  - ci-hang-ci-fuses-001
  - ci-hang-sigint-process-idle-001
---

# objective

Close the **final merged-path remote Linux dual-backend Gate** for M0
interaction reliability as a **docs-only evidence Gate/closeout**, using
fresh approved remote dual-OS dual-backend GitHub Actions evidence on the
pushed product/CI tip after errno, host CI fuses, and process-idle residual
are already done.

This Gate closes broader M0 Linux dual-backend reliability **only** at the
exact product tip/run scope recorded below — **not** as a universal future
guarantee. No product, fixture, build, or CI-YAML edit is required or
authorized for this closeout: the remote run already green-proved the full
matrix on the pushed tip, and the current base is only two later docs
evidence commits after that tip.

Binding product behavior remains
[CLI interaction](../../modules/cli-interaction.md). Host CI fuses remain
rails only ([quality/README](../../quality/README.md)); timeout/cancel never
counts as product pass.

Depends on:

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [cli-sigint-001](./cli-sigint-001.md) | **done** @ `d542332` | Idle/active SIGINT lifecycle + process fixture existence |
| [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md) | **done** @ `bc737025` | Raw Linux errno decode so curl-linked `drainWake` terminates (`linuxRawErrno`) |
| [ci-hang-ci-fuses-001](./ci-hang-ci-fuses-001.md) | **done/closed** @ `97f43de` (impl `1d3abaa`) | Host concurrency + 30m/job rails (not product proof) |
| [ci-hang-sigint-process-idle-001](./ci-hang-sigint-process-idle-001.md) | **done** Phase B @ tip `8a93ec6` / run `30273762011` | Idle process-fixture residual Pass path; same run is the Gate evidence |

Does **not** own Core boundary, prompt-templates implementation, maturity
raise, Runtime Extensions L0 change, product/fixture/build/CI-YAML edits, or
push.

# context

## Why this Gate existed

1. M0 (`cli-sigint-001`) established idle/active SIGINT lifecycle and the
   process fixture.
2. `ci-hang-sigint-linux-errno-001` fixed raw-Linux errno decode under
   curl-linked `link_libc` (`linuxRawErrno` / `std.os.linux.errno`).
3. `ci-hang-ci-fuses-001` added workflow concurrency + 30m job timeout as
   **visible failures/cancellations**, never product hang proof. Exact
   fuses: `group: ${{ github.workflow }}-${{ github.ref }}`,
   `cancel-in-progress: true`, `jobs.test.timeout-minutes: 30`; full
   ubuntu/macos + std/curl matrix; no `continue-on-error`.
4. `ci-hang-sigint-process-idle-001` closed the residual idle oracle via
   Phase B on the same remote Actions run (no product/fixture change).
5. Remaining M0 reliability node: record the **final merged-path** remote
   dual-OS dual-backend Gate as **done** at exact tip/run scope so
   `prompt-templates-001` may unstall for later docs-first planning.

## Adjacent work

| Node | Relationship |
|------|--------------|
| process-idle residual | **done** predecessor; same tip/run is Gate evidence |
| prompt-templates-001 | **Unblocked** for later docs-first planning / next planned capability; **task file not authored here**; **not** implemented |
| Core ownership / D-011 | Unchanged; CLI owns SIGINT |
| Runtime Extensions | Remains **L0**; all maturity rows unchanged |

## References

- Binding product: [cli-interaction](../../modules/cli-interaction.md)
- Quality / CI fuses: [quality/README](../../quality/README.md)
- Predecessors: [cli-sigint-001](./cli-sigint-001.md),
  [ci-hang-sigint-linux-errno-001](./ci-hang-sigint-linux-errno-001.md),
  [ci-hang-ci-fuses-001](./ci-hang-ci-fuses-001.md),
  [ci-hang-sigint-process-idle-001](./ci-hang-sigint-process-idle-001.md)
- Live fixture: `packages/zag-cli/src/sigint_process_fixture.zig`
- Live product signal: `packages/zag-cli/src/sigint.zig`
- Build targets: `zig build sigint-process-fixture`, root `zig build test`

# path

## Docs (this closeout)

- `docs/plan/tasks/linux-dual-backend-gate-001.md` — this task
- status / cross-link truth only (max set for this Gate):
  - `docs/plan/README.md`
  - `docs/roadmap.md`
  - `docs/modules/cli-interaction.md`
  - `docs/modules/README.md`
  - `docs/quality/README.md`
  - `docs/plan/tasks/ci-hang-sigint-process-idle-001.md`

## Implementation path

**None.** Docs-only Gate/closeout: existing pushed product/CI tip already
green on approved remote dual-OS dual-backend Actions evidence. No product,
fixture, build, or CI-YAML edit authorized or performed. Current worktree
base `b953e0b` is only two later docs evidence commits after evidence tip
`8a93ec6`; no product/build/`.github` changes after the remote run.

# contract

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-cli` (`sigint.zig`) | SIGINT Guard, self-pipe, interruptible read, `linuxRawErrno`, process exit UX | Agent cancel semantics beyond binding `*Flag`; HTTP backends |
| Process fixture (`sigint_process_fixture.zig`) | Host-native spawn/wait/kill, idle oracle, active honesty, leak checks | Product Linux non-libc claim; CI workflow knobs |
| `zag-agent-core` | atomic `CancelFlag` only | signal handlers, exit codes, fixtures |
| CI workflow / fuses | Host timeout + concurrency (already closed) | Product correctness claims |
| This task | Final merged-path Gate evidence protocol + M0 reliability close at exact tip/run | Universal future guarantee; prompt-templates implementation; maturity raise |

## 2. Preserved product oracles (binding)

| Oracle | Binding assertion |
|--------|-------------------|
| Idle wait | `waitBounded(io, pid, 4000)` returns non-null (child exits within 4000 ms) — **not** lengthened |
| Idle exit | Direct child exit **0** (`WIFEXITED`); no stderr `error:` / stack / `ReadFailed` |
| Active std | Hard-escape path still exits **130** |
| Active curl | Cooperative/active cancel path still exits **11** with cancelled terminal honesty |
| Errno | Product Linux raw sites use `linuxRawErrno` / `std.os.linux.errno` only |
| Fuses | Exact `${{ github.workflow }}-${{ github.ref }}` + `cancel-in-progress: true` + 30m/job; full dual-OS dual-backend matrix; no `continue-on-error` |

## 3. CI fuses and non-masking

| Event | Allowed as product pass? |
|-------|---------------------------|
| Job `timeout-minutes` fire | **No** — visible failure only |
| Concurrency cancel-in-progress | **No** — cancelled, not success |
| Fixture `waitBounded` null / timeout | **No** — fixture failure, not product pass |
| `continue-on-error`, skip, soft green | **Forbidden** |

**This closeout run completed normally.** Job/step success is product/test
green; fuses were configured/accepted on the workflow but **did not fire**.
Do **not** claim timeout or cancel was exercised as correctness proof.

## 4. Gate scope honesty

- **Closed:** M0 Linux dual-backend reliability Gate at exact pushed tip
  `8a93ec6efb7256413ed3d36e2034bb8fb8a343da` / Actions run `30273762011`.
- **Not claimed:** universal/permanent future Linux dual-backend guarantee
  beyond that tip/run; fuse exercise; maturity raise; product code change.
- **Unblocked (planning only):** `prompt-templates-001` for later docs-first
  planning / next planned capability — **no task file created in this Gate**.

## 5. Defaults and safety

- Permission default **ask**, workspace jail, shell protect unchanged.
- No secrets, real API keys, or external network services in fixtures.
- Product Linux signal path stays raw syscalls (`linuxRawErrno` already fixed).
- No Core ownership change; Runtime Extensions remains L0; maturity rows
  unchanged.

## 6. Budgets

| Budget | Bound |
|--------|-------|
| Idle post-SIGINT wait | `waitBounded(..., 4000)` ms (contract-preserved) |
| CI job wall (host fuse) | 30 minutes per matrix job (unchanged; **not fired** this run) |
| Docs-only Gate closeout | docs-lint + score-check + diff-check; no product commit |

## 7. Compatibility

- std vs curl capability truth unchanged.
- headless cancel exit `11` / hard escape `130` unchanged.
- Maturity rows unchanged; Runtime Extensions **L0** unchanged.
- Unrelated `.gitignore`, packaging out of path.

## 8. Non-goals

- Product, fixture, build, or CI-YAML edits.
- Claiming timeout/cancel fuse exercise (neither fired).
- Universal future Linux dual-backend reliability beyond exact tip/run.
- Creating or implementing `prompt-templates-001`.
- Maturity raise; Runtime Extensions L0 change; quality generated body hand-edits.
- Push; secrets/external services.
- Unrelated `.gitignore` change.
- Softening `waitBounded(4000)` or active std **130** / curl **11**.

## 9. Executable fixtures / verification

### F0 — Docs Gate

| # | Check | Binding assertion |
|---|-------|-------------------|
| F0a | Task authored | Gate scope, oracles, non-goals, evidence table defined |
| F0b | Status truth | plan/roadmap/modules/quality/process-idle link this task; status **done** |
| F0c | `zig build docs-lint` | Pass from task worktree |
| F0d | Score check | `python3 scripts/score_docs.py --check`; restore report timestamps from HEAD if tooling rewrites only timestamps |
| F0e | `git diff --check` | Clean on intended range |
| F0f | Scope | No product/fixture/build/CI-YAML/maturity/prompt-template edits |

### F1 — Remote dual-backend evidence — **complete**

| # | Check | Binding assertion |
|---|-------|-------------------|
| F1a | Tip | `8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (post-errno + post-fuses + process-idle evidence lineage) |
| F1b | Run | Actions [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) success |
| F1c | Ubuntu std | **40/40** steps; **611/611** tests; process-level SIGINT **2/2** `126ms` |
| F1d | Ubuntu curl | **42/42** steps; **610/610** tests; process-level SIGINT **2/2** `126ms`; libcurl install success |
| F1e | macOS | job + both std/curl steps success |
| F1f | Ancillary | OpenAPI **287/287**; catalog **40**; docs readability **91** / security **73** (run/context) |
| F1g | Oracles | `waitBounded(4000)` + idle exit **0**; active std **130** / curl **11**; `linuxRawErrno` preserved |
| F1h | Fuses | Configured/accepted; **did not fire**; timeout/cancel **not** correctness proof |

### F2 — Docs closeout — **complete**

| # | Check | Binding assertion |
|---|-------|-------------------|
| F2a | No code change | Product/fixture/build/CI-YAML untouched for Gate close |
| F2b | Evidence table | host, backend(s), tip, run citation filled |
| F2c | Gate closed | This task `done`; M0 dual-backend reliability closed **at exact tip/run only** |
| F2d | Planning unblock | `prompt-templates-001` unblocked for later docs-first planning; task file **not** created |

# verification

## Docs Gate (this closeout commit)

- [x] Binding task + status truth among plan/roadmap/cli-interaction/modules/quality/process-idle
- [x] Status **done** after Goal-4 independent verification that evidence is sufficient
- [x] Dependencies listed: cli-sigint-001, errno, fuses, process-idle
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] Score check; report timestamps restored from HEAD if only timestamps rewrote
- [x] `git diff --check`
- [x] Explicit `git add` of allowed docs only
- [x] One local docs commit on `task/linux-dual-backend-gate-001`
- [x] No product Zig, no fixture, no CI YAML, no maturity raise, no push

## Implementation Gate

- [x] Remote dual-OS dual-backend evidence complete on approved tip/run
- [x] No product/fixture/build/CI-YAML change for this Gate
- [x] Idle oracle preserved (`waitBounded(4000)` + exit 0); active std **130** / curl **11** retained
- [x] `linuxRawErrno` and exact fuses/full matrix/no continue-on-error preserved in written truth
- [x] Fuses did not fire; timeout/cancel not used as pass
- [x] M0 Linux dual-backend reliability closed **only** at exact tip/run scope
- [x] `prompt-templates-001` unblocked for later planning only; task file not created

# delivery evidence

## Gate evidence (auditable)

| Field | Value |
|-------|--------|
| Path | **Docs-only Gate/closeout** — no product/fixture/build/CI-YAML change |
| Status | **done** |
| Evidence tip (pushed product/CI tip) | `8a93ec6efb7256413ed3d36e2034bb8fb8a343da` |
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
| OpenAPI | **287/287** |
| Catalog | **40** |
| Docs scores (context) | readability **91** / security **73** |
| Idle oracle | readiness (`you>`) + `waitBounded(4000)` + direct exit **0** + stderr/leak assertions — inside **2-test** process fixture |
| Active honesty retained | std **130** / curl **11** |
| `waitBounded` | **4000** ms — **not** lengthened |
| `linuxRawErrno` | preserved (predecessor `bc737025`) |
| CI fuses | Exact workflow+ref concurrency + cancel-in-progress + 30m/job; full matrix; no `continue-on-error`; configured/accepted; **did not fire** |
| Product/fixture/build/CI-YAML change after run | **none** — base `b953e0b` is only two later docs evidence commits after `8a93ec6` |
| Predecessors / ancestors | errno `bc737025`; fuses impl `1d3abaa` / reviewed tip `97f43de`; process-idle Phase B on same run |
| Maturity | **unchanged**; Runtime Extensions **L0** unchanged |
| M0 Linux dual-backend reliability | **CLOSED** at exact tip `8a93ec6` / run `30273762011` only — **not** a universal future guarantee |
| prompt-templates-001 | **Unblocked** for later docs-first planning; task file **not** authored; **not** implemented |

## Non-claims

- Universal/permanent Linux dual-backend reliability beyond this tip/run.
- Timeout or cancel fuse exercise (neither fired).
- Product/fixture/build/CI-YAML change as part of Gate close.
- Maturity raise; Runtime Extensions L0 change.
- `prompt-templates-001` task file or implementation.
- Historical hang co-root invention.
- origin/main advanced past `8a93ec6` by this docs tip (local docs tips unpushed).

# non-goals (task boundary)

See §8. This docs-only Gate closeout records remote dual-backend success and
status truth only. No product/fixture implementation was authorized or shipped.

# closeout

**Closed as docs-only final merged-path Linux dual-backend Gate.** Status
**`done`**.

Fresh explicitly approved remote dual-OS dual-backend evidence at tip
`8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (Actions run
`30273762011`, created `2026-07-27T14:10:10Z`, completed success
`2026-07-27T14:12:09Z`) shows full matrix green: Ubuntu std **40/40 · 611/611**
with process-level SIGINT **2/2** `126ms`; Ubuntu curl **42/42 · 610/610** with
process-level SIGINT **2/2** `126ms` and libcurl install success; macOS job
and both std/curl steps success; OpenAPI **287/287**, catalog **40**, docs
**91/73**. No product or fixture change. Current base `b953e0b` is only two
later docs evidence commits after `8a93ec6`.

**Preserved:** `waitBounded(4000)`; idle exit **0**; active std **130** /
curl **11**; `linuxRawErrno`; exact fuses/full matrix/no `continue-on-error`.

**Closed predecessors (context):**

- `cli-sigint-001` @ `d542332`
- `ci-hang-sigint-linux-errno-001` @ `bc737025`
- `ci-hang-ci-fuses-001` @ `97f43de` (impl `1d3abaa`; host rails only)
- `ci-hang-sigint-process-idle-001` Phase B @ tip `8a93ec6` / run `30273762011`

**M0 Linux dual-backend reliability:** **closed** at exact tip `8a93ec6` /
run `30273762011` only — not a universal future guarantee.

**Unblocked (planning only):** `prompt-templates-001` for later docs-first
planning / the next planned capability. Task file **not** created; not
implemented.

**Fuses this run:** configured/accepted; **did not fire** — timeout/cancel
is not correctness proof.

**No push.** origin/main remains `8a93ec6`; local docs tips are unpushed.
