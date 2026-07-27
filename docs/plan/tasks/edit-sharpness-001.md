---
id: edit-sharpness-001
scope: coding-agent/edit-sharpness (M2 / C4 first slice)
status: contract-in-progress
priority: P1
depends-on:
  - prompt-templates-001
  - h-edit-integrity-001
---

# objective

Freeze and later deliver the **smallest reliable C4 edit-sharpness first slice**
on top of the closed H2 single-file edit integrity contract:

1. **Docs-first binding contract** (this task + owning modules) with exact
   mechanism, review, commit, verification, budgets, errors, ownership, and
   fixture choices — no `hashline or equivalent` / `CLI or SDK` ambiguity.
2. **Production implementation** only after a **different independent reviewer**
   returns **PASS** on the contract track. Until then, production code is
   **BLOCKED**.

**Owner:** `zag-coding-agent` for all patch proposal/review/verification state
and concrete behavior; **thin explicit CLI adapter only** where needed for
interactive hunk accept/reject. **No** new `zag-agent-core` edit/review/lifecycle
ports. **No** new Zig package.

Binding specification: [tools-edit.md](../../modules/tools-edit.md) § C4 first
slice + [C4-edit-sharpness.md](../../phases/C4-edit-sharpness.md).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze (this docs commit) | **in progress** until independent contract review **PASS** |
| Production implementation | **BLOCKED** until that PASS |
| Tools · write/edit maturity | remains **L2** (no L3 claim or row raise) |
| Session v1 / Trace v1 / headless-v1 / `project.zig` / `--no-project` | **unchanged** |

# context

- [D-007](../../decisions/active/D-007-tool-runtime-descriptor.md) descriptor-derived risk; stateful Tool instances
- [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md) thin Core; product Tools/policy in coding-agent
- [tools-edit.md](../../modules/tools-edit.md) H2 integrity + this C4 freeze
- [permissions.md](../../modules/permissions.md) Gate order; `StdinPrompter` risk+`args_len` only
- [workspace-sandbox.md](../../modules/workspace-sandbox.md) jail + contained final symlink
- [tools-shell.md](../../modules/tools-shell.md) shell-v1 bounds (verification must not bypass)
- [tool-runtime.md](../../modules/tool-runtime.md) instance-aware Tool; `max_result_bytes` 64 KiB
- [cli-interaction.md](../../modules/cli-interaction.md) · [sdk-contract.md](../../modules/sdk-contract.md) · [headless-contract.md](../../modules/headless-contract.md)
- [session-store.md](../../modules/session-store.md) · [session-fork.md](../../modules/session-fork.md) · [trace-observability.md](../../modules/trace-observability.md)
- [h-edit-integrity-001](./h-edit-integrity-001.md) atomic same-parent commit; `edit-v1`
- Live seams (read only for this docs node; do not invent Core ports):
  - `packages/zag-coding-agent/src/runtime/edit_tools.zig` — `search_replace`/`write_file`, `max_write_bytes=512KiB`, `atomicCommit`
  - `packages/zag-coding-agent/src/runtime/fs_tools.zig` — `read_file` raw ≤64 KiB body, **no** digest/hashline today
  - `packages/zag-coding-agent/src/toolset.zig` — Phase1Storage; built-ins currently `instance == null`
  - `packages/zag-coding-agent/src/permissions.zig` — `StdinPrompter` / `formatPermissionPrompt` (risk + args_len only)
  - `packages/zag-agent-core/src/tool.zig` — gate order ToolPolicy → Jail → ShellPolicy → execute; stateful instance
  - `packages/zag-coding-agent/src/doctor.zig` — test-entry **presence-only**, not a safe command
  - `packages/zag-cli/src/cli.zig` — ask/yolo/plan/headless flags

# path

## Docs (contract track — this node)

- `docs/plan/tasks/edit-sharpness-001.md` — this task
- `docs/modules/tools-edit.md` — **binding truth** for mechanism/review/commit/verify
- `docs/phases/C4-edit-sharpness.md` — phase freeze + acceptance checkboxes
- Status truth only as needed: `docs/plan/README.md`, `docs/roadmap.md`,
  `docs/maturity.md` (L2 row **unchanged**), `docs/modules/README.md`,
  `docs/quality/evals.md`, and permissions/CLI/SDK notes when their **future**
  contract surface is frozen here

## Implementation (later node; BLOCKED)

