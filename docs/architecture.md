# Zag 架构

> 描述**当前代码**与**目标分层**。成熟度等级见 [maturity.md](./maturity.md)。  
> Teaching Phase 0–3 = 骨架已落地；Production Floor（Phase H）= 规格已写、实现未齐。

## Monorepo 包边界（强制）

按**依赖方向与失败模式**拆，不按「文件多了就拆」。

```text
CLI (src/main.zig)
        │
        ▼
┌─────────────────── agent/ (harness) ───────────────────┐
│  loop · permissions · context · session · trace        │
│  Provider port · Toolset                               │
│  永不 import OpenAPI / HTTP 细节                         │
└────────────┬──────────────────────────┬────────────────┘
             │                          │
             ▼                          ▼
   packages/zag-ai/              src/runtime/
   agent 友好模型面               fs · shell（执行面）
   resolve · ChatOptions          永不知道 permission 矩阵
   stream · catalog · errors
             │
             ▼
   packages/openai-zig/
   线协议 · transport · OpenAPI 资源
   可独立复用；不知道 harness
```

| 包 / 目录 | 职责 | 可依赖 | **禁止**依赖 |
|-----------|------|--------|----------------|
| `packages/openai-zig` | HTTP、重试、SSE、OpenAPI 资源与生成类型 | std | zag-ai、agent、runtime |
| `packages/zag-ai` | 预设、catalog、resolve、Chat 面、错误分类、contract 测试 | openai-zig | agent、permissions、jail |
| `src/agent` | harness 业务：loop、权限、context、session、trace | zag-ai（窄面）、runtime tools | openai-zig 细节、OpenAPI 类型 |
| `src/runtime` | list/read/write/shell 实现 | std、Io | 模型协议、LLM 配置 |
| `src/main.zig` | CLI 组装 resolve → Client → Adapter → Agent | 上述全部（组装层） | — |

**一句话不变式：** harness 只看见 `Provider.chat` + `AssistantTurn`；线协议关在 openai-zig；厂商表/预算关在 zag-ai。

规格映射见 [modules/README.md](./modules/README.md#代码映射表)。

## 现状分层

```text
CLI (main.zig)
    ↓
agent/  ★ 业务（整体 L1；Provider 接线部分已超 L1）
  Agent · Session · loop
  permissions · workspace jail · shell_policy · trace
  context · project · session_store · Provider port · Toolset
    ↓
packages/zag-ai/  模型接入（OpenAI Chat Completions）
  presets · catalog · registry · auth_env · config_file
  openai_compat · stream · types（Usage / ChatOptions / ContentPart）
    ↓
packages/openai-zig/  传输与 OpenAPI
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
| trace | `agent/trace.zig` | L1 JSONL（含 usage / retry 事件雏形） |
| context | `agent/context.zig` | L1 截断 view + catalog 预算 |
| edit | `runtime/edit_tools.zig` | L1 整文件 write |
| provider 适配 | `agent/provider.zig` + zag-ai | L1+（选项/重试已接；H6 未齐） |

## 目标分层（对齐 Hyper 切分，不抄名）

```text
┌─────────────────────────────────────────────────────┐
│ UX：CLI / headless /（C9）TUI / ACP                   │
├─────────────────────────────────────────────────────┤
│ agent/  harness                                       │
│  loop·turn · permissions · plan · context · session │
│  （C5）memory 挂载点 ·（C6）subagent·oracle           │
│  （C8）hooks 挂载点                                   │
├──────────────┬──────────────────┬───────────────────┤
│ tools/runtime│ zag-ai           │ openai-zig        │
│ edit·grep    │ resolve·stream   │ transport·OpenAPI │
│ shell·web*   │ catalog·contract │ resources         │
│ sandbox*     │                  │                   │
├──────────────┴──────────────────┴───────────────────┤
│ extensions*：skills · hooks · MCP · plugins（C8）     │
└─────────────────────────────────────────────────────┘
* = Capability，非 Phase H
```

| 能力 | 位置 | 阶段 |
|------|------|------|
| 厂商表 / catalog / 预算 | `packages/zag-ai` | 有；**H6 收口** |
| 传输 / 全量 API 面 | `packages/openai-zig` | 独立维护 |
| 可靠编辑 | `runtime` + toolset | **H2** → C4 |
| 跨 session Memory Repo | agent + 可选存储 | **C5**（前置 H4） |
| OS sandbox | runtime + agent | C7 |
| Subagent / Oracle | agent | C6 |
| MCP / Skills | extensions | C8 |

## 业务入口（现状）

```zig
var resolve_result = try zag_ai.resolve(gpa, io, env, config_path);
// resolve_result.chat_options / model_info / chat_retries …

var client = Client.init(gpa, io, resolve_result.resolved.config);
var adapter = Adapter.init(client, stream);
adapter.chat_options = resolve_result.chat_options;

var agent = Agent.init(gpa, io, adapter.provider(), .{
    .permission_mode = .ask,
    .shell_policy = .protect,
    .context = context.optionsForModel(resolve_result.model_info, .{}),
    .chat_retries = resolve_result.chat_retries,
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

| 文件 | 内容 | 阶段 |
|------|------|------|
| `.zag/sessions/*.jsonl` | transcript | H4：schema_version |
| `.zag/traces/*.jsonl` | 审计事件 | H7：schema_version；已有 usage 雏形 |
| `.zag/config.json` | 非密钥配置 | 已有 chat/transport knobs |
| `.zag/memory/*`（规划） | 跨 session 记忆 | **C5**，默认关；见 [modules/memory.md](./modules/memory.md) |

## Memory 与「记忆」词表（勿混）

| 概念 | 是什么 | 阶段 |
|------|--------|------|
| Transcript | 会话权威消息日志 | Teaching 2；H4 版本化 |
| Model view | 发给模型的投影（可截断/压缩） | L1 截断；**H4** compaction |
| Repo map | 工作区结构索引，按任务选文件 | **C5** |
| Memory Repo | 跨 session 可审可删长期记忆 | **C5**，默认可关 |

H 阶段**不**交付 Memory Repo；只保证 session/view 边界够硬，C5 才挂记忆。

## 版本叙事

- 包版本见 `src/root.zig` / `build.zig.zon`。  
- **版本号 ≠ 生产就绪。** 生产底线以 [maturity L2 总验收](./maturity.md#l2-总验收phase-h-出门条件) 为准。

## 安全

见 [SECURITY.md](../SECURITY.md)。OS sandbox **未**实现。

## 相关

- [roadmap.md](./roadmap.md) · [vision.md](./vision.md) · [modules/](./modules/)  
- Teaching 章 [chapters/](../chapters/) · 硬化章 [H-harden](../chapters/H-harden/README.md)  
