# Edit transaction (multi-file)

> Binding spec for `edit-transaction-001`
> ([task](../plan/tasks/edit-transaction-001.md)). C4 **second** slice after
> closed `edit-sharpness-001` / `apply_hunk`: a **multi-file, all-or-nothing**
> edit transaction with per-file stale digests and one mandatory review.
> Architecture direction from [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
> item 1 and [C4](../phases/C4-edit-sharpness.md) deferred multi-file work —
> **not** Pi/Codex/Hyper format parity.
>
> **Contract freeze PASS:** dual architecture + safety reviews (**zero blockers**).
> **Implementation:** **done** @ `e086df8` (`apply_transaction` in
> `zag-coding-agent`); §10 fixtures green; Tools · write/edit stays **L2**.
> Next D-012 process node: [process-supervisor](./process-supervisor.md).

## 1. Principles

1. **One write path for later tools**: LSP/repo-map/subagent edits should land
   through the same transaction semantics, not ad-hoc `write_file` loops.
2. **All-or-nothing intent**: v1 attempts to publish every file or leave every
   target byte-identical to its preimage. The **only** permitted partial disk
   state is `transaction_restore_failed` after a mid-commit restore attempt
   fails (§5) — never a silent half-apply.
3. **Stale closed before mutate**: each file carries `expected_sha256`; any
   mismatch / missing / ambiguous anchor aborts the whole transaction with
   **zero** mutations.
4. **One review gate**: a single `HunkReviewer` callback covers the whole
   transaction; deny/cancel rejects everything.
5. **Reuse H/C4 integrity**: same-parent atomic replace, jail Guard APIs,
   ask/remember, redaction, and edit-v1 cleanup truth stay binding; this slice
   adds **transaction orchestration**, not a second filesystem ABI.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-coding-agent` only** | Tool `apply_transaction`; parse/validate; **jail every entry** via existing Guard; digest/anchor; preview assembly; preimage retention; stage+commit+restore; result vocabulary | Core ports; Session/Trace schema fields; TUI widgets |
| `zag-cli` | Reuse existing thin `HunkReviewer` / `PostEditVerifier` bind (same precedence as `apply_hunk`) | transaction body parse; filesystem staging; multi-path jail |
| `zag-agent-core` | Existing Tool/loop only | any edit-transaction types/ports/state |
| `zag-tui` | — | transaction UI in this slice |

## 3. Model-visible surface

### 3.1 Tool: `apply_transaction`

Closed JSON (`additionalProperties: false`):

```json
{
  "type": "object",
  "properties": {
    "entries": {
      "type": "array",
      "minItems": 1,
      "maxItems": 16,
      "items": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "expected_sha256": { "type": "string" },
          "old_string": { "type": "string" },
          "new_string": { "type": "string" }
        },
        "required": ["path", "expected_sha256", "old_string", "new_string"],
        "additionalProperties": false
      }
    }
  },
  "required": ["entries"],
  "additionalProperties": false
}
```

| Item | Binding |
|------|---------|
| Name | `apply_transaction` (exact) |
| N | `entries.len` ∈ **[1, 16]** |
| Per entry | workspace-relative `path` + one content-anchor hunk + `expected_sha256` (64 ASCII hex; compare lowercased — same law as `apply_hunk`) |
| Duplicate `path` | `invalid_arguments` (no silent merge) |
| Parents | **never** create (`parent_dirs=unchanged`) |
| Bytes | raw match/digest; no CRLF/Unicode normalize |
| Existing tools | `apply_hunk` / `search_replace` / `write_file` **unchanged**; this Tool is additive (N=1 allowed; does not deprecate `apply_hunk`) |

### 3.2 Descriptor and Core seams (B1)

| Field | Binding |
|-------|---------|
| `risk` | `write` |
| `shell` | `none` (ShellPolicy no-op) |
| `cancellation` | `none` |
| `workspace.path_field` | **omit / unused for authoritative multi-path jail** |

**Multi-path jail (normative):** the coding-agent handler **MUST**
realpath-contain **every** `entries[i].path` under the workspace Guard **before**
any digest load or temp create. Failure on any entry → `jail_deny` (or existing
jail vocabulary), **zero** mutations, no temps. Core single-`path_field` jail is
**not** sufficient and **must not** be treated as covering the transaction.

Loop order remains ToolPolicy → (optional Core path probe if packaging requires
one) → ShellPolicy → execute; product jail of all entries runs at the start of
execute (and may run again on revalidate paths as needed).

### 3.3 Permission ask / remember (B2)

| Rule | Binding |
|------|---------|
| Gate.ask | **once** per Tool invocation with the full `entries` args (not N asks) |
| Hunk review | **never** skipped by remember (same as `apply_hunk` B5) |
| Remember keys | no new remember domain; if product remember is consulted for write risk, it remains lexical and **cannot** authorize escape from jail or skip review |
| Plan/deny | plan or permission deny → no review path; zero mutations |

### 3.4 Why not “multi-hunk one file” first

C4 closed single-file single-hunk + digest + review. The D-012 gap is
**cross-file atomicity**. Multi-hunk / hashline / apply_patch formats remain
deferred.

## 4. Budgets (checked arithmetic)

| Item | Cap |
|------|----:|
| Per-file read / hash / retained preimage | **512 KiB** |
| `old_string` / `new_string` each | **32 KiB** |
| Aggregate retained preimages (all entries) | **8 MiB** (= 16 × 512 KiB) |
| Aggregate `old_string`+`new_string` source bytes | **1 MiB** |
| Review `preview_text` for this Tool | **16 KiB** (UTF-8 lossy; truncate + `...[preview_truncated]`) |
| Tool-result first line | ≤ trace Tool-result cap (500) |
| Result body | **64 KiB** |

Over budget → soft `too_large` (or `invalid_arguments` for schema shape); **typed
OOM only pre-commit**. **No typed OOM after any successful replace** (extend C4
B1 to the transaction: preallocate reachable post-commit / restore first-lines
before opening temps).

## 5. Execution pipeline (normative)

```text
parse + schema + budgets
  → ToolPolicy (+ permission ask once)
  → product-jail EVERY entry
  → load each file + digest check + unique-anchor resolve   (retain preimages; non-mutating)
  → assemble one preview_text → HunkReviewer               (null → review_unavailable)
  → revalidate every digest                                  (non-mutating on fail)
  → preallocate all reachable result first-lines (success / edit_io / restore_failed)
  → stage complete new bytes for ALL entries (same-parent temps; targets untouched)
  → commit replaces in request order
       on replace failure at index k:
         restore entries[0..k) from retained preimages via atomic-replace helper
         cleanup temps for all entries
  → on full commit success: optional PostEditVerifier per path
