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
| **A (current)** | Docs contract + cross-links; status **`in-progress`**; **contract freeze PASS** @ `69c1ec3` (see below) | Push; run id; Gate green; product/CI edit; Phase B grant |
| **B (not started)** | Live remote/Actions evidence only after a **fresh user Phase B grant** of type `observation_grant` **or** `push_grant` (§authorization) | Implied by Phase A review/merge/PASS; vague “go ahead”; Goal run alone; old session authz |

### Phase A contract freeze PASS (review of prior tip only)

Hardened contract tip
**`69c1ec39528c819ed045cf4d0de1d1c3fb6bedaa`** received **two independent final
re-reviews** (facts/CI path + safety/ops path) with **PASS, zero blockers**.

| Claimed | Not claimed |
|---------|-------------|
| Phase A **contract text** at tip `69c1ec3` is review-PASS | Any `observation_grant` / `push_grant` |
| Local docs protocol freeze may proceed to coordinator ff-only when scheduled | Gate green; remote run id; TARGET rebind |
| This **PASS-record** commit only **records** that prior-tip review | That **this** PASS-record tip itself was re-reviewed |

**This contract document does not authorize Phase B.** No user
`observation_grant` or `push_grant` is claimed here. Template commands below
are **examples for a future authorized Phase B agent** and **must not** be
executed from Phase A.

Depends on (both **done**):

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [tui-minimal-001](./tui-minimal-001.md) | **done** @ impl `f8f7f55` (contract PASS @ `c7a8f3a`; docs closeout lineage `9d69574` → `8694fbb` → TARGET) | Post-TUI product tip + local evidence; TUI closeout did **not** claim remote Gate |
| [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md) | **done** (docs-only) @ tip `8a93ec6` / run `30273762011` | Prior exact-tip remote Gate **pattern** only — tip/run numbers **not** reusable as this Gate’s PASS |

Does **not** own: product/fixture/build/CI-YAML edits; TUI remote maturity;
theme/RPC/ACP/E2/E3; maturity row raise; any remote mutation without valid
`push_grant`; any Phase B live reads/closeout without a valid Phase B grant.

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
| This task (docs only) | TARGET identity; Phase A/B machine; live drift matrix; dual grant schema; unique push shape; run correlation; command tables; failure isolation | Product/CI edits; inventing run ids; greenwashing; Phase B without valid grant; push without `push_grant` |
| `.github/workflows/ci.yml` | Unchanged host rails + default matrix | TUI steps; product hang proof via timeout |
| Packages | Behavior under test | Edits from this node |
| User | Fresh Phase B `observation_grant` **or** `push_grant` (§authorization) | Implied authz via review/merge/“go ahead”/Goal alone |

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
done deps (both point into this task)
  tui-minimal-001 ✅ ──────────────────┐
  linux-dual-backend-gate-001 ✅ ──────┤
                                       ▼
Phase A (CURRENT) — docs contract only
  ├─ status: in-progress (task not done)
  ├─ author contract + cross-links + local docs commits
  ├─ independent dual final re-review PASS @ 69c1ec3 (zero blockers)
  ├─ this tip: PASS-record docs only (not itself claimed re-reviewed)
  ├─ after contract PASS: ff-only local merge allowed when scheduled
  ├─ NO push · NO run id · Gate NOT green · NO Phase B grant
  └─ this task remains docs-only forever

        │  fresh user Phase B grant:
        │    observation_grant  OR  push_grant
        │  (§authorization — not “push-only”)
        ▼

Phase B entry (shared preflight under either grant)
  ├─ live ls-remote only (cache origin/main never decides)
  ├─ classify A / B / C
  │
  ├─ Class A (remote_oid == TARGET)
  │    → Path OBSERVE only; never push
  │    → allowed under observation_grant OR push_grant
  │      (if push_grant: mutation not used; push grant not consumed as push)
  │    → exactly one pre-existing qualifying run → docs closeout
  │    → else STOP / rebind (new Goal)
  │
  ├─ Class B (remote ancestor of TARGET; local proves)
  │    → Path PUSH only if valid unexhausted push_grant
  │    → if only observation_grant → STOP; request fresh push_grant
  │    → unique porcelain push → post live OID == TARGET
  │    → exactly one correlating CI run → evidence → done
  │
  └─ Class C (ahead / diverged / unknown)
       → STOP · rebind · never force
