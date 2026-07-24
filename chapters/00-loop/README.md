# Chapter 0 — 最小真理：Agent Loop

> 对应 Teaching [Phase 0](../../docs/roadmap.md#phase-0--最小真理loop)。  
> **状态：tutorial-complete**（不是 production-ready）。  
> **先读业务，再读基础设施。** Zig 样板已封装；你的注意力应在 harness。

**一句话：** 模型只是引擎；Code Agent 好不好，主要看 **harness**。

---

## 0. 先跑起来

```bash
export DEEPSEEK_API_KEY=sk-...   # 默认 model: deepseek-v4-flash

zig build test
zig build run -- -v "这个项目有几个源文件？读一下 build.zig 摘要。"
```

验收：stderr 出现 `tool_call list_dir` / `read_file`，答案来自 tool 而非臆测。

---

## 1. 业务心智模型

```
transcript ──► provider.chat ──► assistant
     ▲                               │
     │                          tool_calls?
     │                          no → 结束
     │                          yes ↓
     └──────── 执行 tool，role=tool 回灌 ──┘
```

| 问题 | 答案 |
|------|------|
| 谁决定 call tool？ | **模型** |
| 谁执行？ | **harness**（`loop.zig`） |
| 结果放哪？ | **transcript**（`role=tool`） |

---

## 2. 只看业务：该读哪些文件？

按这个顺序读（短 → 完整故事）：

> 0.5.0 拆包后路径：core = `packages/zag-agent-core/src`，coding = `packages/zag-coding-agent/src`。

| 顺序 | 文件 | 你在看什么 |
|------|------|------------|
| 1 | core `message.zig` | 消息 / tool_call 领域类型 |
| 2 | core `transcript.zig` | 账本：append user/assistant/tool |
| 3 | core `loop.zig` | **harness 主循环（核心业务）** |
| 4 | coding `agent.zig` | `Agent` / `Session` 外观 |
| 5 | core `tool.zig` + coding `toolset.zig` | tool 契约与 Phase0 工具包 |
| 6 | core `provider.zig` | 模型端口（纯 vtable，无 HTTP） |
| 7 | core `observer.zig` | 可选事件（`-v`） |

**先不要读**（除非你在修协议/IO）：

- `packages/zag-ai/` — 线协议与厂商表（openai_compat / presets / registry）  
- coding `runtime/fs_tools.zig` — 具体怎么读磁盘  
- `packages/zag-cli/src/cli.zig` + `src/main.zig` — CLI 壳  

分层图见 [architecture.md](../../docs/architecture.md)。

---

## 3. 核心业务代码长什么样？

`Agent` 对外只暴露两句业务话：

```zig
var agent = Agent.initPhase0(gpa, io, client.provider(), .{ .verbose = true });

// 多轮会话
var session = try Session.start(gpa, system_prompt);
defer session.deinit();
const result = try agent.reply(&session, user_text);

// 或 one-shot
const owned = try agent.complete(system_prompt, user_text);
```

`loop.run` 的主干（逻辑摘要）：

```text
while turns < max:
    turn = provider.chat(transcript)
    transcript.appendAssistant(turn)
    if no tool_calls: return text
    for call in tool_calls:
        out = tools.execute(call)
        transcript.appendToolResult(call.id, out)
```

内存 dupe、HTTP、JSON schema 字符串**不在这条主线上出现**。

---

## 4. 封装对照表（样板藏哪了？）

| 样板 | 封装位置 | 业务侧看到 |
|------|----------|------------|
| arena / dupe 消息 | `Transcript` | `appendUser` / `appendAssistantTurn` |
| HTTP + JSON | `openai_compat.Client` | `Provider.chat` |
| env 选 key/model | `provider/config.zig` | `main` 解析一次 |
| 装 list_dir/read_file | `Phase0Storage` / `Agent.initPhase0` | `agent.reply` |
| stderr 日志（产品路径） | `logEventRedacted`（Agent verbose） | `Options.verbose`；低层 bypass 为 `Observer.stderrLogUnredacted`（非产品默认） |
| CLI flag | `main.zig` | 不进 loop |

---

## 5. Tool 业务契约

模型看见：`name` + `description` + JSON Schema。  
本地执行：`Handler(ctx, arguments_json) → []u8`。  
失败：**字符串错误回灌**，loop 不崩——模型可改参数再试。

Phase 0 工具：

| 名 | 作用 |
|----|------|
| `list_dir` | 列目录 |
| `read_file` | 读文本（可截断） |

---

## 6. Provider 可替换

Harness 只依赖 `agent/provider.zig` 的 vtable。  
DeepSeek / xAI / OpenAI 都是 **同一 OpenAI 兼容线协议** + 不同 base/key/model。

默认 DeepSeek：`deepseek-v4-flash` @ `https://api.deepseek.com/v1`。  
覆盖：`ZAG_MODEL` / `ZAG_BASE_URL`。

单元测试里可以塞 Mock Provider（见 `loop.zig` 测试），**不打网也能测业务**。

---

## 7. 练习（仍只动业务层）

1. 读 `loop.zig`，手画一张状态图（与第 1 节对照）。  
2. 在 **不改 loop** 的前提下，给 Toolset 加第三个只读 tool（改 `fs_tools` + `Phase0Storage` 数组长度）。  
3. 写一个测试 Observer：断言「至少发生过一次 `list_dir`」（挂在 Options.observer）。  

不要在练习里加 `write_file`——那是 Chapter 1。

---

## 8. 读完应能回答

- 为什么 loop 不 import `std.http`？  
- Transcript 和「messages 数组」差在哪？  
- 换模型厂商时，业务层改哪、不改哪？  
- 谁决定 call tool？谁执行？结果放哪？

---

## 9. 生产缺口

Teaching 验收只证明「loop 能跑」。离 L2 见 **[docs/gaps/00-loop.md](../../docs/gaps/00-loop.md)**（可机读错误、cancel、golden、流式稳健等）。成熟度总表：[maturity.md](../../docs/maturity.md)。

---

## 10. 下一步

- **[Chapter 1 — 编辑 + 权限](../01-edit-permissions/README.md)**（tutorial-complete）  
- 硬化主线：[Chapter H](../H-harden/README.md) / [Phase H](../../docs/phases/H-harden.md)  
- [architecture.md](../../docs/architecture.md) · [roadmap.md](../../docs/roadmap.md)  
- 外部对照：Ball *How to Build an Agent*
