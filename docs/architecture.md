# Zag 架构

> 描述**当前代码**与**目标分层**。状态真理源见 [maturity.md](./maturity.md)，当前阻断见 [production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)。
> Teaching Phase 0–3 = 骨架已落地；Production Floor（Phase H）final audit 历史上找到两个 file-surface blocker；single-file edit integrity 与 read/search bounds 均已关闭，`h-integration-001` 在 `d22ce6e` 通过 fresh 11-sentence audit（11/11 PASS，panel SHIP），Phase H 达到 **L2（单用户、受控本机）**。
> [D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md)：Pi 是 Harness 行为参考，旧 `pi-mono-zig` 是冻结 Zig 档案，Grok Build 仅提供依赖/quarantine 纪律；Zag 不做 parity fork 或 batteries-included 产品。
> [D-011](./decisions/active/D-011-thin-agent-core-boundary.md)：`zag-agent-core` 已收缩为 loop kernel；product policy/state/observation 由 `zag-coding-agent` 拥有。ownership migration 与 product lifecycle adapter 在 `aecf402` 闭合，follow-on bounded control seam 在 `a5ff2b7` 闭合；既有 L2 行为不得回退。

---

## 目标分层总图（钉死）

分层借鉴 Grok Build 的单向依赖，Harness 行为参照 Pi；名字和合同用 Zag 自己的。双面目标：**L4 以下 = Kernel SDK 面；L5–L6 = 精简产品 Harness**。

```text
┌──────────────────────────────────────────────────────────────┐
│ L6 发行  zag (bin)             精简 Harness 组装                │
├──────────────────────────────────────────────────────────────┤
│ L5 产品面（产品壳 · C9）        对标 pager / dashboard / acp    │
│  zag-cli · zag-tui · zag-acp   只组装，不承载 loop / 协议细节   │
├──────────────────────────────────────────────────────────────┤
│ L4 Kernel ★低层 Zig composition（zag-agent-core）              │
│  Loop · Transcript · Provider/Tool/Cancel ports                │
│  protocol history · required policy/context/event/control      │
│  SDK-ready Gate 已闭合；不由“包已拆出”自动获得                  │
│  L3 产品 Harness（zag-coding-agent）                             │
│  Agent/Session · policy · context · persistence · observation   │
│  model wiring · concrete coding Tools                           │
├────────────────────┬─────────────────────────────────────────┤
│ L2 Model plane     │ L2 Runtime / 领域包                       │
│  （对标 models/    │  zag-tools（fs·edit·shell·grep）           │
│   sampler）        │  zag-workspace（jail·git）                 │
│  zag-ai            │  zag-sandbox*（C7）                        │
│   canonical msgs   │  extension adapters*（C8 / D-010）         │
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
| Zig SDK-ready | stateful Tool、descriptor、high-level injection、ownership/error/event/cancel/session compatibility | **已闭合** — Gate fixture 7/7 at `ebdd7ab`; current external fixture 22/22 after lifecycle/control/session-fork/skills enrichment; contract in [`modules/sdk-contract.md`](./modules/sdk-contract.md) |
| Process SDK/headless | versioned JSON/events、stable errors/exit codes、ACP/RPC boundary | **已闭合** — `headless-v1` + exit matrix + process fixture; merged-main Gate passed at `a1a1e0f`; ACP/editor remains follow-on |

Decisions: [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md) and [D-010](./decisions/active/D-010-extension-tiers-and-process-protocol.md). Zag does not promise a stable C ABI or Zig dynamic plugin ABI.

### Extension boundary

```text
feature surface: Extension / Skill / Prompt / Theme / Package / Model / Provider / SDK / RPC / JSON / UI
                                        ×