```

| Phase / path | Allowed | Forbidden |
|--------------|---------|-----------|
| **A** | Allowed docs; local commit; later local ff-only after review PASS | Any push; run id; Gate green; product/CI edits; Phase B live reads without grant |
| **B Path OBSERVE** (class A) | Live ls-remote; read-only `gh`/API; docs evidence if unique qualifying run | Re-push TARGET; invent run; product/CI fix |
| **B Path PUSH** (class B + `push_grant`) | Live drift twice; unique authorized push; post-push live check; unique run correlation; evidence docs | Force; other refspecs; push under observation_grant; retry without new `push_grant` |

---

# authorization schema (Phase B) — dual grants

Phase B **prereq live reads**, path selection, and **docs closeout** require a
**new user message** choosing **exactly one** grant type below. Goal selection,
Phase A review PASS, local merge, or vague “继续/go ahead” **never** substitute.

Both grant types may authorize **live preflight read** (`ls-remote`, optional
read-only fetch for ancestry under Phase B, and Actions read for the allowed
path). Only `push_grant` may authorize remote mutation.

## Grant type A — `observation_grant`

### Valid (all required)

A **new user message** that includes an **illocutionary authorize verb**, e.g.:

- Chinese: **「我授权」** observation-only Phase B …
- English: **「I authorize」** observation-only Phase B …

and explicitly names:

1. Full TARGET: `b1513073190089bd2dc2473a466373c8a1702f1f`
2. Mode: **observation-only** / **no push**
3. Scope: live remote tip + Actions read + docs closeout for that TARGET only

Example shape (not executed; not claimed as granted):

> I authorize observation-only Phase B for
> `b1513073190089bd2dc2473a466373c8a1702f1f` on `origin` `refs/heads/main`:
> live read and Actions evidence only; **no push**.

### Allows / forbids

| Allows | Forbids |
|--------|---------|
| Live `ls-remote`; class A Path OBSERVE; Actions read; docs closeout if evidence PASS | Any `git push`; class B Path PUSH (must STOP and request `push_grant`); force |

### Evidence fields (`observation_grant`)

| Field | Required |
|-------|----------|
| `grant_type` | `observation_grant` |
| `authorized_at` | ISO-8601 of user message |
| `authorizer` | `user` |
| `verbatim` | Exact user message (or durable citation) |
| `scope` | `observe-only TARGET b1513073190089bd2dc2473a466373c8a1702f1f; no push` |
| `force` | `false` |
| `mutation` | `none` |

## Grant type B — `push_grant`

### Valid (all required)

A **new user message** that includes an **illocutionary authorize verb**, e.g.:

- Chinese: **「我授权 Path PUSH」** / **「我授权推送」**
- English: **「I authorize Path PUSH」**

and explicitly names **all** of:

1. Full TARGET SHA: `b1513073190089bd2dc2473a466373c8a1702f1f`
2. Destination: `origin` / `refs/heads/main`
3. Push class: **normal non-force**
4. Scope: **only** single refspec `TARGET:refs/heads/main`

Example shape (not executed; not claimed as granted):

> I authorize Path PUSH of
> `b1513073190089bd2dc2473a466373c8a1702f1f` to `origin` `refs/heads/main`
> as a normal non-force single refspec only.

### Allows / forbids

| Allows | Forbids |
|--------|---------|
| Live preflight; class A → Path OBSERVE (**mutation not used**; do **not** treat as push consumption); class B → unique Path PUSH | Class B without this grant; force; multi-refspec; short SHA; `HEAD:main` |

### Evidence fields (`push_grant`)

| Field | Required |
|-------|----------|
| `grant_type` | `push_grant` |
| `authorized_at` | ISO-8601 of user message |
| `authorizer` | `user` |
| `verbatim` | Exact user message (or durable citation) |
| `scope` | `only b1513073190089bd2dc2473a466373c8a1702f1f:refs/heads/main` |
| `force` | `false` |
| `attempt` | `one-shot` — **exhausted after one push command attempt** |
| `mutation_used` | `true` if B7 ran; `false` if class A OBSERVE under this grant |

## Invalid authorization (both types; fail-closed)

| Invalid source | Why |
|----------------|-----|
| Prior conversation / prior grant | Not transferable across sessions or attempts |
| Phase A author / review / local merge | Review ≠ Phase B grant |
| Vague “继续 / continue / go ahead / ship it / LGTM” | No authorize verb + no full grant body |
| Only pasting TARGET/refspec without “I authorize…” | No illocutionary force |
| Goal run permission / task selection alone | Opens work; does not grant Phase B |
| Technical review body / checklist text | Not a user authorize act |
| Agent self-authorization | Never |

## Exhaustion / re-authorization

| Grant | Exhaustion |
|-------|------------|
| `push_grant` | Consumed after **one** push command attempt (exit 0 or non-zero). Pure STOP **before** push does **not** consume. Uncertainty whether push started → treat consumed. |
| `observation_grant` | One-shot for a single OBSERVE closeout attempt chain; new grant if rebind, new tip, or later need for push |
| Class A under `push_grant` | **Mutation not used** — do not count as push consumption; record `mutation_used=false`. A later Path PUSH still needs an **unexhausted** `push_grant` (same message only if no push attempt yet; otherwise new message) |
| Class B under `observation_grant` only | **STOP** — request a **new** `push_grant`; do not push |
| Retry / re-run Actions / rebind / different ref | New grant of the appropriate type |

**Current Phase A status:** neither grant exists; do not claim otherwise.

### Class × grant predicate (single binding table)

| Live class | `observation_grant` | `push_grant` |
|------------|---------------------|--------------|
| **A** (`remote_oid == TARGET`) | Path OBSERVE | Path OBSERVE (`mutation_used=false`; never push) |
| **B** (remote ancestor of TARGET) | **STOP** — request `push_grant` | Path PUSH if unexhausted |
| **C** (ahead / diverged / unknown) | **STOP** | **STOP** |

---

# live-only remote drift matrix (Phase B)

## Live OID is the only decision input

| Input | Role |
|-------|------|
| Live `git ls-remote` OID of `refs/heads/main` | **Only** remote tip used for drift class |
| Local `origin/main` / remote-tracking branch | **Cache / history only** — must **not** alone choose path |
| Local TARGET object | Must verify as full commit SHA before push |

### Live read (required; read-only)

Requires a valid Phase B grant (`observation_grant` or `push_grant`).

```text
git ls-remote --exit-code origin refs/heads/main
```

| ls-remote outcome | Action |
|-------------------|--------|
| Exit 0, **exactly one** line, OID is 40-hex full SHA | Parse `remote_oid`; classify |
| Non-zero, empty, multi-line, non-hex, no permission, network error | **STOP** — no push; no guess |

Record `remote_oid` and `live_read_at`.

### Local ancestry proof (class B / Path PUSH)

1. `git rev-parse --verify 'b1513073190089bd2dc2473a466373c8a1702f1f^{commit}'`
   → exact TARGET.
2. Local DB contains `remote_oid` and
   `git merge-base --is-ancestor <remote_oid> <TARGET>` exits 0.
3. If missing/unprovable: **STOP / rebind**. Phase A must not fetch to invent
   proof. Phase B may use **read-only** fetch only under the active Phase B
   grant; still unknown → STOP. **Never force / force-with-lease.**

### Immediate pre-push re-read (TOCTOU; Path PUSH only)

Immediately before push, re-run live ls-remote. If class ≠ B: **STOP** (no
push). Push attempt → `push_grant` consumed per §authorization.

## Mutually exclusive drift classes

| Class | Predicate | Path |
|-------|-----------|------|
| **A** | `remote_oid == TARGET` | **OBSERVE only** — never re-push; grant table above |
| **B** | `remote_oid != TARGET` and local proves ancestor | **PUSH** only with valid `push_grant` |
| **C** | TARGET ancestor of remote; diverged; unknown; live read failed | **STOP** — rebind; no force |

### Observation-only schema (class A only)

- **Never push.**
- Filters: `headSha == TARGET`, `event=push`, `headBranch=main`,
  workflow **name** `CI`, workflow **path** `.github/workflows/ci.yml`
  (from Actions run API — see §run correlation), `run_attempt == 1`,
  `conclusion=success`; uniquely the push of TARGET to main (not PR/dispatch).
- No `createdAt >= push_started_at` (no new push).
- Matching count **exactly 1**; 0 or >1 → STOP.
- Full job/step evidence; status `done` only after evidence docs.

---

# unique push shape (Path PUSH only)

## Sole allowed push command (example; do not run without `push_grant`)

```bash
git push --porcelain origin b1513073190089bd2dc2473a466373c8a1702f1f:refs/heads/main
```

### Pre-push (all required)

| Check | Binding |
|-------|---------|
| Authz | Valid unexhausted **`push_grant`** |
| Drift | Live class **B** |
| Object | `rev-parse` → exact TARGET |
| Ancestry | Local proof |
| Record | `push_started_at` before push |

### Forbidden

`git push origin main`; `HEAD:main`; short SHA; multi-refspec; any `--force*`;
`--all` / `--mirror` / `--tags` / `--follow-tags`; other commits; pull/merge/
reset/rebase to “fix” remote.

### Post-push

Exit **0**; record porcelain stdout/stderr + `push_completed_at`; live
`remote_oid == TARGET` or STOP (no claim, no force); `push_grant` consumed;
`mutation_used=true`.

---

# unique bounded run correlation

## Required run fields

| Field | Required | Source |
|-------|----------|--------|
| Workflow **name** | `CI` | `gh run list/view` `workflowName` / API |
| Workflow **path** | **exactly** `.github/workflows/ci.yml` | Actions Runs API field `path` (see template) |
| `event` | `push` | API / list |
| `head_branch` / `headBranch` | `main` | API / list |
| `head_sha` / `headSha` | TARGET | API / list |
| `run_attempt` / `attempt` | `1` | API / list |
| `created_at` (Path PUSH) | `>= push_started_at` | API |
| `conclusion` | `success` | API / list |

**If workflow `path` cannot be retrieved → STOP** (cannot claim). Do **not**
invent `path` from `gh run view --json` unless that field is actually present;
prefer the REST run object.

Different event / attempt / workflow / path requires **new contract + new grant**.

## Read-only discovery templates (fail → STOP)

Repo assumed `DaviRain-Su/zag` only if remote URL evidence agrees; do not guess.

```bash
# list candidates (name/event/branch filters; path verified per-id below)
gh run list --repo DaviRain-Su/zag --branch main --event push \
  --workflow CI --limit 20 \
  --json databaseId,url,event,headBranch,headSha,status,conclusion,createdAt,updatedAt,attempt,workflowName

