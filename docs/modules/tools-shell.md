# Module: tools-shell

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-coding-agent/src/runtime/edit_tools.zig`（`run_shell`）+ core `shell_policy` |
| 成熟度 | L1 → L2（随 H2/H5）→ L3（后台 job） |
| 对标 | Hyper background tasks；Codex sandbox shell |

## 不变式

1. Shell 经 permission → shell_policy → execute。  
2. stdout/stderr 捕获并截断；超时可配置。  
3. 退出码与超时必须可区分（错误码或结构化前缀）。

## L2 要求

- 统一结果：`exit_code` / `timed_out` / `output`（截断标记）  
- 与 [workspace-sandbox](./workspace-sandbox.md) policy 矩阵联动测试  
- 非交互；文档写明不支持 TTY 程序  

## L3 方向

- 后台任务 + monitor/poll（C 轨 / Hyper user-guide 20）  
- sandbox 内执行（C7）  

## 非目标（H）

- 完整 PTY 复刻 Hyper pager  

## 相关

- [permissions.md](./permissions.md)  
- [phases/H-harden.md](../phases/H-harden.md) H2/H5  
