# Zag 生产成熟度矩阵

> **真理源。** 其他文档对「做到哪了」有争议时，以本文件为准。  
> 更新规则：实现合并后回写「现状」列；新能力先补 L2/L3 验收句再写代码。

| Level | 含义 |
|-------|------|
| **L0** | 无 / 玩具 |
| **L1** | 教程可演示（Teaching Phase 0–3 多数停在这） |
| **L2** | **生产底线**（[Phase H](./phases/H-harden.md) 目标）：日用可信、可审计、可回归 |
| **L3** | 工业锐度（Capability / Hyper·omp 级） |

**总状态（文档日）：** Teaching = L1 齐；Production Floor = **未达 L2**（主线 Phase H）；Capability = 未开始。  
**局部进度：** Provider / Trace 有 L1+ 接线（ChatOptions、retry、usage 事件、catalog 预算），**未**满足 L2 出门句。

> 等级规则：只有 L2 验收句**全部**可演示 + 有证据，才把「现状」升到 L2。部分完成写在「证据」列，不提前升格。

---

## 矩阵

图例：单元格为当前自评等级。证据路径相对于仓库根。

| 子系统 | 现状 | 证据 | L2 验收（一句话） | L3 方向 | 对标 |
|--------|:----:|------|-------------------|---------|------|
| Loop / Turn | L1 | `packages/zag-agent-core/src/loop.zig`（含 `chatWithRetry`） | 统一可机读 tool 错误；cancel 干净结束；max_turns/超时进 trace；≥2 golden | 并行只读、steer、Turn 生命周期 | Pi loop；Nanocodex Turn |
| Tools · read | L1 | `packages/zag-coding-agent/src/runtime/fs_tools.zig` | jail 内 list/read 稳定；大文件截断可解释 | LSP 诊断闭环 | Hyper tools |
| Tools · write/edit | L1 | `packages/zag-coding-agent/src/runtime/edit_tools.zig`（整文件 write） | 默认路径含 **search_replace + 内容锚点**；stale 可恢复；非唯一 overwrite | hashline 级；diff review UX | Hyper hashline；omp |
| Tools · search | L0 | — | `grep` + `glob` 在 jail 内，结果有 budget | AST / codebase-graph | Hyper；Aider |
| Tools · shell | L1 | `edit_tools.zig` `run_shell` | 超时/截断/exit code 统一形状；policy 测试矩阵绿 | 后台 job + monitor | Hyper background |
| Permissions | L1 | `packages/zag-agent-core/src/permissions.zig` | 按 tool 类矩阵；会话内 remember 同 path | plan mode 产品化；细粒度 path 规则 | Hyper permissions |
| Workspace / Sandbox | L1 | `workspace.zig` + `shell_policy.zig` | jail + denylist + **secret redact** + `/doctor` 最小；SECURITY 诚实 | OS sandbox（seatbelt/bwrap） | Hyper sandbox；Codex |
| Context / Compaction | L1 | `context.zig`（截断 + catalog 预算） | 四层 prompt；超限 compaction（摘要+最近 N）落盘可解释 | repo map；智能选文件；**Memory 挂载点** | Pi；Aider；Hyper |
| Session / Resume | L1 | `session_store.zig` | schema 版本 + 迁移；transcript≠view 边界写死 | session 树 / fork / 旁支 | Pi；Nanocodex fork |
| Provider / zag-ai | L1+ | `packages/zag-ai/`、`provider.zig`；retry/usage/ChatOptions/contract_tests 已接；流式取消与 session 账本未齐 | 错误分类+重试成文；usage 进 session/trace；流式取消规格；contract 目录约定 | fallback / multi-key；多协议 | Hyper models；omp |
| Trace / Observability | L1+ | `trace.zig`（usage / provider_retry 事件） | schema 版本化；能复盘 permission/jail/shell/usage | dashboard；费用透视 | Hyper dashboard |
| Memory Repo | L0 | 规格 [modules/memory.md](./modules/memory.md) | （H 不做）C5：默认关；可审可删；注入 ephemeral | embed 检索可选 | Hyper memory |
| Subagents / Oracle | L0 | — | （H 不做）C6：typed 子代理 + Oracle pin + 对话点名触发 | Advisor；worktree fan-out | Amp；Hyper design-oracle |
| Extensions | L0 | — | （H 不做）C8：Skills 目录可加载 | Hooks + MCP + plugin 包 | Pi；goose；Hyper |
| UX | L1 | `packages/zag-cli/src/cli.zig`（main 为薄入口）；**已知 bug：`--trace` 可选参会吞掉 prompt**（`--trace "list_dir ."` 把 prompt 当路径） | headless 友好 exit code + **稳定 flag（修 `--trace` 歧义）**；文档与行为一致 | TUI；ACP | Hyper pager；Codex |
| Quality / Evals | L0 | 包测 + 少量 harness 单测 | H 起：golden + security eval 可 CI | edit eval；cost 基线 | Nanocodex contracts |

---

## 按 Teaching 阶段对照

| Teaching | 教程目标 | 多数子系统落点 | 生产缺口文档 |
|----------|----------|----------------|--------------|
| Phase 0 | 可跑 loop | Loop/Tools-read = L1 | [gaps/00-loop.md](./gaps/00-loop.md) |
| Phase 1 | 能写 + 权限门 | write/shell/permissions = L1 | [gaps/01-edit.md](./gaps/01-edit.md) |
| Phase 2 | 会话续聊 + view | session/context = L1 | [gaps/02-session.md](./gaps/02-session.md) |
| Phase 3 | jail + policy + trace | workspace/trace = L1 | [gaps/03-safety.md](./gaps/03-safety.md) |
| **Phase H** | 全体抬到 **L2** | 见 [phases/H-harden.md](./phases/H-harden.md) | — |

---

## L2 总验收（Phase H 出门条件）

全部为真才可在对外文案写「生产底线（单用户本机）」：

1. 编辑默认路径不是「唯一整文件 overwrite」。  
2. `grep`/`glob` 可用且受 jail。  
3. tool 错误可机读；permission/jail/shell deny 进版本化 trace。  
4. prompt 四层 + 最小 compaction；session 有 schema 版本。  
5. API key 不出现在 verbose/trace/session 明文（redact）。  
6. shell policy 与 jail 有固定测试矩阵。  
7. ≥2 条 golden transcript + ≥1 条 security eval 在 CI。  
8. `SECURITY.md` / `maturity.md` / README 叙事一致：不声称 OS sandbox 已具备。

---

## 维护

- 实现 PR：若改变某行等级，必须改本表「现状」与证据路径。  
- Capability 阶段完成某 L3 项时，把「L3 方向」迁到「现状」并注明阶段 ID（C4…）。  
- 与 [vision.md](./vision.md) 冲突时以 vision 的「刻意不做」为准，降级或标 wont。  
