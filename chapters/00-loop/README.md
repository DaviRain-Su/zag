# Chapter 0 — 最小真理：Agent Loop

对应路线图 [Phase 0](../../docs/roadmap.md#phase-0--最小真理能跑的-loop)。

## 心智模型

```
用户消息
   │
   ▼
┌──────────────────┐
│  messages[]      │  system / user / assistant / tool
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  provider.chat   │  模型决定：说完 or call tool
└────────┬─────────┘
         │
    ┌────┴────┐
    │ tool?   │
    └────┬────┘
     no  │  yes
     │   ▼
     │  本地执行 list_dir / read_file
     │   │
     │   ▼
     │  结果以 role=tool 回灌 messages
     │   │
     │   └──► 再调 provider
     ▼
   输出最终回答
```

- **谁决定 call tool？** 模型  
- **谁执行？** harness（本仓库的 loop + tool registry）  
- **结果放哪？** transcript 里的 tool message  

这就是 harness：模型只是引擎。

## 本仓库落点

| 路径 | 职责 |
|------|------|
| `src/agent/message.zig` | 消息 / tool_call 类型 |
| `src/agent/tool.zig` | tool 定义 + 注册表 + 参数解析 |
| `src/agent/loop.zig` | 循环直到模型不再 call tool |
| `src/provider/openai.zig` | OpenAI 兼容 Chat Completions |
| `src/runtime/fs_tools.zig` | `list_dir`、`read_file` |
| `src/main.zig` | CLI（one-shot / REPL） |

## 怎么跑

```bash
# 任选一个 key
export XAI_API_KEY=...          # 默认 base https://api.x.ai/v1
# 或
export OPENAI_API_KEY=...       # 默认 base https://api.openai.com/v1
# 或
export ZAG_API_KEY=...
export ZAG_BASE_URL=https://...
export ZAG_MODEL=grok-4-latest

zig build run -- -v "这个项目有几个源文件？读一下 build.zig 摘要。"
```

验收：Agent **只靠 tool** 答对，stderr（`-v`）能看到 tool 序列。

## 故意不做（留给后面）

写文件、shell、权限、会话落盘、压缩、MCP、TUI。

## 建议阅读

1. Thorsten Ball — *How to Build an Agent*  
2. 对照本目录代码里的 loop，画出自己的状态图  
