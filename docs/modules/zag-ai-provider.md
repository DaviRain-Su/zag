# Module: zag-ai-provider

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-ai/`；agent 适配 `src/agent/provider.zig` |
| 成熟度 | L1 → **L2（H6）** → L3（fallback/multi-key） |
| 对标 | Hyper models；Pi pi-ai；Nanocodex 行为合同 |

## 不变式

1. Harness 只依赖稳定 Provider 端口；线协议细节关在 zag-ai。  
2. Auth：env + 配置文件；H 不做 OAuth（可后置）。  
3. 可重试错误与不可重试错误分类稳定，供 loop 使用。

## 错误与重试（L2）

与现有错误集对齐并成文：

| Error | 重试？ |
|-------|--------|
| AuthenticationFailed | no |
| RateLimited | yes |
| Timeout | yes |
| ServerError | yes |
| BadRequest | no |
| InvalidResponse | no |

政策：最大次数、backoff 可配置；耗尽后上抛，trace 记录。

## Usage（L2）

- 每次 chat 的 prompt/completion tokens（若供应商返回）写入 turn 结果  
- session/trace 可聚合  

## 流式（L2 规格）

- `--stream` 可取消（与 loop cancel 对齐）  
- 不完整 tool_call 增量：组装完成前不执行 tool；取消则丢弃部分组装  
- 合同测试覆盖「最终 tool_calls 形状」  

## Contract tests（L2）

见 [quality/contracts.md](../quality/contracts.md)：至少一家 OpenAI-compat 固件，无网络。

## L2 验收

- [ ] 重试政策文档 = 代码  
- [ ] usage 出现在 trace 或 session 元数据  
- [ ] 流式取消规格有测试或明确 TODO 绑定 CI  
- [ ] contract 目录约定落地  

## L3

- provider fallback 链、multi-key  
- 非 Chat Completions 协议（Responses 等）按需  

## 非目标（H）

- 完整 OAuth 产品  
- 绑定单一云厂商  

## Hyper 对照

- `xai-grok-models`、sampler；user-guide 多 provider 章  
