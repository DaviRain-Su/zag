# Chapter 2 — 日用雏形：会话、项目说明、Context

> 对应 Teaching [Phase 2](../../docs/roadmap.md#phase-2--日用雏形会话--context)。
> **状态：tutorial-complete**（不是 production-ready）。
> **代码与本章同步。** 先读业务文件。

**一句话：** 关掉进程还能续聊；项目约定进 system；超长历史只给模型看裁切后的 **view**。

---

## 0. 先跑起来

```bash
export DEEPSEEK_API_KEY=sk-...

# 第一次：创建会话文件 + 注入本仓库 AGENTS.md（路径必须相对工作区）
zig build run -- --yolo -s .zag/sessions/default.jsonl -v "记住暗号是 banana-phase2。只回复已记住。"

# 第二次：新进程，显式 resume（-c 默认同一路径）
zig build run -- --yolo -c -v "我刚才让你记住的暗号是什么？"
```

默认 resume 路径：`.zag/sessions/default.jsonl`。

| Flag | 含义 |
|------|------|
| `-s` / `--session PATH` | **create_new**：创建会话；路径已存在则失败；相对工作区路径 |
| `-c` / `--continue` | **resume_existing**：续聊；默认路径 `.zag/sessions/default.jsonl`；缺/坏/不支持/占用 → 失败 |
| `--no-project` | 不注入 AGENTS.md / README |

> 加载失败（缺文件/坏文件/不支持版本/被其他进程占用）**不会**自动当新会话 seed；CLI 报错退出。
> `open_or_create` 仅作 SDK convenience，CLI 不映射该模式。
> Save 失败对调用方可见；原子替换在软件崩溃路径上保留旧文件（**不**声称 fsync/掉电耐久）。

---

## 1. 业务心智模型

```
Session (full transcript, durable)
        │
        │  viewForModel()
        ▼
   context view  ──► provider.chat
        │
        ▼
   append assistant / tools
        │
        ▼
   save JSONL (if path set)
```

| 层 | 职责 |
|----|------|
| **Full transcript** | 真相：审计、续聊、落盘 |
| **Context view** | 本轮给模型的窗口（可丢旧消息） |
| **Project instructions** | 启动时并入 **system**（不是假 user） |

---

## 2. 只看业务：读哪些文件？

| 顺序 | 文件 | 业务点 |
|------|------|--------|
| 1 | core `session_store.zig` | JSONL 字段与 round-trip |
| 2 | coding `project.zig` | AGENTS.md 加载与 compose system |
| 3 | core `context.zig` | view：system + 尾部 + 预算 |
| 4 | coding `agent.zig` | Session.start / save / reply 自动存 |
| 5 | core `loop.zig` | chat 前 `viewForModel` |

（core = `packages/zag-agent-core/src`，coding = `packages/zag-coding-agent/src`）

---

## 3. 会话文件最小字段

每行一个 JSON：

```json
{"v":1,"type":"zag_session"}
{"role":"system","content":"..."}
{"role":"user","content":"..."}
{"role":"assistant","content":"...","tool_calls":[{"id":"...","name":"...","arguments":"..."}]}
{"role":"tool","tool_call_id":"...","content":"..."}
```

- 有 tool_calls 的 assistant 必须与随后的 tool 行成对，否则续聊会乱。
- 加载失败（缺文件/坏文件/不支持 schema/占用）→ **typed error**，不会在同一路径 seed 新会话。
- Header 仅允许首行且 `type` 精确为 `zag_session`；版本字段必须是整数。

---

## 4. 哪些进 system / user / 临时？

| 内容 | 放哪 | 原因 |
|------|------|------|
| 身份、工具规则 | system（base） | 全程有效 |
| AGENTS.md / README 摘要 | system（compose） | 项目约定，续聊也要在 |
| 用户本轮话 | user | 对话 |
| tool 结果 | tool | 协议 |
| 「省略了 N 条历史」 | 临时 system note（仅 view） | 告诉模型被裁过；**不写回** full transcript |

---

## 5. Context 策略（Phase 2 故意糙）

默认（可调 `context.Options`）：

- 保留全部 **leading system**
- 非 system **尾部最多 48 条**
- **约 120k 字符** 软预算，从前沿丢掉
- 不对齐到「裸 tool」：避免 tool 结果没有对应 assistant tool_calls
- **不做** LLM 摘要（Phase 后可加）

坑（读完应能说）：

- **丢历史**：模型忘早期约束；所以项目约定要在 system。
- **摘要**：省 token 但可能编造——Phase 2 宁可不做。

---

## 6. 练习

1. 打开 `.zag/sessions/default.jsonl`，对照 tool 往返是否成对。
2. 改 `max_tail_messages = 4` 跑单测 `view keeps systems…`。
3. 加一个自己的 `AGENTS.md` 规则，看 system compose 是否带上。
4. **不要**在 loop 里直接截断 transcript 数组——业务边界是 view。

---

## 7. 读完应能回答

- 哪些进 system、user、每轮临时？
- 丢历史 vs 摘要各有什么坑？
- 会话文件最小字段有哪些？
- 为什么 full transcript 与 model view 要分开？

---

## 8. 生产缺口

Session open/save 已按 [D-006](../../docs/decisions/active/D-006-session-open-and-durability.md) 到 **L2**（create/resume 分离、原子保存、可见错误、单 writer）。
仍未声称：fsync/掉电耐久、session 路径 symlink containment、fork/tree（L3/C5）。
Context 裁切与四层 prompt 见 **[docs/gaps/02-session.md](../../docs/gaps/02-session.md)** 与 [context-compaction](../../docs/modules/context-compaction.md)。

---

## 9. 下一步

- **[Chapter 3 — 边界雏形](../03-production/README.md)**（tutorial-complete；章名历史遗留）
- 硬化：[Chapter H](../H-harden/README.md)
- 对照：Aider repo map / Hyper sessions

**Tag：** `ch2-session` / `phase-2`