- `packages/zag-coding-agent/src/runtime/edit_tools.zig` (or adjacent coding-agent module) — `apply_hunk` + shared commit
- `packages/zag-coding-agent/src/runtime/fs_tools.zig` — optional `include_digest` on `read_file`
- `packages/zag-coding-agent/src/toolset.zig` — register stateful `apply_hunk`
- coding-agent tests covering tools-edit § C4 fixture matrix
- `packages/zag-cli/src/cli.zig` — thin `InteractiveHunkReviewer` / `AutoAcceptHunkReviewer` wiring only
- optional SDK public types for `HunkReviewer` / `PostEditVerifier`
- **no** Core edit/review ports; **no** session/Trace/headless schema fields; **no** new package

# contract summary (binding detail lives in tools-edit)

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent` | `apply_hunk` handler; proposal bytes; `HunkReviewer` / `PostEditVerifier` ports and default product bindings; read digest extension; all soft-result vocabulary | Core ports; multi-file transaction engine; TUI platform |
| `zag-cli` | Thin interactive stdin hunk accept/reject adapter; bind AutoAccept under `--yolo`; process signals | Patch parse/apply; durable proposal store; inventing review=accept when adapter missing |
| `zag-agent-core` | Existing Tool/loop gates only | New edit/review/lifecycle ports |
| Model | Tool args only | Verify command inside write Tool; bypass permission/shell |

## 2. First-slice patch mechanism (exact)

**Chosen shape:** single-file, single-hunk **content-anchor replace** with a
**full-file SHA-256 stale precondition**, model-visible Tool name **`apply_hunk`**.

**Why not multi-hunk `apply_patch` / pure hashline first:** H2 already ships
unique-content anchors + same-parent atomic commit. The dominant failure is
**stale file** + **no user hunk gate**, not missing multi-hunk syntax. A single
hunk reuses `search_replace` matching rules, adds an explicit digest token, and
fits whole-hunk accept/reject without a TUI or multi-file rollback. Multi-hunk,
hashline line-address formats, and AST/LSP remain non-goals.

**Closed Tool JSON** (`additionalProperties: false`):

```json
{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "Workspace-relative file path (required path_field)."
    },
    "expected_sha256": {
      "type": "string",
      "description": "SHA-256 of the entire current file as raw bytes; 64 hex digits."
    },
    "old_string": {
      "type": "string",
      "description": "Exact unique byte-substring anchor (must appear once)."
    },
    "new_string": {
      "type": "string",
      "description": "Replacement bytes for that unique anchor (empty = delete)."
    }
  },
  "required": ["path", "expected_sha256", "old_string", "new_string"]
}
```

**Descriptor:** `risk=write`, `workspace=path_field:"path"`, `shell=none`,
`cancellation=none` (same class as `search_replace`).

**Stale / token semantics:**

- `expected_sha256` is the SHA-256 of the **entire target file byte contents**
  (not a line range, not a hunk hash).
- Input: exactly 64 ASCII hex digits; compare after lowercasing A–F.
- Host recomputes digest after jailed read. Mismatch → soft
  `stale_precondition`, **non-mutating**.
- Recomputed again after review and **before** opening any commit temporary
  (`stage=revalidate`). Mismatch → soft `stale_precondition`, **non-mutating**,
  no temp.

**Anchor / insert / delete / replace:**

- Exact unique substring match of `old_string` in the full file bytes (same
  family as `search_replace`).
- `old_string` empty → soft `anchor_not_found` (non-mutating).
- Zero matches → `anchor_not_found`; two or more → `ambiguous_anchor`.
- Replace: non-empty `old_string` + any `new_string`.
- Delete: `new_string` length 0.
- Insert: encode as replace of a unique existing context substring with
  `context + inserted` (no separate insert opcode in first slice).
- **No** multi-hunk array, ordering list, or overlap rules: one hunk per call.
  Concurrent external writers are detected only via the digest revalidation
  (trusted-host TOCTOU residual remains; not full compare-and-swap).

**Newline / UTF-8:**

- Match and digest are **raw byte** operations. No CRLF↔LF normalization, no
  Unicode canonicalization, no trailing-newline inventing.
- Tool descriptions continue to say “UTF-8 text”; invalid UTF-8 bytes are still
  hashed and matched exactly. Result bodies remain valid UTF-8 diagnostics
  (no raw file dump of invalid sequences in success/error first lines).

**Compatibility:**

- Existing `search_replace` and `write_file` behavior, JSON, and descriptors stay
  **byte-stable** unless a later contract explicitly and minimally changes them.
- `apply_hunk` is an **additional** preferred sharp path for existing files when
  the model holds a digest; default Tool descriptions must still prefer
  non-whole-file overwrite of large files.

### Backward-compatible read surface for digest (required)

Today’s `read_file` returns **raw bounded text only** — it does **not** supply
hashline/digest metadata. First slice freezes this exact extension:

- Optional JSON property `include_digest` (boolean). Omitted or `false` →
  **exact current** body behavior (raw content / `fs-v1` truncation).
- `true` on success: body begins with **exactly one** meta line, then content:

```text
meta: format=fs-meta-v1 sha256=<64 lowercase hex> size=<decimal full-file byte length>
<content prefix, same truncation rules as today>
```

- Digest and `size` always describe the **entire on-disk file**, even when the
  returned content is truncated to fit `tool.max_result_bytes` (64 KiB) **including**
  the meta line and any `fs-v1` incomplete marker.
- Required fields remain `["path"]` only; `include_digest` is not required.
- Jail/permission/risk unchanged (`risk=read`).
- No separate `read_file_meta` Tool in first slice (avoids tool-count churn).

## 3. Budgets and arithmetic

| Budget | Value | Notes |
|--------|------:|-------|
| Target / result file (`apply_hunk`) | **512 KiB** | Same hard max as `search_replace`/`write_file` (`max_write_bytes`) |
| `old_string` | **32 KiB** | Soft `too_large` if exceeded |
| `new_string` | **32 KiB** | Soft `too_large` if exceeded |
| `read_file` body | **64 KiB** | Unchanged `tool.max_result_bytes` |
| Review preview text | **4 KiB** | Checked; never full unbounded diff |
| Tool-result first line | ≤ `trace.cap_tool_result_body` (**500**) | Stable machine line |
| Trace tool args / body | existing caps (800 / 500) | Redact before durable serialize |

All length checks use **checked arithmetic**. Soft `too_large` for argument/file
budgets; typed `OutOfMemory` for host allocation failures **before** commit.
No unbounded diff or file content in durable Trace/session diagnostics beyond
existing redacted/capped Tool-call argument rules (same honesty as
`search_replace` today).

## 4. Hunk review (exact first slice)

**Surface:** whole **one-hunk** accept/reject only (explicit choice).

**Not** `StdinPrompter`: that intentional surface shows only
`risk` + `args_len` and **must not** be labeled or reused as hunk review
([permissions.zig](../../../packages/zag-coding-agent/src/permissions.zig)
`formatPermissionPrompt`).

**Port (coding-agent):**

```text
HunkReviewPreview { path, expected_sha256, old_len, new_len, preview_text[≤4KiB] }
HunkReviewDecision = accept | reject
HunkReviewer { ptr, reviewFn(ptr, preview) → Decision }
```

**Lifecycle (single Tool invocation; no cross-turn proposal store):**

```text
parse → (loop: ToolPolicy → Jail → execute)
  → handler jail/endpoint → read → digest check → unique anchor
  → build in-memory proposal + bounded preview
  → mandatory HunkReviewer
       reject → soft rejected; target byte-equal; no temp
       accept → revalidate digest/anchor/containment → atomicCommit → optional verify
