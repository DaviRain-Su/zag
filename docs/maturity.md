# Zag 生产成熟度矩阵

> **状态真理源。** 其他文档对“当前做到哪了”有争议时，以本文件为准。合同细节以对应 `docs/modules/` 和 active decisions 为准。

| Level | Meaning |
|-------|---------|
| **L0** | 无 / 玩具 |
| **L1** | 教程可演示；正常路径可用 |
| **L2** | **生产底线**：单用户、受控本机、失败可见、状态可恢复、行为可审计 |
| **L3** | 工业锐度与更高自治 |

`L1+` 只是规划中的中间标记，表示功能明显超过教程但仍被一个或多个 L2 合同反例阻断；它不是可对外宣传的等级。

**总状态（2026-07-25 exit audit）：** Teaching Phase 0–3 = L1 完成；Production Floor Phase H = **未达 L2**；
Capability = 未开始。原 h-integration Agent 组合证据已经独立验收并在 main 的 std/curl Gate 通过；
`h-shell-001` review-fix package 矩阵已落地，但独立 re-review/main Gate 与最终 audit 仍阻塞 Phase H。

> 绿测、schema 字段或包拆分本身不能升格。任何可导致静默数据丢失、权限 fail-open、越界访问或虚假审计终态的反例都会阻止相关子系统升到 L2。

评估与优先级：[production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)。

## 当前矩阵

