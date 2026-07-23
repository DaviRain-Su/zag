# Gap: Phase 3 Jail + Policy + Trace → L2

> Teaching：[chapters/03-production](../../chapters/03-production/README.md) = **tutorial-complete**。  
> 章名含「production」为历史命名；**不等于** Production Floor 完成。  
> 对照：[maturity.md](../maturity.md) Workspace / Trace / Quality。

## 教程已具备

- 工作区路径 jail（相对路径、拒绝对绝对路径与 `..` 逃逸）
- shell denylist（`protect`）
- `--trace` JSONL（tool 序列、jail/shell deny）
- `SECURITY.md` 初稿

## 离 L2 还差什么

| 缺口 | 为何算生产问题 | 落点 |
|------|----------------|------|
| 非 OS sandbox | denylist/jail 可被构造绕过 | 诚实文档 + **C7**；H 不承诺 sandbox |
| 无 secret redact | key/内容进 verbose/trace/session | H5 · [workspace-sandbox](../modules/workspace-sandbox.md) |
| policy 无固定测试矩阵 | 改一行 denylist 无回归 | H5 · [evals](../quality/evals.md) |
| trace schema 无版本 | 审计工具易碎 | H7 · [trace-observability](../modules/trace-observability.md) |
| trace 缺 usage / 停因 | 无法复盘成本与 cancel | H6 + H7 |
| 无 `/doctor` readiness | 不适配仓库仍硬跑 | H5 最小 doctor |
| 无 security eval CI | 「默认拒绝」只是故事 | H · Quality |

## 非本阶段（勿写进「Phase 3 已完成」）

- seatbelt / bubblewrap / 容器  
- 网络 allowlist  
- 多租户隔离  

## 下一步

[H-harden H5 + H7](../phases/H-harden.md)；真沙箱 [C7](../phases/C7-sandbox.md)。  
