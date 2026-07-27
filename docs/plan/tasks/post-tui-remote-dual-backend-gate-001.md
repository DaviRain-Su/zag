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

**TARGET = `b1513073190089bd2dc2473a466373c8a1702f1f`**

This node proves that the **default (non-TUI) CI matrix** still goes green on
that tip after the minimal TUI implementation landed and local docs closeout
followed. It is **post-TUI default-path regression evidence**, not a
cross-platform TUI maturity Gate and **not** a claim that remote CI runs
`-Dtui=true`.

| Phase | What it is | What it is not |
|-------|------------|----------------|
| **A (current)** | Docs contract + cross-links only; status **`in-progress`** | Push; run id; Gate green; product/CI edit |
| **B (not started)** | Only after **fresh one-shot user push authorization** matching §authorization schema | Implied by Phase A review/merge; vague “go ahead”; old session authz |

**This contract document does not authorize Phase B.** No user push
authorization is claimed here. Template commands below are **examples for a
future authorized Phase B agent** and **must not** be executed from Phase A.

Depends on (both **done**):

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [tui-minimal-001](./tui-minimal-001.md) | **done** @ impl `f8f7f55` (contract PASS @ `c7a8f3a`; docs closeout lineage `9d69574` → `8694fbb` → TARGET) | Post-TUI product tip + local evidence; TUI closeout did **not** claim remote Gate |
| [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md) | **done** (docs-only) @ tip `8a93ec6` / run `30273762011` | Prior exact-tip remote Gate **pattern** only — tip/run numbers **not** reusable as this Gate’s PASS |

Does **not** own: product/fixture/build/CI-YAML edits; TUI remote maturity;
theme/RPC/ACP/E2/E3; maturity row raise; any push without valid Phase B authz.

# context

## Why this Gate exists

1. [tui-minimal-001](./tui-minimal-001.md) closed minimal TUI at `f8f7f55` with
   dual final reviews PASS and **local macOS** Gates. Docs closeout tips
   through TARGET stayed **local**.
2. Local remote-tracking reflog once observed an **external/other push** of
   `f8f7f55` to `origin/main`. That is **cache history only** — never a live
   Phase B decision input. **Branch presence ≠ remote Gate.**
3. Historical M0 Gate [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md)
   closed only at tip `8a93ec6` / run `30273762011` — prior tip/run only.
4. Remaining honesty gap: fresh remote default dual-OS dual-backend evidence
   for **exact TARGET** under current workflow (no `-Dtui` step).

## Adjacent work (not this node)

| Node | Relationship |
|------|--------------|
| theme-001 / RPC / ACP / extension UI / WASM | **pending / deferred**; fresh Goal required |
| TUI PTY / remote `-Dtui=true` | **Not claimed** — CI has no TUI step |
| Maturity | **No** new/raised row |
| Product / build / `.github` | **Out of path** forever on this task |

## References

- Prior Gate pattern: [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md)
- TUI: [tui-minimal-001](./tui-minimal-001.md) · [tui-minimal](../../modules/tui-minimal.md)
- CLI: [cli-interaction](../../modules/cli-interaction.md)
- Fuses: [quality/README](../../quality/README.md) · `.github/workflows/ci.yml`
- Plan: [plan/README](../README.md) · [roadmap](../../roadmap.md)

# baseline (worktree truth)

| Field | Value |
|-------|--------|
| TARGET (full) | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| TARGET short | `b151307` (never use short form in push/refspec) |
| Tip message | `docs(tui-minimal-001): record observed remote tip truth` |
| Lineage | impl `f8f7f55` + docs `9d69574` + `8694fbb` + TARGET |
| `f8f7f55` | Ancestor of TARGET (three later **docs-only** commits) |
| Local `origin/main` cache | Historical observation only; **must not** decide Phase B alone |
| Phase A product delta | **none** — TARGET already holds product under test |

**Pattern:** freeze exact target tip first; later (authorized) remote evidence.
Phase A/contract commits may stay local-only. **Remote Gate tip stays TARGET**
and does **not** rebind to this contract commit’s SHA.

# authority / ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| This task (docs only) | TARGET identity; Phase A/B machine; live drift matrix; authz schema; unique push shape; run correlation; command tables; failure isolation | Product/CI edits; inventing run ids; greenwashing; executing push without valid authz |
| `.github/workflows/ci.yml` | Unchanged host rails + default matrix | TUI steps; product hang proof via timeout |
| Packages | Behavior under test | Edits from this node |
| User | **Only** valid Phase B one-shot push authorization (§authorization) | Implied authz via review/merge/“go ahead” |

