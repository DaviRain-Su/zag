# Zag

**A coding agent in Zig** — from a minimal tool loop to something you might actually ship.

> Zig 是载体；**harness** 是主角。代码与 `chapters/` **同步**演进。

## 文档

| 文档 | 内容 |
|------|------|
| [chapters/00-loop](./chapters/00-loop/README.md) | Phase 0：loop + 只读 |
| [chapters/01-edit-permissions](./chapters/01-edit-permissions/README.md) | Phase 1：编辑 + 权限 |
| [chapters/02-session-context](./chapters/02-session-context/README.md) | Phase 2：会话 + context |
| [chapters/03-production](./chapters/03-production/README.md) | Phase 3：jail + policy + trace |
| [SECURITY.md](./SECURITY.md) | 安全默认与审计 |
| [docs/architecture.md](./docs/architecture.md) | 模块边界 |
| [docs/roadmap.md](./docs/roadmap.md) | 路线图 |
| [docs/diagrams/](./docs/diagrams/) | tldraw 架构图 |

## 阶段

```
Phase 0  最小真理     loop + 只读                 ✅
Phase 1  真·Code      write/shell + ask|yolo      ✅
Phase 2  日用级       会话 / AGENTS.md / context  ✅
Phase 3  生产向       jail / shell policy / trace ✅  v0.3.0
```

## 快速开始

Zig **0.16**。

```bash
export DEEPSEEK_API_KEY=sk-...

zig build test
zig build run -- --yolo -v --trace "list_dir ."

# 应被 jail 拒绝：
zig build run -- --yolo -v "read_file /etc/passwd"
```

| Flag | 含义 |
|------|------|
| `--ask` / `--yolo` | 人工权限 |
| `--shell-policy protect\|off` | 命令策略（默认 protect） |
| `-c` / `--session` | 会话 JSONL |
| `--trace [PATH]` | 审计 JSONL |
| `--no-project` | 不注入 AGENTS.md |

```text
src/agent/     ★ 业务（含 workspace / shell_policy / trace）
src/runtime/   FS · shell 实现
src/provider/  HTTP · env
```

版本：`0.3.0`。

## 许可

待定。
