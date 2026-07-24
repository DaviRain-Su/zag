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
| **[docs/INDEX.md](./docs/INDEX.md)** | 文档桶地图（Product Spec / Active / Complete / Reference / Quality） |
| [docs/vision.md](./docs/vision.md) | 定位与吸收原则 |
| [docs/maturity.md](./docs/maturity.md) | L0–L3 成熟度真理源 |
| [docs/roadmap.md](./docs/roadmap.md) | Phase H P0/P1、SDK/headless Gate、Capability DAG |
| [production-floor assessment](./docs/plan/analysis/2026-07-24-production-floor-assessment.md) | 2026-07-24 评估、P0/P1/P2 与实施任务 |
| [docs/architecture.md](./docs/architecture.md) | 分层：Loop⊂Graph · Tool runtime · WireAdapter · 产品壳 |
| [chapters/00-loop](./chapters/00-loop/README.md) | Teaching 0：loop |
| [chapters/01-edit-permissions](./chapters/01-edit-permissions/README.md) | Teaching 1：编辑 + 权限 |
| [chapters/02-session-context](./chapters/02-session-context/README.md) | Teaching 2：会话 + context |
| [chapters/03-production](./chapters/03-production/README.md) | Teaching 3：jail / policy / trace（**目录名历史遗留**；≠ 生产完成） |
| [chapters/H-harden](./chapters/H-harden/README.md) | Phase H P0/P1 硬化（in progress） |
| [docs/modules/memory.md](./docs/modules/memory.md) | Memory Repo 规格（C5；H 不做） |
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
# or: zig build run -- --yolo -v --trace -- "list_dir ."

# 应被 jail 拒绝：
zig build run -- --yolo -v "read_file /etc/passwd"
```

| Flag | 含义 |
|------|------|
| `--ask` / `--yolo` | 人工权限（默认 ask；生产勿默认 yolo） |
| `--shell-policy protect\|off` | 命令策略（默认 protect） |
| `-c` / `--session` | 会话 JSONL |
| `--trace` / `--trace=PATH` | 审计 JSONL（默认 `.zag/traces/latest.jsonl`；裸词不当路径） |
| `--no-project` | 不注入 AGENTS.md |

```text
src/main.zig                    可执行入口（几行 → zag-cli.run）
src/root.zig                    umbrella 再导出（库消费者）
packages/zag-cli/               产品壳：flags · resolve · REPL · one-shot
packages/zag-coding-agent/      Agent 门面 · toolset · WireProvider · runtime tools
packages/zag-agent-core/        loop · 纯 Provider 端口 · session · permissions
packages/zag-ai/                WireAdapter · resolve · catalog
packages/openai-zig/            线协议 · transport · OpenAPI
```

```text
# consumer → dependency
main → zag-cli → coding-agent → agent-core → zag-types
                         └────→ zag-ai ─┬→ zag-types
                                       └→ openai-zig
```

详见 [docs/architecture.md](./docs/architecture.md)。

版本号见 `src/root.zig` / `build.zig.zon`（**≠** 生产底线已达成）。

### 配置示例

```bash
cat > .zag/config.json <<'EOF'
{
  "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "stream": true,
  "temperature": 0.2,
  "max_tokens": 4096,
  "chat_retries": 2
}
EOF
zig build run -- --yolo --stream -v "hello"
```

| 变量 / 文件 | 作用 |
|-------------|------|
| `DEEPSEEK_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` 等 | 自动探测（见 `packages/zag-ai` presets） |
| `ZAG_PROVIDER` / `ZAG_MODEL` | 显式选择 |
| `.zag/config.json` | 非密钥配置 |
| `--stream` | SSE 流式 |

厂商表与 wire 矩阵见 [packages/zag-ai/README.md](./packages/zag-ai/README.md)。

## 许可

待定。
