# Module: session-store

| 项 | 内容 |
|----|------|
| 代码 | `src/agent/session_store.zig`、`transcript.zig` |
| 成熟度 | L1 → **L2（H4）** → L3（fork/树，C5） |
| 对标 | Pi session；Hyper sessions；Nanocodex checkpoint |

## 不变式

1. Session 文件是恢复权威来源之一；与内存 transcript 一致策略成文。  
2. **必须有 schema 版本**；未知版本 → 明确错误，不静默解析。  
3. 可能含代码与命令输出：按敏感本地状态对待（gitignore）。

## Schema（L2 目标）

JSONL 或头部 JSON 元数据至少包含：

| 字段 | 说明 |
|------|------|
| `schema_version` | 整数，从 1 起 |
| `zag_version` | 写入时的包版本 |
| `created_at` / `updated_at` | 可选 ISO 或 unix |
| 消息行 | 与 message 类型兼容 |

### 迁移

- vN → vN+1：纯加字段则向前兼容；破坏性变更必须提供迁移函数或拒绝加载并提示。  
- 迁移失败不得损坏原文件（写临时文件再替换）。

## L2 验收

- [ ] 新旧版本加载行为有测试  
- [ ] resume 后 tool 对仍然成对  
- [ ] 文档列出最小字段  

## L3

- branch / fork / 旁支会话（C5）  
- 与 subagent 子 transcript 索引（C6）  

## 非目标（H）

- 云同步  
- SQLite 强制（可后置）  

## Hyper 对照

- user-guide `17-sessions`  
