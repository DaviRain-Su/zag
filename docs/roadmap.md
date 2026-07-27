# Zag 路线图

> Zag 是 **Pi-inspired Zig-native Agent Harness**。成熟度真理源：[maturity](./maturity.md)；范围决策：[D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md) 与 [D-011](./decisions/active/D-011-thin-agent-core-boundary.md)；三方分析：[Pi alignment](./plan/analysis/2026-07-26-pi-zig-alignment.md)。

## 当前状态

| Track | Status | Meaning |
|-------|--------|---------|
| Teaching 0–3 | ✅ tutorial-complete | 教程可学习/演示；不等于 production claim |
| Production Floor H | ✅ **L2** | single-user trusted-host；11/11 audit PASS；panel SHIP |
| Zig SDK-ready | ✅ **L2** | Gate closed at `ebdd7ab`; current external consumer fixture **23/23** |
| Headless/Process | ✅ **L2** | `headless-v1` + exit matrix + process fixture 4/4 |
| Thin Core responsibility migration | ✅ done | D-011 DAG through the product lifecycle adapter closed at `aecf402`; no L2 behavior change |
| Pi-inspired daily Harness | **next** | lifecycle events ✅; bounded steering/follow-up ✅ at `a5ff2b7`; idle-only durable session fork ✅ at `0a3087f`; E1 Skills ✅ at `caafef5` (`skills-001`, Runtime Extensions L0); E1 Prompt Templates ✅ at `61326ae` (`prompt-templates-001`, Runtime Extensions L0); C4 `edit-sharpness-001` **contract-in-progress** (impl BLOCKED until independent contract PASS; Tools write/edit stays L2); then minimal TUI |

OS sandbox、mid-flight Tool/shell preemption、semver/C ABI、provider breadth、Graph/Memory/MCP 均不因上述 Gate 自动获得。

## 方向规则

1. Zag mainline 保持独立；current Pi 是行为参考，旧 `pi-mono-zig` 是冻结设计/fixture 档案。
2. 对应 Pi 的用户能力类别，不追 release/API/schema/CLI/实现 parity；每个类别可选择不同的 Zig-native 载体。
3. C4–C9 是能力域，不是必须全部完成的线性产品清单。
4. 每个新 task 从一个可复现失败出发，写 contract、fixture、独立 review 和 merged-main Gate。
5. 默认不复制外部源码；任何 fixture/code import 都要 MIT provenance。

## 功能对应地图

| Pi 维度 | Zag 路线 |
|---------|----------|
| Extension | E0 静态组合；E2 process；E3 WASM，按 Tool/events/commands/UI 分 Gate |
| Skill | M2 E1 `skills-001` ✅ at `caafef5`（Runtime Extensions 仍 L0） |
| Prompt Template | E1 `prompt-templates-001` ✅ at `61326ae` — binding [prompt-templates](./modules/prompt-templates.md); Runtime Extensions L0 |
| Theme | `tui-minimal-001` 之后的 host-shell data/renderer task |
| Package | local runtime bundle（E1 + optional E2/E3）；不是执行 tier；E0 不可热安装 |
| Custom Model | validated runtime data task，独立于 WASM |
| Custom Provider | E0 已有；E2/E3 runtime registration 后置 |
| SDK | ✅ L2；lifecycle events 已在 `aecf402` 闭合，bounded steering/control 已在 `a5ff2b7` 闭合，idle-only durable fork 已在 `0a3087f` 闭合（[session-fork](./modules/session-fork.md)）；E1 Skills 已在 `caafef5` 闭合；E1 Prompt Templates 已在 `61326ae` 闭合；current fixture **23/23**，不升成熟度 |
| JSON | ✅ `headless-v1` L2 |
| RPC | 正式后置 `rpc-v1`，独立于 `headless-v1`，不追 Pi command/schema parity |
| TUI/UI | minimal host TUI；E2/E3 host-rendered intents，stateful view/action 另过 Gate |

详细证据：[Pi feature correspondence](./plan/analysis/2026-07-26-pi-feature-correspondence.md)。

## 已完成基础

```text
Teaching 0 → 1 → 2 → 3
              │
              ▼
Phase H correctness ──► Zig SDK-ready ──► closed
              └───────► Headless-v1 ────► closed
```

历史 task 和 Gate 数字保留在 [plan](./plan/README.md)、[maturity](./maturity.md) 及相应 task closeout 中，不在新 Capability 路线重复展开。

## 近期 DAG

