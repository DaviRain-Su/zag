# Zag 架构

> 描述**当前代码**与**目标分层**。成熟度等级见 [maturity.md](./maturity.md)。  
> Teaching Phase 0–3 = 骨架已落地；Production Floor（Phase H）= 规格已写、实现未齐。  
> **主蓝本：Grok Build workspace 分层**（all-in-one 产品 × 可嵌入内核，60+ crate 单向依赖；见 [packaging.md](./packaging.md)）。  
> 辅助对照：[Pi](https://github.com/earendil-works/pi)（loop / session / compaction 教科书叙述——只借叙述，不采纳其极简产品面）。

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
│ L4 Kernel ★SDK 主入口（≈ xai-grok-shell；今 src/agent）         │
│  Loop · Session · Context view · Permissions · Trace           │
│  Tools / Runtime 挂载                                          │
│  Memory Core 端口（默认 no-op · C5）                            │
│  Graph / DAG 编排（可选 · C6）— 节点内仍是 Loop                 │
│  L3 agent 定义（≈ xai-grok-agent；C6 拆出）                     │
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
* openai-zig = OpenAI-compat 线协议实现（可独立复用 / 首个拆 repo 候选）
```

### 分层职责

| 层 | 对标（Grok Build） | 职责 | 阶段 |
|----|--------------------|------|------|
| **L6/L5 产品面** | pager-bin / pager / dashboard / acp-lib | UI/交互/进程模式；**薄**，只组装 | 现状 CLI；**C9** 扩 TUI/ACP |
| **L4 Kernel（SDK 入口）** | xai-grok-shell | 单 agent **Loop**、session、权限、context、trace；可选 Graph | **H** 硬化 Loop；**C6** Graph |
| **L3 agent 定义** | xai-grok-agent | 工具 + 采样 + hooks 组合 | C6 拆出 |
| **Memory Core（端口）** | grok-memory 抽象 | 跨 session 记忆；默认关闭实现 | 接口可早留；**C5** 实现 |
| **L2 Model plane** | models / sampler / sampling-types | resolve、catalog、**canonical→wire 适配**、stream、错误 | H6；多协议适配后置 |
| **L2 Runtime / 领域包** | tools / workspace / sandbox | 执行面，不知模型协议 | H2 工具加深；C7 沙箱 |
| **L0 契约** | tool-types / tool-protocol | 无 IO 领域类型；SDK 最稳面 | H 期间归目录，C 轨 zon 化 |

### 架构不变式

1. **Loop 可独立运行**；日常 coding 路径不强制经过 Graph。  
2. **Graph 节点内部是 Loop**（或确定性 gate）；Graph 是编排层，不替代 tool loop。  
3. **Kernel 只见 canonical 消息与 Provider 端口**；厂商线协议只在 Model plane 适配器（quarantine，学 shell 对 rmcp/reqwest 的隔离）。  
4. **Memory / Graph / 产品面** 不得依赖 `openai-zig` 类型。  
5. **依赖只准朝下**；L4 不 import L5/L6；产品不反噬内核。  
6. Phase H 只保证 **单 Loop 生产底线**；Graph、多协议实现、厚产品壳后置。  
7. **All-in-one 是产品目标，不是架构豁免**：每个新能力先声明落点包（[packaging.md](./packaging.md) §5）。

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
| **Loop** | 单角色工作环：模型决定 tool → 执行 → soft-fail 回灌。≈ Pi-agent-core。代码：`src/agent/loop.zig`。 |
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
  Message / AssistantTurn / ToolCall   ← canonical（zag-ai types）
        │
        │  Provider 端口（agent/provider.zig）
        ▼
  zag-ai
        │  transformContext 等价：context.viewForModel（在 agent）
        │  convertToLlm：WireAdapter（规划）
        ▼
  ┌─────────────┬──────────────────┐
  │ OpenAI-compat│ Anthropic …     │  ← 适配器；**现状仅左列实现**
  │ (openai-zig) │ （预留）         │
  └─────────────┴──────────────────┘
```

### 设计钉死（实现分两步）

| 现在（文档 + 后续 zag-ai 改造） | 现在不做 |
|--------------------------------|----------|
| Canonical 消息类型稳定在 `zag-ai/types` | 实现 Anthropic HTTP 客户端 |
| 规划 **WireAdapter** 接口：`toWire` / `fromWire` / stream map | 在 `loop.zig` 里 `if (anthropic)` |
| `ProviderSpec` 可增 `api_style`（enum；现状仅 `openai_compat`） | Phase H 以「多协议跑通」为出门条件 |
| Harness 只依赖 `Provider.chat` + canonical turn | Agent 依赖 OpenAI JSON 字段名 |

**实现顺序（用户确认）：** 先本文档 → 再改 **zag-ai** 做成可插拔 Provider 适配（OpenAI 为第一个 adapter）→ Anthropic 等需要时再加实现。

详见 [modules/zag-ai-provider.md](./modules/zag-ai-provider.md#wire-adapter预留)。

---

## Memory Core（端口）与 Memory Repo

| 名称 | 含义 |
|------|------|
| **Memory Core** | Agent Core 上的**端口**：read/search/write 注入 ephemeral；默认 **no-op** |
| **Memory Repo** | 端口的一种后端（跨 session 落盘、可审可删） |

- 接口形状可在 H4 边界清晰后预留；**实现与默认开启属 C5**。  
- 不是 transcript，不是 compaction 摘要。  
- 规格：[modules/memory.md](./modules/memory.md)

---

## Product shell（产品壳）

| 模式 | 阶段 | 说明 |
|------|------|------|
| CLI / headless | 现状 | `src/main.zig` 组装 resolve → Client → Adapter → Agent |
| TUI · Bot · Web · RPC | **C9** | 对标 Pi 四模式 / Grok 产品壳；**不得**把 loop 逻辑写进 UI |

目标：Agent Core 可被多种 shell 嵌入；shell 只处理 I/O 与生命周期。

---

## Monorepo 包边界（强制）

按**依赖方向与失败模式**拆。对齐 Pi：`ai` / `agent-core` / `coding-agent` / shell。  
更长拆包标准见 [packaging.md](./packaging.md)（若存在）。

```text
Product shell (src/main.zig)
        │
        ▼
┌── packages/zag-coding-agent ───────────────────────────┐
│  Agent/Session · toolset · project · WireProvider      │
│  runtime tools (list/read/write/shell)                 │
└────────────┬───────────────────────┬───────────────────┘
             │                       │
             ▼                       ▼
 packages/zag-agent-core      packages/zag-ai
 loop · pure Provider         WireAdapter · catalog
 session · permissions        resolve · types
 context · trace
             │
             ▼
 packages/openai-zig
```

| 包 / 目录 | 职责 | 可依赖 | **禁止**依赖 |
|-----------|------|--------|----------------|
| `openai-zig` | HTTP / OpenAPI | std | 上层 agent 包 |
| `zag-ai` | Model plane + WireAdapter | openai-zig | agent-core / coding-agent |
| `zag-agent-core` | Loop、**纯 Provider**、session、permissions | zag-ai（types/retry/catalog only） | `Client`、Wire 组装、产品 toolset |
| `zag-coding-agent` | 产品 Agent、`WireProvider`、默认 tools | core + zag-ai | openai-zig 细节 |
| `src/main` + `src/root` | CLI 壳 + umbrella 再导出 | 上述 | 业务沉在 shell |

**一句话：** Core 只见 `Provider.chat`；Wire 桥在 coding-agent；线协议在 zag-ai 之后。

规格映射见 [modules/README.md](./modules/README.md#代码映射表)。

---

## 现状分层

```text
CLI (main.zig)
    ↓
zag-coding-agent  ★ 产品 harness
  Agent · Session · toolset · WireProvider · runtime tools
    ↓
zag-agent-core  ★ 纯 loop / Provider 端口
  loop · permissions · context · session · trace
    ↓
zag-ai  WireAdapter (openai_compat 默认)
    ↓
openai-zig
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
| trace | `agent/trace.zig` | L1 JSONL（usage / retry 雏形） |
| context | `agent/context.zig` | L1 截断 view + catalog 预算 |
| edit | `runtime/edit_tools.zig` | L1 整文件 write |
| provider | `agent/provider.zig` + zag-ai | L1+；**WireAdapter 显式化待做** |

## 目标能力与阶段

| 能力 | 位置 | 阶段 |
|------|------|------|
| 单 Loop 生产底线 | Agent Core | **Phase H** |
| WireAdapter（OpenAI 实现） | zag-ai | 文档后 **zag-ai 改造**（可与 H6 并行） |
| Anthropic 等协议实现 | zag-ai adapter | 需要时；非 H 出门 |
| 可靠编辑 | runtime + toolset | **H2** → C4 |
| Memory Core + Repo | agent 端口 + 后端 | **C5** |
| Graph / Subagent / Oracle | Agent Core 编排 | **C6** |
| OS sandbox | runtime | C7 |
| Skills / MCP / packages | extensions | C8 |
| 厚产品壳 | shell | C9 |

## 业务入口（现状）

```zig
var resolve_result = try zag_ai.resolve(gpa, io, env, config_path);
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
```

目标形态（改造后）：shell 拿到 `Provider` 实现（某 WireAdapter），Agent Core 不感知 openai-zig。

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
| `.zag/traces/*.jsonl` | 审计事件 | H7：schema_version |
| `.zag/config.json` | 非密钥配置 | 已有 chat/transport knobs |
| `.zag/memory/*`（规划） | Memory Repo 后端 | **C5**，默认关 |

## Memory 词表（勿混）

| 概念 | 是什么 | 阶段 |
|------|--------|------|
| Transcript | 会话权威消息日志 | Teaching 2；H4 |
| Model view | 发给模型的投影 | L1 截断；**H4** compaction |
| Repo map | 工作区结构索引 | **C5** |
| Memory Core | 端口（默认 no-op） | 接口可预留；**C5** |
| Memory Repo | 跨 session 后端 | **C5**，默认可关 |

## 版本叙事

- 包版本见 `src/root.zig` / `build.zig.zon`。  
- **版本号 ≠ 生产就绪。** 生产底线以 [maturity L2 总验收](./maturity.md#l2-总验收phase-h-出门条件) 为准。

## 安全

见 [SECURITY.md](../SECURITY.md)。OS sandbox **未**实现。

## 相关

- [packaging.md](./packaging.md) · [roadmap.md](./roadmap.md) · [vision.md](./vision.md) · [modules/](./modules/)  
- [research/2026-harness-landscape.md](./research/2026-harness-landscape.md)  
- Teaching [chapters/](../chapters/) · [H-harden](../chapters/H-harden/README.md)  