# REQUIRED path + authoritative run fields (do not guess missing JSON keys)
gh api repos/DaviRain-Su/zag/actions/runs/<id> \
  --jq '{id,html_url,name,path,event,head_branch,head_sha,run_attempt,status,conclusion,created_at,updated_at}'

# jobs (when available)
gh run view <id> --repo DaviRain-Su/zag \
  --json databaseId,url,event,headBranch,headSha,status,conclusion,createdAt,updatedAt,attempt,workflowName,jobs

# logs for step summaries
gh run view <id> --repo DaviRain-Su/zag --log
```

After list, **each** candidate must pass `gh api …/actions/runs/<id>` with
`path == ".github/workflows/ci.yml"` and other required fields. Candidates that
fail path check are non-matches.

**If `gh`/API fails or logs unavailable → STOP; do not invent.**

## Cardinality

| Rule | Binding |
|------|---------|
| Path PUSH window | From `push_started_at` until both jobs complete or documented wall bound (~70m max) |
| Path OBSERVE window | Documented bounded query; no invent |
| Matching count | **Exactly 1** |
| 0 or >1 | **STOP** — no “pick latest” |

**Rejected:** `pull_request`, `workflow_dispatch`, `schedule`, historical wrong
SHA, `run_attempt != 1`, cancelled/timeout, wrong `path`.

## Job / step evidence

Jobs: `Zig ubuntu-latest`, `Zig macos-latest` — both conclusion `success`.

| # | Step | Notes |
|---|------|--------|
| 1–8 | Checkout … std `zig build test --summary all` | must success; record summaries |
| 9 | Install libcurl headers | **Ubuntu** success; **macOS** conditional skip **only** allowed non-success |
| 10–13 | curl tests; install; openai-zig tests; examples | must success |

Timeout / cancel / fuse fire / non-excepted skip / missing required logs → **not PASS**.

---

# Phase B command / decision cookbook

Templates only. **Do not execute without the matching grant.** No force/retry
recipes.

| # | Stage | Command / action | Side effect | Grant required | On fail |
|---|-------|------------------|-------------|---------------|---------|
| B0 | Parse grant | Classify message as `observation_grant` or `push_grant`; fill evidence | none | valid one of two | STOP Phase B |
| B1 | Live tip | `git ls-remote --exit-code origin refs/heads/main` | network read | either grant | STOP |
| B2 | Classify | A / B / C on live OID only | none | either | C → STOP/rebind |
| B2a | Class A | Enter Path OBSERVE; never push; if `push_grant`, set `mutation_used=false` | none | either | — |
| B2b | Class B + observation only | **STOP**; request fresh `push_grant` | none | observation only | do not push |
| B2c | Class B + push_grant | continue Path PUSH | none | `push_grant` unexhausted | — |
| B3 | Local TARGET | `git rev-parse --verify 'b151307…^{commit}'` | none | Path PUSH | STOP |
| B4 | Ancestry | `git merge-base --is-ancestor <remote_oid> TARGET` | none | Path PUSH | STOP/rebind |
| B5 | TOCTOU | repeat B1; require class B | network read | Path PUSH | STOP no push |
| B6 | Clock | `push_started_at` | none | Path PUSH | — |
| B7 | **Unique push** | `git push --porcelain origin b151307…:refs/heads/main` | **mutates main** | **`push_grant` only** | record; grant consumed; STOP |
| B8 | Post live | B1; OID == TARGET | network read | after push | STOP no claim |
| B9 | Run list | `gh run list …` | network read | either path | STOP |
| B9a | Run path | `gh api repos/…/actions/runs/<id>` require `path` | network read | either path | STOP if no path |
| B10 | Filter | exactly one full match | none | — | 0/>1 STOP |
| B11 | Logs | `gh run view … --log` | network read | — | STOP if missing |
| B12 | Evidence docs | fill schema; `done` only if PASS | local docs | docs only | stay `in-progress` |

| Missing | Action |
|---------|--------|
| No Phase B grant | Do not start B1+ |
| No live network | STOP |
| No gh/API | STOP (cannot claim) |
| Class B without `push_grant` | STOP; request `push_grant` |
| No unexhausted `push_grant` at B7 | Do not push |

**No force. No retry commands.** New attempt → new grant.

---

# failure isolation

| Situation | Required outcome |
|-----------|------------------|
| CI red on TARGET | Stay `in-progress`; no greenwash; no product/CI edit on this task/tip |
| Run correlation not unique / missing / no path | STOP; not PASS |
| Live tip drift / wrong post-push OID | STOP; no force |
| Product or CI bug | **Fresh Goal** → scoped fix task → new exact tip → **new** Gate |
| This task | **Forever docs-only** |

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
| Status | **`in-progress`** (task not done; Gate not green) |
| TARGET | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Contract freeze tip (reviewed) | `69c1ec39528c819ed045cf4d0de1d1c3fb6bedaa` |
| Dual final re-review | **PASS**, zero blockers (facts/CI + safety/ops) on that tip |
| This PASS-record tip | records prior-tip PASS only; **not** claimed re-reviewed |
| Phase B grants | **none claimed** (`observation_grant` / `push_grant` absent) |
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
- Phase B execution from Phase A

# acceptance / checklists

## Phase A — Docs contract (current)

- [x] Task authored; `status: in-progress`; depends-on both done preds
- [x] TARGET frozen full SHA `b1513073190089bd2dc2473a466373c8a1702f1f`
- [x] Dual grant schema (`observation_grant` / `push_grant`) + class×grant table
- [x] Live drift A/B/C; unique push; run correlation with API `path`; command table
- [x] Explicit: no remote `-Dtui`; no maturity raise; no historical run as PASS
- [x] Local docs commits for contract (incl. harden + auth-path clarify); **no push**
- [x] Docs lint + score check + `git diff --check` + scope on contract commits
- [x] **Independent dual final re-review PASS** on contract tip `69c1ec3` (facts/CI + safety/ops; zero blockers) — **not** a Phase B grant; **not** Gate green
- [x] Status remains **`in-progress`** until Phase B evidence; Gate **not** green; grants **none**

## Phase B — not started

- [ ] Fresh user `observation_grant` **or** `push_grant` recorded (authorize verb + body)
- [ ] Live ls-remote OID; class A or B (C → STOP)
- [ ] Class A: OBSERVE only; never push; unique qualifying run + `path`
- [ ] Class B: only with `push_grant`; unique porcelain push; post OID == TARGET
- [ ] Exactly one correlating run; name `CI`; **path** `.github/workflows/ci.yml`; attempt 1; success
- [ ] Both jobs + step evidence (macOS step 9 skip exception only)
- [ ] Real run id/URL + log numbers (no `30273762011` / local TUI copy)
- [ ] Status → `done` only after evidence docs; still no maturity raise

# failure outcomes

| Failure | Outcome |
|---------|---------|
| Job/step fail / timeout / cancel / skip (non-excepted) | not PASS; stay `in-progress` |
| Class C or unknown live tip | STOP; rebind; no force |
| Class B with only `observation_grant` | STOP; request `push_grant` |
| Product/CI defect | new fix task + new tip + new Gate |
| Grant missing/invalid/exhausted | no push; no false OBSERVE claim |
| >1 or 0 matching runs / no path | STOP |

# non-goals

- Feature novelty; remote `-Dtui`; maturity raise
- Editing packages/build/CI; force push; soft green
- Reusing `8a93ec6` / `30273762011` as this tip’s PASS
- Marking `done` in Phase A; selecting theme/RPC/ACP without fresh Goal
- Claiming current user has granted Phase B (`observation_grant` or `push_grant`)

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
| Docs closeout → TARGET | `9d69574` → `8694fbb` → **TARGET** | Gate tip (remote Gate headSha) |
| Phase A initial contract | `2c9babcb789f767c15ca17fbe49ce3a793cdc477` | define Gate; does not rebind TARGET |
| Phase A safety harden | `81b93554942e55d1bae975a8b7b3ba2318c068fe` | original review F1–F8 covered by hardened sections |
| Phase A auth clarify / **contract review PASS** | `69c1ec39528c819ed045cf4d0de1d1c3fb6bedaa` | dual grants; dual final re-review PASS, zero blockers |
| Phase A PASS-record (this tip) | local docs after `69c1ec3` | records prior-tip PASS only; **this tip not claimed re-reviewed** |
| Phase B run | *pending valid Phase B grant* | real run only; not started |

# delivery evidence (Phase A)

| Field | Value |
|-------|--------|
| Path | Docs-only Phase A (contract + harden + auth clarify + PASS-record) |
| Status | **`in-progress`** |
| TARGET | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Contract PASS tip | `69c1ec39528c819ed045cf4d0de1d1c3fb6bedaa` |
| Dual re-review | **PASS**, zero blockers (facts/CI + safety/ops) on `69c1ec3` |
| Phase B grants | **not present / not claimed** |
| Run id | **none** |
| Maturity | unchanged |
| Remote `-Dtui` | not claimed |
| Gate green | **No** |

# closeout

**Phase A contract freeze is review-PASS** at tip `69c1ec3` (dual final
re-reviews, zero blockers). Task remains **`in-progress`** until Path OBSERVE
or Path PUSH records valid remote evidence under a fresh user grant. This
PASS-record commit does **not** authorize Phase B, invent a run id, or mark
the Gate green. Templates remain non-executable without a fresh grant.
