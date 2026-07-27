# Zag 包分层与拆包设计（Pi-inspired Harness × Kernel SDK）

| 项 | 内容 |
|----|------|
| 状态 | **Active design**；包边界已落地，SDK-ready Gate 已闭合；发布 Gate 仍开放 |
| 对标 | Pi Harness 语义 + Grok Build 单向 workspace discipline；不复制源码/API/包粒度 |
| 决策 | **单 monorepo 多包**；拆 repo 是发布动作，不是架构动作；见 [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md) 与 [D-011](./decisions/active/D-011-thin-agent-core-boundary.md) |

---

## 0. 产品与包边界

[D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md) 将 Zag 定位为 **Pi-inspired Zig-native Agent Harness**，而不是 all-in-one 或 parity fork：

1. **产品目标 = 小而完整的 Harness**：只把已复现失败所需的能力放进近期产品面。
2. **实现纪律 = 严格分层**：每个能力有 owner 包、failure contract 和独立 Gate；依赖只准朝下。
3. **SDK 目标 = Harness 可嵌入**：`zag-agent-core` low-level composition 与 `zag-coding-agent` high-level injection 已闭合 SDK-ready Gate；D-011 已在无 semver 发布承诺下收窄 Core，external consumer fixture 记录迁移。
4. **参考纪律 = 行为对齐，不追源码/API/功能表**：current Pi 与旧 `pi-mono-zig` 是固定快照参考，不是依赖或同步上游。

```text
      Zag 产品 Harness（plain/headless/later minimal TUI）
              ▲  组装
      Kernel composition → SDK-ready ✅（zag-agent-core + selected APIs）
              ▲  依赖
      契约层（zag-types / Tool runtime metadata）
```

两个客户，一套代码：本地 Zag 产品与 Zig SDK consumer。产品是 Kernel 的第一个、也是最严格的消费者。

### Zig build package 与 runtime extension bundle 不是一回事

| Property | E0 Zig source/build package | Runtime extension bundle |
|----------|-----------------------------|--------------------------|
| Owner | Zig build graph / SDK consumer | product extension host |
| Trust point | compile time | install/enable time |
| Distribution | source, monorepo, `build.zig.zon` | manifest + content + digest/provenance |
| Execution | same-process trusted code | E1 passive data, E2 child, E3 Component |
| Hot install | no; rebuild required | only after its tier Gate |
| Contents | E0 only | E1 resources + optional E2/E3 artifacts; never E0 |

