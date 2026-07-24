# Zag 生产成熟度矩阵

> **状态真理源。** 其他文档对“当前做到哪了”有争议时，以本文件为准。合同细节以对应 `docs/modules/` 和 active decisions 为准。

| Level | Meaning |
|-------|---------|
| **L0** | 无 / 玩具 |
| **L1** | 教程可演示；正常路径可用 |
| **L2** | **生产底线**：单用户、受控本机、失败可见、状态可恢复、行为可审计 |
| **L3** | 工业锐度与更高自治 |

`L1+` 只是规划中的中间标记，表示功能明显超过教程但仍被一个或多个 L2 合同反例阻断；它不是可对外宣传的等级。

**总状态（2026-07-24 评估后）：** Teaching Phase 0–3 = L1 完成；Production Floor Phase H = **未达 L2**；Capability = 未开始。

> 绿测、schema 字段或包拆分本身不能升格。任何可导致静默数据丢失、权限 fail-open、越界访问或虚假审计终态的反例都会阻止相关子系统升到 L2。

评估与优先级：[production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)。

## 当前矩阵

| Subsystem | Current | Evidence and blocker | L2 exit | L3 direction |
|-----------|:-------:|----------------------|---------|--------------|
| Loop / Turn | **L1+** | soft Tool errors、serial order、goldens、between-call cancel 已有；provider failure/terminal trace 与 in-flight cancel 未闭合 | API/error/trace terminal 一致；cancel/deadline 有界；≥2 goldens | steer、parallel read-only |
| Tool runtime / registry | **L2** | D-007: instance-aware Tool + mandatory ToolDescriptor/Capabilities；`buildTool`+`validateTools`+`loop.run` 对 missing/invalid caps fail-closed；path/shell 参数校验；Provider/WireProvider 仅 ToolDefinition；`.cooperative` 仅为声明（mid-flight cancel 属 h-provider-001） | stateful Tool；mandatory descriptor；missing capability fail-closed | progress、concurrency、behavior version |
| Tools · read/search | **L1+** | list/read/grep/glob + budgets；symlink-aware containment（h-workspace-001）已拦 escape；结果预算有 | 结果有界 + walker 矩阵稳定 | LSP/repo map integration |
| Tools · write/edit | **L1+** | search_replace 唯一锚点、write_file、可选 diff；create/write 经 Guard 祖先 walk；escape/dangling deny | containment 下 stale/ambiguous 可恢复且不误写 | hashline/apply_patch、hunk review |
| Tools · shell | **L1** | timeout/truncation/exit 基础存在；denylist 不是 sandbox；policy 选 shell 靠 descriptor.shell 非名称 | 统一错误形状、deadline/cancel、policy matrix | background job/process supervisor |
| Permissions | **L2** | D-007: Gate/Ask/plan/remember 消费 descriptor.risk；custom write/execute 与 built-in 同 gate；无 `riskOf(name)` | descriptor-derived risk；custom Tool 与 built-in 同一 gate；missing risk fail-closed | path/domain policies、Plan UX |
| Workspace / Safety | **L1+** | lexical + **symlink-aware file containment**（Root/Guard、loop+handler 双检、`code=jail_deny`）；descriptor 选 path/shell；shell 仍 denylist；**无** secret redaction/doctor → 整行未达 L2 | file containment ✅；redaction、doctor、诚实 threat model 文档齐 | OS sandbox/network/worktree |
| Context / Compaction | **L1+** | four Layers + view-only summary 已有；second-stage trim accounting 不完整 | final returned view 与 dropped/summary/session/trace 一致 | repo map、智能选文件 |
| Session / Resume | **L2** | D-006: create/resume distinct; open_or_create SDK-only; atomic save + per-Writer test fault preserves prior bytes; `Agent.reply` save IoFailed fixture; one active writer via reusable `{path}.lock`; strict header (version required on typed header); lexical session path; P0 fixtures (create-existing, resume missing/invalid/unsupported/general-I/O, fault-save, busy, stale sidecar, CLI open-mode). Not claimed: fsync/power-loss, symlink containment, hostile Writer-copy defense | explicit create/resume; atomic preservation; visible save errors; exclusive writer/conflict | fork/tree/journal as needed |
| Provider / zag-ai | **L1+** | two wire styles、retry/usage/contracts/cost 已有；std timeout 无效、stream cancel/partial Tool safety 未闭合 | enforced-or-rejected deadline；in-flight cancel；redaction；contract matrix | fallback/multi-key/third protocol on demand |
| Trace / Observability | **L1** | event JSONL/usage/retry 已有；无 schema，provider failure 可被 finalise 为成功，I/O hidden | versioned schema；exactly one truthful terminal；visible persistence failure | dashboard/correlation |
| Zig source composition | **L1** | external low-level Kernel composition 可编译运行 | [SDK gate](./packaging.md#sdk-ready-gate)：stateful Tool、injection、ownership/error/event contracts、external consumer CI | published packages after second consumer |
| Headless / Process SDK | **L1** | one-shot CLI 存在；无 versioned JSON/events/exit matrix | clean JSON/streaming output + stable errors/exit codes | ACP/editor integration |
| Memory Repo | L0 | 仅规格 | H 不做；C5 默认关闭 | optional retrieval backend |
| Subagents / Oracle | L0 | 仅规格 | H 不做；依赖 event/cancel/session contract | typed agents/Graph |
| Extensions | L0 | 仅规格 | H 不做；依赖 Tool/process contracts | Skills/Hooks/MCP |
| Quality / Evals | **L1+** | goldens、provider fixtures、dual backend CI；tool-policy + session + **symlink containment** P0 fixtures 已进；redaction 等仍缺 | P0/P1 failure matrix进入 CI；不得削弱断言 | edit/cost/performance baselines |

## Phase H production-floor exit

全部为真，才能对外写“生产底线（单用户、受控本机）”：

1. **Session durability**：create/resume 分离；invalid/unsupported/I/O 不回退新会话；save 原文件保护；错误可见；并发 writer 冲突。
2. **Tool contract**：Tool 有 instance state 和 mandatory runtime descriptor；risk/path/cancel 不按名称猜测；缺失 metadata fail-closed。
3. **Filesystem containment**：read/list/search/write/edit 不能经 symlink/alias 离开 workspace（**file sub-capability done** h-workspace-001）；shell 边界单独诚实说明；整行 Safety 仍待 redaction/doctor。
4. **Truthful lifecycle**：每个 started run 恰有一个 terminal；provider/save/trace/cancel/timeout 不得记为 completed success。
5. **Context accounting**：compaction event、summary/lineage、session meta、trace 与最终 model view 一致。
6. **Secrets**：fake configured key 不出现在 verbose、trace、session fixtures；`.zag/` 仍标敏感。
7. **Deadline/cancel**：公开 timeout 真正执行或明确拒绝；provider/stream cancellation 有界；半截 Tool call 不执行。
8. **Editing/runtime**：search_replace/grep/glob 可用；shell exit/timeout/truncation/deny 为稳定机器可读形状。
9. **Observability**：trace schema versioned；permission/jail/shell/usage/stop reason 可复盘；显式 trace I/O failure可见。
10. **Regression evidence**：goldens + P0 fault fixtures + security/redaction + provider cancel contracts 均在 CI。
11. **Documentation truth**：README、SECURITY、architecture、Phase H 与本表一致，不声称 OS sandbox 或 SDK-ready 已具备。

L2 **不要求 OS sandbox**，前提是声明严格限定在单用户 trusted-host，并保持默认 ask。更高自治、background job、untrusted executable extension 的发布 Gate 需要 C7 sandbox/process supervisor。

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
| Phase 1 | write/shell/ask | descriptor-driven risk (D-007 L2); file symlink containment closed in H |
| Phase 2 | session/context | durability/open/compaction accounting |
| Phase 3 | lexical jail/policy/trace | real file containment (H); redaction/truthful trace still open |
| **Phase H** | raises all existing surfaces | current active P0/P1 tasks |

## Maintenance

- Behavior changes update the relevant module doc, this matrix, task, and teaching chapter together.
- A partial implementation stays L1/L1+ until every exit sentence for that row passes.
- Capability work cannot mark a blocked H row L2 indirectly.