# exact target identity

| Identity | Binding value |
|----------|----------------|
| **TARGET** | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Destination ref | `refs/heads/main` on remote `origin` |
| Acceptable Actions `headSha` | **Exactly** TARGET |
| Forbidden as PASS | Any other SHA; timeout/cancel/skipped; historical run `30273762011`; local TUI counts as remote proof; re-run attempt ≠ 1 without new contract |

---

# Phase A / Phase B state machine

```text
done deps
  tui-minimal-001 ✅
  linux-dual-backend-gate-001 ✅
        │
        ▼
Phase A (CURRENT) — docs contract only
  ├─ status: in-progress
  ├─ author contract + cross-links + local docs commit
  ├─ independent review of THIS hardened contract still required (not PASS yet)
  ├─ after review PASS: ff-only local merge allowed
  ├─ NO push · NO run id · Gate NOT green
  └─ this task remains docs-only forever

        │  only after FRESH one-shot user push authz (§authorization)
        ▼

Phase B — two mutually exclusive paths (never both)
  ├─ Path OBSERVE (drift class A only): remote already at TARGET
  │    → never re-push
  │    → observation-only if exactly one pre-existing qualifying run
  │    → else STOP / rebind (new Goal)
  │
  └─ Path PUSH (drift class B only): remote ancestor of TARGET, local proves it
       → unique porcelain push of TARGET:refs/heads/main
       → post-push live OID == TARGET
       → exactly one correlating CI run in window
       → record evidence → status done only then

Class C (ahead / diverged / unknown): STOP · rebind · never force
```

| Phase | Allowed | Forbidden |
|-------|---------|-----------|
| **A** | Allowed docs paths; local commit; later local ff-only after review PASS | Any push; run id; Gate green; product/CI edits |
| **B Path OBSERVE** | Live ls-remote; read-only `gh`/API; docs evidence if unique qualifying run already exists | Re-push TARGET; invent run; product/CI fix |
| **B Path PUSH** | Live drift twice; unique authorized push; post-push live check; unique run correlation; evidence docs | Force; other refspecs; retry without new authz; pull/merge/reset/rebase to “fix” remote |

---

# authorization schema (Phase B push) — F1

## Valid authorization (all required)

A Phase B **push** is authorized only by a **new user message** (not an agent
summary, not a Goal preamble) that **explicitly names all** of:

1. Full target SHA: `b1513073190089bd2dc2473a466373c8a1702f1f`
2. Destination: `origin` / `refs/heads/main` (or unambiguous `origin/main` as
   that exact ref)
3. Push class: **normal non-force**
4. Scope: **only** that single refspec (TARGET → `refs/heads/main`)

## Invalid authorization (non-exhaustive; all fail-closed)

| Invalid source | Why |
|----------------|-----|
| Prior conversation / prior push grant | Authz is not transferable across sessions or attempts |
| Phase A author / review / local merge agreement | Review ≠ push |
| Vague “继续 / continue / go ahead / ship it / LGTM” | Does not name TARGET + ref + non-force + single refspec |
| Goal run permission / task selection | Goal may open work; it does not authorize remote mutation |
| Seeing independent review PASS | Review is local contract quality only |
| Agent self-authorization or tool default | Never |

## Evidence fields (record before any push; Path PUSH only)

| Field | Required value |
|-------|----------------|
| `authorized_at` | ISO-8601 timestamp when the user message was received |
| `authorizer` | `user` |
| `verbatim` | Exact user message text (or durable citation of it) |
| `scope` | `only b1513073190089bd2dc2473a466373c8a1702f1f:refs/heads/main` |
| `force` | `false` |
| `attempt` | `one-shot` — **this authorization is exhausted after one push attempt** |

## Exhaustion / re-authorization

- After **one** push command attempt (exit 0 or non-zero), the grant is
  **consumed**.
- New grant required for: any retry, re-run of Actions, rebind of tip, different
  ref/refspec, or Path OBSERVE → later Path PUSH switch.
- Path OBSERVE does **not** consume a push grant (and must not push).

**Current Phase A status:** no authorization exists; do not claim otherwise.

---