| Subsystem | Current | Evidence and blocker | L2 exit | L3 direction |
|-----------|:-------:|----------------------|---------|--------------|
| Loop / Turn | **L2** | soft Tool errors、serial order、goldens、facade 单 terminal、provider in-flight cancel/deadline；accepted multi-Tool between-call cancel 的 Agent/transcript/session/trace 组合 fixture 已独立验收并通过 main std/curl Gate；Tool/shell mid-flight preemption 明确为 post-H process work | API/error/trace terminal 一致 ✅；provider cancel/deadline 有界 ✅；≥2 goldens ✅；真实组合 cancel fixture ✅ | steer、parallel read-only |
| Tool runtime / registry | **L2** | D-007: instance-aware Tool + mandatory ToolDescriptor/Capabilities；`buildTool`+`validateTools`+`loop.run` 对 missing/invalid caps fail-closed；path/shell 参数校验；Provider/WireProvider 仅 ToolDefinition；`.cooperative` 仅为声明（handler preemption 属 post-H shell/process work） | stateful Tool；mandatory descriptor；missing capability fail-closed | progress、concurrency、behavior version |
| Tools · read/search | **L1+** | list/read/grep/glob + budgets；h-workspace-001 symlink-aware containment 与 walker fixture 已落地；独立 row promotion 仍需按模块 acceptance 审计，不由 Phase H 绿测自动获得 | 结果有界 + walker 矩阵稳定 | LSP/repo map integration |
| Tools · write/edit | **L1+** | search_replace 唯一锚点、write_file、可选 diff；descriptor + Guard containment 已落地；canonical permission-path identity 和一般 write-fault/no-partial-mutation 保证未宣称 | containment 下 stale/ambiguous 可恢复且不误写；write fault contract 明确 | hashline/apply_patch、hunk review |
| Tools · shell | **L1** | review-fix: fixed deny；UTF-8/base64 + scoped limits；real N/N+1；checked body；direct-PID + Agent chain。re-review/main open；非 sandbox | package matrix ✅；re-review/main + final audit open | process supervisor |
| Permissions | **L2** | D-007: Gate/Ask/plan/remember 消费 descriptor.risk；custom write/execute 与 built-in 同 gate；无 `riskOf(name)`；canonical contained-path remember identity 不额外宣称 | descriptor-derived risk；custom Tool 与 built-in 同一 gate；missing risk fail-closed | path/domain policies、Plan UX |
| Workspace / Safety | **L2** | lexical + symlink-aware file containment（Root/Guard、loop+handler 双检、`code=jail_deny`）+ secret redaction + provider-independent doctor；default Agent ask-deny write / yolo escaping-symlink jail composition 已独立验收并通过 main std/curl；shell 是单独非 path-jail 边界；无 OS sandbox claim | file containment ✅；redaction ✅；doctor ✅；Agent policy/containment composition ✅ | OS sandbox/network/worktree |
| Context / Compaction | **L2** | h-context-001: fixed-point final-view；ID 精确 tool bundle fail-closed→`invalid_context`；lineage 截断有 digest/marker；共享 summary_cap=800；UTF-8 sanitize；session/trace 成功路径 byte-equal；soft min_tail；OOM 不静默 | final returned view 与 dropped/summary/session/trace 一致 ✅ | repo map、智能选文件 |
| Session / Resume | **L2** | D-006: create/resume distinct; open_or_create SDK-only; atomic save + per-Writer test fault preserves prior bytes; `Agent.reply` save IoFailed fixture; one active writer via reusable `{path}.lock`; strict header; lexical session path. Not claimed: fsync/power-loss, symlink containment, hostile Writer-copy defense | explicit create/resume; atomic preservation; visible save errors; exclusive writer/conflict | fork/tree/journal as needed |
| Provider / zag-ai | **L1+** | two wire styles、retry/usage/cost；curl active deadline/cancel；std ordinary OK + controlled lifecycle fail-closed `unsupported_control`；strict stream/tool atomic（h-provider-001）；HTTP 诊断仅 status+body length（h-redact-001） | capability-truth deadline/cancel ✅；redaction diagnostics ✅；contract matrix | fallback/multi-key/third protocol on demand |
| Trace / Observability | **L2** | h-trace-001 lifecycle + h-redact-001 redaction before serialize；schema；facade 单 terminal；Guard symlink jail；atomic；fail-closed。核心模块 L2；Phase H 仍待 h-shell-001 证明 shell policy/runtime 结果可复盘 | versioned schema ✅；truthful terminal ✅；symlink/atomic persistence ✅；redact ✅ | dashboard/correlation |
| Zig source composition | **L1** | external low-level Kernel composition 可编译运行 | [SDK gate](./packaging.md#sdk-ready-gate)：stateful Tool、injection、ownership/error/event contracts、external consumer CI | published packages after second consumer |
| Headless / Process SDK | **L1** | one-shot CLI 存在；无 versioned JSON/events/exit matrix | clean JSON/streaming output + stable errors/exit codes | ACP/editor integration |
| Memory Repo | L0 | 仅规格 | H 不做；C5 默认关闭 | optional retrieval backend |
| Subagents / Oracle | L0 | 仅规格 | H 不做；依赖 event/cancel/session contract | typed agents/Graph |
| Extensions | L0 | 仅规格 | H 不做；依赖 Tool/process contracts | Skills/Hooks/MCP |
| Quality / Evals | **L1+** | 既有 P0/P1 Gate passed；shell review-fix matrix 已进 suite，re-review/main pending | existing composition ✅；shell package ✅；Gate open | edit/cost/perf baselines |

## Phase H production-floor exit

全部为真，才能对外写“生产底线（单用户、受控本机）”：

1. **Session durability ✅**：create/resume 分离；invalid/unsupported/I/O 不回退新会话；save 原文件保护；错误可见；并发 writer 冲突。
2. **Tool contract ✅**：Tool 有 instance state 和 mandatory runtime descriptor；risk/path/cancel 不按名称猜测；缺失 metadata fail-closed。
3. **Filesystem containment/readiness ✅**：read/list/search/write/edit 不能经 symlink/alias 离开 workspace；shell 边界单独诚实说明；provider-independent doctor 暴露 active/degraded controls；default Agent policy/containment 组合 fixture 已独立验收并通过 main Gate。
4. **Truthful lifecycle ✅**：每个 started run 恰有一个 terminal；provider/save/trace 失败不得记为 completed success；provider timeout/in-flight cancel 已 contract-tested。
5. **Context accounting ✅**：compaction event、summary/lineage、session meta、trace 与最终 model view 一致。
6. **Secrets ✅**：fake configured key 不出现在 verbose、trace、session fixtures；`.zag/` 仍标敏感；无 zeroization/DLP 声称。
7. **Deadline/cancel ✅（按 H 边界）**：curl 真正执行 provider deadline/active cancel；std 配置 deadline 显式 `unsupported_control`；半截 Tool call 不执行；accepted multi-Tool turn 的 between-Tool cancel 组合 fixture 已验收。已运行 Tool/shell 的 mid-flight preemption 不属于 H，作为 post-H process work 保持显式 open。
8. **Editing/runtime — GATE OPEN (`h-shell-001`)**：review-fix package fixtures 已证明 fixed deny、
   UTF-8/base64、scoped limits、real N/N+1 与稳定 outcome shape；完整 body 有界且无 fake partial。
   独立 re-review/main Gate 尚未完成。
9. **Observability — GATE OPEN (`h-shell-001`)**：real invalid UTF-8 fixture 经 transcript/session/
   resume/parsed single-call trace 后以 recovered `completed` 收口；trace 用 exact-one counts，
   不假设 result call ID。独立 re-review/main Gate 与最终 audit 尚未完成。
10. **Regression evidence — PARTIAL GATE**：既有 P0/P1 composition 已通过独立/main std/curl；
    shell review-fix 矩阵已进入 package suite，但仍待独立 re-review 与 main std/curl Gate。
11. **Documentation truth ✅（当前基线）**：README、SECURITY、architecture、Phase H、module/task DAG 与本表一致，不声称 OS sandbox、process-tree cleanup、mid-flight Tool preemption、atomic edit fault guarantee 或 SDK-ready 已具备。

L2 **不要求 OS sandbox**，前提是声明严格限定在单用户 trusted-host，并保持默认 ask。更高自治、background job、untrusted executable extension 的发布 Gate 需要 C7 sandbox/process supervisor。

`h-shell-001` 完成后仍须重新运行全部 exit audit；它不会自动把 Phase H、read/search、write/edit、SDK 或 headless 标为 L2。

## SDK-ready gate

Phase H correctness 是前置，但不自动等于 SDK-ready。SDK-ready 还要求：

- supported high-level injection of Toolset/Observer/policy;
- documented ownership/lifetime/error/cancel/event compatibility;
- repository-owned external stateful consumer test;
- package self-contained tests;
- migration/release policy。

Semver publication and repo mirror wait for a second real consumer and release channel. See [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md).

## Teaching mapping

| Teaching | Demonstrates | Production gap |
|----------|--------------|----------------|
| Phase 0 | basic loop/read | lifecycle/error contracts |
| Phase 1 | write/shell/ask | descriptor-driven risk L2；file symlink containment closed；shell-v1 runtime open |
| Phase 2 | session/context | durability/open L2；compaction accounting L2 |
| Phase 3 | lexical jail/policy/trace | real file containment、truthful/versioned trace、redaction closed；no OS sandbox |
| **Phase H** | raises existing surfaces | in-progress `h-shell-001`（package evidence landed/Gate pending）→ blocked integration closeout → full exit audit |

## Maintenance

- Behavior changes update the relevant module doc, this matrix, task, and teaching chapter together.
- A partial implementation stays L1/L1+ until every exit sentence for that row passes.
- Capability work cannot mark a blocked H row L2 indirectly.
