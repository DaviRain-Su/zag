# Chapter 0 — 最小真理：Agent Loop

> 对应路线图 [Phase 0](../../docs/roadmap.md#phase-0--最小真理能跑的-loop)。  
> 代码已实现；本章是**跟着读代码的教程**，不是空路线。

**一句话：** 模型只是引擎；Code Agent 好不好，主要看 **harness**（循环、工具、回灌）。

---

## 0. 你将得到什么

做完本章，你手里有一个可运行的 CLI：

```
用户一句话 → 调模型 → 可能 call tool → 本地执行 → 结果回灌 → 循环直到结束
```

**Phase 0 只给两个只读 tool：** `list_dir`、`read_file`。  
**故意不做：** 写文件、shell、权限、会话落盘、MCP、TUI。

验收标准（roadmap）：

> 对一个小目录说：「这个项目有几个源文件？读一下 build 文件摘要。」  
> Agent **只靠 tool** 答对，且 `-v` 能看到 tool 序列。

---

## 1. 先跑起来（5 分钟）

需要：Zig **0.16**、任意兼容 OpenAI Chat Completions 的 API key。

```bash
cd /path/to/zag

# 推荐：DeepSeek（默认模型 deepseek-v4-flash）
export DEEPSEEK_API_KEY=sk-...

# 可选：换模型 / 换 base
# export ZAG_MODEL=deepseek-v4-pro
# export ZAG_BASE_URL=https://api.deepseek.com/v1

zig build test          # 离线单测（不调模型）
zig build run -- -v "这个项目有几个源文件？读一下 build.zig 摘要。"
```

无参数进入 REPL：

```bash
zig build run -- -v
# you> ...
```

Key 优先级（见 `src/provider/config.zig`）：

| 顺序 | 环境变量 | 默认 base | 默认 model |
|------|----------|-----------|------------|
| 1 | `ZAG_API_KEY` | 需配合 `ZAG_BASE_URL`，否则 xAI | `ZAG_MODEL` 或 grok |
| 2 | `DEEPSEEK_API_KEY` | `https://api.deepseek.com/v1` | **`deepseek-v4-flash`** |
| 3 | `XAI_API_KEY` | `https://api.x.ai/v1` | `grok-4-latest` |
| 4 | `OPENAI_API_KEY` | `https://api.openai.com/v1` | `gpt-4o-mini` |

`ZAG_BASE_URL` / `ZAG_MODEL` 可覆盖**任意** preset。

`-v` 时 stderr 类似：

```text
info: provider preset=deepseek base_url=https://api.deepseek.com/v1 model=deepseek-v4-flash
info: tool_call list_dir({"path": "."})
info: tool_result list_dir: ...
info: tool_call read_file({"path": "build.zig"})
info: completed in N turn(s)
```

若最终答案里有目录结构，但 **没有** 上述 tool 行——说明模型在瞎编，harness 没被用上（检查 system prompt / tools 是否发出去）。

---

## 2. 心智模型（读代码前先画这张图）

```
                    ┌─────────────────────────────────────┐
                    │           messages[]                │
                    │  system / user / assistant / tool   │
                    └─────────────────┬───────────────────┘
                                      │
                                      ▼
                            ┌──────────────────┐
                            │  provider.chat   │  ← HTTP + JSON
                            │  (+ tools 定义)  │
                            └────────┬─────────┘
                                     │
                              assistant message
                                     │
                          ┌──────────┴──────────┐
                          │ 有 tool_calls？      │
                          └──────────┬──────────┘
                               no    │    yes
                               │     ▼
                               │  registry.execute
                               │  list_dir / read_file
                               │     │
                               │     ▼
                               │  role=tool 写回 messages
                               │     │
                               │     └──► 再 chat
                               ▼
                          输出 final_text
```

三个问题（实现时钉死答案）：

| 问题 | Phase 0 答案 |
|------|----------------|
| 谁决定 call tool？ | **模型**（在 completion 里返回 `tool_calls`） |
| 谁执行？ | **harness**（`agent/loop.zig` + `tool.Registry`） |
| 结果放哪？ | transcript 里 **`role=tool`**，带上 `tool_call_id` |

没有这三步，只是「会聊天的脚本」，不是 agent harness。

建议对照阅读：[Thorsten Ball — How to Build an Agent](https://ampcode.com/how-to-build-an-agent)（Go ~400 行同一故事）。

---

## 3. 仓库地图（代码落点）

```text
zag/
  chapters/00-loop/     ← 你在这里
  docs/roadmap.md       ← 四阶段总图
  docs/architecture.md  ← 协议与模块边界（随实现更新）
  src/
    main.zig            # CLI：参数、env、one-shot / REPL
    root.zig            # 包导出
    agent/
      message.zig       # Message / ToolCall / AssistantTurn
      tool.zig          # Definition、Registry、参数解析
      loop.zig          # 主循环（harness 心脏）
    provider/
      config.zig        # 从环境变量解析 key / base / model
      openai.zig        # Chat Completions 请求与解析
    runtime/
      fs_tools.zig      # list_dir、read_file 实现
```

分层原则（后面阶段也尽量守）：

- **`agent/`** — 协议与循环，尽量不直接碰 HTTP 细节  
- **`provider/`** — 「怎么跟模型说话」  
- **`runtime/`** — 「怎么跟本机世界说话」（FS、以后还有 process）  
- **`main.zig`** — 薄：接线，不塞业务

---

## 4. 逐文件导读

### 4.1 `message.zig` — transcript 长什么样

四种 role：`system` / `user` / `assistant` / `tool`。

- **assistant** 可以只带 `tool_calls`、content 为空  
- **tool** 必须带 `tool_call_id`，content 是工具输出字符串  

`ToolCall` 三个字段：`id`、`name`、`arguments`（**原始 JSON 字符串**，不是已解析的 struct）。  
为什么 arguments 保持字符串？因为模型给的就是字符串；执行时再 parse，失败也能把错误字符串回灌给模型。

### 4.2 `tool.zig` — 模型看见的 vs 本地执行的

模型看见的是 `Definition`：

- `name` / `description`  
- `parameters_json` — JSON Schema 字符串（OpenAI `function.parameters`）

本地还有 `Handler`：`(Context, arguments_json) → []u8`。

`Registry.execute`：**未知 tool 或执行失败 → 返回错误字符串，不炸 loop**。  
这样模型有机会改参数再试；Phase 0 故意选择「软失败」。

### 4.3 `fs_tools.zig` — 两个只读工具

| Tool | 参数 | 行为 |
|------|------|------|
| `list_dir` | `path` | 相对 cwd 列目录，`name\tkind` 每行一条 |
| `read_file` | `path` | 读文本；过大则截断并注明 |

注意 Phase 0 **没有路径 jail**（那是 Phase 3）。相对路径 + 工作区约定先够用。

### 4.4 `provider/openai.zig` — 一种线协议钉死

请求体核心字段：

- `model`  
- `messages`（含历史 tool 结果）  
- `tools`：`[{ "type":"function", "function":{ name, description, parameters } }]`

响应里我们关心：

```json
{
  "choices": [{
    "finish_reason": "tool_calls" | "stop" | ...,
    "message": {
      "content": "..." | null,
      "tool_calls": [{
        "id": "call_...",
        "function": { "name": "list_dir", "arguments": "{\"path\":\".\"}" }
      }]
    }
  }]
}
```

`config.zig` 只负责 **选哪家、哪个 model**；真正 HTTP 都走这一套 OpenAI 兼容形状。  
换 DeepSeek / xAI / OpenAI = 换 base_url + key + model，**不换 loop**。

### 4.5 `loop.zig` — harness 心脏

伪代码：

```text
for turn in 1..max_turns:
    turn = provider.chat(messages, tools)
    append assistant message
    if no tool_calls:
        return turn.content
    for each call:
        result = registry.execute(call)
        append tool message(call.id, result)
return error.MaxTurnsExceeded
```

实现细节（读代码时注意）：

- **长寿命 arena**：整段 transcript 的字符串  
- **每 turn 小 arena**：HTTP JSON 解析临时对象，解析完把需要的字段 dupe 进长 arena  
- `max_turns` 默认 20，防止模型死循环 call tool  

### 4.6 `main.zig` — 接线

1. 解析 `-v` / `-h` / prompt  
2. `provider_config.resolve(environ)`  
3. 有 prompt → `loop.runPrompt`；无 prompt → REPL（同一 `messages` 列表跨多轮用户输入）  

System prompt 要求模型：**优先用 tool，不要猜磁盘上的文件**。这是行为开关，不是装饰。

---

## 5. 数据流：一轮 tool call 的完整形状

发给模型（简化）：

```json
{
  "model": "deepseek-v4-flash",
  "messages": [
    { "role": "system", "content": "You are Zag..." },
    { "role": "user", "content": "这个项目有几个源文件？" }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "list_dir",
        "description": "...",
        "parameters": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] }
      }
    }
  ]
}
```

模型返回 `tool_calls` 后，transcript 追加：

```json
{ "role": "assistant", "content": null, "tool_calls": [ { "id": "call_1", "function": { "name": "list_dir", "arguments": "{\"path\":\".\"}" } } ] }
{ "role": "tool", "tool_call_id": "call_1", "content": "src\tdirectory\nbuild.zig\tfile\n..." }
```

再 `chat` 一次；模型可能继续 `read_file`，或直接用自然语言收尾。

---

## 6. 自己改一改（练习）

按兴趣选做，保持「每阶段只加一类能力」：

1. **加第三个只读 tool：`grep`**（或 `search_file`）——只读、参数 schema、handler、注册进 `phase0Tools`。  
2. **把 `max_turns` 做成 CLI 参数**（例如 `--max-turns 8`）。  
3. **把 system prompt 挪到文件**（例如 `prompts/phase0.txt`），体会「行为配置 vs 代码」。  
4. **故意关掉 tools 发一次请求**，对比模型是否开始瞎编目录——加深对 harness 的体感。

做完 1 仍然算 Phase 0；不要顺手加 `write_file`（那是 Chapter 1）。

---

## 7. 测试怎么跑、测什么

```bash
zig build test
```

当前覆盖（会随代码增长）：

| 区域 | 测什么 |
|------|--------|
| `tool.zig` | JSON 参数字段解析 |
| `fs_tools.zig` | 真读仓库 `build.zig` / 列目录 |
| `openai.zig` | 解析 text turn / tool_calls turn；组请求体含 tools |
| `config.zig` | DeepSeek preset、override、优先级、缺 key |

**不测**（Phase 0）：真实打 API（需要 key、不稳定）。端到端用手工 `zig build run -- -v "..."`。

---

## 8. 读完应能回答

- Tool 对模型暴露的是什么？（name + description + JSON schema）  
- 一轮里：谁决定 call、谁执行、结果放哪？  
- 为什么这叫 harness，而不是聊天脚本？  
- 换 DeepSeek / OpenAI 时，**哪一层**变了、哪一层不变？

---

## 9. 下一步

- 路线总图：[docs/roadmap.md](../../docs/roadmap.md)  
- 模块边界：[docs/architecture.md](../../docs/architecture.md)  
- **Phase 1**：`write_file` / `run_shell` + `ask` / `yolo` 权限  
- 参考链接：[docs/references.md](../../docs/references.md)

**Tag 建议：** `ch0-loop` / `phase-0`
