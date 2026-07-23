# Chapter H — Production Floor（硬化）

> 对应 [Phase H](../../docs/phases/H-harden.md)。  
> **状态：planned** — 规格已写；实现与本节「先跑起来」同步后更新命令与代码路径。  
> Teaching 0–3 = tutorial-complete；本章目标 = **maturity L2**。

**一句话：** 不堆新功能表面；把已有 loop / edit / session / safety / provider / trace 补到**敢日用**的底线。

---

## 0. 读之前

1. [docs/maturity.md](../../docs/maturity.md) — 看清 L1→L2  
2. [docs/phases/H-harden.md](../../docs/phases/H-harden.md) — H1–H7 清单  
3. 对应 [docs/gaps/](../../docs/gaps/) — 各 Teaching 章缺口  

---

## 1. 业务心智（在 Phase 3 三道门上加「可回归」）

```text
Teaching: 能演示
    ↓
H: 错误可机读 · 编辑可局部 · 上下文可压缩 · 密钥可脱敏 · 行为可 CI
    ↓
对外文案才允许：「单用户本机生产底线」
```

三道门仍在：`permission → jail → shell policy → execute`。  
H 要求每道门的失败都进**版本化** trace，且有测试钉住。

---

## 2. 切片与规格（实现时按此读）

| 切片 | 规格 | 主要代码（现状） |
|------|------|------------------|
| H1 Loop | [modules/loop-turn.md](../../docs/modules/loop-turn.md) | `src/agent/loop.zig` |
| H2 Edit | [modules/tools-edit.md](../../docs/modules/tools-edit.md) | `src/runtime/edit_tools.zig` |
| H3 Permissions | [modules/permissions.md](../../docs/modules/permissions.md) | `src/agent/permissions.zig` |
| H4 Context/Session | [context-compaction](../../docs/modules/context-compaction.md) · [session-store](../../docs/modules/session-store.md) | `context.zig` · `session_store.zig` |
| H5 Safety | [workspace-sandbox.md](../../docs/modules/workspace-sandbox.md) | `workspace.zig` · `shell_policy.zig` |
| H6 Provider | [zag-ai-provider.md](../../docs/modules/zag-ai-provider.md) | `packages/zag-ai/` + `provider.zig`（retry/usage **部分已有**） |
| H7 Trace | [trace-observability.md](../../docs/modules/trace-observability.md) | `src/agent/trace.zig`（usage 事件雏形） |

**明确不做（本章）：** Memory Repo、repo map、subagent、MCP —— 见 [memory.md](../../docs/modules/memory.md) / Capability 轨。

---

## 3. 先跑起来（实现后填写）

```bash
# TODO(H): 替换为硬化后的验收命令
# zig build test
# zig build run -- --yolo -v --trace "…"
# cat .zag/traces/latest.jsonl
```

出门条件见 [maturity L2 总验收](../../docs/maturity.md#l2-总验收phase-h-出门条件)。

---

## 4. 读完应能回答

- 为什么 Teaching「边界雏形」章（目录名 03-production）仍不是生产完成？  
- L2 与 L3（Capability）边界在哪？（例：OS sandbox 属 C7）  
- 改 harness 时哪两类测试必须绿？

---

## 5. 下一步

- H 完成后进入 [C4 编辑锐度](../../docs/phases/C4-edit-sharpness.md)  
- Quality：[evals](../../docs/quality/evals.md) · [contracts](../../docs/quality/contracts.md)  
