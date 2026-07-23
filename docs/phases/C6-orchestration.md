# C6 — Orchestration / Oracle

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成** |
| 失败模式 | 弱模型硬撑；子代理散文不可用；大任务无计划 |
| 模块 | [subagents-oracle](../modules/subagents-oracle.md) |
| 对标设计 | Hyper `design-oracle.md`（对话点名；不做 `/oracle`） |

## 目标

主会话可用便宜/日常模型干活；卡住时请到**更强只读 Oracle**；计划与子代理有界。

## 范围

1. Subagent runtime：explore / plan / general；独立 transcript；预算  
2. Typed / `output_schema` 回传  
3. **Oracle：** 只读；`[subagents.models] oracle = …` pin；未 pin 或同模型 → warn  
4. 触发：连续失败 / 架构抉择 / **用户对话点名 oracle**（强制服从 spawn）  
5. Plan mode 产品化（接 H3 语义）：里程碑 + 验收清单字段  
6. Turn：cancel 已有则补 steer（中途纠偏）

## 非目标

- Amp 四档 Modes  
- 默认每步 Advisor（可后置，默认关）  
- `/oracle` slash  

## 验收

- [ ] fixture：两轮红测 → 应 spawn oracle（评测可 mock）  
- [ ] 用户说「用 oracle …」→ 必须 spawn，不得硬撑  
- [ ] Oracle 与父模型相同时非致命 warn  
- [ ] plan 文件含可勾选验收项  

## 对标

Amp Oracle；Hyper design-oracle；omp typed subagents  
