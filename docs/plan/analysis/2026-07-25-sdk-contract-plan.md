---
date: 2026-07-25
task: sdk-contract-001
phase: H L2 closeout → SDK-ready Gate
status: analysis only (no code changes)
---

# `sdk-contract-001` 实施交付分析

> 本文档是 `sdk-contract-001` 的 docs-first 规格核对，不是实现。
> 工作目录：`main` @ `d6ea6ca`（Phase H 已 L2 收口）。
> 结论：SDK-ready Gate **尚未闭合**；需要先做一次小的 public-surface 收口（`Agent.Options` 注入能力 + root re-export），再写仓库内 external-consumer fixture，并同步更新 packaging/architecture/maturity 文档。

---

## 摘要

| 维度 | 结论 |
|------|------|
| L0 契约 (`zag-types`) | 已可独立 import，public root 干净，无可注入私有路径。 |
| L4 Kernel (`zag-agent-core`) | 已可独立 import，仅依赖 `zag-types`；low-level composition（Provider/Toolset/Observer/loop）已工作。 |
| L3 产品 harness (`zag-coding-agent`) | 包已拆出，但 `Agent.Options` **缺少** 自定义 `Toolset` 与 `Observer` 注入字段；默认 toolset 是写死的 `Phase1Storage`。这是当前最大 gap。 |
| 外部 consumer fixture | 应建在仓库内独立 package（推荐 `tests/sdk-consumer-fixture/` 或 `packages/sdk-consumer-fixture/`），通过 path dependency 引用 `zag-coding-agent`（或 `zag-agent-core`），并在根 `build.zig` 的 `test` step 中挂接。 |
| 文档化合同 | ownership/lifetime/error/event/cancel/session 的语义已在 `D-006/D-007/D-008` 与模块文档中沉淀，但尚未汇总为一份面向 SDK 消费者的“public contract”文档。 |
| 不做范围 | C ABI、动态插件 ABI、semver 发布、headless process contract 均明确不进入本任务。 |

---

## 1. 当前外部 consumer 真实可 import 的边界

### 1.1 包 / 模块名称

| 包名（`build.zig.zon` `.name`） | Zig module 名 | public root 文件 | 当前依赖 |
|---|---|---|---|
| `.zag_types` | `zag-types` | `packages/zag-types/src/root.zig` | std only |
| `.zag_agent_core` | `zag-agent-core` | `packages/zag-agent-core/src/root.zig` | `zag-types` only |
| `.zag_coding_agent` | `zag-coding-agent` | `packages/zag-coding-agent/src/root.zig` | `zag-agent-core` + `zag-ai`（后者再拉 `openai-zig`、`comptime-serde`、可选 `curl`） |
| `.zag`（root） | `zag` | `src/root.zig` | umbrella re-export，不用于 SDK consumer |

外部 consumer 在自家 `build.zig.zon` 里写 `.path = "../zag-types"` 之类的 path dependency 后，代码中应只使用模块名 import：

```zig
const zt = @import("zag-types");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");
```

### 1.2 各 public root 实际公开的声明

**`zag-types`**（`packages/zag-types/src/root.zig`）

已完整公开 L0 契约：

```startLine:9:499:packages/zag-types/src/root.zig
pub const ChatError = error{ ... };
pub const CancelFlag = struct { ... };
pub const RequestControl = struct { ... };
pub const Message = struct { ... };
pub const ToolDefinition = struct { ... };
pub const ToolCapabilities = struct { ... };
pub const ToolDescriptor = struct { ... };
pub const AssistantTurn = struct { ... };
pub const StreamEvent = union(enum) { ... };
pub const ChatOptions = struct { ... };
...
```

所有声明都在 root 层，`@import("zag-types")` 即可拿到。

**`zag-agent-core`**（`packages/zag-agent-core/src/root.zig`）

```startLine:1:40:packages/zag-agent-core/src/root.zig
pub const message = @import("message.zig");
pub const tool = @import("tool.zig");
pub const transcript = @import("transcript.zig");
pub const provider = @import("provider.zig");
pub const observer = @import("observer.zig");
pub const permissions = @import("permissions.zig");
pub const context = @import("context.zig");
pub const session_store = @import("session_store.zig");
pub const shell_policy = @import("shell_policy.zig");
pub const workspace = @import("workspace.zig");
pub const tool_error = @import("tool_error.zig");
pub const cancel = @import("cancel.zig");
pub const redact = @import("redact.zig");
pub const trace = @import("trace.zig");
pub const loop = @import("loop.zig");

pub const Message = message.Message;
pub const Role = message.Role;
pub const ToolCall = message.ToolCall;
pub const AssistantTurn = message.AssistantTurn;
pub const Provider = provider.Provider;
pub const ChatError = provider.ChatError;
pub const Tool = tool.Tool;
pub const ToolDefinition = tool.Definition;
pub const ToolDescriptor = tool.ToolDescriptor;
pub const ToolCapabilities = tool.ToolCapabilities;
pub const ToolRisk = tool.ToolRisk;
pub const Registration = tool.Registration;
pub const RegistrationError = tool.RegistrationError;
```

