# Chapter 3 — 生产向：边界、策略、可观测

> 对应 [Phase 3](../../docs/roadmap.md#phase-3--生产向可能上生产)。  
> **代码与本章同步。**

**一句话：** 别人敢在受控环境用——**默认拒绝危险操作**，并能**复盘**一次 run。

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
| 1 | `src/agent/workspace.zig` | 路径 jail 规则 |
| 2 | `src/agent/shell_policy.zig` | 命令 denylist |
| 3 | `src/agent/trace.zig` | 结构化事件 |
| 4 | `src/agent/loop.zig` | 三道门顺序 |
| 5 | `SECURITY.md` | 产品安全说明 |

---

## 3. 默认拒绝什么？

### 路径 jail

- 绝对路径：`/etc/passwd`、`C:\…`  
- 逃出工作区：`../secret`、`a/../../b`  
- 空路径、内嵌 NUL  

允许：`src/main.zig`、`./foo`、`a/b/../c`（仍在树内）。

### Shell policy（protect）

- `rm -rf /`、磁盘擦除、fork bomb  
- `curl|bash` / `wget|sh` 一类管道进 shell  
- 粗暴破坏性关键字（见源码列表）  

**不是**完整沙箱：恶意构造仍可能绕过——单用户本机最小条。

---

## 4. Trace 字段

每行 JSON：

```json
{"seq":0,"kind":"run_start","version":"0.3.0","permission":"yolo","shell_policy":"protect"}
{"seq":1,"kind":"turn","turn":1}
{"seq":2,"kind":"tool_call","id":"…","name":"list_dir","arguments":"…"}
{"seq":3,"kind":"jail_deny","name":"read_file","path":"/etc/passwd"}
{"seq":4,"kind":"run_end","turns":1,"ok":true}
```

`kind` 全集：`run_start` · `turn` · `assistant` · `tool_call` · `permission` · `jail_deny` · `shell_deny` · `tool_result` · `run_end`。

---

## 5. 读完应能回答

- 默认拒绝什么？如何审计一次危险操作？  
- jail / policy / ask 三层各解决什么？  
- 为什么 soft fail 而不是进程 exit？  
- Phase 3 **还没**做到哪些工业能力？

---

## 6. 练习

1. 加一条 shell denylist + 单元测试。  
2. 用 mock loop 断言 `../x` 产生 `workspace jail` tool 结果（仓库已有绝对路径测试）。  
3. 读一份 `--trace` 文件，手绘 tool 时序。

---

## 7. 下一步（本阶段之后）

- 真沙箱 / 容器  
- 配置文件（非仅 env）  
- MCP 或 hooks 深挖一条  
- Golden transcript 回归集  

**Tag：** `ch3-prod` / `v0.3.0`
