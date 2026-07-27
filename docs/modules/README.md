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
| [tools-shell.md](./tools-shell.md) | H2/H5 → L3 | coding-agent `runtime/edit_tools.zig` + `shell_policy.zig` | future process supervisor remains separate |
| [permissions.md](./permissions.md) | H3 **L2** | `zag-coding-agent/src/permissions.zig` | concrete product policy stays in coding-agent; required Core seam |
| [context-compaction.md](./context-compaction.md) | H4 → C5 | Core `protocol_history.zig`/`context_view.zig` + coding-agent `context.zig` | ownership split complete; future repo-map work separate |
| [session-store.md](./session-store.md) | H4 → C5 | `packages/zag-coding-agent/src/session_store.zig` | durable store stays coding-agent; Transcript stays Core; fork contract in [session-fork](./session-fork.md) |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | coding-agent `workspace.zig`/`shell_policy.zig`/`redact.zig` | future C7 OS sandbox remains separate |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 | `zag-ai` + coding `wire_provider` | core 仅纯 Provider |
| [trace-observability.md](./trace-observability.md) | H7 | `packages/zag-coding-agent/src/{trace,redact,observer}.zig`；Core emits source facts via `LoopEventSink` | implementation moved to coding-agent by core-observation-ownership-001 |
| [cli-interaction.md](./cli-interaction.md) | Product CLI → M0 ✅; errno hotfix ✅ `bc737025` (`ci-hang-sigint-linux-errno-001`); [CI fuses](../plan/tasks/ci-hang-ci-fuses-001.md) ✅ done/closed @ `97f43de` host rails only; [process-idle](../plan/tasks/ci-hang-sigint-process-idle-001.md) ✅ done Phase B @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) (Ubuntu std **611/611**+fixture **2/2**, curl **610/610**+**2/2**; no product change); [linux dual-backend Gate](../plan/tasks/linux-dual-backend-gate-001.md) ✅ done @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) (exact tip/run only; not universal); E1 Prompt Templates thin CLI routing ✅ `61326ae` | `packages/zag-cli/src/{cli,sigint}.zig` + core cancel flag; CI fuses: [quality/README](../quality/README.md) + `.github/workflows/ci.yml` | 保持 signal UX 在产品层；raw Linux errno 不得走 libc `posix.errno`；CI timeout ≠ product proof；idle residual + dual-backend Gate PASS at exact tip/run only；`prompt-templates-001` done @ `61326ae` (thin CLI routing; Runtime Extensions L0) |
| [harness-events.md](./harness-events.md) | M1 events ✅ | coding-agent SDK adapter over Core Loop facts + facade run facts; closed at `aecf402` | no Core `lifecycle.zig`; steering and fork closed separately |
| [harness-steering.md](./harness-steering.md) | M1 steering ✅ | Session-owned bounded queues + explicit Core `ControlInput`; closed at `a5ff2b7` | no provider/Tool preemption; Trace/headless schemas unchanged; no maturity change |
| [session-fork.md](./session-fork.md) | M1 fork ✅ | idle-only durable `Session.fork`; closed at `0a3087f` | schema v1 unchanged; Session remains L2; no tree/journal claim |
| [skills.md](./skills.md) | M2 / C8 E1 ✅ | implemented (`skills-001` @ `caafef5`); coding-agent only | no Core/schema/Trace/headless change; Runtime Extensions remains L0 |
| [prompt-templates.md](./prompt-templates.md) | M2 / C8 E1 ✅ | implemented (`prompt-templates-001` @ `61326ae`); coding-agent only + thin CLI routing | no Core/schema/Trace/headless change; Runtime Extensions remains L0 |
| [tui-minimal.md](./tui-minimal.md) | M2 / C9 **contract PASS** @ `c7a8f3a`; **impl candidate** | `packages/zag-tui` + CLI `-Dtui` wire (`tui-minimal-001`); awaiting independent review + coordinator Gates; **no** maturity raise | unique `packages/zag-tui`; dual-thread host; redactAlloc; `-Dtui` default false |
| [memory.md](./memory.md) | **C5 deferred** | —（未实现） | 无真实 use case 前不建挂载点 |
| [subagents-oracle.md](./subagents-oracle.md) | C6 | — | agent 内 |
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
| [session-store.md](./session-store.md) | H4 → C5 | 会话落盘 / schema |
| [workspace-sandbox.md](./workspace-sandbox.md) | H5 → C7 | jail / policy / redact |
| [zag-ai-provider.md](./zag-ai-provider.md) | H6 + WireAdapter | OpenAI-compatible + Anthropic；deadline/cancel contract |
| [trace-observability.md](./trace-observability.md) | H7 | 审计 trace |
| [sdk-contract.md](./sdk-contract.md) | SDK-ready | Public Zig source-composition contract（status: closed at `ebdd7ab`） |
| [headless-contract.md](./headless-contract.md) | Headless Gate **L2** | Public JSON/NDJSON process contract + exit matrix; closed at `a1a1e0f` |
| [cli-interaction.md](./cli-interaction.md) | Product CLI → M0 ✅; `ci-hang-sigint-linux-errno-001` ✅ `bc737025`; [CI fuses](../plan/tasks/ci-hang-ci-fuses-001.md) ✅ done/closed @ `97f43de` host rails only; [process-idle](../plan/tasks/ci-hang-sigint-process-idle-001.md) ✅ done Phase B @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011); [linux dual-backend Gate](../plan/tasks/linux-dual-backend-gate-001.md) ✅ done @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) (exact tip/run only) | REPL/one-shot input ownership, Ctrl+C lifecycle, raw Linux errno decode under `link_libc`; host CI fuses closed; process-idle residual + dual-backend Gate PASS at exact tip/run (not universal); `prompt-templates-001` done @ `61326ae` (thin CLI routing; Runtime Extensions L0) |
| [harness-events.md](./harness-events.md) | M1 events ✅ | product SDK lifecycle adapter closed at `aecf402`; no Core lifecycle channel |
| [harness-steering.md](./harness-steering.md) | M1 steering ✅ | Session control queues + protocol-safe Core insertion seam; closed at `a5ff2b7` |
| [session-fork.md](./session-fork.md) | M1 fork ✅ | Idle-only durable `Session.fork`; closed at `0a3087f`; schema v1 and Session L2 unchanged |
| [skills.md](./skills.md) | M2 / C8 E1 ✅ | Passive Agent Skills binding contract (`skills-001` done @ `caafef5`); coding-agent only |
| [prompt-templates.md](./prompt-templates.md) | M2 / C8 E1 ✅ | Passive Prompt Templates binding contract (`prompt-templates-001` done @ `61326ae`); coding-agent only + thin CLI routing |
| [tui-minimal.md](./tui-minimal.md) | M2 / C9 contract PASS @ `c7a8f3a`; impl candidate | Minimal host TUI binding + package candidate (`tui-minimal-001`; awaiting independent review) |
| [memory.md](./memory.md) | C5 deferred | Memory Repo（跨 session；default-off; no current trigger） |
| [subagents-oracle.md](./subagents-oracle.md) | C6 stub | 子代理 / Oracle |
| [extensions.md](./extensions.md) | C8 / D-010 | Pi feature surface × E0 static / E1 passive / E2 process / E3 WASM; package/model/Provider/RPC/UI boundaries |

总览：[../maturity.md](../maturity.md) · [../phases/H-harden.md](../phases/H-harden.md) · [../phases/C5-context.md](../phases/C5-context.md)  
