# Zag 架构

> 描述**当前代码**与**目标分层**。状态真理源见 [maturity.md](./maturity.md)，当前阻断见 [production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)。
> Teaching Phase 0–3 = 骨架已落地；Production Floor（Phase H）仍由 in-progress shell-v1 的独立/main Gate 与最终 exit audit 阻塞（package evidence 已落地）。
> Grok Build / Pi / Oh My Pi 只作机制参照：借依赖纪律、生命周期与能力合同，不复制 crate 数或完整产品复杂度。

---

## 目标分层总图（钉死）

对齐 **Grok Build**（tool-types → tools → agent → shell → pager → bin）；名字用 Zag 自己的。双轨目标：**L4 以下 = Kernel SDK 面；L5–L6 = All-in-One 产品面**。

```text
┌──────────────────────────────────────────────────────────────┐
│ L6 发行  zag (bin)             all-in-one 组装（对标 pager-bin）│
├──────────────────────────────────────────────────────────────┤
│ L5 产品面（产品壳 · C9）        对标 pager / dashboard / acp    │
│  zag-cli · zag-tui · zag-acp   只组装，不承载 loop / 协议细节   │
├──────────────────────────────────────────────────────────────┤
│ L4 Kernel ★低层 Zig composition（今 zag-agent-core）           │
│  Loop · Session · Context view · Permissions · Trace           │
│  ToolDescriptor / Runtime 挂载                                 │
│  SDK-ready = 独立 Gate；不由“包已拆出”自动获得                  │
│  Memory / Graph 均为后续可选能力，不是 Kernel 最低合同          │
│  L3 产品 agent 定义（今 zag-coding-agent）                      │
├────────────────────┬─────────────────────────────────────────┤
│ L2 Model plane     │ L2 Runtime / 领域包                       │
│  （对标 models/    │  zag-tools（fs·edit·shell·grep）           │
│   sampler）        │  zag-workspace（jail·git）                 │
│  zag-ai            │  zag-sandbox*（C7）                        │
│   canonical msgs   │  zag-hooks / zag-mcp*（C8）                │
│   + wire adapters  │                                           │
│  openai-zig*       │                                           │
├────────────────────┴─────────────────────────────────────────┤
│ L0 契约  zag-types（message · tool 协议 · sampling；无 IO）      │
└──────────────────────────────────────────────────────────────┘
* openai-zig = OpenAI-compat 线协议实现；是否拆 repo 由 SDK/release gate 决定
```

### “可组合”与 “SDK-ready”

| Level | Meaning | Current |
|-------|---------|---------|
| Low-level Zig composition | caller directly assembles Provider/Toolset/Observer/Transcript/loop | 已验证可行 |
| Zig SDK-ready | stateful Tool、descriptor、high-level injection、ownership/error/event/cancel/session compatibility | **未达** |
| Process SDK/headless | versioned JSON/events、stable errors/exit codes、ACP/RPC boundary | **未达** |

Decision: [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md). Zag does not currently promise a stable C ABI or Zig dynamic plugin ABI.

### 分层职责

| 层 | 对标（Grok Build） | 职责 | 阶段 |
|----|--------------------|------|------|
| **L6/L5 产品面** | pager-bin / pager / dashboard / acp-lib | UI/交互/进程模式；**薄**，只组装 | 现状 CLI；**C9** 扩 TUI/ACP |
| **L4 Kernel composition** | xai-grok-shell | 单 agent Loop、session、权限、context、trace、Tool runtime | **H** correctness；其后独立 SDK-ready Gate；C6 Graph 可选 |
| **L3 agent 定义** | xai-grok-agent | 工具 + 采样 + hooks 组合 | C6 拆出 |
| **Memory Core（future port）** | grok-memory 抽象 | 跨 session 记忆；default-off | **C5** 按真实 use case 设计，不在 H/SDK minimum 预留 |
| **L2 Model plane** | models / sampler / sampling-types | resolve、catalog、WireAdapter、stream、errors | L1+；OpenAI-compatible + Anthropic；curl active deadline/cancel + std fail-closed capability truth 已落地 |
| **L2 Runtime / 领域包** | tools / workspace / sandbox | 执行面，不知模型协议 | H2 工具加深；C7 沙箱 |
| **L0 契约** | tool-types / tool-protocol | provider-facing canonical types + separate runtime ToolCapabilities；无厂商/产品 IO | H/P0 完成 descriptor；SDK Gate 后才承诺稳定发布 |

