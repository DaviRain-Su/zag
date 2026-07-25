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
| H1 Loop | [loop-turn](../../docs/modules/loop-turn.md) | L2：soft errors/serial/goldens + facade terminal；provider active control；accepted multi-Tool between-call Agent composition 已通过独立/main Gate；mid-flight Tool preemption post-H |
| H2 Edit/Shell | [tools-edit](../../docs/modules/tools-edit.md) · [tools-shell](../../docs/modules/tools-shell.md) | shell L2 + single-file write/edit L2 已独立/main 验收；read/search bounds 仍 ready/blocking |
| H3 Tool/Permissions | [tool-runtime](../../docs/modules/tool-runtime.md) · [permissions](../../docs/modules/permissions.md) | D-007 L2 landed（descriptor fail-closed） |
| H4 Context/Session | [context](../../docs/modules/context-compaction.md) · [session](../../docs/modules/session-store.md) | session D-006 L2；context final-view accounting h-context-001 L2 |
| H5 Safety | [workspace-sandbox](../../docs/modules/workspace-sandbox.md) | L2 trusted-host boundary：file containment + redaction + doctor + Agent policy/containment composition 已通过；shell/OS sandbox 是单独边界 |
| H6 Provider | [zag-ai-provider](../../docs/modules/zag-ai-provider.md) | L2：final audit confirmed dual-wire/retry/usage/strict completion + curl enforce/std fail-closed capability truth + scrubbed diagnostics |
| H7 Trace/Quality | [trace](../../docs/modules/trace-observability.md) · [evals](../../docs/quality/evals.md) | h-trace-001 lifecycle + h-redact-001 redaction before serialize；dashboard still open |

Schema presence or existing happy-path tests do not mark H3/H4 closed.

## 3. Current task order

```text
P0: h-session-001 · h-tool-runtime-001 · h-workspace-001 · h-trace-001
  ↓
P1 modules: h-context-001 · h-provider-001 · h-redact-001 ✅
  ↓
h-doctor-001（provider/API-key-independent readiness report）✅
  ↓
h-integration original Agent chains（independent + main Gate）✅ evidence

Tool runtime + trace
  ↓
h-shell-001（re-review + Oracle + main std/curl）✅
  ↓
final audit FAIL（existing suites green）
  ├─ h-edit-integrity-001 ✅ reviews/Oracle/main Gate
  └─ h-read-search-bounds-001 ready
  ↓
h-integration-001 blocked → read/search done 后 fresh sentence audit
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

All [maturity Phase H conditions](../../docs/maturity.md#phase-h-production-floor-exit) must pass. The first final audit failed exits 8/10/11 on two file-surface contracts; edit integrity is now closed, while h-integration-001 remains blocked until read/search bounds passes and then must repeat the independent sentence audit. H completion would not claim mid-flight Tool/shell preemption, descendants/process-tree cleanup, detached jobs, PTY, power-loss edit durability, or OS sandbox, and would not automatically imply SDK-ready or headless-ready.
