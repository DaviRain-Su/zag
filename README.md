# Zag

**A coding agent in Zig** — from a minimal tool loop to something you might actually ship.

> Zig 是载体；**harness**（循环、工具、上下文、权限）是主角。  
> **代码与 `chapters/` 教程同步演进。**

## 文档（从这里开始）

| 文档 | 内容 |
|------|------|
| **[chapters/00-loop](./chapters/00-loop/README.md)** | Phase 0：loop + 只读 tools |
| **[chapters/01-edit-permissions](./chapters/01-edit-permissions/README.md)** | Phase 1：write / shell + ask\|yolo |
| **[docs/roadmap.md](./docs/roadmap.md)** | 四阶段路线 |
| **[docs/architecture.md](./docs/architecture.md)** | 模块边界与协议 |
| **[docs/references.md](./docs/references.md)** | 外部资料 |

## 阶段

```
Phase 0  最小真理     loop + 只读 tools          ✅
Phase 1  真·Code      write/shell + 权限         ✅
Phase 2  日用级       会话 / context / 项目说明
Phase 3  生产向       沙箱 / 可观测 / 稳定边界
```

## 快速开始

需要 Zig **0.16**。

```bash
export DEEPSEEK_API_KEY=sk-...   # 默认 deepseek-v4-flash

zig build test
zig build run -- -v "这个项目有几个源文件？"

# Phase 1：写文件 / shell（默认会确认）
zig build run -- -v "用 write_file 写 hello_zag.txt，内容 hello"

# 跳过确认（仅本地可信环境）
zig build run -- --yolo -v "run_shell: echo hi"
```

| Flag | 含义 |
|------|------|
| `-v` | tool / permission 日志 |
| `--ask` | 写/shell 要确认（默认） |
| `--yolo` | 全部自动允许 |

```text
src/
  agent/      # ★ 业务：loop / permissions / Agent / Transcript …
  runtime/    # fs_tools · edit_tools
  provider/   # HTTP JSON + env
  main.zig
chapters/
  00-loop/
  01-edit-permissions/
```

业务入口：`src/agent/loop.zig`、`src/agent/permissions.zig`。

## 相关

- 教学标杆：[How to Build an Agent (Go)](https://ampcode.com/how-to-build-an-agent)  
- 工业对照：Hyper / goose  

## 许可

待定。
