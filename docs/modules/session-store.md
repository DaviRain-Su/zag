# Module: session-store

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-agent-core/src/{session_store,transcript}.zig` |
| 成熟度 | L1 → **L2（H4 已落地）** → L3（fork/树，C5） |
| 对标 | Pi session；Hyper sessions；Nanocodex checkpoint |

## 不变式

1. Session 文件是恢复权威来源之一；与内存 transcript 一致策略成文。  
2. **必须有 schema 版本**；未知版本 → 明确错误，不静默解析。  
3. 可能含代码与命令输出：按敏感本地状态对待（gitignore）。

## Schema（L2）

JSONL 头部 + 消息行。头字段：

| 字段 | 说明 |
|------|------|
| `schema_version` | 整数，当前 **1**（亦写 legacy `v`） |
| `type` | 恒为 `zag_session` |
| `zag_version` | 写入时的包版本（可选） |
| `compaction_gen` | 视图压缩代数 |
| `compaction_summary` | 最近一次启发式摘要（可选） |
| 消息行 | `role` / `content` / `tool_calls` … |

未知 `schema_version` → `UnsupportedSchema`（不静默解析）。无头旧文件按 v1 加载。

### 迁移

- vN → vN+1：纯加字段则向前兼容；破坏性变更必须提供迁移函数或拒绝加载并提示。  
- 迁移失败不得损坏原文件（写临时文件再替换）。

## L2 验收

- [x] 新旧版本加载行为有测试（legacy `v`、无头、schema=99 拒绝）  
- [x] resume 后 tool 对仍然成对（既有 golden / roundtrip）  
- [x] 文档列出最小字段  

## L3

- branch / fork / 旁支会话（C5）  
- 与 subagent 子 transcript 索引（C6）  

## 非目标（H）

- 云同步  
- SQLite 强制（可后置）  

## Hyper 对照

- user-guide `17-sessions`  