```

Pre-commit failures (parse, policy, jail, stale, anchor, review deny, revalidate,
preview/preallocate OOM) **never** open temps and **never** mutate any target.

### 5.1 Stage-all-then-commit (B5)

Staging creates temps for **all** entries before the first `replace`. Targets
remain byte-identical until the commit loop starts. This minimizes the restore
window versus stage-one-commit-one.

## 6. Atomicity and restore (v1)

| Rule | Binding |
|------|---------|
| Pre-commit abort | all targets preserved; `temp_artifact=absent` |
| Commit success | all targets show new bytes; `apply_transaction_success` |
| Mid-commit failure | restore **already replaced** entries `[0..k)` from in-memory preimages via the same atomic-replace helper; not-yet-replaced entries stay preserved; cleanup all temps |
| Restore success after mid-commit fail | report `edit_io_failed` `operation=apply_transaction` with targets **preserved** (restored + never-touched); not `apply_transaction_success` |
| Restore failure | `transaction_restore_failed` `target=partial`; closed status atoms per entry index (`restored` / `modified` / `preserved`) — **no** absolute paths, temp names, OS errors, or file bodies on the first line |
| Durability | software-crash / ordinary I/O only — **no** `fsync`/power-loss; **no** hostile concurrent-writer CAS beyond digest revalidate |

v1 does **not** invent a journal file or Session-durable undo log.

## 7. Review and verification (B3 / B9)

| Concern | Binding |
|---------|---------|
| Reviewer port | Reuse `HunkReviewer` / `HunkReviewDecision` from C4 (**infallible** `accept`/`reject`) |
| Preview | Single `preview_text` ≤ **16 KiB**: workspace-relative paths + per-entry hunk summaries; UTF-8-safe; fixed truncation marker. No durable persist of preview in Session/Trace/headless |
| Preview path display | relative only (same safety as `apply_hunk`) |
| Null reviewer | `review_unavailable` — no mutation |
| Interactive EOF/read | **reject** (same as `apply_hunk`) |
| Bind precedence | identical first-match ladder as `apply_hunk` (plan/deny → yolo AutoAccept → interactive → null) |
| PostEditVerifier | Optional; run **only after full successful commit**. **Not** run on pre-commit abort. **Not** run on mid-commit failure even if restore succeeds. On `transaction_restore_failed`, verifier is **not** consulted (disk already partial) |

## 8. Result vocabulary (`format=edit-txn-v1`)

| code | Mutates |
|------|---------|
| `invalid_arguments` / `too_large` / `review_unavailable` / `rejected` | no |
| `stale_precondition` / `anchor_not_found` / `ambiguous_anchor` / `not_found` | no |
| `jail_deny` / policy deny (existing codes) | no |
| `edit_io_failed` `operation=apply_transaction` | no successful replace remaining (pre-replace fail, or mid-commit + restore ok) |
| `transaction_restore_failed` | **partial** — some paths may remain modified |
| `apply_transaction_success` | yes (all paths); `verification=ok\|not_configured\|failed` |

When a pre-commit stale/anchor failure is on entry `i`, the first line **may**
include `entry=<i>` (decimal, 0-based) as a closed atom — never the raw path
string on that line (path may appear only inside already-redacted / relative
preview surfaces, not as an absolute leak).

First line: no raw OS errors, temp names, absolute paths, or file bodies; fits
trace Tool-result cap.

## 9. Schemas and non-interference

| Contract | Rule |
|----------|------|
| Session v1 / Trace v1 / headless-v1 | **unchanged** |
| Core / D-011 | **no** new ports |
| Maturity | Tools · write/edit stays **L2** unless a separate L3 Gate says otherwise |
| TUI / Theme / vaxis | **orthogonal** |
| `apply_hunk` | byte-behavioral compatibility retained |

## 10. Fixtures (implementation track)

| # | Class | Expect |
|---|-------|--------|
| 1 | Happy 2-file | digests ok → review allow → both mutated; success |
| 2 | Stale second file | zero mutations; `stale_precondition` (+ optional `entry=1`) |
| 3 | Review deny | zero mutations; `rejected` |
| 4 | Null reviewer | `review_unavailable`; zero mutations |
| 5 | Mid-commit restore ok | fail replace after file0; file0 restored; file1 preserved; `edit_io_failed` |
| 6 | Mid-commit restore fail | inject restore fail; `transaction_restore_failed`; partial atoms |
| 7 | Duplicate path | `invalid_arguments` |
| 8 | N=17 | `too_large` / schema reject |
| 9 | Second path jail escape | `jail_deny`; zero mutations (Core single-path probe must not be sole check) |
| 10 | Ask once | one Gate.ask with full entries; remember never skips review |
| 11 | Schema | Session/Trace/headless unchanged |
| 12 | Ownership | no Core transaction symbols; sources under coding-agent (+ thin CLI bind) |
| 13 | Regression | `apply_hunk` matrix still green |
| 14 | Preimage budget | aggregate >8 MiB rejected pre-commit |

## 11. Non-goals

- Multi-hunk / hashline / Codex `apply_patch` format parity
- Power-loss durable journal / `fsync` claims
- Automatic project-script verification CLI
- TUI multi-file diff pane
- Core ownership or schema v2
- Maturity raise
- Blocking on TUI vaxis / Theme landing
- Expanding Core to native multi-`path_field` (product jail is the v1 law)

## 12. Contract-review disposition

| ID | Finding | Disposition |
|----|---------|-------------|
| B1 | Core single `path_field` insufficient for N paths | **closed** — §3.2 product jails every entry |
| B2 | Ask/remember vs N files / review skip | **closed** — §3.3 one ask; review never skipped by remember |
| B3 | `HunkReviewer` single-hunk preview shape | **closed** — §7 one `preview_text` ≤16 KiB |
| B4 | Preimage RAM unbounded | **closed** — §4 aggregate ≤8 MiB |
| B5 | Ambiguous stage vs commit interleaving | **closed** — §5.1 stage-all-then-commit |
| B6 | Principle “all identical” vs restore_failed | **closed** — §1.2 + §6 explicit partial hatch |
| B7 | Missing exact JSON schema | **closed** — §3.1 |
| B8 | Descriptor fields unspecified | **closed** — §3.2 |
| B9 | Verifier on failure paths | **closed** — §7 verifier only after full success |
| B10 | Which entry failed diagnostics | **closed** — §8 optional `entry=<i>` atom |

## Related

- [task edit-transaction-001](../plan/tasks/edit-transaction-001.md)
- [tools-edit](./tools-edit.md) · [edit-sharpness-001](../plan/tasks/edit-sharpness-001.md)
- [C4-edit-sharpness](../phases/C4-edit-sharpness.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
