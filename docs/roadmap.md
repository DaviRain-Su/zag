# Zag 路线图

> Zig 是载体；harness 是主角。成熟度真理源：[maturity](./maturity.md)。当前实施基线：[production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)。

## 诚实状态

| Track | Status | Meaning |
|-------|--------|---------|
| Teaching Phase 0–3 | ✅ tutorial-complete | 可学习、可演示；不是 production-ready |
| Production Floor Phase H | ❌ **P0/P1 in progress** | 单用户 trusted-host L2；当前唯一主线 |
| Zig SDK-ready gate | ❌ 未达 | low-level composition 已证明；支持契约未闭合 |
| Headless/process gate | ❌ 未达 | one-shot 存在；结构化协议/exit matrix 未闭合 |
| Capability C4–C9 | 未开始 | 按依赖解锁，不再视为严格线性链 |

禁止在 Phase H exit 前声称 production-ready、SDK-ready 或 OS sandbox 已具备。

## 总 DAG

```text
Teaching 0 → 1 → 2 → 3  ✅
                │
                ▼
Phase H correctness
  P0: session · Tool policy · containment · truthful trace
  P1: context · redact · provider deadline/cancel · doctor · real composition
                │
                ├────► Zig SDK-ready gate ───► package publication decision
                ├────► headless/process gate ─► ACP/editor integration later
                ├────► C4 edit sharpness
                ├────► C5.1 repo map/fork (after session/context)
                └────► C7 sandbox + process supervisor
                                      ├────► background jobs
                                      ├────► executable hooks/MCP
                                      └────► full executable subagents

Later/default-off: Memory Repo · Graph · TUI/dashboard · full LSP/AST
```

The arrows are hard dependencies. Work without an arrow may overlap once its own module contracts are stable.

## Teaching track (retained)

| Phase | Demonstration | Production debt |
|-------|---------------|-----------------|
| 0 — Loop | prompt → provider → Tool → result | lifecycle/error/cancel contract |
| 1 — Edit/permission | write/shell + ask/yolo | extensible Tool descriptor and fail-closed policy |
| 2 — Session/context | JSONL resume + project instructions + view | safe open/save/concurrency and exact compaction accounting |
| 3 — Safety/trace | lexical jail + shell policy + JSONL trace | real containment, redaction, truthful/versioned trace |

Teaching chapters remain useful tutorials. Their completion does not imply the corresponding L2 row.

## Phase H — current queue

Detailed spec: [H-harden](./phases/H-harden.md). Task index: [plan](./plan/README.md).

### P0

| Task | Exit |
|------|------|
| [h-session-001](./plan/tasks/h-session-001.md) | explicit create/resume, atomic preservation, visible save error, writer conflict |
| [h-tool-runtime-001](./plan/tasks/h-tool-runtime-001.md) | stateful Tool, mandatory descriptor, fail-closed custom policy |
| [h-workspace-001](./plan/tasks/h-workspace-001.md) | symlink-aware containment for all file Tools |
| [h-trace-001](./plan/tasks/h-trace-001.md) | one truthful terminal state and visible trace I/O failure |

### P1

| Task | Depends on | Exit |
|------|------------|------|
| [h-context-001](./plan/tasks/h-context-001.md) | session + trace | final-view compaction accounting |
| [h-provider-001](./plan/tasks/h-provider-001.md) | trace | enforced deadline/in-flight cancel/partial Tool safety |
| [h-redact-001](./plan/tasks/h-redact-001.md) | session + trace | shared pre-persistence redaction |
| [h-doctor-001](./plan/tasks/h-doctor-001.md) | Tool/workspace/redaction | **done:** no-key readiness/control truth; no policy mutation or OS-sandbox claim |
| [h-integration-001](./plan/tasks/h-integration-001.md) | all module P0/P1 + doctor | two missing Agent composition chains + matrix audit + truth update |

