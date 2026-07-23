# C5 — Context Engineering

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成**（尤其 H4） |
| 失败模式 | 长任务断片；上下文贵；旁问污染主线 |
| 模块 | [context-compaction](../modules/context-compaction.md)、[session-store](../modules/session-store.md) |

## 目标

在 H4 四层 + 最小 compaction 之上，做到中型仓库可日用。

## 范围

1. **Repo map**：文件树 + 轻量符号摘要；按任务选文件进 ephemeral/view  
2. Session **fork / 旁支**：旁问不污染主线（Pi / Nanocodex 启发）  
3. Compaction 升级：可选 LLM 摘要（可关）；摘要质量有回归夹具  
4. 跨 session **memory**（默认关、可审、可删）

## 非目标

- 云端记忆同步  
- 全库向量库作为唯一检索（可后置）  

## 验收

- [ ] 中型 fixture 仓不问「结构」也能定位关键文件  
- [ ] fork 旁支后主 session 消息数不膨胀  
- [ ] memory 关闭时零行为变化  

## 对标

Aider repo map；Pi branching；Hyper memory  