E0 static Zig source composition ──► existing SDK (same process, trusted)
E1 passive resources             ──► product discovery + bounded context/data
E2 executable child              ◄─► zag-ext-v1 process binding ◄─ product supervisor
E3 WASM Component                ◄─► zag-ext-v1 WIT binding ◄──── quarantined runtime
```

The feature and carrier axes are independent: Package is a runtime bundle above E1/E2/E3; E0 remains a build-time source dependency; Custom Model data is distinct from executable Custom Provider behavior; `headless-v1` JSON is distinct from future bidirectional `rpc-v1`.

E2/E3 transport canonical data and construct validated shims; they never move allocators, raw terminal input, renderer pointers, or private Agent memory across the boundary. Product process ownership is separate from OS sandbox enforcement. E3 is selected only by an evidence Gate and starts with compute-only Tools before later separately gated hooks/commands/Provider/UI worlds.

### 分层职责

| 层 | 对标（Grok Build） | 职责 | 阶段 |
|----|--------------------|------|------|
| **L6/L5 产品面** | pager-bin / pager / dashboard / acp-lib | UI/交互/进程模式；**薄**，只组装 | 现状 CLI；**C9** 扩 TUI/ACP |
| **L4 Kernel composition** | Pi low-level agent loop | 单 Agent Loop、Transcript、Provider/Tool/Cancel contracts、protocol history、required policy/context/event seams | **D-011 migration**；既有 H/SDK L2 contract 保持 |
| **L3 产品 Harness** | Pi coding-agent AgentSession | Agent/Session facade、policy/context/persistence/observation、model wiring、concrete Tools | `zag-coding-agent` 当前并持续拥有 |
| **Memory Core（future port）** | grok-memory 抽象 | 跨 session 记忆；default-off | **C5** 按真实 use case 设计，不在 H/SDK minimum 预留 |
| **L2 Model plane** | models / sampler / sampling-types | resolve、catalog、WireAdapter、stream、errors | L2；final audit confirmed dual-wire contract、strict completion、curl active controls + std fail-closed capability truth |
| **L2 Runtime / 领域包** | tools / workspace / sandbox | 执行面，不知模型协议 | H2 工具加深；C7 沙箱 |
| **L0 契约** | tool-types / tool-protocol | provider-facing canonical types + separate runtime ToolCapabilities；无厂商/产品 IO | H/P0 完成 descriptor；SDK-ready Gate 已闭合；semver 仍待第二真实 consumer + 发布通道 |

### 架构不变式

1. **Loop 可独立运行**；日常 coding 路径不强制经过 Graph。
2. **Graph 节点内部是 Loop**（或确定性 gate）；Graph 是编排层，不替代 tool loop。
3. **Kernel 只见 canonical 消息与 Loop 所需 ports**；厂商线协议、durable state 和具体产品 policy 不进入 Kernel。
4. Model-visible `ToolDefinition` 与 local `ToolCapabilities` 分离；Core revalidates metadata and fixes ToolPolicy → Jail → ShellPolicy → execute order；具体实现由 coding-agent 注入，缺失端口不得隐式 allow。
5. **Memory / Graph / 产品面** 不得依赖 `openai-zig` 类型，也不得成为 H/SDK 最低合同的占位 hook。
6. **依赖只准朝下**；Kernel 不 import 产品面，也不通过同包放置偷渡 product state/policy；产品是 Kernel 的第一个严格消费者。
7. Phase H 保证 single-Loop correctness；SDK-ready/headless 是独立 Gate；headless contract 见 [`modules/headless-contract.md`](./modules/headless-contract.md)；Graph、Memory、TUI 后置。
8. OS sandbox 是 runner/process-supervisor enforcement，不污染 Provider/message Kernel ABI。
9. **小而完整不是架构豁免**：每个新能力仍先声明用户失败、owner 包与 failure contract；竞品功能本身不是加入理由。

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
| CLI / one-shot | default L1 human; headless L2 | `zag-cli` 组装 resolve → WireAdapter → Agent；headless 模式见 [`modules/headless-contract.md`](./modules/headless-contract.md) |
| Headless JSON/process SDK | ✅ L2 at `a1a1e0f` | one-shot/output-only `headless-v1` + exit matrix + process fixture；不等于 RPC |
| Long-lived RPC | planned separate Gate | Zag-native correlated command/response/event protocol after public events/control/session; no Pi schema parity |
| TUI · extension UI host · dashboard · polished ACP | **C9 / later Gates** | 只组装；E2/E3 UI uses host-rendered intents/view actions, not raw terminal ownership |

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
| `zag-agent-core` | Loop、Transcript、纯 Provider/Tool/Cancel ports、protocol history、required policy/context/event/control seams | **zag-types only** | durable session/Trace/redaction、concrete policy/workspace/shell/context、Client/Wire/UI |
| `zag-coding-agent` | Agent/Session facade、policy/context/persistence/observation、WireProvider、默认/runtime Tools | core + zag-ai | openai-zig 细节、CLI/process-global state |
| `zag-cli` | 产品壳（args/REPL/one-shot/headless、signals/stdin/terminal） | coding-agent + core + zag-ai | loop 业务 |
| `src/main` | 进程入口 → `zag_cli.run` | zag-cli | 逻辑 |
| `src/root` | umbrella 再导出 | 各 packages | — |

**一句话：** Core 只见 Loop 所需 contracts；Wire 桥、product policy/state/observation 在 coding-agent；线协议在 zag-ai 之后。

### Thin-Core boundary after D-011 and bounded control

```text
Session control queues ──► explicit ControlInput ──► Core safe insertion points
                                                    │
Core loop source facts ──► required LoopEventSink ──► coding-agent fan-out
       │                                                ├─ durable Trace (fail closed)
       │                                                ├─ verbose Observer (best effort)
       └─ Result/RunError ──► Agent facade              ├─ SDK lifecycle adapter
                                  ├─ session save       └─ headless mapping
                                  └─ one run terminal
