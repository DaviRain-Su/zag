---
id: ci-hang-sigint-process-idle-001
scope: product/cli-interaction
status: blocked
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

This file is an **evidence-first task contract**, not an implementation
authorization. No product, fixture, build, or CI-YAML edit is authorized by
authoring this contract alone.

**Blocker (status `blocked`):** acquisition of a fresh, explicitly approved
Linux runner or remote action on a post-errno/post-fuses tip. Without that
evidence surface, the residual stays open and this node remains blocked.

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

## Why this residual exists

1. M0 (`cli-sigint-001`) established the idle process fixture: real direct
   `zag` binary, isolated cwd, synthetic credentials, observe `you>`, first
   SIGINT, bounded exit `0` without stderr `error:` / stack / `ReadFailed`.
2. `ci-hang-sigint-linux-errno-001` fixed raw-Linux errno decode under
   curl-linked `link_libc` so self-pipe drain terminates. Closeout used local
   macOS dual-backend Gates; **no fresh post-fix remote Linux runner**.
3. `ci-hang-ci-fuses-001` added workflow concurrency + 30m job timeout. Those
   are **visible failures/cancellations**, never product hang proof.
4. **Current Linux status of the idle process fixture is unknown.** Local
   macOS std/curl root Gates (e.g. **611/611** / **610/610**) and process
   fixture **2/2** are context only — **not** Linux proof.

Historical hang narratives must not be invented or co-rooted here. Only
**fresh post-errno/fuses Linux evidence** may drive pass/fail for this node.

## Adjacent work (not this node)

| Node | Relationship |
|------|--------------|
| final merged-path Linux dual-backend Gate | Separate later Gate: full remote Linux after this residual is resolved; still required before prompt-templates |
| prompt-templates-001 | Blocked on residual reliability chain (process-idle + final Linux Gate) |
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

## Docs (this contract node)

- `docs/plan/tasks/ci-hang-sigint-process-idle-001.md` — this task
- status / cross-link truth only:
  - `docs/plan/README.md`
  - `docs/roadmap.md`
  - `docs/modules/cli-interaction.md`
  - `docs/modules/README.md`
  - `docs/quality/README.md`

## Implementation path (not authorized by docs-only commit)

**None until Phase A fails with a unique evidenced root cause (Phase C).**

If and only if Phase C authorizes a change, the minimal edit surface is:

- `packages/zag-cli/src/sigint.zig` and/or
- `packages/zag-cli/src/sigint_process_fixture.zig`

**Forbidden without unique evidence:** lengthening `waitBounded`, silent
retry, skip, `continue-on-error`, timeout-as-success, Core ownership edits,
CI fuse removal/softening, maturity raise, prompt templates, unrelated
`.gitignore`, secrets/external services, push without fresh authorization.

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
necessity proven by unique root-cause evidence.

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

## 4. Binding phases

### Phase A — Evidence acquisition only

**Prerequisite tip:** post-errno (`bc737025` lineage) **and** post-fuses
(`97f43de` lineage) code. Prefer current main tip after those closes.

**Authorization:** a **fresh, explicitly approved** Linux runner or remote
action. This docs contract does **not** grant that approval.

**Minimum evidence (curl):**

```text
zig build sigint-process-fixture -Dhttp_backend=curl --summary all
```

**Preferred evidence (std + curl):**

```text
zig build sigint-process-fixture -Dhttp_backend=std --summary all
zig build sigint-process-fixture -Dhttp_backend=curl --summary all
```

When the **final** merged-path Linux dual-backend Gate later runs (separate
node), full root suites are required:

```text
zig build test -Dhttp_backend=std --summary all
zig build test -Dhttp_backend=curl --summary all
```

This process-idle node may close on focused process-fixture evidence if Phase
B criteria are met; the final Gate remains separate.

**Record for every run:** host identity, backend (`std` / `curl`), tip SHA,
command lines, pass/fail per assertion, and a durable run citation
(log path / Actions run id / approved runner session id as applicable).

**Phase A does not edit product or fixture code.**

### Phase B — Pass path (no product/fixture change)

If fresh Linux evidence shows **existing code already passes** the preserved
idle oracle (and active std 130 / curl 11 remain green on the focused
fixture where run):

1. Make **no** product or fixture change.
2. Record host / backend / tip / run citation in this task’s delivery evidence.
3. Mark this residual **closed** (status → `done` only after that record).
4. Leave the **final merged-path Linux dual-backend Gate** as a separate open
   node.

### Phase C — Fail path (repro → investigate → minimal edit only if unique)

If Phase A fails:

1. **Before any edit**, capture a deterministic post-errno Linux repro:
   process state, full relevant output, and **which assertion** failed
   (marker wait, `waitBounded` null, non-zero exit, stderr leak class, etc.).
2. Distinguish **child product behavior** from **harness/timing/fixture**
   noise.
3. Run deep investigation + a **fresh** verifier on the same tip class.
4. Only a **unique, evidenced root cause** may authorize a **minimal**
   `zag-cli` / fixture change.
5. **Forbidden “fixes”:** silent `waitBounded` lengthening; retry loops that
   hide failure; skip; `continue-on-error`; timeout-as-success; inventing
   historical co-roots without repro.
6. If evidence is **ambiguous**, remain **`blocked`** (or return to Phase A)
   — do not ship a speculative patch.

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
| Prompt readiness wait | existing fixture marker bound (e.g. 8000 ms class) — do not weaken |
| CI job wall (host fuse) | 30 minutes per matrix job (unchanged) |
| Docs-only node | docs-lint + score-check + diff-check; **no** Linux runner required for contract authoring |

