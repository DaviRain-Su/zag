---
id: post-tui-remote-dual-backend-gate-001
scope: product/cli-interaction + host-shell/tui-minimal (post-TUI default-path remote dual-backend Gate; docs-only Phase A contract)
status: in-progress
priority: P0
depends-on:
  - tui-minimal-001
  - linux-dual-backend-gate-001
---

# objective

Freeze a **docs-first, two-phase fail-closed** contract for a **fresh remote
default-path dual-OS dual-backend GitHub Actions Gate** on the exact local
post-TUI product+closeout tip:

**`b1513073190089bd2dc2473a466373c8a1702f1f`**

This node proves that the **default (non-TUI) CI matrix** still goes green on
that tip after the minimal TUI implementation landed and local docs closeout
followed. It is **post-TUI default-path regression evidence**, not a
cross-platform TUI maturity Gate and **not** a claim that remote CI runs
`-Dtui=true`.

**Phase A (this commit / this task state):** author the contract + cross-link
status truth only. Status stays **`in-progress`**. No run id. No Gate green.
No push.

**Phase B (only after a fresh, explicit user authorization):** read-only
remote drift check → if still ff-able, exact normal push of **only**
`b151307…` to `origin/main` → watch the triggered Actions run with
`headSha == b151307…` → record real run id/URL and observed log numbers →
docs closeout. Never force-push. Never docs-greenwash a failed job.

Depends on:

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [tui-minimal-001](./tui-minimal-001.md) | **done** @ impl `f8f7f55` (contract PASS @ `c7a8f3a`; docs closeout lineage `9d69574` → `8694fbb` → `b151307`) | Post-TUI product tip + local merged-path evidence; this Gate is the remote default-path follow-on that TUI closeout explicitly **did not** claim |
| [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md) | **done** (docs-only) @ tip `8a93ec6` / run `30273762011` | Prior exact merged-path product+remote dual-backend evidence pattern and M0 dual-backend baseline; **historical only** — numbers and run id are **not** reusable as this node’s PASS |

Does **not** own: product/fixture/build/CI-YAML edits; TUI remote maturity;
theme/RPC/ACP/E2/E3; maturity row raise; push without Phase B authorization.

# context

## Why this Gate exists

1. [tui-minimal-001](./tui-minimal-001.md) closed the minimal host TUI at
   implementation tip `f8f7f55` with dual final reviews PASS and **local macOS**
   default + TUI dual-backend Gates. Docs closeout tips
   (`9d69574` → `8694fbb` → `b151307`) stayed **local**.
2. Local remote-tracking reflog observed an **external/other push** of
   implementation tip `f8f7f55` to `origin/main`. That push was **not**
   executed or authorized by the TUI closeout. **Branch presence ≠ remote
   Gate.** Current remote-tracking tip `origin/main` may equal `f8f7f55`
   while the full local post-TUI tip (impl + docs closeout) is
   `b151307…`.
3. Historical M0 remote Gate
   [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md) closed only
   at exact tip `8a93ec6` / run `30273762011`. That is a **prior tip/run
   only** — not a future guarantee and **not** evidence for post-TUI tips.
4. Remaining honesty gap: record a **fresh** remote default dual-OS dual-backend
   Gate for the exact post-TUI tip `b151307…` under the **current** workflow
   (no `-Dtui` step).

## Adjacent work (not this node)

| Node | Relationship |
|------|--------------|
| theme-001 / RPC / ACP / extension UI / WASM | Stay **pending / deferred**; **fresh Goal** required; this Gate does **not** select them |
| TUI PTY / `-Dtui=true` remote | **Not claimed** — CI has no TUI step; PTY remains local macOS product path only |
| Maturity matrix | **No** new or raised row (Headless/Process stays L2; Runtime Extensions L0; no TUI row) |
| Product packages / build / `.github` | **Out of path** for this node |

## References

- Prior remote Gate pattern: [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md)
- TUI product closeout: [tui-minimal-001](./tui-minimal-001.md) · [tui-minimal](../../modules/tui-minimal.md)
- CLI / SIGINT / M0: [cli-interaction](../../modules/cli-interaction.md)
- Host CI fuses: [quality/README](../../quality/README.md) · `.github/workflows/ci.yml`
- Plan status: [plan/README](../README.md) · [roadmap](../../roadmap.md)

# baseline (worktree truth)

