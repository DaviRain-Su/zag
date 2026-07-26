# Zag 生产成熟度矩阵

> **状态真理源。** 其他文档对“当前做到哪了”有争议时，以本文件为准。合同细节以对应 `docs/modules/` 和 active decisions 为准。

| Level | Meaning |
|-------|---------|
| **L0** | 无 / 玩具 |
| **L1** | 教程可演示；正常路径可用 |
| **L2** | **生产底线**：单用户、受控本机、失败可见、状态可恢复、行为可审计 |
| **L3** | 工业锐度与更高自治 |

`L1+` 只是规划中的中间标记，表示功能明显超过教程但仍被一个或多个 L2 合同反例阻断；它不是可对外宣传的等级。

**总状态（2026-07-26 interaction closeout）：** Teaching Phase 0–3 = L1 完成；Production Floor Phase H = **L2（单用户、受控本机）**；Zig SDK-ready = **L2**；Headless/Process SDK = **L2**；Capability = 未开始。Phase H L2 仅限 single-user trusted-host scope；OS sandbox、process-tree ownership、mid-flight Tool/shell preemption、power-loss/fsync durability、exhaustive concurrent traversal、DLP/zeroization、第三方 Tool 通用 body 保证、ACP/editor、semver/C ABI 仍不宣称。`sdk-contract-001` 在 `ebdd7ab` 关闭 Zig SDK-ready Gate。`headless-001` 在 `a1a1e0f` 关闭 Headless/Process Gate：`headless-v1` + `--json`/`--json-stream` + exit matrix + process fixture 4/4；independent review APPROVE_WITH_NITS → F-1 fix；ship panel SHIP；merged-main Gate root std **452/452**、curl **451/451**、coding **139/139**、docs lint、readability **91/100**、security **66/100**（44 files）、OpenAPI **287/287**、catalog **40**。

**产品范围（D-009/D-011）：** closed L2 rows remain unchanged. Interaction reliability M0 closed at `d542332`: direct idle SIGINT exits cleanly, active cancellation has a bounded hard escape, and merged-main std **465/465** plus curl **464/464** passed independent verification. This does not claim build-runner normalization, std-HTTP active interruption, Tool/shell preemption, or process-tree ownership. Thin-Core migration step 1 closed at `b6a33a6`: `loop.run` now requires explicit `ToolPolicy`, `Jail`, `ShellPolicy`, `ContextView`, and fallible canonical `LoopEventSink`. Step 2 closed at `b137723`: durable session storage moved to `zag-coding-agent` while Core retained `Transcript`; D-006 behavior and session v1 remained unchanged. Step 3 closed at `b0cabb3`: Trace, redaction, and product Observer/logging moved to `zag-coding-agent` while Core retained one borrowed/fallible `LoopEventSink`; the 12-kind source map, Trace v1, headless-v1, borrowed-payload SDK evidence, and merged-main std **479/479** plus curl **478/478** remained green. Concrete permission/workspace/shell ownership is the next serialized move; lifecycle events/control and session fork remain re-queued behind the full migration. This ownership correction does not lower or raise maturity: every move must preserve the existing L2 fixtures, schemas, and terminal truth before closeout. Pi feature categories have a correspondence map, but RPC, theme, runtime package/model/Provider/UI, and E2/E3 remain L0/planned and do not inherit maturity. Oracle/Graph/Memory/MCP/sandbox/provider breadth are not implied roadmap obligations.

> 绿测、schema 字段或包拆分本身不能升格。任何可导致静默数据丢失、权限 fail-open、越界访问或虚假审计终态的反例都会阻止相关子系统升到 L2。

评估与优先级：[production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md)；最新 Gate：[2026-07-25 Phase H final audit](./plan/analysis/2026-07-25-phase-h-final-audit.md)。

## 当前矩阵