# live-only remote drift matrix (Phase B) — F2

## Live OID is the only decision input

| Input | Role |
|-------|------|
| Live `git ls-remote` OID of `refs/heads/main` | **Only** remote tip used for drift class |
| Local `origin/main` / remote-tracking branch | **Cache / history only** — must **not** alone choose Path PUSH/OBSERVE/STOP |
| Local TARGET object | Must exist and verify as the full commit SHA before push |

### Live read (required; read-only)

```text
git ls-remote --exit-code origin refs/heads/main
```

(Or a review-approved equivalent GitHub API that returns the same single OID.)

| ls-remote outcome | Action |
|-------------------|--------|
| Exit 0, **exactly one** line, OID is 40-hex full SHA | Parse `remote_oid`; continue drift class |
| Non-zero exit, empty, multi-line, non-hex, no permission, network error | **STOP** — no push; record failure; no guess |

Record `remote_oid` and `live_read_at` in evidence.

### Local ancestry proof (required for class B)

Before Path PUSH:

1. `git rev-parse --verify 'b1513073190089bd2dc2473a466373c8a1702f1f^{commit}'`
   must print **exactly** `b1513073190089bd2dc2473a466373c8a1702f1f`.
2. Local object DB must contain `remote_oid` **and** prove
   `remote_oid` is an ancestor of TARGET
   (e.g. `git merge-base --is-ancestor <remote_oid> <TARGET>` exit 0).
3. If object missing or ancestry unprovable without guesswork: **STOP / rebind**.
   Do **not** fetch “to make it work” under Phase A. Under Phase B, a
   **read-only** fetch is allowed **only if** the same fresh push authz (or a
   separate explicit user grant for read-only fetch) permits network read; if
   still unknown after allowed read → STOP. **Never force. Never lease-force.**

### Immediate pre-push re-read (TOCTOU)

On Path PUSH, **immediately before** the push command, run live ls-remote again.
If `remote_oid` changed class (no longer B): **STOP** — do not push; grant still
consumed if a push was attempted; if stopped before push, document whether grant
remains (default: **consume only after push attempt** — a pure STOP before push
does **not** consume, but a new live class still requires re-evaluation and may
need new authz if class changed to non-B).

**Binding rule:** if any uncertainty whether push started → treat grant as
consumed; require new authz.

## Mutually exclusive drift classes

Let `TARGET = b1513073190089bd2dc2473a466373c8a1702f1f`.

| Class | Predicate (live `remote_oid` only) | Path |
|-------|-------------------------------------|------|
| **A** | `remote_oid == TARGET` | **OBSERVE only** — **never re-push**. If exactly one pre-existing run already qualifies under §run correlation (without requiring `createdAt >= push_started_at` from a new push — use observation schema below), may record observation-only amendment. Else **STOP / rebind** (new Goal). |
| **B** | `remote_oid != TARGET` **and** local proves `remote_oid` is ancestor of TARGET | **PUSH** path only after valid authz + preflight |
| **C** | TARGET is ancestor of `remote_oid` (remote ahead); **or** histories diverged; **or** `remote_oid`/ancestry unknown; **or** ref missing after live read failure already STOPped | **STOP** — new Goal / rebind tip; **forbid** force, force-with-lease, delete, or any non-ff “repair” |

Classes are exclusive. Do not combine A with push. Do not treat cache
`origin/main` as live `remote_oid`.

### Observation-only schema (class A only)

- **Never push.**
- Search for existing runs with §run correlation filters except
  `createdAt >= push_started_at` (no new push). Instead require a run whose
  `headSha == TARGET`, `event=push`, `headBranch=main`, workflow `CI`,
  `attempt=1`, `conclusion=success`, and is uniquely identifiable as the
  **push of TARGET to main** (not PR, not dispatch).
- Matching run count must be **exactly 1** inside the bounded observation
  query; 0 or >1 → STOP / independent adjudication — do not pick “latest”.
- Still fill full job/step evidence schema.
- Status may move to `done` only after observation evidence docs commit;
  still **no** product/CI edits.

---

# unique push shape (Path PUSH only) — F3

## Sole allowed push command (example; do not run without authz)

```bash
git push --porcelain origin b1513073190089bd2dc2473a466373c8a1702f1f:refs/heads/main
```

### Pre-push (all required)