```text
M0 — interaction reliability
  cli-sigint-001 ✅
        │
        └─► ci-hang-sigint-linux-errno-001 ✅ bc737025
              │
              ├─► ci-hang-ci-fuses-001 ✅ done/closed @ 97f43de (host fuses only)
              ├─► ci-hang-sigint-process-idle-001 ✅ done Phase B (tip 8a93ec6 / run 30273762011)
              └─► linux-dual-backend-gate-001 ✅ done (tip 8a93ec6 / run 30273762011; exact tip/run only)
        │
        ▼
M0.5 — thin Core responsibility migration
  core-boundary-001
    → core-seams-001
    → core-session-ownership-001
    → core-observation-ownership-001
    → core-policy-ownership-001
    → core-context-ownership-001
        │
        ▼
M1 — product Harness controls
  harness-events-001 ✅ aecf402
        │
        ├────► harness-steering-001 ✅ a5ff2b7
        └────► session-fork-001 ✅ 0a3087f
                       │
                       ▼
M2 — selected daily UX
  skills-001 ✅ caafef5 → prompt-templates-001 ✅ 61326ae
        │
        ├──────────────┐
        │       edit-sharpness-001 (contract-in-progress; impl BLOCKED)
        └──────────────┬──────────────┘
                       ▼
                 tui-minimal-001
```

### M0 — Interaction reliability

Task: [cli-sigint-001](./plan/tasks/cli-sigint-001.md) — **done** at `d542332`.

- idle direct REPL first Ctrl+C exits cleanly;
- active first Ctrl+C requests cooperative cancel;
- second interrupt provides bounded hard escape;
- direct binary behavior is contractual; `zig build run` parent-process-group behavior is only documented;
- no new std-HTTP or Tool/shell active-preemption claim;
- independent verification passed; merged-main std **465/465** and curl **464/464** Gates are green.

Follow-on (P0, **done** at `bc737025`): [ci-hang-sigint-linux-errno-001](./plan/tasks/ci-hang-sigint-linux-errno-001.md) —
decode raw Linux self-pipe/`read`/`pipe2`/`fcntl` returns with `std.os.linux.errno` so curl-linked `link_libc`
builds do not misclassify `-EAGAIN` as success and hang in `drainWake`. Candidate Gate std **611/611**, curl
**610/610**; independent review-fix PASS (zero blockers); ff-only local main `3cd0837` → `bc737025`; merged-main
local macOS Gate again std **40/40 · 611/611**, curl **42/42 · 610/610**. Pure raw-Linux decoder regression ran in
both std and curl-linked test artifacts; local host gates passed. Does not raise maturity; does not soften the
separately tracked idle process-fixture timeout; does not change CI workflows. **No push.**

Process-idle residual
[ci-hang-sigint-process-idle-001](./plan/tasks/ci-hang-sigint-process-idle-001.md) is **done** via Phase B Pass
path (no product/fixture change) on fresh Actions run
[30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) against tip
`8a93ec6efb7256413ed3d36e2034bb8fb8a343da` (created `2026-07-27T14:10:10Z`, completed success
`2026-07-27T14:12:09Z`). Ubuntu job `Zig ubuntu-latest` success: std **40/40 · 611/611** with process-level
SIGINT `run test 2 pass (2 total) 126ms`; curl **42/42 · 610/610** with process-level SIGINT `run test 2 pass
(2 total) 126ms`; libcurl install success. macOS job `Zig macos-latest` success. Idle oracle (readiness +
`waitBounded(4000)` + exit 0 + stderr/leak assertions) and active std **130** / curl **11** retained; fuses
configured but **not** fired. Current Linux idle status is **PASS** at that exact tip/run only — not a universal
future guarantee.
[ci-hang-ci-fuses-001](./plan/tasks/ci-hang-ci-fuses-001.md) is **done/closed** at `97f43de` as host rails only
(binding [quality/README](./quality/README.md); exact fuses
`group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: true`, 30m per matrix job; full
ubuntu/macos + std/curl retained; no `continue-on-error`; independent review + ff-only local main
`af293b0` → `97f43de`; **no push**; timeout/cancel ≠ product hang proof; remote Actions fuse enforcement **not**
claimed). Final merged-path remote Linux dual-backend Gate
[linux-dual-backend-gate-001](./plan/tasks/linux-dual-backend-gate-001.md) is **done** (docs-only) on the same
tip/run: Ubuntu std **40/40 · 611/611** + process-level SIGINT **2/2** `126ms`; curl **42/42 · 610/610** +
**2/2** `126ms`; libcurl install success; macOS job + both std/curl success; OpenAPI **287/287**; catalog **40**;
docs **91/73**; `waitBounded(4000)`, idle exit **0**, active std **130** / curl **11**, `linuxRawErrno`, and exact
fuses/full matrix/no `continue-on-error` preserved; fuses configured but **did not fire**. Broader M0 Linux
dual-backend reliability is **closed only** at exact tip `8a93ec6` / run `30273762011` — not a universal future
guarantee. `prompt-templates-001` is **done** at `61326ae`
([task](./plan/tasks/prompt-templates-001.md), binding [module](./modules/prompt-templates.md));
merged-main local macOS dual-backend Gate std **40/40 · 633/633**, curl **42/42 · 632/632**;
Runtime Extensions L0 unchanged; **no push** and no fresh remote/Linux evidence for this tip.

