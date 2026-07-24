# Chapter 1 — 真·Code Agent：编辑 + 权限

> 对应 Teaching [Phase 1](../../docs/roadmap.md#phase-1--真code编辑--权限)。
> **状态：tutorial-complete**（不是 production-ready 全量）。
> 权限矩阵与自定义 Tool 合同见 [D-007](../../docs/decisions/active/D-007-tool-runtime-descriptor.md) / [permissions](../../docs/modules/permissions.md)（**L2**）。
> **先读业务，再读 runtime。** 与代码同步维护。

**一句话：** 写文件和 shell 只是另一种 tool；**危险的是默认允许**，所以 harness 要加权限门闩——且风险来自 **descriptor**，不是工具名字符串。

---

## 0. 先跑起来

```bash
export DEEPSEEK_API_KEY=sk-...

# 默认 ask：write / shell 会提示 y/N
zig build run -- -v "在 /tmp 不行；请在当前目录用 write_file 写一个 hello_zag.txt，内容为 hello"

# 自动批准（本地玩具用；生产慎用）
zig build run -- --yolo -v "给 README 加一行注释太危险；改用 write_file 写 toys/version_note.txt 内容为 phase1"
```

| Flag | 含义 |
|------|------|
| `--ask`（默认） | 只读自动过；`write` / `execute` 风险要确认 |
| `--yolo` | 全部自动允许（仍受 jail / shell policy 约束） |
| `-p ask\|yolo` | 同上 |
| `-v` | 打 tool / permission 事件 |

验收（roadmap）：

1. 让 agent「写一个小文件」→ **y** 后磁盘上有内容；**N** 后文件不出现。
2. `run_shell` 例如 `echo hi` → 输出进 transcript。
3. 拒绝后模型收到 `permission denied` 字符串，不崩溃。

---

## 1. 业务心智模型（在 Phase 0 上多一扇门）

```
tool_call
    │
    ▼
 registry.find ── unknown ──► soft unknown_tool（不推断权限）
    │
  descriptor
    │
    ▼
 permission gate ── deny ──► tool 结果 = "permission denied…" ──► 回灌
    │
   allow
    │
    ▼
 jail (若 workspace.path_field) / shell policy (若 shell.command_argument)
    │
    ▼
 registry.execute(instance) ──► tool 结果 ──► 回灌
```

| 风险（descriptor.capabilities.risk） | 典型工具 | ask 模式 |
|------|------|----------|
| read | `list_dir`, `read_file`, `grep`, `glob` | 自动允许 |
| write | `write_file`, `search_replace` | 问人 |
| execute | `run_shell` | 问人 |

分类**不**来自名字列表。自定义 mutating Tool 只要声明 `risk=write|execute`，就会被 `denyAllDangerous` / ask 与内置一视同仁。

**yolo** = 跳过询问（显式 opt-in）。生产默认很少 yolo——一句话误伤可写盘/执行命令。

---

## 2. 只看业务：读哪些文件？

| 顺序 | 文件 | 业务点 |
|------|------|--------|
| 1 | L0 `zag-types` ToolRisk / ToolCapabilities / ToolDescriptor | 模型 schema 与本地安全元数据分离 |
| 2 | core `tool.zig` | Registration fail-closed、instance-aware Handler |
| 3 | core `permissions.zig` | Mode / Risk / Gate（descriptor 驱动） |
| 4 | core `loop.zig` | find → permission → jail → shell → execute |
| 5 | coding `agent.zig` | `permission_mode` 接线 |
| 6 | coding `toolset.zig` / `runtime/*` | 内置 tool 显式 capabilities |

（core = `packages/zag-agent-core/src`，coding = `packages/zag-coding-agent/src`）

---

## 3. 权限状态机（读完应能默画）

```
          ┌─────────────┐
          │ tool_call   │
          └──────┬──────┘
                 ▼
          ┌─────────────┐
          │ find by name│
          └──────┬──────┘
         missing │    found → descriptor.risk
          │      │         │
          ▼      │    read │    write/execute
   unknown_tool  │     │   │         │
          soft   │     ▼   │    ┌────┴────┐
                 │   allow │    │ mode?   │
                 │         │    └────┬────┘
                 │         │   yolo  │  ask
                 │         │    │    ▼
                 │         │    │  human y/N
                 │         │    │    │
                 │         │    │  y │  N
                 ▼         ▼    ▼    ▼  ▼
               soft     execute   deny→string
```

拒绝**不是**抛错退出 loop，而是：

```text
role=tool  content="error: code=permission_denied message=…"
```

模型可以改主意或向用户解释——这是 harness 行为，不是模型魔法。

---

## 4. 新工具契约（模型看见什么）

模型只看见 `ToolDefinition`（name / description / parameters）。**不会**看见 risk、workspace、cancellation、instance。

### `write_file`

| 参数 | 含义 |
|------|------|
| `path` | 相对工作区路径 |
| `content` | **整文件**内容（Phase 1 不做 diff/patch） |

本地 descriptor：`risk=write`，`workspace=path_field("path")`。

### `run_shell`

| 参数 | 含义 |
|------|------|
| `command` | 交给 `/bin/sh -c` |

本地 descriptor：`risk=execute`，`shell=command_argument`（policy 不靠名字猜）。同步 handler 使用 `shell-v1` first line 区分 success/nonzero/signal/timeout/output-limit/process failure；每流 30 KiB，timeout/output-limit 不伪造 partial output。这里只覆盖 foreground direct child，不是 PTY/background/process-tree supervisor。

---

## 5. 和 Phase 0 的边界

| 仍在业务层 | 仍在基建层 |
|------------|------------|
| 何时问人 / 何时放行 | `createDirPath` / `process.run` |
| deny 如何回灌 | HTTP provider |
| Toolset 包含哪些名与 capabilities | JSON 参数解析细节 |

**不要**在 loop 里写「如果是 write_file 就 fsync」——那是 runtime。
**不要**用 `if (name == "run_shell")` 做安全分支——用 descriptor。

---

## 6. 练习

1. 画权限状态机，对照 `permissions.zig` + `loop.zig`。
2. 用 mock provider + `Gate.denyAllDangerous()` 写测试：断言 transcript 含 `permission_denied`（仓库已有类似测试）。
3. 注册一个**自定义** `risk=write` 的 Tool，确认同样被 deny——不能靠「名字不认识就当 read」。
4. **不要**默认把 CLI 改成 yolo；想清楚什么时候才该 `--yolo`。

---

## 7. 读完应能回答

- 写文件失败、命令超时，loop 里怎么表现给模型？
- 「先问再改」状态机能不能画出来？风险从哪来？
- 为什么生产很少默认 yolo？
- deny 为什么用 tool message 而不是中断进程？
- 自定义 mutating tool 为什么不能靠名字逃过 gate？

---

## 8. 生产缺口

整文件 `write_file` + 全局 ask/yolo 只够 **Teaching** 演示编辑路径。
**D-007 / h-tool-runtime-001 已补：** 强制 capabilities、instance-aware handler、Provider 只见 definitions；h-workspace-001 已补 symlink-aware file containment。
**Package 已落地、Gate pending：** `h-shell-001` 的 shell-v1 runtime/budget/direct-child/parsed-trace fixtures 已进入 suite，但独立/main Gate 与最终 Phase H audit 未完成。**仍不宣称：** mid-flight shell cancellation/process-tree ownership、一般 atomic write-fault guarantee、完整 Plan UX 与 path-domain 细策略。

---

## 9. 下一步

- **[Chapter 2 — 会话 / context / 项目说明](../02-session-context/README.md)**（tutorial-complete）
- 硬化：[Chapter H](../H-harden/README.md) · [gaps/01-edit](../../docs/gaps/01-edit.md)
- 对照：Aider 编辑策略 / Hyper `permissionMode`

**Tag 建议：** `ch1-edit` / `phase-1`
