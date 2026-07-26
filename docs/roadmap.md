# Zag 路线图

> Zag 是 **Pi-inspired Zig-native Agent Harness**。成熟度真理源：[maturity](./maturity.md)；范围决策：[D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md)；三方分析：[Pi alignment](./plan/analysis/2026-07-26-pi-zig-alignment.md)。

## 当前状态

| Track | Status | Meaning |
|-------|--------|---------|
| Teaching 0–3 | ✅ tutorial-complete | 教程可学习/演示；不等于 production claim |
| Production Floor H | ✅ **L2** | single-user trusted-host；11/11 audit PASS；panel SHIP |
| Zig SDK-ready | ✅ **L2** | public composition + external consumer fixture 7/7 |
| Headless/Process | ✅ **L2** | `headless-v1` + exit matrix + process fixture 4/4 |
| Pi-inspired daily Harness | **next** | interaction、events/control、fork、Skills/Prompt Templates、edit、minimal TUI |

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
| Skill | M2 E1 `skills-001` |
| Prompt Template | E1 `prompt-templates-001`，复用资源发现基础 |
| Theme | `tui-minimal-001` 之后的 host-shell data/renderer task |
| Package | local runtime bundle（E1 + optional E2/E3）；不是执行 tier；E0 不可热安装 |
| Custom Model | validated runtime data task，独立于 WASM |
| Custom Provider | E0 已有；E2/E3 runtime registration 后置 |
| SDK | ✅ L2；后续通过 events/control/fork 丰富 |
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
  cli-sigint-001
        │
        ▼
M1 — core Harness controls
  harness-events-001
        │
        ├────► harness-steering-001
        └────► session-fork-001
                       │
                       ▼
M2 — selected daily UX
  skills-001 → prompt-templates-001
        │
        ├──────────────┐
        │       edit-sharpness-001
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

Contract: [CLI interaction](./modules/cli-interaction.md).

### M1 — Core Harness controls

These tasks require their own analysis/task docs before implementation.

| Task | Objective | Gate |
|------|-----------|------|
| [harness-events-001](./plan/tasks/harness-events-001.md) | source-backed message/Tool/run lifecycle vocabulary | ordering + one terminal + separate SDK/Trace/headless types; no internal-union serialization |
| `harness-steering-001` | bounded steering/follow-up queues | deterministic insertion, ownership, cancel, transcript/session/trace evidence |
| `session-fork-001` | safe branch/fork behavior | parent unchanged; child durable/redacted; no lock/schema fallback |

This milestone aligns the smallest valuable Pi Harness semantics. It does **not** add subagents, Graph, provider hooks, or a new wire-compatible RPC protocol.

### M2 — Selected daily UX

| Task | Objective | Deliberate limit |
|------|-----------|------------------|
| `skills-001` | passive `SKILL.md` discovery + bounded prompt injection | loader has no execute privilege; induced Tool calls still use normal security Gates |
| `prompt-templates-001` | reusable slash-expanded prompts over the shared E1 loader | explicit non-recursive substitution; no script runtime |
| `edit-sharpness-001` | patch-grade edit + review/verification | no AST/LSP suite or multi-tool expansion |
| `tui-minimal-001` | streaming text, multiline input, Tool/permission/error cards | no dashboard/theme/image/plugin platform |

Minimal TUI depends on the event/control contracts; it must only assemble Kernel APIs and keep plain/headless Gates green.

## Extension release ladder (D-010)

| Rung | Surface | Gate |
|------|---------|------|
| E0 | trusted static Zig Toolset/Provider/Observer/policy | already covered by SDK-ready L2 |
| E1 | passive Skills, then Prompt Templates; theme data later | jailed discovery + budget + no loader execution; downstream Tool gates remain mandatory |
| Events | optional trusted static deny-only hooks | lifecycle event contract first; no runtime loading claim |
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
| C4 Edit | `edit-sharpness-001` in M2 | multi-file transactions, AST/LSP |
| C5 Context | session fork in M1 | repo map until measured need; LLM summary optional; Memory default-off |
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
| Keep current monorepo/package boundaries | now |
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
