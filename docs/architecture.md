# Zag 架构（随实现更新）

> 描述**当前代码**。Phase 0–3：loop → 编辑/权限 → 会话/context → **边界/策略/trace**。

## 分层

```text
CLI (main.zig)
    ↓
agent/  ★ 业务
  Agent · Session · loop
  permissions · workspace jail · shell_policy · trace
  context · project · session_store · Provider port · Toolset
    ↓
provider/  （模型接入，对齐 pi-ai 形状）
  presets → registry + auth_env → openai_compat (唯一线协议)
    + runtime/
    ↓
LLM · FS · shell
```

### Provider 扩展（OpenAI 格式 only）

| 文件 | 职责 |
|------|------|
| `provider/presets.zig` | 声明式 `ProviderSpec` 表（加厂商加一行） |
| `provider/auth_env.zig` | 从 env 取 API key（无 OAuth） |
| `provider/registry.zig` | 探测 / `ZAG_PROVIDER` / 自定义 endpoint |
| `provider/openai_compat.zig` | 唯一线协议：Chat Completions + tools |

加厂商：在 `presets.builtin` 追加一条，无需改 resolve 分支。

## 工具执行三道门（Phase 3）

```text
permission (HITL) → workspace jail → shell policy → execute
```

| 模块 | 路径 | 职责 |
|------|------|------|
| permissions | `agent/permissions.zig` | ask / yolo |
| workspace | `agent/workspace.zig` | 相对路径 jail |
| shell_policy | `agent/shell_policy.zig` | 危险命令 denylist |
| trace | `agent/trace.zig` | JSONL 审计 |

## 业务入口

```zig
var agent = Agent.init(gpa, io, provider, .{
    .permission_mode = .ask,
    .shell_policy = .protect,
    .trace_path = ".zag/traces/latest.jsonl",
});
defer agent.deinit();
```

## 工具

| Tool | 门闩 |
|------|------|
| list_dir / read_file | jail |
| write_file | permission + jail |
| run_shell | permission + shell policy |

## 持久化

| 文件 | 内容 |
|------|------|
| `.zag/sessions/*.jsonl` | 对话 transcript |
| `.zag/traces/*.jsonl` | run 审计事件 |

## 版本

`zag.version` = **0.3.0**（见 `src/root.zig` / `build.zig.zon`）。

## 安全说明

见仓库根 [SECURITY.md](../SECURITY.md)。

## 相关章节

- [00-loop](../chapters/00-loop/README.md)  
- [01-edit-permissions](../chapters/01-edit-permissions/README.md)  
- [02-session-context](../chapters/02-session-context/README.md)  
- [03-production](../chapters/03-production/README.md)  