注意：`tool.Toolset`、`tool.Registry`、`observer.Observer`、`permissions.Gate`、`permissions.Mode`、`session_store.Writer`、`loop.Result` 等关键类型**没有**顶层 re-export，但可以通过子模块访问（如 `core.tool.Toolset`、`core.observer.Observer`）。这对外部 consumer 仍属合法 public surface。

**`zag-coding-agent`**（`packages/zag-coding-agent/src/root.zig`）

```startLine:1:49:packages/zag-coding-agent/src/root.zig
pub const agent_core = core;

pub const message = core.message;
pub const tool = core.tool;
pub const transcript = core.transcript;
pub const provider = core.provider;
pub const observer = core.observer;
pub const permissions = core.permissions;
pub const context = core.context;
pub const session_store = @import("session_store.zig");
pub const shell_policy = core.shell_policy;
pub const workspace = core.workspace;
pub const redact = core.redact;
pub const trace = core.trace;
pub const loop = core.loop;

pub const agent = @import("agent.zig");
pub const toolset = @import("toolset.zig");
pub const project = @import("project.zig");
pub const doctor = @import("doctor.zig");
pub const wire_provider = @import("wire_provider.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");
pub const edit_tools = @import("runtime/edit_tools.zig");
pub const golden_tests = @import("golden_tests.zig");

pub const WireProvider = wire_provider.WireProvider;
pub const Adapter = wire_provider.Adapter;

pub const Agent = agent.Agent;
pub const Session = agent.Session;
pub const Options = agent.Options;
pub const OpenMode = agent.OpenMode;
```

因此 consumer 可以合法访问：
- `coding.Agent`、`coding.Session`、`coding.Options`、`coding.OpenMode`
- `coding.tool.Tool`、`coding.tool.Toolset`、`coding.tool.buildTool`
- `coding.provider.Provider`
- `coding.observer.Observer`、`coding.observer.Event`
- `coding.permissions.Gate`、`coding.permissions.Mode`
- `coding.session_store.openOrCreateWithRedactor` 等

### 1.3 必须先清掉的“私有路径 / 内部文件”引用

1. **Source-level 目前不存在非法引用**：三个包的 public root 都没有 `@import("./private/...")` 或 `@import("../zag-agent-core/src/...")` 之类的跨包私有路径。`
2. **Build-time 的私有路径是允许的 monorepo path dependency**：`packages/zag-coding-agent/build.zig.zon` 里写的是 `path = "../zag-agent-core"`、`path = "../zag-ai"`。这是 Zig package manager 在 monorepo 内消费 sibling 包的标准方式，不等于 consumer 代码引用私有文件。但外部 consumer 的 fixture 应该使用**自己 manifest 里的 path**，而不是依赖 monorepo 内部相对路径来偷渡 internal 文件。
3. **真正需要收口的是 `zag-coding-agent.Agent.Options` 的字段完备性**：当前 consumer 为了“注入自定义 toolset/observer”，没有 public 字段可用，只能去 import `zag-coding-agent/src/agent.zig` 内部的 `tools_storage` 或写死 `toolset.Phase1Storage`，这会把 consumer 逼向内部文件。解决方式是在 `Options` 里加两个字段并修改 `effectiveToolset` / `deps`。

---

## 2. 任务书 6 条 verification 逐条分析

### V1. 外部 package 可 import 支持的模块，且不引用私有 monorepo 路径

**现状差距**

- `zag-types`、`zag-agent-core` 已满足。
- `zag-coding-agent` 的 public root 已暴露足够模块；但 consumer 若要完整实现“自定义 toolset + observer”的高阶组合，**没有 public 字段可注入**，会自然滑向内部类型。

**需要的代码/文档变更**

- 文档：在 `docs/packaging.md#SDK-ready Gate` 中明确列出“支持的 import 模块名”与“禁止的 import 模式”。
- 代码：在 `zag-coding-agent/src/agent.zig` 的 `Options` 中新增：
  - `toolset: ?[]const core.tool.Tool = null`（或 `?core.tool.Toolset`）
  - `observer: ?core.observer.Observer = null`