```

Core retains Tool metadata validation and `ToolPolicy → Jail → ShellPolicy → execute` ordering. The five closed D-011
seams are explicit; missing safety ports never mean allow. `harness-steering-001`, closed at `a5ff2b7`, added a sixth
explicit but non-safety `ControlInput` composition field: low-level hosts select `.none()`, while coding-agent owns all
concrete Session queue state. The D-011 ownership migration and bounded-control follow-on are complete; later
capabilities must preserve the owner map in [`modules/core-boundary.md`](./modules/core-boundary.md).

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

| 模块 | 当前路径 → D-011 target | 当前等级 / blocker |
|------|--------------------------|--------------------|
| Tool runtime | core `tool.zig` + `zag-types` → **keep in Core** | L2；stateful handler + mandatory descriptor/capabilities fail-closed |
| permissions | core `permissions.zig` → concrete implementation in coding-agent; required `ToolPolicy` seam in Core | L2 行为必须保持；descriptor-derived risk；remember = exact lexical request-path，alias re-prompt，Guard 始终重检 |
| workspace | core `workspace.zig` → coding-agent `Jail` implementation | L2 trusted-host file boundary必须保持；realpath/ancestor Guard + Agent composition；非 OS sandbox |
| shell policy/runtime | core `shell_policy.zig` + coding runtime → policy/runtime in coding-agent; required `ShellPolicy` seam in Core | L2 synchronous contract必须保持；denylist 非 sandbox |
| trace / observation | core `trace.zig`/observer logger → coding-agent Trace/redaction/fan-out; Core only `LoopEventSink` | L2 versioned、truthful unique terminal、atomic persistence、redaction均为迁移 regression Gate |
| context | core `context.zig` → protocol history in Core; layers/compaction in coding-agent `ContextView` | L2 fixed-point final-view accounting + strict Tool bundles均保持 |
| read/search | `zag-coding-agent/src/runtime/fs_tools.zig` | L2；h-read-search-bounds-001 closed scoped bounded body + explicit cutoff contract; not exhaustive concurrent traversal |
| write/edit | `zag-coding-agent/src/runtime/edit_tools.zig` | L2；h-edit-integrity-001 target-preserving atomic commit + cleanup truth + final symlink/Agent evidence passed independent/main Gate |
| provider | core Provider + zag-ai WireAdapter | L2；two wire styles + strict completion；curl active controls，std requested controls fail closed before network |

## 目标能力与阶段

| 能力 | 位置 | 阶段 |
|------|------|------|
| 单 Loop production correctness | Agent Core | **Phase H P0/P1** |
| Tool runtime descriptor | zag-types + Agent Core | **Phase H P0** |
| WireAdapter（OpenAI-compatible + Anthropic） | zag-ai | wire 基础 + h-provider-001 deadline/cancel capability truth 已落地 |
| Zig SDK-ready | supported Kernel/product facade | ✅ closed at `ebdd7ab` |
| Headless/process contract | zag-cli/product shell | ✅ closed at `a1a1e0f` — headless-v1 + fixture + dual-backend Gate |
| 可靠编辑 | runtime + toolset | H2 correctness → C4 sharpness |
| Repo map / full session tree；Memory Repo | context/session backend | C5；idle-only durable fork closed at `0a3087f`; full tree and Memory later/default-off |
| Graph / Subagent / Oracle | optional orchestration | C6；依赖 lifecycle/process safety |
| OS sandbox/process supervisor | product runtime | C7；不进入 Provider/message ABI |
| Extension carriers | E0 static SDK / E1 passive / E2 process / E3 WASM | D-010；E2 needs C7.1, untrusted native also C7.2; E3 needs WIT/runtime/capability/package Gates |
| Programmatic/product UI | JSON L2 / future RPC / TUI + host-rendered extension UI | C9 + separate RPC/UI Gates |
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
| list_dir / read_file | ✅ mandatory descriptor + lexical/real containment + checked 64 KiB body + exact `fs-v1` incomplete reason | scoped L2; no exhaustive concurrent traversal claim |
| grep / glob | ✅ descriptor + symlink-aware walker containment + hit/body/walker/source/binary/pattern cutoff truth | fixed `.git`/build exclusions intentional; likely-binary heuristic |
| search_replace | ✅ unique anchor + descriptor + containment + L2 atomic commit | contained final symlink + cleanup-truthful `edit-v1` fault + Agent evidence |
| write_file | ✅ create/full write + descriptor + containment + L2 atomic commit | no direct truncate/write; endpoint/parent/temp residue contracts verified |
| run_shell | ✅ permission + descriptor-selected policy + fixed deny + synchronous UTF-8/base64 shell-v1/scoped-budget/direct-PID/trace Gate passed | mid-flight cancel/process tree/background/PTY/OS sandbox remain post-H |

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
- **版本号 ≠ production-ready 或已发布 SDK。** Product L2 以 [maturity Phase H exit](./maturity.md#phase-h-production-floor-exit) 为准；SDK-ready Gate 已闭合，但 semver publication 仍待第二真实 consumer 与发布通道。

## 安全

见 [SECURITY.md](../SECURITY.md)。OS sandbox **未**实现。

## 相关

- [packaging.md](./packaging.md) · [roadmap.md](./roadmap.md) · [vision.md](./vision.md) · [modules/](./modules/)
- [research/2026-harness-landscape.md](./research/2026-harness-landscape.md)
- Teaching [chapters/](../chapters/) · [H-harden](../chapters/H-harden/README.md)