Contract: [CLI interaction](./modules/cli-interaction.md). CI fuses quality contract:
[quality/README](./quality/README.md).

### M0.5 — Thin Core responsibility migration

[D-011](./decisions/active/D-011-thin-agent-core-boundary.md) corrected the package responsibility model before more
Harness features landed. Its serialized ownership tasks and the product lifecycle adapter completed at `aecf402`; see
[the Core boundary module](./modules/core-boundary.md). They preserved all closed L2 contracts and created no new Zig
package.

### M1 — Product Harness controls

The lifecycle prerequisite, bounded interactive-control slice, and safe idle-only durable Session fork are closed.
`harness-steering-001` passed its merged-main Gate at `a5ff2b7`; `session-fork-001` passed independent reviews and its
merged-main dual-backend Gate at `0a3087f`. The fork preserves session schema v1 and does **not** change maturity.

| Task | Status | Objective | Gate |
|------|--------|-----------|------|
| [harness-events-001](./plan/tasks/harness-events-001.md) | **done @ `aecf402`** | coding-agent SDK lifecycle projection from Core source facts + facade run facts | ordering + one terminal + separate SDK/Trace/headless types; no Core lifecycle channel or internal-union serialization |
| [harness-steering-001](./plan/tasks/harness-steering-001.md) | **done @ `a5ff2b7`** | Session-owned bounded steering/follow-up + thin Core insertion seam | std 567/567; curl 566/566; Core 89/89; Coding 298/298; SDK 20/20; deterministic insertion, ownership/retention, `code=steered`, and compatible Trace/session/lifecycle evidence |
| [session-fork-001](./plan/tasks/session-fork-001.md) | **done @ `0a3087f`** | safe idle-only durable fork (parent unchanged; child exclusive create_new + deep-copy) | std 40/40 steps, 579/579 tests; curl 42/42 steps, 578/578 tests; Core 89/89; Coding 309/309; SDK 21/21; fixture list 1–29; no Core fork or schema/maturity change |

This milestone aligns the smallest valuable Pi Harness semantics. The M1 closeout is SDK/Loop/Session enrichment only:
Phase H, SDK-ready, Headless/Process, Loop, Session, Trace, and Zig source composition remain **L2**. It does **not** add
session tree/journal, subagents, Graph, provider hooks, or a new wire-compatible RPC protocol.

### M2 — Selected daily UX

| Task | Objective | Deliberate limit |
|------|-----------|------------------|
| `skills-001` | passive `SKILL.md` discovery + bounded prompt injection; **done @ `caafef5`** ([skills](./modules/skills.md), [task](./plan/tasks/skills-001.md)) | loader has no execute privilege; induced Tool calls still use normal security Gates; Runtime Extensions stays L0 |
| [prompt-templates-001](./plan/tasks/prompt-templates-001.md) | reusable slash-expanded prompts; **done @ `61326ae`** ([prompt-templates.md](./modules/prompt-templates.md)) | explicit one-pass `$ARGUMENTS`/`$$` substitution; project overrides user; no script runtime; maturity stays L0 |
| [edit-sharpness-001](./plan/tasks/edit-sharpness-001.md) | **contract-in-progress**: freeze `apply_hunk` + digest `read_file` + mandatory hunk review + optional post-commit verifier ([tools-edit](./modules/tools-edit.md)); impl **BLOCKED** until independent contract PASS | no AST/LSP; no multi-file txn; no Core/schema change; Tools write/edit stays L2 |
| `tui-minimal-001` | streaming text, multiline input, Tool/permission/error cards | no dashboard/theme/image/plugin platform |

Minimal TUI depends on the event/control contracts; it must only assemble Kernel APIs and keep plain/headless Gates green.

## Extension release ladder (D-010)

| Rung | Surface | Gate |
|------|---------|------|
| E0 | trusted static Zig Toolset/Provider/Observer/policy | already covered by SDK-ready L2 |
| E1 | passive Skills, then Prompt Templates; theme data later | jailed discovery + budget + no loader execution; downstream Tool gates remain mandatory |
| Events | optional trusted static deny-only hooks | lifecycle contract closed at `aecf402`; hook API and runtime loading remain unimplemented |
| Supervisor | bounded child ownership | C7.1, only after concrete runtime-extension consumer |
| E2 | trusted local `zag-ext-v1` process extension | supervisor + versioned protocol + D-007 composition |
| Untrusted native | downloaded/third-party process | additionally required OS enforcement; no downgrade |
| E3 WASM Component | planned preferred installable third-party executable format | Tool/WIT → measured runtime → host capabilities/metering → packaging/trust → later feature worlds |