| Field | Value |
|-------|--------|
| Task worktree baseline (exact) | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Tip short | `b151307` |
| Tip message | `docs(tui-minimal-001): record observed remote tip truth` |
| Lineage on tip | impl `f8f7f55` + docs closeout `9d69574` + feature-correspondence `8694fbb` + remote-truth follow-up `b151307` |
| `f8f7f55` relation | Ancestor of `b151307` (three later **docs-only** commits) |
| Local remote-tracking observation | `origin/main` observed at implementation tip `f8f7f55` (external/other push); **not** equal to full post-TUI tip `b151307` |
| Phase A product code delta | **none required** — Gate tip already contains the product under test |

**Pattern:** same “first freeze exact target tip, later record remote evidence”
shape used by prior exact merged-path Gates. The Phase A contract commit may
remain **local-only**. The **remote Gate tip stays `b151307…`** and does **not**
recursively rebind to this contract commit’s own SHA.

# authority / ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| This task (docs) | Exact tip identity; Phase A/B state machine; remote drift matrix; push authorization boundary; evidence schema; acceptance/non-goals | Product/fixture/build/CI edits; inventing run ids; greenwashing failed jobs |
| `.github/workflows/ci.yml` (unchanged) | Default dual-OS dual-backend steps + host fuses already closed | TUI steps (none exist); product hang proof via timeout/cancel |
| `zag-cli` / `zag-tui` / other packages | Unchanged product behavior under test | Edits from this node |
| Coordinator / user | Explicit Phase B push authorization | Silent force-push; push of Phase A docs commits with product tip |

# exact target identity

| Identity | Binding value |
|----------|----------------|
| **Remote Gate tip (full SHA)** | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| What it includes | TUI impl `f8f7f55` + docs closeout `9d69574`/`8694fbb` + remote-truth follow-up `b151307` |
| What it is **not** | A TUI-on CI tip; a rebind of the historical `8a93ec6` Gate; this Phase A contract’s own later SHA |
| Acceptable Actions `headSha` for PASS | **Exactly** `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Forbidden as PASS | Any other SHA; cancelled/timeout/skipped runs; old historical run `30273762011`; local-only TUI numbers as remote proof |

# Phase A / Phase B state machine

```text
Phase A (CURRENT) — docs contract only
  ├─ author this task + cross-links
  ├─ status: in-progress
  ├─ independent review PASS → ff-only local merge allowed
  ├─ NO push
  ├─ NO run id
  └─ Gate NOT green

        │  only after fresh explicit user authorization
        ▼

Phase B — remote evidence (NOT authorized by Phase A alone)
  1. read-only remote check (fetch optional only if user allows read;
     never force-push)
  2. remote drift matrix (below) — STOP + rebind/re-review if blocked
  3. if clear: exact normal push/refspec of **b151307 only** → origin/main
     (do NOT push Phase A / later evidence docs commits)
  4. watch GitHub Actions run for that push
  5. require: headSha == b151307… ; event/branch correct; conclusion success
  6. record real run id/URL + observed log numbers
  7. only then status → done (separate docs closeout commit)