- 代码：修改 `effectiveToolset()`（`packages/zag-coding-agent/src/agent.zig:468-477`）和 `deps()`（`packages/zag-coding-agent/src/agent.zig:478-506`），当 `options.toolset` 非空时使用用户 toolset，否则使用默认 `Phase1Storage`；当 `options.observer` 非空时，先/后调用用户 observer，再保留 Agent 内部的 usage/cost/verbose 处理。
- 代码：在 `zag-coding-agent/src/root.zig` 顶层增加 `pub const Toolset = tool.Toolset;`、`pub const Observer = observer.Observer;` 等便利 re-export，减少 consumer 必须深入子模块的频率。

**建议的 external consumer fixture 形态**

```text
tests/sdk-consumer-fixture/
  build.zig
  build.zig.zon
  src/
    root.zig          # 测试入口
    mock_provider.zig # 状态化 mock provider
    custom_tool.zig   # 状态化 custom tool
```

`build.zig.zon` 只依赖需要的包（示例是高级 fixture；若只做 low-level 可去掉 `zag-coding-agent`）：

```zig
.dependencies = .{
    .zag_types = .{ .path = "../../packages/zag-types" },
    .zag_agent_core = .{ .path = "../../packages/zag-agent-core" },
    .zag_coding_agent = .{ .path = "../../packages/zag-coding-agent" },
},
```

Consumer 代码示例（变更后）：

```zig
const std = @import("std");
const zt = @import("zag-types");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");

var counter_state: u32 = 0;
fn counterHandler(ctx: core.tool.Context, instance: ?*anyopaque, args: []const u8) ![]u8 {
    const state: *u32 = @ptrCast(@alignCast(instance.?));
    state.* += 1;
    return std.fmt.allocPrint(ctx.allocator, "{d}", .{state.*});
}

const my_tool = try core.tool.buildTool(gpa, .{
    .definition = .{ .name = "counter", .description = "inc", .parameters_json = "{\"type\":\"object\"}" },
    .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
    .instance = &counter_state,
    .handler = counterHandler,
});

var agent = try coding.Agent.init(gpa, io, my_provider, .{
    .permission_mode = .yolo,
    .toolset = &[_]core.tool.Tool{my_tool},   // 新增字段
    .observer = my_observer,                  // 新增字段
});
```

### V2. 高阶组合可注入有状态的自定义 Toolset、Provider、Observer 和 policy

**现状差距**

| 注入点 | 当前状态 | 缺口 |
|---|---|---|
| Provider | `Agent.init(gpa, io, provider, .{})` 已支持 | 无 |
| Policy | `Options.permission_mode` / `permission_gate` 已支持 | 无 |
| Toolset | 硬编码 `Phase1Storage` | **缺 public 注入字段** |
| Observer | 固定使用内部 `onAgentEvent` | **缺 public 注入字段** |

`Phase1Storage` 写死 7 个内置 tool：

```startLine:16:46:packages/zag-coding-agent/src/toolset.zig
pub const Phase1Storage = struct {
    tools: [7]tool.Tool,

    pub fn init() Phase1Storage {
        const ro = fs_tools.phase0Tools();
        const search = fs_tools.searchTools();
        const rw = edit_tools.phase1ExtraTools();
        return .{
            .tools = .{
                ro[0], ro[1], search[0], search[1], rw[0], rw[1], rw[2],
            },
        };
    }
    ...
};
```

`effectiveToolset()` 无条件返回默认：

```startLine:468:477:packages/zag-coding-agent/src/agent.zig
fn effectiveToolset(self: *Agent) tool.Toolset {
    if (builtin.is_test) {
        if (self.test_tools) |override| return .{ .tools = override };
    }
    return self.tools_storage.toolset();
}
```

`deps()` 中 observer 也是写死的内部回调：

```startLine:478:506:packages/zag-coding-agent/src/agent.zig
fn deps(self: *Agent, session: *Session) loop.Deps {
    ...
    return .{
        ...
        .observer = .{
            .ptr = self,
            .on_event = onAgentEvent,
        },
        ...
    };
}
```

**需要的变更**

1. `packages/zag-coding-agent/src/agent.zig`：
   - `Options` 增加 `toolset: ?[]const core.tool.Tool = null`、`observer: ?core.observer.Observer = null`。
   - `Agent` 字段 `tools_storage` 改为 union 或保留默认 storage + 可选 custom slice。
   - `effectiveToolset()` 优先 `options.toolset`，再 `test_tools`，再默认。
   - `deps()` 构造 observer 时，若 `options.observer` 存在则包装成 chain：先调用用户 observer，再调用 `onAgentEvent` 内部逻辑；或把内部 cost/verbose 逻辑从 observer 中拆出，直接监听 `loop.Deps` 的 usage 事件。
