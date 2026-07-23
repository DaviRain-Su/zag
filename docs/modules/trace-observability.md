# Module: trace-observability

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-agent-core/src/{trace,observer}.zig` |
| 成熟度 | L1 → **L2（H7）** → L3（dashboard，C9） |
| 对标 | Hyper telemetry/dashboard；SECURITY 审计 |

## 不变式

1. Trace 是审计与复盘通道，不是 debug println。  
2. Schema 必须版本化；读方校验版本。  
3. 与 transcript 互补：trace 偏事件，transcript 偏对话内容。  
4. 经 redact 后再写盘（见 workspace-sandbox）。

## Schema（L2）

文件头或每行含 `schema_version`（或 `run_start` 带版本）。

**kind 最小集（L2）：**

`run_start` · `turn` · `assistant` · `tool_call` · `tool_result` · `permission` · `jail_deny` · `shell_deny` · `usage` · `run_end`

`run_end` 必含：`turns`、`ok`、`stop_reason`。

## L2 验收

- [ ] 拒绝写文件的路径能在 trace 看到 permission 或等价  
- [ ] jail/shell deny 可复盘  
- [ ] usage 至少在有供应商数据时出现  
- [ ] SECURITY.md 指向本 schema  

## L3

- 本地 dashboard（会话/费用/子代理）  
- 与 CI artifact 上传约定  

## 非目标（H）

- 云端遥测强制  

## Hyper 对照

- user-guide `23-dashboard`、`24-monitoring-usage`  
