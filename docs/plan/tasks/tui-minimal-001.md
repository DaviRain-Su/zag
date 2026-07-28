---
id: tui-minimal-001
scope: host-shell/tui-minimal (M2 / C9; contract PASS; implementation done)
status: done
priority: P1
depends-on:
  - harness-events-001
  - harness-steering-001
  - cli-sigint-001
  - headless-001
  - edit-sharpness-001
---

# objective

Freeze the **minimal host TUI binding contract** and deliver a **minimal
interactive host shell** that assembles public coding-agent / CLI APIs
**without** inventing lifecycle kinds, weakening ask/jail/shell, polluting
headless stdout, or placing UI logic in Kernel packages.

**Binding specification:** [tui-minimal.md](../../modules/tui-minimal.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze | **PASS** @ `c7a8f3a` — independent arch + safety re-reviews, **zero blockers** |
| Implementation tip | **`f8f7f55014a01ce4d6cf3ad7b751c8f6f0aa30b5`** — two independent final code reviews **PASS**, **zero blockers** |
| Overall product task | **`done`** — local ff-only merge of impl tip to canonical main; task-worktree + merged-main Gates green (local macOS only) |
| Docs closeout tips | `9d69574` (delivery closeout) → `8694fbb` (feature-correspondence sync) → this push-truth follow-up; **remain local / not on `origin/main`** |
| Maturity / C9 broader shell | **unchanged** — no new maturity row; not theme/RPC/ACP/extension-UI/dashboard/Pi parity |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** |
| Linux / remote Gate | **not claimed** by this TUI task for tip `f8f7f55` (or docs tips) — branch presence ≠ validation. Post-TUI default-path remote dual-backend Gate is owned by [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md) (**in-progress**, Phase A; TARGET `f352b60`; Class C rebind awaiting fresh dual review; **no** run id; **no** remote `-Dtui` claim). |
| `origin/main` presence | Local remote-tracking reflog records an **external/other push** of implementation tip `f8f7f55` to `origin/main` (`update by push` @ `2026-07-28 06:17:02 +0800`); **this closeout did not execute or authorize that push**. TUI docs closeout tips remain local through historical `b151307` (OLD_TARGET on the post-TUI Gate). Remote branch presence is **not** a Linux/remote Gate. Unrelated canonical `.gitignore` retained on local merge. |

## Contract vs implementation (history)

```text
CONTRACT NODE (docs freeze)
  PASS tip: c7a8f3a23eb2b66febdd24a891ba55ee7fd09a11
  paths: docs only at freeze time
  did not ship packages/zag-tui

IMPLEMENTATION NODE (product package + wire + fixtures)
  final tip: f8f7f55014a01ce4d6cf3ad7b751c8f6f0aa30b5
  paths: packages/zag-tui/** + zag-cli / root -Dtui wire + §11 tests
  independent dual final reviews: PASS, zero blockers
  local ff-only onto canonical main at same tip (canonical .gitignore retained)
  later: local origin/main reflog shows external/other push of f8f7f55
         (not executed/authorized by this closeout; not a remote Gate)

DOCS CLOSEOUT NODE (local only; not on origin/main at f8f7f55)
  9d69574 → 8694fbb → this tip
  paths: docs only — status truth + indexes; no product code
```

# context

- Closed M1 lifecycle: [harness-events-001](./harness-events-001.md) @ `aecf402`
- Closed M1 steering: [harness-steering-001](./harness-steering-001.md) @ `a5ff2b7`
- Closed M0 SIGINT: [cli-sigint-001](./cli-sigint-001.md) +
  [cli-interaction](../../modules/cli-interaction.md)
- Closed headless: [headless-001](./headless-001.md) — stdout purity,
  `-Dtui` default false, Kernel no-TUI scan
- Closed C4 first slice: [edit-sharpness-001](./edit-sharpness-001.md) @
  `7be5151` — hunk review ≠ permission; TUI ask v1 hunk_reviewer **null**
- Contract: Round-1 **BLOCKED** → freezes @ `a38f0ec` → signal-host
  @ `6c73e46` → teardown @ `c7a8f3a` → **final re-reviews PASS**
- Implementation: package + dual-review fix → PTY fixtures → test hygiene →
  final tip `f8f7f55` dual review **PASS** (zero blockers)

# path

## Docs (closeout)

| Path | Role |
|------|------|
| `docs/plan/tasks/tui-minimal-001.md` | this task |
| `docs/modules/tui-minimal.md` | **binding truth** + closeout evidence pointer |
| `docs/phases/C9-product-shell.md` | product acceptance checkboxes |
| `docs/modules/README.md` · `docs/plan/README.md` · `docs/roadmap.md` · `docs/INDEX.md` | indexes |
| `docs/packaging.md` · `docs/maturity.md` | package status + closeout truth (no row raise) |

## Implementation (delivered)

| Path | Role |
|------|------|
| **`packages/zag-tui/**` only** | host UI (module `zag-tui`) |
| root + `zag-cli` `build.zig` / `.zon` | `-Dtui` bool; lazy optional `zag-tui` + terminal dep |
| `packages/zag-cli` | `--tui` mode mutex + SignalHost wrapping Guard; assemble when `-Dtui=true` |
| tests under `zag-tui` / CLI process fixtures | §11 unit/integration/PTY matrix |
| **forbidden / unchanged** | Core/schema/maturity; production defaults (ask + jail + shell protect) |

# contract summary

Authoritative detail lives in [tui-minimal.md](../../modules/tui-minimal.md).
Do not restate conflicting rules here. Mechanism freezes through `c7a8f3a` are
unchanged by implementation or this docs closeout.

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Package owner | **only** `packages/zag-tui/` (`zag-tui`); CLI wires when `-Dtui=true` |
| Dep direction | CLI → `zag-tui` only; `SignalHost` defined by TUI, implemented by CLI |
| Init / teardown / redaction / concurrency / mode matrix | as frozen through `c7a8f3a` |
| Defaults | permission **ask**; workspace jail; shell **protect**; `-Dtui` default **false** / lazy |
| Non-goals | theme/dashboard/RPC/ACP/E2–E3/schema/maturity/Pi parity/wholesale vaxis |

# verification (contract track — historical)

- [x] Round-1 architecture + safety **BLOCKED** findings closed @ `a38f0ec`
- [x] Signal host / Guard-after-Agent order follow-up @ `6c73e46`
- [x] Teardown order A11/B-S10 follow-up @ `c7a8f3a`
- [x] Independent **architecture / ownership** contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] Independent **safety / fail-closed** contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] Contract-path docs lint / score / `git diff --check`
- [x] Contract node contained **only** docs (no product code)

