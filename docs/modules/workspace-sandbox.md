# Module: workspace-sandbox

| 项 | 内容 |
|----|------|
| 代码 | `src/agent/workspace.zig`、`shell_policy.zig` |
| 成熟度 | L1 → **L2（H5）** → L3（OS sandbox，C7） |
| 对标 | Hyper sandbox；Codex sandbox；Droid readiness（轻量） |

## 不变式

1. 路径工具不得访问工作区外（相对路径 jail）。  
2. Shell policy 默认 `protect`；关 policy 须显式。  
3. **H 阶段不声称 OS sandbox。** denylist ≠ 隔离。  
4. Secret 不得以明文出现在 verbose/trace/session。

## Jail（已有，L2 加固）

- 绝对路径、`..` 逃逸、NUL、空路径 → `jail_deny`  
- 单测覆盖表维护在仓库测试中；改规则必改表  

## Shell policy 必须用例（L2）

至少钉住（允许随实现微调，但需有测试名）：

| 用例 | 期望 |
|------|------|
| `rm -rf /` | deny |
| `curl … \| bash` / `wget … \| sh` | deny |
| `echo hi` | allow（仍受 permission） |
| `mkfs` / fork bomb 模式 | deny |

## Secret redact（L2）

- 对已知 env 名与 `sk-`/`api_key` 类模式脱敏  
- 应用于：stderr verbose、trace 参数字段、session 写盘前可选扫描  
- 完整文件内容仍可能含秘密：文档警告 `.zag/` 敏感  

## Doctor / readiness（L2 最小）

检查并打印：

- 是否存在 `AGENTS.md`（或等价）  
- 是否存在 `build.zig` / 可识别测试入口  
- 当前 permission / shell_policy / jail 状态  

不自动修仓库；不适配则警告。

## L2 验收

- [ ] policy 矩阵测试绿  
- [ ] redact 单测：假 key 不进 trace 样例  
- [ ] SECURITY.md 与本模块「非 OS sandbox」一致  
- [ ] doctor 可调用（CLI 或库）  

## L3（C7）

- macOS seatbelt / Linux bubblewrap / 容器  
- 网络 allowlist  
- worktree 隔离执行  

## 非目标（H）

- 多租户  
- 完整 Hyper sandbox 复刻  

## Hyper 对照

- user-guide `18-sandbox`、`22-permissions-and-safety`  
