# Modules — 规格索引

每页模板：不变式 · API/事件 · 失败模式 · L2/L3 验收 · 对标 · 非目标。

## 代码映射表

规格页 ↔ 现状路径。实现 PR 若搬家，**先改本表**再改 maturity 证据列。

| 规格 | 阶段 | 现状路径 | 目标拆分（可选） |
|------|------|----------|------------------|
| [core-boundary.md](./core-boundary.md) | D-011 done | thin Core + coding-agent product facade | Core owns Loop/contracts; coding-agent owns product policy/state/lifecycle adapter |
| [loop-turn.md](./loop-turn.md) | H1 | `packages/zag-agent-core/src/loop.zig` | required kernel seams complete; bounded steering v1 closed at `a5ff2b7`; parallel read-only Tools remain L3 |
| [tool-runtime.md](./tool-runtime.md) | H/P0 **L2** → SDK | `zag-types` ToolDefinition + ToolCapabilities；Core `tool.zig` | keep generic registry/validation in Core |
| [tools-edit.md](./tools-edit.md) | H2 **L2** → C4 first-slice **done** @ `7be5151` ([edit-sharpness-001](../plan/tasks/edit-sharpness-001.md); Tools write/edit L2) | `zag-coding-agent/src/runtime/*`、`toolset.zig` | 保持在 coding-agent；无 Core edit ports |
| [edit-transaction.md](./edit-transaction.md) | C4 second slice **done** @ `e086df8` ([edit-transaction-001](../plan/tasks/edit-transaction-001.md); D-012 item 1) | `zag-coding-agent` `runtime/edit_tools.zig` | 多文件 all-or-nothing；不碰 Core/TUI；Tools · write/edit stays L2 |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | coding-agent `runtime/edit_tools.zig` + `shell_policy.zig` | future process supervisor: [process-supervisor.md](./process-supervisor.md) |
| [process-supervisor.md](./process-supervisor.md) | D-012 item 3 **landed** (Wave 1b; dual review open; [process-supervisor-001](../plan/tasks/process-supervisor-001.md) still `draft`) | `zag-coding-agent` `runtime/process_supervisor.zig`; `run_shell` via `runForeground` | no Core ports; no OS sandbox; no maturity raise |
| [rpc-v1.md](./rpc-v1.md) | D-012 item 4 **implemented** @ `0eeef5d` ([rpc-v1-001](../plan/tasks/rpc-v1-001.md); closeout pending) | `zag-cli` `--rpc` + `rpc/` | no Core/coding-agent ports; does not extend `headless-v1` |
| [acp.md](./acp.md) | D-012 item 4b **implemented** @ `8d2ba64` ([acp-001](../plan/tasks/acp-001.md); closeout pending) | `zag-cli` `--acp` | editor JSON-RPC; sibling of rpc-v1; no Core changes |
| [lsp.md](./lsp.md) | D-012 item 2 **implemented** @ `75f213b` ([lsp-001](../plan/tasks/lsp-001.md); closeout pending) | `zag-coding-agent` `runtime/code_intel_tool.zig` + `runtime/lsp/` | owns spawn until supervisor long-lived slots; no Core LSP types |
| [permissions.md](./permissions.md) | H3 **L2** | `zag-coding-agent/src/permissions.zig` | concrete product policy stays in coding-agent; required Core seam |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | Core `protocol_history.zig`/`context_view.zig` + coding-agent `context.zig` | ownership split complete; future repo-map work separate |
| [session-item.md](./session-item.md) | M3 ✅ `31523b6` | Core `session_item.zig` + additive message fields | reasoning/synthetic/prompt-index and view-only repair/token trim; no maturity raise |
| [chat-state-prune.md](./chat-state-prune.md) | M3 ✅ `31523b6` | Core `session_item.zig` + coding-agent context composition | carrier-scoped dedup and prompt-index rewind API; no maturity raise |
| [compaction-llm.md](./compaction-llm.md) | M3 ✅ `31523b6` | Core summary helpers + coding-agent provider seam | optional LLM checkpoint summary with heuristic fallback; no maturity raise |
| [session-store.md](./session-store.md) | H4 → C5 | `packages/zag-coding-agent/src/session_store.zig` | durable store stays coding-agent; Transcript stays Core; fork contract in [session-fork](./session-fork.md) |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | coding-agent `workspace.zig`/`shell_policy.zig`/`redact.zig` | future C7 OS sandbox remains separate |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 | `zag-ai` + coding `wire_provider` | core 仅纯 Provider |
| [trace-observability.md](./trace-observability.md) | H7 | `packages/zag-coding-agent/src/{trace,redact,observer}.zig`；Core emits source facts via `LoopEventSink` | implementation moved to coding-agent by core-observation-ownership-001 |
| [cli-interaction.md](./cli-interaction.md) | Product CLI → M0 ✅; errno ✅ `bc737025`; fuses ✅ `97f43de`; process-idle + M0 dual-backend Gate ✅ tip `8a93ec6`/run `30273762011` (exact only); [post-TUI remote Gate](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) **in-progress** Phase A (TARGET `f352b60`; Class C rebind review PASS @ `7f9cfa4`; no Phase B grant / run / Gate green); templates ✅ `61326ae` | `zag-cli` signal UX + cancel flag; [quality/README](../quality/README.md) | signal UX product-layer; CI timeout ≠ product proof; post-TUI Gate separate |
| [harness-events.md](./harness-events.md) | M1 events ✅ | coding-agent SDK adapter over Core Loop facts + facade run facts; closed at `aecf402` | no Core `lifecycle.zig`; steering and fork closed separately |
| [harness-steering.md](./harness-steering.md) | M1 steering ✅ | Session-owned bounded queues + explicit Core `ControlInput`; closed at `a5ff2b7` | no provider/Tool preemption; Trace/headless schemas unchanged; no maturity change |
| [session-fork.md](./session-fork.md) | M1 fork ✅ | idle-only durable `Session.fork`; closed at `0a3087f` | schema v1 unchanged; Session remains L2; no tree/journal claim |
| [skills.md](./skills.md) | M2 / C8 E1 ✅ | implemented (`skills-001` @ `caafef5`); coding-agent only | no Core/schema/Trace/headless change; Runtime Extensions remains L0 |
| [prompt-templates.md](./prompt-templates.md) | M2 / C8 E1 ✅ | implemented (`prompt-templates-001` @ `61326ae`); coding-agent only + thin CLI routing | no Core/schema/Trace/headless change; Runtime Extensions remains L0 |
| [tui-minimal.md](./tui-minimal.md) | M2 / C9 **done** @ `f8f7f55` (PASS @ `c7a8f3a`); post-TUI remote Gate Phase A **in-progress** (TARGET `f352b60`; Class C rebind review PASS @ `7f9cfa4`; no Phase B grant / run / Gate green; no remote `-Dtui`) | `packages/zag-tui` + CLI `-Dtui` wire; local macOS Gates; **no** maturity raise | unique package; dual-thread host; `-Dtui` default false |
| [tui-streaming.md](./tui-streaming.md) | C9 follow-on ✅ `2d57e84` | Provider stream → Loop/Façade events → progressive TUI card | default streaming transport; headless/session/Trace wire unchanged |
| [tui-layout.md](./tui-layout.md) | C9 follow-on ✅ `189de9e` | `zag-tui` layout + presenter | pure geometry and dirty-flag paint; no cell diff/virtualization |
| [tui-vaxis.md](./tui-vaxis.md) | C9 backend ✅ `76360ab` | quarantined vaxis in `zag-tui` | no vxfw wholesale |
| [theme.md](./theme.md) | M2 / C9 Theme ✅ canvas @ `f5e1356` ([theme-001](../plan/tasks/theme-001.md) **done**) | `theme.zig` + role→Style | owner `zag-tui` only; fail-closed built-in; contract PASS @ `9e1b9f9` was the freeze, not “no code” |
| [tui-slash-host.md](./tui-slash-host.md) | C9 canvas ✅ | overlay + slash palette | reuse skill/template expand; no Core slash |
| [tui-transcript.md](./tui-transcript.md) | C9 canvas ✅ | scroll transcript region | keep streaming deltas; PTY markers |
| [memory.md](./memory.md) | **C5 deferred** | —（未实现） | 无真实 use case 前不建挂载点 |
| [subagents-oracle.md](./subagents-oracle.md) | C6 in-process slice @ `1dabd25`; Oracle/Graph still L0 | `zag-coding-agent/src/subagent.zig` + `task` tool | process-backed / Oracle / Graph remain deferred |
| [extensions.md](./extensions.md) | C8 / D-010 | E0 static SDK exists; E1 Skills @ `caafef5`; E1 Prompt Templates @ `61326ae`; E2/E3 unimplemented; Runtime Extensions L0 | feature surface is orthogonal to carriers; no new Zig build package until ownership exists; WASM engine quarantined from Kernel |