| Subsystem | Current | Evidence and blocker | L2 exit | L3 direction |
|-----------|:-------:|----------------------|---------|--------------|
| Loop / Turn | **L2** | soft Tool errors、serial order、goldens、facade 单 terminal、provider in-flight cancel/deadline；accepted multi-Tool between-call cancel 的 Agent/transcript/session/trace 组合 fixture 已独立验收并通过 main std/curl Gate；Tool/shell mid-flight preemption 明确为 post-H process work | API/error/trace terminal 一致 ✅；provider cancel/deadline 有界 ✅；≥2 goldens ✅；真实组合 cancel fixture ✅ | steer、parallel read-only |
| Tool runtime / registry | **L2** | D-007: instance-aware Tool + mandatory ToolDescriptor/Capabilities；`buildTool`+`validateTools`+`loop.run` 对 missing/invalid caps fail-closed；path/shell 参数校验；Provider/WireProvider 仅 ToolDefinition；`.cooperative` 仅为声明（handler preemption 属 post-H shell/process work） | stateful Tool；mandatory descriptor；missing capability fail-closed | progress、concurrency、behavior version |
| Tools · read/search | **L2** | `h-read-search-bounds-001` done：四 handler bodies `<=64KiB`；完整 first `fs-v1` marker；read N/N+1/growth；walker node/depth/per-dir/io；source/binary/pattern；fixed `.git`/build-directory search-scope exclusions；likely-binary probe heuristic；generic bounded path/name-free jail/unknown bodies；required/defaulted descriptor behavior with real Agent evidence；reviews 01–10 review/fix cycle + final review 10 PASS + ship panel SHIP + merged-main Gate passed | scoped read/search L2 ✅；not exhaustive concurrent traversal or third-party generic body enforcement | LSP/repo map integration |
| Tools · write/edit | **L2** | h-edit-integrity-001: strict endpoint/selected-parent containment；same-parent atomic replace；cleanup `absent|may_remain` truth；allocation-free staged failure selection；contained final symlink；signaled optional-diff child retains success；Agent/session/trace + lexical remember fixtures；reviews 01–04 review/fix cycle + final Oracle/main Gate passed | target-preserving single-file commit ✅；stable `edit-v1` + Agent chain ✅ | hashline/apply_patch、hunk review |
| Tools · shell | **L2** | fixed generic deny；UTF-8/base64 + scoped capture/body limits；real N/N+1；checked 64 KiB body；direct-PID + Agent/session/parsed-trace chain；independent re-review + Oracle + main std/curl passed；非 sandbox | synchronous shell-v1 matrix、bounded body、direct-child evidence、truthful recovered terminal ✅ | process supervisor |
| Permissions | **L2** | D-007 descriptor-derived gate；remember = exact lexical request-path，alias 保守 re-prompt，execution-time Guard 不可绕过；h-edit-integrity-001 focused alias/jail independent/main Gate passed | descriptor-derived risk；custom Tool 同 gate；missing risk fail-closed；lexical remember boundary ✅ | canonical path/domain policies、Plan UX |
| Workspace / Safety | **L2** | lexical + symlink-aware file containment（Root/Guard、loop+handler 双检、`code=jail_deny`）+ secret redaction + provider-independent doctor；default Agent ask-deny write / yolo escaping-symlink jail composition 已独立验收并通过 main std/curl；shell 是单独非 path-jail 边界；无 OS sandbox claim | file containment ✅；redaction ✅；doctor ✅；Agent policy/containment composition ✅ | OS sandbox/network/worktree |
| Context / Compaction | **L2** | h-context-001: fixed-point final-view；ID 精确 tool bundle fail-closed→`invalid_context`；lineage 截断有 digest/marker；共享 summary_cap=800；UTF-8 sanitize；session/trace 成功路径 byte-equal；soft min_tail；OOM 不静默 | final returned view 与 dropped/summary/session/trace 一致 ✅ | repo map、智能选文件 |
| Session / Resume | **L2** | D-006: create/resume distinct; open_or_create SDK-only; atomic save + per-Writer test fault preserves prior bytes; `Agent.reply` save IoFailed fixture; one active writer via reusable `{path}.lock`; strict header; lexical session path. Not claimed: fsync/power-loss, symlink containment, hostile Writer-copy defense | explicit create/resume; atomic preservation; visible save errors; exclusive writer/conflict | fork/tree/journal as needed |
| Provider / zag-ai | **L2** | final audit confirmed two wire styles、canonical retry/error/usage/cost、strict terminal/tool atomicity、curl active deadline/cancel、std ordinary success + controlled lifecycle fail-closed `unsupported_control`、redacted diagnostics；backend capability truth is explicit | backend-capability deadline/cancel ✅；strict completion/tool bundle ✅；redacted diagnostics + deterministic contract matrix ✅ | fallback/multi-key/third protocol on demand |
| Trace / Observability | **L2** | h-trace-001 lifecycle + h-redact-001 redaction before serialize；schema；facade 单 terminal；Guard symlink jail；atomic；fail-closed；h-shell-001 证明 fixed policy/runtime first line 经 transcript/session/parsed exact-one trace 后 recovered completed | versioned schema ✅；truthful terminal ✅；symlink/atomic persistence ✅；redact ✅；shell projection ✅ | dashboard/correlation |
| Zig source composition | **L2** | SDK-ready Gate closed at `ebdd7ab`：stateful Tool、high-level `Toolset`/`Observer` injection、ownership/lifetime/error/event/per-run cancel/session contracts、external consumer CI | supported import surface + contract docs + `tests/sdk-consumer-fixture/` pass merged-main Gate | published packages after second consumer |
| Headless / Process SDK | **L2** | `headless-001` done at `a1a1e0f`：output-only `headless-v1` + `--json`/`--json-stream` + headless-only exit matrix；process fixture 4/4（real binary + mock provider, both backends）；stdout purity；stream terminal uniqueness incl. halt-then-success；default mode 0/1/2 unchanged；`-Dtui` optional + Kernel no-TUI scan | clean JSON/streaming output + stable errors/exit codes ✅ | separate Zag-native `rpc-v1` / ACP/editor Gates |
| Memory Repo | L0 | 仅规格 | H 不做；C5 默认关闭 | optional retrieval backend |
| Subagents / Oracle | L0 | 仅规格 | H 不做；依赖 event/cancel/session contract | typed agents/Graph |
| Runtime Extensions | L0 | D-010 + feature correspondence specs only；trusted static Zig composition is SDK L2, but E1 discovery / E2 process / E3 WASM host / runtime bundle/UI do not exist | E1 Skills then Prompt Templates；E2 requires C7.1；E3 requires WIT/runtime/capability/package Gates；untrusted native requires C7.2 | local bundle + host-rendered stateful UI + separately gated WASM Provider/hook worlds |
| Quality / Evals | **L2** | 既有 module/doctor/Agent/shell/edit/read-search matrices 均通过；fresh integration audit 在 `d22ce6e` PASS；gate 数字见总状态 | existing composition ✅；shell/edit/read-search matrices ✅；fresh integration audit PASS | edit/cost/perf baselines |