## 7. Compatibility

- std vs curl capability truth unchanged.
- headless cancel exit `11` / hard escape `130` unchanged.
- Maturity rows unchanged by this residual alone.
- Unrelated `.gitignore`, packaging, prompt templates out of path.

## 8. Non-goals

- Inventing or co-rooting the historical failure without fresh Linux repro.
- Changing `waitBounded(4000)` without contract necessity proven by unique
  root cause.
- Product or fixture edits before Phase A fail + Phase C repro capture.
- Removing, softening, or claiming CI fuses as product hang proof.
- Changing Core ownership (D-011).
- Final remote Linux dual-backend Gate (full monorepo) as this node’s sole
  closeout.
- Prompt templates; maturity raise; quality generated body hand-edits.
- Push without fresh authorization.
- Unrelated `.gitignore` or secrets/external services.
- Treating local macOS std/curl **611/611** / **610/610** or process fixture
  **2/2** as Linux proof.
- Claiming current Linux status known without Phase A evidence.

## 9. Executable fixtures / verification

### F0 — Docs contract Gate (this node)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F0a | Task authored | This file defines phases A/B/C, idle oracle, non-goals, blocker |
| F0b | Status truth | plan/roadmap/modules/quality link this task; status **blocked** on runner authorization/evidence |
| F0c | `zig build docs-lint` | Pass from task worktree |
| F0d | Score check | `python3 scripts/score_docs.py --check` (or `zig` equivalent); restore report timestamps from HEAD if tooling rewrites only timestamps |
| F0e | `git diff --check` | Clean on intended range |
| F0f | Scope | No product/fixture/build/CI-YAML/maturity/prompt-template edits |

### F1 — Phase A Linux evidence (blocked until approved runner)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F1a | Tip | Post-errno + post-fuses code |
| F1b | Minimum | `zig build sigint-process-fixture -Dhttp_backend=curl --summary all` on approved Linux |
| F1c | Preferred | Also std backend process fixture on same tip class |
| F1d | Oracle | Assertions in §2 recorded pass/fail with citation |
| F1e | Active honesty | std 130 and curl 11 remain when those fixture cases run |
| F1f | Fuses | Timeout/cancel not counted as product pass |

### F2 — Phase B closeout (if pass)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F2a | No code change | Product/fixture untouched for residual close |
| F2b | Evidence table | host, backend(s), tip, run citation filled |
| F2c | Residual closed | This task `done`; final Linux Gate still separate |

### F3 — Phase C closeout (if fail → fix)

| # | Check | Binding assertion |
|---|-------|-------------------|
| F3a | Repro first | Deterministic post-errno Linux repro captured pre-edit |
| F3b | Unique cause | Root cause documented and not ambiguous |
| F3c | Minimal edit | Only zag-cli/fixture as authorized; no silent bound games |
| F3d | Fresh verifier | Re-run F1 class on fix tip; dual-backend honesty retained |
| F3e | Independent review | Same delivery bar as other P0 product nodes before `done` |

# verification

## Docs Gate (this commit)

- [x] Binding task + status truth among plan/roadmap/cli-interaction/modules/quality
- [x] Status **blocked** on fresh approved Linux runner/remote action
- [x] Dependencies listed: cli-sigint-001, ci-hang-sigint-linux-errno-001, ci-hang-ci-fuses-001
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] Score check; report timestamps restored from HEAD if only timestamps rewrote
- [x] `git diff --check`
- [x] Explicit `git add` of allowed docs only
- [x] One local docs commit on `task/ci-hang-sigint-process-idle-001`
- [x] No product Zig, no fixture, no CI YAML, no maturity raise, no push

## Implementation Gate (future; not this commit)

- [ ] Phase A completed on approved Linux runner with citation
- [ ] Phase B **or** Phase C path followed without non-goal violations
- [ ] Idle oracle preserved; fuses exact; no timeout-as-pass
- [ ] Final merged-path Linux Gate still tracked separately

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | this file (docs-first residual) |
| Status | **blocked** — fresh explicitly approved Linux runner / remote action not yet acquired |
| Tip class required | post-`bc737025` errno + post-`97f43de` fuses |
| Phase A run | *pending authorization* |
| Host / backend / tip / citation | *empty until Phase A* |
| Product/fixture change | **none** in docs contract commit; none unless Phase C |
| Maturity | **unchanged** |
| Not claimed | Linux idle fixture pass/fail; broader Linux reliability closed; final remote Gate; prompt-templates unblocked; remote Actions fuse enforcement as product proof |

# non-goals (task boundary)

See §8. This docs node only authors the residual contract and status truth.
Implementation remains unauthorized until Phase A fails with unique cause
(Phase C) or Phase B records a pure-evidence pass.

# closeout

**Not closed.** Status remains **`blocked`** on fresh explicitly approved
Linux runner / remote action evidence (Phase A).

**Closed predecessors (context only):**

- `cli-sigint-001` @ `d542332`
- `ci-hang-sigint-linux-errno-001` @ `bc737025`
- `ci-hang-ci-fuses-001` @ `97f43de` (host rails only)

**Still open after this residual eventually closes:**

- final merged-path remote Linux dual-backend Gate
- then `prompt-templates-001` may unstall on that residual chain

**Context-only (not Linux proof):** local macOS std/curl root counts and
process fixture **2/2**. Current Linux status: **unknown**.
