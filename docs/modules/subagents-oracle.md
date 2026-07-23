# Module: subagents-oracle（Capability stub）

| 项 | 内容 |
|----|------|
| 状态 | **stub** — 前置 [Phase H](../phases/H-harden.md) |
| 阶段 | [C6](../phases/C6-orchestration.md) |
| 对标 | Amp Oracle；Hyper design-oracle；omp Advisor（可选后置） |

## 不变式（目标）

1. Oracle = **更强模型** × **被真正调用**；同模型继承则模式失效。  
2. Oracle **只读**；纠偏由主 agent 执行。  
3. 用户强制入口 = **对话点名**（「用 oracle…」）；**不做** `/oracle` slash。  
4. 子代理有预算（rounds/time/tools）与可选 `output_schema`。

## L2

不适用（H 不做）。C6 完成前保持 L0。

## L3 方向

- explore / plan / general / oracle  
- model pin 配置  
- 失败循环 harness 提醒（可选 auto-spawn flag，默认关）  

## 非目标

- Amp 四档 Modes  
- 每步 Advisor（默认可关的贵路径）  

## 详设

见 [C6-orchestration.md](../phases/C6-orchestration.md)。  
