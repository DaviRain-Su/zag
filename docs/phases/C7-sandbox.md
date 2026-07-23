# C7 — Sandbox Plus

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成**（尤其 H5） |
| 失败模式 | denylist/jail 可绕过；yolo 仍危险 |
| 模块 | [workspace-sandbox](../modules/workspace-sandbox.md) L3 |

## 目标

在 jail + policy + redact 之上提供 **OS 级**执行边界，使「别人敢开较高自治」成为可能。

## 范围

1. macOS seatbelt 与/或 Linux bubblewrap（按平台）  
2. 网络默认拒绝 + 可配允许域  
3. 可选 git worktree 隔离危险任务  
4. Secrets：环境注入策略与 redact 加强  
5. Doctor 扩展：报告 sandbox 是否可用  

## 非目标

- 多租户云隔离  
- 完美对抗内核逃逸  

## 验收

- [ ] sandbox 开启时，构造性逃逸用例失败  
- [ ] 文档清晰：无 sandbox 平台上的降级行为  
- [ ] security eval 覆盖 sandbox on/off  

## 对标

Hyper sandbox；Codex sandbox；Pi「文档建议容器」  
