# Zag 生产成熟度矩阵

> **状态真理源。** 其他文档对“当前做到哪了”有争议时，以本文件为准。合同细节以对应 `docs/modules/` 和 active decisions 为准。

| Level | Meaning |
|-------|---------|
| **L0** | 无 / 玩具 |
| **L1** | 教程可演示；正常路径可用 |
| **L2** | **生产底线**：单用户、受控本机、失败可见、状态可恢复、行为可审计 |
| **L3** | 工业锐度与更高自治 |

`L1+` 只是规划中的中间标记，表示功能明显超过教程但仍被一个或多个 L2 合同反例阻断；它不是可对外宣传的等级。

**总状态（2026-07-25 final audit；2026-07-25 edit develop update）：** Teaching Phase 0–3 = L1 完成；Production Floor Phase H = **未达 L2**；Capability = 未开始。最终审计发现两个 file-surface L2 反例。`h-edit-integrity-001` 的 review-02 已通过 endpoint/outside-staging 与 cleanup-truth 修复，但 Oracle 随后发现 cleanup 后 result allocation OOM 可遮蔽 `may_remain` artifact；第三次 allocation-free selection 修复在 in-progress task branch，仍待 re-verification 与 merged-main Gate。read/search 预算/截断 blocker 仍 open，`h-integration-001` 在两者完成前 blocked。

> 绿测、schema 字段或包拆分本身不能升格。任何可导致静默数据丢失、权限 fail-open、越界访问或虚假审计终态的反例都会阻止相关子系统升到 L2。

评估与优先级：[production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)；最新 Gate：[2026-07-25 Phase H final audit](./plan/analysis/2026-07-25-phase-h-final-audit.md)。

## 当前矩阵

