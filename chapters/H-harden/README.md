# Chapter H — Production Floor（硬化）

> 对应 [Phase H](../../docs/phases/H-harden.md)。  
> **状态：in progress，未达 L2。** Teaching 0–3 tutorial-complete；当前 P0/P1 基线见 [assessment](../../docs/plan/analysis/2026-07-24-production-floor-assessment.md)。

**一句话：** 不堆新功能表面；先让已有 loop、Tool、edit、session、workspace、provider、trace 在失败路径上不丢数据、不 fail-open、不说假成功。

## 0. 读之前

1. [maturity](../../docs/maturity.md) — 当前 L1/L1+ 与 L2 exit；
2. [assessment](../../docs/plan/analysis/2026-07-24-production-floor-assessment.md) — P0/P1/P2 与证据；
3. [Phase H](../../docs/phases/H-harden.md) — slice 状态；
4. [plan](../../docs/plan/README.md) — 实施 task DAG。

## 1. 业务心智

```text
Teaching: normal path 可演示
    ↓
H P0: preserve state · fail closed · real containment · truthful terminal
    ↓
H P1: exact context · redact · deadline/cancel · failure regression
    ↓
才允许：「single-user trusted-host production floor」
```

Tool 执行目标边界：

```text
validated ToolDescriptor
  → permission
  → filesystem containment（file Tool）
  → shell/process policy（execute Tool）
  → execute
```

Deny/expected Tool failure soft-fail；host registration、session、trace 等基础设施错误必须返回给 host，不能伪装成 Tool success。

## 2. Slice 与当前状态

| Slice | Spec | Current truth |
|-------|------|---------------|
| H1 Loop | [loop-turn](../../docs/modules/loop-turn.md) | soft errors/serial/goldens + facade terminal；provider in-flight cancel/deadline（h-provider-001）；accepted multi-Tool between-call composition pending；mid-flight Tool preemption post-H |
| H2 Edit | [tools-edit](../../docs/modules/tools-edit.md) | search_replace/write under file+dir containment (h-workspace-001); Plan UX still open |
| H3 Tool/Permissions | [tool-runtime](../../docs/modules/tool-runtime.md) · [permissions](../../docs/modules/permissions.md) | D-007 L2 landed（descriptor fail-closed） |
| H4 Context/Session | [context](../../docs/modules/context-compaction.md) · [session](../../docs/modules/session-store.md) | session D-006 L2；context final-view accounting h-context-001 L2 |
| H5 Safety | [workspace-sandbox](../../docs/modules/workspace-sandbox.md) | file symlink containment (h-workspace-001) + secret redaction (h-redact-001); h-doctor-001 ready → Safety remains L1+ |
| H6 Provider | [zag-ai-provider](../../docs/modules/zag-ai-provider.md) | two wire styles/retry/usage；deadline/cancel/partial Tool safety（h-provider-001）；log scrub helpers（h-redact-001） |
| H7 Trace/Quality | [trace](../../docs/modules/trace-observability.md) · [evals](../../docs/quality/evals.md) | h-trace-001 lifecycle + h-redact-001 redaction before serialize；dashboard still open |

Schema presence or existing happy-path tests do not mark H3/H4 closed.

## 3. Current task order

```text
P0: h-session-001 · h-tool-runtime-001 · h-workspace-001 · h-trace-001
  ↓
P1 modules: h-context-001 · h-provider-001 · h-redact-001 ✅
  ↓
h-doctor-001（provider/API-key-independent readiness report）
  ↓
h-integration-001（two missing Agent composition chains + matrix audit）
  ↓
Phase H exit decision
  ↓
SDK-ready gate · headless gate · C4/C5.1/C7 by dependency
```

Run the deterministic suite after each behavior change:

```bash
zig build test --summary all
zig build test -Dhttp_backend=curl --summary all
```

Each task adds its named failure fixture before claiming closeout. Live provider success is supplemental only.

## 4. Explicit non-goals

- Memory Repo / early Memory hook
- Graph/DAG runtime
- full subagents/Oracle
- MCP/executable extensions
- background jobs
- TUI
- OS sandbox implementation inside H
- C ABI or Zig dynamic plugin ABI

## 5. Exit

All [maturity Phase H conditions](../../docs/maturity.md#phase-h-production-floor-exit), h-doctor-001, and h-integration-001 verifications must pass independently and on main. H completion does not claim mid-flight Tool/shell preemption and does not automatically imply SDK-ready or headless-ready; those are separate gates.
