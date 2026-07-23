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

### Monorepo：`packages/zag-ai`（Grok Build 式拆分）

AI 模块独立于 agent harness，类似 hyper crates 分离：

```text
packages/zag-ai/          # 独立 Zig package
  types · presets · catalog · registry · auth_env
  openai_compat (非流) · stream (SSE) · config_file
src/agent/                # harness 业务
  provider.Adapter → 包装 zag-ai.Client（可选 stream）
```

| 能力 | 位置 |
|------|------|
| 厂商表 | `packages/zag-ai/src/presets.zig` |
| Model catalog | `packages/zag-ai/src/catalog.zig` |
| 配置文件 | `.zag/config.json` / `zag.json` / `--config` |
| SSE streaming | `packages/zag-ai/src/stream.zig` + CLI `--stream` |

加厂商：改 presets + catalog，无需改 harness。

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