## Phase H production-floor exit

全部为真，才能对外写“生产底线（单用户、受控本机）”：

1. **Session durability ✅**：create/resume 分离；invalid/unsupported/I/O 不回退新会话；save 原文件保护；错误可见；并发 writer 冲突。
2. **Tool contract ✅**：Tool 有 instance state 和 mandatory runtime descriptor；risk/path/cancel 不按名称猜测；缺失 metadata fail-closed。
3. **Filesystem containment/readiness ✅**：read/list/search/write/edit 不能经 symlink/alias 离开 workspace；shell 边界单独诚实说明；provider-independent doctor 暴露 active/degraded controls；default Agent policy/containment 组合 fixture 已独立验收并通过 main Gate。
4. **Truthful lifecycle ✅**：每个 started run 恰有一个 terminal；provider/save/trace 失败不得记为 completed success；provider timeout/in-flight cancel 已 contract-tested。
5. **Context accounting ✅**：compaction event、summary/lineage、session meta、trace 与最终 model view 一致。
6. **Secrets ✅**：fake configured key 不出现在 verbose、trace、session fixtures；`.zag/` 仍标敏感；无 zeroization/DLP 声称。
7. **Deadline/cancel ✅（按 H 边界）**：curl 真正执行 provider deadline/active cancel；std 配置 deadline 显式 `unsupported_control`；半截 Tool call 不执行；accepted multi-Tool turn 的 between-Tool cancel 组合 fixture 已验收。已运行 Tool/shell 的 mid-flight preemption 不属于 H，作为 post-H process work 保持显式 open。
8. **Editing/runtime ✅**：shell、single-file write/edit、read/search bounded-output 子合同均已独立/main 验收；read/search closeout covers four handler bodies `<=64KiB`, complete `fs-v1` markers, read N/N+1/growth, walker/source/binary/pattern/defaulted-descriptor/Agent evidence.
9. **Observability ✅**：real invalid UTF-8 shell fixture 经 transcript/session/resume/parsed single-call trace 后以 recovered `completed` 收口；trace 用 exact-one counts，不假设 result call ID；shell policy/runtime replay Gate 已通过。
10. **Regression evidence ✅**：mutator endpoint/preservation/cleanup、post-staging allocation boundary、post-commit signaled diff ownership、yolo Agent composition、core remember fixtures、read/search budget/walker/source/binary/pattern/defaulted-descriptor/Agent fixtures 均已通过 merged-main evidence.
11. **Documentation truth ✅**：read/search task closeout 与 integration-ready 状态已同步；fresh 11-sentence integration audit 在 `d22ce6e` PASS，panel SHIP，gate 数字已验证。

