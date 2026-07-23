# C5 — Context Engineering

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成**（尤其 H4：四层 prompt、compaction、session schema） |
| 失败模式 | 长任务断片；上下文贵；旁问污染主线；重复交代偏好 |
| 模块 | [context-compaction](../modules/context-compaction.md)、[session-store](../modules/session-store.md)、[memory](../modules/memory.md) |

## 目标

在 H4 四层 + 最小 compaction 之上，做到中型仓库可日用，并可选跨 session 记忆。

## 范围（分条，可分期）

| 优先级 | 主题 | 说明 |
|--------|------|------|
| C5.1 | **Repo map** | 文件树 + 轻量符号摘要；按任务选文件进 ephemeral/view |
| C5.2 | Session **fork / 旁支** | 旁问不污染主线（Pi / Nanocodex 启发） |
| C5.3 | Compaction 升级 | 可选 LLM 摘要（可关）；摘要质量有回归夹具 |
| C5.4 | **Memory Repo** | 跨 session 长期条目；**默认关**；可审可删；见 [memory.md](../modules/memory.md) |

### Memory Repo（单独钉死）

- **不是** transcript，**不是** compaction 摘要，**不是** AGENTS.md。  
- 前置：H4 边界已硬（view 投影、session 版本）。  
- 关闭时与 H 出口 **零行为变化**。  
- 可选检索：全文/tag 优先；`zag-ai` embed 仅可选后端。  
- **不进** Phase H；**不进** L2 总验收。

## 非目标

- 云端记忆同步  
- 全库向量库作为唯一检索  
- 在 H 未完成时提前做 Memory 平台  

## 验收

- [ ] 中型 fixture 仓不问「结构」也能定位关键文件（repo map）  
- [ ] fork 旁支后主 session 消息数不膨胀  
- [ ] memory **关闭**时零行为变化  
- [ ] memory **开启**后：write → 新 session 可检索 → delete 后不再注入  

## 对标

Aider repo map；Pi branching；Hyper memory  

## 相关

- [modules/memory.md](../modules/memory.md)  
- [architecture.md — 记忆词表](../architecture.md#memory-与记忆词表勿混)  
- [roadmap.md](../roadmap.md)  