| Check | Binding |
|-------|---------|
| Authz | Valid, unexhausted one-shot grant (§authorization) |
| Drift | Live class **B** on latest ls-remote |
| Object | `git rev-parse --verify 'b1513073190089bd2dc2473a466373c8a1702f1f^{commit}'` → exact TARGET |
| Ancestry | Local proof remote_oid ancestor of TARGET |
| Record | `push_started_at` (ISO-8601) **before** invoking push |

### Forbidden push forms (any ⇒ protocol violation)

- `git push origin main`
- `git push origin HEAD:main` / `HEAD:refs/heads/main`
- Any **shortened** SHA in refspec
- Multiple refspecs; `--force`, `--force-with-lease`, `--force-if-includes`
- `--all`, `--mirror`, `--tags`, `--follow-tags`
- Pushing any other branch/tag/commit (including Phase A/evidence tips)
- `git pull` / `merge` / `reset` / `rebase` to “fix” remote after mismatch

### Post-push (all required)

| Check | Binding |
|-------|---------|
| Push exit | **Must be 0** |
| Porcelain stdout | Record full stdout/stderr |
| `push_completed_at` | ISO-8601 |
| Immediate live ls-remote | `remote_oid` **exactly** TARGET; else **STOP** — do not claim Gate; do not force-repair |
| Grant | Consumed |

---

# unique bounded run correlation — F4

## Default accepted run (Path PUSH)

All must hold:

| Field | Required |
|-------|----------|
| Workflow **name** | `CI` |
| Workflow **path** | `.github/workflows/ci.yml` |
| `event` | `push` |
| `headBranch` | `main` |
| `headSha` | TARGET (`b1513073190089bd2dc2473a466373c8a1702f1f`) |
| `attempt` | `1` |
| `createdAt` | `>= push_started_at` |
| `conclusion` | `success` |

Different event / attempt / workflow requires a **new contract + new authz**.

## Read-only discovery templates (examples; fail → STOP)

Repo assumed `DaviRain-Su/zag` (adjust only if remote URL evidence says otherwise;
do not guess).

```bash
# list candidates after push (read-only)
gh run list --repo DaviRain-Su/zag --branch main --event push \
  --workflow CI --limit 20 \
  --json databaseId,url,event,headBranch,headSha,status,conclusion,createdAt,updatedAt,attempt,workflowName

# view one candidate
gh run view <id> --repo DaviRain-Su/zag \
  --json databaseId,url,event,headBranch,headSha,status,conclusion,createdAt,updatedAt,attempt,workflowName,jobs

# job/step logs (required for summaries)
gh run view <id> --repo DaviRain-Su/zag --log
```

Equivalent official GitHub REST/GraphQL API is acceptable if it returns the same
fields. **If `gh`/API fails or logs are unavailable → STOP; do not invent.**

## Cardinality in bounded window

| Window | Rule |
|--------|------|
| Default observation window | From `push_started_at` through a single bounded wait (e.g. poll until both matrix jobs complete or wall clock exceeds job timeout class × 2, max ~70 minutes wall) — document the bound used |
| Matching runs in window | Must be **exactly 1** |
| 0 matches after window | **STOP** — not PASS |
| >1 matches | **STOP** — independent adjudication; do not pick “newest” |

**Rejected:** `pull_request`, `workflow_dispatch`, `schedule`, historical runs,
re-runs (`attempt != 1`), wrong `headSha`, cancelled/timeout conclusions.

## Job / step evidence (both matrix jobs)

Job names (from workflow): `Zig ubuntu-latest`, `Zig macos-latest`.

For **each** job record: name, OS, conclusion (**must** be `success`).

For **each** of the 13 workflow steps (actual `.github/workflows/ci.yml` order),
record step conclusion and real log summary where applicable:

| # | Step | Notes |
|---|------|--------|
| 1 | Checkout | must success |
| 2 | Install Zig 0.16.0 | must success |
| 3 | Python (path coverage script) | must success |
| 4 | Catalog sources in sync | record check result |
| 5 | Docs score (readability + security) | record scores if printed |
| 6 | Docs lint (XPlan layout) | must success |
| 7 | OpenAPI path coverage (openai-zig) | record e.g. **287/287** if logged |
| 8 | `zig build test --summary all` | record Build Summary steps/tests |
| 9 | Install libcurl headers (Linux, curl backend) | **Ubuntu:** success required. **macOS:** conditional `if: runner.os == 'Linux'` → **skipped is the only allowed non-success** for this step |
| 10 | `zig build test -Dhttp_backend=curl --summary all` | record summary |
| 11 | `zig build` (install zag) | must success |
| 12 | openai-zig package tests | must success |
| 13 | openai-zig examples (compile) | must success |

