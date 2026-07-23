# Zag 架构（随实现更新）

> 原则：文档描述**当前已存在的代码**。  
> Phase 0：只读 tool loop；**业务与样板分离**。

## 分层（先看业务）

```text
┌──────────────────────────────────────────────────┐
│  main.zig          CLI 壳：flag / env / 打印      │
└───────────────────────────┬──────────────────────┘
                            │
┌───────────────────────────▼──────────────────────┐
│  agent/            ★ 业务层（教程主线）            │
│    Agent · Session · loop · Transcript           │
│    Provider(port) · Toolset · Observer           │
│    message · tool                                │
└────────────┬───────────────────────┬─────────────┘
             │                       │
┌────────────▼──────────┐  ┌─────────▼─────────────┐
│  provider/            │  │  runtime/             │
│  openai HTTP+JSON     │  │  fs_tools             │
│  config (env presets) │  │  （本机能力）           │
└───────────────────────┘  └───────────────────────┘
```

**打开 `agent/loop.zig` 应只看到 harness 业务，不看到 HTTP / 双 arena 样板。**

## 业务入口

| 类型 | 路径 | 一句话 |
|------|------|--------|
| `Agent` | `agent/agent.zig` | 装好 tools + provider，暴露 `reply` / `complete` |
| `Session` | `agent/agent.zig` | 一段对话的 transcript 生命周期 |
| `loop.run` | `agent/loop.zig` | chat → tool → 回灌，直到模型停 |
| `Transcript` | `agent/transcript.zig` | 消息账本（字符串所有权关在这里） |
| `Provider` | `agent/provider.zig` | 模型端口（vtable），不绑死某一家 |
| `Toolset` | `agent/toolset.zig` | Phase 0 只读工具包 |
| `Observer` | `agent/observer.zig` | 可选事件（`-v` 日志） |

### 调用形状（业务）

```zig
var agent = Agent.initPhase0(gpa, io, client.provider(), .{ .verbose = true });
var session = try Session.start(gpa, system_prompt);
defer session.deinit();
const result = try agent.reply(&session, user_text);
// result.final_text
```

## 基础设施（可以后读）

| 模块 | 路径 | 职责 |
|------|------|------|
| OpenAI 兼容客户端 | `provider/openai.zig` | HTTP、JSON 编解码；实现 `Provider` |
| 环境配置 | `provider/config.zig` | key / base / model preset |
| FS tools | `runtime/fs_tools.zig` | `list_dir` / `read_file` 实现 |

## 协议（Phase 0）

| role | 关键字段 |
|------|----------|
| `system` / `user` | `content` |
| `assistant` | `content`；可选 `tool_calls[]` |
| `tool` | `tool_call_id` + `content` |

`ToolCall`：`id`、`name`、`arguments`（JSON 字符串）。

默认 DeepSeek 模型：`deepseek-v4-flash`。

## 内存约定

| 对象 | 策略 |
|------|------|
| `Session` | heap 上 `ArenaAllocator`，transcript 字符串全在其中 |
| 每 turn | 临时 arena 给 provider 解析；需要留下的字段 dupe 进 transcript |
| Tool 输出 | GPA 分配 → dupe 进 transcript → free GPA 缓冲 |

## 演进预告

| Phase | 增量 | 业务层怎么长 |
|-------|------|----------------|
| 1 | write / shell + 权限 | 扩 Toolset + `permissions` 钩进 loop 执行前 |
| 2 | 会话落盘、context | 扩 `Session` / Transcript 策略 |
| 3 | jail、trace | Observer → 结构化 trace；runtime sandbox |

## 相关

- [chapters/00-loop](../chapters/00-loop/README.md)  
- [roadmap.md](./roadmap.md)  
