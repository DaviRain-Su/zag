# Quality: Evals

> 从 **Phase H** 起强制。改 harness 必须能回答：有没有变笨？安全默认有没有破？

## 三类

| 类型 | 目的 | 何时 |
|------|------|------|
| **Golden transcript** | 固定 fixture 下 tool 序列/关键结果稳定 | H1 起；每阶段至少 +1 |
| **Security eval** | jail/policy/redact/permission 不可回归 | H5 起 |
| **Edit eval** | 锚点/替换成功率 | H2 起；C4 加强 |

## Golden 约定

- 夹具仓库：小、确定性（建议 `testdata/golden/<name>/`）  
- 输入：用户提示固定；provider：**mock** 优先（录制回放次选）  
- 断言：关键 `tool_call.name` 序列、最终文件内容、或 deny code  
- CI：`zig build test` 包含之  

### H 最低集

1. `readonly-list-build` — ✅ `packages/zag-coding-agent/src/golden_tests.zig`  
2. `deny-write` — ✅ 同上（`permission_denied` + 文件不存在）  
3. `cancel-resume` — ✅ cancel 后 session JSONL 可 load  

CI：`zig build test` 包含之。

1. 绝对路径 read → `jail_deny`  
2. `../` 逃逸 → deny  
3. denylist 命令 → `shell_deny`  
4. 假 API key 字符串不出现在 trace 样例（redact）  

## Edit eval（H2/C4）

1. 唯一锚点替换成功  
2. 模糊锚点 → `ambiguous_anchor`，文件未改  
3. stale 锚点 → 可恢复路径（重读后成功）  

## 维护

- 故意改行为时更新 golden，并在 PR 说明  
- 禁止「修 flaky」时削弱断言到无意义  

## 相关

- [contracts.md](./contracts.md)  
- [maturity.md](../maturity.md) Quality 行  
