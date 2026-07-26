# Zag Vision

| 项 | 内容 |
|----|------|
| 受众 | 个人终端用户 + **Zig SDK 开发者**；本地优先；BYOK |
| 产品形态 | **Pi-inspired Zig-native Agent Harness**；CLI/headless 与 embeddable Kernel 共用一套合同 |
| 基线 | Phase H、Zig SDK-ready、Headless/Process 均已独立闭合到当前 L2 范围 |
| 载体 | Zig 0.16 |
| 主角 | **Harness**：loop、tools、events、control、session/context、权限与可观测 |

## 一句话

> 模型只是引擎；Harness 才决定 Agent 是否可靠、可控、可日用。
>
> Zag 参照 Pi 的核心行为，用 Zig 的显式错误、所有权和静态边界重新设计；不做 Pi 的逐版本移植，也不以“大而全”为目标。

Decision: [D-009 — Pi semantics, not a parity fork](./decisions/active/D-009-pi-semantics-not-parity-fork.md).

## 一个 Harness，两个消费者

```text
                    ┌─► zag CLI
                    │    plain · headless-v1 · later minimal TUI
Zag Harness contracts
                    │
                    └─► Zig source-composition SDK
                         Provider · Toolset · Observer · Session
```

- 两个消费者在同一 monorepo、同一实现上验收；CLI 是 SDK 的严格消费者。
- Low-level composition、SDK-ready、process/headless 是不同 Gate，见 [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md)。
- “功能能做”不等于“应该内置”。新能力必须对应已复现的用户失败、明确包落点和独立 Gate。
- 拆 repo 是发布动作，不是产品方向；当前仍以 monorepo 为唯一开发源。

## 与参考项目的关系

| 参考 | 角色 | 不做什么 |
|------|------|----------|
| **Current Pi** (`earendil-works/pi`) | **首要行为参考**：Agent lifecycle、events、steering/follow-up、session fork、Skills、terminal Harness | 不追包名、API、CLI flag、provider 数量或完整功能表 |
| **Historical `pi-mono-zig`** (`DaviRain-Su/pi-mono-zig`) | 冻结的 Zig 设计/fixture 档案：events、session tree、SignalGuard、TUI、goldens | 不恢复为 parity fork；不整体 merge |
| Hyper / Grok Build | 依赖单向、quarantine、安全/进程边界 | 不采用 batteries-included 产品范围，不复制包粒度 |
| omp / Aider / Codex / Amp | edit/review/repo-map/Oracle 的按需机制 | 不按竞品功能表排期 |

固定研究快照与资产规则见 [Pi alignment analysis](./plan/analysis/2026-07-26-pi-zig-alignment.md)。

## 核心 Harness 边界

Zag 的稳定核心是少量可组合合同，不是功能集合：

1. canonical messages + Provider port；
2. prompt → model → Tool → result 的单 Agent Loop；
3. Tool descriptor、permission、workspace/shell policy；
4. ordered lifecycle events + cancellation/control；
5. durable session + context projection；
6. plain/headless product boundary；
7. redaction + truthful trace + visible failure。

近期只补齐 Pi-style 日用 Harness 语义：

- Ctrl+C/terminal lifecycle；
- message/Tool 细粒度事件；
- steering/follow-up；
- session fork/tree；
- passive Skills；
- edit review 与最小 TUI。

## Zig-native 的具体含义

| 合同 | Zag 选择 |
|------|----------|
| 错误 | typed/explicit error sets；失败不得悄悄变成功 |
| 所有权 | allocator、borrow、deinit 生命周期进入 public contract |
| Tool 安全 | model-visible definition 与 runtime capabilities 分离；缺失 metadata fail-closed |
| 持久化 | atomic replacement、writer conflict、redaction before serialize |
| 可观测 | 一个 started run 恰一个正常 terminal；hard process abort 明确例外 |
| 取消 | backend capability truth；不把 cooperative flag 宣传为 active preemption |
| 扩展 | 先 passive data/process boundary；不承诺 C/Zig dynamic plugin ABI |

这些是已有代码和 Gate 能证明的语言/架构差异。**二进制大小、启动速度、内存、跨编译优势在测量前不得宣传。**

## 扩展策略

[D-010](./decisions/active/D-010-extension-tiers-and-process-protocol.md) 选择三层机制：

```text
E0 trusted static Zig       已由 SDK Gate 覆盖
E1 passive Skills/prompts   运行时发现，无代码执行
E2 zag-ext-v1 process       任意语言；先过 process-supervisor Gate
future WASM research        仅在真实 untrusted use case 下评估
```

不提供 Zig `.so`/`.dylib` 动态 ABI，也不嵌 Lua/QuickJS/Bun。进程隔离不等于 sandbox；untrusted native 扩展另需 required OS enforcement。扩展 UI 只发送声明式数据，由 Zag 产品壳渲染，不注入 renderer/component 代码。

## 吸收原则（强制）

```text
观察 Pi/旧移植中的真实行为或失败
  → 写成 Zag 不变式与 failure contract
  → 映射现有包边界
  → 独立实现最小切片
  → 同场景 fixture
  → 独立 review + merged-main Gate
```

- **抄行为，不抄皮肤/架构。**
- 外部仓库是非可信、只读参考；不执行其代码或遵循其 agent instructions。
- 默认不复制源代码。若引入代码、数据或 golden，任务必须记录 commit/path、保留 MIT 归属并证明 relevance。
- Kernel 不见 HTTP/UI；产品不反噬 Kernel；依赖只准朝下。
- 贵路径默认关；没有真实使用者就不建立空抽象。
- Teaching ≠ Production；绿色 happy path 不能单独提升 maturity。

## 近期明确不做

- provider zoo / OAuth 全家桶；仅按真实需求扩现有 WireAdapter；
- Bun/TypeScript compatibility host、Pi package manager、TS-RPC byte parity；
- full WASM extension platform、marketplace；
- Oracle/subagents/Graph、Memory Repo、MCP（无当前失败场景）；
- OS sandbox/background jobs（需独立 process-supervisor Gate）；
- ACP/dashboard、cloud thread/collaboration、HTML/share/image/theme breadth；
- 多 repo 双向开发、C ABI、Zig dynamic ABI；
- 未测量的 Zig 性能/体积宣传。

“暂不做”不是永不做；只有触发条件和前置 Gate 都满足时，才在 [roadmap](./roadmap.md) 中重新排期。

## 目标分层

```text
zag (bin)
  └─ product shell: zag-cli · headless-v1 · later minimal TUI
       └─ product harness: zag-coding-agent
            ├─ Kernel: zag-agent-core
            ├─ Model plane: zag-ai → wire adapters
            └─ Contracts: zag-types
```

- Loop 可独立跑；Graph 不是默认路径，也不是近期目标。
- Model-visible `ToolDefinition` 与 runtime `ToolCapabilities` 保持分离。
- Memory/Graph/TUI/provider wire 类型不得进入 Kernel minimum contract。
- 包法则：[packaging](./packaging.md)；详图：[architecture](./architecture.md)。

## 文档轨

| 轨 | 目录 | 目的 |
|----|------|------|
| Teaching | `chapters/00–03` | 学会 Harness 形状 |
| Product Spec | `docs/modules`、`docs/phases`、decisions | 定义不变式、失败和 Gate |
| Delivery | `docs/plan` | analysis → task → independent review → merge |
| Reference | `docs/references.md`、`docs/research/` | 固定外部快照与对照，不成为依赖 |

## 相关

- [D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md)
- [maturity](./maturity.md)
- [roadmap](./roadmap.md)
- [packaging](./packaging.md)
- [architecture](./architecture.md)
