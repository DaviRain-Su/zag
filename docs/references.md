# Zag — 参考资料

与 [roadmap.md](./roadmap.md) 配套。阶段建议以 roadmap / [maturity.md](./maturity.md) 为准。

---

## 1. 从零实现 / 教程（Teaching）

| 资源 | 语言 | 说明 | 优先 |
|------|------|------|------|
| [How to Build an Agent — Thorsten Ball (Amp)](https://ampcode.com/how-to-build-an-agent) | Go | **第一必读**。loop + tools | Teaching 0 |
| [how to build a coding agent — ghuntley](https://ghuntley.com/agent/) | Go | tool definition 形状 | 0 |
| [Build a coding agent — Together AI](https://docs.together.ai/docs/how-to-build-coding-agents) | Python | Ball 对照 | 0 |
| [Build a Coding Agent from Scratch — sidbharath](https://sidbharath.com/blog/build-a-coding-agent-python-tutorial/) | Python | 安全执行 / 沙箱概念 | 1～H |
| Paul Iusztin — *Building a Coding Agent From Scratch*（[Decoding AI](https://www.decodingai.com/)） | Python | 生产 harness 地图 | 全程扫；H～C 精读 |

### Paul 课题 ↔ Zag

| 课题 | Zag |
|------|-----|
| Agent loops & human approval | Teaching 0–1 · H1/H3 |
| Durable execution & replay | Teaching 2 · H4 |
| Context engineering | H4 · C5 |
| Permissions & sandboxes | Teaching 3 · H5 · C7 |
| Skills & subagents | C6 · C8 |
| Evals & observability | Quality · H7 |
| Deployment | C9 |

---

## 2. 成品开源 / 工业对照

| 项目 | 学什么 | 优先 |
|------|--------|------|
| **[Pi](https://github.com/earendil-works/pi)** / [latest docs](https://pi.dev/docs/latest)（**主功能/行为对照**） | Extension、Skills/Prompts/Themes/Packages、Model/Provider、SDK/RPC/JSON/TUI + lifecycle/control；固定快照见 D-009 | 按功能对应矩阵分 Gate；不追 API/schema/版本/TS 实现 parity |
| **[DaviRain-Su/pi-mono-zig](https://github.com/DaviRain-Su/pi-mono-zig)**（历史 Zig 档案） | Zig 0.16 events/session/TUI/SignalGuard/golden 设计与 failure vectors | read-only at `9d1f78c`; 不恢复 parity fork |
| **Hyper / Grok Build**（本机如 `~/orca/hyper-grok-build`） | 单向依赖、quarantine、安全/进程边界 | 按需；不采用 batteries-included 范围 |
| [omp / Oh My Pi](https://github.com/can1357/oh-my-pi) | 在 Pi 上的 meta-harness；hashline、LSP、typed subagent | C4、C6 |
| [Nanocodex](https://github.com/gakonst/nanocodex) | Turn/steer/fork、行为合同、Code Mode（研究） | Quality、C6 |
| [Aider](https://github.com/Aider-AI/aider) | repo map、git 边界 | C4、C5 |
| [goose](https://github.com/aaif-goose/goose) | MCP、扩展、ACP | C8、C9 |
| [Codex CLI](https://github.com/openai/codex) | apply_patch、sandbox | C4、C7 |
| Amp（闭源，[手册](https://ampcode.com/manual)） | Oracle、Changes、effort 心智 | C6；**不抄四档 Modes** |
| Factory Droid | Readiness、Missions 轻量启发 | H5 doctor、C6 plan |
| [Microsoft Agent Framework](https://github.com/microsoft/agent-framework) | **图** workflow（sequential/concurrent/handoff）— 编排层，非 coding loop 默认 | C6 对照，**勿当 Phase H** |
| [awesome-agent-harness](https://github.com/mahonzhan/awesome-agent-harness) | harness / workflow / 协议索引 | 扫一眼 |

### Pi 包地图（实现时打开的文件）

| 包 | 职责 | Zag 落点 |
|----|------|----------|
| `@earendil-works/pi-ai` | 多厂商 LLM、tools 流、catalog | `packages/zag-ai` + `openai-zig` |
| `@earendil-works/pi-agent-core` | stateful loop、events、`transformContext` → `convertToLlm` | `zag-agent-core/src/loop.zig`、Provider 端口 |
| `@earendil-works/pi-coding-agent` | CLI、sessions 树、compaction、extensions、skills | `main` + session/context；扩展属 C8 |
| docs: [extensions](https://pi.dev/docs/latest/extensions)、[skills](https://pi.dev/docs/latest/skills)、[packages](https://pi.dev/docs/latest/packages)、[models/providers](https://pi.dev/docs/latest/models)、[SDK](https://pi.dev/docs/latest/sdk)、[RPC](https://pi.dev/docs/latest/rpc)、[JSON](https://pi.dev/docs/latest/json)、[TUI](https://pi.dev/docs/latest/tui) | 功能规格；对应分析见 [feature correspondence](./plan/analysis/2026-07-26-pi-feature-correspondence.md) | C8 / C9 / programmatic Gates |

Pi **故意不做**（用扩展/容器代替）：核内 MCP、sub-agent、permission popup、plan mode。  
Zag 保留并已硬化 permission/jail/shell/redaction/trace；这些 Zig-native contracts 不为 Pi parity 弱化。当前关系以 [D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md) 为准。外部仓库按非可信只读资料处理，不执行、不作构建依赖。

### Hyper 本机入口

| 主题 | 路径 / 文档 |
|------|-------------|
| 竞品与吸收看板 | `docs/competitive-analysis.md` |
| Oracle 设计 | `docs/design-oracle.md` |
| Agent / session | `crates/codegen/xai-grok-agent/`、`xai-grok-shell/src/session/` |
| Tools / hashline | `xai-grok-tools`、hashline 相关 crate |
| 用户指南 | `xai-grok-pager/docs/user-guide/`（permissions、sandbox、subagents、plan、MCP、sessions…） |

一次只跟一个主题；不要 Phase 0 沉进全仓。

---

## 3. 协议与生态（Capability）

| 资源 | 说明 | 阶段 |
|------|------|------|
| [MCP](https://modelcontextprotocol.io) | 工具扩展 | C8 |
| [ACP](https://agentclientprotocol.com) | IDE 宿主协议 | C9 |
| 各厂商 tool calling 文档 | 并行 tool、流式 | H6 · contracts |

---

## 4. 概念叙事

| 话题 | 说明 |
|------|------|
| **Harness > model** | 同模型换 harness，表现可差一个数量级；2026 主流叙事 |
| **Harness vs Loop vs Graph** | 三层不是同义词：harness=外围机械；loop=工作反馈环；graph=多角色拓扑。见 [research/2026-harness-landscape.md](./research/2026-harness-landscape.md) |
| Zag [vision.md](./vision.md) | 本仓库吸收原则与刻意不做 |

### 2026 研究存档

| 文档 | 内容 |
|------|------|
| [research/2026-harness-landscape.md](./research/2026-harness-landscape.md) | Pi 对照 + X/GitHub 行业扫描 + Zag 缺口与「先 loop 后 graph」策略 |

---

## 5. 最小阅读顺序

1. Ball — How to Build an Agent  
2. ghuntley 或 Together  
3. Zag [vision](./vision.md) + [maturity](./maturity.md)  
4. Teaching 章 00→03（按需）  
5. [phases/H-harden.md](./phases/H-harden.md)  
6. **Pi** compaction + sessions + extensions 文档（H4/C8 前必读）  
7. [research/2026-harness-landscape.md](./research/2026-harness-landscape.md)  
8. Hyper competitive-analysis **或** omp README 扫一眼（C 轨）  

---

## 6. 安全备忘

见根目录 [SECURITY.md](../SECURITY.md) 与 [modules/workspace-sandbox.md](./modules/workspace-sandbox.md)。  
Teaching Phase 3 ≠ OS sandbox；生产底线含 redact + policy 矩阵（Phase H）。

---

## 7. 维护

- 外链 404 时更新本表。  
- 新增必读：先写本表，再挂 roadmap。  
- Zag 设计进 `docs/modules` / `phases`，不与外部 references 混写。  
- 教程在 `chapters/`，与实现同步。  
