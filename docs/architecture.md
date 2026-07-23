# Zag 架构

> 描述**当前代码**与**目标分层**。成熟度等级见 [maturity.md](./maturity.md)。  
> Teaching Phase 0–3 = 骨架已落地；Production Floor（Phase H）= 规格已写、实现未齐。

## 现状分层

```text
CLI (main.zig)
    ↓
agent/  ★ 业务（L1 骨架）
  Agent · Session · loop
  permissions · workspace jail · shell_policy · trace
  context · project · session_store · Provider port · Toolset
    ↓
packages/zag-ai/  模型接入（OpenAI Chat Completions）
  presets · catalog · registry · auth_env
  openai_compat · stream · config_file
    ↓
runtime/  FS · shell 实现
    ↓
LLM · 本地磁盘 · /bin/sh
```

### 工具执行三道门（已有）

```text
permission (HITL) → workspace jail → shell policy → execute
```

全部 soft-fail 回灌模型。

| 模块 | 路径 | 现状等级 |
|------|------|----------|
| permissions | `agent/permissions.zig` | L1 ask/yolo |
| workspace | `agent/workspace.zig` | L1 path jail |
| shell_policy | `agent/shell_policy.zig` | L1 denylist |
| trace | `agent/trace.zig` | L1 JSONL |
| context | `agent/context.zig` | L1 截断 view |
| edit | `runtime/edit_tools.zig` | L1 整文件 write |

## 目标分层（对齐 Hyper 切分，不抄名）

```text
┌─────────────────────────────────────────────────────┐
│ UX：CLI / headless /（C9）TUI / ACP                   │
├─────────────────────────────────────────────────────┤
│ agent/  harness                                       │
│  loop·turn · permissions · plan · context · session │
│  （C6）subagent·oracle ·（C8）hooks 挂载点            │
├──────────────┬──────────────────┬───────────────────┤
│ tools        │ zag-ai           │ runtime           │
│ edit·grep    │ providers·stream │ fs·shell·sandbox  │
│ shell·web*   │ catalog·contract │ worktree*         │
├──────────────┴──────────────────┴───────────────────┤
│ extensions*：skills · hooks · MCP · plugins（C8）     │
└─────────────────────────────────────────────────────┘
* = Capability，非 Phase H
```

| 能力 | 位置 | 阶段 |
|------|------|------|
| 厂商表 / catalog | `packages/zag-ai` | 有；H6 硬化 |
| 可靠编辑 | `runtime` + toolset | H2 → C4 |
| OS sandbox | runtime + agent | C7 |
| Subagent / Oracle | agent | C6 |
| MCP / Skills | extensions | C8 |

## 业务入口（现状）

```zig
var agent = Agent.init(gpa, io, provider, .{
    .permission_mode = .ask,
    .shell_policy = .protect,
    .trace_path = ".zag/traces/latest.jsonl",
});
defer agent.deinit();
```

## 工具（现状 vs H2 目标）

| Tool | 现状 | H2+ |
|------|------|-----|
| list_dir / read_file | ✅ jail | 保持 |
| write_file | ✅ 整文件 | 保留；非唯一编辑路径 |
| search_replace | ❌ | ✅ 默认编辑 |
| grep / glob | ❌ | ✅ |
| run_shell | ✅ policy | 统一错误形状 |

## 持久化

| 文件 | 内容 | H4+ |
|------|------|-----|
| `.zag/sessions/*.jsonl` | transcript | schema_version |
| `.zag/traces/*.jsonl` | 审计事件 | schema_version + usage |
| `.zag/config.json` | 非密钥配置 | 已有雏形 |

## 版本叙事

- 包版本见 `src/root.zig` / `build.zig.zon`。  
- **版本号 ≠ 生产就绪。** 生产底线以 [maturity L2 总验收](./maturity.md#l2-总验收phase-h-出门条件) 为准。

## 安全

见 [SECURITY.md](../SECURITY.md)。OS sandbox **未**实现。

## 相关

- [roadmap.md](./roadmap.md) · [vision.md](./vision.md) · [modules/](./modules/)  
- Teaching 章 [chapters/](../chapters/) · 硬化章 [H-harden](../chapters/H-harden/README.md)  
