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
post-TUI product+closeout+Phase A protocol tip:

**TARGET = `f352b60d08e81c19d70ba46198fb06b71ddc85a1`** (unique **active** freeze)

**OLD_TARGET (historical / abandoned) = `b1513073190089bd2dc2473a466373c8a1702f1f`**

This node proves that the **default (non-TUI) CI matrix** still goes green on
**exact TARGET** after the minimal TUI implementation landed, local docs
closeout followed, Phase A protocol docs landed, and a non-product `.gitignore`
update closed the tip. It is **post-TUI default-path regression evidence**, not
a cross-platform TUI maturity Gate and **not** a claim that remote CI runs
`-Dtui=true`.

| Phase | What it is | What it is not |
|-------|------------|----------------|
| **A (current)** | Docs contract + Class C TARGET rebind + cross-links; status **`in-progress`**; rebind candidate **awaiting fresh dual review** | Push; run id; Gate green; product/CI edit; Phase B grant; transfer of OLD_TARGET grant/review as rebind PASS |
| **B (not started)** | Live remote/Actions evidence only after a **fresh user Phase B grant** of type `observation_grant` **or** `push_grant` (§authorization) naming **TARGET** | Implied by Phase A review/merge/PASS; vague “go ahead”; Goal run alone; old session / OLD_TARGET authz |

### Class C TARGET rebind (this tip)

Independent product-delta accounting for
`b1513073190089bd2dc2473a466373c8a1702f1f..f352b60d08e81c19d70ba46198fb06b71ddc85a1`:

| Commit | Subject | Paths |
|--------|---------|-------|
| `2c9babc` | docs: define post-TUI remote dual-backend Gate | docs only |
| `81b9355` | docs: harden post-TUI remote Gate execution | docs only |
| `69c1ec3` | docs: clarify post-TUI Gate authorization paths | docs only |
| `d29ff00` | docs: record post-TUI Gate contract PASS | docs only |
| `f352b60` | Update .gitignore | `.gitignore` only |

**No** `packages/**`, `src/**`, `build.zig*`, or `.github/**` product/CI delta
in that range. **TARGET already exists** as the full tip **before** this rebind
commit: it holds post-TUI product, TUI docs closeout, Phase A protocol docs, and
`.gitignore`. **This rebind commit does not recursively change TARGET** — Gate
`headSha` / push identity stay **`f352b60…`**, not the rebind commit’s SHA.

#### Supplied Class C event (authorization / remote truth)

| Fact | Binding |
|------|---------|
| Drift class that forced rebind | **Class C** relative to abandoned **OLD_TARGET** `b151307…` (live remote already ahead / not equal to OLD_TARGET) |
| Live remote before any OLD_TARGET push | Observed as **TARGET** `f352b60…` (supplied Class C incident) |
| Push of OLD_TARGET | **Not executed** |
| Prior OLD_TARGET `push_grant` | Had **no mutation**; **non-transferable / non-reusable** onto TARGET `f352b60…` |
| Rebind / different tip | Requires **fresh** grant of the appropriate type naming **new TARGET** |
| `origin/main` / local `main` at worktree creation | May equal TARGET as an **observed snapshot only** — **not** a Phase B decision input and **not** a grant |
| Phase B still requires | Fresh user grant **and** live `ls-remote` (never cache alone) |

### Review truth after rebind

| Claimed | Not claimed |
|---------|-------------|
| OLD_TARGET hardened protocol tip `69c1ec3` had dual-path PASS (facts/CI + safety/ops) under the **OLD_TARGET** identity contract | That PASS is a rebind PASS for **TARGET** `f352b60…` |
| Generic dual-grant / live-drift / unique-push / run-correlation **mechanisms** are retained | Any `observation_grant` / `push_grant` for TARGET |
| This tip is a **rebind candidate awaiting fresh facts/safety dual review** | Gate green; remote run id; Phase B started |
| Local docs rebind may later proceed after fresh dual review when scheduled | That old review transfers to the rebind tip |

**This contract document does not authorize Phase B.** No user
`observation_grant` or `push_grant` is claimed here. Template commands below
are **examples for a future authorized Phase B agent** and **must not** be
executed from Phase A.

