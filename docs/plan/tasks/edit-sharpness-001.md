---
id: edit-sharpness-001
scope: coding-agent/edit-sharpness (M2 / C4 first slice)
status: in-progress # contract PASS; implementation not started
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
2. **Production implementation** only under the frozen contract in a **later
   separately dispatched** implementation node. **No product code landed** in
   this contract node.

**Owner:** `zag-coding-agent` for all patch proposal/review/verification state
and concrete behavior; **thin explicit CLI adapter only** where needed for
interactive hunk accept/reject. **No** new `zag-agent-core` edit/review/lifecycle
ports. **No** new Zig package.

Binding specification: [tools-edit.md](../../modules/tools-edit.md) § C4 first
slice + [C4-edit-sharpness.md](../../phases/C4-edit-sharpness.md).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze | **PASS** at candidate tip `07b8dab2158d100642abf5bd61dbc64366f1aba4` after B1–B8: independent architecture/API **PASS**, independent safety/transaction **PASS**, final adjudication **PASS**, zero blockers |
| Overall product task | **`in-progress` — contract PASS; implementation not started** |
| Production implementation | **not started** — contract PASS **authorizes only** a later separately dispatched implementation Goal/node under this freeze; no code landed here; not preselected as done |
| Tools · write/edit maturity | remains **L2** (no L3 claim or row raise; no current-tip Linux claim) |
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
  - `packages/zag-agent-core/src/tool.zig` — gate order **ToolPolicy → Jail → ShellPolicy → execute**; stateful instance
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

## Implementation (later node; not started)

- `packages/zag-coding-agent/src/runtime/edit_tools.zig` (or adjacent coding-agent module) — `apply_hunk` + shared commit
- `packages/zag-coding-agent/src/runtime/fs_tools.zig` — optional `include_digest` on `read_file`
- `packages/zag-coding-agent/src/toolset.zig` / `agent.zig` — stateful default `apply_hunk` + `Agent.Options` ports
- `packages/zag-coding-agent/src/root.zig` — public re-exports listed in §7
- coding-agent tests covering §10 fixture matrix
- `packages/zag-cli/src/cli.zig` — thin Interactive/AutoAccept bind per §4 precedence + interactive protocol §4.1
- **no** Core edit/review ports; **no** session/Trace/headless schema fields; **no** new package

