---
id: tui-minimal-001
scope: host-shell/tui-minimal (M2 / C9; contract PASS; implementation candidate)
status: ready
priority: P1
depends-on:
  - harness-events-001
  - harness-steering-001
  - cli-sigint-001
  - headless-001
  - edit-sharpness-001
---

# objective

Freeze the **minimal host TUI binding contract** and deliver an **implementation
candidate** that assembles public coding-agent / CLI APIs into a small
interactive shell **without** inventing lifecycle kinds, weakening ask/jail/shell,
polluting headless stdout, or placing UI logic in Kernel packages.

Contract track remains **PASS**. Implementation is a **candidate awaiting
independent code review + coordinator task/main Gates** — not product “done”,
not maturity raise, not Linux/remote claim.

**Binding specification:** [tui-minimal.md](../../modules/tui-minimal.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze | **PASS** @ `c7a8f3a` — independent arch+safety re-reviews, zero blockers |
| Implementation candidate | **in this worktree** (`task/tui-minimal-001-impl`) — `packages/zag-tui` + CLI wire + §11 tests; **awaiting independent code review + coordinator Gates** |
| Overall product task | **`ready`** (contract) + **implementation candidate** (not claimed done) |
| Maturity / C9 product acceptance | **unchanged / not claimed** |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** by this impl |

## Contract vs implementation split

```text
THIS NODE (docs contract)
  status: ready (contract track PASS @ c7a8f3a; not product done)
  paths: docs only
  verify: docs lint + score_docs --check + git diff --check (no full std/curl claim)
  merge: docs-only contract may ff-only merge; does not ship TUI

LATER NODE (implementation; separate tip / Gate / worktree)
  NOT opened by this node
  Requires:
    1) contract PASS (done @ c7a8f3a) and contract merge
    2) explicit future Goal / reconciliation selecting an implementation delivery
  paths: packages/zag-tui/ ONLY + zag-cli wire + build wiring + tests
  verify: full fixture matrix in tui-minimal.md §11 + dual-backend Gates
```

Frontmatter `status: ready` means the **contract track is ready for merge**
and a future Goal may select implementation work — **not** that product TUI
is done or that implementation has started.

# context

- Closed M1 lifecycle: [harness-events-001](./harness-events-001.md) @ `aecf402`
- Closed M1 steering: [harness-steering-001](./harness-steering-001.md) @ `a5ff2b7`
- Closed M0 SIGINT: [cli-sigint-001](./cli-sigint-001.md) +
  [cli-interaction](../../modules/cli-interaction.md)
- Closed headless: [headless-001](./headless-001.md) — stdout purity,
  `-Dtui` default false, Kernel no-TUI scan
- Closed C4 first slice: [edit-sharpness-001](./edit-sharpness-001.md) @
  `7be5151` — hunk review ≠ permission; TUI ask v1 hunk_reviewer **null**
- Round-1 architecture/safety **BLOCKED** → freezes @ `a38f0ec` → signal-host
  @ `6c73e46` → teardown @ `c7a8f3a` → **final re-reviews PASS** (zero blockers)

# path

## Docs (this node — only allowed changes)

| Path | Role |
|------|------|
| `docs/plan/tasks/tui-minimal-001.md` | this task |
| `docs/modules/tui-minimal.md` | **binding truth** |
| `docs/phases/C9-product-shell.md` | phase; product acceptance unchecked |
| `docs/modules/README.md` | module index |
| `docs/plan/README.md` | DAG + task index |
| `docs/roadmap.md` | M2 / C9 pointer |
| `docs/INDEX.md` | product-spec link |
| optional minimal cross-links | packaging / headless only for single truth |

## Later implementation paths (NOT this node)

| Path | Role |
|------|------|
| **`packages/zag-tui/**` only** | host UI (module `zag-tui`) |
| root + `zag-cli` `build.zig` / `.zon` | `-Dtui` bool pass-through; lazy optional `zag-tui` + terminal dep |
| `packages/zag-cli/src/cli.zig` | `--tui` mode mutex + assemble `zag-tui` when built |
| tests under `zag-tui` / CLI | §11 fixture matrix |
| **forbidden** | `packages/zag-cli/src/tui/**` owner; Core/schema/maturity changes |

# contract summary

Authoritative detail lives in [tui-minimal.md](../../modules/tui-minimal.md).
Do not restate conflicting rules here. Mechanism freezes are unchanged by this
PASS-record tip.

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Package owner | **only** `packages/zag-tui/` (`zag-tui`); CLI wires when `-Dtui=true` |
| Dep direction | CLI → `zag-tui` only; `SignalHost` defined by TUI, implemented by CLI |
| Init / teardown / redaction / concurrency / mode matrix | as frozen through `c7a8f3a` |
| Non-goals | theme/dashboard/RPC/ACP/E2–E3/schema/maturity/Pi parity/wholesale vaxis |

# verification (contract track — this node)

- [x] Round-1 architecture + safety **BLOCKED** findings closed @ `a38f0ec`
- [x] Signal host / Guard-after-Agent order follow-up @ `6c73e46`
- [x] Teardown order A11/B-S10 follow-up @ `c7a8f3a`
- [x] Independent **architecture / ownership** contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] Independent **safety / fail-closed** contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] `python3 scripts/lint_docs.py` (docs path; this tip)
- [x] `python3 scripts/score_docs.py --check` (docs path; this tip)
- [x] `git diff --check` on contract docs range
- [x] Diff contains **only** expected docs (+ quality reports if body/score changes)
- [x] Confirm **no** `packages/`, `src/`, `build.zig*` product changes
- [x] C9 product acceptance remains **unchecked**
- [x] No maturity raise; no “TUI implemented” / current-tip Linux claim
- [ ] Full std/curl product Gate — **not run on this tip**; do not invent numbers

# verification (implementation track — candidate)

- [x] Package `packages/zag-tui` + lazy `-Dtui` root/cli wire (default false)
- [x] Named §11 unit/integration/process fixtures (see zag-tui `tests_gate.zig` + CLI `tui_process_fixture.zig`)
- [x] `zig build test` (default false) green on implementer host
- [x] `zig build test -Dtui=true` green on implementer host
- [x] `zig build test -Dtui=true -Dhttp_backend=curl` green on implementer host
- [x] Kernel import scan green; plain/headless path retained
- [ ] Independent code review PASS
- [ ] Coordinator task/main Gates (not claimed by implementer)
- [ ] No maturity row raise; no Linux/remote claim

# non-goals

- Theme / dashboard / images / plugin platform
- RPC / ACP / editor host
- E2/E3 extension UI
- OS sandbox; multi-file edit platform
- Core or session-v1 / Trace-v1 / headless-v1 schema changes
- Maturity promotion
- Pi API or TUI parity; wholesale vaxis port
- This contract node adding packages, dependencies, or product code
- Claiming product TUI done or auto-starting implementation from contract merge

# lineage (tips)

| Stage | Tip |
|-------|-----|
| Contract candidate (initial freeze) | `d01d70b7d02566f0354f976775dab020399d0df5` |
| Blocker-close follow-up | `a38f0ecde46d9f0c948f3a36dd8f46b1a7aad66f` |
| Signal-host / Guard order follow-up | `6c73e4652a737b3fead0dbd15a2c661ebe66cfda` |
| Teardown order follow-up (PASS tip) | `c7a8f3a23eb2b66febdd24a891ba55ee7fd09a11` |
| Contract PASS record (this docs tip) | tip with message `docs: record minimal TUI contract pass` |
| Implementation | **not started** (future Goal / separate node) |
| Closeout | blocked on implementation |
