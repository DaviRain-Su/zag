# Module: permissions

| 项 | 内容 |
|----|------|
| 代码 | `src/agent/permissions.zig` |
| 成熟度 | L1（ask/yolo）→ **L2（H3）** → L3（细粒度 + plan 产品化） |
| 对标 | Hyper permissions-and-safety；Claude Code 默认 UX |

## 不变式

1. 默认偏拒绝危险写/shell（产品默认 `ask`，非 yolo）。  
2. Deny 永远 soft-fail 回灌，不崩 loop。  
3. yolo **不**绕过 jail / shell_policy（除非用户显式关 policy）。

## L2：类别矩阵

| 类别 | 典型 tools | ask 默认 | yolo |
|------|------------|----------|------|
| read | list/read/grep/glob | allow | allow |
| write | search_replace/write_file | confirm | allow |
| shell | run_shell | confirm | allow |

### Remember（会话内）

- 用户批准 `write` 某 `path` 后，同 session 再次写同 path 可跳过确认。  
- 可配置关闭；trace 记录 `permission` 含 `remembered=true`。

## Plan 模式语义（H 占位，实现可部分延后）

**不变式：** plan 模式下禁止一般 write/shell；允许读 + 写约定 plan 文件（如 `plan.md` / `.zag/plan.md`）。  
完整 UX 与切换快捷键可在 C6 做完；H 须在文档与配置键名上预留，避免日后语义冲突。

## L2 验收

- [ ] 矩阵表与实现一致  
- [ ] remember 可测  
- [ ] plan 语义成文（代码可 stub）  

## L3

- path/command 级规则文件  
- 与 ACP session mode 对齐（若做 C9）  

## 非目标

- Amp 四档 effort Modes  

## Hyper 对照

- user-guide `22-permissions-and-safety`、`19-plan-mode`  
