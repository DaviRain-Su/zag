# Zag 路线：从零实现 Code Agent

> **Zag** — 用 Zig 做的 Code Agent：从最小 loop 慢慢长成可上生产的 harness。  
> 模型只是引擎；好不好，主要看 **harness**。

## 总览

```
Phase 0  最小真理     loop + tools（只读）
Phase 1  真·Code      写文件 + 权限
Phase 2  日用级       会话 / context / 项目说明
Phase 3  生产向       沙箱 / 可观测 / 稳定边界
```

| 阶段 | 目标 | 故意不做 |
|------|------|----------|
| **0. 骨架** | 跑通 loop | 多模型、MCP、TUI |
| **1. 能改代码** | 真 tool + 权限 | 子 agent、压缩 |
| **2. 能日用** | 会话、context、Git 感 | 分布式、复杂编排 |
| **3. 像生产** | 沙箱、可观测、稳定 API | 一上来对标工业全量 |

- **主实现语言：** Zig（钉死版本，见仓库根 README / `build.zig`）
- **对照材料：** Go 最小样例、Python 生产课大纲、Rust 工业实现（goose / Hyper）——读架构，不强制换语言重写
- **链接全集：** [references.md](./references.md)

**原则：** agent 逻辑是主角；Zig 底层细节能推到附录 / `runtime/` 就推。每阶段只加 **一类** 能力。

---

## 全程常备（卡住就回来）

