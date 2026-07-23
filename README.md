# Zag

**A coding agent in Zig** — from a minimal tool loop to something you might actually ship.

> Zig 是载体；**harness**（循环、工具、上下文、权限、会话）是主角。  
> **代码与 `chapters/` 教程同步演进。**

## 文档

| 文档 | 内容 |
|------|------|
| [chapters/00-loop](./chapters/00-loop/README.md) | Phase 0：loop + 只读 tools |
| [chapters/01-edit-permissions](./chapters/01-edit-permissions/README.md) | Phase 1：write / shell + ask\|yolo |
| [chapters/02-session-context](./chapters/02-session-context/README.md) | Phase 2：会话 JSONL + AGENTS.md + context |
| [docs/roadmap.md](./docs/roadmap.md) | 四阶段路线 |
| [docs/architecture.md](./docs/architecture.md) | 模块边界 |
| [docs/references.md](./docs/references.md) | 外部资料 |
| [AGENTS.md](./AGENTS.md) | 本仓库项目约定（会被 agent 注入 system） |

## 阶段

```
Phase 0  最小真理     loop + 只读 tools          ✅
Phase 1  真·Code      write/shell + 权限         ✅
Phase 2  日用级       会话 / context / 项目说明   ✅
Phase 3  生产向       沙箱 / 可观测 / 稳定边界
```

## 快速开始

需要 Zig **0.16**。

```bash
export DEEPSEEK_API_KEY=sk-...

zig build test

# 只读探索
zig build run -- -v "这个项目有几个源文件？"

# 写文件（默认会确认；本地可用 --yolo）
zig build run -- --yolo -v "用 write_file 写 hello.txt 内容 hello"

# 会话续聊（默认 .zag/sessions/default.jsonl）
zig build run -- --yolo -c -v "记住暗号是 banana"
zig build run -- --yolo -c -v "暗号是什么？"
```

| Flag | 含义 |
|------|------|
| `-v` | 详细日志 |
| `--ask` / `--yolo` | 权限 |
| `-c` / `--continue` | 续会话 |
| `-s PATH` | 会话文件路径 |
| `--no-project` | 不注入 AGENTS.md |

```text
src/agent/     ★ 业务
src/runtime/   本机能力
src/provider/  HTTP / env
chapters/      与代码同步的教程
```

业务入口：`loop.zig` · `permissions.zig` · `session_store.zig` · `context.zig` · `project.zig`。

## 许可

待定。
