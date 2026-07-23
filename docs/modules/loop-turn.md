# Module: loop-turn

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-agent-core/src/loop.zig` |
| 分层 | **Agent Core 内核**（[architecture 总图](../architecture.md#目标分层总图钉死)） |
| 成熟度 | L1 → **L2（H1）** → L3（C6 Turn/steer；Graph 节点内仍用本 Loop） |
| 对标 | Pi-agent-core loop；Nanocodex Turn |

## 不变式

1. 模型决定是否 `tool_calls`；harness 执行并回灌。  
2. Tool 失败 **soft-fail**（进 transcript），不崩进程。  
3. 发给模型的是 **context view**，不是任意截断后的权威账本。  
4. 一次 run 的停因可审计（max_turns / cancel / 正常结束 / provider 错）。

## 公共 API / 事件（目标）

- `run(deps, transcript) → Result { final_text, turns, stop_reason }`  
- `stop_reason`: `completed | max_turns | cancelled | provider_error`  
- Observer / Trace：`turn`、`tool_call`、`tool_result`、`run_end(stop_reason)`  

### Tool 错误形状（L2）

回灌字符串须可被测试解析，建议前缀或 JSON 行：

```text
error: code=<CODE> message=<human>
```

最少 `CODE`：`unknown_tool | invalid_arguments | permission_denied | jail_deny | shell_deny | tool_failed | cancelled`。

## 失败模式

| 场景 | 行为 |
|------|------|
| max_turns | 停止；trace `run_end`；Result 标明 |
| SIGINT | 不写半截 tool 对；stop_reason=cancelled |
| Provider 失败 | 可重试由 zag-ai；耗尽则 ProviderFailed |

## 并行策略（规格；实现可分期）

- 同一 assistant 消息内：仅 **只读** tools 可并行；含 write/shell 则串行。  
- L2 可先串行实现，但文档与测试注明策略。

## L2 验收

- [ ] 错误码稳定，golden 可断言 `permission_denied`  
- [ ] cancel 后 session 文件可 resume  
- [ ] max_turns 出现在 trace  
- [ ] ≥2 golden（只读；拒写）

## L3 方向

steer（中途纠偏）、并行只读落地、与 subagent 生命周期对齐（C6）。

## Loop vs Graph（边界）

| | Loop（本模块 / Phase H） | Graph（C6+ 编排，非本模块默认 runtime） |
|--|---------------------------|----------------------------------------|
| 适用 | 单 coding agent：模型选 tool → 执行 → 回灌 | 多角色 fan-out、handoff、条件汇合、组织拓扑 |
| 状态 | transcript + context view | 共享 state + 节点检查点 |
| 对标 | Pi agent-core loop；Claude Code 薄循环 | LangGraph / MS Agent Framework；Pi 不把 graph 做核 |

**H1 实现的是 loop，不是 workflow DAG。**  
图论/图工程若引入，挂在 C6（subagent/Oracle 编排），且每个节点内部仍可以是 loop。  
行业扫描见 [research/2026-harness-landscape.md](../research/2026-harness-landscape.md)。

## 非目标

- 分布式工作流引擎 / 把 `loop.run` 换成通用 graph runtime（H 阶段）  
- 多租户调度  

## 对照

- Pi：`packages/agent` agent-loop；`transformContext` → `convertToLlm`  
- Hyper：`xai-grok-shell` session / turn 入口（只读架构）  
