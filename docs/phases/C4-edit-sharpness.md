# C4 — Edit Sharpness

| 项 | 内容 |
|----|------|
| 前置 | Phase H edit/containment L2 ✅ |
| 路线位置 | M2 `edit-sharpness-001`（selected daily UX） |
| 失败模式 | stale/whitespace 锚点导致误改；用户无法审阅将落盘的变化 |
| 模块 | [tools-edit](../modules/tools-edit.md) L2 runtime + **C4 first-slice contract freeze** |
| Task | [edit-sharpness-001](../plan/tasks/edit-sharpness-001.md) |
| 合同状态 | **done** at `7be5151` — contract PASS @ `07b8dab`/`f13b0f8` → impl/fix/closeout; Tools · write/edit remains **L2** |
| 成熟度 | Tools · write/edit remains **L2** (no L3 row raise; local macOS Gates only; no current-tip Linux/remote claim) |

## 目标

在现有 target-preserving single-file contract 上增加一个小而可靠的日用编辑切片，而不是扩成 AST/LSP 工具平台。

## 冻结的第一切片（exact choices）

Binding truth: [tools-edit § C4 first-slice](../modules/tools-edit.md#l3--c4-first-slice-binding-contract-edit-sharpness-001).

| Decision | Frozen choice |
|----------|---------------|
| Ownership | All patch/review/verify state in **zag-coding-agent**; thin CLI reviewer adapter only; **no** new Core ports; **no** new package |
| Patch mechanism | Model-visible Tool **`apply_hunk`**: single-file, **one** content-anchor hunk + **full-file SHA-256** `expected_sha256` |
| Why not multi-hunk apply_patch / pure hashline first | Reuse H2 unique-anchor + atomic commit; close stale + review gates first |
| Digest read (B3/B4) | JSON boolean `include_digest` only; omitted/false byte-identical; true hashes ≤512 KiB or soft `too_large` with no meta; body = meta + content + optional one `fs-v1` body_limit marker under checked arithmetic |
| Budgets | File/hash ≤512 KiB; old/new ≤32 KiB; preview ≤4 KiB; result body ≤64 KiB |
| Hunk review (B2/B5/B6/B8) | Infallible `reviewFn`; null → `review_unavailable`; first-match bind: plan/deny → none; else yolo AutoAccept (incl. headless JSON); else interactive InteractiveHunkReviewer (stderr/stdin protocol); else null. Not StdinPrompter. Preview UTF-8-safe, relative path, fixed truncation marker |
| Post-commit body law (B1) | Preallocate all reachable post-commit first-lines **before any temp**; after replace select allocation-free; no typed OOM after replace; bound verifier non-ok never reported as success |
| Commit order | parse → ToolPolicy → Jail → ShellPolicy → execute → digest/anchor → review → revalidate → preallocate post-commit bodies → atomic → optional verify |
| Verification | Host `PostEditVerifier` on workspace-relative path; default null → `not_configured`; after commit; fail → partial `target=modified` |
| Public surface (B7) | Root re-exports + `Agent.Options.hunk_reviewer` / `post_edit_verifier`; default Agent-owned `ApplyHunkState`; custom toolset does not auto-splice Options ports |
| Schemas | Session v1 / Trace v1 / headless-v1 / `project.zig` / `--no-project` **unchanged** |

## 第一切片交付（closed @ `7be5151`）

1. `apply_hunk` + `read_file` digest option per freeze (B1–B8) ✅
2. CLI thin bind + interactive stderr protocol ✅
3. Fixture matrix §10 on dual-backend local macOS Gates (incl. fail-next post-replace + digest boundaries) ✅
4. Legacy `search_replace`/`write_file` behavior stable ✅

## 第二切片（closed @ `e086df8`）

- 多文件事务/回滚 — **done** [edit-transaction-001](../plan/tasks/edit-transaction-001.md)
  / [edit-transaction.md](../modules/edit-transaction.md)（contract PASS → impl
  `apply_transaction` + §10 fixtures；Tools · write/edit stays **L2**；
  no remote Gate claim this tip）。

## 后移

- AST/LSP/DAP；
- 完整 IDE/TUI diff pane；
- multi-hunk apply_patch / hashline line-address formats；
- 自动 doctor→verify command；
- process supervisor / mid-flight shell preemption — [process-supervisor-001](../plan/tasks/process-supervisor-001.md)；
- 以增加 Tool 数量为目标的扩张；
- Core 变更或 schema 变更。

## 验收

### Contract track

- [x] Independent contract review **PASS** on `07b8dab` (architecture/API + safety/transaction + final adjudication; zero blockers after B1–B8);
- [x] Owning docs freeze exact mechanism/review/verification with no ambiguous “or”; B1–B8 closed;
- [x] Maturity text still claims Tools · write/edit **L2** only;
- [x] Contract PASS authorizes **only** a later separately dispatched implementation node; no product code in this contract lineage.

### Implementation track (closed @ `7be5151`)

- [x] stale digest precondition + **revalidate** non-mutating deterministic fixtures；
- [x] 拒绝单个 hunk 后磁盘 byte-equal 且无 temp；interactive cancel flag never accepts；
- [x] 接受后仍满足 atomic/jail/`edit-v1`（`operation=apply_hunk` `parent_dirs=unchanged`）；
- [x] B1: post-replace fail-next allocator keeps exact partial `target=modified`；bound verifier non-ok never `apply_hunk_success`；
- [x] B3/B4 digest type/cap/body formula fixtures；
- [x] 默认 Tool 描述仍优先 search_replace / apply_hunk over whole-file overwrite；
- [x] Independent code review PASS + candidate/merged-main local macOS dual-backend Gates at `7be5151`（std **655/655**、curl **654/654**；coding **375**、CLI **36**、SDK **24/24**；docs **92/74**）；
- [x] Coordinator ff-only local main `f13b0f8` → `7be5151`；**no push**；**no fresh remote/Linux evidence for this tip**；Tools · write/edit stays **L2**。

## 对标

Pi edit behavior；Hyper hashline；Amp Changes；Codex apply_patch。对齐 failure semantics，不追 API/格式 parity。
