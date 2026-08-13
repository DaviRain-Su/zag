# C6 — Interactive Control / Optional Orchestration

| 项 | 内容 |
|----|------|
| 前置 | Phase H lifecycle/session + SDK/headless event contracts ✅；executable agents 另依赖 process supervisor |
| 近期路线位置 | M1 `harness-events-001` ✅ at `aecf402` → `harness-steering-001` ✅ at `a5ff2b7`; `session-fork-001` ✅ at `0a3087f` |
| 状态边界 | bounded steering/follow-up 已闭合；in-process `task` subagent 已落地 @ `1dabd25`；Oracle / Graph / process-backed 仍不得当作已实现 |
| 模块 | [harness-steering](../modules/harness-steering.md)、[loop-turn](../modules/loop-turn.md)、[subagents-oracle](../modules/subagents-oracle.md) |

## 目标

Pi Harness 的最小 interactive-control 语义——有界 steering 与 follow-up——已由 `harness-steering-001`
在 `a5ff2b7` 闭合。进程内 `task`/`scout`/`reviewer` 已在 `1dabd25` 落地，**不**升 Subagents/Oracle 行。
Oracle、Graph、进程隔离子代理仍不是当前产品承诺。

## 近期范围

1. message/Tool/run 生命周期事件与 ordering 已由 `harness-events-001` 闭合；
2. bounded steering queue：Session 每类 4×4096-byte 预分配槽，在明确的 turn/Tool boundary 注入纠偏；
3. bounded follow-up queue：would-complete 时 one-at-a-time 追加工作，仍在同一 run/terminal；
4. Core 只持显式 `ControlInput.peek(boundary)/commit`；would-complete 原子选择、mid-batch 预留、queue ownership、retention、cancel、session/trace projection 和 overflow behavior 由 [binding contract](../modules/harness-steering.md) 钉死；
5. 单 Agent Loop 仍是默认和完整路径。

## Deferred

- read-only Oracle；
- process-backed / worktree-isolated subagents（in-process slice already landed）；
- typed schema handoff；
- plan-mode product UX；
- Graph/DAG/handoff/join；
- mid-flight Tool/shell preemption。

任何 deferred 项重启前都需要 [roadmap re-entry trigger](../roadmap.md#re-entry-triggers-for-deferred-work) 和独立 task。

## Invariants

- steering/follow-up 不绕过 permission、workspace、context validation；
- queue 归 Session，容量固定且 overflow 不覆盖/丢弃；Agent 不缓存跨 Session control；
- message ownership 跨线程/run/arena 边界安全；enqueue 路径不与 reply 共享 allocator；
- cancel/error/max-turn 后不执行也不自动清空未接受 work；仅 apply、显式 clear、deinit 移除；
- transcript/session/Trace/lifecycle 对实际注入结果一致，Trace/headless v1 不加 control kind；
- UI/headless 只消费事件，不实现 queue business logic。

## 验收

- [x] deterministic fixture pin 住 pre-turn、between-Tool、would-complete insertion points；
- [x] v1 one-at-a-time FIFO、steering-before-follow-up、`code=steered` 与 max-turn retention 顺序明确；
- [x] queue overflow/cancel/OOM/sink failure 不静默丢消息或终态；
- [x] Session A/B 隔离与跨线程 enqueue 通过真实 barrier fixture；
- [x] plain/headless/SDK 观察到兼容语义，且每个 started run 仍恰有一个 terminal。

Merged-main Gate at `a5ff2b7`: std **567/567**, curl **566/566**, Core **89/89**, Coding **298/298**, SDK
**20/20**. This closes only the bounded-control slice; C6 Graph/subagents remain deferred, and all existing L2 rows
remain unchanged.

## 对标

Current Pi + historical `pi-mono-zig` 的 steering/follow-up 行为。重新实现到 Zag Loop/ownership model，不搬 god-object Agent。
