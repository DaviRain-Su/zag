# C9 — Product Shell

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成**；建议 C4–C6 至少部分可用 |
| 失败模式 | 只能玩具 CLI；无法进 CI；无法嵌编辑器 |
| 对标 | Hyper pager/headless/ACP/dashboard |

## 目标

日用与自动化外壳：稳定 CLI、headless CI、可选 TUI、可选 ACP、轻量透视。

## 范围

1. Headless：`-p`/非交互、JSON 或流式、稳定 exit code  
2. Config：schema、semver、迁移（与 session schema 纪律一致）  
3. 可选 TUI：流式、tool 卡片、diff pane（不做皮肤竞赛）  
4. 可选 ACP：嵌 IDE  
5. 轻量 dashboard：会话费用、tool 时序（可读本地 HTML/TUI 其一）  

## 非目标

- 10 语言 i18n 首发（可后置）  
- 云协作 thread  

## 验收

- [ ] CI job 用 headless 改 fixture 仓并跑测试  
- [ ] flag/config 文档与 `--help` 一致  
- [ ] （若做 TUI）核心任务不比纯 CLI 丢功能  

## 对标

Hyper pager-bin、user-guide headless/ACP/dashboard  
