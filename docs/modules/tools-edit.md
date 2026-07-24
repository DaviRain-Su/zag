# Module: tools-edit

| 项 | 内容 |
|----|------|
| 代码 | `packages/zag-coding-agent/src/runtime/{edit_tools,fs_tools}.zig`、`toolset.zig` |
| 成熟度 | write/edit/search = **L1+（H2 大半）** → L2 收口 golden；L3（C4） |
| 对标 | Hyper hashline；omp；Codex apply_patch |

## 不变式

1. 所有路径工具受 workspace jail。  
2. **生产默认编辑路径**不是「唯一整文件 overwrite」。  
3. 锚点失败必须 soft-fail 并可恢复（提示重读文件）。  
4. 结果有统一 byte budget。

## H2 钉死的工具面

| Tool | 角色 |
|------|------|
| `search_replace` | **默认编辑**：旧内容锚点 → 替换；可带简易 hash/唯一性检查 |
| `write_file` | 新建或明确需要整文件时 |
| `read_file` / `list_dir` | 已有 |
| `grep` | 内容搜索（jail 内） |
| `glob` | 路径匹配（jail 内） |

锚点策略（简化 hashline）：匹配前要求 `old_string` 在文件中 **唯一**；不唯一则返回错误码 `ambiguous_anchor` 并建议扩大上下文。

## 写后 diff（L2）

- 可选：编辑成功后附短 `git diff`（若在 git 仓）；失败则省略，不硬失败。  

## 失败模式

| 场景 | code |
|------|------|
| 锚点 0 次匹配 | `anchor_not_found` |
| 锚点多次匹配 | `ambiguous_anchor` |
| 超大写 | `too_large` |
| jail | `jail_deny` |

## L2 验收

- [x] 默认 tool 描述引导模型优先 `search_replace`  
- [x] stale 锚点 soft-fail（`anchor_not_found` / `ambiguous_anchor`）+ 单测；golden 仍可选  
- [x] grep/glob 受 jail；绝对路径失败  
- [x] overwrite 不再是文档中的「唯一」编辑方式  

## L3（C4）

- 完整 hashline / apply_patch  
- hunk accept/reject UX  
- 编辑后自动跑项目测试的工作流  

## 非目标（H）

- AST 结构编辑（先 skill）  
- IDE diff UI  

## Hyper 对照

- `grok_build_hashline` / tools implementations 编辑路径  
