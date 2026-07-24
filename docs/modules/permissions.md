# Module: permissions

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-agent-core/src/permissions.zig` |
| 成熟度 | L1（ask/yolo）→ **L2（H3）** → L3（细粒度 + plan 产品化） |
| 对标 | Hyper permissions-and-safety；Claude Code 默认 UX |
| CLI | `--ask` / `--yolo` · `--plan` · `--no-remember` |

## 不变式

1. 默认偏拒绝危险写/shell（产品默认 `ask`，非 yolo）。  
2. Deny 永远 soft-fail 回灌，不崩 loop。  
3. yolo **不**绕过 jail / shell_policy（除非用户显式关 policy）。  
4. `SessionKind.plan` 是硬约束：即使 `--yolo` 也禁止一般 write / shell。

## L2：类别矩阵

| 类别 | 典型 tools | ask 默认 | yolo | plan |
|------|------------|----------|------|------|
| read | list/read/grep/glob | allow | allow | allow |
| write | search_replace/write_file | confirm | allow | **仅** `plan.md` / `.zag/plan.md` |
| shell | run_shell | confirm | allow | **deny** |

实现枚举：`Risk.read` / `.write` / `.execute`（`.label()` → `shell`）。

### Remember（会话内）

- 用户批准 `write` 某 `path` 后，同 Agent 生命周期内再次写同 path 可跳过确认。  
- 默认开；`--no-remember` / `Options.remember_writes=false` 关闭。  
- 上限 64 条 path（有界）。  
- Trace：`permission` 事件含 `remembered=true|false`。

## Plan 模式语义（H3 stub；完整 UX → C6）

**不变式：** plan 模式下禁止一般 write/shell；允许读 + 写约定 plan 文件（`plan.md` / `.zag/plan.md`，含 `./` 前缀）。  
配置键：`SessionKind` = `agent` | `plan`（CLI `--plan`）。  
完整切换快捷键 / 产品壳可在 C6 做完；此处语义与键名已固定，避免日后冲突。

## L2 验收

- [x] 矩阵表与实现一致（`riskOf` + 单测）  
- [x] remember 可测（`remember skips second ask for same path`）  
- [x] plan 语义成文 + stub（`plan mode blocks shell and non-plan writes`；CLI `--plan`）  

## L3

- path/command 级规则文件  
- 与 ACP session mode 对齐（若做 C9）  
- plan 模式完整 UX（快捷键、专用 plan 文件编辑流）  

## 非目标

- Amp 四档 effort Modes  

## Hyper 对照

- user-guide `22-permissions-and-safety`、`19-plan-mode`  