Depends on (both **done**):

| Predecessor | Status | Why required |
|-------------|--------|--------------|
| [tui-minimal-001](./tui-minimal-001.md) | **done** @ impl `f8f7f55` (contract PASS @ `c7a8f3a`; docs closeout lineage `9d69574` → `8694fbb` → OLD_TARGET `b151307`) | Post-TUI product tip + local evidence; TUI closeout did **not** claim remote Gate |
| [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md) | **done** (docs-only) @ tip `8a93ec6` / run `30273762011` | Prior exact-tip remote Gate **pattern** only — tip/run numbers **not** reusable as this Gate’s PASS |

Does **not** own: product/fixture/build/CI-YAML edits; TUI remote maturity;
theme/RPC/ACP/E2/E3; maturity row raise; any remote mutation without valid
`push_grant` naming **TARGET**; any Phase B live reads/closeout without a valid
Phase B grant naming **TARGET**.

# context

## Why this Gate exists

1. [tui-minimal-001](./tui-minimal-001.md) closed minimal TUI at `f8f7f55` with
   dual final reviews PASS and **local macOS** Gates. Docs closeout tips
   through OLD_TARGET `b151307` stayed **local** to that closeout chain.
2. Local remote-tracking reflog once observed an **external/other push** of
   `f8f7f55` to `origin/main`. That is **cache history only** — never a live
   Phase B decision input. **Branch presence ≠ remote Gate.**
3. Historical M0 Gate [linux-dual-backend-gate-001](./linux-dual-backend-gate-001.md)
   closed only at tip `8a93ec6` / run `30273762011` — prior tip/run only.
4. Phase A docs for this Gate landed on top of OLD_TARGET as
   `2c9babc → 81b9355 → 69c1ec3 → d29ff00`, then `f352b60` (`.gitignore`) —
   becoming the sole **active** freeze tip **TARGET**.
5. Class C vs OLD_TARGET (live remote already at TARGET before any OLD_TARGET
   push) abandoned OLD_TARGET; this rebind freezes **TARGET** only.
6. Remaining honesty gap: fresh remote default dual-OS dual-backend evidence
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
| **TARGET** (full; unique active freeze) | `f352b60d08e81c19d70ba46198fb06b71ddc85a1` |
| TARGET short | `f352b60` (never use short form in push/refspec) |
| Tip message | `Update .gitignore` |
| **OLD_TARGET** (historical / abandoned) | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| Product lineage into TARGET | impl `f8f7f55` + docs `9d69574` → `8694fbb` → OLD_TARGET `b151307` + Phase A docs `2c9babc` → `81b9355` → `69c1ec3` → `d29ff00` + `f352b60` |
| `f8f7f55` | Ancestor of TARGET (later **docs-only** + `.gitignore` commits) |
| Product delta OLD_TARGET..TARGET | **docs + `.gitignore` only** — no `packages/**` / `src/**` / `build.zig*` / `.github/**` |
| Local `origin/main` / main cache | Historical or creation-time **observation only**; **must not** decide Phase B alone |
| Phase A product delta (this rebind) | **none** — TARGET already holds product under test; rebind is docs-only |
| Rebind commit vs TARGET | Rebind docs commit is **after** TARGET; does **not** rebind Gate identity to itself |

**Pattern:** freeze exact target tip first; later (authorized) remote evidence.
Phase A/contract/rebind commits may stay local-only. **Remote Gate tip stays
TARGET** and does **not** rebind to this rebind commit’s SHA.

# authority / ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| This task (docs only) | TARGET identity; OLD_TARGET abandonment record; Phase A/B machine; live drift matrix; dual grant schema; unique push shape; run correlation; command tables; failure isolation | Product/CI edits; inventing run ids; greenwashing; Phase B without valid grant naming TARGET; push without `push_grant`; transferring OLD_TARGET grants |
| `.github/workflows/ci.yml` | Unchanged host rails + default matrix | TUI steps; product hang proof via timeout |
| Packages | Behavior under test | Edits from this node |
| User | Fresh Phase B `observation_grant` **or** `push_grant` (§authorization) naming **TARGET** | Implied authz via review/merge/“go ahead”/Goal alone; reuse of OLD_TARGET grant |

