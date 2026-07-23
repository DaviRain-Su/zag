# C4 — Edit Sharpness

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成**（尤其 H2） |
| 失败模式 | 编辑偏行；不敢 auto-apply；多文件改动不可审 |
| 模块 | [tools-edit](../modules/tools-edit.md) L3 |

## 目标

把 H2 的简化锚点升到日用「打得准」：更稳的编辑格式、写后验证、改动审阅。

## 范围

1. hashline 级或 `apply_patch` 工业路径（与 H2 search_replace 共存或迁移）  
2. Change review：hunk accept / reject / 部分接受（先 CLI）  
3. 编辑后验证工作流：约定跑 `zig build test`（或项目 script）；连续失败信号留给 C6  
4. 多文件编辑的原子性策略（失败回滚或明确部分成功）

## 非目标

- AST 编辑（先 skill）  
- 完整 IDE diff UI（C9）  

## 验收（可开 issue）

- [ ] 锚点 stale 恢复成功率有 edit eval（见 [evals](../quality/evals.md)）  
- [ ] 用户能拒绝单个 hunk 且磁盘一致  
- [ ] 默认 tool 描述不再引导「整文件覆写大文件」  

## 对标

Hyper hashline；omp；Amp Changes；Codex apply_patch  
