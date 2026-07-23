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
| **唯一**整文件 overwrite | 大文件易毁掉；偏一行无法局部改 | H2 · [tools-edit](../modules/tools-edit.md) |
| 无内容锚点 / search_replace | 空白/错位 diff 高发 | H2（钉死 search_replace+锚点） |
| 无 grep/glob | 定位靠 shell 或臆测 | H2 |
| 无写后 diff 回灌 | 模型不知道净变更 | H2 |
| 权限仅两档全局 | 无法「只对某 path remember」 | H3 · [permissions](../modules/permissions.md) |
| 无 plan 模式语义 | 大改前缺少只读规划合同 | H3 占位 → C6 |
| shell 错误形状不统一 | exit/timeout/policy 难区分 | H2 旁路 · [tools-shell](../modules/tools-shell.md) |

## 非本阶段

- hunk 级 TUI accept/reject（属 C4）  
- hashline 完整工业实现（C4 可升级；H2 先简化锚点）  
- 后台 shell（C 轨 / tools-shell L3）

## 下一步

[H-harden H2 + H3](../phases/H-harden.md)。  
