# Zag

**A coding agent in Zig** — from a minimal tool loop to something you might actually ship.

> Zig 是载体；**harness**（循环、工具、上下文、权限）是主角。

## 文档（从这里开始）

| 文档 | 内容 |
|------|------|
| **[docs/roadmap.md](./docs/roadmap.md)** | 从零实现四阶段路线：每阶段目标、实现清单、读什么、验收 |
| **[docs/references.md](./docs/references.md)** | 参考资料与链接全集（Ball / Aider / goose / Hyper 等） |

## 阶段一览

```
Phase 0  最小真理     loop + 只读 tools
Phase 1  真·Code      写文件 + 权限
Phase 2  日用级       会话 / context / 项目说明
Phase 3  生产向       沙箱 / 可观测 / 稳定边界
```

## 状态

**Phase 0 已落地**：最小 agent loop + 只读 tools（`list_dir` / `read_file`）+ OpenAI 兼容 provider。

```text
src/
  agent/      # message、tool、loop
  runtime/    # fs_tools（只读）
  provider/   # openai-compatible chat
  main.zig    # CLI：one-shot / REPL
chapters/
  00-loop/    # 本章说明
```

### 快速开始（Phase 0）

```bash
# 任选一个 API key（优先级：ZAG_ > DEEPSEEK_ > XAI_ > OPENAI_）
export DEEPSEEK_API_KEY=...   # 默认 deepseek-chat @ api.deepseek.com
# export XAI_API_KEY=...
# export OPENAI_API_KEY=...

zig build run -- -v "这个项目有几个源文件？读一下 build.zig 摘要。"
```

可用 `ZAG_BASE_URL` / `ZAG_MODEL` 覆盖任意 preset 的默认值。  
详见 [chapters/00-loop](./chapters/00-loop/README.md)。

## 相关

- 工业对照（本机）：Hyper / Grok Build 等 Rust Code Agent 实现  
- 教学标杆：[How to Build an Agent (Go)](https://ampcode.com/how-to-build-an-agent)  

## 许可

待定（实现开源时再补 `LICENSE`）。