```

**Missing reviewer = fail-closed:** soft `review_unavailable`, **never** imply
accept. Product must bind a concrete reviewer instance; absence is not yolo.

| Host mode | Permission (existing Gate) | Reviewer binding | apply_hunk |
|-----------|----------------------------|------------------|------------|
| Interactive CLI `--ask` | `StdinPrompter` (risk+args_len) | **InteractiveHunkReviewer** (CLI thin adapter: accept/reject on preview) | both gates; review mandatory after allow |
| CLI `--yolo` | auto-allow write (plan still applies) | **AutoAcceptHunkReviewer** (still a bound instance) | review “accepts”; missing instance still `review_unavailable` |
| `--plan` | non-plan writes denied | n/a when denied | no mutation |
| Headless / noninteractive / no ask callback | dangerous → deny | default **null** | permission deny and/or `review_unavailable`; never silent accept |
| SDK | host Gate / mode | host **must** inject `HunkReviewer` | null → `review_unavailable` |
| `--no-remember` / remember | lexical path remember for write only | review decisions **not** remembered in first slice | every `apply_hunk` re-reviews unless AutoAccept |

Review is **separately mandatory** from permission: permission `yes` alone never
commits an `apply_hunk`.

**Reject:** target **byte-equal** to pre-call state; **no** temp created (review
is pre-staging); no verifier call.

**Preview bounds:** ≤4 KiB text; no durable session/Trace/headless-v1 silent
persist of raw proposal/diff bytes beyond ordinary redacted Tool **arguments**
already present on the wire (do not add new Trace kinds or session fields for
diffs). Headless-v1 schema **unchanged**.

## 5. Commit transaction (exact order)

```text
1. Parse closed JSON; budget-check fields
2. Loop (unchanged): ToolPolicy → Jail → ShellPolicy(n/a) → execute
3. Handler: lexical path + file endpoint shape
4. Guard existing + mutation endpoint (contained final symlink → real target)
5. Read full target with limit 512 KiB+1 → too_large if over
6. SHA-256; compare expected_sha256 → stale_precondition (preserved)
7. Unique old_string → anchor_not_found | ambiguous_anchor
8. Build complete replacement bytes; result size ≤ 512 KiB
9. Mandatory review (above)
10. Revalidate: re-read, digest, unique anchor still holds, Guard containment
11. Preallocate success/failure bodies (H2 pattern)
12. Existing same-parent atomic helper (createFileAtomic → write → flush →
    containment recheck → replace); preserve edit-v1 cleanup/symlink truth
