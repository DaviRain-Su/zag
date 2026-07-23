# Module: context-compaction

| 项 | 内容 |
|----|------|
| 代码 | `src/agent/context.zig`、`project.zig` |
| 成熟度 | L1（截断）→ **L2（H4）** → L3（repo map，C5） |
| 对标 | Pi session/compaction；Aider repo map；Hyper compaction |

## 不变式

1. **Transcript 权威；view 是投影。** 禁止在 loop 里直接砍 transcript 数组当「压缩」。  
2. 项目约定（AGENTS.md）必须在压缩后仍可到达模型（system/project 层）。  
3. 压缩可解释：trace 或 session 记录「触发了 compaction」。

## 四层 Prompt（L2）

| 层 | 内容 | 生命周期 |
|----|------|----------|
| system | 身份、安全、tool 使用政策 | 进程/配置 |
| project | AGENTS.md、项目规则 | 工作区 |
| session | 用户长期偏好、压缩摘要 | 会话文件 |
| ephemeral | 本 turn 提醒、doctor、Oracle 建议 | 单 turn |

`viewForModel` = 组装四层 + 选取的历史消息尾部。

## Compaction 最小算法（L2）

1. 触发：估计 token 或消息数超阈值（配置项）。  
2. 动作：将「中间历史」折叠为一条 `role=system` 或 session 摘要消息；**保留**最近 N 条原始消息；**保留**所有 system/project。  
3. 摘要可先用启发式（拼接决策句），L2 不强制再调 LLM；若用 LLM 摘要须可关。  
4. 落盘：session 中记录 `compaction_gen` 与摘要文本。

## L2 验收

- [ ] 四层在文档与代码注释对齐  
- [ ] 超限触发 compaction；摘要后项目规则仍在  
- [ ] 全量 transcript 仍可从磁盘读到压缩前要点或摘要  

## L3（C5）

- repo map（工作区索引；见 [C5](../phases/C5-context.md)）  
- 智能选文件  
- **跨 session Memory Repo** 挂载点：只经 ephemeral/project 注入；规格见 [memory.md](./memory.md)  

H4 必须为 C5 留好的边界：transcript 权威、view 可重建、session schema 可版本化。

## 非目标（H）

- 完美语义压缩  
- 云端记忆  
- Memory Repo 实现（属 C5，默认关）  

## Hyper / Pi 对照

- Pi：turn snapshot vs config 边界  
- Hyper：compaction 入口（只读）  

