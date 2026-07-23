# Zag — 参考资料

与 [roadmap.md](./roadmap.md) 配套的链接表。按类型整理；阶段建议见路线图正文。

---

## 1. 从零实现 / 教程（必读梯队）

| 资源 | 语言 | 说明 | 优先阶段 |
|------|------|------|----------|
| [How to Build an Agent — Thorsten Ball (Amp)](https://ampcode.com/how-to-build-an-agent) | Go | **第一必读**。~400 行讲透 agent loop + tools | 0（全文），1（复习编辑/shell） |
| [how to build a coding agent — ghuntley](https://ghuntley.com/agent/) | Go | 工作坊版；tool definition 示例清晰 | 0 |
| [Build a coding agent — Together AI](https://docs.together.ai/docs/how-to-build-coding-agents) | Python | Ball 文的 Python 对照实现 | 0 |
| [Build a Coding Agent from Scratch — sidbharath](https://sidbharath.com/blog/build-a-coding-agent-python-tutorial/) | Python | 更完整：MVP loop → 安全执行 / 沙箱思路 | 1～3 |
| Paul Iusztin — *Building a Coding Agent From Scratch*（[Decoding AI](https://www.decodingai.com/)） | Python | 生产 harness 八课级大纲：loop、HITL、durable、context、sandbox、skills/subagents、evals、deploy | 地图：0 扫一眼；2～3 精读对应课 |
| 各类「95 行 / 131 行 agent」短文（如 waku-agent 等社区传播版） | 多 Python | 只用来建立「最小可运行」直觉，不作架构权威 | 0 可选 |

### Paul 系列课题 ↔ Zag 阶段（概念对齐）

| 课题（典型标题） | Zag 阶段 |
|------------------|----------|
| System architecture | 全程地图 |
| Agent loops & human approval | 0～1 |
| Durable execution & replay | 2 |
| Context engineering | 2 |
| Permissions & sandboxes | 1 概念 / 3 实现 |
| Skills & parallel subagents | 3 可选 |
| AI evals & observability | 3 |
| Deployment | 3 |

---

## 2. 成品开源（读架构，不抄全仓）

| 项目 | 语言 | 学什么 | 优先阶段 |
|------|------|--------|----------|
| [Aider](https://github.com/Aider-AI/aider) | Python | Git 感知编辑、repo map、pair 工作流 | 1～2 |
| [OpenHands](https://github.com/OpenHands/openhands) | 偏 Python | 自主软件工程 agent、agent server | 2～3 |
| [goose](https://github.com/aaif-goose/goose)（AAIF / 原 Block） | Rust | 本地生产 agent：MCP、扩展、subagents、ACP | 2～3 |
| OpenCode / Cline 等终端·编辑器 agent | 多 TS 等 | 产品形态对照（CLI / IDE） | 扫一眼即可 |
| **Hyper / Grok Build**（本地，如 `~/orca/hyper-grok-build`） | Rust | 工业 harness：Agent 定义、turn loop、tool bridge、subagent、compaction、hooks、sandbox | 全程对照；3 最深 |

### Hyper 对照阅读入口（本机）

按需打开，**一次只跟一个主题**：

| 主题 | 大致路径 / 文档 |
|------|-----------------|
| Agent 定义与拼装 | `crates/codegen/xai-grok-agent/`（含 README） |
| Session / turn / tool_dispatch | `crates/codegen/xai-grok-shell/src/session/` |
| 子 agent | 用户指南 subagents + `shell` subagent 模块 |
| 权限 / plan mode | 用户指南 permissions、plan-mode |
| Hooks / MCP | 用户指南 hooks、mcp |

（具体相对路径以你本机 monorepo 为准。）

---

## 3. 协议与生态（中后期）

| 资源 | 说明 | 阶段 |
|------|------|------|
| [Agent Client Protocol (ACP)](https://agentclientprotocol.com) | IDE / 宿主与 agent 的 JSON-RPC 约定 | 3 可选 |
| [Model Context Protocol (MCP)](https://modelcontextprotocol.io) | 工具/资源扩展协议 | 3 可选 |
| 各模型商 tool calling 文档（OpenAI / Anthropic / xAI 等） | JSON schema、并行 tool call、流式 | 0 钉一家即可 |

---

## 4. 概念与社区叙事

| 话题 | 说明 |
|------|------|
| **Harness > model** | 同模型换 harness，榜单可大幅变化（如 Terminal-Bench 相关讨论）；书/实现主线应是 harness |
| freeCodeCamp / 通用 AI agent 入门 | LangGraph 等偏「通用 agent」，Code Agent 可借鉴状态机思想，勿被框架绑架 |
| Santiago 等「any language can build agent」 | 语言可换，loop 形状不变——支撑「用 Zig 实现」的合理性 |

---

## 5. 最小阅读顺序（启动用）

1. [Ball — How to Build an Agent](https://ampcode.com/how-to-build-an-agent)（全文）  
2. [ghuntley](https://ghuntley.com/agent/) 或 [Together](https://docs.together.ai/docs/how-to-build-coding-agents)  
3. Paul 系列大纲（Decoding AI）  
4. [Aider](https://github.com/Aider-AI/aider) 文档（编辑与上下文）  
5. Hyper **或** [goose](https://github.com/aaif-goose/goose) 工业上限扫一眼  

然后进入 [roadmap.md](./roadmap.md) **Phase 0**。

---

## 6. 安全与生产备忘（Phase 3）

撰写 `SECURITY.md` 时可覆盖：

- 默认工作区 jail；拒绝工作区外写  
- shell 超时、输出截断、审批策略  
- API key 不进日志 / transcript 脱敏  
- yolo 模式的明确风险说明  
- 依赖与 Zig 版本钉死策略  

（具体条文随实现补全；此处仅作清单提醒。）

---

## 7. 维护说明

- 外链可能变更；发现 404 时更新本文件并在 PR/提交说明里提一句。  
- 新增「必读」级资料时：先写进本表，再在 `roadmap.md` 对应 Phase 挂引用。  
- Zag 自己的设计文档进 `docs/architecture.md`（待建），不要和外部 references 混成一篇。  
