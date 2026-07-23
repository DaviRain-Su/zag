# Gap: Phase 2 Session + Context → L2

> Teaching：[chapters/02-session-context](../../chapters/02-session-context/README.md) = **tutorial-complete**。  
> 对照：[maturity.md](../maturity.md) Context / Session。

## 教程已具备

- `.zag/sessions/*.jsonl` 保存/续聊
- `AGENTS.md` / README 注入 system
- `viewForModel`：保留 system + 最近 N 条（截断，非摘要）
- full transcript 与 model view 分离（雏形）

## 离 L2 还差什么

| 缺口 | 为何算生产问题 | 落点 |
|------|----------------|------|
| 无 prompt 四层正式定义 | system/project/session/ephemeral 混用易回归 | H4 · [context-compaction](../modules/context-compaction.md) |
| 仅截断、无 compaction | 长任务丢早期约束或反复爆上下文 | H4 |
| session 无 schema 版本 | 改字段会静默坏旧文件 | H4 · [session-store](../modules/session-store.md) |
| 无迁移规则 | 升级即数据赌博 | H4 |
| 无 repo map | 中型仓定位差 | C5（H 只定边界） |
| 无 session fork / 旁支 | 旁问污染主线 | C5 / Nanocodex 启发 |

## 非本阶段

- 跨 session memory 产品化（C5 可选）  
- 分布式 durable execution  

## 下一步

[H-harden H4](../phases/H-harden.md)；repo map 进 [C5](../phases/C5-context.md)。  
