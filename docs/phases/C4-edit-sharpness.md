# C4 — Edit Sharpness

| 项 | 内容 |
|----|------|
| 前置 | Phase H edit/containment L2 ✅ |
| 路线位置 | M2 `edit-sharpness-001`（selected daily UX） |
| 失败模式 | stale/whitespace 锚点导致误改；用户无法审阅将落盘的变化 |
| 模块 | [tools-edit](../modules/tools-edit.md) L2 runtime + **C4 first-slice contract freeze** |
| Task | [edit-sharpness-001](../plan/tasks/edit-sharpness-001.md) |
| 合同状态 | **contract track in progress** — production implementation **BLOCKED** until independent contract review **PASS** |
| 成熟度 | Tools · write/edit remains **L2** (no L3 row raise from docs alone) |

## 目标

在现有 target-preserving single-file contract 上增加一个小而可靠的日用编辑切片，而不是扩成 AST/LSP 工具平台。

## 冻结的第一切片（exact choices）

Binding truth: [tools-edit § C4 first-slice](../modules/tools-edit.md#l3--c4-first-slice-binding-contract-edit-sharpness-001).

| Decision | Frozen choice |
|----------|---------------|
| Ownership | All patch/review/verify state in **zag-coding-agent**; thin CLI reviewer adapter only; **no** new Core ports; **no** new package |
| Patch mechanism | Model-visible Tool **`apply_hunk`**: single-file, **one** content-anchor hunk + **full-file SHA-256** `expected_sha256` |
| Why not multi-hunk apply_patch / pure hashline first | Reuse H2 unique-anchor + atomic commit; close stale + review gates first; avoid TUI/multi-file/parser platform |
| Digest read surface | Optional `read_file.include_digest` → `meta: format=fs-meta-v1 sha256=… size=…` then content; omitted = raw body unchanged (current `read_file` has **no** digest today) |
| Budgets | File ≤512 KiB; old/new ≤32 KiB each; review preview ≤4 KiB; result body ≤64 KiB; checked arithmetic |
| Hunk review | Whole one-hunk accept/reject via coding-agent **`HunkReviewer`** on stateful Tool; **mandatory**; missing → `review_unavailable` (never accept). **Not** `StdinPrompter` |
| Mode matrix | ask+interactive → InteractiveHunkReviewer; yolo → AutoAcceptHunkReviewer (still bound); headless/SDK null default fail-closed; plan/deny unchanged; remember ≠ review skip |
| Commit order | parse → ToolPolicy → Jail → execute → digest/anchor → review → revalidate → H2 same-parent atomic → optional verify |
| Verification | Host-owned **`PostEditVerifier` callback only**; no model command in write Tool; doctor presence-only not auto-run; default null → `verification=not_configured`; after commit; fail → partial `target=modified` no rollback |
| Schemas | Session v1 / Trace v1 / headless-v1 / `project.zig` / `--no-project` **unchanged** |

## 近期范围（implementation after PASS）

1. Implement `apply_hunk` + `read_file` digest option per freeze;
2. CLI thin Interactive/AutoAccept hunk reviewer wiring;
3. Fixture matrix §10 on dual-backend Gates;
4. Keep legacy `search_replace`/`write_file` behavior stable.

## 后移

- 多文件事务/回滚；
- AST/LSP/DAP；
- 完整 IDE/TUI diff pane；
- multi-hunk apply_patch / hashline line-address formats；
- 自动 doctor→verify command；
- 以增加 Tool 数量为目标的扩张；
- Core 变更或 schema 变更。

## 验收

### Contract track

- [ ] Independent contract review **PASS** (production code blocked until then);
- [ ] Owning docs freeze exact mechanism/review/verification with no ambiguous “or”;
- [ ] Maturity text still claims Tools · write/edit **L2** only.

### Implementation track (later)

- [ ] stale digest 不会落到错误位置；deterministic eval 覆盖 precondition + revalidate；
- [ ] 拒绝单个 hunk 后磁盘 byte-equal 且无 temp；
- [ ] 接受后仍满足现有 atomic/jail/redaction/`edit-v1` contract；
- [ ] verification 失败返回 partial `target=modified`，不标记 overall verified success，不宣称 rollback；
- [ ] 默认 Tool 描述不引导整文件覆写大文件；
- [ ] std/curl full Gates + §10 fixtures.

## 对标

Pi edit behavior；Hyper hashline；Amp Changes；Codex apply_patch。对齐 failure semantics，不追 API/格式 parity。
