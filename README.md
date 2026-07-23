# Zag

**A coding agent in Zig** — teaching harness first, then harden to a production floor.

> Zig 是载体；**harness** 是主角。代码与 `chapters/` 同步演进。

## 状态（请先读这）

| 轨道 | 状态 |
|------|------|
| Teaching Phase 0–3 | ✅ **tutorial-complete** |
| Production Floor（Phase H） | ❌ **未完成** — 当前主线 |
| Capability C4–C9 | 未开始 |

> Phase 3 教程演示了 jail / policy / trace，**不等于**生产就绪。权威矩阵：[docs/maturity.md](./docs/maturity.md)。

## 文档

| 文档 | 内容 |
|------|------|
| **[docs/README.md](./docs/README.md)** | 文档地图（推荐入口） |
| [docs/vision.md](./docs/vision.md) | 定位与吸收原则 |
| [docs/maturity.md](./docs/maturity.md) | L0–L3 成熟度真理源 |
| [docs/roadmap.md](./docs/roadmap.md) | Teaching / H / Capability / Quality |
| [docs/architecture.md](./docs/architecture.md) | 现状 vs 目标分层 |
| [chapters/00-loop](./chapters/00-loop/README.md) | Teaching 0：loop |
| [chapters/01-edit-permissions](./chapters/01-edit-permissions/README.md) | Teaching 1：编辑 + 权限 |
| [chapters/02-session-context](./chapters/02-session-context/README.md) | Teaching 2：会话 + context |
| [chapters/03-production](./chapters/03-production/README.md) | Teaching 3：边界雏形（历史目录名） |
| [chapters/H-harden](./chapters/H-harden/README.md) | Phase H 硬化（planned） |
| [SECURITY.md](./SECURITY.md) | 安全默认与「尚未」 |

## 阶段

```
Teaching 0  loop + 只读                 ✅ tutorial
Teaching 1  write/shell + ask|yolo      ✅ tutorial
Teaching 2  会话 / AGENTS.md / context  ✅ tutorial
Teaching 3  jail / shell policy / trace ✅ tutorial（≠ 生产完成）
Phase H     硬化到 maturity L2          ❌ 下一步
C4–C9       锐度 / 编排 / 沙箱 / 扩展…   依赖 H
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
| `--ask` / `--yolo` | 人工权限（默认 ask；生产勿默认 yolo） |
| `--shell-policy protect\|off` | 命令策略（默认 protect） |
| `-c` / `--session` | 会话 JSONL |
| `--trace [PATH]` | 审计 JSONL |
| `--no-project` | 不注入 AGENTS.md |

```text
src/agent/          ★ harness 业务
src/runtime/        FS · shell
packages/zag-ai/    模型接入
```

版本号见 `src/root.zig` / `build.zig.zon`（**≠** 生产底线已达成）。

### Monorepo：`packages/zag-ai`

```bash
cat > .zag/config.json <<'EOF'
{ "provider": "deepseek", "model": "deepseek-v4-flash", "stream": true }
EOF
zig build run -- --yolo --stream -v "hello"
```

| 变量 / 文件 | 作用 |
|-------------|------|
| `DEEPSEEK_API_KEY` 等 | 自动探测 |
| `ZAG_PROVIDER` / `ZAG_MODEL` | 显式选择 |
| `.zag/config.json` | 非密钥配置 |
| `--stream` | SSE 流式 |

## 许可

待定。
