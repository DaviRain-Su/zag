---
id: edit-transaction-001
scope: tools/edit-transaction (C4 second slice; D-012 item 1)
status: contract-draft
priority: P1
depends-on:
  - edit-sharpness-001
---

# objective

Freeze and later implement the **multi-file edit transaction** slice: additive
Tool `apply_transaction` (N≤16 files, one content-anchor hunk + full-file
SHA-256 per path), **all-or-nothing** publish with mid-commit restore from
retained preimages, one mandatory `HunkReviewer` gate over the whole
transaction, and closed `edit-txn-v1` result vocabulary — without changing
Session v1 / Trace v1 / headless-v1, without Core ports, and without waiting on
TUI vaxis/Theme.

**Binding specification:** [edit-transaction.md](../../modules/edit-transaction.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent architecture + safety re-reviews |
| Implementation | not started |
| Maturity | **unchanged** — Tools · write/edit stays L2 unless a separate L3 Gate |
| edit-sharpness-001 / `apply_hunk` | **unchanged** behavioral contract |
| TUI vaxis / Theme | **orthogonal** — must not block or claim |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** by contract law |

# context

- C4 first slice closed at `7be5151` (`apply_hunk` + digest + review + verifier).
- [tools-edit.md](../../modules/tools-edit.md) explicitly defers “multi-file
  atomic/partial-success policy” beyond the first slice.
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
  lists multi-file edit transactions as roadmap item 1 (before supervisor/LSP).
- Analysis order: [2026-08-06 local agent analysis](../analysis/2026-08-06-pi-omp-hyper-local-agent-analysis.md).
- Parallel TUI work (vaxis backend / Theme) must not be coupled to this node.

# path

| Path | Role |
|------|------|
| `docs/modules/edit-transaction.md` | **binding truth** |
| `docs/plan/tasks/edit-transaction-001.md` | this task |
| `docs/modules/tools-edit.md` · `docs/phases/C4-edit-sharpness.md` | cross-link only on contract tip |
| Future impl (after dual contract PASS + fresh Goal) | `packages/zag-coding-agent/src/runtime/**` (+ thin CLI reviewer bind if needed) |
| Forbidden on contract tip | product/build/CI/chapter code; Core; zag-tui |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Tool | additive `apply_transaction`; N∈[1,16]; per file: path + one hunk + `expected_sha256` |
| Atomicity | all-or-nothing publish; mid-commit failure restores already-replaced files from retained preimages |
| Stale | any digest/anchor failure aborts with **zero** mutations |
| Review | one `HunkReviewer` preview for the whole txn; null → `review_unavailable` |
| Integrity | reuse H/C4 same-parent atomic replace, jail, ask/remember, redaction |
| Owner | **zag-coding-agent only**; no Core ports; no Session/Trace fields |
| Format | `edit-txn-v1` closed codes (see binding §7) |
| Orthogonal | TUI vaxis / Theme / supervisor / LSP / rpc-v1 **out of scope** |

# verification (contract track)

- [ ] Binding module authored
- [ ] Task frontmatter (`status: contract-draft` → `ready` after dual PASS)
- [ ] Independent **architecture/ownership** re-review PASS (zero blockers)
- [ ] Independent **safety/atomicity/restore** re-review PASS (zero blockers)
- [ ] Docs lint / score / `git diff --check` on contract docs path
- [ ] Scope: docs only on contract tip
- [ ] No maturity raise; no remote Gate claim; no TUI coupling

# verification (implementation track — later)

See [edit-transaction.md §9](../../modules/edit-transaction.md). Summary: happy
2-file, stale abort, review deny, null reviewer, mid-commit restore, duplicate
path, N=17 budget, jail, ask/remember, schema unchanged, ownership scan,
`apply_hunk` regression. develop ≠ verify; task Gate + merged-main Gate; no
maturity raise by default.

# non-goals

- Multi-hunk / hashline / apply_patch parity
- Power-loss journal / fsync claims
- TUI diff pane; Theme; vaxis
- Process supervisor / LSP / rpc-v1 packaging
- Core ownership; schema v2; maturity raise

# related

- [edit-transaction.md](../../modules/edit-transaction.md)
- [edit-sharpness-001](./edit-sharpness-001.md) · [tools-edit.md](../../modules/tools-edit.md)
- [C4-edit-sharpness](../../phases/C4-edit-sharpness.md)
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