# verification (implementation track — closed @ `f8f7f55`)

- [x] Package `packages/zag-tui` + lazy `-Dtui` root/cli wire (default **false**)
- [x] Named §11 unit/integration/process fixtures (`tests_gate.zig` + CLI `tui_process_fixture.zig`)
- [x] Dual-thread host; lifecycle cards; permission single-slot; full outward redaction
- [x] PTY process fixtures (macOS product path): geometry; idle Ctrl+C; blocked busy first/second SIGINT; Ctrl+D / termios restore — **no** current-tip Linux/remote claim
- [x] gate21 write isolation: run-unique exclusive owned workspace (`f8f7f55`); no bare cwd pollution
- [x] Independent final code reviews (**two paths**) **PASS**, **zero blockers** @ `f8f7f55`
- [x] Local ff-only merge of impl tip onto canonical main (same tip); unrelated canonical `.gitignore` retained
- [x] Local remote-tracking reflog later recorded an **external/other push** of `f8f7f55` to `origin/main`; **this closeout did not execute or authorize that push**. Docs closeout remains local. Remote branch presence is **not** a Linux/remote Gate
- [x] Task-worktree **and** merged canonical main — same serial matrix (local macOS):

| Matrix | Steps · tests |
|--------|----------------|
| default std (`-Dtui` false) | **42/42 · 656/656** |
| default curl | **44/44 · 655/655** |
| TUI std (`-Dtui=true`) | **47/47 · 711/711** |
| TUI curl (`-Dtui=true -Dhttp_backend=curl`) | **49/49 · 710/710** |
| OpenAPI | **287/287** |
| catalog | **40** |
| docs readability / security | **92/100** / **74/100** (55 files) |
| docs lint + committed-range diff | clean |

- [x] Kernel import scan / plain+headless paths retained; Core / session-v1 / Trace-v1 / headless-v1 schemas **unchanged**
- [x] No maturity row raise; no Linux/remote Gate claim for this tip; no production-default weaken

# non-goals

- Theme / dashboard / images / plugin platform
- RPC / ACP / editor host
- E2/E3 extension UI
- OS sandbox; multi-file edit platform
- Core or session-v1 / Trace-v1 / headless-v1 schema changes
- Maturity promotion or a new “TUI L2” row
- Pi API or TUI parity; wholesale vaxis port
- Claiming remote CI or Linux Gates for tip `f8f7f55` (branch presence ≠ Gate)
- Owning the post-TUI default-path remote dual-backend Gate (see
  [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md);
  Phase A in-progress; separate authorization for Phase B push)

# lineage (tips)

| Stage | Tip |
|-------|-----|
| Contract candidate (initial freeze) | `d01d70b7d02566f0354f976775dab020399d0df5` |
| Blocker-close follow-up | `a38f0ecde46d9f0c948f3a36dd8f46b1a7aad66f` |
| Signal-host / Guard order follow-up | `6c73e4652a737b3fead0dbd15a2c661ebe66cfda` |
| Teardown order follow-up (**contract PASS**) | `c7a8f3a23eb2b66febdd24a891ba55ee7fd09a11` |
| Dual-review product fix | `adf3097` |
| Strict PTY Gates #30–32/#18 | `ab610ce` |
| gate21 hygiene (scoped write) | `a97efa6` |
| gate21 exclusive run-unique workspace (**impl final tip**; later on `origin/main` via external/other push) | `f8f7f55014a01ce4d6cf3ad7b751c8f6f0aa30b5` |
| Docs closeout delivery | `9d69574` (local only) |
| Docs feature-correspondence sync | `8694fbb` (local only) |
| Docs remote-tip truth follow-up | `b151307` (local only; historical OLD_TARGET for [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md); active TARGET is now `f352b60`) |
