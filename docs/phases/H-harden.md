# Phase H — Production Floor（硬化）

| 项 | 内容 |
|----|------|
| 状态 | **规格**（实现未完成） |
| 前置 | Teaching Phase 0–3 tutorial-complete |
| 目标 | 全体关键子系统 → [maturity L2](../maturity.md) |
| 非目标 | subagent、MCP、OS sandbox、TUI（属 C 轨） |

## 原则

1. **加深已有表面**，不新增产品品类。  
2. 每切片：规格 → 实现 → 回写 maturity → 至少 1 条测试/golden。  
3. 出门条件见 maturity「L2 总验收」。

---

## H1 — Loop

**规格：** [modules/loop-turn.md](../modules/loop-turn.md)

- 统一 tool 错误形状：可机读 `code` + `message`（字符串仍可给人/模型读）  
- cancel：SIGINT → 干净结束当前 turn，transcript 一致  
- `max_turns` / 超时可配置且写入 trace  
- 并行策略成文：只读可并、写串行（实现可分期，规格先钉）  
- Golden ≥2：只读问答；拒绝写文件  

## H2 — Edit

**规格：** [modules/tools-edit.md](../modules/tools-edit.md)

- **钉死：** 默认编辑路径 = `search_replace` + **内容锚点**（Hyper hashline 简化版）；`write_file` 保留给新建/小文件  
- `grep` / `glob` 进默认 toolset，受 jail + result budget  
- 写后可选 `git diff` 回灌（runtime 辅助）  
- 禁止「生产默认只有整文件 overwrite」作为唯一编辑路径  

## H3 — Permissions

**规格：** [modules/permissions.md](../modules/permissions.md)

- 按 tool 类别矩阵：read / write / shell  
- 会话内 remember：同 path 二次写可跳过确认（可关）  
- plan 模式**产品语义**占位：只读 + 允许写 plan 文件；完整实现可落 C6，H 必须写清不变式  

## H4 — Context / Session

**规格：** [context-compaction.md](../modules/context-compaction.md)、[session-store.md](../modules/session-store.md)

- prompt 四层：system / project / session / ephemeral  
- compaction 最小版：超限 → 结构化摘要 + 保留最近 N；算法与落盘格式成文  
- session schema 版本号 + 迁移规则  
- transcript（权威）≠ model-view（投影）边界写死  

## H5 — Safety

**规格：** [workspace-sandbox.md](../modules/workspace-sandbox.md)

- shell policy **必须用例表** + 单测  
- secret redact：API key 模式不进 verbose/trace/session 明文  
- 文档明确：**尚非 OS sandbox**；C7 边界  
- readiness/doctor 最小：探测 `zig build test` 脚本或 `build.zig`、`AGENTS.md` 是否存在  

## H6 — Provider（zag-ai）

**规格：** [zag-ai-provider.md](../modules/zag-ai-provider.md)

- 错误分类与重试政策成文（与代码 `isRetryableError` 对齐）  
- usage 记入 session/trace  
- 流式取消与不完整 tool_call 组装规格  
- ≥1 家 OpenAI-compat contract test 目录约定（见 [quality/contracts.md](../quality/contracts.md)）  

## H7 — Trace

**规格：** [trace-observability.md](../modules/trace-observability.md)

- 事件 schema 版本化  
- 必须能复盘：permission / jail_deny / shell_deny / usage / 停因  
- 与 [SECURITY.md](../../SECURITY.md) 交叉链接  

---

## 建议实现顺序

```text
H1 + H7（错误与审计底座）
  → H2 + H3（编辑与权限）
    → H4（上下文）
      → H5 + H6（安全与模型）
        → Quality CI 绿灯 → 回写 maturity 全 L2
```

## 对照读码（一次一个）

- Hyper：tools 编辑 / hashline **或** shell session turn  
- Pi：session vs compaction 边界叙述  

## 相关

- [chapters/H-harden](../../chapters/H-harden/README.md)  
- [roadmap.md](../roadmap.md)  
- [quality/evals.md](../quality/evals.md)  