# exact target identity

| Identity | Binding value |
|----------|----------------|
| **TARGET** (active freeze) | `f352b60d08e81c19d70ba46198fb06b71ddc85a1` |
| **OLD_TARGET** (historical / abandoned) | `b1513073190089bd2dc2473a466373c8a1702f1f` — **not** acceptable as active headSha / grant body / push command |
| Destination ref | `refs/heads/main` on remote `origin` |
| Acceptable Actions `headSha` | **Exactly** TARGET |
| Forbidden as PASS | OLD_TARGET; any other SHA; timeout/cancel/skipped; historical run `30273762011`; local TUI counts as remote proof; re-run attempt ≠ 1 without new contract; rebind commit SHA as Gate tip |

---

# Phase A / Phase B state machine

```text
done deps (both point into this task)
  tui-minimal-001 ✅ ──────────────────┐
  linux-dual-backend-gate-001 ✅ ──────┤
                                       ▼
Phase A (CURRENT) — docs contract + Class C TARGET rebind
  ├─ status: in-progress (task not done)
  ├─ author contract + Class C rebind + cross-links + local docs commits
  ├─ OLD_TARGET protocol dual-review PASS @ 69c1ec3 retained as lineage only
  ├─ TARGET identity rebind = material change → awaiting fresh dual review
  ├─ this tip: Class C rebind docs only (not itself claimed re-reviewed PASS)
  ├─ after fresh dual review PASS: ff-only local merge allowed when scheduled
  ├─ NO push · NO run id · Gate NOT green · NO Phase B grant
  └─ this task remains docs-only forever

        │  fresh user Phase B grant naming TARGET:
        │    observation_grant  OR  push_grant
        │  (§authorization — not “push-only”; OLD_TARGET grants invalid)
        ▼

Phase B entry (shared preflight under either grant)
  ├─ live ls-remote only (cache origin/main never decides)
  ├─ classify A / B / C against TARGET
  │
  ├─ Class A (remote_oid == TARGET)
  │    → Path OBSERVE only; never push
  │    → allowed under observation_grant OR push_grant
  │      (if push_grant: mutation not used; push grant not consumed as push)
  │    → exactly one pre-existing qualifying run → docs closeout
  │    → else STOP / rebind (new Goal)
  │
  ├─ Class B (remote ancestor of TARGET; local proves)
  │    → Path PUSH only if valid unexhausted push_grant naming TARGET
  │    → if only observation_grant → STOP; request fresh push_grant
  │    → unique porcelain push → post live OID == TARGET
  │    → exactly one correlating CI run → evidence → done
  │
  └─ Class C (ahead / diverged / unknown)
       → STOP · rebind · never force
```

| Phase / path | Allowed | Forbidden |
|--------------|---------|-----------|
| **A** | Allowed docs; local commit; later local ff-only after **fresh** dual review PASS on rebind tip | Any push; run id; Gate green; product/CI edits; Phase B live reads without grant; treating OLD_TARGET review as rebind PASS |
| **B Path OBSERVE** (class A) | Live ls-remote; read-only `gh`/API; docs evidence if unique qualifying run | Re-push TARGET; invent run; product/CI fix |
| **B Path PUSH** (class B + `push_grant`) | Live drift twice; unique authorized push of TARGET; post-push live check; unique run correlation; evidence docs | Force; other refspecs; push under observation_grant; retry without new `push_grant`; OLD_TARGET refspec |

---

# authorization schema (Phase B) — dual grants

Phase B **prereq live reads**, path selection, and **docs closeout** require a
**new user message** choosing **exactly one** grant type below. Goal selection,
Phase A review PASS, local merge, Class C rebind, or vague “继续/go ahead”
**never** substitute.

Both grant types may authorize **live preflight read** (`ls-remote`, optional
read-only fetch for ancestry under Phase B, and Actions read for the allowed
path). Only `push_grant` may authorize remote mutation.