13. Post-commit: no hard failure of a completed mutation (H2 rule)
14. Optional PostEditVerifier (after commit only)
```

**Preserve:** contained final-symlink semantics; `temp_artifact=absent|may_remain`;
`parent_dirs` rules (`apply_hunk` does **not** create parents — missing parent →
non-mutating fault, same family as `search_replace`); post-commit no-failure of
edit success path.

**Races:** digest at steps 6 and 10; residual trusted-host TOCTOU after step 12
unchanged from H2. **No** multi-file transaction or rollback.

## 6. Post-edit project verification (exact)

**Surface:** host-owned **`PostEditVerifier` callback only** (coding-agent port on
the stateful Tool / Agent composition).

```text
PostEditVerifyResult = ok | failed | timeout | denied | unavailable
PostEditVerifier { ptr, verifyFn(ptr, path) → Result }
```

**Provenance laws:**

- A model-supplied command **must never** appear inside `apply_hunk` (or any
  write Tool) JSON to ride a write past execute permission / shell protect.
- Doctor `test_entry` is **presence-only** and is **not** a safe command; first
  slice does **not** auto-map doctor candidates to shell.
- First-slice **product default:** verifier **null** → success body
  `verification=not_configured` (commit may succeed; **not** claimed as
  project-verified success).
- SDK/CLI may inject a host callback. If a future CLI flag supplies a command
  string, that is a **separate** later contract; **not** this freeze.
- When non-null: runs **only after** successful atomic commit; must apply host
  authorization the host chose; if the host implementation shells out, it must
  use shell-policy protect and existing shell body/time caps (30s / 30 KiB
  streams / 64 KiB body family) and must not leak command text into stable
  edit diagnostics beyond shell-v1 rules.
- Missing/unavailable callback result → `verification=unavailable` on partial
  line if commit already happened; null binding stays `not_configured`.
- Cancel: cooperative cancel observed **before** starting verify; mid-verify
  preemption not claimed (Tool cancellation remains `.none`).
- Verify fail/timeout/deny: **no rollback**; stable partial truth:

```text
partial: code=verification_failed format=edit-sharp-v1 operation=apply_hunk target=modified verification=<failed|timeout|denied|unavailable> temp_artifact=absent
```

Distinguish:

| Outcome | Disk | Result class |
|---------|------|--------------|
| Commit + verification ok | modified | full `apply_hunk_success` + `verification=ok` |
| Commit + verifier null | modified | `apply_hunk_success` + `verification=not_configured` |
| Commit + verify fail | modified | **partial** `verification_failed` (edit committed; not overall verified success) |
| Review reject / stale / permission deny | preserved | soft error; not success |

## 7. State / allocator / lifetime

| Object | Owner | Lifetime |
|--------|-------|----------|
| `ApplyHunkState` (reviewer + verifier pointers) | coding-agent toolset / Agent composition | outlives every handler call (D-007 instance rule) |
| Proposal / preview bytes | handler allocator for **one** invocation | freed before return; not Session-durable |
| Reviewer / verifier instances | host or CLI adapter | outlive Tool copies sharing `instance` |
| Fork / resume | no proposal catalog | rebind from Agent options; Session v1 unchanged |
| Concurrent runs | existing single-flight `Agent.reply` | no multi-writer proposal lock in first slice |
| OOM | typed before commit; H2 post-staging allocation-free selection for commit faults | verify OOM → `verification=unavailable` after commit, not edit rollback |

## 8. Security

- Defaults: **ask + workspace jail + shell protect**.
- Missing reviewer/verifier/ports **never** allow / yolo / identity / discard /
  no-control.
- Redaction before durable diagnostics (existing Trace/session redactor).
- Induced later Tools still pass ordinary gates.
- Stable errors: no raw absolute path, temp name, or full body dump.

## 9. Error / result vocabulary

| code | Class | Mutates? |
|------|-------|----------|
| `stale_precondition` | soft | no |
| `anchor_not_found` | soft | no |
| `ambiguous_anchor` | soft | no |
| `too_large` | soft | no |
| `rejected` | soft | no |
| `review_unavailable` | soft | no |
| `invalid_arguments` | soft | no |
| `jail_deny` | soft | no |
| `permission_denied` | soft (Gate) | no |
| `edit_io_failed` `format=edit-v1` | soft | preserved (+ cleanup truth) |
| `apply_hunk_success` | soft ok | yes |
| `verification_failed` | soft **partial** | yes (already) |
| `OutOfMemory` | typed host | no commit |

First-line examples:

```text
error: code=stale_precondition format=edit-sharp-v1 operation=apply_hunk stage=precondition target=preserved temp_artifact=absent
error: code=rejected format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
error: code=review_unavailable format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
ok: code=apply_hunk_success format=edit-sharp-v1 operation=apply_hunk target=modified verification=not_configured temp_artifact=absent
partial: code=verification_failed format=edit-sharp-v1 operation=apply_hunk target=modified verification=failed temp_artifact=absent
```

No false success: committed+verify-failed is **partial**, not `apply_hunk_success`
with hidden failure. Existing `search_replace`/`write_file` strings unchanged.

## 10. Executable fixture matrix (implementation Gate)

1. Valid single-hunk success (`verification=not_configured` default).
2. Stale token pre + revalidate; non-mutate; no temp.
3. Missing / ambiguous / empty `old_string` / invalid hex digest / oversize args.
4. Insert (context replace), delete (`new_string` empty), exact newline/UTF-8 bytes.
5. Reject: byte-equal, no temp, verifier not called.
6. Ask deny; yolo AutoAccept; remember does not skip review; plan deny non-plan path.
7. Jail / symlink / retarget recheck; contained final symlink preservation.
8. Reviewer missing → `review_unavailable`; reviewer path OOM fail-closed.
9. Verifier pass / fail / timeout / denied / unavailable; post-commit
   `target=modified` truth; no rollback claim.
10. Session resume/fork: no durable proposal; schema v1 unchanged.
11. Trace/headless schemas unchanged; caps hold; redaction holds.
12. SDK public surface injects reviewer/verifier; null reviewer fails closed.
13. CLI one-shot/REPL interactive reviewer; headless default no silent accept.
14. Local failures need **no** extra provider/model call.
15. std + curl full Gates green on candidate and merged-main.

## 11. Explicit non-goals

- TUI platform / full diff pane / theme
- Multi-file transactions / rollback / partial multi-file orchestration
- AST / LSP / DAP
- Hostile external-writer CAS beyond digest precondition + revalidate
- OS sandbox / process-tree mid-flight preemption
- E2/E3 / scripts / hooks / MCP / WASM
- Core package changes; session/Trace/headless schema changes
- Maturity raise of Tools · write/edit above L2 in this task
- Auto doctor→verify command; model-supplied verify command in write Tool JSON
- Multi-hunk apply_patch syntax; pure hashline line-address format

# verification (contract track)

- Independent **contract** review by a different agent returns **PASS** (or
  fix loop) before any production implementation node.
- `python3 scripts/lint_docs.py`
- `python3 scripts/score_docs.py --check` (timestamp-only report rewrites must be
  restored to HEAD bytes)
- `/usr/bin/git diff --check`
- Docs-only commit; no `packages/**` / tests / build / schema changes

# verification (implementation track — later)

- Full §10 fixture matrix in coding-agent tests
- Dual-backend std/curl Gates; docs lint/score; independent code review PASS
- Maturity row Tools · write/edit remains L2 unless a **separate** L3 Gate is
  explicitly scheduled and closed