```

| Phase | Allowed | Forbidden |
|-------|---------|-----------|
| **A** | Docs under allowed paths; local commit; local ff-only after review | Push; run id; Gate green; product/CI edits |
| **B** (authz required) | Read-only remote inspect; exact normal push of `b151307`; watch run; evidence docs | Force push; push of non-tip commits; copy historical run numbers; mark done on timeout/cancel/other SHA |

# remote drift matrix (Phase B pre-push)

Before any push, inspect live remote (read-only). Decide:

| Observation | Action |
|-------------|--------|
| `origin/main` (or live remote main) still **fast-forwardable** from current remote tip to `b151307` along the normal path (remote has `f8f7f55` lineage; `b151307` is descendant) and `b151307` **not** already on remote without a matching new run | Proceed with authorized exact push of `b151307` only |
| Remote already **contains** `b151307` **and** a new Actions run with `headSha == b151307` exists | Do **not** re-push; record that run if it meets evidence schema; else STOP |
| Remote already contains `b151307` but **no** corresponding new successful run for that SHA | STOP — do not invent green; investigate / re-authorize observation only |
| Remote main **diverged** so `f8f7f55 → b151307` is **not** a normal fast-forward (rewritten history, other tip, force-required) | **STOP** — rebind tip and re-review; **never force-push** |
| Remote advanced past unrelated commits that make `b151307` non-ff | **STOP** — rebind/re-review; no force-push |

# push authorization boundary

| Rule | Binding |
|------|---------|
| Phase A | **No push** of any kind from this task as part of contract authoring |
| Phase B push | Requires **fresh, explicit user authorization** in the authorizing conversation |
| What may be pushed | **Only** exact tip `b1513073190089bd2dc2473a466373c8a1702f1f` to `origin/main` via **normal** push/refspec |
| What must not be pushed with the Gate tip | Phase A contract commits; later Phase B evidence/closeout docs commits (those may stay local-only after the Gate, same pattern as prior Gate evidence docs) |
| Force push | **Forbidden** |
| Refspec honesty | Push must not silently include unrelated worktree commits |

# workflow / step evidence schema (Phase B only)

Authoritative workflow file (read-only for this node): `.github/workflows/ci.yml`.

## Host rails (must remain; not product PASS)

| Key | Required value |
|-----|----------------|
| `concurrency.group` | `${{ github.workflow }}-${{ github.ref }}` |
| `concurrency.cancel-in-progress` | `true` |
| `jobs.test.timeout-minutes` | `30` |
| `strategy.fail-fast` | `false` |
| Matrix OS | `ubuntu-latest`, `macos-latest` |
| `continue-on-error` | **absent / false** on Gate steps |

Fuse fire (timeout or cancel-in-progress) = **not** product PASS.

## Default (non-TUI) matrix bar — record observations from the real run

Each matrix job name form: `Zig ${{ matrix.os }}` (e.g. `Zig ubuntu-latest`,
`Zig macos-latest`). Sequential steps (actual YAML order):

1. Checkout
2. Install Zig 0.16.0
3. Python (path coverage script)
4. Catalog sources in sync — `python3 packages/zag-ai/scripts/generate_catalog.py --check`
5. Docs score — `python3 scripts/score_docs.py --check`
6. Docs lint — `python3 scripts/lint_docs.py`
7. OpenAPI path coverage (openai-zig)
8. **`zig build test --summary all`** (std backend)
9. Install libcurl headers (Linux only)
10. **`zig build test -Dhttp_backend=curl --summary all`**
11. `zig build` (install zag)
12. openai-zig package tests
13. openai-zig examples compile

### Evidence fields to fill only from a real `headSha == b151307…` success run

| Field | Rule |
|-------|------|
| Run id | Real GitHub Actions run id (not copied from history) |
| Run URL | `https://github.com/DaviRain-Su/zag/actions/runs/<id>` |
| `headSha` | Must equal `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Event / branch | `push` (or the actually authorized event) on `main`/`master` as observed |
| Conclusion | **success** |
| Ubuntu job | success; record std step summary (steps/tests) + curl step summary + libcurl install success |
| macOS job | success; record std + curl step success / summaries |
| Catalog / docs score / docs lint / OpenAPI | Record observed values from that run’s logs |
| Build / package / examples | success as in workflow |
| Fuses | State whether they fired; timeout/cancel **never** count as PASS |

### Explicit non-claims for this Gate’s bar

- **No** remote `-Dtui=true` / TUI job / PTY remote claim (CI has no TUI step).
- **No** reuse of historical run `30273762011` / tip `8a93ec6` numbers as this tip’s PASS.
- **No** reuse of local TUI matrix numbers (`711/711`, etc.) as remote proof.
- **No** maturity row add/raise.

## Phase A evidence table (intentionally empty of run ids)

| Field | Phase A value |
|-------|----------------|
| Status | **`in-progress`** (contract freeze) |
| Target Gate tip | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Remote Actions run id | **not recorded** (Phase B only) |
| Remote Actions URL | **not recorded** (Phase B only) |
| Gate green? | **No** |

# path

## Allowed (this node)

| Path | Role |
|------|------|
| `docs/plan/tasks/post-tui-remote-dual-backend-gate-001.md` | this task (create) |
| `docs/plan/README.md` | Active DAG + task index |
| `docs/roadmap.md` | status truth |
| `docs/modules/cli-interaction.md` | cross-link (non-claim) |
| `docs/modules/tui-minimal.md` | cross-link (remote Gate pending; no claim invent) |
| `docs/modules/README.md` | module index |
| `docs/plan/tasks/tui-minimal-001.md` | cross-link / non-claim only |
| `docs/quality/README.md` | quality / fuses adjacency |
| `docs/maturity.md` | non-raise honesty only |
| `docs/INDEX.md` | index pointer |
| generated quality reports | **only if** body/score materially changes; restore if timestamp-only |

## Forbidden

- `packages/**` (including `packages/zag-tui/README.md`)
- `build.zig*` · `src/**` · fixtures · schemas
- `.github/**` (including `ci.yml`)
- Product/CI/build edits of any kind
- Deleting worktrees; merge to remote; push from Phase A
- Writing fabricated run ids

# acceptance / checklists

## Phase A — Docs contract (current)

- [x] Task authored with frontmatter `id` / `scope` / `status: in-progress` / `priority` / `depends-on`
- [x] Exact Gate tip frozen to full SHA `b1513073190089bd2dc2473a466373c8a1702f1f`
- [x] Phase A/B state machine + remote drift matrix + push boundary frozen
- [x] Workflow/step evidence schema matches actual `ci.yml` (default non-TUI)
- [x] Explicit: no remote `-Dtui`; no maturity raise; no copied historical run id
- [ ] Independent review PASS on this contract (out of band)
- [ ] Docs lint + score `--check` + `git diff --check` clean on intended range
- [ ] Explicit `git add` of allowed paths only; local docs commit; **no push**
- [ ] Status remains **`in-progress`** (not `done`)

## Phase B — Remote Gate (not started; needs fresh authz)

- [ ] Fresh user authorization recorded
- [ ] Read-only remote drift matrix evaluated; proceed only if clear
- [ ] Exact normal push of **only** `b151307…` (no force; no Phase A docs tip)
- [ ] Actions run with `headSha == b151307…`, correct event/branch, conclusion **success**
- [ ] Ubuntu + macOS jobs success; std + curl steps success; catalog/docs/OpenAPI/build/package/examples observed
- [ ] Real run id/URL + log numbers recorded (no copy of `8a93ec6` / `30273762011` / local TUI counts)
- [ ] Fuses did not substitute for product PASS if they fired
- [ ] Status → `done` only after evidence docs closeout; still no maturity raise

# failure outcomes

| Failure | Required outcome |
|---------|------------------|
| Any matrix job or required step fails on `b151307` | Task **must not** become `done`; **no** docs-greenwash |
| Timeout / cancel / skipped / wrong SHA / old run | **Not PASS** |
| Remote not ff-able without force | **STOP**; rebind/re-review; no force-push |
| Product bug found | Open a **scoped** product/CI-fix task; fix; then **fresh exact-tip** Gate |
| Drift / wrong tip pushed | Do not claim Gate; re-authorize and rebind |

# non-goals

- Feature novelty (theme, RPC, ACP, E2/E3, extension UI, WASM, dashboard).
- Remote `-Dtui=true` or cross-platform TUI maturity Gate.
- New or raised maturity rows (Headless/Process remain L2; Runtime Extensions L0; no TUI row).
- Changing Core thin boundary, CLI/TUI ownership, ask + workspace jail + shell protect, relative paths, Session v1 / Trace v1 / headless-v1.
- Editing `packages/**`, `build.zig*`, `.github/**`, fixtures, schemas.
- Reusing historical run `30273762011` or tip `8a93ec6` numbers as this tip’s evidence.
- Soft success via timeout, cancel, skip, or `continue-on-error`.
- Force push; push of Phase A contract or later evidence commits as the Gate tip.
- Marking this task `done` in Phase A.
- Selecting `theme-001` or any C9 follow-on without a fresh Goal.

# verification commands (Phase A)

From task worktree root:

```bash
python3 scripts/lint_docs.py
python3 scripts/score_docs.py --check
git diff --check
# scope scan (example): ensure no packages/ build.zig .github product edits
git status -sb
git diff --name-only
```

Optional local product smoke is **not** required for Phase A contract freeze
and does **not** substitute for Phase B remote evidence.

# lineage

| Stage | Tip / id | Note |
|-------|----------|------|
| Historical M0 remote dual-backend Gate | tip `8a93ec6` / run `30273762011` | Prior exact tip/run only; **not** this Gate |
| TUI contract PASS | `c7a8f3a` | Docs freeze |
| TUI implementation final | `f8f7f55014a01ce4d6cf3ad7b751c8f6f0aa30b5` | Local macOS Gates; external/other push observed to `origin/main` ≠ remote Gate |
| TUI docs closeout chain | `9d69574` → `8694fbb` → **`b151307`** | Local post-TUI tip = **this Gate target** |
| Phase A contract (this node) | local docs commit after baseline `b151307` | Does **not** rebind remote Gate tip SHA |
| Phase B remote run | *pending authorization* | Must cite real run for `headSha == b151307…` |

# delivery evidence (Phase A)

| Field | Value |
|-------|--------|
| Path | **Docs-only Phase A contract** |
| Status | **`in-progress`** |
| Target remote Gate tip | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Phase B push | **not authorized** by this contract alone |
| Remote run id / URL | **none** (must not invent) |
| Maturity | **unchanged** |
| Remote `-Dtui` | **not claimed** |
| theme / RPC / ACP / E2 / E3 | remain pending/deferred |

# closeout

**Not closed.** Phase A freezes the contract and status truth only. Task stays
**`in-progress`** until Phase B records a real successful Actions run on exact
tip `b151307…` under the schema above.