| Event | PASS? |
|-------|-------|
| Job timeout / cancel / fuse fire | **No** |
| Core step **skipped** (except macOS step 9 as above) | **No** |
| Job success but required summary logs missing | **No** |
| `continue-on-error` soft green | **Forbidden / No** |

---

# Phase B command / decision cookbook — F5

Templates only. **Do not execute push without valid authz.** No force/retry
recipes exist.

| # | Stage | Command / action | Side effect | Authz | On fail |
|---|-------|------------------|-------------|-------|---------|
| B0 | Preflight authz | Parse user message against §authorization; fill evidence fields | none | must already have valid grant for Path PUSH | STOP Path PUSH |
| B1 | Live tip | `git ls-remote --exit-code origin refs/heads/main` | network read | none (read-only) | STOP |
| B2 | Classify | Apply drift class A/B/C on live OID only | none | — | Class C → STOP/rebind |
| B3 | Local TARGET | `git rev-parse --verify 'b1513073190089bd2dc2473a466373c8a1702f1f^{commit}'` | none | — | STOP |
| B4 | Ancestry (B only) | `git merge-base --is-ancestor <remote_oid> b1513073190089bd2dc2473a466373c8a1702f1f` | none | — | STOP/rebind |
| B5 | TOCTOU re-read | repeat B1; re-classify | network read | — | if not B → STOP (no push) |
| B6 | Record clock | set `push_started_at` | none | Path PUSH only | — |
| B7 | **Unique push** | `git push --porcelain origin b1513073190089bd2dc2473a466373c8a1702f1f:refs/heads/main` | **mutates remote main** | **valid one-shot grant** | record; grant consumed; STOP; no force repair |
| B8 | Post live tip | B1 again; require OID == TARGET | network read | — | STOP no claim |
| B9 | Run list | `gh run list …` per §run correlation | network read | gh auth available | STOP |
| B10 | Run filter | exactly one match | none | — | 0 or >1 → STOP |
| B11 | Run view/log | `gh run view` + `--log` | network read | — | STOP if missing |
| B12 | Evidence docs | fill schema; status `done` only if all PASS | local docs commit | docs only | stay `in-progress` |

| Missing capability | Action |
|--------------------|--------|
| No live network / ls-remote | STOP |
| No `gh`/API access for runs | STOP (cannot claim) |
| No valid push authz | Do not enter B7 |

**No force commands. No retry commands.** Retry = new user authz + new attempt
number in evidence (still `attempt=1` on Actions unless new contract allows
otherwise — default still requires Actions `attempt=1` for a new push).

---

# failure isolation — F6

| Situation | Required outcome |
|-----------|------------------|
| CI red on TARGET | Task **stays `in-progress`**; **no** docs-greenwash; **no** product/CI edit on this task or tip |
| Run correlation not unique / missing | STOP; not PASS |
| Live tip drift / wrong post-push OID | STOP; not PASS; no force |
| Product or CI bug | **Fresh Goal** → new scoped fix task → new exact tip → **new** Gate contract/run |
| This task path | **Forever docs-only** under allowed paths |

Do **not** “fix green” by editing `packages/**`, `build.zig*`, or
`.github/**` inside this Gate node.

---

# workflow bar summary (default non-TUI)

Authoritative file (read-only): `.github/workflows/ci.yml`.

| Host rail | Value |
|-----------|-------|
| `concurrency.group` | `${{ github.workflow }}-${{ github.ref }}` |
| `cancel-in-progress` | `true` |
| `timeout-minutes` | `30` per matrix job |
| `fail-fast` | `false` |
| Matrix | `ubuntu-latest`, `macos-latest` |
| `continue-on-error` | absent/false |

Fuse fire ≠ product PASS. **No** remote `-Dtui`. **No** maturity raise.

## Phase A evidence (no run id)

| Field | Value |
|-------|--------|
| Status | **`in-progress`** |
| TARGET | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Phase B authz | **none claimed** |
| Run id / URL | **none** |
| Gate green | **No** |

---

# path

## Allowed (this node)