**OLD_TARGET grants are void for TARGET.** A grant that named
`b1513073190089bd2dc2473a466373c8a1702f1f` — even with `mutation_used=false` —
**cannot** authorize observation or push of
`f352b60d08e81c19d70ba46198fb06b71ddc85a1`. Rebind / different tip → **fresh**
grant naming TARGET.

## Grant type A — `observation_grant`

### Valid (all required)

A **new user message** that includes an **illocutionary authorize verb**, e.g.:

- Chinese: **「我授权」** observation-only Phase B …
- English: **「I authorize」** observation-only Phase B …

and explicitly names:

1. Full TARGET: `f352b60d08e81c19d70ba46198fb06b71ddc85a1`
2. Mode: **observation-only** / **no push**
3. Scope: live remote tip + Actions read + docs closeout for that TARGET only

Example shape (not executed; not claimed as granted):

> I authorize observation-only Phase B for
> `f352b60d08e81c19d70ba46198fb06b71ddc85a1` on `origin` `refs/heads/main`:
> live read and Actions evidence only; **no push**.

### Allows / forbids

| Allows | Forbids |
|--------|---------|
| Live `ls-remote`; class A Path OBSERVE; Actions read; docs closeout if evidence PASS | Any `git push`; class B Path PUSH (must STOP and request `push_grant`); force; OLD_TARGET grant reuse |

### Evidence fields (`observation_grant`)

| Field | Required |
|-------|----------|
| `grant_type` | `observation_grant` |
| `authorized_at` | ISO-8601 of user message |
| `authorizer` | `user` |
| `verbatim` | Exact user message (or durable citation) |
| `scope` | `observe-only TARGET f352b60d08e81c19d70ba46198fb06b71ddc85a1; no push` |
| `force` | `false` |
| `mutation` | `none` |

## Grant type B — `push_grant`

### Valid (all required)

A **new user message** that includes an **illocutionary authorize verb**, e.g.:

- Chinese: **「我授权 Path PUSH」** / **「我授权推送」**
- English: **「I authorize Path PUSH」**

and explicitly names **all** of:

1. Full TARGET SHA: `f352b60d08e81c19d70ba46198fb06b71ddc85a1`
2. Destination: `origin` / `refs/heads/main`
3. Push class: **normal non-force**
4. Scope: **only** single refspec `TARGET:refs/heads/main`

Example shape (not executed; not claimed as granted):

> I authorize Path PUSH of
> `f352b60d08e81c19d70ba46198fb06b71ddc85a1` to `origin` `refs/heads/main`
> as a normal non-force single refspec only.

### Allows / forbids

| Allows | Forbids |
|--------|---------|
| Live preflight; class A → Path OBSERVE (**mutation not used**; do **not** treat as push consumption); class B → unique Path PUSH of TARGET | Class B without this grant; force; multi-refspec; short SHA; `HEAD:main`; OLD_TARGET refspec |

### Evidence fields (`push_grant`)

| Field | Required |
|-------|----------|
| `grant_type` | `push_grant` |
| `authorized_at` | ISO-8601 of user message |
| `authorizer` | `user` |
| `verbatim` | Exact user message (or durable citation) |
| `scope` | `only f352b60d08e81c19d70ba46198fb06b71ddc85a1:refs/heads/main` |
| `force` | `false` |
| `attempt` | `one-shot` — **exhausted after one push command attempt** |
| `mutation_used` | `true` if B7 ran; `false` if class A OBSERVE under this grant |

## Invalid authorization (both types; fail-closed)

| Invalid source | Why |
|----------------|-----|
| Prior conversation / prior grant | Not transferable across sessions or attempts |
| OLD_TARGET-named grant (any type) | Tip identity changed; non-transferable to TARGET |
| Phase A author / review / local merge / Class C rebind | Review ≠ Phase B grant |
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
| Retry / re-run Actions / rebind / different ref / different TARGET | New grant of the appropriate type naming the active TARGET |

**Current Phase A status:** neither grant exists for TARGET; do not claim
otherwise. Any historical OLD_TARGET grant is **void** for this freeze.

### Class × grant predicate (single binding table)

