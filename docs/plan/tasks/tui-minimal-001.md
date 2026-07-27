---
id: tui-minimal-001
scope: host-shell/tui-minimal (M2 / C9 contract candidate)
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

Freeze the **minimal host TUI binding contract** so a later implementation
node can assemble public coding-agent / CLI APIs into a small interactive
shell **without** inventing lifecycle kinds, weakening ask/jail/shell,
polluting headless stdout, or placing UI logic in Kernel packages.

This task node is **docs-only (contract candidate)**. It does **not**
implement a product TUI, does **not** check off C9 product acceptance as
done, and does **not** claim maturity or Linux tip evidence.

**Binding specification:** [tui-minimal.md](../../modules/tui-minimal.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze (this node) | **candidate** — BLOCKED closed @ `a38f0ec`; signal-host @ `6c73e46`; teardown order follow-up; **re-review pending** |
| Overall product task | **`ready`** for re-review; **implementation BLOCKED** |
| Production TUI implementation | **not started** — blocked (see split below) |
| Maturity / C9 product acceptance | **unchanged / not claimed** |
| Session v1 / Trace v1 / headless-v1 / Core | **must remain unchanged** by later impl |

## Contract vs implementation split

```text
THIS NODE (docs contract candidate)
  paths: docs only
  verify: lint_docs + score_docs --check + git diff --check
  review: architecture/ownership + safety/fail-closed (re-review after blocker fix)
  merge: candidate only; does not ship TUI

LATER NODE (implementation; separate tip / Gate)
  BLOCKED until:
    1) independent architecture/ownership contract PASS
    2) independent safety/fail-closed contract PASS
    3) this contract merged to the integration branch used for impl
  paths: packages/zag-tui/ ONLY + zag-cli wire + build wiring + tests
  verify: full fixture matrix in tui-minimal.md §11 + dual-backend Gates
```

Frontmatter `status: ready` means dependencies are met for **contract
re-review**, not that implementation may start before the two contract PASS
results and merge.

# context

- Closed M1 lifecycle: [harness-events-001](./harness-events-001.md) @ `aecf402`
- Closed M1 steering: [harness-steering-001](./harness-steering-001.md) @ `a5ff2b7`
- Closed M0 SIGINT: [cli-sigint-001](./cli-sigint-001.md) +
  [cli-interaction](../../modules/cli-interaction.md)
- Closed headless: [headless-001](./headless-001.md) — stdout purity,
  `-Dtui` default false, Kernel no-TUI scan
- Closed C4 first slice: [edit-sharpness-001](./edit-sharpness-001.md) @
  `7be5151` — hunk review ≠ permission; TUI ask v1 hunk_reviewer **null**
- Round-1 architecture A1–A5 (+ A6–A10) and safety B-S1–B-S9 **BLOCKED**;
  unique freezes landed @ `a38f0ec`
- Follow-up: Guard install **after** `Agent.init`; `SignalHost` defined by
  `zag-tui`, implemented by CLI over `sigint.Guard`; post-join
  `acknowledge_cancel`; ≤250 ms poll timeout for coalesced wakes
- Follow-up A11/B-S10: final teardown
  ack → restore tty → App quiesce → **Guard.deinit** → Session.deinit →
  Agent.deinit → App free last (Guard unbind/drain before Agent storage free)

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
Do not restate conflicting rules here.

### Frozen choices (index after blocker close)

| Topic | Freeze |
|-------|--------|
| Package owner | **only** `packages/zag-tui/` (`zag-tui`); CLI wires when `-Dtui=true`; no `zag-cli/src/tui` |
| Dep direction | CLI → `zag-tui` only; **no** TUI import of CLI/`sigint`; `SignalHost` defined by TUI, implemented by CLI over Guard |
| Init order | App prealloc → `Agent.init` → `Guard.install(&agent.cancel)` → `Session.start` → bind redactor/SignalHost → raw |
| Post-join | every worker join success/error → `SignalHost.acknowledge_cancel` before idle (avoid false second SIGINT) |
| Final teardown | ack → restore tty → App quiesce (keep storage) → Guard.deinit → Session.deinit → Agent.deinit → App free; never Agent before Guard |
| Wake | bounded nonblocking drop-on-full + poll timeout ≤250 ms |
| Concurrency | UI + single reply worker; short locks; permission single-slot rendezvous; no worker TTY I/O |
| Session | product `create_new`/`resume_existing` only; no `open_or_create` product path |
| Bind matrix | ask→`Gate.ask(TuiPermissionAdapter)`; yolo explicit; TUI ask hunk **null**; yolo AutoAccept |
| Redaction / reserves / mode matrix | unchanged from `a38f0ec` freezes (no rollback) |
| Non-goals | theme/dashboard/RPC/ACP/E2–E3/schema/maturity/Pi parity/wholesale vaxis |

# verification (contract track — this node)

- [x] Round-1 architecture + safety **BLOCKED** findings closed @ `a38f0ec`
- [x] Signal host / Guard-after-Agent order follow-up recorded (still not PASS)
- [x] Teardown order A11/B-S10 follow-up recorded (still not PASS)
- [ ] Independent **architecture / ownership** contract **re-review** PASS
- [ ] Independent **safety / fail-closed** contract **re-review** PASS
- [ ] `python3 scripts/lint_docs.py`
- [ ] `python3 scripts/score_docs.py --check`
- [ ] `git diff --check`
- [ ] Diff contains **only** expected docs (+ quality reports if body/score changes)
- [ ] Confirm **no** `packages/`, `src/`, `build.zig*` product changes
- [ ] C9 product acceptance remains **unchecked**
- [ ] No maturity raise; no “TUI implemented” / current-tip Linux claim

# verification (implementation track — later; blocked)

- [ ] Full matrix in [tui-minimal.md §11](../../modules/tui-minimal.md)
- [ ] Independent code review PASS
- [ ] Candidate + merged-main dual-backend Gates on that tip
- [ ] Kernel import scan green; plain/headless unchanged
- [ ] No schema/maturity inflation unless separate Gate

# non-goals

- Theme / dashboard / images / plugin platform
- RPC / ACP / editor host
- E2/E3 extension UI
- OS sandbox; multi-file edit platform
- Core or session-v1 / Trace-v1 / headless-v1 schema changes
- Maturity promotion
- Pi API or TUI parity; wholesale vaxis port
- This contract node adding packages, dependencies, or product code

# lineage (tips)

| Stage | Tip |
|-------|-----|
| Contract candidate (initial freeze) | `d01d70b7d02566f0354f976775dab020399d0df5` |
| Blocker-close follow-up | `a38f0ecde46d9f0c948f3a36dd8f46b1a7aad66f` |
| Signal-host / Guard order follow-up | `6c73e4652a737b3fead0dbd15a2c661ebe66cfda` |
| Teardown order follow-up | tip with message `docs: fix TUI teardown ordering` |
| Contract PASS record | pending re-review |
| Implementation | blocked |
| Closeout | blocked |