| Path | Role |
|------|------|
| `docs/plan/tasks/post-tui-remote-dual-backend-gate-001.md` | this task |
| `docs/plan/README.md` | Active DAG + index |
| `docs/roadmap.md` | status truth |
| `docs/modules/cli-interaction.md` | cross-link |
| `docs/modules/tui-minimal.md` | cross-link |
| `docs/modules/README.md` | index |
| `docs/plan/tasks/tui-minimal-001.md` | cross-link only |
| `docs/quality/README.md` | fuses adjacency |
| `docs/maturity.md` | non-raise only |
| `docs/INDEX.md` | index |
| generated quality reports | only if body/score material; restore if timestamp-only |

## Forbidden

- `packages/**` · `build.zig*` · `src/**` · fixtures · schemas · `.github/**`
- Product/CI/build edits; force push; fabricated run ids
- Executing Phase B push from Phase A

# acceptance / checklists

## Phase A — Docs contract (current)

- [x] Task authored; frontmatter `status: in-progress`; depends-on both done preds
- [x] TARGET frozen full SHA `b1513073190089bd2dc2473a466373c8a1702f1f`
- [x] Phase A/B machine + live drift A/B/C + authz schema + unique push + run correlation + command table
- [x] Explicit: no remote `-Dtui`; no maturity raise; no copied historical run as PASS
- [x] Local docs commits for contract authoring (incl. harden follow-up); **no push**
- [x] Docs lint + score check + `git diff --check` + scope (on each contract commit)
- [ ] **Independent review PASS** on this hardened contract (out of band) — **not yet**
- [ ] Status remains **`in-progress`** until Phase B evidence; Gate **not** green

## Phase B — not started

- [ ] Valid one-shot user push authz recorded **or** class A observation path chosen
- [ ] Live ls-remote OID recorded; class A or B only
- [ ] Path PUSH: unique porcelain push; exit 0; post live OID == TARGET
- [ ] Exactly one correlating `CI` push run; attempt 1; headSha TARGET; success
- [ ] Both jobs + step evidence (macOS libcurl skip exception only for step 9)
- [ ] Real run id/URL + log numbers (no `30273762011` / local TUI copy)
- [ ] Status → `done` only after evidence docs; still no maturity raise

# failure outcomes

| Failure | Outcome |
|---------|---------|
| Job/step fail / timeout / cancel / skip (non-excepted) | not PASS; stay `in-progress` |
| Class C or unknown live tip | STOP; rebind via new Goal; no force |
| Product/CI defect | new fix task + new tip + new Gate — not this node |
| Authz missing/invalid/exhausted | no push |
| >1 or 0 matching runs | STOP |

# non-goals

- Feature novelty; remote `-Dtui`; maturity raise
- Editing packages/build/CI; force push; soft green
- Reusing `8a93ec6` / `30273762011` as this tip’s PASS
- Marking `done` in Phase A; selecting theme/RPC/ACP without fresh Goal
- Claiming current user has authorized Phase B

# verification commands (Phase A)

```bash
python3 scripts/lint_docs.py
python3 scripts/score_docs.py --check
git diff --check
git status -sb
git diff --name-only
```

# lineage

| Stage | Tip / id | Note |
|-------|----------|------|
| Historical M0 Gate | `8a93ec6` / run `30273762011` | prior only |
| TUI contract PASS | `c7a8f3a` | docs freeze |
| TUI impl final | `f8f7f55` | local macOS; cache push ≠ Gate |
| Docs closeout → TARGET | `9d69574` → `8694fbb` → **TARGET** | Gate tip |
| Phase A contract | local docs after TARGET | does not rebind TARGET |
| Phase A harden | this follow-up | closes adversarial F1–F8 protocol gaps |
| Phase B run | *pending valid authz* | real run only |

# delivery evidence (Phase A)

| Field | Value |
|-------|--------|
| Path | Docs-only Phase A (+ harden) |
| Status | **`in-progress`** |
| TARGET | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Phase B authz | **not present / not claimed** |
| Run id | **none** |
| Maturity | unchanged |
| Remote `-Dtui` | not claimed |

# closeout

**Not closed.** Hardened Phase A freezes executable Phase B protocol only.
Task stays **`in-progress`** until Path OBSERVE or Path PUSH records valid
evidence under this document. Independent review of the hardened contract is
still required before treating protocol freeze as review-PASS.
