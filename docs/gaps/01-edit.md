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
| write/edit fault matrix | containment 与 Agent deny/jail 组合已验收；一般 atomic/no-partial write fault 仍不能声称 | H exit audit / C4 |

## 非本阶段

- hunk 级 TUI accept/reject（属 C4）  
- hashline 完整工业实现（C4 可升级；H2 先简化锚点）  
- 后台 shell（C 轨 / tools-shell L3）
- plan 模式产品壳 / 快捷键（C6）

## 下一步

`h-tool-runtime-001`、`h-workspace-001`、`h-doctor-001`、`h-shell-001` 与原 h-integration Agent evidence 均通过各自独立/main Gate。下一步是 ready `h-integration-001` 的最终 Phase H audit。Mid-flight shell cancellation、process tree、atomic edit fault guarantee 与更强 edit UX 均未宣称。
