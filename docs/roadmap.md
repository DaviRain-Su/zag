# Zag 路线图

> Zig 载体；**harness** 主角。  
> 权威成熟度见 [maturity.md](./maturity.md)；定位见 [vision.md](./vision.md)。

## 诚实状态

| 轨道 | 状态 | 含义 |
|------|------|------|
| **Teaching** Phase 0–3 | ✅ tutorial-complete | 能学会、能演示；**不是** production-ready |
| **Production Floor** Phase H | ❌ 未完成 | 日用生产底线（L2）；**下一步主线** |
| **Capability** C4–C9 | 未开始 | 依赖 H；工业锐度 / 扩展 / 产品壳 |
| **Quality** | ❌ 未达标 | 从 H 起强制；golden + security + contracts |

```text
Teaching 0 → 1 → 2 → 3  ✅
                ↓
         Phase H（硬化到 L2）  ← 你在这里
                ↓
    C4 → C5 → C6 → C7 → C8 → C9
         ↕ Quality（横切）
```

**原则：** 完成 H 之前，文档与 README **禁止**写「已是生产级 / Phase 3 即生产完成」。

**主对照：** [Pi harness](https://github.com/earendil-works/pi)（session/compaction/extensions 包纪律）。  
**行业与缺口：** [research/2026-harness-landscape.md](./research/2026-harness-landscape.md)（先强 loop，graph 属 C6+）。  
**架构钉死：** [architecture.md](./architecture.md) — Loop⊂Graph、WireAdapter 预留、Memory Core 端口、产品壳。  
**WireAdapter：** 已落地（`wire.zig` + OpenAI 默认实现）；下一协议 = Anthropic 另开。

---

## Teaching Track（保留学习路径）

每阶段目标与旧版一致；**验收仅作 tutorial**。生产缺口见 `docs/gaps/`。

### Phase 0 — 最小真理（loop）

- **教程目标：** 用户话 → 模型 → tool → 回灌 → 结束。  
- **最少 tool：** `list_dir`、`read_file`。  
- **教程验收：** 小目录问答只靠 tool；transcript 可回放。  
- **章：** [chapters/00-loop](../chapters/00-loop/README.md)  
- **缺口：** [gaps/00-loop.md](./gaps/00-loop.md)

### Phase 1 — 真·Code（编辑 + 权限）

- **教程目标：** `write_file` / `run_shell` + `ask`|`yolo`。  
- **教程验收：** 批准后文件出现；拒绝则不改；deny soft-fail。  
- **章：** [chapters/01-edit-permissions](../chapters/01-edit-permissions/README.md)  
- **缺口：** [gaps/01-edit.md](./gaps/01-edit.md)

### Phase 2 — 日用雏形（会话 / context）

- **教程目标：** JSONL 续聊；`AGENTS.md`；超长截断 view。  
- **教程验收：** 两进程续暗号；project instructions 进 system。  
- **章：** [chapters/02-session-context](../chapters/02-session-context/README.md)  
- **缺口：** [gaps/02-session.md](./gaps/02-session.md)

### Phase 3 — 边界雏形（jail / policy / trace）

- **教程目标：** 路径 jail、shell denylist、JSONL trace。  
- **教程验收：** `/etc/passwd` 被拒；trace 可复盘序列。  
- **章：** [chapters/03-production](../chapters/03-production/README.md)（章名历史遗留；**≠ 生产完成**）  
- **缺口：** [gaps/03-safety.md](./gaps/03-safety.md)

### Teaching 对照读码

| 阶段结束 | 只读一个点 |
|----------|------------|
| 0 | Ball *How to Build an Agent* vs 自己的 loop |
| 1 | Aider 编辑策略 **或** Hyper permissionMode |
| 2 | Hyper sessions **或** Aider repo map 入口 |
| 3 | Hyper sandbox 文档 **或** goose 权限模型 |

---

## Phase H — Production Floor（主线）

**目标：** 不引入 subagent/MCP 等新表面；把已有 loop/edit/session/safety/provider/trace **抬到 L2**。

详设：[phases/H-harden.md](./phases/H-harden.md)  
教程骨架：[chapters/H-harden](../chapters/H-harden/README.md)

| 切片 | 抬升 | 模块规格 |
|------|------|----------|
| H1 Loop | 可机读错误、cancel、配置进 trace、golden | [modules/loop-turn.md](./modules/loop-turn.md) |
| H2 Edit | search_replace+锚点、grep/glob、写后 diff（**大半已落地**） | [modules/tools-edit.md](./modules/tools-edit.md) |
| H3 Permissions | 矩阵、remember、plan 语义占位 | [modules/permissions.md](./modules/permissions.md) |
| H4 Context/Session | 四层 prompt、compaction、schema 版本 | [modules/context-compaction.md](./modules/context-compaction.md)、[session-store.md](./modules/session-store.md) |
| H5 Safety | policy 矩阵、redact、doctor；明确非 OS sandbox | [modules/workspace-sandbox.md](./modules/workspace-sandbox.md) |
| H6 Provider | 收口：流式取消、session 文件元数据、contract 目录（retry/usage/ChatOptions/Ledger **已有**） | [modules/zag-ai-provider.md](./modules/zag-ai-provider.md) |
| H7 Trace | schema 版本、复盘字段齐全（usage 事件 **已有雏形**） | [modules/trace-observability.md](./modules/trace-observability.md) |

**出门条件：** [maturity.md § L2 总验收](./maturity.md#l2-总验收phase-h-出门条件)。

**对照读码：** Hyper `xai-grok-tools` 编辑路径 **或** shell session turn 入口（一次一个）。

---

## Capability Track（依赖 H）

每篇开头前提：**Phase H 完成**。规格到可开 issue 即可。

| ID | 主题 | 文档 | 失败模式 |
|----|------|------|----------|
| **C4** | 编辑锐度 | [phases/C4-edit-sharpness.md](./phases/C4-edit-sharpness.md) | 偏行、不敢 apply |
| **C5** | Context 工程 · **Memory Repo** | [phases/C5-context.md](./phases/C5-context.md) · [modules/memory.md](./modules/memory.md) | 长任务断片、上下文贵、重复交代 |
| **C6** | 编排 / Oracle | [phases/C6-orchestration.md](./phases/C6-orchestration.md) | 弱模型硬撑 |
| **C7** | 真沙箱增强 | [phases/C7-sandbox.md](./phases/C7-sandbox.md) | denylist 可绕过 |
| **C8** | 扩展面 | [phases/C8-extensions.md](./phases/C8-extensions.md) | 扩展必须改核心 |
| **C9** | 产品壳 | [phases/C9-product-shell.md](./phases/C9-product-shell.md) | 只能玩具 CLI |

相关模块 stub：[memory.md](./modules/memory.md)、[subagents-oracle.md](./modules/subagents-oracle.md)、[extensions.md](./modules/extensions.md)、[tools-shell.md](./modules/tools-shell.md)。

**建议顺序：** C4 → C5 → C6 → C7 → C8 → C9（编辑→上下文/记忆→Oracle→沙箱→扩展）。

### Memory Repo 排期（钉死）

```text
现在～Phase H     禁止实现跨 session Memory 平台
H4                只保证 transcript≠view、session 可版本化
C5（H 之后）      repo map → Memory Repo MVP（默认关）
```

详见 [modules/memory.md](./modules/memory.md) 与 [architecture 词表](./architecture.md#memory-与记忆词表勿混)。

---

## Quality（横切，H 起强制）

| 文档 | 内容 |
|------|------|
| [quality/evals.md](./quality/evals.md) | golden transcript、security eval、edit eval |
| [quality/contracts.md](./quality/contracts.md) | provider 行为合同 |

每 Capability 阶段至少新增 1 条可 CI 验收；禁止「只加功能不加回归」。

---

## Packaging（横切；双轨 Kernel SDK × All-in-One）

设计：[packaging.md](./packaging.md)（对齐 Grok Build workspace 分层）。

| 阶段 | Packaging 动作 | 状态 |
|------|----------------|------|
| 骨架拆分 | `zag-agent-core` + `zag-coding-agent` + `zag-cli`；main 薄入口 | ✅ |
| **zag-types** | L0 canonical + 中性 ChatError；解开 core→zag-ai | ✅ |
| **Phase H（下一步）** | 修 `--trace` 歧义；推进 H1–H5/H7 生产底线（非再拆包） | ⏳ |
| C4–C5 | H2/H5 出门后拆 `zag-tools`（自 coding-agent/runtime）/ `zag-workspace`（自 core） | 排期 |
| C9 | `zag-tui` / `zag-acp` 产品面成包；`zag` bin 只组装 | 排期 |
| 发布 | 满足 packaging §3 四条标准的包 mirror 拆 repo（首个候选 `openai-zig`） | 排期 |

规则：**每个 C 轨新能力必须在设计中声明落点包**；不允许直接长在 main/cli。

---

## 建议节奏

| 段落 | 做什么 |
|------|--------|
| 1 | 读 [vision](./vision.md) + [maturity](./maturity.md) |
| 2 | 按需复习 Teaching 章；读对应 gaps |
| 3 | 实现 Phase H（按 H1→H7，可与模块规格并行） |
| 4 | H 出门后再开 C4 |
| 5 | 全程维护 maturity 回写 |

时间分配：实现 ~70%，规格/对照读码 ~20%，eval ~10%。

---

## 目录对应

```text
zag/
  docs/
    README.md          文档地图
    vision.md          定位（双轨：Kernel SDK × All-in-One）
    packaging.md       包分层与拆包（对齐 Grok Build）
    maturity.md        成熟度真理源
    roadmap.md         本文件
    architecture.md    包边界 + 分层
    references.md
    gaps/              Teaching → L2 缺口
    modules/           模块规格（含 memory stub）
    phases/            H + C4–C9
    quality/
  chapters/            教程（00–03 tutorial；H planned）
  packages/zag-agent-core/    harness 内核（loop · 纯 Provider · session）
  packages/zag-coding-agent/  产品 harness（Agent · toolset · runtime · WireProvider）
  packages/zag-cli/           产品壳（flags · REPL）
  packages/zag-ai/            agent 友好模型面（resolve · WireAdapter）
  packages/openai-zig/        线协议 / OpenAPI（可独立复用）
  src/main.zig                进程薄入口 → zag_cli.run
```

---

## 相关

- [references.md](./references.md)  
- [architecture.md](./architecture.md)  
- 根 [README.md](../README.md) · [SECURITY.md](../SECURITY.md)  
