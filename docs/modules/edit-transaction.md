# Edit transaction (multi-file)

> Binding spec for `edit-transaction-001`
> ([task](../plan/tasks/edit-transaction-001.md)). C4 **second** slice after
> closed `edit-sharpness-001` / `apply_hunk`: a **multi-file, all-or-nothing**
> edit transaction with per-file stale digests and one mandatory review.
> Architecture direction from [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
> item 1 and [C4](../phases/C4-edit-sharpness.md) deferred multi-file work —
> **not** Pi/Codex/Hyper format parity.

## 1. Principles

1. **One write path for later tools**: LSP/repo-map/subagent edits should land
   through the same transaction semantics, not ad-hoc `write_file` loops.
2. **All-or-nothing publish**: either every file in the transaction replaces
   successfully, or **every** target remains byte-identical to its preimage
   (no partial multi-file success in v1).
3. **Stale closed before mutate**: each file carries `expected_sha256`; any
   mismatch / missing / ambiguous anchor aborts the whole transaction with
   **zero** mutations.
4. **One review gate**: a single `HunkReviewer`-compatible preview covers the
   whole transaction; deny/cancel rejects everything.
5. **Reuse H/C4 integrity**: same-parent atomic replace, jail, ask/remember,
   redaction, and `edit-v1` / `edit-sharp-v1` vocabulary stay binding; this
   slice adds **transaction orchestration**, not a second filesystem ABI.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-coding-agent` only** | transaction parse/validate, staging plan, per-file digest/anchor, review preview assembly, ordered commit + rollback-on-failure, Tool surface | Core ports; Session/Trace schema fields; TUI widgets |
| `zag-cli` | thin bind of existing `HunkReviewer` / `PostEditVerifier` when present | transaction body parse; filesystem staging |
| `zag-agent-core` | — | any edit-transaction types/ports/state |
| `zag-tui` | — | transaction UI in this slice (diff pane deferred) |

## 3. Model-visible surface

### 3.1 Tool: `apply_transaction`

| Item | Binding |
|------|---------|
| Name | `apply_transaction` (exact) |
| Scope | **N files**, **N ≥ 1**, **N ≤ 16** (v1 hard cap) |
| Per entry | workspace-relative `path` + exactly **one** content-anchor hunk (`old_string`/`new_string`) + `expected_sha256` (full-file SHA-256 hex, same law as `apply_hunk`) |
| Budgets | per-file file/hash ≤ **512 KiB**; per-hunk old/new ≤ **32 KiB**; aggregate preview ≤ **16 KiB**; result body ≤ **64 KiB**; aggregate source bytes across entries ≤ **1 MiB** |
| Order | entries applied in **request order**; commit phase also follows that order |
| Existing tools | `apply_hunk` / `search_replace` / `write_file` **unchanged** and remain available; this Tool is additive |

Unknown top-level JSON keys → `invalid_arguments`. Missing required fields →
`invalid_arguments`. Duplicate `path` in one transaction → `invalid_arguments`
(no silent merge).

### 3.2 Why not “multi-hunk one file” first

C4 already closed single-file single-hunk + digest + review. The D-012 gap is
**cross-file atomicity**. Multi-hunk / hashline / apply_patch formats remain
deferred (same as C4 non-goals).

## 4. Execution pipeline (normative)

```text
parse + budget
  → ToolPolicy + Jail + ShellPolicy (every path)
  → load each file + digest check + unique-anchor resolve   (all non-mutating)
  → assemble transaction preview → HunkReviewer             (null → review_unavailable)
  → revalidate every digest                                   (non-mutating on fail)
  → preallocate all success/failure result bodies
  → stage complete bytes per file (same-parent temps)
  → commit replaces in order
       on any commit failure after first success:
         restore already-replaced files from retained preimages
         (best-effort software crash; see §5)
  → optional PostEditVerifier per committed path (non-ok → partial vocabulary)
```

Pre-commit failures (parse, policy, jail, stale, anchor, review deny, revalidate)
**never** open temps and **never** mutate any target.

## 5. Atomicity and restore (v1)

| Rule | Binding |
|------|---------|
| Pre-commit abort | all targets preserved; `temp_artifact=absent` |
| Commit success | all targets show new bytes; one success code |
| Mid-commit failure | restore **already replaced** files from in-memory preimages via the same atomic-replace helper; files not yet replaced stay preserved |
| Restore failure | report `transaction_restore_failed` with `target=partial`; list which paths are `restored` / `modified` / `preserved` using closed codes only — **no** raw paths in the first line beyond validated relative ids already accepted |
| Durability claim | software-crash / ordinary I/O only — **no** `fsync`/power-loss, **no** hostile concurrent writer CAS beyond digest revalidate |

v1 does **not** invent a journal file or Session-durable undo log.

## 6. Review and verification

| Concern | Binding |
|---------|---------|
| Reviewer port | Reuse `HunkReviewer` / `HunkReviewPreview` / `HunkReviewDecision` from C4 |
| Preview | Relative paths + per-file hunk previews; UTF-8-safe truncation; aggregate ≤ 16 KiB with fixed marker |
| Null reviewer | `review_unavailable` — no mutation |
| Remember / ask | Same Gate/remember law as `apply_hunk`; remember keys remain lexical request paths **per file**; transaction does not invent a new remember domain |
| PostEditVerifier | Optional; run **after** full successful commit (or after restore attempt on failure — never on pure pre-commit abort); non-ok uses partial vocabulary without claiming full success |

## 7. Result vocabulary (`format=edit-txn-v1`)

| code | Mutates |
|------|---------|
| `invalid_arguments` / `too_large` / `review_unavailable` / `rejected` | no |
| `stale_precondition` / `anchor_not_found` / `ambiguous_anchor` / `not_found` | no |
| `jail_deny` / policy deny (existing codes) | no |
| `edit_io_failed` (staging/commit; `operation=apply_transaction`) | preserved (+ cleanup) when no successful replace yet |
| `transaction_restore_failed` | **partial** — some paths may remain modified |
| `apply_transaction_success` | yes (all paths); `verification=ok\|not_configured\|failed` |

First line: no raw OS errors, temp names, absolute paths, or file bodies; fits
trace Tool-result cap. Closed diagnostic atoms only.

## 8. Schemas and non-interference

| Contract | Rule |
|----------|------|
| Session v1 / Trace v1 / headless-v1 | **unchanged** — no Theme/transaction fields |
| Core / D-011 | **no** new ports |
| Maturity | Tools · write/edit stays **L2** unless a separate L3 Gate says otherwise |
| TUI / Theme / vaxis | **orthogonal** — this slice must not block or require them |
| `apply_hunk` | byte-behavioral compatibility retained |

## 9. Fixtures (implementation track)

| # | Class | Expect |
|---|-------|--------|
| 1 | Happy 2-file | both digests ok → review allow → both mutated; success |
| 2 | Stale second file | zero mutations; `stale_precondition` |
| 3 | Review deny | zero mutations; `rejected` |
| 4 | Null reviewer | `review_unavailable`; zero mutations |
| 5 | Mid-commit restore | inject replace fail after file1; file1 restored; file2 preserved |
| 6 | Duplicate path | `invalid_arguments` |
| 7 | N=17 | `too_large` / budget reject |
| 8 | Jail escape path | deny; zero mutations |
| 9 | Ask/remember | lexical per-file; jail still enforced |
| 10 | Schema | Session/Trace/headless unchanged |
| 11 | Ownership | no Core transaction symbols; sources under coding-agent (+ thin CLI bind) |
| 12 | Regression | `apply_hunk` matrix still green |

## 10. Non-goals

- Multi-hunk / hashline / Codex `apply_patch` format parity
- Power-loss durable journal / `fsync` claims
- Automatic project-script verification CLI
- TUI multi-file diff pane
- Core ownership or schema v2
- Maturity raise
- Blocking on TUI vaxis / Theme landing

## Related

- [task edit-transaction-001](../plan/tasks/edit-transaction-001.md)
- [tools-edit](./tools-edit.md) · [edit-sharpness-001](../plan/tasks/edit-sharpness-001.md)
- [C4-edit-sharpness](../phases/C4-edit-sharpness.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
