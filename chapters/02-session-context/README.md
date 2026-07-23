# Chapter 2 — 日用级：会话、项目说明、Context

> 对应 [Phase 2](../../docs/roadmap.md#phase-2--日用级能连续干活)。  
> **代码与本章同步。** 先读业务文件。

**一句话：** 关掉进程还能续聊；项目约定进 system；超长历史只给模型看裁切后的 **view**。

---

## 0. 先跑起来

```bash
export DEEPSEEK_API_KEY=sk-...

# 第一次：写入会话 + 注入本仓库 AGENTS.md
zig build run -- --yolo -c -v "记住暗号是 banana-phase2。只回复已记住。"

# 第二次：新进程，续同一会话
zig build run -- --yolo -c -v "我刚才让你记住的暗号是什么？"
```

默认会话路径：`.zag/sessions/default.jsonl`。

| Flag | 含义 |
|------|------|
| `-c` / `--continue` | 续聊；默认路径 `.zag/sessions/default.jsonl` |
| `-s` / `--session PATH` | 指定 JSONL 路径（保存/加载） |
| `--no-project` | 不注入 AGENTS.md / README |

验收：

1. 两进程后仍能答对「暗号」。  
2. 有 `AGENTS.md` 时，agent 行为更贴项目约定（system 里可见 Project instructions）。  
3. 历史很长时，`-v` 仍正常；全量在磁盘/内存 transcript，发给模型的是 view。

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
| 1 | `src/agent/session_store.zig` | JSONL 字段与 round-trip |
| 2 | `src/agent/project.zig` | AGENTS.md 加载与 compose system |
| 3 | `src/agent/context.zig` | view：system + 尾部 + 预算 |
| 4 | `src/agent/agent.zig` | Session.start / save / reply 自动存 |
| 5 | `src/agent/loop.zig` | chat 前 `viewForModel` |

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
- 加载失败（缺文件/坏文件）→ 当作新会话 seed。

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

## 8. 下一步

- **[Chapter 3 — 生产向](../03-production/README.md)**（已实现）  
- 对照：Aider repo map / Hyper sessions  

**Tag：** `ch2-session` / `phase-2`
