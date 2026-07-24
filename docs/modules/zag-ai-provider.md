# Module: zag-ai-provider

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-ai/`；纯端口 `zag-agent-core/src/provider.zig`；桥 `zag-coding-agent/src/wire_provider.zig`；传输 `openai-zig`（OpenAI）/ `std.http`（Anthropic） |
| 成熟度 | **L1+**；deadline/cancel/partial Tool safety 已落地（h-provider-001）；L2 仍欠 redact 联动等 |
| 对标 | Hyper models；Pi pi-ai；Nanocodex 行为合同 |

## 包内分层

```text
zag-agent-core/provider.Provider     ← 纯端口（无 Client）
        ↑
zag-coding-agent/wire_provider       ← WireAdapter → Provider 桥
        → zag-ai
             factory.createWire · resolve · catalog · ChatOptions
                ├─ openai_compat → openai-zig
                └─ anthropic_messages → zag-ai `http` (`std` \| `-Dhttp_backend=curl`)
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
  (openai-zig resources)     (http facade: std \| curl)
```

| 项 | 现状 |
|----|------|
| Canonical 消息 | ✅ `types.Message` 等 |
| `factory.createWire` / `Resolved.createWire` | ✅ |
| `api_style` | ✅ presets + `ZAG_API_STYLE` / `ZAG_PROVIDER=anthropic` |
| OpenAI Chat Completions + SSE | ✅ `openai_compat`（唯一 openai-zig chat 消费者） |
| Anthropic Messages + SSE | ✅ `anthropic_messages` |
| 传输 | `openai-zig` / zag-ai `http` | 同一 `-Dhttp_backend=std\|curl`（[D-005](../decisions/complete/D-005-outbound-http-std-not-httpz.md) 已收口；默认 std） |
| 共享 `wire.Error` | ✅；`mapSdkError` 仅 OpenAI 适配器 |
| `WireAdapter.embed` | ✅ OpenAI 实现；Anthropic → `NotSupported` |
| presets / catalog | ✅ ~20 家表驱动预设；catalog curated（context / vision / reasoning） |
| Agent `if` 厂商 | 禁止（保持） |

### Wire 边界（故意收窄）

| 做 | 不做（近中期） |
|----|----------------|
| `openai_compat` + `anthropic_messages` | Google / Mistral-native / Bedrock / Vertex |
| env key 预设（OpenAI/Anthropic 系 + 兼容网关） | OAuth（Codex / Copilot） |
| JSON 模型表 → comptime `catalog_data.zig` + `cost.Ledger` | 运行时解析 JSON（不用） |
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
4. 配置密钥不进 verbose/trace/session 明文（与 H5 redact 对齐）。
5. 配置的 deadline 必须真正执行或在启动/调用时明确拒绝；禁止静默保存无效 `timeout_ms`。
6. Cancel/deadline 贯穿 Provider 与 stream；取消后的半截 Tool call 不进入 transcript 或执行。
7. 每次 provider attempt 只有一个 owner 负责重试，避免 transport 与 loop 组合造成未记录的重试爆炸。

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
| JSON catalog → comptime | `data/models/*.json` + `scripts/generate_catalog.py` → `catalog_data.zig` |
| Cost 账本 | `cost.zig` + Agent `ledger`（CLI 汇总 / trace `run_end`） |
| Contract 雏形 | `packages/zag-ai/src/contract_tests.zig`（无网络） |
| Multimodal / embed | `ContentPart`；`WireAdapter.embed` |

## 错误与重试（政策 = 代码）

| Error | 重试？ |
|-------|--------|
| AuthenticationFailed | no |
| RateLimited | yes |
| **Timeout** | **no**（端到端 deadline / 配置超时；预算不按 attempt 重置） |
| **Cancelled** | **no** |
| ServerError | yes |
| HttpFailed | yes（loop 层；且仍在 deadline 预算内） |
| BadRequest | no |
| InvalidResponse | no |
| NotSupported | no |

政策：transport `max_retries` + loop `chat_retries` + `retry_base_delay_ms` 可配置（文件 / env）。**单 owner 重试**：loop 拥有 chat 重试；Timeout/Cancelled 永不按 generic provider failure 重试。

## Usage

- ✅ turn 级 usage（供应商返回时）
- ✅ trace 事件（含 turn `usage`；`run_end` 可带累计 tokens / `estimated_usd`）
- ✅ Agent `cost.Ledger`：每 chat turn 记账；CLI one-shot / REPL 结束打印汇总
- ❌ session JSONL 元数据里持久化 usage（仍待）

## Deadline / cancel / 流式（h-provider-001）

### Capability model（诚实边界）

| Backend | Ordinary no-timeout HTTP | Configured deadline / `timeout_ms` | Active in-flight cancel | Cooperative cancel flag only |
|---------|--------------------------|------------------------------------|-------------------------|------------------------------|
| **std** (D-005 default) | ✅ works | `UnsupportedControl` **before network** | `UnsupportedControl` if `require_active_cancel` | preflight + between-chunk only (**not** bounded active abort) |
| **curl** | ✅ | ✅ `CURLOPT_TIMEOUT_MS` remaining budget | ✅ xferinfo abort | same (active) |

- Default `timeout_ms=null` imposes **no** timeout on either backend.
- No silent store of ineffective timeout; no unsafe std cross-thread connection shutdown.
- **L2 for controlled lifecycle is backend-capability L2**: production deadline/active-cancel needs curl (`-Dhttp_backend=curl`).

### RequestControl 合同（L0）

- `deadline_mono_ns` + borrowed `*CancelFlag` + `require_active_cancel`.
- `needsEnforcedLifecycle()` → std fail closed; curl enforces.
- Loop sole retry owner for agent chat (wire `max_retries=0` on provider path).
- Timeout/Cancelled/UnsupportedControl never retried; deadline budget end-to-end.

### Stream completion / atomic tool turns

- OpenAI: explicit SSE `[DONE]` required; premature EOF / leftover event → error; no fabricated done.
- Anthropic: explicit `message_stop` required; malformed SSE JSON fails whole turn.
- Before return: every tool call nonempty id/name + arguments complete JSON **object**; any invalid slot rejects entire turn.

### Terminals

- `cancelled` ok=true; `timeout` ok=false; `unsupported_control` ok=false; auth/transport `provider_error`.

## Contract tests

见 [quality/contracts.md](../quality/contracts.md)。

- ✅ 包内 `contract_tests.zig`（含 loopback 慢服务器 timeout/cancel；双后端）
- ❌ 独立 fixture 目录命名仍待收口（行为已在包内 CI）

## L2 验收（H6 出门）

- [x] WireAdapter + 至少两家 style。
- [x] retry/error/usage 的基础 contract fixtures 无网络运行。
- [x] usage 出现在 trace，并可聚合 cost ledger。
- [x] 每个公开 timeout 配置都被执行（std+curl）；默认 null 不意外超时。
- [x] cancel/deadline 贯穿 Provider、adapter、std/curl stream。
- [x] 取消/超时后的不完整 Tool call 不进入执行，并有 CI fixture。
- [x] Timeout/Cancelled 不重试；deadline 跨 attempt 共享。
- [ ] contract fixture 目录与 CI 门禁命名仍可再收口。
- [ ] 与 H5：密钥不出现在 verbose/trace/session。

Session usage metadata是后续可加字段，不优先于 persistence correctness。勾满本表后才升 L2。

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
