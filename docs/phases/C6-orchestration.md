# C6 — Interactive Control / Optional Orchestration

| 项 | 内容 |
|----|------|
| 前置 | Phase H lifecycle/session + SDK/headless event contracts ✅；executable agents 另依赖 process supervisor |
| 近期路线位置 | M1 `harness-events-001` ✅ at `aecf402` → `harness-steering-001` planned |
| 失败模式 | 运行中的 Agent 无法接收纠偏；结束时无法排入 follow-up；复杂编排反客为主 |
| 模块 | [loop-turn](../modules/loop-turn.md)、[subagents-oracle](../modules/subagents-oracle.md)（deferred） |

## 目标

先实现 Pi Harness 的最小 interactive-control 语义：有界 steering 与 follow-up。Oracle、subagents、Graph 不是当前产品承诺。

## 近期范围

1. message/Tool/run 生命周期事件与 ordering 已由 `harness-events-001` 闭合；
2. bounded steering queue：在明确的 turn/Tool boundary 注入纠偏；
3. bounded follow-up queue：Agent 将结束时追加工作；
4. queue ownership、cancel、session/trace projection 和 overflow behavior 显式；
5. 单 Agent Loop 仍是默认和完整路径。

## Deferred

- read-only Oracle；
- executable explore/plan/general subagents；
- typed schema handoff；
- plan-mode product UX；
- Graph/DAG/handoff/join；
- mid-flight Tool/shell preemption。

任何 deferred 项重启前都需要 [roadmap re-entry trigger](../roadmap.md#re-entry-triggers-for-deferred-work) 和独立 task。

## Invariants

- steering/follow-up 不绕过 permission、workspace、context validation；
- queue 有明确容量和 deterministic overflow result；
- message ownership 跨 run/arena 边界安全；
- cancel 后不执行未接受的 queued work；
- transcript/session/trace 对实际注入内容一致；
- UI/headless 只消费事件，不实现 queue business logic。

## 验收

- [ ] deterministic fixture pin 住每个 insertion point；
- [ ] full/all 与 one-at-a-time（若都提供）顺序明确；
- [ ] queue overflow/cancel/OOM 不丢失终态；
- [ ] plain/headless/SDK 观察到一致语义。

## 对标

Current Pi + historical `pi-mono-zig` 的 steering/follow-up 行为。重新实现到 Zag Loop/ownership model，不搬 god-object Agent。
