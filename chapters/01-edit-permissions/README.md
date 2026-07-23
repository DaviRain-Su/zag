# Chapter 1 — 真·Code Agent：编辑 + 权限

> 对应路线图 [Phase 1](../../docs/roadmap.md#phase-1--真code-agent能改代码)。  
> **先读业务，再读 runtime。** 与代码同步维护。

**一句话：** 写文件和 shell 只是另一种 tool；**危险的是默认允许**，所以 harness 要加权限门闩。

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
| `--ask`（默认） | 只读自动过；`write_file` / `run_shell` 要确认 |
| `--yolo` | 全部自动允许 |
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
 permission gate ── deny ──► tool 结果 = "permission denied…" ──► 回灌
    │
   allow
    │
    ▼
 registry.execute ──► tool 结果 ──► 回灌
```

| 风险 | 工具 | ask 模式 |
|------|------|----------|
| read | `list_dir`, `read_file` | 自动允许 |
| write | `write_file` | 问人 |
| execute | `run_shell` | 问人 |

**yolo** = 跳过询问（显式 opt-in）。生产默认很少 yolo——一句话误伤可写盘/执行命令。

---

## 2. 只看业务：读哪些文件？

| 顺序 | 文件 | 业务点 |
|------|------|--------|
| 1 | `src/agent/permissions.zig` | Mode / Risk / Gate / 拒绝文案 |
| 2 | `src/agent/loop.zig` | 执行前 `decide`；deny → soft error |
| 3 | `src/agent/agent.zig` | `permission_mode` 接线 |
| 4 | `src/agent/toolset.zig` | `Phase1Storage` 四个 tool |
| 5 | `src/runtime/edit_tools.zig` | write / shell **实现**（基建） |

Phase 0 文件（message / transcript / provider port）不变。

---

## 3. 权限状态机（读完应能默画）

```
          ┌─────────────┐
          │ tool_call   │
          └──────┬──────┘
                 ▼
          ┌─────────────┐
          │ riskOf(name)│
          └──────┬──────┘
         read    │    write/execute
          │      │         │
          ▼      │    ┌────┴────┐
        allow    │    │ mode?   │
                 │    └────┬────┘
                 │   yolo  │  ask
                 │    │    ▼
                 │    │  human y/N
                 │    │    │
                 │    │  y │  N
                 ▼    ▼    ▼  ▼
               execute   deny→string
```

拒绝**不是**抛错退出 loop，而是：

```text
role=tool  content="error: permission denied for tool 'write_file'..."
```

模型可以改主意或向用户解释——这是 harness 行为，不是模型魔法。

---

## 4. 新工具契约（模型看见什么）

### `write_file`

| 参数 | 含义 |
|------|------|
| `path` | 相对工作区路径 |
| `content` | **整文件**内容（Phase 1 不做 diff/patch） |

失败：返回 error 字符串（路径无效、写失败、过大）。  
成功：`ok: wrote N bytes to path`。

### `run_shell`

| 参数 | 含义 |
|------|------|
| `command` | 交给 `/bin/sh -c` |

- 超时约 30s → 明确 timeout 文案  
- stdout/stderr 截断  
- 结果里带 `exit_code` / `signal`  

Phase 1 **不做**命令白名单（那是 Phase 3 策略）；权限层先做人审。

---

## 5. 和 Phase 0 的边界

| 仍在业务层 | 仍在基建层 |
|------------|------------|
| 何时问人 / 何时放行 | `createDirPath` / `process.run` |
| deny 如何回灌 | HTTP provider |
| Toolset 包含哪些名 | JSON 参数解析细节 |

**不要**在 loop 里写「如果是 write_file 就 fsync」——那是 runtime。

---

## 6. 练习

1. 画权限状态机，对照 `permissions.zig` + `loop.zig`。  
2. 用 mock provider + `Gate.denyAllDangerous()` 写测试：断言 transcript 含 `permission denied`（仓库已有类似测试）。  
3. **不要**默认把 CLI 改成 yolo；想清楚什么时候才该 `--yolo`。  
4. （可选）给 `run_shell` 加「命令预览截断」优化，仍走同一 Gate。

---

## 7. 读完应能回答

- 写文件失败、命令超时，loop 里怎么表现给模型？  
- 「先问再改」状态机能不能画出来？  
- 为什么生产很少默认 yolo？  
- deny 为什么用 tool message 而不是中断进程？

---

## 8. 下一步

- Phase 2：会话落盘、context、`AGENTS.md`  
- Phase 3：路径 jail、命令策略、结构化 trace  
- 对照：Aider 编辑策略 / Hyper `permissionMode`

**Tag 建议：** `ch1-edit` / `phase-1`