| Live class | `observation_grant` | `push_grant` |
|------------|---------------------|--------------|
| **A** (`remote_oid == TARGET`) | Path OBSERVE | Path OBSERVE (`mutation_used=false`; never push) |
| **B** (remote ancestor of TARGET) | **STOP** — request `push_grant` | Path PUSH if unexhausted |
| **C** (ahead / diverged / unknown) | **STOP** | **STOP** |

**Note:** If live remote is already TARGET, Class A applies and Path OBSERVE
must **never re-push**. Cache equality to TARGET is not sufficient — Phase B
still requires a valid grant + live `ls-remote`.

---

# live-only remote drift matrix (Phase B)

## Live OID is the only decision input

| Input | Role |
|-------|------|
| Live `git ls-remote` OID of `refs/heads/main` | **Only** remote tip used for drift class |
| Local `origin/main` / remote-tracking branch | **Cache / history only** — must **not** alone choose path |
| Worktree-creation snapshot of main/origin | Observation only — not a grant; not live proof |
| Local TARGET object | Must verify as full commit SHA before push |

### Live read (required; read-only)

Requires a valid Phase B grant (`observation_grant` or `push_grant`) naming
TARGET.

```text
git ls-remote --exit-code origin refs/heads/main
```

| ls-remote outcome | Action |
|-------------------|--------|
| Exit 0, **exactly one** line, OID is 40-hex full SHA | Parse `remote_oid`; classify vs TARGET |
| Non-zero, empty, multi-line, non-hex, no permission, network error | **STOP** — no push; no guess |

Record `remote_oid` and `live_read_at`.

### Local ancestry proof (class B / Path PUSH)