2. `packages/zag-coding-agent/src/root.zig`：顶层 re-export `Toolset`、`Observer`。
3. `docs/architecture.md` 与 `docs/packaging.md`：把“高阶组合 API”写入 SDK-ready 门控条件。

**Fixture 形态**

Fixture 必须证明四件事都能由 consumer 注入：
- **Provider**：mock provider 返回 tool_calls，验证 consumer 代码能驱动 loop。
- **Toolset**：注入一个带 `instance` 指针的 custom tool，验证多次调用后状态递增。
- **Observer**：注入一个 Observer，记录事件序列，验证 `run_start` / `tool_call` / `tool_result` / `run_end` 等事件。
- **Policy**：注入 `permissions.Gate.ask(...)`，验证 ask/deny 路径。

示例 fixture 目录：

```text
tests/sdk-consumer-fixture/src/
  root.zig
  mock_provider.zig
  counting_tool.zig
  recording_observer.zig
  ask_policy.zig
```

### V3. 走一遍 cancellation 与 session persistence/error 路径

**现状差距**

Cancellation 与 session 的底层能力已经 L2 闭合：

- `core.cancel.Flag` / `zt.CancelFlag` 是 seq_cst 原子 flag（`packages/zag-agent-core/src/cancel.zig:10-50`）。
- `loop.run` 在 between-turn / between-tool 检查 cancel，pending tool calls 会回填 `code=cancelled`（`packages/zag-agent-core/src/loop.zig:280-290`）。
- `Session.start` 支持 `create_new` / `resume_existing` / `open_or_create`（`packages/zag-coding-agent/src/agent.zig:69-74`、`packages/zag-coding-agent/src/session_store.zig:250-340`；D-011 core-session-ownership-001 将 durable store 从 `zag-agent-core` 移至 `zag-coding-agent`）。
- `Agent.reply` 在成功路径先 `session.save()` 再 commit trace terminal（`packages/zag-coding-agent/src/agent.zig:680-710`）。

但 **high-level facade 没有给 consumer 暴露 cancel 的显式 API**，consumer 只能靠直接修改 `agent.cancel` 字段或自行安装 SIGINT。`agent.cancel` 字段虽是 public，但文档里应明确这是受支持的 public contract。

**需要的变更**

- 文档化：在 SDK contract 中写明 consumer 两种 cancel 方式：
  1. 设置 `Options.provider_timeout_ms` 得到 deadline `timeout`。
  2. 调用 `agent.cancel.request()`（或 `core.cancel.installSigInt(&agent.cancel)`）得到 clean `cancelled`。
- 代码：无需大改，但建议给 `Agent` 加一个显式 `requestCancel()` 方法，避免 consumer 依赖字段可见性。
- Fixture：写三个测试：
  1. **cancel after assistant tool_calls**：mock provider 返回 tool_calls 后 set flag，断言 `stop_reason == .cancelled`，且 transcript 中 pending tool results 都是 `code=cancelled`。
  2. **session create → save → resume**：创建 session，运行一次 reply，重新 `Session.start(.{ .open_mode = .resume_existing })`，验证 transcript 完整。
  3. **session error path**：用不可写路径（例如把 session 文件路径设成已存在的目录，或父路径是文件）触发 `IoFailed` → `session_error`，断言 prior bytes 不变。

### V4. ownership/lifetime 与 compatibility 规则已文档化

**现状差距**

规则散落于 `D-006/D-007/D-008` 与 `docs/modules/*.md` 中，尚未汇总为一份给 SDK consumer 的“public contract”。maturity 矩阵里 `Zig source composition` 还是 L1，明确 blocker 就是缺文档和 external consumer。

**需要的变更**

新增或更新 `docs/modules/sdk-contract.md`（或直接在 `docs/packaging.md#SDK-ready Gate` 扩展），把第 3 节的规则清单写进去。然后：
- `docs/maturity.md` 中 `Zig source composition` 一行更新证据。
- `docs/architecture.md` 的“可组合/SDK-ready”表格更新为“已闭合”。
- `docs/packaging.md#SDK-ready Gate` 增加“public contract 文档化”作为条件之一。

### V5. 本 gate 不宣称 C ABI、动态插件 ABI、semver 发布

**现状差距**

- `D-008` 已明确（`docs/decisions/active/D-008-sdk-and-process-boundaries.md:20-30`）。
- `docs/packaging.md` 第 4 节也已写明（`docs/packaging.md:130-180`）。

**需要的变更**

- 只需在 consumer fixture / SDK contract 文档的“Non-goals”段再钉一次，确保对外宣传口径一致。
- 无需代码变更。

