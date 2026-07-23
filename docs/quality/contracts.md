# Quality: Provider Behavior Contracts

> 锁的是 **线协议与组装行为**，不是某个模型的智商。  
> 对标 Nanocodex「行为合同」思想；落在 `packages/zag-ai`。

## 为何需要

多 provider / 流式 / tool_calls 增量时，harness 回归常被「偶发 JSON」掩盖。合同测试用**固定字节流**断言解析结果。

## L2（H6）约定

| 项 | 要求 |
|----|------|
| 位置 | **已有** `packages/zag-ai/src/contract_tests.zig`；可增 `testdata/contracts/` 固件 |
| 网络 | **禁止** CI 打外网 |
| 最少覆盖 | 非流式 chat + tools；流式拼接后最终 `tool_calls` 形状 |
| 供应商 | ≥1 家 OpenAI-compat（DeepSeek 或 OpenAI 固件） |

现状：包内 contract 测试已覆盖 turn 解析 / request body / 错误分类；H6 收口补流式固件与目录约定说明。

## 断言示例

- `choices[0].message.tool_calls[].function.name`  
- arguments 为合法 JSON 对象字符串  
- usage 字段映射到 zag-ai `Usage`  
- 可重试错误分类与 HTTP 状态映射  

## L3

- 每启用一家正式 provider，加一份固件  
- 流式取消半截 tool_call 不执行  

## 相关

- [modules/zag-ai-provider.md](../modules/zag-ai-provider.md)  
- [evals.md](./evals.md)  
