# Zag

**A coding agent in Zig** — from a minimal tool loop to something you might actually ship.

> Zig 是载体；**harness**（循环、工具、上下文、权限）是主角。

## 文档（从这里开始）

| 文档 | 内容 |
|------|------|
| **[chapters/00-loop](./chapters/00-loop/README.md)** | **Phase 0 教程**：怎么跑、心智模型、逐文件导读、练习 |
| **[docs/roadmap.md](./docs/roadmap.md)** | 四阶段路线：目标、读什么、验收 |
| **[docs/architecture.md](./docs/architecture.md)** | 当前模块边界与协议 |
| **[docs/references.md](./docs/references.md)** | 外部资料（Ball / Aider / goose / Hyper…） |

## 阶段一览

```
Phase 0  最小真理     loop + 只读 tools     ← 已实现 + 教程
Phase 1  真·Code      写文件 + 权限
Phase 2  日用级       会话 / context / 项目说明
Phase 3  生产向       沙箱 / 可观测 / 稳定边界
```

## 快速开始（Phase 0）

需要 Zig **0.16**。

```bash
# 推荐 DeepSeek（默认模型 deepseek-v4-flash）
export DEEPSEEK_API_KEY=sk-...

zig build test
zig build run -- -v "这个项目有几个源文件？读一下 build.zig 摘要。"
```

| 环境变量 | 说明 |
|----------|------|
| `DEEPSEEK_API_KEY` | DeepSeek；默认 `https://api.deepseek.com/v1` + **`deepseek-v4-flash`** |
| `XAI_API_KEY` / `OPENAI_API_KEY` | 其它厂商 preset |
| `ZAG_API_KEY` + `ZAG_BASE_URL` + `ZAG_MODEL` | 完全自定义 |
| `ZAG_MODEL` | 覆盖当前 preset 的模型（任意 key 都可配合使用） |

Key 优先级：`ZAG_API_KEY` → `DEEPSEEK_API_KEY` → `XAI_API_KEY` → `OPENAI_API_KEY`。

```text
src/
  agent/      # message、tool、loop
  runtime/    # fs_tools（只读）
  provider/   # config + openai-compatible chat
  main.zig
chapters/
  00-loop/    # 本章教程（与代码同步）
```

## 相关

- 工业对照（本机）：Hyper / Grok Build 等  
- 教学标杆：[How to Build an Agent (Go)](https://ampcode.com/how-to-build-an-agent)  

## 许可

待定（实现开源时再补 `LICENSE`）。
