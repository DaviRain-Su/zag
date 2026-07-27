---
id: edit-sharpness-001
scope: coding-agent/edit-sharpness (M2 / C4 first slice)
status: done
priority: P1
depends-on:
  - prompt-templates-001
  - h-edit-integrity-001
---

# objective

Deliver the **smallest reliable C4 edit-sharpness first slice** on top of the
closed H2 single-file edit integrity contract:

1. **Docs-first binding contract** with exact mechanism, review, commit,
   verification, budgets, errors, ownership, and fixture choices — no
   `hashline or equivalent` / `CLI or SDK` ambiguity.
2. **Production implementation** under that freeze: model-visible `apply_hunk`,
   backward-compatible `read_file.include_digest`, public reviewer/verifier
   ports + `Agent.Options` / default `ApplyHunkState`, thin CLI reviewer bind,
   and §10 fixtures.

`edit-sharpness-001` closed at tip
`7be5151a72f074cb9435ca81276c284bfbbb8b23` after contract freeze, implementation,
review-fix, independent correctness / boundary / final adjudication **PASS**
(zero blockers), dual-backend candidate + merged-main **local macOS** Gates, and
this docs-truth closeout. Tools · write/edit remains **L2** (no L3 claim or row
raise). **No push**; **no fresh remote/Linux evidence for this tip**.

**Owner:** `zag-coding-agent` for all patch proposal/review/verification state
and concrete behavior; **thin explicit CLI adapter only** for interactive hunk
accept/reject. **No** new `zag-agent-core` edit/review/lifecycle ports. **No**
new Zig package.

Binding specification: [tools-edit.md](../../modules/tools-edit.md) § C4 first
slice + [C4-edit-sharpness.md](../../phases/C4-edit-sharpness.md).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze | **PASS** at candidate tip `07b8dab2158d100642abf5bd61dbc64366f1aba4` after B1–B8: independent architecture/API **PASS**, independent safety/transaction **PASS**, final adjudication **PASS**, zero blockers; contract PASS record tip `f13b0f851aeac52fe8285668fbc1679e910394ed` |
| Overall product task | **`done` @ `7be5151`** (2026-07-28 local closeout) |
| Production implementation | **done** — `cfdc81b` (impl) → `241374a` (review-fix) → `7be5151` (docs truth + this closeout). Independent correctness **PASS**, boundary/integration **PASS**, final adjudication **PASS** at `7be5151` (zero blockers) |
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

# path

## Docs

- `docs/plan/tasks/edit-sharpness-001.md` — this task
- `docs/modules/tools-edit.md` — **binding truth** for mechanism/review/commit/verify
- `docs/phases/C4-edit-sharpness.md` — phase freeze + acceptance checkboxes
- Status truth: `docs/plan/README.md`, `docs/roadmap.md`, `docs/maturity.md`
  (Tools · write/edit **L2** unchanged), `docs/modules/README.md`,
  `docs/quality/evals.md`, permissions/CLI/SDK notes

## Implementation (delivered)

- `packages/zag-coding-agent/src/runtime/edit_tools.zig` — `apply_hunk` + B1 post-commit bodies + shared `atomicCommit` (`operation=apply_hunk`)
- `packages/zag-coding-agent/src/runtime/fs_tools.zig` — optional `include_digest` on `read_file` (B3/B4)
- `packages/zag-coding-agent/src/toolset.zig` / `agent.zig` — heap-stable `ApplyHunkState` + `Agent.Options` ports
- `packages/zag-coding-agent/src/root.zig` — public re-exports listed in binding §7
- coding-agent tests covering §10 fixture matrix (see verification)
- `packages/zag-cli/src/cli.zig` — thin Interactive/AutoAccept bind per B2 precedence + interactive protocol B6
- **no** Core edit/review ports; **no** session/Trace/headless schema fields; **no** new package

