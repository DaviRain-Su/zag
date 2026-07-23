# Zag 架构（随实现更新）

> 原则：文档描述**当前已存在的代码**，不写空头设计。  
> Phase 0 范围：只读 tool loop + OpenAI 兼容 provider。

## 目标

用 Zig 实现一个可演进的 **coding agent harness**：

- 教程：按章节长出来，每阶段可运行、可验收  
- 工程：边界清晰，后续能加权限、会话、沙箱而不推翻 loop  

**模型可替换；harness 是产品。**

## 模块图（Phase 0）

```text
                 ┌──────────── main.zig ────────────┐
                 │  CLI / env / REPL / one-shot      │
                 └───────┬───────────────┬───────────┘
                         │               │
              provider_config         agent.loop
                         │               │
                         ▼               ▼
                 openai.Client ◄── messages[] + tools[]
                         │               │
                    HTTPS JSON           ▼
                   (chat/completions)  tool.Registry
                                         │
                                         ▼
                                      fs_tools
                                   list_dir/read_file
```

| 模块 | 路径 | 职责 | 非职责 |
|------|------|------|--------|
| CLI | `src/main.zig` | 参数、环境、启动 loop | 业务协议细节 |
| Message | `src/agent/message.zig` | transcript 类型 | 序列化到 HTTP |
| Tool | `src/agent/tool.zig` | 定义 + 注册表 + 参数辅助 | 具体 FS/网络 |
| Loop | `src/agent/loop.zig` | turn 循环、回灌 | HTTP、权限策略 |
| Config | `src/provider/config.zig` | key/base/model 解析 | 发请求 |
| Provider | `src/provider/openai.zig` | Chat Completions 编解码 | tool 执行 |
| FS tools | `src/runtime/fs_tools.zig` | 只读目录/文件 | agent 策略 |

## 协议约定（Phase 0）

### Message

| role | 关键字段 |
|------|----------|
| `system` / `user` | `content` |
| `assistant` | `content`；可选 `tool_calls[]` |
| `tool` | `tool_call_id` + `content`（工具输出） |

`ToolCall`：`id`、`name`、`arguments`（JSON **字符串**）。

### Tool 定义（发给模型）

OpenAI function tools：

```json
{
  "type": "function",
  "function": {
    "name": "...",
    "description": "...",
    "parameters": { /* JSON Schema object */ }
  }
}
```

### Provider 配置

环境变量解析见 `provider/config.zig`。默认 DeepSeek 模型：**`deepseek-v4-flash`**。

线协议固定为 OpenAI 兼容；换厂商不换 loop。

## 内存（Phase 0 实践）

- Juicy Main：`init.gpa` / `init.arena` / `init.io`  
- Loop：长寿命 arena 存 transcript；每 turn 子 arena 做 JSON 解析  
- Tool 输出先用 GPA 分配，再 dupe 进 transcript arena  

后续若引入会话落盘（Phase 2），再单独定 ownership 边界。

## 演进预告（未实现）

| Phase | 预期增量 | 可能新模块 |
|-------|----------|------------|
| 1 | write / shell + 权限 | `runtime/process.zig`、`agent/permissions.zig` |
| 2 | 会话、context、项目说明 | `agent/session.zig`、`agent/context.zig` |
| 3 | jail、日志、稳定配置 | `runtime/sandbox.zig`、`SECURITY.md` |

每阶段**只加一类能力**；对照工业实现（Hyper / goose）只读一个子系统。

## 相关

- [roadmap.md](./roadmap.md)  
- [chapters/00-loop](../chapters/00-loop/README.md)  
- [references.md](./references.md)  