L2 **不要求 OS sandbox**，前提是声明严格限定在单用户 trusted-host，并保持默认 ask。更高自治、background job、untrusted executable extension 的发布 Gate 需要 C7 sandbox/process supervisor。

Phase H 已 closeout 为 **L2（单用户、受控本机）**。Edit integrity 与 read/search 已独立合并并 L2；`h-integration-001` fresh audit PASS。Zig SDK-ready 与 Headless/Process 已各自独立闭合；上述排除项（OS sandbox、mid-flight preemption、semver/C ABI、ACP 等）仍不自动获得。

## SDK-ready gate

Phase H correctness 是前置，但不自动等于 SDK-ready。SDK-ready 已在 `ebdd7ab` 闭合：

- supported high-level injection of Toolset/Observer/policy ✅
- documented ownership/lifetime/error/cancel/event/session compatibility ✅
- repository-owned external stateful consumer test ✅ (`tests/sdk-consumer-fixture/` 7/7)
- package self-contained tests ✅
- migration/release policy ✅（semver publication still waits for a second real consumer and release channel）

Semver publication and repo mirror wait for a second real consumer and release channel. See [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md).

## Headless / Process SDK gate

Independent of Zig source composition. Closed at `a1a1e0f` (`headless-001`):

- versioned `headless-v1` public protocol (not a dump of Observer/Trace) ✅
- `--json` single envelope and `--json-stream` NDJSON with exactly one terminal ✅
- headless-only structured errors and exit-code matrix; default mode 0/1/2 unchanged ✅
- stdout purity (logs/help/REPL do not pollute protocol stdout) ✅
- process-level CI fixture (real `zag` binary, empty env, mock provider) on both HTTP backends ✅
- TUI optional (`-Dtui` default false); Kernel packages do not import TUI ✅

Does not claim ACP/editor integration, OS sandbox, or default-mode exit redesign. Contract: [modules/headless-contract.md](./modules/headless-contract.md).

## Teaching mapping

| Teaching | Demonstrates | Production gap |
|----------|--------------|----------------|
| Phase 0 | basic loop/read | lifecycle/error contracts |
| Phase 1 | write/shell/ask | descriptor risk、file containment、synchronous shell-v1 与 scoped atomic single-file edit integrity 均已过独立/main Gate |
| Phase 2 | session/context | durability/open L2；compaction accounting L2 |
| Phase 3 | lexical jail/policy/trace | real file containment、truthful/versioned trace、redaction closed；no OS sandbox |
| **Phase H** | raises existing surfaces | L2 closeout：original DAG done；final audit file blockers closed；integration audit PASS；SDK Gate closed at `ebdd7ab`；Headless Gate closed at `a1a1e0f` |

## Maintenance

- Behavior changes update the relevant module doc, this matrix, task, and teaching chapter together.
- A partial implementation stays L1/L1+ until every exit sentence for that row passes.
- Capability work cannot mark a blocked H row L2 indirectly.