# contract summary (binding detail lives in tools-edit)

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent` | `apply_hunk` handler; proposal bytes; `HunkReviewer` / `PostEditVerifier` ports; default `ApplyHunkState`; digest `read_file`; soft-result vocabulary; public root re-exports | Core ports; multi-file transaction engine; TUI platform |
| `zag-cli` | Thin bind of Interactive/AutoAccept per §4 first-match rule; interactive stderr protocol; process signals | Patch parse/apply; durable proposal store; inventing accept when adapter missing |
| `zag-agent-core` | Existing Tool/loop only (**ToolPolicy → Jail → ShellPolicy → execute**) | New edit/review/lifecycle ports |
| Model | Tool args only | Verify command inside write Tool; bypass permission/shell |

## 2. First-slice patch mechanism (exact)

**Chosen shape:** single-file, single-hunk **content-anchor replace** with a
**full-file SHA-256 stale precondition**, model-visible Tool name **`apply_hunk`**.

**Why not multi-hunk `apply_patch` / pure hashline first:** H2 already ships
unique-content anchors + same-parent atomic commit. The dominant failure is
**stale file** + **no user hunk gate**. Multi-hunk, hashline line-address formats,
and AST/LSP remain non-goals.

**Closed Tool JSON** (`additionalProperties: false`):

```json
{
  "type": "object",
  "properties": {
    "path": {
      "type": "string",
      "description": "File path relative to the working directory (required path_field)."
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
`cancellation=none` (same class as `search_replace`). Loop still runs full
**ToolPolicy → Jail → ShellPolicy → execute** with ShellPolicy a no-op for
`shell=none`.

**`expected_sha256` parse vs stale:**

- **Parse (before any digest compare):** must be exactly 64 ASCII hex digits
  (`0-9A-Fa-f`). Wrong length or non-hex charset → soft `invalid_arguments`,
  non-mutating. (Stale is **not** used for parse failures.)
- **Compare:** after lowercasing A–F; SHA-256 of the **entire** target file
  raw bytes (not a line range, not a hunk hash).
- Host recomputes after jailed read. Digest mismatch → soft
  `stale_precondition` with `stage=precondition`, **non-mutating**.
- After review, before any commit temporary: recompute again. Mismatch → soft
  `stale_precondition` with **`stage=revalidate`**, **non-mutating**, no temp:

```text
error: code=stale_precondition format=edit-sharp-v1 operation=apply_hunk stage=revalidate target=preserved temp_artifact=absent
```

**Anchor / insert / delete / replace:**

- Exact unique substring match of `old_string` in full file bytes (same family as
  `search_replace`).
- `old_string` empty → soft `anchor_not_found` (non-mutating).
- Zero matches → `anchor_not_found`; two or more → `ambiguous_anchor`.
- Replace: non-empty `old_string` + any `new_string`. Delete: empty `new_string`.
- Insert: replace unique context with `context + inserted` (no separate opcode).
- **No** multi-hunk array. Concurrent external writers only via digest revalidate
  (trusted-host TOCTOU residual; not full CAS).

**Newline / UTF-8:** raw-byte match and digest; no CRLF↔LF normalization; no
Unicode canonicalization. Invalid UTF-8 still hashed/matched exactly. Stable
result first lines remain valid UTF-8 diagnostics (no raw invalid dump).

**Missing target (exact):** after lexical/endpoint checks, if the path does not
resolve to an existing regular file strictly below Guard root (ordinary absence,
not jail escape): soft

```text
error: code=not_found format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
```

Escaping/dangling/looping/unresolvable → existing `jail_deny` (path-free body).
Directory/non-file endpoints → existing invalid-endpoint / `invalid_arguments`
family before staging.

**Compatibility:** `search_replace` / `write_file` stay **byte-stable**.
`apply_hunk` is additive. Optional post-commit git-diff enrichment (H2 style) may
be **omitted** or best-effort for `apply_hunk`; it **must never** change the
mandatory ok/partial/error class or substitute for `PostEditVerifier`.

### Backward-compatible read surface for digest (B3 + B4)

Today’s `read_file` returns **raw bounded text only** — no hashline/digest.

**Type / work budget (B3):**

- Optional JSON property `include_digest` **must be a JSON boolean** when present.
- **Omitted or `false`:** body is **byte-identical** to current `read_file`
  (raw content / existing `fs-v1` truncation). No digest work required.
- **Non-boolean present value** (string/number/null/object/array) → soft
  `invalid_arguments` (non-mutating; no partial meta).
- **`true`:** stream full-file SHA-256 with hard **512 KiB** file-size cap using
  checked arithmetic. File byte length **> 512 KiB** → soft `too_large`, **no**
  meta line and **no** partial meta/content digest body. Digest/`size` cover the
  full on-disk file **only when within the 512 KiB cap**. No unbounded CPU/I/O:
  at most one sequential read of ≤512 KiB for hashing under that cap.

**Success body formula when `include_digest=true` and file ≤512 KiB (B4):**

```text
body = meta_line + content_bytes + optional_exactly_one_complete_fs_v1_body_limit_marker
```

- **Meta always first**, exact format (trailing newline **included** in `meta_len`):

```text
meta: format=fs-meta-v1 sha256=<64 lowercase hex> size=<unpadded decimal full-file bytes>\n
```

  - `size` is unpadded decimal ASCII (no leading zeros; `0` for empty file).
  - `sha256` is 64 lowercase hex of the full file within the B3 cap.

- Let `body_cap = tool.max_result_bytes` (**65536**). Let
  `marker` be the complete `fs-v1` body_limit incomplete marker already used by
  read (exact existing bytes: `... incomplete: format=fs-v1 reason=body_limit\n`).
  Let `marker_len` be that full length.

- **If** `meta_len + full_file_size <= body_cap`: emit **full** content; **no**
  incomplete marker.
- **Else:** reserve full `marker_len` first; emit maximal content prefix of length
  `body_cap - meta_len - marker_len` under **checked** subtraction/addition; then
  append **exactly one** complete marker. Never two markers.
- Total body length always `<= body_cap`. Digest/`size` still describe full file
  (within B3 cap) even when content is truncated.
- Required args remain `["path"]` only. Jail/permission/risk unchanged (`risk=read`).

## 3. Budgets and arithmetic

| Budget | Value | Notes |
|--------|------:|-------|
| Target / result file (`apply_hunk`) | **512 KiB** | Same hard max as mutators |
| Digest hash input (`include_digest=true`) | **512 KiB** | Soft `too_large` above; no partial meta |
| `old_string` / `new_string` each | **32 KiB** | Soft `too_large` |
| `read_file` body | **64 KiB** | `tool.max_result_bytes` |
| Review `preview_text` | **4 KiB** | B8; never unbounded |
| Tool-result first line | ≤ `trace.cap_tool_result_body` (**500**) | Stable machine line |
| Trace tool args / body | existing caps (800 / 500) | Redact before durable serialize |

All length checks use **checked arithmetic**. Soft `too_large` for argument/file
budgets; typed `OutOfMemory` only for host allocation failures **before** commit
(and **never** after successful replace — B1).

## 4. Hunk review (exact first slice)

**Surface:** whole **one-hunk** accept/reject only.

**Not** `StdinPrompter`: risk + `args_len` only; must not be labeled or reused as
hunk review.

**Port (coding-agent; public — §7):**

```text
HunkReviewPreview { path, expected_sha256, old_len, new_len, preview_text[≤4KiB] }
HunkReviewDecision = accept | reject
HunkReviewer { ptr, reviewFn(ptr, preview) → HunkReviewDecision }  // infallible
```

**`reviewFn` is infallible** (B5): returns only `accept|reject`. No error union.

- Allocate proposal + preview **before** calling `reviewFn`. Allocation failure →
  typed **`OutOfMemory`**, pre-commit, non-mutating, no temp.
- **Null** reviewer → soft `review_unavailable` (never accept; never OOM-labeled).
- Borrowed `HunkReviewPreview` (including `preview_text`) is valid **only for the
  duration of the `reviewFn` call**. Callers must not retain slices after return.
- Interactive EOF/read failure → **reject** (soft `rejected` path), never accept,
  and **not** typed OOM.

### 4.0 Reviewer bind precedence (B2 — first-match product rule)

Replace all prior conflicting matrices with this **exact first-match** order for
the **product CLI default composition**. SDK host injection is separate (below).

1. **Existing plan / permission deny** → handler not entered for that call (or
   soft permission deny). **No review path.**
2. **Else if CLI `--yolo`:** bind explicit **`AutoAcceptHunkReviewer`** for
   **all** yolo process modes, including **`--json` / `--json-stream`**.
   AutoAccept performs **no** prompt and writes **no** review UI to stdout
   (headless stdout purity preserved). The instance is **bound**, not missing.
3. **Else if interactive non-headless ask** (TTY human CLI, not `--json` /
   `--json-stream`): bind **`InteractiveHunkReviewer`** (§4.1).
4. **Else** (headless ask, noninteractive, or no adapter): leave reviewer
   **null**. If the handler is reached → soft `review_unavailable`. Permission
   may still deny earlier under ask without askFn.

**SDK:** host injects via `Agent.Options.hunk_reviewer`. **Null** →
`review_unavailable` if `apply_hunk` runs. An **explicitly injected**
AutoAccept-equivalent is **bound**, not missing. Missing/null **never** accepts.
**Remember** never skips review (lexical path remember is permission-only).

Review is **separately mandatory** from permission: permission allow alone never
commits an `apply_hunk`.

**Reject:** target **byte-equal**; **no** temp (review is pre-staging); no verifier.

### 4.1 Interactive protocol (B6)

`InteractiveHunkReviewer` (non-headless ask only):

- Human prompt + bounded preview written to **stderr only** (never stdout).
- Stdin: `y` / `Y` / `yes` / `YES` (trimmed) → **accept**; **everything else**
  including empty line → **reject**.
- EOF or stdin read failure → **reject** (not accept; not OOM).
- Cooperative cancel / Ctrl+C observed **before** a decision is returned →
  **must not accept**; follows existing CLI cooperative-cancel truth for the
  active run; **no** new schema field; **no** mutation; no temp.
- Separate from `StdinPrompter` / risk+args_len permission prompt.
- Exact visual layout of stderr text is adapter-owned; B8 bounds still apply to
  `preview_text` supplied by coding-agent.

### 4.2 Preview safety (B8)

- `preview_text` length checked **≤ 4096** bytes after construction.
- Content presented as **valid UTF-8**; invalid source display bytes replaced
  with U+FFFD (lossy) for preview only (does not alter apply match bytes).
- `path` in preview is **workspace-relative only** (no absolute path).
- Truncation: cut on a **valid UTF-8 boundary**, then append the fixed ASCII
  marker **`...[preview_truncated]`** (literal **22** ASCII bytes) **within** the 4 KiB
  cap (reserve marker before cutting content).
- `old_len` / `new_len` are exact true byte lengths; `expected_sha256` is exact.
- Interactive display may show local hunk text on stderr; **never** persist raw
  preview bytes in session / Trace / headless-v1. Ordinary Tool args/results stay
  capped/redacted under existing contracts. No new Trace kinds or session fields.

## 5. Commit transaction (exact order) + post-commit body law (B1)

```text
1. Parse closed JSON; budget-check fields
   - invalid expected_sha256 length/charset → invalid_arguments (not stale)
2. Loop (unchanged): ToolPolicy → Jail → ShellPolicy → execute
3. Handler: lexical path + file endpoint shape
4. Guard existing + mutation endpoint (contained final symlink → real target)
   - ordinary missing → not_found (above); jail escape → jail_deny
5. Read full target with limit 512 KiB+1 → too_large if over
6. SHA-256; compare expected_sha256 → stale_precondition stage=precondition
7. Unique old_string → anchor_not_found | ambiguous_anchor
8. Build complete replacement bytes; result size ≤ 512 KiB
9. Allocate proposal + preview; null reviewer → review_unavailable
   else reviewFn → reject | accept (B5)
10. Revalidate: re-read, digest, unique anchor, Guard containment
    → stale_precondition stage=revalidate on digest/anchor loss
11. **B1 preallocate** all stable post-commit first-line bodies reachable for
    this invocation (before any commit temporary):
    - verifier == null  → only success body verification=not_configured
    - verifier != null  → success verification=ok
                          + partial verification_failed for each of
                            failed | timeout | denied | unavailable
    plus any H2 staged-failure bodies required by atomicCommit
12. Existing same-parent atomic helper (createFileAtomic → write → flush →
    containment recheck → replace); preserve edit-v1 cleanup/symlink truth;
    operation=apply_hunk; parent_dirs=unchanged (apply_hunk never creates parents)
13. On successful replace only:
    - if verifier null: select preallocated not_configured success (allocation-free)
    - if verifier bound: invoke verifyFn(workspace-relative request path);
      callback/host inability including verifier-internal OOM maps to preallocated
      unavailable partial; select matching body allocation-free; free every
      unselected body exactly once
14. **Forbid** typed OOM after successful replace. **Forbid** reporting
    apply_hunk_success when a bound verifier did not return ok (null verifier's
    not_configured is edit-commit success but not verified success).
```

**edit-v1 commit I/O** (pre-commit/staged failures) use:

```text
error: code=edit_io_failed format=edit-v1 operation=apply_hunk stage=<...> target=preserved parent_dirs=unchanged temp_artifact=<absent|may_remain>
```

**Preserve:** contained final-symlink semantics; cleanup truth; post-commit
no-failure of a completed mutation’s disk publish. **No** multi-file
transaction/rollback.

**Races:** digest at steps 6 and 10; residual trusted-host TOCTOU after replace
unchanged from H2.

## 6. Post-edit project verification (exact)

**Surface:** host-owned **`PostEditVerifier`** (coding-agent port; public §7).

```text
PostEditVerifyResult = ok | failed | timeout | denied | unavailable
PostEditVerifier { ptr, verifyFn(ptr, path) → PostEditVerifyResult }
```

- `path` argument is the **workspace-relative request path** (same spelling as
  Tool `path` arg; not absolute).
- Model-supplied command **must never** appear inside `apply_hunk` JSON.
- Doctor `test_entry` is **presence-only** — not auto-executed.
- Product default verifier **null** → only `verification=not_configured` success
  body after commit (B1).
- Non-null: runs **only after** successful replace; selection per B1.
- Cancel observed **before** starting verify; mid-verify preemption not claimed
  (`cancellation=none`).
- Fail/timeout/deny/unavailable after commit → **partial**, no rollback:

```text
partial: code=verification_failed format=edit-sharp-v1 operation=apply_hunk target=modified verification=<failed|timeout|denied|unavailable> temp_artifact=absent
```

| Outcome | Disk | Result class |
|---------|------|--------------|
| Commit + verification ok | modified | `apply_hunk_success` + `verification=ok` |
| Commit + verifier null | modified | `apply_hunk_success` + `verification=not_configured` |
| Commit + verify non-ok | modified | **partial** `verification_failed` |
| Review reject / stale / permission / not_found | preserved | soft error; not success |

## 7. State / allocator / public surface / lifetime (B7)

**Public root re-exports** (`zag-coding-agent` root; implementation later):

- `HunkReviewer`, `HunkReviewPreview`, `HunkReviewDecision`
- `PostEditVerifier`, `PostEditVerifyResult`

**`Agent.Options` (exact):**

```text
hunk_reviewer: ?HunkReviewer = null
post_edit_verifier: ?PostEditVerifier = null
```

| Object | Owner | Lifetime |
|--------|-------|----------|
| Default built-in Agent path `ApplyHunkState` | Agent (heap, stable address) | Outlives all `reply` calls and all Tool value copies; deinit frees safely |
| Default toolset `apply_hunk` Tool | points `instance` at Agent-owned `ApplyHunkState` | Ports copied/borrowed into state at init from Options; D-007 borrow rules |
| `Options.toolset != null` | **caller** owns all custom Tool instance lifetimes | Options `hunk_reviewer` / `post_edit_verifier` are **not** auto-spliced into custom tools |
| Null reviewer on an `apply_hunk` instance | — | soft `review_unavailable` when handler runs |
| Descriptor/static schema strings | existing borrow rules | must outlive Tool copies |
| Proposal / preview bytes | handler allocator, one invocation | freed before return; **not** Session-durable |
| Fork / resume / reply | no proposal catalog | rebind live ports from Agent/state; Session schema **v1** unchanged; no raw preview/proposal in durable session |

Concurrent runs: existing single-flight `Agent.reply`.

## 8. Security

- Defaults: **ask + workspace jail + shell protect**.
- Missing reviewer/verifier/ports **never** allow / yolo / identity / discard /
  no-control.
- Redaction before durable diagnostics.
- Induced later Tools still pass ordinary gates.
- Stable errors: no raw absolute path, temp name, or full body dump.

## 9. Error / result vocabulary

| code | Class | Mutates? |
|------|-------|----------|
| `stale_precondition` | soft | no |
| `anchor_not_found` | soft | no |
| `ambiguous_anchor` | soft | no |
| `not_found` | soft | no |
| `too_large` | soft | no |
| `rejected` | soft | no |
| `review_unavailable` | soft | no |
| `invalid_arguments` | soft | no |
| `jail_deny` | soft | no |
| `permission_denied` | soft (Gate) | no |
| `edit_io_failed` `format=edit-v1` `operation=apply_hunk` `parent_dirs=unchanged` | soft | preserved (+ cleanup) |
| `apply_hunk_success` | soft ok | yes |
| `verification_failed` | soft **partial** | yes (already) |
| `OutOfMemory` | typed host | no commit; **never after successful replace** |

First-line examples:

```text
error: code=invalid_arguments format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
error: code=stale_precondition format=edit-sharp-v1 operation=apply_hunk stage=precondition target=preserved temp_artifact=absent
error: code=stale_precondition format=edit-sharp-v1 operation=apply_hunk stage=revalidate target=preserved temp_artifact=absent
error: code=not_found format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
error: code=rejected format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
error: code=review_unavailable format=edit-sharp-v1 operation=apply_hunk target=preserved temp_artifact=absent
ok: code=apply_hunk_success format=edit-sharp-v1 operation=apply_hunk target=modified verification=not_configured temp_artifact=absent
ok: code=apply_hunk_success format=edit-sharp-v1 operation=apply_hunk target=modified verification=ok temp_artifact=absent
partial: code=verification_failed format=edit-sharp-v1 operation=apply_hunk target=modified verification=failed temp_artifact=absent
partial: code=verification_failed format=edit-sharp-v1 operation=apply_hunk target=modified verification=unavailable temp_artifact=absent
```

No false success: committed+verify-non-ok is **partial**. Existing
`search_replace`/`write_file` strings unchanged.

## 10. Executable fixture matrix (implementation Gate)

1. Valid single-hunk success (`verification=not_configured` default null verifier).
2. Stale token **precondition** + **revalidate** (`stage=revalidate` example);
   non-mutate; no temp.
3. Missing / ambiguous / empty `old_string` / invalid hex length-or-charset
   (`invalid_arguments`, not stale) / oversize args / ordinary `not_found`.
4. Insert (context replace), delete (`new_string` empty), exact newline/UTF-8 bytes.
5. Reject: byte-equal, no temp, verifier not called; interactive EOF → reject.
6. Ask deny; yolo AutoAccept **including headless `--json`/`--json-stream`**
   (no review UI on stdout); remember does not skip review; plan deny non-plan path.
7. Jail / symlink / retarget recheck; contained final symlink preservation.
8. Reviewer missing → `review_unavailable`; proposal/preview OOM → typed OOM
   pre-commit; interactive read fail → reject (not OOM).
9. Verifier pass / fail / timeout / denied / unavailable; post-commit
   `target=modified` partial truth; no rollback; **fail-next allocator after
   successful replace** proves verify-fail remains exact preallocated partial
   (B1).
10. `include_digest` false/omitted byte-identical; non-boolean invalid_arguments;
    true + ≤512 KiB digest; >512 KiB too_large no meta; exact N / N+1 / meta
    boundary bodies (B3/B4).
11. Session resume/fork: no durable proposal; schema v1 unchanged.
12. Trace/headless schemas unchanged; caps hold; redaction holds; preview not
    durably persisted.
13. SDK public surface: Options ports + root re-exports; null reviewer fail-closed;
    custom toolset does not auto-splice Options ports.
14. CLI interactive: stderr-only preview; stdout purity; no-temp byte-equal rejection.
15. Local failures need **no** extra provider/model call.
16. std + curl full Gates green on candidate and merged-main.

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

- [x] Independent **contract** review on candidate `07b8dab`: architecture/API
  **PASS**, safety/transaction **PASS**, final adjudication **PASS**, zero
  blockers after B1–B8. Contract PASS authorizes **only** a later separately
  dispatched implementation node; **no product code** in this contract node.
- [x] `python3 scripts/lint_docs.py`
- [x] `python3 scripts/score_docs.py --check` (scores **92/74** truth preserved;
  timestamp-only report rewrites restored; deterministic body changes committed
  when required)
- [x] `/usr/bin/git diff --check` on committed range from base tip
- [x] Docs-only contract lineage; no `packages/**` / tests / build / schema changes

# verification (implementation track — later; **not started**)

- [ ] Full §10 fixture matrix in coding-agent tests
- [ ] Dual-backend std/curl Gates; docs lint/score; independent **code** review PASS
- [ ] Maturity row Tools · write/edit remains L2 unless a **separate** L3 Gate is
  explicitly scheduled and closed
- [ ] Later Goal/delivery decision to dispatch the implementation node under this
  frozen contract (not preselected as done here)
