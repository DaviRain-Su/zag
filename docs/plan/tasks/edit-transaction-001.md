---
id: edit-transaction-001
scope: tools/edit-transaction (C4 second slice; D-012 item 1)
status: done
priority: P1
depends-on:
  - edit-sharpness-001
---

# objective

Deliver additive Tool `apply_transaction` (N≤16, one hunk + full-file SHA-256
per path), **stage-all-then-commit** all-or-nothing publish with mid-commit
restore from retained preimages, one mandatory `HunkReviewer` gate, product
multi-path jail, and closed `edit-txn-v1` vocabulary — without changing Session
v1 / Trace v1 / headless-v1, without Core ports, and without waiting on TUI
vaxis/Theme.

**Binding specification:** [edit-transaction.md](../../modules/edit-transaction.md)

**Contract freeze:** dual reviews **PASS**, zero blockers —
[architecture/ownership](../reviews/edit-transaction-001-01-architecture.md) +
[safety/atomicity/restore](../reviews/edit-transaction-001-02-safety.md).

**Implementation:** landed at `e086df8` (feat: apply_transaction); fixture
matrix §10.1–10.10 + §10.14 extended on this closeout tip; coding-agent package
Gate **417/417** green (local Linux). Tools · write/edit remains **L2** (no L3
claim or row raise). **No push**; **no fresh remote dual-backend Gate** claimed
for this tip.

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — dual reviews zero blockers; binding B1–B10 |
| Task frontmatter | **`done`** |
| Implementation | **done** @ `e086df8` (+ fixture polish on closeout tip) |
| Local package Gate | coding-agent **417/417** (std backend local Linux) |
| Maturity | **unchanged** — Tools · write/edit stays **L2** |
| edit-sharpness-001 / `apply_hunk` | **unchanged** behavioral contract |
| TUI vaxis / Theme | **orthogonal** |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** |

# context

- C4 first slice closed at `7be5151` (`apply_hunk` + digest + review + verifier).
- Contract tip lineage: `cd55b2d` → dual PASS → `ready` → impl `e086df8` → docs closeout.
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md) item 1.
- Next D-012 node: [process-supervisor-001](./process-supervisor-001.md) (contract draft).

# path

| Path | Role |
|------|------|
| `docs/modules/edit-transaction.md` | **binding truth** |
| `docs/plan/tasks/edit-transaction-001.md` | this task (`status: done`) |
| `docs/plan/reviews/edit-transaction-001-01-architecture.md` | arch PASS |
| `docs/plan/reviews/edit-transaction-001-02-safety.md` | safety PASS |
| `packages/zag-coding-agent/src/runtime/edit_tools.zig` | `apply_transaction` + §10 fixtures |
| `packages/zag-coding-agent/src/toolset.zig` | default toolset entry (no Core path_field) |
| CLI | reuses existing thin `HunkReviewer` / `PostEditVerifier` bind |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Tool | additive `apply_transaction`; `entries` N∈[1,16]; per entry path+hunk+digest |
| Jail | **product jails every entry**; Core single `path_field` not authoritative |
| Ask | one Gate.ask with full args; remember never skips hunk review |
| Atomicity | stage-all-then-commit; mid-commit restore from preimages; only `transaction_restore_failed` may leave partial disk |
| Budgets | 512 KiB/file; 8 MiB aggregate preimages; preview 16 KiB; old/new ≤32 KiB each |
| Review | one `HunkReviewer` / one `preview_text` |
| Verifier | only after full successful commit |
| Owner | **zag-coding-agent only**; no Core ports; no Session/Trace fields |
| Orthogonal | TUI vaxis / Theme / supervisor / LSP / rpc-v1 **out of scope** |

# verification (contract track)

- [x] Binding module authored + B1–B10 closed
- [x] Independent **architecture/ownership** review PASS
- [x] Independent **safety/atomicity/restore** review PASS
- [x] No maturity raise; no remote Gate claim; no TUI coupling

# verification (implementation track)

See [edit-transaction.md §10](../../modules/edit-transaction.md).

| # | Class | Evidence |
|---|-------|----------|
| 1 | Happy 2-file | `edit-txn §10.1` |
| 2 | Stale second file | `edit-txn §10.2` |
| 3 | Review deny | `edit-txn §10.3` |
| 4 | Null reviewer | `edit-txn §10.4` |
| 5 | Mid-commit restore ok | `edit-txn §10.5` |
| 6 | Mid-commit restore fail | `edit-txn §10.6` |
| 7 | Duplicate path | `edit-txn §10.7` |
| 8 | N=17 | `edit-txn §10.8` |
| 9 | Second path jail escape | `edit-txn §10.9` |
| 10 | One review (N files) | `edit-txn §10.10` (+ Gate.ask once is loop-level design) |
| 11–13 | Schema / ownership / apply_hunk regression | no schema fields; coding-agent-only; existing apply_hunk matrix green in same package run |
| 14 | Budget too_large | `edit-txn §10.14` (per-entry 32 KiB string; aggregate caps structural under N×per-entry) |

- [x] coding-agent package tests **417/417** local Linux
- [ ] Full monorepo `zig build test` dual-backend / remote Gate (not claimed this tip)
- [x] Maturity: Tools · write/edit **L2** only

# non-goals

- Multi-hunk / hashline / apply_patch parity
- Power-loss journal / fsync claims
- TUI diff pane; Theme; vaxis
- Process supervisor / LSP / rpc-v1 packaging
- Core ownership; schema v2; maturity raise

# related

- [edit-transaction.md](../../modules/edit-transaction.md)
- [reviews 01 architecture](../reviews/edit-transaction-001-01-architecture.md) · [02 safety](../reviews/edit-transaction-001-02-safety.md)
- [edit-sharpness-001](./edit-sharpness-001.md) · [tools-edit.md](../../modules/tools-edit.md)
- [process-supervisor-001](./process-supervisor-001.md) (next D-012)
- [C4-edit-sharpness](../../phases/C4-edit-sharpness.md)
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
