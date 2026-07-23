# Zag 架构（随实现更新）

> 描述**当前代码**。Phase 0–1：只读 + 编辑/shell + 权限。业务与样板分离。

## 分层

```text
┌──────────────────────────────────────────────────┐
│  main.zig     CLI：flag / env / --ask|--yolo     │
└───────────────────────────┬──────────────────────┘
                            │
┌───────────────────────────▼──────────────────────┐
│  agent/           ★ 业务层                         │
│    Agent · Session · loop · Transcript            │
│    permissions.Gate · Provider · Toolset · Observer│
│    message · tool                                 │
└────────────┬───────────────────────┬─────────────┘
             │                       │
┌────────────▼──────────┐  ┌─────────▼─────────────┐
│  provider/            │  │  runtime/             │
│  openai + config      │  │  fs_tools · edit_tools│
└───────────────────────┘  └───────────────────────┘
```

## 业务入口

| 类型 | 路径 | 一句话 |
|------|------|--------|
| `Agent` | `agent/agent.zig` | tools + provider + **permission gate** |
| `Session` | `agent/agent.zig` | transcript 生命周期 |
| `loop.run` | `agent/loop.zig` | chat → **gate** → tool → 回灌 |
| `permissions` | `agent/permissions.zig` | ask / yolo · risk · decide |
| `Transcript` | `agent/transcript.zig` | 消息账本 |
| `Provider` | `agent/provider.zig` | 模型端口 |
| `Toolset` | `agent/toolset.zig` | Phase1：四工具 |
| `Observer` | `agent/observer.zig` | tool / permission 事件 |

### 调用形状

```zig
var agent = Agent.init(gpa, io, client.provider(), .{
    .verbose = true,
    .permission_mode = .ask, // or .yolo
});
var session = try Session.start(gpa, system_prompt);
defer session.deinit();
const result = try agent.reply(&session, user_text);
```

## 权限（Phase 1）

```text
tool_call → riskOf(name)
  read            → allow
  write/execute   → ask? human : yolo allow
  deny            → tool message "permission denied…" (soft)
```

| 风险 | 工具 |
|------|------|
| read | `list_dir`, `read_file` |
| write | `write_file` |
| execute | `run_shell` |

CLI：`--ask`（默认）、`--yolo`、`-p ask|yolo`。

## 工具一览

| Tool | 模块 | 权限 |
|------|------|------|
| `list_dir` | `runtime/fs_tools.zig` | read |
| `read_file` | `runtime/fs_tools.zig` | read |
| `write_file` | `runtime/edit_tools.zig` | write |
| `run_shell` | `runtime/edit_tools.zig` | execute |

## 协议

| role | 字段 |
|------|------|
| system/user | content |
| assistant | content；可选 tool_calls |
| tool | tool_call_id + content（成功、失败、**拒绝** 都走这里） |

默认模型（DeepSeek preset）：`deepseek-v4-flash`。

## 内存

| 对象 | 策略 |
|------|------|
| Session | heap Arena → transcript 字符串 |
| 每 turn | 临时 arena 给 provider |
| Tool 输出 | GPA → dupe 进 transcript |

## 演进

| Phase | 增量 |
|-------|------|
| 2 | 会话落盘、context、AGENTS.md |
| 3 | 路径 jail、命令策略、结构化 trace |

## 相关

- [chapters/00-loop](../chapters/00-loop/README.md)  
- [chapters/01-edit-permissions](../chapters/01-edit-permissions/README.md)  
- [roadmap.md](./roadmap.md)  