### V6. 所有 package tests + external consumer 在 CI 中运行

**现状差距**

根 `build.zig` 的 `test` step 已经跑：openai、types、ai、core、coding、cli、root mod、doctor fixture、openai coverage、catalog check、docs lint（`build.zig:330-340`）。**缺少 sdk-consumer-fixture**。

**需要的变更**

1. 新增 `tests/sdk-consumer-fixture/build.zig` + `build.zig.zon`。
2. 根 `build.zig.zon` 增加 `.sdk_consumer_fixture = .{ .path = "tests/sdk-consumer-fixture" }`（lazy 可选）。
3. 根 `build.zig` 中新增 test artifact：

```zig
const fixture_dep = b.dependency("sdk_consumer_fixture", .{
    .target = target,
    .optimize = optimize,
    .http_backend = http_backend,
});
const fixture_tests = b.addTest(.{ .root_module = fixture_dep.module("sdk-consumer-fixture") });
const run_fixture_tests = b.addRunArtifact(fixture_tests);
test_step.dependOn(&run_fixture_tests.step);
```

4. 若 fixture 依赖 `zag-coding-agent`，需要把 `http_backend` option 传下去； fixture 的 `build.zig` 接受 `http_backend` option 并透传给 `zag-ai` / `zag-coding-agent`。

---

## 3. ownership / lifetime / error / event / cancel 合同规则（按现有语义整理）

以下规则全部来自现有代码/决策，不发明新行为。

### 3.1 所有权与生命周期

| 对象 | 所有者 | 借用规则 |
|---|---|---|
| `Tool` 及其 `descriptor` 字符串、`instance` 指针 | caller | 必须 outlive 所有 `Tool`/`Toolset` 副本及每一次 `handler` 调用。`Tool` 是 value-copy，不 deep clone。 |
| `Provider` 的 `ptr` + `vtable` | caller | 必须 outlive `Agent` / `loop.run`。每次 `chat` 调用会传入一个 scratch arena，provider 返回的 `AssistantTurn` 内容属于该 arena。 |
| `Observer` 回调接收的 `Event` 切片 | callback 内部 | 回调返回后失效；如需保留必须拷贝。 |
| `Session` | caller | `Session` 持有 transcript arena 与 writer lock。`Agent.reply(session, ...)` 要求 `session` 存活于整个 `reply` 调用期间。 |
| `Agent` | caller | `Agent` 持有 owned redactor、trace buffer、remember store。`deinit` 只释放内存，不会伪造 terminal。 |
| `Trace` 的 `path` | borrowed from `Agent.Options.trace_path` / caller | `Trace` 只保存指针；路径切片必须 outlive Trace。 |
| `CancelFlag` | caller / host | 必须 outlive 整个 run；provider 在 in-flight 请求中借用 `*CancelFlag`。 |
| `Redactor` | `Agent` 或 `Session` 拥有 | `clone` 产生独立副本；原始释放后 clone 仍可工作。不承诺 cryptographic zeroization。 |
| `RequestControl.deadline_mono_ns` | 值类型 | 构建后 immutable；deadline 是进程内单调时间，不能跨进程比较。 |

关键代码锚点：

```startLine:20:35:packages/zag-agent-core/src/tool.zig
//! - **Instance** (`?*anyopaque`): borrowed. The caller owns the pointed-to
//!   state; it must outlive every `handler` invocation for this `Tool`.
//! - **Descriptor strings** ... borrowed. They must remain valid for the lifetime of every
//!   copy of the `Tool` / `Toolset` ...
//! - **`Tool` is copyable** ... Copies share the same borrowed instance pointer ...
```

```startLine:37:49:packages/zag-agent-core/src/provider.zig
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub fn chat(...) ChatError!message.AssistantTurn { ... }
};
```

### 3.2 错误合同

**Loop / Facade 错误映射**（来源：`packages/zag-agent-core/src/loop.zig:70-120`、`packages/zag-coding-agent/src/agent.zig:630-640`）：

| 运行时错误 | `loop.run` 返回值 | `Agent.reply` 传播 | facade terminal `stop_reason` | `ok` |
|---|---|---|---|---|
| 正常完成 | `Result{ .stop_reason = .completed }` | `Result` | `completed` | true |
| max turns | `Result{ .stop_reason = .max_turns }` | `Result` | `max_turns` | true |
| clean cancel | `Result{ .stop_reason = .cancelled }` | `Result` | `cancelled` | true |
| deadline | `Result{ .stop_reason = .timeout }` | `Result` | `timeout` | false |
| unsupported control | `Result{ .stop_reason = .unsupported_control }` | `Result` | `unsupported_control` | false |
| provider/auth 失败 | `error.ProviderFailed` | `ReplyError` | `provider_error` | false |
| toolset 校验失败 | `error.InvalidToolset` | `ReplyError` | `invalid_toolset` | false |
| OOM | `error.OutOfMemory` | `ReplyError` | `out_of_memory` | false |
| mid-run trace 失败 | `error.TraceFailed` | `ReplyError` | `trace_error` | false |
| context 校验失败 | `error.InvalidContext` | `ReplyError` | `invalid_context` | false |
| session save 失败 | — | `session_store.Error` | `session_error` | false |
| trace persist 失败 | — | `trace.Error` | `trace_error` | false |

