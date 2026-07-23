# Module: zag-ai-provider

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-ai/`；适配 `src/agent/provider.zig`；传输 `packages/openai-zig/` |
| 成熟度 | L1 → **L1+ partial H6** → **L2（H6 收口）** → L3（fallback/multi-key） |
| 对标 | Hyper models；Pi pi-ai；Nanocodex 行为合同 |

## 包内分层

```text
agent/provider.Adapter
        → zag-ai.Client / stream / resolve
                → openai-zig transport + chat resources
```

| 层 | 路径 | 职责 |
|----|------|------|
| 端口 | `src/agent/provider.zig` | harness vtable；`chat_options` |
| 产品面 | `packages/zag-ai` | resolve、catalog 预算、ChatOptions、Usage、错误分类、embed、config |
| 协议面 | `packages/openai-zig` | HTTP 重试、SSE、OpenAPI |

Harness **禁止**依赖 openai-zig 类型。详见 [architecture 包边界](../architecture.md#monorepo-包边界强制)。

## 不变式

1. Harness 只依赖稳定 Provider 端口；线协议细节关在 openai-zig。  
2. Auth：env + 配置文件；H 不做 OAuth（可后置）。  
3. 可重试错误与不可重试错误分类稳定，供 loop 使用（`isRetryableError`）。  
4. 配置密钥不进 trace/session 明文（与 H5 redact 对齐；H6 配合）。

## 已落地（L1+，勿重复劳动）

| 能力 | 证据 |
|------|------|
| 错误分类 | `zag-ai` `openai_compat.Error` + `types.isRetryableError` |
| 传输层重试 | openai-zig transport `max_retries` / backoff |
| Loop 层重试 | `loop.chatWithRetry` + `chat_retries`；trace `provider_retry` |
| ChatOptions | temperature / max_tokens / tool_choice…；config + env |
| Usage | `AssistantTurn.usage`；trace `usage` 事件；verbose 日志 |
| Catalog 预算 | `catalog.contextBudgetChars` → `context.optionsForModel` |
| Contract 雏形 | `packages/zag-ai/src/contract_tests.zig`（无网络） |
| Multimodal / embed | `ContentPart`；`Client.embed`（agent 主路径未用） |

## 错误与重试（L2 政策 = 代码）

| Error | 重试？ |
|-------|--------|
| AuthenticationFailed | no |
| RateLimited | yes |
| Timeout | yes |
| ServerError | yes |
| HttpFailed | yes（loop 层） |
| BadRequest | no |
| InvalidResponse | no |

政策：transport `max_retries` + loop `chat_retries` + `retry_base_delay_ms` 可配置（文件 / env）。

## Usage（L2）

- ✅ turn 级 usage（供应商返回时）  
- ✅ trace 事件  
- ❌ 尚未：session 级聚合账本、费用估算  

## 流式（L2 规格 — 未齐）

- `--stream` 可取消（与 loop cancel 对齐）— **待 H1/H6**  
- 不完整 tool_call 增量：组装完成前不执行 tool；取消则丢弃部分组装  
- 合同测试覆盖「最终 tool_calls 形状」  

## Contract tests（L2）

见 [quality/contracts.md](../quality/contracts.md)。

- ✅ 包内 `contract_tests.zig`  
- ❌ 约定目录 / 多家 fixture / CI 门禁命名仍待收口  

## L2 验收（H6 出门）

- [x] 重试政策文档 = 代码（本页 + isRetryableError + loop）  
- [x] usage 出现在 trace（turn 级）  
- [ ] usage 可选进入 session 元数据 / 聚合  
- [ ] 流式取消规格有测试或明确 TODO 绑定 CI  
- [ ] contract 目录约定落地并进 CI 说明  
- [ ] 与 H5：密钥不出现在 verbose/trace  

**结论：** H6 **部分完成**；未全部勾选前 maturity 保持 **L1**（或文档写 L1+），不宣称 Provider L2。

## L3

- provider fallback 链、multi-key  
- 非 Chat Completions 协议（Responses 等）按需  
- Memory / RAG 用 embed 仅作可选后端，见 [memory.md](./memory.md)  

## 非目标（H）

- 完整 OAuth 产品  
- 绑定单一云厂商  
- Memory Repo（属 C5）  

## Hyper 对照

- `xai-grok-models`、sampler；user-guide 多 provider 章  
