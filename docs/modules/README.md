# Modules — 规格索引

每页模板：不变式 · API/事件 · 失败模式 · L2/L3 验收 · 对标 · 非目标。

## 代码映射表

规格页 ↔ 现状路径。实现 PR 若搬家，**先改本表**再改 maturity 证据列。

| 规格 | 阶段 | 现状路径 | 目标拆分（可选） |
|------|------|----------|------------------|
| [loop-turn.md](./loop-turn.md) | H1 | `packages/zag-agent-core/src/loop.zig` | 保持 |
| [tool-runtime.md](./tool-runtime.md) | H/P0 **L2** → SDK | `zag-types` ToolDefinition + ToolCapabilities；core `tool.zig` | 保持定义/运行时分离 |
| [tools-edit.md](./tools-edit.md) | H2 → C4 | `zag-coding-agent/src/runtime/*`、`toolset.zig` | 保持在 coding-agent |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | runtime `run_shell` + core `shell_policy` | 保持 |
| [permissions.md](./permissions.md) | H3 **L2** | `zag-agent-core/.../permissions.zig` | 保持 |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | core `context`；coding `project` | 保持 |
| [session-store.md](./session-store.md) | H4 → C5 | core `session_store.zig` | 保持 |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | core `workspace` + `shell_policy` + `redact.zig` | C7 sandbox |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 | `zag-ai` + coding `wire_provider` | core 仅纯 Provider |
| [trace-observability.md](./trace-observability.md) | H7 | core `trace.zig` + redaction | 保持 |
| [memory.md](./memory.md) | **C5**（前置 H4） | —（未实现） | `.zag/memory/` + agent 挂载点 |
| [subagents-oracle.md](./subagents-oracle.md) | C6 | — | agent 内 |
| [extensions.md](./extensions.md) | C8 | — | 独立 extensions 层 |

### 包边界速查

| 包 | 公开面（给上游用） | 内部 |
|----|-------------------|------|
| `openai-zig` | `Client`、resources、transport | generated OpenAPI |
| `zag-ai` | `resolve`、`WireAdapter`、`ChatOptions`、catalog | openai_compat |
| `zag-types` | Message / ToolDefinition / ToolRisk / ToolCapabilities / ToolDescriptor / ChatError | — |
| `zag-agent-core` | `loop`、**纯 `Provider` 端口**、session、permissions、`redact` | 无 `Client` / 无 toolset 产品 / 无 zag-ai |
| `zag-coding-agent` | `Agent`、`WireProvider`、toolset、runtime tools | 组装 core + wire |
| `zag-cli` | flags / REPL / one-shot | 产品壳 |
| `src/main` | 进程入口 → `zag_cli.run` | 薄 |

依赖单向：

```text
# consumer → dependency
main → zag-cli → coding-agent → agent-core → zag-types
                         └────→ zag-ai ─┬→ zag-types
                                       └→ openai-zig
```

详见 [architecture.md](../architecture.md#monorepo-包边界强制)。

---

## 模块列表

| 模块 | 阶段 | 说明 |
|------|------|------|
| [loop-turn.md](./loop-turn.md) | H1 | harness 主循环 |
| [tool-runtime.md](./tool-runtime.md) | H/P0 → SDK | model definition / runtime capabilities / stateful handler |
| [tools-edit.md](./tools-edit.md) | H2 → C4 | 编辑 / grep / glob |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | shell 执行 |
| [permissions.md](./permissions.md) | H3 | 权限矩阵 / plan 语义 |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | 四层 prompt / 压缩 |
| [session-store.md](./session-store.md) | H4 → C5 | 会话落盘 / schema |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | jail / policy / redact |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 + WireAdapter | OpenAI-compatible + Anthropic；deadline/cancel contract |
| [trace-observability.md](./trace-observability.md) | H7 | 审计 trace |
| [memory.md](./memory.md) | C5 stub | Memory Repo（跨 session；默认可关） |
| [subagents-oracle.md](./subagents-oracle.md) | C6 stub | 子代理 / Oracle |
| [extensions.md](./extensions.md) | C8 stub | Skills / Hooks / MCP |

总览：[../maturity.md](../maturity.md) · [../phases/H-harden.md](../phases/H-harden.md) · [../phases/C5-context.md](../phases/C5-context.md)  