**永不重试**：`Timeout`、`Cancelled`、`NotSupported`、`UnsupportedControl`；loop 重试只针对 `RateLimited`、`ServerError`、`HttpFailed`（`packages/zag-types/src/root.zig:469-478`）。

### 3.3 事件合同

`Observer.Event`（`packages/zag-agent-core/src/observer.zig:10-25`）：

```startLine:10:25:packages/zag-agent-core/src/observer.zig
pub const Event = union(enum) {
    assistant_text: []const u8,
    usage: message.Usage,
    tool_call: message.ToolCall,
    tool_result: struct { name: []const u8, body: []const u8 },
    permission: struct { tool_name: []const u8, allowed: bool, remembered: bool = false, risk: ?[]const u8 = null },
};
```

`Trace` 事件 kind（schema v1）：

```startLine:67:100:packages/zag-agent-core/src/trace.zig
pub const EventKind = enum {
    run_start, turn, assistant, usage, tool_call,
    permission, jail_deny, shell_deny, tool_result,
    provider_retry, compaction, run_end,
};
```

**关键事件不变式**：
- 一次 started run 最终有且仅有一个 `run_end`。
- `run_end.ok` 由真实结果/错误决定；`deinit` 不伪造成功 terminal。
- trace 在写入 JSON **之前** 先经过 redactor；redaction OOM → `OutOfMemory`，不会回落到原始输出。
- session note-compaction 先于 trace compaction 事件；sink OOM 时不会写 trace compaction 行，防止 session 与 trace 元数据静默分叉。

### 3.4 Cancel / deadline 合同

```startLine:95:190:packages/zag-types/src/root.zig
pub const RequestControl = struct {
    deadline_mono_ns: ?u64 = null,
    cancel: ?*CancelFlag = null,
    require_active_cancel: bool = false,
    ...
    pub fn check(self: RequestControl, now_mono_ns: u64) error{ Cancelled, Timeout }!void { ... }
};
```

- `cancel` 指针在请求期间 borrowed；host 必须保证 flag 存活。
- 当 cancel 与 deadline 同时触发时，cancel 优先（`packages/zag-types/src/root.zig:165-170`）。
- curl backend 能执行 active cancel；std backend 在配置 deadline 时返回 `UnsupportedControl`（`docs/modules/loop-turn.md:50-60`）。
- 已 accepted 的 multi-tool turn 在 tool 之间触发 cancel 时，会把剩余 tool 结果回填 `code=cancelled`，保持 transcript resume-safe。
- **Tool handler 的 mid-flight preemption 明确不做**：`.cooperative` 只是元数据声明，实际 shell/process 抢占属于 post-H 工作。

### 3.5 Session 持久化合同

- `create_new`：目标文件已存在 → `SessionAlreadyExists`，不会覆盖。
- `resume_existing`：缺失/无效/不支持/被锁 → 各自 distinct error，不会回退成新建 session。
- `open_or_create`：只在 `SessionNotFound` 时创建，其他错误原样传播。
- 保存：先写临时文件，再 atomic replace；失败保留原文件。
- 单写者：通过 `{path}.lock` 的 advisory exclusive lock 保证。
- 不承诺 fsync / 断电安全。
- Session path 仅做 lexical 校验（相对路径、无 `..`、非绝对），不是 symlink containment。

```startLine:37:46:packages/zag-coding-agent/src/session_store.zig
pub const Error = error{
    OutOfMemory, IoFailed, InvalidSession, UnsupportedSchema,
    SessionNotFound, SessionAlreadyExists, SessionBusy, InvalidPath,
};
```

### 3.6 兼容性合同

- Trace schema 版本：导出 `trace.current_schema_version = 1`（`packages/zag-agent-core/src/trace.zig:35`）。
- Session schema 版本：`session_store.current_schema_version = 1`（`packages/zag-coding-agent/src/session_store.zig:49`；D-011 移动后归 coding-agent 所有）。
- 同一版本内允许新增 optional 字段；strict reader 对未知 version 失败。
- 破坏性重命名必须出新 schema version 并提供迁移或显式拒绝。
- 在 SDK-ready Gate 闭合前，不承诺 semver；闭合后按 `packaging.md` 的发布策略执行。

