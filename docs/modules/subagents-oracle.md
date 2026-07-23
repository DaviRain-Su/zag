# Module: subagents-oracle · Graph 编排（Capability stub）

| 项 | 内容 |
|----|------|
| 状态 | **stub** — 前置 [Phase H](../phases/H-harden.md)（单 Loop 须先 L2） |
| 阶段 | [C6](../phases/C6-orchestration.md) |
| 对标 | Amp Oracle；Hyper design-oracle；omp Advisor；编排层可对标 LangGraph **仅作拓扑**，不替换 coding loop |
| 分层 | [architecture — Loop ⊂ Graph](../architecture.md#loop--graph多角色编排) |

## Graph 与 Loop（钉死）

```text
Graph / DAG（本模块 · 编排）
  node = sub-agent | oracle | deterministic gate
  每个 agentic 节点内部 = Agent Core Loop（同一套 Provider / tools 政策可收窄）
```

1. Graph **不**替代 [loop-turn](./loop-turn.md)；Loop 是节点执行引擎。  
2. 单 coding 任务默认 **只跑 Loop**，不强制建图。  
3. 确定性节点（测试、权限、worktree）可与 LLM 节点混排。

## 不变式（目标）

1. Oracle = **更强模型** × **被真正调用**；同模型继承则模式失效。  
2. Oracle **只读**；纠偏由主 agent 执行。  
3. 用户强制入口 = **对话点名**（「用 oracle…」）；**不做** `/oracle` slash。  
4. 子代理有预算（rounds/time/tools）与可选 `output_schema`。  
5. 子代理仍走 canonical Provider 端口，不直连线协议。

## L2

不适用（H 不做）。C6 完成前保持 L0。

## L3 方向

- explore / plan / general / oracle  
- model pin 配置  
- 显式 DAG：handoff、join、失败回边  
- 失败循环 harness 提醒（可选 auto-spawn flag，默认关）  

## 非目标

- Amp 四档 Modes  
- 每步 Advisor（默认可关的贵路径）  
- Phase H 内实现 Graph 运行时  
- 用 workflow 引擎重写单 agent coding loop  

## 详设

见 [C6-orchestration.md](../phases/C6-orchestration.md)。  

