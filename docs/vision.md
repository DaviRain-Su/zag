# Zag Vision

| 项 | 内容 |
|----|------|
| 受众 | 个人 power user + **SDK 开发者**；本地优先；多 provider / BYOK |
| 产品形态 | **双轨：Kernel SDK × All-in-One agent**（对齐 Grok Build 路线，非 Pi 极简路线） |
| 生产条 | 先过 Phase H trusted-host correctness；再分别过 Zig SDK-ready 与 headless/process Gate；semver publication 更晚 |
| 载体 | Zig 0.16 |
| 主角 | **Harness**（loop、tools、权限、context、可观测） |

## 一句话

> 模型只是引擎；Code Agent 好不好，主要看 harness。
> Zag 用 Zig 做一个 **all-in-one 的 coding agent**，并用**严格分层的小包**把内核做成可嵌入 SDK——功能全和结构清不冲突，Grok Build 已经证明了这一点。

## 双轨定位（核心决策）

```text
轨 A：All-in-One 产品     zag bin：工具全、子代理、沙箱、扩展、TUI/headless
轨 B：Kernel SDK          zag-kernel + 领域包：别人嵌入即得完整 agent 能力
```

- 两轨**同一 monorepo、同一套代码**；产品是 Kernel 的第一个严格用户。Low-level composition、SDK-ready、process SDK 是三道不同 Gate，见 [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md)。
- 功能广度是目标（学 Grok Build batteries-included），**不是**罪过；
- 广度的代价用**包分层纪律**支付，见 [packaging.md](./packaging.md)。
- 拆 repo 是发布动作：`openai-zig`、`zag-ai` 等达到拆包标准后 mirror 出去。

## 与参考项目的关系（修订）

| 项目 | 学什么 | 不学什么 |
|------|--------|----------|
| **Grok Build / Hyper** | **主蓝本**：包分层、依赖单向、quarantine、all-in-one 组装 | crate 粒度不必 1:1 复刻 |
| Pi | 扩展验证纪律（先 skill/plugin 后内置）、session/compaction 叙述 | ~~最小默认工具面~~（与双轨目标冲突，**不采纳**） |
| omp | 编辑/LSP/DAP 锐度、stream rules | 一次性堆 32 tools |
| Amp | Oracle 行为、Changes 审阅 | 四档 Modes、云 thread |
| Nanocodex | Turn/steer/fork、行为合同测试 | 绑单一供应商 |
| Aider / goose / Codex | repo map / MCP / apply_patch+sandbox | — |

## 吸收原则（强制）

```text
观察失败场景 → 提炼一句话不变式 → 映射 Zag 包落点（packaging.md）
  → MVP（可关）→ 同场景验收 → 回写 maturity.md
```

| 原则 | 含义 |
|------|------|
| 抄行为，不抄皮肤 | Oracle = 更强只读顾问 × 被真正调用；不必同名 slash |
| **新能力必须声明落点包** | 不允许长在 main/cli 里；见 packaging.md §5 |
| 依赖只准朝下 | kernel 不见 HTTP；产品不反噬内核 |
| 一能力一验收 | 必须对应可复现失败场景 |
| 可关、可配、默认可解释 | 贵路径默认关 |
| 先扩展验证后内置 | 新工作流先 skill/plugin 试；验证后**内置进产品**（不是永远留在包外） |
| Teaching ≠ Production | Phase 0–3 是教程完成；**Phase H 才是生产底线** |

## 失败模式 → 能力（摘要）

| 痛点 | 解法方向 | 落点 |
|------|----------|------|
| 编辑偏一行 / 空白打架 | 锚点 edit / patch | H2 → C4 · zag-tools |
| 长任务断片 / 上下文爆 | 分层 prompt + compaction | H4 → C5 · zag-kernel/zag-compaction |
| 弱模型硬撑 | Oracle pin + 可感知触发 | C6 · zag-agent |
| 不敢 auto-apply | change review | C4 · zag-tools + 产品面 |
| 危险命令 / 逃逸 | jail → OS sandbox | H5 → C7 · zag-workspace/zag-sandbox |
| 跨会话偏好 / 重复交代 | Memory Repo（默认可关） | **C5 only**（[memory.md](./modules/memory.md)） |
| 扩展要改核心 | skills / hooks / MCP | C8 · zag-hooks/zag-mcp |
| 改 harness 变笨 | golden + contracts | Quality（H 起） |
| SDK 用户无法安全嵌入 | stateful Tool + runtime descriptor + injection + ownership/event/session contract | Phase H P0/P1 → SDK Gate |

## 目标分层（摘要）

```text
发行 zag(bin) → 产品面 (CLI/TUI/ACP…) → Kernel（Loop ± Graph · Memory 端口 · Tools 挂载）
                                     → Model plane（canonical + WireAdapters）
                                     → Runtime / 领域包
```

- **Loop** 可独立跑；**Graph** 多角色编排（C6），节点内仍是 Loop。
- Model-visible `ToolDefinition` 与 local runtime `ToolCapabilities` 分离；缺失 metadata fail-closed。
- **WireAdapter** 隔离协议；现状 OpenAI-compatible + Anthropic。
- Memory/Graph hooks 不进入 H 或 SDK minimum contract；到对应 C 阶段按真实 use case 设计。
- 包分层与拆包：[packaging.md](./packaging.md)；详图：[architecture.md](./architecture.md)。

## 刻意不做（当前）

- Amp 式 low–ultra 四档 Modes 整包解析层
- 云 thread / collab、企业 Missions / SDLC 云平台
- 一上来打磨 TUI（属 C9；但 TUI **是**目标，不是永久非目标）
- Phase H 内做 Memory 平台 / 云知识库（属 C5，默认关）
- 一开始就 multi-repo development（monorepo 唯一开发源）
- 未测量就宣传 Zig binary size/startup/cross-build advantage
- 在 SDK Gate 前承诺 semver、C ABI 或 Zig dynamic plugin ABI
- ~~把默认工具面压到最小~~（已废弃的 Pi 叙事）

## 文档轨

| 轨 | 目录 | 目的 |
|----|------|------|
| Teaching | `chapters/00–03` | 学会 harness 形状 |
| Spec | `docs/modules`、`docs/phases`、`docs/packaging.md` | 指导实现到 L2/L3 与包边界 |
| Gaps | `docs/gaps` | 每章诚实列出离生产差什么 |
| Research | `docs/research/` | 行业与竞品对照存档 |

## 相关

- [packaging.md](./packaging.md) — 包分层与拆包（双轨的结构基础）
- [maturity.md](./maturity.md) — 成熟度真理源
- [roadmap.md](./roadmap.md) — 阶段排期
