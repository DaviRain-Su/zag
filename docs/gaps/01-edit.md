# Gap: Phase 1 Edit + Permissions → L2

> Teaching：[chapters/01-edit-permissions](../../chapters/01-edit-permissions/README.md) = **tutorial-complete**。  
> 对照：[maturity.md](../maturity.md) Tools·write/edit/shell、Permissions。

## 教程已具备

- `write_file`（整文件覆盖）+ `run_shell`（超时/截断）
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
| custom Tool risk 按名称且 unknown→read | 第三方写/执行 Tool 可绕过确认 | P0 [tool-runtime](../modules/tool-runtime.md) / `h-tool-runtime-001` |
| file Tool 仅 lexical jail | symlink 可越界 | P0 [workspace-sandbox](../modules/workspace-sandbox.md) |
| shell 错误/deadline/cancel 形状未闭合 | exit/timeout/policy/cancel 难统一审计 | H P1 · [tools-shell](../modules/tools-shell.md) |
| edit/failure golden matrix | 端到端回归需覆盖 custom deny/containment | H Quality |

## 非本阶段

- hunk 级 TUI accept/reject（属 C4）  
- hashline 完整工业实现（C4 可升级；H2 先简化锚点）  
- 后台 shell（C 轨 / tools-shell L3）
- plan 模式产品壳 / 快捷键（C6）

## 下一步

先完成 Phase H P0 `h-tool-runtime-001` 与 `h-workspace-001`；built-in matrix 已有，但 Permissions/Workspace 尚未达到 extensible L2。