Phase H exits only after doctor and integration pass their independent worktree Gates, both backends pass again on main, and [maturity § production-floor exit](./maturity.md#phase-h-production-floor-exit) remains true.

## Post-H gates

### Zig SDK-ready

Decision: [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md). Task: [sdk-contract-001](./plan/tasks/sdk-contract-001.md).

Required before a public compatibility claim:

- high-level custom Toolset/Observer/policy injection;
- stateful Tool and documented lifetimes;
- stable errors/events/cancel/session contract;
- repository-owned external consumer CI;
- package self-contained tests.

A second consumer and release channel are still required before repo mirror/semver publication.

### Headless/process interface

Task: [headless-001](./plan/tasks/headless-001.md).

Headless is split from late TUI work:

- machine-clean JSON/streaming JSON;
- stable structured errors and exit codes;
- auth/session/save/cancel/timeout/sandbox-unavailable matrix;
- CI end-to-end fixture.

ACP/editor integration follows a versioned process contract; it does not require a stable Zig dynamic ABI.

## Capability track — dependency rules

### C4 — Edit sharpness

Spec: [C4-edit-sharpness](./phases/C4-edit-sharpness.md).

May start after H edit/containment correctness. It does not depend on Memory or Graph.

- hashline/apply_patch-grade path;
- hunk review;
- post-edit verification;
- multi-file partial-failure policy.

### C5 — Context engineering

Spec: [C5-context](./phases/C5-context.md).

- **C5.1 repo map** and **C5.2 fork** follow safe session/context contracts and may overlap C4.
- C5.3 LLM summary remains optional.
- C5.4 Memory Repo remains default-off and later; it is not a Phase H or SDK prerequisite.

### C6 — Oracle/subagents/Graph

Spec: [C6-orchestration](./phases/C6-orchestration.md).

- Read-only Oracle may follow stable event/cancel/session/headless contracts.
- Full executable subagents require process ownership, budgets, cancellation, and an explicit safety policy.
- Graph is optional orchestration around Loop; it never replaces the default coding Loop.

### C7 — Sandbox/process supervisor

Spec: [C7-sandbox](./phases/C7-sandbox.md).

May develop in parallel after H safety semantics stabilize. It is not required for narrowly scoped trusted-host L2, but it blocks:

- higher-autonomy/yolo production claims;
- autonomous background processes;
- untrusted executable hooks/MCP;
- executable multi-agent fan-out.

A mode that requires enforcement fails closed if the platform/profile cannot enforce it.

### C8 — Extensions

Spec: [C8-extensions](./phases/C8-extensions.md).

Split by risk:

- passive Skills/prompt packages can arrive after injection/budget contracts;
- hooks and MCP Tool registration require D-007 descriptors;
- executable servers require process-supervisor and permission/sandbox policy.

### C9 — Product shell

Spec: [C9-product-shell](./phases/C9-product-shell.md).

Headless moved to an earlier gate. C9 retains optional TUI, diff UX, dashboard, and polished ACP/editor integration. Product UI only assembles Kernel APIs.

## Quality (cross-cutting)

- [evals](./quality/evals.md): goldens, P0 fault/security fixtures, SDK/headless E2E.
- [provider contracts](./quality/contracts.md): wire/error/retry/deadline/cancel/partial Tool safety.
- Every fixed P0/P1 failure remains a permanent CI regression.

## Packaging

| Action | Timing |
|--------|--------|
| Keep current monorepo package boundaries | now |
| Add Tool runtime descriptor contract | Phase H P0 |
| External consumer fixture | SDK gate |
| Split `zag-tools`/`zag-workspace` | only after the relevant APIs stabilize and a real dependency reason exists |
| Repo mirror / semver publication | SDK gate + second consumer + release channel |
| C ABI / dynamic plugin ABI | no current commitment; prefer process protocol |

## Stop-doing until P0/P1 close

- provider/catalog breadth without a user requirement;
- Graph, Memory Repo, TUI, full LSP/AST, background jobs;
- mid-flight Tool/shell preemption disguised as provider work (it requires post-H process ownership/cleanup);
- package/repo splitting for appearance;
- unmeasured Zig performance/startup/cross-build claims;
- production/L2/SDK-ready language based only on green happy-path tests.