No dynamic Zig library ABI, embedded Lua/QuickJS/Bun, Pi package-manager parity, raw-terminal extension access, or arbitrary Host renderer pointers. Later E2/E3 stateful UI uses host-rendered view/action data, not component pointers.

Planned post-M2 programmatic/extension capabilities (each needs its own docs-first contract):

```text
public events/control/session
        ├─► rpc-v1
        ├─► extension-schema-001
        │      ├─► process-supervisor-001 ──► extension-process-001 (E2)
        │      └─► extension-wasm-contract-001
        │             → extension-wasm-runtime-001
        │             → extension-wasm-capabilities-001
        │             → extension-wasm-package-001 (E3)
        ├─► runtime-model-catalog-001 (data-only)
        └─► extension-ui-schema-001 (basic intents first; stateful views later)

host shell: tui-minimal-001 → theme-001
```

E3 is a formal direction, not current implementation. The first WASM host is compute-only Tool scope; later hooks/commands/Provider/UI worlds require separate Gates. Engine choice remains open until measured/security evidence exists.

## Capability domains after D-009

| Domain | Near-term slice | Deferred |
|--------|-----------------|----------|
| C4 Edit | `edit-sharpness-001` in M2 — **contract-in-progress** ([task](./plan/tasks/edit-sharpness-001.md), [C4](./phases/C4-edit-sharpness.md)); impl BLOCKED pending contract PASS | multi-file transactions, AST/LSP, multi-hunk apply_patch platform |
| C5 Context | idle-only durable session fork closed in M1 | full tree/journal and repo map deferred; LLM summary optional; Memory default-off |
| C6 Control/Orchestration | steering/follow-up in M1 | Oracle, executable subagents, Graph |
| C7 Process/Sandbox | none | process supervisor only when executable/background use appears; OS enforcement after that |
| C8 Extensions | E0 static SDK already; E1 Skills + Prompt Templates in M2 | E2 after C7.1; E3 WASM portable executable tier; bundle/model/UI worlds separately gated |
| C9 Product shell | minimal TUI in M2 | `rpc-v1`, themes, extension UI host, ACP, dashboard/images/full configuration UX |

The detailed phase docs describe domain constraints. A deferred item is not an implied future commitment.

## Re-entry triggers for deferred work

| Capability | Required trigger before planning |
|------------|----------------------------------|
| Repo map | measured medium-repo file-selection failure that current search/context cannot close |
| Oracle | repeated real weak-model dead ends and a pinned stronger-model budget |
| Process supervisor | background child, executable extension, or mid-flight process cancellation use case |
| OS sandbox | required higher-autonomy/untrusted execution profile after supervisor exists |
| E2 process extensions / MCP / runtime hooks | concrete local extension consumer + C7.1 supervisor; untrusted native additionally needs C7.2 OS enforcement |
| `rpc-v1` | a long-lived client that cannot use one-shot `headless-v1`, after public events/control/session contracts |
| Runtime Custom Model/Provider | concrete model/provider requirement that static catalog/E0 Provider cannot express; credentials remain host-owned |
| Package/UI extension | at least one local multi-resource bundle or stateful view that basic intents cannot express |
| ACP/editor | a real editor host willing to consume versioned process semantics |
| Memory | repeated cross-session retrieval use case with delete/audit requirements |
| Graph/subagents | repeated orchestration shape that cannot be expressed by one Loop + steering |
| New provider/OAuth | named user/provider requirement and wire contract fixture |

## Quality rules

- Every fixed P0/P1 and public process/SDK behavior remains a permanent regression.
- External Pi/legacy assets are untrusted reference data; no execution or dependency is introduced by research.
- Imported code/data/goldens require exact commit/path, MIT notice, and a scoped relevance test.
- std/curl capability differences remain explicit.
- No performance/startup/size/cross-build claim before a reproducible benchmark Gate.

## Packaging

| Action | Timing |
|--------|--------|
| Keep current monorepo package set; migrate responsibility within Core/coding-agent per D-011 | now |
| Add new package | only after real ownership/dependency pressure; no empty future packages |
| Repo mirror / semver publication | second real consumer + release channel |
| C/Zig dynamic plugin ABI | no current commitment; prefer versioned process contracts |

## Stop doing

- chasing Pi’s provider count, OAuth breadth, exact CLI flags, npm package manager, RPC command/schema parity, or release cadence;
- reviving/merging the historical parity port as Zag’s implementation base;
- implementing Oracle/Graph/Memory/MCP/sandbox/dashboard because a competitor has them;
- adding business logic to `main`/TUI/CLI instead of the owning package;
- claiming graceful cancellation where only cooperative flags exist;
- unmeasured Zig marketing claims.
