---
id: edit-transaction-001
scope: tools/edit-transaction (C4 second slice; D-012 item 1)
status: ready
priority: P1
depends-on:
  - edit-sharpness-001
---

# objective

Freeze the **multi-file edit transaction** binding contract, then (in a later
Goal) implement additive Tool `apply_transaction` (N≤16, one hunk + full-file
SHA-256 per path), **stage-all-then-commit** all-or-nothing publish with
mid-commit restore from retained preimages, one mandatory `HunkReviewer` gate,
product multi-path jail, and closed `edit-txn-v1` vocabulary — without changing
Session v1 / Trace v1 / headless-v1, without Core ports, and without waiting on
TUI vaxis/Theme.

**Binding specification:** [edit-transaction.md](../../modules/edit-transaction.md)

**Contract freeze:** dual reviews **PASS**, zero blockers —
[architecture/ownership](../reviews/edit-transaction-001-01-architecture.md) +
[safety/atomicity/restore](../reviews/edit-transaction-001-02-safety.md).
Task **`status: ready`** means a later **fresh Goal** may select implementation.
Contract PASS alone does **not** ship product code.

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — dual reviews zero blockers; binding hardened (B1–B10) |
| Task frontmatter | **`ready`** — eligible for independent implementation Goal |
| Implementation | **not started**; not authorized by this tip alone |
| Maturity | **unchanged** — Tools · write/edit stays L2 unless a separate L3 Gate |
| edit-sharpness-001 / `apply_hunk` | **unchanged** behavioral contract |
| TUI vaxis / Theme | **orthogonal** — must not block or claim |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** by contract law |

# context

- C4 first slice closed at `7be5151` (`apply_hunk` + digest + review + verifier).
- Draft tip `cd55b2d` authored the first binding; this tip closes review blockers
  B1–B10 and records dual PASS → `ready`.
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md) item 1.
- Parallel TUI work (vaxis / Theme) must not be coupled to this node.

# path

| Path | Role |
|------|------|
| `docs/modules/edit-transaction.md` | **binding truth** |
| `docs/plan/tasks/edit-transaction-001.md` | this task (`status: ready`) |
| `docs/plan/reviews/edit-transaction-001-01-architecture.md` | arch PASS |
| `docs/plan/reviews/edit-transaction-001-02-safety.md` | safety PASS |
| Future impl (after fresh Goal) | `packages/zag-coding-agent/src/runtime/**` (+ thin CLI reviewer bind if needed) |
| Forbidden until impl Goal | product/build/CI/chapter code; Core; zag-tui |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Tool | additive `apply_transaction`; `entries` N∈[1,16]; per entry path+hunk+digest |
| Jail | **product jails every entry**; Core single `path_field` not authoritative |
| Ask | one Gate.ask with full args; remember never skips hunk review |
| Atomicity | stage-all-then-commit; mid-commit restore from preimages; only `transaction_restore_failed` may leave partial disk |
| Budgets | 512 KiB/file; 8 MiB aggregate preimages; preview 16 KiB |
| Review | one `HunkReviewer` / one `preview_text` |
| Verifier | only after full successful commit |
| Owner | **zag-coding-agent only**; no Core ports; no Session/Trace fields |
| Orthogonal | TUI vaxis / Theme / supervisor / LSP / rpc-v1 **out of scope** |

# verification (contract track)

- [x] Binding module authored + B1–B10 closed
- [x] Task frontmatter `status: ready`
- [x] Independent **architecture/ownership** review PASS (zero blockers)
- [x] Independent **safety/atomicity/restore** review PASS (zero blockers)
- [ ] Docs lint / score / `git diff --check` on contract docs path (this tip)
- [x] Scope: docs only on this tip
- [x] No maturity raise; no remote Gate claim; no TUI coupling
- [ ] Implementation Goal / product code (later)

# verification (implementation track — later)

See [edit-transaction.md §10](../../modules/edit-transaction.md). develop ≠ verify;
task Gate + merged-main Gate; no maturity raise by default.

# non-goals

- Product implementation on this tip
- Multi-hunk / hashline / apply_patch parity
- Power-loss journal / fsync claims
- TUI diff pane; Theme; vaxis
- Process supervisor / LSP / rpc-v1 packaging
- Core ownership; schema v2; maturity raise

# related

- [edit-transaction.md](../../modules/edit-transaction.md)
- [reviews 01 architecture](../reviews/edit-transaction-001-01-architecture.md) · [02 safety](../reviews/edit-transaction-001-02-safety.md)
- [edit-sharpness-001](./edit-sharpness-001.md) · [tools-edit.md](../../modules/tools-edit.md)
- [C4-edit-sharpness](../../phases/C4-edit-sharpness.md)
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