| Subsystem | Current | Evidence and blocker | L2 exit | L3 direction |
|-----------|:-------:|----------------------|---------|--------------|
| Loop / Turn | **L2** | soft Tool errors、serial order、goldens、facade 单 terminal、provider in-flight cancel/deadline；accepted multi-Tool between-call cancel 的 Agent/transcript/session/trace 组合 fixture 已独立验收并通过 main std/curl Gate；Tool/shell mid-flight preemption 明确为 post-H process work | API/error/trace terminal 一致 ✅；provider cancel/deadline 有界 ✅；≥2 goldens ✅；真实组合 cancel fixture ✅ | steer、parallel read-only |
| Tool runtime / registry | **L2** | D-007: instance-aware Tool + mandatory ToolDescriptor/Capabilities；`buildTool`+`validateTools`+`loop.run` 对 missing/invalid caps fail-closed；path/shell 参数校验；Provider/WireProvider 仅 ToolDefinition；`.cooperative` 仅为声明（handler preemption 属 post-H shell/process work） | stateful Tool；mandatory descriptor；missing capability fail-closed | progress、concurrency、behavior version |
| Tools · read/search | **L1+** | containment 已落地；final audit 反例：list/glob 仅 count cap 可超 64 KiB，read oversized prefix 与 Zig 0.16 limit 语义不一致，walker/source/pattern cutoffs 可静默不完整；`h-read-search-bounds-001` ready | 四类 body ≤64 KiB；每个 runtime cutoff 有完整 `fs-v1` marker；N/N+1/walker 矩阵 | LSP/repo map integration |
| Tools · write/edit | **L1+** | `h-edit-integrity-001` review-02 已通过 endpoint/strict target-parent、cleanup-truth 与 post-close replace；Oracle 的 post-cleanup OOM blocker 以 preallocated bodies + allocation-free ownership selection 修复并加入 allocator-boundary fixture；待 re-verification 与 merged-main Gate | target-preserving single-file commit；contained final symlink；stable `edit-v1` fault + Agent chain | hashline/apply_patch、hunk review |
| Tools · shell | **L2** | fixed generic deny；UTF-8/base64 + scoped capture/body limits；real N/N+1；checked 64 KiB body；direct-PID + Agent/session/parsed-trace chain；independent re-review + Oracle + main std/curl passed；非 sandbox | synchronous shell-v1 matrix、bounded body、direct-child evidence、truthful recovered terminal ✅ | process supervisor |
| Permissions | **L2** | D-007 descriptor-derived gate；remember 明确定义为 exact lexical request-path key，alias 保守 re-prompt 且 execution-time Guard 不可绕过；focused alias/jail evidence 跟随 h-edit-integrity-001 | descriptor-derived risk；custom Tool 同 gate；missing risk fail-closed；lexical remember boundary | canonical path/domain policies、Plan UX |
| Workspace / Safety | **L2** | lexical + symlink-aware file containment（Root/Guard、loop+handler 双检、`code=jail_deny`）+ secret redaction + provider-independent doctor；default Agent ask-deny write / yolo escaping-symlink jail composition 已独立验收并通过 main std/curl；shell 是单独非 path-jail 边界；无 OS sandbox claim | file containment ✅；redaction ✅；doctor ✅；Agent policy/containment composition ✅ | OS sandbox/network/worktree |
| Context / Compaction | **L2** | h-context-001: fixed-point final-view；ID 精确 tool bundle fail-closed→`invalid_context`；lineage 截断有 digest/marker；共享 summary_cap=800；UTF-8 sanitize；session/trace 成功路径 byte-equal；soft min_tail；OOM 不静默 | final returned view 与 dropped/summary/session/trace 一致 ✅ | repo map、智能选文件 |
| Session / Resume | **L2** | D-006: create/resume distinct; open_or_create SDK-only; atomic save + per-Writer test fault preserves prior bytes; `Agent.reply` save IoFailed fixture; one active writer via reusable `{path}.lock`; strict header; lexical session path. Not claimed: fsync/power-loss, symlink containment, hostile Writer-copy defense | explicit create/resume; atomic preservation; visible save errors; exclusive writer/conflict | fork/tree/journal as needed |
| Provider / zag-ai | **L2** | final audit confirmed two wire styles、canonical retry/error/usage/cost、strict terminal/tool atomicity、curl active deadline/cancel、std ordinary success + controlled lifecycle fail-closed `unsupported_control`、redacted diagnostics；backend capability truth is explicit | backend-capability deadline/cancel ✅；strict completion/tool bundle ✅；redacted diagnostics + deterministic contract matrix ✅ | fallback/multi-key/third protocol on demand |
| Trace / Observability | **L2** | h-trace-001 lifecycle + h-redact-001 redaction before serialize；schema；facade 单 terminal；Guard symlink jail；atomic；fail-closed；h-shell-001 证明 fixed policy/runtime first line 经 transcript/session/parsed exact-one trace 后 recovered completed | versioned schema ✅；truthful terminal ✅；symlink/atomic persistence ✅；redact ✅；shell projection ✅ | dashboard/correlation |
| Zig source composition | **L1** | external low-level Kernel composition 可编译运行 | [SDK gate](./packaging.md#sdk-ready-gate)：stateful Tool、injection、ownership/error/event contracts、external consumer CI | published packages after second consumer |
| Headless / Process SDK | **L1** | one-shot CLI 存在；无 versioned JSON/events/exit matrix | clean JSON/streaming output + stable errors/exit codes | ACP/editor integration |
| Memory Repo | L0 | 仅规格 | H 不做；C5 默认关闭 | optional retrieval backend |
| Subagents / Oracle | L0 | 仅规格 | H 不做；依赖 event/cancel/session contract | typed agents/Graph |
| Extensions | L0 | 仅规格 | H 不做；依赖 Tool/process contracts | Skills/Hooks/MCP |
| Quality / Evals | **L1+** | 既有 module/doctor/Agent/shell matrices 均通过；edit review-02 已通过，第三次修复新增 fail-next allocator fixture 证明 staged cleanup/result selection 无 allocation；仍待 re-verification，read/search budget/walker fixtures 仍缺 | existing composition ✅；shell matrix ✅；两项 file-surface fixtures + fresh integration audit | edit/cost/perf baselines |

## Phase H production-floor exit

全部为真，才能对外写“生产底线（单用户、受控本机）”：

1. **Session durability ✅**：create/resume 分离；invalid/unsupported/I/O 不回退新会话；save 原文件保护；错误可见；并发 writer 冲突。
2. **Tool contract ✅**：Tool 有 instance state 和 mandatory runtime descriptor；risk/path/cancel 不按名称猜测；缺失 metadata fail-closed。
3. **Filesystem containment/readiness ✅**：read/list/search/write/edit 不能经 symlink/alias 离开 workspace；shell 边界单独诚实说明；provider-independent doctor 暴露 active/degraded controls；default Agent policy/containment 组合 fixture 已独立验收并通过 main Gate。
4. **Truthful lifecycle ✅**：每个 started run 恰有一个 terminal；provider/save/trace 失败不得记为 completed success；provider timeout/in-flight cancel 已 contract-tested。
5. **Context accounting ✅**：compaction event、summary/lineage、session meta、trace 与最终 model view 一致。
6. **Secrets ✅**：fake configured key 不出现在 verbose、trace、session fixtures；`.zag/` 仍标敏感；无 zeroization/DLP 声称。
7. **Deadline/cancel ✅（按 H 边界）**：curl 真正执行 provider deadline/active cancel；std 配置 deadline 显式 `unsupported_control`；半截 Tool call 不执行；accepted multi-Tool turn 的 between-Tool cancel 组合 fixture 已验收。已运行 Tool/shell 的 mid-flight preemption 不属于 H，作为 post-H process work 保持显式 open。
8. **Editing/runtime ❌**：shell 子合同已通过；edit review-02 已通过 endpoint/outside-staging 与 cleanup-truth，Oracle 后续 post-cleanup OOM blocker 的 preallocation 修复已在 task branch，但 re-verification/main Gate 未完成；`h-read-search-bounds-001` 仍须证明四类 body 有界且所有 cutoff 显式 `fs-v1` incomplete。
9. **Observability ✅**：real invalid UTF-8 shell fixture 经 transcript/session/resume/parsed single-call trace 后以 recovered `completed` 收口；trace 用 exact-one counts，不假设 result call ID；shell policy/runtime replay Gate 已通过。
10. **Regression evidence ❌**：mutator endpoint/preservation/cleanup、post-staging allocation boundary、yolo Agent composition 与 separate core remember 永久 fixtures 已在 edit task branch 增加但待 re-verification；read/search budget/walker boundary fixtures 仍缺。
11. **Documentation truth ❌（delivery 状态）**：负面能力边界保持诚实；edit task 保持 `in-progress`，integration 保持 blocked。只有两 file task 完成且 fresh integration audit 通过后才能重新勾选本句。

L2 **不要求 OS sandbox**，前提是声明严格限定在单用户 trusted-host，并保持默认 ask。更高自治、background job、untrusted executable extension 的发布 Gate 需要 C7 sandbox/process supervisor。

Final audit verdict remains **FAIL** despite the historical default `384/384` and curl `383/383`. The edit task's develop implementation does not close its independent/merged-main Gate; complete and independently merge both file-surface tasks first, then return `h-integration-001` to `ready` for a fresh 11-sentence audit. A green shell/provider/edit develop suite does not promote Phase H, SDK, or headless indirectly.

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
| Phase 1 | write/shell/ask | descriptor-driven risk、file containment 与 synchronous shell-v1 已分别过 Gate；atomic edit fault implementation 在 task branch，仍待独立/main Gate |
| Phase 2 | session/context | durability/open L2；compaction accounting L2 |
| Phase 3 | lexical jail/policy/trace | real file containment、truthful/versioned trace、redaction closed；no OS sandbox |
| **Phase H** | raises existing surfaces | original DAG done；final audit found edit-integrity + read/search-bounds blockers → integration blocked |

## Maintenance

- Behavior changes update the relevant module doc, this matrix, task, and teaching chapter together.
- A partial implementation stays L1/L1+ until every exit sentence for that row passes.
- Capability work cannot mark a blocked H row L2 indirectly.