# contract summary (binding detail lives in tools-edit)

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent` | `apply_hunk` handler; proposal bytes; `HunkReviewer` / `PostEditVerifier` ports; default `ApplyHunkState`; digest `read_file`; soft-result vocabulary; public root re-exports | Core ports; multi-file transaction engine; TUI platform |
| `zag-cli` | Thin bind of Interactive/AutoAccept per B2 first-match rule; interactive stderr protocol; process signals | Patch parse/apply; durable proposal store; inventing accept when adapter missing |
| `zag-agent-core` | Existing Tool/loop only (**ToolPolicy → Jail → ShellPolicy → execute**) | New edit/review/lifecycle ports |
| Model | Tool args only | Verify command inside write Tool; bypass permission/shell |

## 2–9. Binding detail

Authoritative exact mechanism, digest formula, budgets, review bind precedence,
B1 post-commit body law, public surface, security, and result vocabulary remain
in [tools-edit.md](../../modules/tools-edit.md) § C4 first-slice binding
contract. Do not restate conflicting rules here.

## 10. Executable fixture matrix (implementation Gate)

Named test map (review-fix + closeout evidence):

| §10 | Test name | Path |
|----:|-----------|------|
| 1 | `edit-sharp §10.1 valid single-hunk success not_configured` | `edit_tools.zig` |
| 2 | `edit-sharp §10.2 stale precondition and revalidate non-mutate` | `edit_tools.zig` |
| 3 | `edit-sharp §10.3 missing ambiguous empty invalid hex oversize not_found` | `edit_tools.zig` |
| 4 | `edit-sharp §10.4 insert delete exact newline and utf8 bytes` + preview invalid UTF-8 | `edit_tools.zig` |
| 5 | `edit-sharp §10.5 reject byte-equal no temp verifier not called` + `decideHunkReviewLine` EOF | `edit_tools.zig` / `cli.zig` |
| 6 | `edit-sharp §10.6 B2 reviewer bind…` + remember does not skip review; plan deny | `cli.zig` / `agent.zig` |
| 7 | `edit-sharp §10.7 jail and contained final symlink` | `edit_tools.zig` |
| 8 | `edit-sharp §10.8 missing reviewer and pre-review OOM` | `edit_tools.zig` |
| 9 | `edit-sharp §10.9 verifier matrix and post-replace fail-next allocator` (real arm-in-verifyFn) | `edit_tools.zig` |
| 10 | `edit-sharp §10.10 include_digest omitted false true caps and boundaries` | `fs_tools.zig` |
| 11 | `edit-sharp §10.11 resume fork schema v1 no durable preview proposal` | `agent.zig` |
| 12 | `edit-sharp §10.12 trace caps no raw preview marker` (+ §10.11) | `agent.zig` |
| 13 | `edit-sharp §10.13 Options ports…` + SDK public ports Options | `agent.zig` / `sdk-consumer-fixture` |
| 14 | Interactive stderr seam + yolo AutoAccept no stderr_writes | `cli.zig` |
| 15 | local soft failure exactly two provider calls | `agent.zig` |
| 16 | `edit-sharp §10.16 search_replace write_file byte stability` | `edit_tools.zig` |

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
- Mid-verify cancel preemption (`cancellation=none`)

# verification (contract track)

- [x] Independent **contract** review on candidate `07b8dab`: architecture/API
  **PASS**, safety/transaction **PASS**, final adjudication **PASS**, zero
  blockers after B1–B8. Contract PASS record tip
  `f13b0f851aeac52fe8285668fbc1679e910394ed`.
- [x] `python3 scripts/lint_docs.py` / `score_docs.py --check` on contract lineage
- [x] Docs-only contract lineage; no product code in the contract node

# verification (implementation track — closed)

- [x] Full §10 fixture matrix green (named map above; private deterministic seams only)
- [x] Independent **code** review PASS at tip `7be5151`: correctness **PASS**,
  boundary/integration **PASS**, final adjudication **PASS**, zero blockers
  (impl `cfdc81b` + review-fix `241374a` + docs truth `7be5151`)
- [x] Candidate Gate at exact `7be5151` (local macOS): std **40/40 · 655/655**;
  curl **42/42 · 654/654**; coding-agent **375/375**; CLI **36/36**; external
  SDK consumer **24/24**; OpenAPI **287/287**; catalog **40**; docs readability
  **92/100** and security **74/100** (54 files); docs lint + score + working/range
  diff pass; clean after timestamp restore
- [x] Coordinator ff-only advanced local main `f13b0f8` → `7be5151` while
  preserving unrelated canonical `.gitignore`
- [x] Merged-main local macOS Gate at exact `7be5151` repeated std
  **40/40 · 655/655**, curl **42/42 · 654/654**, coding **375**, CLI **36**,
  SDK **24**, OpenAPI **287**, catalog **40**, docs **92/74**, diff pass
- [x] Maturity row Tools · write/edit remains **L2** (no L3 claim)
- [x] **No push**; **no fresh remote/Linux evidence for this tip**
- [x] Scope held: additive coding-agent `apply_hunk` + `include_digest` + public
  reviewer/verifier/`Agent.Options`/default state + thin CLI bind + §10; no
  Core/session-v1/Trace-v1/headless-v1/`project.zig`/`--no-project` semantics;
  no TUI/multi-file/AST/LSP/E2/E3

# lineage (tips)

| Stage | Tip |
|-------|-----|
| Contract candidate (B1–B8 freeze) | `07b8dab2158d100642abf5bd61dbc64366f1aba4` |
| Contract PASS record / base | `f13b0f851aeac52fe8285668fbc1679e910394ed` |
| Implementation | `cfdc81b5acce736e3cf50eb3e1528ad372edf40e` |
| Review-fix (B1 fail-next + §10 integration/SDK) | `241374a740e1040676f4af4b0c56ff74db75783b` |
| Docs fixture-count truth | `7be5151a72f074cb9435ca81276c284bfbbb8b23` |
| Closeout (this docs tip; same product tip as Gates) | `7be5151a72f074cb9435ca81276c284bfbbb8b23` |
