# Modules — 规格索引

每页模板：不变式 · API/事件 · 失败模式 · L2/L3 验收 · 对标 · 非目标。

## 代码映射表

规格页 ↔ 现状路径。实现 PR 若搬家，**先改本表**再改 maturity 证据列。

| 规格 | 阶段 | 现状路径 | 目标拆分（可选） |
|------|------|----------|------------------|
| [loop-turn.md](./loop-turn.md) | H1 | `src/agent/loop.zig`、`agent.zig` | 保持 |
| [tools-edit.md](./tools-edit.md) | H2 → C4 | `src/runtime/edit_tools.zig`、`fs_tools.zig`、`toolset.zig` | 可增 `tools/edit` 逻辑仍在 runtime |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | `edit_tools.zig` `run_shell`、`shell_policy.zig` | 保持 |
| [permissions.md](./permissions.md) | H3 | `src/agent/permissions.zig` | 保持 |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | `src/agent/context.zig`、`project.zig` | 保持 |
| [session-store.md](./session-store.md) | H4 → C5 | `src/agent/session_store.zig` | 保持 |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | `workspace.zig`、`shell_policy.zig` | C7 可增 runtime sandbox |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 | `packages/zag-ai/*`、`src/agent/provider.zig` | 已拆 openai-zig；zag-ai 保持窄面 |
| [trace-observability.md](./trace-observability.md) | H7 | `src/agent/trace.zig` | 保持 |
| [memory.md](./memory.md) | **C5**（前置 H4） | —（未实现） | `.zag/memory/` + agent 挂载点 |
| [subagents-oracle.md](./subagents-oracle.md) | C6 | — | agent 内 |
| [extensions.md](./extensions.md) | C8 | — | 独立 extensions 层 |

### 包边界速查

| 包 | 公开面（给上游用） | 内部 |
|----|-------------------|------|
| `openai-zig` | `Client`、resources、transport | generated OpenAPI |
| `zag-ai` | `resolve`、`WireAdapter`、`ChatOptions`、catalog | openai_compat |
| `zag-agent-core` | `loop`、**纯 `Provider` 端口**、session、permissions | 无 `Client` / 无 toolset 产品 |
| `zag-coding-agent` | `Agent`、`WireProvider`、toolset、runtime tools | 组装 core + wire |
| `src/main` | CLI | 产品壳 |

依赖单向：

```text
main → coding-agent → agent-core → zag-ai → openai-zig
                  ↘───────────→ zag-ai
```

详见 [architecture.md](../architecture.md#monorepo-包边界强制)。

---

## 模块列表

| 模块 | 阶段 | 说明 |
|------|------|------|
| [loop-turn.md](./loop-turn.md) | H1 | harness 主循环 |
| [tools-edit.md](./tools-edit.md) | H2 → C4 | 编辑 / grep / glob |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | shell 执行 |
| [permissions.md](./permissions.md) | H3 | 权限矩阵 / plan 语义 |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | 四层 prompt / 压缩 |
| [session-store.md](./session-store.md) | H4 → C5 | 会话落盘 / schema |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | jail / policy / redact |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 + WireAdapter | 模型接入；**适配器预留**（OpenAI 先） |
| [trace-observability.md](./trace-observability.md) | H7 | 审计 trace |
| [memory.md](./memory.md) | C5 stub | Memory Repo（跨 session；默认可关） |
| [subagents-oracle.md](./subagents-oracle.md) | C6 stub | 子代理 / Oracle |
| [extensions.md](./extensions.md) | C8 stub | Skills / Hooks / MCP |

总览：[../maturity.md](../maturity.md) · [../phases/H-harden.md](../phases/H-harden.md) · [../phases/C5-context.md](../phases/C5-context.md)  
