# Module: zag-ai-provider

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-ai/`；纯端口 `zag-agent-core/src/provider.zig`；桥 `zag-coding-agent/src/wire_provider.zig`；传输 `openai-zig`（OpenAI）/ `std.http`（Anthropic） |
| 成熟度 | **H6 大半完成（L1+）**；L2 出门尚欠 session 账本 / 流式取消测试 / redact 联动 |
| 对标 | Hyper models；Pi pi-ai；Nanocodex 行为合同 |

## 包内分层

```text
zag-agent-core/provider.Provider     ← 纯端口（无 Client）
        ↑
zag-coding-agent/wire_provider       ← WireAdapter → Provider 桥
        → zag-ai
             factory.createWire · resolve · catalog · ChatOptions
                ├─ openai_compat → openai-zig
                └─ anthropic_messages → std.http only
```

| 层 | 路径 | 职责 |
|----|------|------|
| 纯端口 | `packages/zag-agent-core/src/provider.zig` | `Provider` vtable only |
| 组装桥 | `packages/zag-coding-agent/src/wire_provider.zig` | stream / options / ownership |
| Model plane | `packages/zag-ai` | WireAdapter、factory、resolve、contract |
| 协议实现 | `openai_compat` / `anthropic_messages` | 厂商 schema + SSE |

Harness **禁止**依赖 openai-zig 类型。总图见 [architecture.md](../architecture.md#目标分层总图钉死)。

## Wire Adapter（已落地）

对齐 Pi：`convertToLlm` + stream 事件映回统一形状。

```text
canonical: types.Message / ToolDefinition / ChatOptions
                │
                ▼
        WireAdapter (vtable)
          · api_style / name / deinit
          · chat / chatStream → AssistantTurn
          · embed → EmbeddingResult | NotSupported
                │
        ┌───────┴────────────────┐
        ▼                        ▼
  openai_compat              anthropic_messages
  (openai-zig resources)     (std.http only)
```

| 项 | 现状 |
|----|------|
| Canonical 消息 | ✅ `types.Message` 等 |
| `factory.createWire` / `Resolved.createWire` | ✅ |
| `api_style` | ✅ presets + `ZAG_API_STYLE` / `ZAG_PROVIDER=anthropic` |
| OpenAI Chat Completions + SSE | ✅ `openai_compat`（唯一 openai-zig chat 消费者） |
| Anthropic Messages + SSE | ✅ `anthropic_messages` |
| 共享 `Config` + `http.Client` | ✅ `http` 仅 `std.http` |
| 共享 `wire.Error` | ✅；`mapSdkError` 仅 OpenAI 适配器 |
| `WireAdapter.embed` | ✅ OpenAI 实现；Anthropic → `NotSupported` |
| presets / catalog | ✅ ~20 家表驱动预设；catalog curated（context / vision / reasoning） |
| Agent `if` 厂商 | 禁止（保持） |

### Wire 边界（故意收窄）

| 做 | 不做（近中期） |
|----|----------------|
| `openai_compat` + `anthropic_messages` | Google / Mistral-native / Bedrock / Vertex |
| env key 预设（OpenAI/Anthropic 系 + 兼容网关） | OAuth（Codex / Copilot） |
| curated model 表 + 预算 | 全量镜像 Pi `generate-models` + $/token 账本 |
| （规划）OpenAI Responses、图像生成 | 绑死单一云 |

### 不变式（适配层）

1. Agent Core / `loop` **永不** import 厂商 wire 类型。  
2. 错误分类在 adapter 边界映到统一 `Error` + `isRetryableError`。  
3. Usage / finish_reason / tool_calls 在 canonical `AssistantTurn` 上对齐。  
4. 流式：wire 增量 → 统一 `StreamEvent` 或组装后的 turn（流式**取消**测试仍属 H6 收口）。

## 不变式

1. Harness 只依赖稳定 Provider 端口；线协议细节关在 adapter / 协议包。  
2. Auth：env + 配置文件；H 不做 OAuth（可后置）。  
3. 可重试错误与不可重试错误分类稳定，供 loop 使用（`isRetryableError`）。  
4. 配置密钥不进 trace/session 明文（与 H5 redact 对齐；H6 配合）。

## 已落地（勿重复劳动）

| 能力 | 证据 |
|------|------|
| WireAdapter + factory | `wire.zig`、`factory.zig` |
| 双协议 | `openai_compat`、`anthropic_messages` |
| 错误分类 | `wire.Error` + `types.isRetryableError` |
| 传输层重试 | openai-zig / http `max_retries` / backoff |
| Loop 层重试 | `loop.chatWithRetry` + `chat_retries`；trace `provider_retry` |
| ChatOptions | temperature / max_tokens / tool_choice…；config + env |
| Usage | `AssistantTurn.usage`；trace `usage` 事件；verbose 日志 |
| Catalog 预算 | `catalog.contextBudgetChars` → `context.optionsForModel` |
| 多厂商 preset | `presets.builtin`（openai_compat + anthropic_messages only） |
| Contract 雏形 | `packages/zag-ai/src/contract_tests.zig`（无网络） |
| Multimodal / embed | `ContentPart`；`WireAdapter.embed` |

## 错误与重试（政策 = 代码）

| Error | 重试？ |
|-------|--------|
| AuthenticationFailed | no |
| RateLimited | yes |
| Timeout | yes |
| ServerError | yes |
| HttpFailed | yes（loop 层） |
| BadRequest | no |
| InvalidResponse | no |
| NotSupported | no |

政策：transport `max_retries` + loop `chat_retries` + `retry_base_delay_ms` 可配置（文件 / env）。

## Usage

- ✅ turn 级 usage（供应商返回时）  
- ✅ trace 事件  
- ❌ 尚未：session 级聚合账本、费用估算  

## 流式

- ✅ OpenAI / Anthropic SSE 组装为 turn  
- ❌ `--stream` 可取消（与 loop cancel 对齐）— **待 H1/H6 收口**  
- ❌ 取消时丢弃不完整 tool_call 的 CI 断言  

## Contract tests

见 [quality/contracts.md](../quality/contracts.md)。

- ✅ 包内 `contract_tests.zig`  
- ❌ 约定目录 / 多家 fixture / CI 门禁命名仍待收口  

## L2 验收（H6 出门）

- [x] WireAdapter + 至少两家 style  
- [x] 重试政策文档 = 代码  
- [x] usage 出现在 trace（turn 级）  
- [ ] usage 可选进入 session 元数据 / 聚合  
- [ ] 流式取消规格有测试或明确 TODO 绑定 CI  
- [ ] contract 目录约定落地并进 CI 说明  
- [ ] 与 H5：密钥不出现在 verbose/trace  

**结论：** 多协议 Model plane **已可用**；maturity Provider 行保持 **L1+**，勾满上表后升 **L2**。

## L3

- provider fallback 链、multi-key  
- **OpenAI Responses** WireAdapter（与 Completions 并存）  
- **图像生成**独立面（不进 chat loop）  
- Memory / RAG 用 embed 仅作可选后端，见 [memory.md](./memory.md)  

## 非目标（H）

- 完整 OAuth 产品  
- 绑定单一云厂商  
- Memory Repo（属 C5）  
- Graph 编排（属 C6；节点内仍用本 Provider 端口）  

## Hyper 对照

- `xai-grok-models`、sampler；user-guide 多 provider 章  