### 包边界速查

| 包 | 公开面（给上游用） | 内部 |
|----|-------------------|------|
| `openai-zig` | `Client`、resources、transport | generated OpenAPI |
| `zag-ai` | `resolve`、`WireAdapter`、`ChatOptions`、catalog | openai_compat |
| `zag-types` | Message / ToolDefinition / ToolRisk / ToolCapabilities / ToolDescriptor / ChatError | — |
| `zag-agent-core` | `loop`、Transcript、纯 Provider/Tool/Cancel ports、protocol history、required policy/context/event seams | 无 durable session/Trace/redaction/Observer、无 concrete product policy/Tools、无 zag-ai |
| `zag-coding-agent` | Agent/Session、policy/context/persistence/observation、Trace/redaction/Observer/LifecycleObserver、WireProvider、toolset/runtime tools、durable session store | 组装 core + wire |
| `zag-cli` | flags / REPL / one-shot/headless / signal + terminal ownership | 产品壳 |
| `src/main` | 进程入口 → `zag_cli.run` | 薄 |

依赖单向：

```text
# consumer → dependency
main → zag-cli → coding-agent → agent-core → zag-types
                         └────→ zag-ai ─┬→ zag-types
                                       └→ openai-zig
```

详见 [architecture.md](../architecture.md#monorepo-包边界强制)。

---

## 模块列表

| 模块 | 阶段 | 说明 |
|------|------|------|
| [core-boundary.md](./core-boundary.md) | D-011 | thin Core ownership and serialized migration contract |
| [loop-turn.md](./loop-turn.md) | H1 | harness 主循环 |
| [tool-runtime.md](./tool-runtime.md) | H/P0 → SDK | model definition / runtime capabilities / stateful handler |
| [tools-edit.md](./tools-edit.md) | H2 **L2** → C4 first-slice done @ `7be5151` | 编辑 / grep / glob；`apply_hunk` C4 first slice shipped (Tools write/edit L2) |
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | shell 执行 |
| [permissions.md](./permissions.md) | H3 | 权限矩阵 / plan 语义 |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | 四层 prompt / 压缩 |
| [session-item.md](./session-item.md) | M3 ✅ `31523b6` | reasoning/synthetic/prompt-index + repair/token trim |
| [chat-state-prune.md](./chat-state-prune.md) | M3 ✅ `31523b6` | tool-result dedup + prompt-index rewind |
| [compaction-llm.md](./compaction-llm.md) | M3 ✅ `31523b6` | optional LLM checkpoint compaction |
| [session-store.md](./session-store.md) | H4 → C5 | 会话落盘 / schema |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | jail / policy / redact |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 + WireAdapter | OpenAI-compatible + Anthropic；deadline/cancel contract |
| [trace-observability.md](./trace-observability.md) | H7 | 审计 trace |
| [sdk-contract.md](./sdk-contract.md) | SDK-ready | Public Zig source-composition contract（status: closed at `ebdd7ab`） |
| [headless-contract.md](./headless-contract.md) | Headless Gate **L2** | Public JSON/NDJSON process contract + exit matrix; closed at `a1a1e0f` |
| [cli-interaction.md](./cli-interaction.md) | Product CLI → M0 ✅; errno/fuses/idle/M0 Gate done; post-TUI remote Gate Phase A **in-progress** | REPL/one-shot + Ctrl+C + raw Linux errno; M0 Gate exact tip/run only; post-TUI Gate separate |
| [harness-events.md](./harness-events.md) | M1 events ✅ | product SDK lifecycle adapter closed at `aecf402`; no Core lifecycle channel |
| [harness-steering.md](./harness-steering.md) | M1 steering ✅ | Session control queues + protocol-safe Core insertion seam; closed at `a5ff2b7` |
| [session-fork.md](./session-fork.md) | M1 fork ✅ | Idle-only durable `Session.fork`; closed at `0a3087f`; schema v1 and Session L2 unchanged |
| [skills.md](./skills.md) | M2 / C8 E1 ✅ | Passive Agent Skills binding contract (`skills-001` done @ `caafef5`); coding-agent only |
| [prompt-templates.md](./prompt-templates.md) | M2 / C8 E1 ✅ | Passive Prompt Templates binding contract (`prompt-templates-001` done @ `61326ae`); coding-agent only + thin CLI routing |
| [tui-minimal.md](./tui-minimal.md) | M2 / C9 **done** @ `f8f7f55`; post-TUI remote Gate Phase A **in-progress** | Minimal host TUI + `zag-tui`; no maturity raise; no remote `-Dtui` claim |
| [tui-streaming.md](./tui-streaming.md) | C9 follow-on ✅ `2d57e84` | progressive assistant streaming; default transport |
| [tui-layout.md](./tui-layout.md) | C9 follow-on ✅ `189de9e` | pure layout + dirty-flag presenter |
| [theme.md](./theme.md) | M2 / C9 Theme **done** (canvas; contract PASS @ `9e1b9f9`) | Host-shell Theme; implementation in `zag-tui`; no maturity raise |
| [memory.md](./memory.md) | C5 deferred | Memory Repo（跨 session；default-off; no current trigger） |
| [rpc-v1.md](./rpc-v1.md) | C9 **implemented** @ `0eeef5d` (closeout pending) | `--rpc` NDJSON; does not modify `headless-v1` |
| [acp.md](./acp.md) | C9 **implemented** @ `8d2ba64` (closeout pending) | `--acp` editor JSON-RPC adapter |
| [lsp.md](./lsp.md) | C4/C5 **implemented** @ `75f213b` (closeout pending) | `code_intel` tool + hand-rolled LSP client |
| [subagents-oracle.md](./subagents-oracle.md) | C6 in-process slice landed; Oracle/Graph stub | `task`/`scout`/`reviewer`; no process isolation; row stays L0 |
| [extensions.md](./extensions.md) | C8 / D-010 | Pi feature surface × E0 static / E1 passive / E2 process / E3 WASM; package/model/Provider/RPC/UI boundaries |
| [zag-live.md](./zag-live.md) | D-014 Route A **implemented** @ zag-live-001 **done** (2026-08-14; 23/23; review pass) | `packages/zag-live/`; supervised live Scheme image; L2 domain service, `zag-types` only, host ports; no maturity claim |

总览：[../maturity.md](../maturity.md) · [../phases/H-harden.md](../phases/H-harden.md) · [../phases/C5-context.md](../phases/C5-context.md)  
