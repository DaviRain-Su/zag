# Zag 架构（随实现更新）

> 描述**当前代码**。Phase 0–2：loop、编辑/权限、会话/项目/context。

## 分层

```text
┌──────────────────────────────────────────────────┐
│  main.zig     CLI：权限 / session / continue     │
└───────────────────────────┬──────────────────────┘
                            │
┌───────────────────────────▼──────────────────────┐
│  agent/           ★ 业务层                         │
│    Agent · Session · loop · Transcript            │
│    permissions · context · project · session_store│
│    Provider · Toolset · Observer · message · tool │
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
| `Agent` | `agent/agent.zig` | reply / complete；自动 save |
| `Session` | `agent/agent.zig` | transcript + 可选 path |
| `loop.run` | `agent/loop.zig` | **view** → chat → gate → tools |
| `context` | `agent/context.zig` | full vs model view |
| `project` | `agent/project.zig` | AGENTS.md → system |
| `session_store` | `agent/session_store.zig` | JSONL 持久化 |
| `permissions` | `agent/permissions.zig` | ask / yolo |
| `Transcript` | `agent/transcript.zig` | 消息账本 |

### 会话 + 项目

```zig
var session = try Session.start(gpa, io, .{
    .base_system = sys,
    .path = ".zag/sessions/default.jsonl",
    .continue_existing = true,
    .load_project_instructions = true,
});
defer session.deinit();
const result = try agent.reply(&session, user_text); // auto-save
```

## Context 策略（Phase 2）

- **Full transcript**：Session 内存 + JSONL  
- **Model view**：leading system + 尾部消息 + 字符预算；可插一条临时 system note  
- 不在 loop 里破坏 full 历史  

## 权限（Phase 1）

read 自动过；write/shell 在 ask 下确认；deny → soft tool error。

## 工具

| Tool | 风险 |
|------|------|
| list_dir, read_file | read |
| write_file | write |
| run_shell | execute |

## 会话 JSONL

```text
{"v":1,"type":"zag_session"}
{"role":"system"|"user"|"assistant"|"tool", ...}
```

## 演进

| Phase | 状态 |
|-------|------|
| 0 loop | ✅ |
| 1 edit + permissions | ✅ |
| 2 session + context | ✅ |
| 3 jail / trace / semver | 下一步 |

## 相关

- [chapters/00-loop](../chapters/00-loop/README.md)  
- [chapters/01-edit-permissions](../chapters/01-edit-permissions/README.md)  
- [chapters/02-session-context](../chapters/02-session-context/README.md)  
- [roadmap.md](./roadmap.md)  
