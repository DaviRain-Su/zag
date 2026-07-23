# Zag Vision

| 项 | 内容 |
|----|------|
| 受众 | 个人 power user；本地优先；多 provider / BYOK |
| 生产条 | 敢在**受控本机**日用 + CI headless；不是企业多租户云平台 |
| 载体 | Zig 0.16 |
| 主角 | **Harness**（loop、tools、权限、context、可观测） |

## 一句话

> 模型只是引擎；Code Agent 好不好，主要看 harness。  
> Zag 用 Zig 实现可教学、可演进的 coding harness；锐度对标 Hyper / omp 一类生产终端 agent，不堆功能博物馆。

## 与 Hyper / Grok Build 的关系

| | Hyper（参考） | Zag（本仓库） |
|--|---------------|---------------|
| 角色 | 工业级 Rust 终端 agent（多 provider） | Zig 教程 + 实现；读架构、写规格、按模块长到生产底线 |
| 读什么 | 竞品分析、sandbox、subagent、hashline、MCP | `~/orca/hyper-grok-build` 等本机对照 |
| 写哪里 | 不 fork 进 Zag | `src/agent/`、`packages/zag-ai/`、`packages/openai-zig/`、`src/runtime/` |

抄**失败模式的解法**与**模块边界**，不抄 crate 名与 UI 皮肤。

## 吸收原则（强制）

```text
观察失败场景 → 提炼一句话不变式 → 映射 Zag 模块落点
  → MVP（可关）→ 同场景验收 → 回写 maturity.md
```

| 原则 | 含义 |
|------|------|
| 抄行为，不抄皮肤 | Oracle = 更强只读顾问 × 被真正调用；不必同名 slash |
| 优先落在已有管道 | edit → tools；权限 → permissions；审计 → trace |
| 一能力一验收 | 必须对应可复现失败场景 |
| 可关、可配、默认可解释 | 锐度默认开得克制；贵路径默认关 |
| 先插件后内核 | Skills/MCP 验证后再考虑内置（Pi） |
| Teaching ≠ Production | Phase 0–3 是教程完成；**Phase H 才是生产底线** |

## 失败模式 → 能力（摘要）

| 痛点 | 解法方向 | Zag 落点 |
|------|----------|----------|
| 编辑偏一行 / 空白打架 | 锚点 edit / patch | Phase H → C4 |
| 长任务断片 / 上下文爆 | 分层 prompt + compaction | Phase H → C5 |
| 跨会话偏好 / 重复交代 | Memory Repo（默认可关） | **C5 only**（[memory.md](./modules/memory.md)） |
| 弱模型硬撑 | Oracle pin + 可感知触发 | C6 |
| 不敢 auto-apply | change review | C4 |
| 危险命令 / 逃逸 | jail → OS sandbox | H → C7 |
| 扩展要改核心 | skills / hooks / MCP | C8 |
| 改 harness 变笨 | golden + contracts | Quality（H 起） |

详见 [maturity.md](./maturity.md) 与 [roadmap.md](./roadmap.md)。

## 刻意不做（当前）

- Amp 式 low–ultra 四档 Modes 整包解析层（用模型 pin + Oracle 代替）
- 云 thread / collab
- 企业 Missions / SDLC 云平台
- 一上来打磨 TUI（CLI + 锐度优先；TUI 属 C9）
- Phase H 内做 Memory 平台 / 云知识库（属 C5，默认关）
- 把 Zag 砍成「仅四工具」——学 Pi 的扩展纪律，不学阉割产品目标

## 双轨文档

| 轨 | 目录 | 目的 |
|----|------|------|
| Teaching | `chapters/00–03` | 学会 harness 形状 |
| Spec | `docs/modules`、`docs/phases` | 指导实现到 L2/L3 |
| Gaps | `docs/gaps` | 每章诚实列出离生产差什么 |

## 相关

- [README.md](./README.md) — 文档地图  
- [maturity.md](./maturity.md) — 成熟度真理源  
- [roadmap.md](./roadmap.md) — 阶段排期  