---

## 4. 不做范围（按任务书要求钉死）

| 不做项 | 理由 / 当前状态 |
|---|---|
| **C ABI** | `D-008` 已决定：跨语言宿主使用后续 process/headless contract，不在 Zig SDK-ready Gate 内。 |
| **Zig 动态插件 ABI** | 同 `D-008`；`tool-runtime.md` 的 non-goals 也列明。 |
| **semver 发布** | `packaging.md` 要求：至少第二个真实 consumer + 发布通道，才进入 semver / repo mirror。本任务只关 source contract。 |
| **headless 协议** | 属于 `headless-001` 任务；本 gate 只解决 in-process Zig composition。 |
| **OS sandbox** | 已在 maturity / architecture 中明确为 C7 工作，不在 SDK-ready 最低合同。 |
| **Tool mid-flight 强制取消 / 进程树清理** | 已在 `loop-turn.md` 中声明为 post-H 工作；本 gate 只验证 between-tool cancel 和 provider cancel。 |

---

## 5. 风险与顺序建议

### 5.1 推荐执行顺序

1. **public-surface 收口**（最小代码变更，1 个文件 + root re-export）
   - `packages/zag-coding-agent/src/agent.zig`：给 `Options` 加 `toolset`、`observer` 字段；调整 `effectiveToolset` 与 `deps`。
   - `packages/zag-coding-agent/src/root.zig`：顶层 re-export `Toolset`、`Observer`。
   - 风险：低；只增加可选字段，默认行为不变。

2. **写 consumer fixture**（新目录）
   - 先写 low-level core composition fixture，确认 `zag-types` + `zag-agent-core` path dependency 可独立工作。
   - 再写 high-level `zag-coding-agent` fixture，验证 toolset/observer/policy/provider 注入。
   - 风险：中等；会暴露 API  ergonomics 问题，可能反向要求第 1 步补字段。

3. **文档化 public contract**
   - 新增/更新 `docs/modules/sdk-contract.md` 或 `docs/packaging.md#SDK-ready Gate`。
   - 更新 `docs/maturity.md` 中 `Zig source composition` 行证据。
   - 风险：低；纯文档。

4. **挂接 CI**
   - 根 `build.zig` / `build.zig.zon` 增加 fixture test step。
   - 跑 `zig build test` 全量回归。
   - 风险：低；但如果 fixture 依赖 `zag-coding-agent` → `zag-ai` → `openai-zig`，会增加 CI 时间。

### 5.2 路径重叠 / 串行点

- **串行**：必须先完成第 1 步 public-surface 收口，才能写出一个不依赖内部文件的高阶 consumer fixture。
- **并行**：
  - 文档 contract 整理可与第 1 步并行开始，因为规则已存在于代码/决策中。
  - low-level core fixture 可先于 high-level fixture 合并，提前验证 `zag-agent-core` 独立可用。
- **潜在重叠**：
  - 若第 2 步发现 `Agent` 的 observer chaining 语义不清晰（例如用户 observer 与内部 usage ledger 的调用顺序），会回到第 1 步修改。
  - 若 `zag-coding-agent` 拉入 `zag-ai`/`openai-zig` 导致 fixture 过重，可能需要把 fixture 拆成“仅 core”和“完整 coding-agent”两个 package。

### 5.3 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `Agent.Options` 注入设计不当，后续破坏默认 CLI/one-shot 行为 | 高 | 所有新字段必须 optional，默认走现有 `Phase1Storage` + 内部 observer 路径；CLI 不传新字段。 |
| fixture 依赖 `zag-coding-agent` 后编译时间显著增加 | 中 | fixture 可只依赖 `zag-agent-core` 做主要验证；`zag-coding-agent` 作为可选 high-level suite。 |
| 文档 contract 与代码语义 drift | 中 | 所有文档条目必须对应到具体类型/函数/错误码，并引用文件行号。 |
| 外部 consumer 在 monorepo 内引用 sibling package 路径被误当成“私有路径” | 低 | 在 SDK contract 中明确：path dependency 是 build-time monorepo 标准做法；禁止的是 source code 中 `@import("../src/...")` 内部文件。 |

---

## 6. 发现的 spec 缺口与建议修订

阅读 `docs/plan/tasks/sdk-contract-001.md` 后，发现以下值得在任务书里明确或修正的地方（**不修改任务书**，仅在本分析中记录）：

