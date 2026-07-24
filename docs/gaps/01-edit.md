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
| 权限仅两档全局 | 无法「只对某 path remember」 | H3 · [permissions](../modules/permissions.md) |
| 无 plan 模式语义 | 大改前缺少只读规划合同 | H3 占位 → C6 |
| shell 错误形状不统一 | exit/timeout/policy 难区分 | H 旁路 · [tools-shell](../modules/tools-shell.md) |
| edit golden transcript | 端到端回归 | H2 收口 / Quality |

## 非本阶段

- hunk 级 TUI accept/reject（属 C4）  
- hashline 完整工业实现（C4 可升级；H2 先简化锚点）  
- 后台 shell（C 轨 / tools-shell L3）

## 下一步

[H-harden H2 + H3](../phases/H-harden.md)。  