| 资料 | 作用 | 怎么用 |
|------|------|--------|
| [Thorsten Ball — How to Build an Agent](https://ampcode.com/how-to-build-an-agent) | 最小心智模型（~400 行 Go） | 先通读 1 遍，实现时当规格说明书 |
| [ghuntley — how to build a coding agent](https://ghuntley.com/agent/) | 工作坊版同一故事 | 对照 tool definition 怎么拆 |
| [Together AI — Build a coding agent](https://docs.together.ai/docs/how-to-build-coding-agents) | Ball 的 Python 对照 | Go 片段看不懂时看这个 |
| Paul Iusztin — *Building a Coding Agent From Scratch*（Decoding AI） | 生产 harness 全景（约 8 课） | 当地图；Phase 0 不要照抄全栈 |
| Hyper / Grok Build（本地 monorepo） | 工业级对照 | 每阶段结束后只读一个子系统 |
| [goose](https://github.com/aaif-goose/goose) | 本地生产 agent（Rust） | Phase 2～3 对照 MCP / 扩展 |

**写在笔记首页的一句话：**

> 模型只是引擎；Code Agent 好不好，主要看 harness。

---

## Phase 0 — 最小真理（能跑的 loop）

### 目标

一个 CLI：`用户一句话 → 调模型 → 可能 call tool → 结果回灌 → 循环直到结束`。

**最少 tool：** `list_dir`、`read_file`（可选只读 `grep`）。  
**先不要：** 写文件、子 agent、MCP、TUI、多 provider。

### 实现清单

1. Message 列表（user / assistant / tool）
2. 调一个 LLM API（先钉死一家）
3. 解析 `tool_calls`
4. 本地执行 tool，以 tool message 回灌
5. 退出条件：模型不再 call tool / 或显式结束

### 建议目录落点

```text
src/agent/     # loop、message、tool 协议  ← 主线
src/runtime/   # fs、process、http、json   ← 可先糙
src/provider/  # 先一个后端
src/main.zig   # CLI 入口（薄）
```

### 该看什么（按顺序）

| 顺序 | 资料 | 看什么 |
|------|------|--------|
| 1 | **Ball — How to Build an Agent** | 全文。tool schema、执行、回传 |
| 2 | **ghuntley workshop** | `ReadFile` / `ListFiles` / `Bash` 的 definition 形状 |
| 3 | **Together Python 版** | 同一架构的另一套代码 |
| 4 | （可选）极简 95 行级 agent 短文 | 建立「loop 可以很短」的信心 |

### 读完应能回答

- Tool 对模型暴露的是什么？（name + description + JSON schema）
- 一轮里：谁决定 call tool？谁执行？结果放哪？
- 为什么这叫 harness，而不是「会聊天的脚本」？

### 本阶段不做

写文件、权限系统、压缩、多 agent、美化 UI。

### 验收

对一个小目录说：「这个项目有几个源文件？读一下 build 文件摘要。」  
Agent **只靠 tool** 答对，且 transcript 可回放。

**Tag 建议：** `ch0-loop` / `phase-0`

---

## Phase 1 — 真·Code Agent（能改代码）

### 目标

能改工作区文件 + 危险操作可拦截。

**加上：** `write_file` 或简单 patch、`run_shell`（超时/截断）。  
**权限：** 至少两档，例如 `ask`（写/shell 要确认）和 `yolo`。

### 该看什么

| 顺序 | 资料 | 看什么 |
|------|------|--------|
| 1 | 重读 Ball / ghuntley 的 **Bash + 编辑** | 写操作只是另一种 tool |
| 2 | [sidbharath — Build a Coding Agent](https://sidbharath.com/blog/build-a-coding-agent-python-tutorial/) | 安全执行、沙箱**概念**（实现可放到 Phase 3） |
| 3 | [Aider](https://github.com/Aider-AI/aider) 文档 + 源码浏览 | 整文件写 vs diff/patch；与 Git 的关系 |
| 4 | Paul 系列：**Agent loops & human approval** | HITL 在整体架构中的位置 |
| 5 | Hyper 用户指南：`permissionMode` / plan mode | 产品层权限语义 |

### 读完应能回答

- 写文件失败、命令超时，loop 里怎么表现给模型？
- 「先问再改」状态机能不能画出来？
- 为什么生产环境很少默认 yolo？

### 本阶段不做

完美 Git 集成、子 agent、自动压缩、MCP 全家桶。

### 验收

玩具仓库：「给入口加一个 `--version`」。  
批准后文件真改对；拒绝则不改。

**Tag 建议：** `ch1-edit` / `phase-1`

---

## Phase 2 — 日用级（能连续干活）

### 目标

中等会话不那么断片；重开能续。

**加上：**

- 会话落盘 / 恢复（jsonl 即可）
- 注入项目说明（`AGENTS.md` 或 README 摘要）
- Context：超长时截断或「最近 N 轮 + 摘要」（先糙）
- Shell 输出截断、统一错误格式

### 该看什么

| 顺序 | 资料 | 看什么 |
|------|------|--------|
| 1 | Paul：**Context engineering**、**Durable execution**（概念） | harness 比 loop 大在哪 |
| 2 | Aider：**repo map** / 选哪些文件进上下文 | context ≠ 全塞进 prompt |
| 3 | Hyper 用户指南：AGENTS.md、sessions、memory | 产品行为对照 |
| 4 | Hyper 选读：prompt 拼装、compaction **入口** | 知道工业界挂在哪，不要求复刻 |
| 5 | goose 文档：skills / recipes / session | 扩展点怎么产品化 |

### 读完应能回答

- 哪些进 system、哪些进 user、哪些每轮临时注入？
- 上下文爆了：丢历史 vs 摘要，各有什么坑？
- 会话文件最小字段有哪些？

### 本阶段不做

分布式、远程 sandbox 集群、完整 eval 平台。

### 验收

关掉进程再开能续会话；带 `AGENTS.md` 的小项目里行为明显更贴约定。

**Tag 建议：** `ch2-session` / `phase-2`

---

## Phase 3 — 生产向（「可能上生产」）

### 目标

别人敢在**受控环境**用：有边界、有日志、有版本承诺。

**逐项加（一次一项）：**

1. 路径 jail / 工作区外拒绝  
2. 命令策略（黑白名单或审批）  
3. 结构化日志 + 一次 run 的 trace  
4. Provider 抽象稳定、配置文件、semver  
5. 可选：MCP **或** subagent **或** hooks（只选一条深挖）  
6. 少量测试：tool 契约 + 1～2 条 golden transcript  

### 该看什么

| 顺序 | 资料 | 看什么 |
|------|------|--------|
| 1 | Paul 剩余：sandboxes、skills/subagents、evals、deploy | 检查清单，不是一次性作业 |
| 2 | sidbharath 等文的 **sandbox** 章节 | 进程隔离、资源限制思路 |
| 3 | **goose**：权限、扩展、MCP | Rust 生产向怎么拆 |
| 4 | Hyper：sandbox、hooks、subagent、ACP | 工业上限长什么样 |
| 5 | 安全基线短文（LLM 应用勿瞎执行 shell） | 写进 `SECURITY.md` 的素材 |

### 读完应能回答

- 默认拒绝什么？如何审计一次危险操作？
- 版本升级会不会弄坏用户配置？
- 没有 eval，怎么知道改 harness 没变笨？

### 验收

- `SECURITY.md` + 配置说明 + 版本号  
- 工作区外写文件失败且可解释  
- 一次完整 run 的日志能复盘 tool 序列  

**Tag 建议：** `ch3-prod` / `v0.1.0`

---

## 横向：每阶段结束后的「对照读码」

| 阶段结束 | 对照读 1 个点（别开新坑） |
|----------|---------------------------|
| Phase 0 | Ball 全文再过一遍 vs 自己的 loop |
| Phase 1 | Aider 的 edit 策略 **或** Hyper `permissionMode` |
| Phase 2 | Hyper prompt 拼装 **或** Aider repo map |
| Phase 3 | goose 扩展模型 **或** Hyper sandbox/hooks **选一** |

**时间分配建议：** 实现约 80%，对照读码约 20%。不要 Phase 0 就沉进 Hyper 全仓。

---

## 建议节奏（慢慢来）

| 段落 | 做什么 |
|------|--------|
| 1 | **只读** Ball + 笔记画 loop 图 |
| 2 | Phase 0 做到验收 |
| 3 | Phase 1 + Aider/权限对照 |
| 4 | Phase 2 + context/session |
| 5 | Phase 3 一项一项加，每项半页设计说明 |

---

## 与仓库目录的对应

```text
zag/
  README.md
  docs/
    roadmap.md       ← 本文件
    references.md    ← 链接与书单
    architecture.md  ← 模块边界（随实现更新）
  chapters/          ← 每章教程（与代码同步）
    00-loop/         ← Phase 0 已写
    01-edit-permissions/
    02-session-context/
    03-production/
  src/               ← 实现（按 Phase 慢慢长）
    agent/
    runtime/
    provider/
    main.zig
```

---

## 最小阅读顺序（只想先读 5 样）

1. **Ball** — How to Build an Agent（全文）  
2. **ghuntley** 或 **Together** — 对照 tool 形状  
3. **Paul 系列大纲** — 知道后面还有什么  
4. **Aider** — 改代码与上下文（文档为主）  
5. **Hyper 或 goose 选一个** — 工业上限扫一眼  

然后再动手 Phase 0。

---

## 相关文档

- [references.md](./references.md) — 链接全集与分类  
- [architecture.md](./architecture.md) — 当前模块边界与协议  
- [chapters/00-loop](../chapters/00-loop/README.md) — Phase 0 教程（与代码同步）  
- 根目录 [README.md](../README.md) — 项目定位与入口  
