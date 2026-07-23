# Module: memory（Memory Core 端口 + Memory Repo）

| 项 | 内容 |
|----|------|
| 状态 | **stub / 未实现** |
| 前置 | **Phase H 完成**，尤其 [H4](../phases/H-harden.md)（四层 prompt + session schema + view≠transcript） |
| 阶段 | [C5 Context Engineering](../phases/C5-context.md) |
| 代码（规划） | `MemoryCore` 端口（可先 no-op）+ 后端 `.zag/memory/` |
| 成熟度 | L0 → L3（C5）；**不进 Phase H 出门条件** |
| 对标 | Hyper / Grok Build memory 抽象；Pi 长期偏好；不照搬云 thread |
| 分层位置 | [architecture — Memory Core](../architecture.md#memory-core端口与-memory-repo) |

## 词表（先分清再实现）

| 名称 | 含义 | 谁负责 |
|------|------|--------|
| **Transcript** | 单会话权威消息流 | [session-store](./session-store.md) |
| **Model view** | 发给模型的投影 | [context-compaction](./context-compaction.md) |
| **Compaction 摘要** | 会话内折叠历史 | H4 / context |
| **Repo map** | 工作区结构索引，按任务选文件 | C5（与 memory 并列，不是同一物） |
| **Memory Core** | Agent Core 上的**端口**（search/write/inject）；默认 **no-op** | 本模块 · 抽象 |
| **Memory Repo** | 端口的一种**后端**：跨 session 落盘、可审可删 | 本模块 · C5 实现 |

禁止把「截断 view」或「session JSONL」改名叫 Memory。  
**Memory Core ≠ Loop 内部状态**；由 Agent Core 在组 view 时调用端口，类似 Pi 的可插拔上下文变换点。

## Memory Core 端口（抽象，实现可晚）

目标形状（名称可调）：

```text
MemoryCore
  · enabled() bool                    // 默认 false
  · search(query, budget) → snippets  // 供 ephemeral 注入
  · write(entry) → id                 // 显式；可走 tool
  · delete(id) / wipe()
```

- H 阶段：可不存在代码，或存在 **NullMemory** 恒空实现。  
- C5：接 Memory Repo 后端；关闭时与 H 出口零行为变化。

## 不变式（C5 必须遵守）

1. **默认关闭。** `memory.enabled=false` 时零 I/O、零 prompt 注入、与 H 行为一致。  
2. **可审、可删、可导出。** 条目落盘人类可读；提供 list / delete / wipe。  
3. **不进 transcript 权威流。** Memory 只经 **ephemeral 或 project 层** 注入 view；禁止改写历史 user/assistant 行冒充发生过。  
4. **不存密钥。** 与 [workspace-sandbox](./workspace-sandbox.md) redact 规则一致；命中模式拒绝写入。  
5. **有预算。** 注入 token/条数上限；超限按优先级丢弃并记 trace。  
6. **显式写入。** 模型或用户触发 `memory_write`（名称可改）；禁止静默全盘抓取对话当记忆。

## 最小产品形状（C5 MVP）

```text
.zag/memory/
  index.jsonl          # 元数据：id, created, tags, source_session
  entries/<id>.md      # 正文（或 json）
```

| 操作 | 行为 |
|------|------|
| write | 一条可检索笔记（标题 + 正文 + 可选 tags） |
| search / list | 关键词或 tag；结果进 ephemeral |
| delete / wipe | 用户或 tool（需 permission） |

可选后续：embeddings 检索（`WireAdapter.embed` / `supportsEmbed`）——**不得**作为唯一路径；无向量时全文/tag 仍可用。

## 与 Repo map 的关系

| | Repo map | Memory Repo |
|--|----------|-------------|
| 关于 | 当前工作区**代码结构** | 用户/任务**长期事实与偏好** |
| 生命周期 | 随仓库变 | 跨 session，显式删 |
| 失败模式 | 找不到文件 | 长任务断片、重复交代偏好 |

C5 可先做 repo map，再做 memory；或并行，但**分模块、分开关**。

## L2/H

**无。** Phase H 不实现本模块。H4 只保证边界，使 C5 可安全挂载。

## L3 验收（C5）

- [ ] 关闭时与 H 出口行为 diff 为空（零行为变化）  
- [ ] 开启后：写入 → 新 session 能检索到 → 删除后不再注入  
- [ ] 注入出现在 view/trace，不污染 transcript 历史行  
- [ ] 密钥类内容拒绝入库  
- [ ] 有条数/字符预算与测试  

## 非目标

- 云端同步 / 多机 memory  
- 企业知识库 / RAG 平台  
- 静默「记住所有对话」  
- 替代 AGENTS.md（项目规则仍走 project 层）  

## 实现顺序建议

```text
H4 出门
  → C5.1 repo map（可选优先，日用体感大）
  → C5.2 Memory Repo MVP（开关 + 落盘 + 注入 ephemeral）
  → C5.3 可选 embed 检索
```

## 相关

- [C5-context.md](../phases/C5-context.md)  
- [context-compaction.md](./context-compaction.md)  
- [session-store.md](./session-store.md)  
- [architecture.md](../architecture.md#memory-与记忆词表勿混)  
