# Zag 包分层与拆包设计（Kernel SDK × All-in-One）

| 项 | 内容 |
|----|------|
| 状态 | **Active design**；包边界已落地，SDK-ready/发布 Gate 未达 |
| 对标 | Grok Build 单向 workspace discipline；不复制 crate 粒度 |
| 决策 | **单 monorepo 多包**；拆 repo 是发布动作，不是架构动作；见 [D-008](./decisions/active/D-008-sdk-and-process-boundaries.md) |

---

## 0. 定位修正

此前文档偏向 Pi 的「最小内核」叙事。**修正为 Grok Build 路线：**

1. **产品目标 = all-in-one**：工具、子代理、沙箱、扩展、TUI 都是一等目标，不做「刻意极简」。
2. **实现纪律 = 严格分层**：功能多不等于泥球；每个能力落进一个小包，依赖只准朝下。
3. **SDK 目标 = 内核可嵌入**：`zag-agent-core` 的 low-level composition 已可行；只有通过 SDK-ready Gate 的 public surface 才获得兼容承诺，不能把所有下层包自动视为已发布 SDK。
4. Pi 保留的只有一条：**扩展验证纪律**（新工作流先 skill/plugin 验证再内置）——不再作为「默认面要小」的依据。

```text
      All-in-One 产品（zag bin / TUI / headless）
              ▲  组装
      Kernel composition → SDK-ready Gate（zag-agent-core + selected domain APIs）
              ▲  依赖
      契约层（types / tool-protocol）
```

两个客户，一套代码：自己的产品是 SDK 的第一个、也是要求最苛刻的用户。

---

## 1. Grok Build 分层（依赖证据）

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
                 zag-workspace       jail · git · worktree（今在 agent-core；H5 稳定后拆出）
                 zag-sandbox         OS 沙箱（C7 新包）
                 zag-hooks / zag-mcp / zag-memory / zag-compaction（C 轨按需新包）
L3 产品 harness  zag-coding-agent ✅  Agent/Session 外观 · 默认 toolset · WireProvider 桥 · runtime tools
L4 内核 ★low-level composition
                 zag-agent-core ✅    loop · 纯 Provider 端口 · session · policy · trace（**仅依赖 zag-types**）
                 SDK-ready ❌         stateful Tool/capabilities/session/event contract 待 Gate
L5 产品面        zag-cli ✅           flags · resolve · one-shot / REPL
                 zag-tui / zag-acp   （C9）
L6 发行          zag (bin)           `src/main.zig` 薄入口 → `zag_cli.run` ✅
```

> 命名说明：早稿虚名 `zag-kernel` / `zag-agent` 已由实际包名 **`zag-agent-core`** / **`zag-coding-agent`** 取代（Pi 式命名，分层语义与 Grok Build shell/agent 一致）。文档一律用实际包名。

### 依赖规则（强制）

1. **只准朝下依赖**；L4 不得 import L5/L6。
2. L2 包之间不互相依赖，经 L0 契约通信（例外须在本文件登记）。
3. HTTP/network details quarantine in `openai-zig` / `zag-ai` / future `zag-mcp`; `zag-agent-core` does not see wire clients.
4. Model-visible `ToolDefinition` 与 local runtime `ToolCapabilities` 分离；见 [D-007](./decisions/active/D-007-tool-runtime-descriptor.md)。
5. 每个包独立 `zig build test`；契约测试放在被依赖方；SDK Gate 另有 external consumer fixture。

### 概念层 ↔ 实际包名

| 概念层（architecture） | 实际包 | 状态 |
|------------------------|--------|------|
| Product shell | zag-cli（+ C9 zag-tui / zag-acp）+ zag (bin) | ✅ |
| Kernel low-level composition | **zag-agent-core** | ✅；SDK-ready ❌ |
| 产品 harness（agent 定义 + 组装） | **zag-coding-agent** | ✅；caller injection 待 SDK Gate |
| Model plane（canonical + WireAdapter） | zag-ai + openai-zig | L1+；curl active deadline/cancel + std unsupported-control truth 已落地 |
| Runtime / 领域包 | coding-agent runtime / core workspace；未来 sandbox | Tool descriptor/file containment 已稳定；shell-v1 Gate open；非为拆而拆 |
| 契约 | **zag-types** | canonical + runtime ToolCapabilities/Descriptor 已落地；SDK compatibility Gate 仍未达 |

### 后续拆分排期

| 拆什么 | 从哪拆 | 时机 | 动机 |
|--------|--------|------|------|
| ~~**zag-types**~~ | ~~`zag-ai/types`~~ | ✅ 已完成 | core 仅依赖 zag-types；`ChatError` 中性 |
| zag-tools | `zag-coding-agent/src/runtime/*` + toolset | SDK Gate 后且有第二消费边界 | 不是 H2 完成的自动动作 |
| zag-workspace | core workspace/shell policy | containment contract 稳定且 C7 需要独立演进时 | sandbox runner 不强制与 lexical policy 同包 |
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
| Zig SDK-ready | supported high-level injection + ownership/error/event/cancel/session compatibility | ❌ Gate open |
| Process SDK/headless | versioned JSON/events + stable errors/exit codes | ❌ Gate open |

### SDK-ready Gate

All conditions are required:

1. Phase H correctness passes; no fail-open custom Tool or unsafe session semantics.
2. `Tool` supports instance state and mandatory runtime capabilities.
3. Supported high-level composition accepts caller Toolset, Observer, and policy without product-private fields.
4. Ownership/lifetime, typed errors, cancellation/deadline, events, and session semantics are documented and tested.
5. A repository-owned external consumer builds/runs in CI without private monorepo imports.
6. Package tests are self-contained.

Only after the Gate may a stability table assign semver promises. Repo mirror additionally needs a second real consumer and release channel.

Target usage is intentionally illustrative until the Gate lands:

```zig
// Target shape; this is not the current Agent.Options API.
var agent = zag.Agent.init(gpa, io, provider, .{
    .toolset = my_tools,
    .observer = my_observer,
    .permission_policy = my_policy,
});
```

Cross-language hosts use the later process/headless contract. No stable C ABI, Zig dynamic ABI, or in-process dynamic plugin ABI is promised.

---

## 5. 与路线图的关系

- **Phase H**：保持当前 package layout；session、Tool descriptor、containment、trace、context、redact、provider control 已落地；synchronous shell-v1/observability review-fix package evidence 已落地但 `h-shell-001` re-review/main Gate 尚未完成，之后仍需最终 audit。
- **SDK-ready Gate**：完成 public composition 和 external consumer；不由 Phase H 或 package count 自动获得。
- **Headless Gate**：提供 process contract，早于 TUI/ACP polish。
- **C track**：新能力先声明 package boundary 与 failure contract；不把 business logic 长进 cli/main。
- Split decisions use dependency/consumer pressure, not phase completion as an automatic trigger.

## 6. 刻意不做

- 在 H/P0-P1 correctness 未闭合时继续碎拆；
- 在 SDK Gate 前承诺 semver public API、C ABI 或 dynamic plugin ABI；
- 双向同步的 multi-repo development flow；
- 为对齐 Grok Build 而复刻其 crate 粒度；只有真实 ownership/dependency pressure 才拆包。

## 相关

- [architecture.md](./architecture.md) — 分层图（与本文件一致）
- [vision.md](./vision.md) — 双轨定位
- [roadmap.md](./roadmap.md) — 阶段推进