1. **V2 假设“高阶组合已支持 Toolset/Observer 注入”，但代码没有。**
   - 建议修订：把 `packages/zag-coding-agent/src/agent.zig` 增加 `toolset` / `observer` 注入字段列为 V2 的前置实现点，而不是假设已完成。

2. **任务书 paths 没有列出 `zag-ai` / `openai-zig`，但 consumer fixture 若依赖 `zag-coding-agent` 必然间接依赖它们。**
   - 建议修订：在任务书 path 段补充“consumer fixture 通过 `zag-coding-agent` 间接依赖 `zag-ai`；或 fixture 可只依赖 `zag-agent-core`”。

3. **V4 “ownership/lifetime 已文档化”缺乏验收标准。**
   - 建议修订：明确验收物为一份新增/更新的 `docs/modules/sdk-contract.md`（或 `docs/packaging.md` 扩展节），并列出必须覆盖的 6 类规则：Tool/Provider/Observer/Session/Trace/Cancel。

4. **V6 “CI 运行 external consumer”没有说明 fixture 位置与挂接方式。**
   - 建议修订：写明 fixture 是仓库内独立 package，并在根 `build.zig` `test` step 中显式 depend；避免把它放进某个现有包的 tests 里从而失去“external”含义。

5. **任务书没有明确外部 consumer 应如何证明自己“不引用私有路径”。**
   - 建议修订：验收标准可补充“fixture 的 `.zig` 源码中只出现 `@import("zag-types")` / `@import("zag-agent-core")` / `@import("zag-coding-agent")`，不得出现 sibling 包内部文件路径”。

---

## 7. 建议的 docs-first commit 内容

一个最小可闭合 SDK-ready Gate 的 commit 组（按变更文件列）：

### 代码变更

1. `packages/zag-coding-agent/src/agent.zig`
   - `Options` 增加 `toolset: ?[]const core.tool.Tool = null` 和 `observer: ?core.observer.Observer = null`。
   - `effectiveToolset()` 优先使用 `options.toolset`。
   - `deps()` 中把用户 observer 与内部 `onAgentEvent` 包装成 chain。
   - （可选）新增 `Agent.requestCancel()` 方法。

2. `packages/zag-coding-agent/src/root.zig`
   - 顶层 re-export：`pub const Toolset = tool.Toolset;`、`pub const Observer = observer.Observer;`、`pub const ToolRegistry = tool.Registry;`。

3. `tests/sdk-consumer-fixture/`
   - 新建 `build.zig`、`build.zig.zon`、`src/root.zig` 等。
   - 测试覆盖：自定义 Provider、自定义 stateful Toolset、Observer 事件记录、ask policy、cancel、session create/resume/error。

4. `build.zig.zon` / `build.zig`
   - 增加 `sdk_consumer_fixture` dependency；在 `test` step 中挂接其 tests。

### 文档变更

5. `docs/packaging.md`
   - 在 `SDK-ready Gate` 节增加“支持的 import 模块名”与“public API 注入点”小节。
   - 更新状态表格：`Zig SDK-ready` 从 ❌ 改为 ✅（commit 时）。

6. `docs/architecture.md`
   - “可组合 / SDK-ready”表格更新当前状态。

7. `docs/maturity.md`
   - `Zig source composition` 行从 L1 升级到 L2，引用 consumer fixture 与文档。

8. `docs/modules/sdk-contract.md`（新增）
   - 汇总第 3 节的 ownership/lifetime/error/event/cancel/session/compatibility 规则，作为 SDK 消费者的 public contract。

---

## 参考文件清单（绝对路径）

- `/Users/davirian/orca/zag/docs/plan/tasks/sdk-contract-001.md`
- `/Users/davirian/orca/zag/docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `/Users/davirian/orca/zag/docs/decisions/active/D-007-tool-runtime-descriptor.md`
- `/Users/davirian/orca/zag/docs/packaging.md`
- `/Users/davirian/orca/zag/docs/architecture.md`
- `/Users/davirian/orca/zag/docs/maturity.md`
- `/Users/davirian/orca/zag/docs/modules/tool-runtime.md`
- `/Users/davirian/orca/zag/docs/modules/loop-turn.md`
- `/Users/davirian/orca/zag/docs/modules/session-store.md`
- `/Users/davirian/orca/zag/docs/modules/trace-observability.md`
- `/Users/davirian/orca/zag/docs/modules/permissions.md`
- `/Users/davirian/orca/zag/packages/zag-types/src/root.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/root.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/loop.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/provider.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/tool.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/observer.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/cancel.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/trace.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/permissions.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/root.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/agent.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/session_store.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/toolset.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/wire_provider.zig`
- `/Users/davirian/orca/zag/build.zig`
- `/Users/davirian/orca/zag/build.zig.zon`