本文件其余“package/包”默认指 Zig build/package boundary。用户可安装的 runtime bundle 由 [extensions module](./modules/extensions.md#runtime-package-bundle-vs-e0-source-distribution) 与 [D-010](./decisions/active/D-010-extension-tiers-and-process-protocol.md) 定义，不能热安装 E0 Zig 源码。

---

## 1. 外部分层纪律参考（Grok Build）

从 workspace Cargo.toml 实测的依赖方向：

```text
L0 契约      xai-tool-types → xai-tool-protocol → xai-grok-tools-api → xai-tool-runtime
             sampling-types · config-types · workspace-types · hooks-plugins-types
L1 基础设施  paths · env · version · tty-utils · file-utils · token-estimation · http · secrets · tracing
L2 领域服务  models · config · auth · sampler · tools · sandbox · workspace ·
             memory · hooks · mcp · compaction · codebase-graph · hunk-tracker · chat-state
L3 agent     xai-grok-agent   （tools + sampling-types + hooks 的组合定义）
L4 内核      xai-grok-shell   （session · turn loop · subagent · workflow —— kernel）
L5 产品 UX   xai-grok-pager · pager-render · dashboard · acp-lib
L6 发行      xai-grok-pager-bin（单一二进制，组装 L4+L5）
```

**可抄的三条纪律：**

| 纪律 | Grok Build 证据 |
|------|-----------------|
| 依赖单向，产品不反噬内核 | pager-bin → pager → shell → agent → tools → tool-protocol；无回边 |
| 重依赖隔离（quarantine） | shell 注释明确：reqwest/rmcp 关在 `xai-grok-mcp` 内部，"shell never sees it" |
| 类型与实现分包 | `*-types` / `tools-api` 独立于实现 crate，SDK 消费者可只依赖契约 |

---

## 2. Zag 包分层（0.5.0 已落地骨架）

Zig monorepo。**2026-07-24 已完成第一轮拆包**（`8c5f543` + `076183e`）：
`zag-agent-core` / `zag-coding-agent` / `zag-cli` 各自独立 `build.zig(.zon)`，`src/main.zig` 只剩进程入口，`src/root.zig` 为 umbrella re-export。

```text
L0 契约          zag-types ✅         canonical message · tool 协议 · 中性 ChatError
L1 基础设施      （暂并入各包；token 估算 / paths 膨胀后再拆 zag-utils）
L2 领域服务      openai-zig          HTTP SDK ✅
                 zag-ai              resolve · WireAdapter · catalog · stream · contract ✅
                 zag-tools           fs/edit/grep/shell 实现（今在 coding-agent/runtime；H2 稳定后拆出）
                 zag-workspace       future only if a second owner appears; implementation currently stays in coding-agent
                 zag-sandbox         OS 沙箱（C7 新包）
                 future extension/memory packages（仅真实 ownership pressure 时创建）
L3 产品 harness  zag-coding-agent ✅  Agent/Session · policy/permissions/HITL/remember · workspace containment · shell protect · context · persistence/observation/lifecycle adapter · model wiring · runtime tools (depends on zag-agent-core + zag-ai + zag-types)
L4 内核 ★low-level composition
                 zag-agent-core ✅    loop · Transcript · Provider/Tool/Cancel ports · protocol history · required ToolPolicy/Jail/ShellPolicy/ContextView/LoopEventSink/ControlInput ports（**仅依赖 zag-types**）
                 SDK-ready ✅         stateful Tool/capabilities/session/event/ownership/cancel/control/fork/skills contract 已闭合；Gate fixture 7/7，current fixture 22/22
L5 产品面        zag-cli ✅           flags · resolve · one-shot / REPL
                 zag-tui / zag-acp   （C9）
L6 发行          zag (bin)           `src/main.zig` 薄入口 → `zag_cli.run` ✅
```

> 命名说明：早稿虚名 `zag-kernel` / `zag-agent` 已由实际包名 **`zag-agent-core`** / **`zag-coding-agent`** 取代（Pi 式命名，分层语义与 Grok Build shell/agent 一致）。文档一律用实际包名。

### 依赖规则（强制）

1. **只准朝下依赖**；L4 不得 import L5/L6。
2. L2 包之间不互相依赖，经 L0 契约通信（例外须在本文件登记）。
3. HTTP/network/WASM runtime details stay quarantined in `openai-zig` / `zag-ai` / future consumed extension adapters; `zag-agent-core` sees no wire client or engine type.
4. Model-visible `ToolDefinition` 与 local runtime `ToolCapabilities` 分离；见 [D-007](./decisions/active/D-007-tool-runtime-descriptor.md)。
5. 每个包独立 `zig build test`；契约测试放在被依赖方；SDK Gate 另有 external consumer fixture。
6. 同包不是 ownership 豁免：durable state、concrete product policy、logging/redaction 即使只依赖 L0，也不得因此留在 loop kernel。

### D-011 responsibility migration and bounded-control follow-on

D-011 did not create another package. The serialized migration is complete through `harness-events-001` at `aecf402`:

| Concern | Stable owner/location |
|---|---|
| Loop/Transcript/Provider/Tool/Cancel/protocol history | Core |
| Required ToolPolicy/Jail/ShellPolicy/ContextView/LoopEventSink contracts | Core contracts |
| Session store | coding-agent |
| Trace/redaction/Observer/verbose logger | coding-agent; CLI renders terminal/log output |
| permission/workspace/shell implementations | coding-agent |
| context layers/compaction | coding-agent; Core retains protocol-history validation and authoritative context-view types |
| run preflight/start/terminal and public lifecycle adapter | coding-agent |
| bounded control queues | coding-agent Session; Core owns only the required generic `ControlInput` seam and safe insertion points |

The migration preserved existing L2 schemas and behavior; it neither downgraded nor raised a maturity row. Every move
reran package, SDK, headless, std/curl, and security fixtures. The final product lifecycle adapter Gate passed std
**530/530**, curl **529/529**, and SDK consumer fixture **18/18** at that closeout. The follow-on bounded-control Gate at
`a5ff2b7` passed std **567/567**, curl **566/566**, and SDK fixture **20/20** at that closeout. The idle-only durable
Session-fork Gate at `0a3087f` passed std **579/579**, curl **578/578**, and SDK fixture **21/21** at that closeout. The
E1 Skills Gate at `caafef5` passed std **609/609**, curl **608/608**, and the current SDK fixture **22/22**. None of
these enrichments changed a maturity row (Runtime Extensions remains L0). See [`modules/core-boundary.md`](./modules/core-boundary.md).

### 概念层 ↔ 实际包名

| 概念层（architecture） | 实际包 | 状态 |
|------------------------|--------|------|
| Product shell | zag-cli（+ C9 zag-tui / zag-acp）+ zag (bin) | ✅ |
| Kernel low-level composition | **zag-agent-core** | ✅ SDK-ready baseline；D-011 responsibility migration done at `aecf402` |
| 产品 harness（agent 定义 + 组装） | **zag-coding-agent** | ✅ caller injection + product policy/context/persistence/observation/lifecycle adapter owner |
| Model plane（canonical + WireAdapter） | zag-ai + openai-zig | L2 H contract；dual-wire strict completion + curl active controls + std unsupported-control truth |
| Runtime / 领域包 | coding-agent runtime/workspace/shell policy；未来 sandbox | Tool descriptor/file containment/synchronous shell-v1 Gates 已通过；OS sandbox 仍后置；SDK compatibility 已闭合 |
| 契约 | **zag-types** | canonical + runtime ToolCapabilities/Descriptor 已落地；SDK-ready Gate 已闭合；semver publication 仍待第二真实 consumer + 发布通道 |

### 后续拆分排期

| 拆什么 | 从哪拆 | 时机 | 动机 |
|--------|--------|------|------|
| ~~**zag-types**~~ | ~~`zag-ai/types`~~ | ✅ 已完成 | core 仅依赖 zag-types；`ChatError` 中性 |
| ~~D-011 Core responsibility migration~~ | ~~core session/trace/redact/policy/workspace/shell/context~~ | ✅ done through `harness-events-001` at `aecf402` | ownership moved without a new Zig package |
| zag-tools | `zag-coding-agent/src/runtime/*` + toolset | SDK Gate 后且有第二消费边界 | 不是 H2 完成的自动动作 |
| zag-workspace | coding-agent workspace/shell policy | containment implementation出现第二 owner且 C7 需要独立演进时 | sandbox runner 不强制与 lexical policy 同包 |
| zag-agent（若需要） | coding-agent agent definition | C6 出现真实多 agent composition 后 | 不提前建空包 |

### 2.1 ~~已知残留：core → zag-ai~~（已解）

`zag-agent-core` 现只依赖 **`zag-types`**。catalog 预算在 `zag-cli` 经 `context.optionsFromBudget` 注入；`wire.Error` 为 `ChatError` 别名。

---

## 3. 拆包 / 拆 repo 标准

Monorepo 是常态（Grok Build 也是单仓）。一个包升级为独立 repo 须同时满足：

1. **API 冻结**：语义化版本，破坏性变更有迁移文档；
2. **第二使用方**：除 zag bin/仓库 fixture 外至少一个真实外部消费者；计划本身不算消费者；
3. **测试自洽**：不依赖 monorepo 其他包的私有测试设施；
4. **发布通道**：tag / zon 包可独立获取。

拆出方式优先 **read-only mirror + tag 同步**（monorepo 仍是唯一开发源），避免双向合并。`openai-zig` 是第一个候选。

---

## 4. SDK readiness（当前无发布承诺）

[D-008](./decisions/active/D-008-sdk-and-process-boundaries.md) separates three levels:

| Level | Contract | Current |
|-------|----------|---------|
| Low-level Zig composition | direct Provider/Toolset/Observer/Transcript/loop assembly | ✅ validated |
| Zig SDK-ready | supported high-level injection + ownership/error/event/cancel/session compatibility | ✅ closed at `ebdd7ab` — Gate fixture 7/7; current fixture **22/22** after D-011/lifecycle/control/session-fork/skills enrichment; see [`sdk-contract.md`](./modules/sdk-contract.md) |
| Process SDK/headless | versioned JSON/events + stable errors/exit codes | ✅ closed — `headless-v1` + exit matrix + process fixture; merged-main Gate passed at `a1a1e0f` |

### SDK-ready Gate

The Gate is **closed** as of `ebdd7ab`. All conditions are satisfied:

1. Phase H correctness passes; no fail-open custom Tool or unsafe session semantics.
2. `Tool` supports instance state and mandatory runtime capabilities.
3. Supported high-level composition accepts caller `Toolset`, `Observer`, and policy without product-private fields.
4. Ownership/lifetime, typed errors, cancellation/deadline, events, and session semantics are documented and tested in [`docs/modules/sdk-contract.md`](./modules/sdk-contract.md).
5. A repository-owned external consumer (`tests/sdk-consumer-fixture/`) builds/runs in CI without private monorepo imports — **7/7** tests pass.
6. Package tests are self-contained.

Merged-main evidence: fixture **7/7**, `zag-coding-agent` **139/139**, root std **440/440**, curl **439/439**, docs lint, readability **91/100**, security **66/100** (43 files), OpenAPI **287/287**, catalog **40**. No explicit skips; the single curl differential is the existing `zag-ai` backend-specific fixture.

Only after the Gate may a stability table assign semver promises. Repo mirror additionally needs a second real consumer and release channel.

Supported consumer import modules: `zag-types`, `zag-agent-core`, `zag-coding-agent`. Consumer code must import by module name only; sibling source paths such as `@import("../packages/...")` are not supported.

Target usage is intentionally illustrative until the Gate lands:

```zig
// Target shape; this is not the current Agent.Options API.
var agent = zag.Agent.init(gpa, io, provider, .{
    .toolset = my_tools,
    .observer = my_observer,
    .permission_policy = my_policy,
});
```

Cross-language hosts use versioned process contracts. [D-010](./decisions/active/D-010-extension-tiers-and-process-protocol.md) distinguishes outward `headless-v1` from future inward `zag-ext-v1`; neither promises a stable C ABI, Zig dynamic ABI, or in-process dynamic plugin ABI.

---

## 5. 与路线图的关系

- **Phase H**：保持当前 package layout；既有 Gates、`h-edit-integrity-001`、`h-read-search-bounds-001`、`h-integration-001` 均已通过；Phase H 在 `d22ce6e` closeout 为 **L2（单用户、受控本机）**。
- **SDK-ready Gate**：已闭合；public injection、external consumer、contract docs 均已落地并通过 merged-main Gate；不由 Phase H 或 package count 自动获得。
- **Headless Gate**：已闭合于 `a1a1e0f`；`--json` / `--json-stream`、`headless-v1`、exit matrix、process fixture 与 dual-backend Gate 均已通过；不宣称 ACP/editor、OS sandbox 或 default-mode exit 重设计。
- **C track**：新能力先声明 package boundary 与 failure contract；不把 business logic 长进 cli/main。
- Split decisions use dependency/consumer pressure, not phase completion as an automatic trigger.

## 6. 刻意不做

- 在 H/P0-P1 correctness 未闭合时继续碎拆；
- 在第二真实 consumer 与发布通道落地前承诺 semver public API、C ABI 或 dynamic plugin ABI；
- 双向同步的 multi-repo development flow；
- 为对齐 Grok Build 而复刻其 crate 粒度；只有真实 ownership/dependency pressure 才拆包。

## 相关

- [architecture.md](./architecture.md) — 分层图（与本文件一致）
- [vision.md](./vision.md) — Pi-inspired Harness × Kernel SDK 定位
- [roadmap.md](./roadmap.md) — 阶段推进
