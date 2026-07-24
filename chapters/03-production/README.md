# Chapter 3 — 边界雏形：Jail、策略、Trace

> 对应 Teaching [Phase 3](../../docs/roadmap.md#phase-3--边界雏形jail--policy--trace)。
> **状态：tutorial-complete**（**不是** Production Floor / 不是 production-ready）。
> 章名目录仍为 `03-production`（历史路径）；语义上是「安全边界雏形」。
> **代码与本章同步。**

**一句话：** 演示级默认拒绝危险路径/命令，并能用 JSONL **复盘**一次 run——距离「敢日用生产底线」见 Phase H。

---

## 0. 先跑起来

```bash
export DEEPSEEK_API_KEY=sk-...

# 工作区 jail：绝对路径应被拒绝（软错误回灌模型）
zig build run -- --yolo -v --trace "用 read_file 读 /etc/passwd"

# 正常相对路径 + 审计日志
zig build run -- --yolo -v --trace "list_dir 当前目录，只列名字"

# 查看 trace
cat .zag/traces/latest.jsonl
```

| Flag | 含义 |
|------|------|
| （默认）路径 jail | 始终开启 |
| `--shell-policy protect` | 默认；危险命令拒绝 |
| `--shell-policy off` | 关闭策略（仍受 ask/yolo） |
| `--trace [PATH]` | JSONL 审计（默认 `.zag/traces/latest.jsonl`） |

验收：

1. `SECURITY.md` 存在；版本号可查（`zag.version` / `build.zig.zon`）。
2. 工作区外路径失败且文案可解释。
3. `--trace` 文件能复盘 tool 序列。

---

## 1. 业务心智：三道门

```
tool_call
   │
   ▼
① permission (ask|yolo) ── deny ──► soft error
   │ allow
   ▼
② workspace jail (path tools) ── deny ──► soft error
   │ allow
   ▼
③ shell policy (run_shell) ── deny ──► soft error
   │ allow
   ▼
execute → tool result → transcript + trace
```

全部是 **soft fail**（tool message），loop 不崩。

---

## 2. 只看业务：读哪些文件？

| 顺序 | 文件 | 业务点 |
|------|------|--------|
| 1 | core `workspace.zig` | 路径 jail 规则 |
| 2 | core `shell_policy.zig` | 命令 denylist |
| 3 | core `trace.zig` | 结构化事件 |
| 4 | core `loop.zig` | 三道门顺序 |

（core = `packages/zag-agent-core/src`）
| 5 | `SECURITY.md` | 产品安全说明 |

---

## 3. 默认拒绝什么？

### 路径 jail（lexical + real containment）

- 绝对路径：`/etc/passwd`、`C:\…`
- 逃出工作区：`../secret`、`a/../../b`
- 空路径、内嵌 NUL
- **symlink/alias escape**：工作区内指向 **sibling outside** 的链接，read/list/grep/glob/write/search_replace → `code=jail_deny`
- 悬挂（dangling）或经父目录 escape 的 create/write 同样 deny；outside 字节不变

允许：`src/main.zig`、`./foo`、`a/b/../c`（仍在树内）；**目标仍在 root 内** 的 file/dir symlink 可读写列搜。

实现：`workspace.Root` / `Guard`（组件边界 contains）；loop 每 run 解析一次 root；built-in handler 再强制一次（raw Registry 不能绕过）。

**不是 OS sandbox**：check-time 软件约束 + trusted host；shell 另边界；TOCTOU 残余见 SECURITY。

### Shell policy（protect）

- `rm -rf /`、磁盘擦除、fork bomb
- `curl|bash` / `wget|sh` 一类管道进 shell
- 粗暴破坏性关键字（见源码列表）

**不是**完整沙箱：denylist 挡事故，不是对抗性 OS 隔离——单用户本机最小条。

---

## 4. Trace 字段

每行 JSON（`schema_version` 必现于 `run_start`；当前 = 1）：

```json
{"seq":0,"kind":"run_start","schema_version":1,"version":"0.5.0","permission":"yolo","shell_policy":"protect"}
{"seq":1,"kind":"turn","turn":1}
{"seq":2,"kind":"tool_call","id":"…","name":"list_dir","arguments":"…"}
{"seq":3,"kind":"jail_deny","name":"read_file","path":"/etc/passwd"}
{"seq":4,"kind":"run_end","turns":1,"ok":true,"stop_reason":"completed"}
```

`kind` 全集：`run_start` · `turn` · `assistant` · `usage` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `provider_retry` · `compaction` · `run_end`。

Production 合同（h-trace-001）：每 reply 一 run；显式 path 原子写 **最新完成 reply**；非破坏 preflight + atomic replace；provider/session/trace 失败 `ok=false` 且 stop_reason 不误标；写失败 → `TraceIoFailed`（不静默、不 OOM 伪装）；`Agent.deinit` 不发明成功终态。详见 [trace-observability](../../docs/modules/trace-observability.md)。

---

## 5. 读完应能回答

- 默认拒绝什么？如何审计一次危险操作？
- jail / policy / ask 三层各解决什么？
- 为什么 soft fail 而不是进程 exit？
- Teaching 3 与 Phase H（Production Floor）各解决什么？还缺哪些（见 gaps/03-safety）？

---

## 6. 练习

1. 加一条 shell denylist + 单元测试。
2. 用 mock loop 断言 `../x` 产生 `workspace jail` tool 结果（仓库已有绝对路径测试）。
3. 读一份 `--trace` 文件，手绘 tool 时序。

---

## 7. 扩展 OpenAI 兼容厂商

见 `packages/zag-ai/src/presets.zig`：加一行 `ProviderSpec`（id / base_url / env_keys / default_model / api_style）。
不要改 `openai_compat.zig` 除非线协议本身变了。OAuth 登录暂不支持（仅 env key）。

## 8. 生产缺口

File **symlink-aware containment**（h-workspace-001）、**truthful/versioned trace**（h-trace-001）与 known-key/shape **redaction**（h-redact-001）已在 Phase H 落地；Safety 整行仍因 doctor 未实现保持 L1+（[h-doctor-001](../../docs/plan/tasks/h-doctor-001.md) 已 ready）。见 **[docs/gaps/03-safety.md](../../docs/gaps/03-safety.md)**；OS sandbox 属 C7。不要把 file jail 称为 OS sandbox。

---

## 9. 下一步

- **主线：** [Chapter H — Production Floor](../H-harden/README.md)
- 规格：[phases/H-harden.md](../../docs/phases/H-harden.md)
- 真沙箱属 Capability [C7](../../docs/phases/C7-sandbox.md)，不在 Teaching 3

**Tag：** `ch3-boundary` / tutorial-complete
