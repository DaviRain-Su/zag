# Gap: Phase 1 Edit + Permissions → L2

> Teaching：[chapters/01-edit-permissions](../../chapters/01-edit-permissions/README.md) = **tutorial-complete**。  
> 对照：[maturity.md](../maturity.md) Tools·write/edit/shell、Permissions。

## 教程已具备

- `write_file`（整文件覆盖）+ `run_shell`（capture deadline / 有界输出）
- `ask` / `yolo` 权限门；deny → soft tool message
- 危险操作默认需确认

## 离 L2 还差什么

| 缺口 | 为何算生产问题 | 落点 |
|------|----------------|------|
| ~~唯一整文件 overwrite~~ | — | ✅ H2：`search_replace` 默认 + `write_file` 保留 |
| ~~无内容锚点~~ | — | ✅ 唯一 `old_string`；失败码 `anchor_not_found` / `ambiguous_anchor` |
| ~~无 grep/glob~~ | — | ✅ `fs_tools` + jail |
| ~~无写后 diff~~ | — | ✅ 可选短 `git diff`（失败省略） |
| ~~built-in 权限仅两档全局~~ | — | ✅ write-path remember + `--no-remember` |
| ~~无 plan 模式语义~~ | — | ✅ `SessionKind.plan` stub；完整 UX → C6 |
| ~~custom Tool risk 按名称且 unknown→read~~ | **closed** D-007 / h-tool-runtime-001：descriptor risk fail-closed | done |
| ~~file Tool 仅 lexical jail~~ | **closed** h-workspace-001：symlink-aware Guard + handler recheck | done |
| ~~shell-v1 outcome/body/cleanup/trace Gate~~ | **closed:** fixed deny、UTF-8/base64、scoped limits、N/N+1、direct-PID、Agent parsed-trace；independent/Oracle/main passed | done [h-shell-001](../plan/tasks/h-shell-001.md) |
| single-file write/edit fault preservation | final audit confirmed direct truncate/write can destroy prior bytes；basic target preservation is H correctness, not C4 sharpness | open [h-edit-integrity-001](../plan/tasks/h-edit-integrity-001.md) |
| read/search body + cutoff truth | count caps do not prove 64 KiB；walker/source/pattern limits may look complete | open [h-read-search-bounds-001](../plan/tasks/h-read-search-bounds-001.md) |

## 非本阶段

- hunk 级 TUI accept/reject（属 C4）  
- hashline 完整工业实现（C4 可升级；H2 先简化锚点）  
- 后台 shell（C 轨 / tools-shell L3）
- plan 模式产品壳 / 快捷键（C6）

## 下一步

既有 Tool/workspace/doctor/shell 与原 Agent evidence 保持通过。Final audit 已把 `h-edit-integrity-001` 与 `h-read-search-bounds-001` 提升为 blocking tasks；`h-integration-001` 等两者完成后再 fresh audit。Mid-flight shell cancellation、process tree、power-loss durability 与更强 edit UX 仍未宣称。