### 架构不变式

1. **Loop 可独立运行**；日常 coding 路径不强制经过 Graph。
2. **Graph 节点内部是 Loop**（或确定性 gate）；Graph 是编排层，不替代 tool loop。
3. **Kernel 只见 canonical 消息与 Provider 端口**；厂商线协议只在 Model plane adapter。
4. Model-visible `ToolDefinition` 与 local `ToolCapabilities` 分离；permission/workspace/runner 消费同一 runtime descriptor，缺失 metadata fail-closed。
5. **Memory / Graph / 产品面** 不得依赖 `openai-zig` 类型，也不得成为 H/SDK 最低合同的占位 hook。
6. **依赖只准朝下**；Kernel 不 import 产品面；产品是 Kernel 的第一个严格消费者。
7. Phase H 保证 single-Loop correctness；SDK-ready/headless 是独立 Gate；Graph、Memory、TUI 后置。
8. OS sandbox 是 runner/process-supervisor enforcement，不污染 Provider/message Kernel ABI。
9. **All-in-one 是产品目标，不是架构豁免**：每个新能力先声明落点与 failure contract。

---

## Loop ⊂ Graph（多角色编排）

```text
         ┌──────────── Graph / DAG（C6，可选）────────────┐
         │  node = role / sub-agent / deterministic gate   │
         │  edge = handoff · branch · join · retry         │
         │  shared state = session / artifacts             │
         │                                                   │
         │    ┌──── Loop（Agent Core · 必选内核）────┐     │
         │    │  prompt → model → tools → 回灌 …     │     │
         │    └──────────────────────────────────────┘     │
         └───────────────────────────────────────────────────┘

单 coding 路径（默认）:

         ┌──── Loop ────────────────────────────────────┐
         │  无 Graph 外壳也可完整工作                      │
         └──────────────────────────────────────────────┘
```

| 概念 | 含义 |
|------|------|
| **Loop** | 单角色工作环：模型决定 tool → 执行 → soft-fail 回灌。≈ Pi-agent-core。代码：`packages/zag-agent-core/src/loop.zig`。 |
| **Graph / DAG** | **多角色编排**：谁先谁后、分支汇合、失败回边。每个 **agentic 节点** 内部仍跑 Loop。 |
| **确定性节点** | 可非 LLM：permission gate、跑测试、worktree 隔离——与 agentic 节点混排。 |

**禁止误解：** 用 DAG 引擎「画一遍整个 coding 流程」替代模型选 tool 的 Loop。
**正确吸收：** Graph 提供**更强一层**多角色能力；Loop 是节点执行引擎。

规格：

- Loop：[modules/loop-turn.md](./modules/loop-turn.md) · Phase **H1**
- Graph / 子代理：[modules/subagents-oracle.md](./modules/subagents-oracle.md) · Phase **C6**
- 行业背景：[research/2026-harness-landscape.md](./research/2026-harness-landscape.md)

---

## Model plane：canonical 消息 + Provider 适配器

对齐 Pi：`transformContext` / `convertToLlm` + 多厂商 stream 映回统一事件。

```text
Agent Core
  Message / AssistantTurn / ToolCall   ← canonical（zag-types / zag-ai types）
        │
        │  Provider 端口（zag-agent-core/provider.zig）
        ▼
  zag-coding-agent WireProvider
        │
        ▼
  zag-ai WireAdapter (factory.createWire)
        │
  ┌─────┴──────────────┐
  ▼                    ▼
 openai_compat     anthropic_messages
 (openai-zig)      (std.http only)
```

| 现状 | 禁止 |
|------|------|
| Canonical 消息 + `WireAdapter` vtable | `loop` 里 `if (anthropic)` |
| `api_style` / `createWire` | Agent Core import openai-zig |
| OpenAI + Anthropic SSE | — |

详见 [modules/zag-ai-provider.md](./modules/zag-ai-provider.md)。

---

## Memory Core（端口）与 Memory Repo

| 名称 | 含义 |
|------|------|
| **Memory Core** | Agent Core 上的**端口**：read/search/write 注入 ephemeral；默认 **no-op** |
| **Memory Repo** | 端口的一种后端（跨 session 落盘、可审可删） |

- 不是 transcript，也不是 compaction summary。
- H/SDK minimum contract 不提前增加 Memory hook；在 C5 以真实 retrieval/use case 设计端口。
- 实现与默认策略属 C5，默认关闭。规格：[modules/memory.md](./modules/memory.md)

---