1. `git rev-parse --verify 'f352b60d08e81c19d70ba46198fb06b71ddc85a1^{commit}'`
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
| **B** | `remote_oid != TARGET` and local proves ancestor | **PUSH** only with valid `push_grant` naming TARGET |
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
git push --porcelain origin f352b60d08e81c19d70ba46198fb06b71ddc85a1:refs/heads/main
```

When live remote is already TARGET, Class A applies: **OBSERVE only — never
re-push** even under a `push_grant` (`mutation_used=false`).

### Pre-push (all required)

| Check | Binding |
|-------|---------|
| Authz | Valid unexhausted **`push_grant`** naming TARGET |
| Drift | Live class **B** |
| Object | `rev-parse` → exact TARGET |
| Ancestry | Local proof |
| Record | `push_started_at` before push |

### Forbidden

`git push origin main`; `HEAD:main`; short SHA; multi-refspec; any `--force*`;
`--all` / `--mirror` / `--tags` / `--follow-tags`; other commits (including
OLD_TARGET or rebind commit); pull/merge/reset/rebase to “fix” remote.

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
SHA (including OLD_TARGET), `run_attempt != 1`, cancelled/timeout, wrong `path`.

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

Templates only. **Do not execute without the matching grant naming TARGET.**
No force/retry recipes.

| # | Stage | Command / action | Side effect | Grant required | On fail |
|---|-------|------------------|-------------|---------------|---------|
| B0 | Parse grant | Classify message as `observation_grant` or `push_grant` naming TARGET; fill evidence; reject OLD_TARGET-named grants | none | valid one of two | STOP Phase B |
| B1 | Live tip | `git ls-remote --exit-code origin refs/heads/main` | network read | either grant | STOP |
| B2 | Classify | A / B / C on live OID vs TARGET only | none | either | C → STOP/rebind |
| B2a | Class A | Enter Path OBSERVE; never push; if `push_grant`, set `mutation_used=false` | none | either | — |
| B2b | Class B + observation only | **STOP**; request fresh `push_grant` | none | observation only | do not push |
| B2c | Class B + push_grant | continue Path PUSH | none | `push_grant` unexhausted | — |
| B3 | Local TARGET | `git rev-parse --verify 'f352b60d08e81c19d70ba46198fb06b71ddc85a1^{commit}'` | none | Path PUSH | STOP |
| B4 | Ancestry | `git merge-base --is-ancestor <remote_oid> TARGET` | none | Path PUSH | STOP/rebind |
| B5 | TOCTOU | repeat B1; require class B | network read | Path PUSH | STOP no push |
| B6 | Clock | `push_started_at` | none | Path PUSH | — |
| B7 | **Unique push** | `git push --porcelain origin f352b60d08e81c19d70ba46198fb06b71ddc85a1:refs/heads/main` | **mutates main** | **`push_grant` only** | record; grant consumed; STOP |
| B8 | Post live | B1; OID == TARGET | network read | after push | STOP no claim |
| B9 | Run list | `gh run list …` | network read | either path | STOP |
| B9a | Run path | `gh api repos/…/actions/runs/<id>` require `path` | network read | either path | STOP if no path |
| B10 | Filter | exactly one full match (`headSha` == TARGET) | none | — | 0/>1 STOP |
| B11 | Logs | `gh run view … --log` | network read | — | STOP if missing |
| B12 | Evidence docs | fill schema; `done` only if PASS | local docs | docs only | stay `in-progress` |

| Missing | Action |
|---------|--------|
| No Phase B grant naming TARGET | Do not start B1+ |
| OLD_TARGET-only grant | Reject; request fresh grant naming TARGET |
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
| **TARGET** (active freeze) | `f352b60d08e81c19d70ba46198fb06b71ddc85a1` |
| **OLD_TARGET** (abandoned) | `b1513073190089bd2dc2473a466373c8a1702f1f` |
| OLD_TARGET protocol dual-review | **PASS** @ `69c1ec3` under OLD_TARGET identity only — **not** rebind PASS |
| Rebind review status | **rebind candidate awaiting fresh facts/safety dual review** |
| Phase B grants | **none claimed** (`observation_grant` / `push_grant` absent for TARGET) |
| Run id / URL | **none** |
| Gate green | **No** |
| Phase B | **not started** |

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

## Phase A — Docs contract + Class C TARGET rebind (current)

- [x] Task authored; `status: in-progress`; depends-on both done preds
- [x] Independent product-delta accounting: OLD_TARGET..TARGET = Phase A docs chain + `.gitignore` only; **no** packages/src/build.zig*/.github product/CI delta
- [x] **TARGET** frozen full SHA `f352b60d08e81c19d70ba46198fb06b71ddc85a1` (unique active freeze; exists before rebind commit)
- [x] **OLD_TARGET** `b151307…` recorded as historical/abandoned; not active headSha/grant/push
- [x] Class C incident + old grant **non-transfer** recorded
- [x] Dual grant schema (`observation_grant` / `push_grant`) + class×grant table rebinding evidence scopes to TARGET
- [x] Live drift A/B/C; unique push of TARGET; run correlation with API `path`; command table
- [x] Explicit: no remote `-Dtui`; no maturity raise; no historical run as PASS; no OLD_TARGET as active freeze
- [x] Allowed Active surfaces cross-links updated to TARGET
- [x] Local docs rebind commit; **no push**
- [x] Docs lint + score check + `git diff --check` + scope on rebind commit
- [ ] **Fresh independent dual final re-review** (facts/CI + safety/ops) on this **rebind** tip — **unchecked**; OLD_TARGET `69c1ec3` PASS is **not** rebind PASS
- [x] Status remains **`in-progress`** until Phase B evidence; Gate **not** green; grants **none**; Phase B **not started**

## Phase B — not started

- [ ] Fresh user `observation_grant` **or** `push_grant` recorded naming **TARGET** (authorize verb + body)
- [ ] Live ls-remote OID; class A or B vs TARGET (C → STOP)
- [ ] Class A: OBSERVE only; never push; unique qualifying run + `path` with `headSha` == TARGET
- [ ] Class B: only with `push_grant`; unique porcelain push of TARGET; post OID == TARGET
- [ ] Exactly one correlating run; name `CI`; **path** `.github/workflows/ci.yml`; attempt 1; success
- [ ] Both jobs + step evidence (macOS step 9 skip exception only)
- [ ] Real run id/URL + log numbers (no `30273762011` / local TUI copy / OLD_TARGET headSha)
- [ ] Status → `done` only after evidence docs; still no maturity raise

# failure outcomes

| Failure | Outcome |
|---------|---------|
| Job/step fail / timeout / cancel / skip (non-excepted) | not PASS; stay `in-progress` |
| Class C or unknown live tip | STOP; rebind; no force |
| Class B with only `observation_grant` | STOP; request `push_grant` |
| Product/CI defect | new fix task + new tip + new Gate |
| Grant missing/invalid/exhausted / OLD_TARGET-named only | no push; no false OBSERVE claim |
| >1 or 0 matching runs / no path | STOP |

# non-goals

- Feature novelty; remote `-Dtui`; maturity raise
- Editing packages/build/CI; force push; soft green
- Reusing `8a93ec6` / `30273762011` as this tip’s PASS
- Reusing OLD_TARGET `b151307…` as active TARGET / headSha / grant / push
- Marking `done` in Phase A; selecting theme/RPC/ACP without fresh Goal
- Claiming current user has granted Phase B (`observation_grant` or `push_grant`)
- Treating OLD_TARGET dual-review PASS as rebind PASS

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
| Docs closeout → OLD_TARGET | `9d69574` → `8694fbb` → **`b151307` OLD_TARGET** | abandoned freeze tip |
| Phase A initial contract | `2c9babcb789f767c15ca17fbe49ce3a793cdc477` | define Gate under OLD_TARGET |
| Phase A safety harden | `81b93554942e55d1bae975a8b7b3ba2318c068fe` | dual-grant / live-drift mechanisms |
| Phase A auth clarify / OLD_TARGET contract review PASS | `69c1ec39528c819ed045cf4d0de1d1c3fb6bedaa` | dual final re-review PASS under **OLD_TARGET** only |
| Phase A PASS-record | `d29ff0043c8aafb7c940041fcc5441c8044a708c` | recorded prior OLD_TARGET-tip PASS |
| **TARGET** tip (active freeze) | **`f352b60d08e81c19d70ba46198fb06b71ddc85a1`** | `.gitignore` on Phase A chain; product+docs tip |
| Class C rebind (this tip) | local docs after TARGET | rebinds active identity to TARGET; does **not** change TARGET SHA; awaiting fresh dual review |
| Class C incident | live remote already TARGET before OLD_TARGET push; no push; OLD_TARGET grant non-transfer | forces rebind + fresh grant |
| Phase B run | *pending valid Phase B grant naming TARGET* | real run only; not started |

# delivery evidence (Phase A)

| Field | Value |
|-------|--------|
| Path | Docs-only Phase A (contract + harden + auth clarify + PASS-record + **Class C TARGET rebind**) |
| Status | **`in-progress`** |
| **TARGET** | `f352b60d08e81c19d70ba46198fb06b71ddc85a1` |
| **OLD_TARGET** | `b1513073190089bd2dc2473a466373c8a1702f1f` (abandoned) |
| OLD_TARGET dual re-review | **PASS** @ `69c1ec3` (facts/CI + safety/ops) — lineage only |
| Rebind dual re-review | **awaiting** (not PASS; not claimed) |
| Phase B grants | **not present / not claimed** for TARGET |
| Run id | **none** |
| Maturity | unchanged |
| Remote `-Dtui` | not claimed |
| Gate green | **No** |
| Phase B | **not started** |

# closeout

**Active freeze is TARGET
`f352b60d08e81c19d70ba46198fb06b71ddc85a1`.** OLD_TARGET protocol review PASS
@ `69c1ec3` remains lineage under the abandoned identity only. This Class C
rebind tip is a **rebind candidate awaiting fresh facts/safety dual review**
and does **not** inherit OLD_TARGET review as rebind PASS. Task remains
**`in-progress`** until Path OBSERVE or Path PUSH records valid remote evidence
under a fresh user grant **naming TARGET**. This rebind commit does **not**
authorize Phase B, invent a run id, mark the Gate green, or change TARGET to
the rebind commit’s own SHA. Templates remain non-executable without a fresh
grant. If live remote is already TARGET, Class A Path OBSERVE applies and must
**never re-push**.
