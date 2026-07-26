# Zag 路线图

> Zag 是 **Pi-inspired Zig-native Agent Harness**。成熟度真理源：[maturity](./maturity.md)；范围决策：[D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md)；三方分析：[Pi alignment](./plan/analysis/2026-07-26-pi-zig-alignment.md)。

## 当前状态

| Track | Status | Meaning |
|-------|--------|---------|
| Teaching 0–3 | ✅ tutorial-complete | 教程可学习/演示；不等于 production claim |
| Production Floor H | ✅ **L2** | single-user trusted-host；11/11 audit PASS；panel SHIP |
| Zig SDK-ready | ✅ **L2** | public composition + external consumer fixture 7/7 |
| Headless/Process | ✅ **L2** | `headless-v1` + exit matrix + process fixture 4/4 |
| Pi-inspired daily Harness | **next** | interaction、events/control、fork、Skills、edit、minimal TUI |

OS sandbox、mid-flight Tool/shell preemption、semver/C ABI、provider breadth、Graph/Memory/MCP 均不因上述 Gate 自动获得。

## 方向规则

1. Zag mainline 保持独立；current Pi 是行为参考，旧 `pi-mono-zig` 是冻结设计/fixture 档案。
2. 不追 Pi release/API/feature parity；只跟选定的 Harness 语义。
3. C4–C9 是能力域，不是必须全部完成的线性产品清单。
4. 每个新 task 从一个可复现失败出发，写 contract、fixture、独立 review 和 merged-main Gate。
5. 默认不复制外部源码；任何 fixture/code import 都要 MIT provenance。

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
  skills-001       edit-sharpness-001
        └──────────────┬──────────────┘
                       ▼
                 tui-minimal-001
```

### M0 — Interaction reliability

Task: [cli-sigint-001](./plan/tasks/cli-sigint-001.md) — **ready**.

- idle direct REPL first Ctrl+C exits cleanly;
- active first Ctrl+C requests cooperative cancel;
- second interrupt provides bounded hard escape;
- direct binary behavior is contractual; `zig build run` parent-process-group behavior is only documented;
- no new std-HTTP or Tool/shell active-preemption claim。

Contract: [CLI interaction](./modules/cli-interaction.md).

### M1 — Core Harness controls

These tasks require their own analysis/task docs before implementation.

| Task | Objective | Gate |
|------|-----------|------|
| `harness-events-001` | stable message/Tool/run lifecycle vocabulary | ordering + one terminal + mapping to Observer/headless; no internal-union serialization |
| `harness-steering-001` | bounded steering/follow-up queues | deterministic insertion, ownership, cancel, transcript/session/trace evidence |
| `session-fork-001` | safe branch/fork behavior | parent unchanged; child durable/redacted; no lock/schema fallback |

This milestone aligns the smallest valuable Pi Harness semantics. It does **not** add subagents, Graph, provider hooks, or a new wire-compatible RPC protocol.

### M2 — Selected daily UX

| Task | Objective | Deliberate limit |
|------|-----------|------------------|
| `skills-001` | passive `SKILL.md` discovery + bounded prompt injection | no executable privilege/package manager |
| `edit-sharpness-001` | patch-grade edit + review/verification | no AST/LSP suite or multi-tool expansion |
| `tui-minimal-001` | streaming text, multiline input, Tool/permission/error cards | no dashboard/theme/image/plugin platform |

Minimal TUI depends on the event/control contracts; it must only assemble Kernel APIs and keep plain/headless Gates green.

## Extension release ladder (D-010)

| Rung | Surface | Gate |
|------|---------|------|
| E0 | trusted static Zig Toolset/Provider/Observer/policy | already covered by SDK-ready L2 |
| E1 | passive Skills | M2 `skills-001`; jailed discovery + budget + no execute |
| Events | optional trusted static deny-only hooks | lifecycle event contract first; no runtime loading claim |
| Supervisor | bounded child ownership | C7.1, only after concrete runtime-extension consumer |
| E2 | trusted local `zag-ext-v1` process extension | supervisor + versioned protocol + D-007 composition |
| Untrusted native | downloaded/third-party process | additionally required OS enforcement; no downgrade |
| E3 WASM Component | planned preferred installable third-party extension format | WIT contract → measured runtime → host capabilities/metering → packaging/trust |

No dynamic Zig library ABI, embedded Lua/QuickJS/Bun, Pi package-manager parity, or arbitrary extension-rendered TUI.

Planned post-M2 extension tasks (each needs its own docs-first contract):

```text
extension-schema-001
        │
process-supervisor-001 ──► extension-process-001 (E2)
        │
        └─► extension-wasm-contract-001
               → extension-wasm-runtime-001
               → extension-wasm-capabilities-001
               → extension-wasm-package-001 (E3)
```

E3 is a formal direction, not current implementation. Engine choice remains open until measured/security evidence exists.

## Capability domains after D-009

| Domain | Near-term slice | Deferred |
|--------|-----------------|----------|
| C4 Edit | `edit-sharpness-001` in M2 | multi-file transactions, AST/LSP |
| C5 Context | session fork in M1 | repo map until measured need; LLM summary optional; Memory default-off |
| C6 Control/Orchestration | steering/follow-up in M1 | Oracle, executable subagents, Graph |
| C7 Process/Sandbox | none | process supervisor only when executable/background use appears; OS enforcement after that |
| C8 Extensions | E0 static SDK already; E1 passive Skills in M2 | E2 process after C7.1；E3 WASM Component is the planned portable third-party tier |
| C9 Product shell | minimal TUI in M2 | ACP, dashboard, themes/images/full configuration UX |

The detailed phase docs describe domain constraints. A deferred item is not an implied future commitment.

## Re-entry triggers for deferred work

| Capability | Required trigger before planning |
|------------|----------------------------------|
| Repo map | measured medium-repo file-selection failure that current search/context cannot close |
| Oracle | repeated real weak-model dead ends and a pinned stronger-model budget |
| Process supervisor | background child, executable extension, or mid-flight process cancellation use case |
| OS sandbox | required higher-autonomy/untrusted execution profile after supervisor exists |
| E2 process extensions / MCP / runtime hooks | concrete local extension consumer + C7.1 supervisor; untrusted native additionally needs C7.2 OS enforcement |
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

- chasing Pi’s provider count, OAuth surface, CLI flags, package manager, TS-RPC, or release cadence;
- reviving/merging the historical parity port as Zag’s implementation base;
- implementing Oracle/Graph/Memory/MCP/sandbox/dashboard because a competitor has them;
- adding business logic to `main`/TUI/CLI instead of the owning package;
- claiming graceful cancellation where only cooperative flags exist;
- unmeasured Zig marketing claims.