## Product shell（产品壳）

| 模式 | 阶段 | 说明 |
|------|------|------|
| CLI / one-shot | 现状 L1 | `zag-cli` 组装 resolve → WireAdapter → Agent；尚无稳定 machine contract |
| Headless JSON/process SDK | post-H Gate | versioned JSON/events、stable errors/exit codes；早于 TUI |
| TUI · dashboard · polished ACP | **C9** | 只组装，不把 loop 逻辑写进 UI |

Agent Core 可被多种 shell 嵌入；shell 只处理 I/O、protocol 与 lifecycle。See [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md).

---

## Monorepo 包边界（强制）

按**依赖方向与失败模式**拆。对齐 Pi：`ai` / `agent-core` / `coding-agent` / shell。
更长拆包标准见 [packaging.md](./packaging.md)（若存在）。

```text
# consumer → dependency
src/main.zig → zag-cli → zag-coding-agent → zag-agent-core → zag-types
                                  └───────→ zag-ai ─┬─────→ zag-types
                                                   └─────→ openai-zig
```

| 包 / 目录 | 职责 | 可依赖 | **禁止**依赖 |
|-----------|------|--------|----------------|
| `zag-types` | Canonical messages、`ChatError`；目标 runtime `ToolCapabilities` | std | vendors / product IO |
| `openai-zig` | HTTP / OpenAPI | std | 上层 agent 包 |
| `zag-ai` | Model plane + WireAdapter | zag-types + openai-zig | agent / cli 包 |
| `zag-agent-core` | Loop、纯 Provider、session、permissions | **zag-types only** | Client、Wire 组装、zag-ai、产品 toolset |
| `zag-coding-agent` | 产品 Agent、WireProvider、默认 tools | core + zag-ai | openai-zig 细节 |
| `zag-cli` | 产品壳（args/REPL/one-shot） | coding-agent + core + zag-ai | loop 业务 |
| `src/main` | 进程入口 → `zag_cli.run` | zag-cli | 逻辑 |
| `src/root` | umbrella 再导出 | 各 packages | — |

**一句话：** Core 只见 `Provider.chat`；Wire 桥在 coding-agent；线协议在 zag-ai 之后。

