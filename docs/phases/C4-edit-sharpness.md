# C4 — Edit Sharpness

| 项 | 内容 |
|----|------|
| 前置 | Phase H edit/containment L2 ✅ |
| 路线位置 | M2 `edit-sharpness-001`（selected daily UX） |
| 失败模式 | stale/whitespace 锚点导致误改；用户无法审阅将落盘的变化 |
| 模块 | [tools-edit](../modules/tools-edit.md) L3 |

## 目标

在现有 target-preserving single-file contract 上增加一个小而可靠的日用编辑切片，而不是扩成 AST/LSP 工具平台。

## 近期范围

1. patch-grade edit path（hashline 或等价 stale-anchor contract；方案由 docs-first analysis 决定）；
2. CLI hunk review：accept/reject 后磁盘状态可证明；
3. post-edit verification：显式命令/项目脚本，失败可见；
4. legacy `pi-mono-zig`/Pi 只作行为与 fixture 参考，不搬其 Tool 架构。

## 后移

- 多文件事务/回滚；
- AST/LSP/DAP；
- 完整 IDE diff pane；
- 以增加 Tool 数量为目标的扩张。

## 验收

- [ ] stale anchor 不会落到错误位置；恢复策略有 deterministic eval；
- [ ] 拒绝单个 hunk 后磁盘 byte-equal；
- [ ] 接受后仍满足现有 atomic/jail/redaction contract；
- [ ] verification 失败不被标记为成功；
- [ ] 默认 Tool 描述不引导整文件覆写大文件。

## 对标

Pi edit behavior；Hyper hashline；Amp Changes；Codex apply_patch。对齐 failure semantics，不追 API/格式 parity。