规格映射见 [modules/README.md](./modules/README.md#代码映射表)。

---

## 现状分层

```text
# consumer → dependency
main → zag-cli → zag-coding-agent → zag-agent-core → zag-types
                         └────────→ zag-ai ─┬→ zag-types
                                           └→ openai-zig
```

### Tool 执行边界（目标顺序）

```text
validated ToolDescriptor
  → permission (HITL)
  → filesystem containment（file Tool）
  → shell policy / process policy（execute Tool）
  → execute
```

Expected deny/Tool failures soft-fail 回灌；host registration、persistence、trace 等配置/基础设施错误不得伪装成 Tool soft success。

| 模块 | 现状路径 | 当前等级 / blocker |
|------|----------|--------------------|
| Tool runtime | `zag-agent-core/src/tool.zig` + `zag-types` | L2；stateful handler + mandatory descriptor/capabilities fail-closed |
| permissions | `zag-agent-core/src/permissions.zig` | L2；descriptor-derived risk (D-007)；不额外声称 canonical contained-path remember identity |
| workspace | `zag-agent-core/src/workspace.zig` | L2 trusted-host file boundary；realpath/ancestor Guard + Agent composition；非 OS sandbox |
| shell policy/runtime | `shell_policy.zig` + coding `runtime/edit_tools.zig` | L1（Gate pending）；shell-v1/30 KiB streams/checked body/direct-child/Agent evidence 已落地；denylist 非 sandbox |
| trace | `zag-agent-core/src/trace.zig` | L2；versioned、truthful unique terminal、atomic persistence、redaction；shell projection package fixture 已落地，Gate pending |
| context | `zag-agent-core/src/context.zig` | L2；fixed-point final-view accounting + strict Tool bundles |
| read/search | `zag-coding-agent/src/runtime/*` | L1+；descriptor + containment + budgets 已落地；row promotion 单独审计 |
| write/edit | `zag-coding-agent/src/runtime/edit_tools.zig` | L1+；anchor + containment 已落地；不声称一般 write-fault atomic/no-partial guarantee |
| provider | core Provider + zag-ai WireAdapter | L1+；OpenAI-compatible + Anthropic；curl active control、std `unsupported_control` fail-closed |

## 目标能力与阶段

| 能力 | 位置 | 阶段 |
|------|------|------|
| 单 Loop production correctness | Agent Core | **Phase H P0/P1** |
| Tool runtime descriptor | zag-types + Agent Core | **Phase H P0** |
| WireAdapter（OpenAI-compatible + Anthropic） | zag-ai | wire 基础 + h-provider-001 deadline/cancel capability truth 已落地 |
| Zig SDK-ready | supported Kernel/product facade | post-H independent Gate |
| Headless/process contract | zag-cli/product shell | post-H independent Gate，早于 TUI |
| 可靠编辑 | runtime + toolset | H2 correctness → C4 sharpness |
| Repo map/fork；Memory Repo | context/session backend | C5；Memory later/default-off |
| Graph / Subagent / Oracle | optional orchestration | C6；依赖 lifecycle/process safety |
| OS sandbox/process supervisor | product runtime | C7；不进入 Provider/message ABI |
| Skills / Hooks / MCP | extensions | C8，按 risk 分阶段 |
| TUI/dashboard/polished ACP | product shell | C9 |
| Third native model protocol | zag-ai adapter | only on user demand；非 H gate |

## 业务入口（现状）

```zig
var resolve_result = try zag_ai.resolve(gpa, io, env, config_path);
var wire = try resolve_result.resolved.createWire(gpa, io);
var bridge = coding.WireProvider.init(wire, stream, true);
bridge.chat_options = resolve_result.chat_options;

var agent = coding.Agent.init(gpa, io, bridge.asProvider(), .{
    .permission_mode = .ask,
    .shell_policy = .protect,
    .context = core.context.optionsForModel(resolve_result.model_info, .{}),
    .chat_retries = resolve_result.chat_retries,
    .trace_path = ".zag/traces/latest.jsonl",
});
```

Agent Core 只见 `Provider.chat`；不感知 openai-zig。

## Tools（现状 vs correctness target）

| Tool | Current | Remaining contract |
|------|---------|--------------------|
| list_dir / read_file | ✅ mandatory descriptor + lexical/real containment | bounded/read-search row promotion remains an explicit audit |
| grep / glob | ✅ descriptor + budgets + symlink-aware walker containment | same independent row audit; shell remains separate |
| search_replace | ✅ unique anchor + descriptor + containment | canonical permission-path identity and broader write-fault matrix are not claimed |
| write_file | ✅ create/full write + descriptor + containment | no general atomic truncate-write/no-partial-fault claim; not default large-file edit path |
| run_shell | ✅ permission + descriptor-selected policy + synchronous shell-v1/budget/direct-child/trace package evidence | `h-shell-001` independent/main Gate pending；mid-flight cancel/process tree/OS sandbox remain post-H |

## 持久化

| 文件 | 内容 | 阶段 |
|------|------|------|
| `.zag/sessions/*.jsonl` | transcript | schema v1；explicit create/resume、atomic replacement fault preservation、visible save failure、writer conflict 已落地 |
| `.zag/traces/*.jsonl` | audit events | schema v1；truthful unique terminal、visible I/O、atomic replacement、redaction 已落地 |
| `.zag/config.json` | 非密钥配置 | 已有 chat/transport knobs |
| `.zag/memory/*`（规划） | Memory Repo 后端 | **C5**，默认关 |

## Memory 词表（勿混）

| 概念 | 是什么 | 阶段 |
|------|--------|------|
| Transcript | 会话权威消息日志 | Teaching 2；H4 |
| Model view | 发给模型的投影 | L1 截断；**H4** compaction |
| Repo map | 工作区结构索引 | **C5** |
| Memory Core | optional future port | **C5**；不提前进入 H/SDK minimum contract |
| Memory Repo | cross-session backend | **C5 later**，default-off |

## 版本叙事

- 包版本见 `src/root.zig` / `build.zig.zon`。
- **版本号 ≠ production-ready 或 SDK-ready。** Product L2 以 [maturity Phase H exit](./maturity.md#phase-h-production-floor-exit) 为准；SDK 另过 [SDK-ready gate](./maturity.md#sdk-ready-gate)。

## 安全

见 [SECURITY.md](../SECURITY.md)。OS sandbox **未**实现。

## 相关

- [packaging.md](./packaging.md) · [roadmap.md](./roadmap.md) · [vision.md](./vision.md) · [modules/](./modules/)
- [research/2026-harness-landscape.md](./research/2026-harness-landscape.md)
- Teaching [chapters/](../chapters/) · [H-harden](../chapters/H-harden/README.md)
