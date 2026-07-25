---
date: 2026-07-25
task: headless-001
phase: H L2 closeout → Headless/Process SDK Gate
status: analysis only (no code changes)
---

# `headless-001` docs-first 规格核对

> 本文档是 `headless-001` 的 docs-first 规格核对，不是实现。
> 工作目录：`main` @ `af2687d`（Phase H L2、SDK-ready Gate 均已闭合）。
> 结论：Headless/Process SDK Gate **尚未闭合**；需要在 CLI 上叠加 `--json` / `--json-stream` 两种 headless 模式，建立版本化事件/错误协议、稳定 exit code 矩阵、端到端 process fixture，并同步更新 packaging/architecture/maturity 文档。

---

## 摘要

| 维度 | 结论 |
|------|------|
| 当前 CLI 真实行为 | one-shot 把模型最终文本写到 **stdout**；verbose/cost/错误走 **stderr**；help/doctor/REPL 提示也走 stdout；**timeout / unsupported_control / max_turns / cancelled 在 one-shot 中目前全部 exit 0**，这会在 headless 模式下被误判为成功。 |
| 规格缺口 | 任务书只有 5 条 verification，没有 flag 名、protocol version、event schema、exit code 矩阵、fixture 形态。 |
| 推荐 headless 形态 | `--json`：stdout 只输出一个最终 envelope（result 或 error）；`--json-stream`：stdout 输出 NDJSON 事件流 + 单一 terminal。协议版本 `headless-v1`，独立 public schema，不直接序列化内部 Observer/Trace。 |
| 关键代码变更点 | `packages/zag-cli/src/cli.zig`（解析、输出、错误映射）；`packages/zag-coding-agent/src/agent.zig` 已提供 Result/stop_reason，只需 CLI 消费；Observer 注入字段已存在，可直接用于 streaming。 |
| 验收物 | 新增 `packages/zag-cli/src/headless_process_fixture.zig`，仿 `doctor_process_fixture` 在 root `test` step 以 empty env / 隔离 cwd 运行真实 `zag` 二进制。 |
| 明确不做 | TUI 实现、ACP/editor 协议、SDK in-process 语义变化。 |

---

## 1. 当前 CLI 真实行为盘点

### 1.1 one-shot 的 stdout / stderr 分工

入口在 `packages/zag-cli/src/cli.zig` 的 `run()`，one-shot 最终调用 `runOneShot()`：

```startLine:339:370:packages/zag-cli/src/cli.zig
fn runOneShot(
    agent: *coding.Agent,
    prompt: []const u8,
    verbose: bool,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
) !void {
    const result = agent.completeWithSession(default_system, prompt, .{
        .path = session_path,
        .open_mode = open_mode,
        .load_project_instructions = load_project,
    }) catch |err| {
        std.log.err("agent failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(agent.gpa);

    if (verbose) {
        std.log.info("completed in {d} turn(s) stop={s}", .{ result.turns, @tagName(result.stop_reason) });
        agent.logCostSummary();
    } else if (agent.ledger.turns > 0) {
        // Quiet one-liner on run_end so cost is visible without -v.
        agent.logCostSummary();
    }
    if (result.stop_reason == .max_turns) {
        std.log.warn("stopped: max_turns reached ({d})", .{result.turns});
    } else if (result.stop_reason == .cancelled) {
        std.log.warn("stopped: cancelled (SIGINT)", .{});
    }

    try writeStdout(agent.io, result.final_text);
    if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
        try writeStdout(agent.io, "\n");
    }
}
```

- **stdout**：只有最终 `result.final_text` + 末尾换行。`
- **stderr**：`std.log.info` / `std.log.warn` / `std.log.err` 全部走 stderr；包括 verbose 启动信息、cost summary、max_turns/cancelled 警告、所有错误。

`writeStdout()` 封装的是 `Io.File.stdout()`：

```startLine:520:522:packages/zag-cli/src/cli.zig
fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}
```

### 1.2 `--doctor` 路径

`--doctor` 在参数校验之后、provider 解析之前返回，把报告写 **stdout**：

```startLine:156:159:packages/zag-cli/src/cli.zig
    if (want_doctor) {
        try runDoctor(gpa, io, doctorOptionsFromFlags(permission_mode, shell_policy, no_project));
        return;
    }
```

```startLine:308:318:packages/zag-cli/src/cli.zig
fn runDoctor(gpa: std.mem.Allocator, io: Io, opts: coding.doctor.Options) !void {
    const report = coding.doctor.collect(gpa, io, Io.Dir.cwd(), opts);
    var buf: [coding.doctor.report_buf_len]u8 = undefined;
    const text = coding.doctor.formatReport(&buf, report) catch {
        std.log.err("doctor report format failed", .{});
        std.process.exit(1);
    };
    try writeStdout(io, text);
}
```

### 1.3 REPL 路径

`runRepl()` 把提示符、session 状态、模型回复都写 **stdout**；错误只记 stderr 并继续：

```startLine:459:517:packages/zag-cli/src/cli.zig
fn runRepl(
    agent: *coding.Agent,
    io: Io,
    mode: core.permissions.Mode,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
) !void {
    try writeStdout(io, "zag (jail + policy + trace, permission=");
    ...
        const result = agent.reply(&session, user_text) catch |err| {
            std.log.err("agent failed: {s}", .{@errorName(err)});
            continue;
        };
    ...
}
```

### 1.4 当前 exit code 现状

| 场景 | 当前 exit code | 位置 |
|------|---------------|------|
| `--help` | 0 | `printUsage()` → stdout |
| `--doctor` 成功 | 0 | `runDoctor()` |
| one-shot `completed` | 0 | `runOneShot()` |
| one-shot `max_turns` | **0**（仅 stderr warn） | `runOneShot()` |
| one-shot `cancelled` | **0**（仅 stderr warn） | `runOneShot()` |
| one-shot `timeout` | **0**（无特殊处理） | `runOneShot()` |
| one-shot `unsupported_control` | **0**（无特殊处理） | `runOneShot()` |
| 参数错误（unknown flag / missing value / 无效 session path） | 2 | `cli.zig` 多处 `std.process.exit(2)` |
| missing API key / unknown provider /  unsupported style / base url | 1 | `ai.resolve()` catch |
| wire init失败 / Agent init OOM | 1 | `cli.zig` |
| one-shot `provider_error` / `session_error` / `trace_error` / `out_of_memory` / `invalid_toolset` / `invalid_context` | 1 | `runOneShot()` catch |
| REPL 内错误 | **不退出** | `runRepl()` catch + continue |

**关键发现**：`timeout` 和 `unsupported_control` 在 `loop.run` 里作为 `Result` 返回（不是 error），但 `runOneShot()` 没有检查 `stop_reason`，直接 exit 0。`max_turns` / `cancelled` 同样 exit 0。这意味着脚本无法从 exit code 区分成功和部分/失败状态。

### 1.5 会污染 JSON 协议的 stdout 内容

当前默认模式下 stdout 只包含最终文本，所以**默认模式不会污染 JSON 协议**（因为默认模式本来就不是 JSON 模式）。但在 headless 模式下，以下输出必须从 stdout 中移除或转为 JSON：

- `--help` 的人类文本；
- `--doctor` 的人类文本；
- REPL 提示符和状态行（headless 模式应禁用 REPL，或报错）；
- one-shot 的纯文本 `final_text`（应包进 JSON envelope）。

verbose / cost / 错误日志已经走 stderr，不需要 stdout 净化改造，只需保证 headless 模式下**不再新增 stdout 日志**。

---

## 2. 任务书 5 条 verification 逐条核对

任务书原文 verification：

> - stdout in JSON modes contains only protocol output;
> - auth, invalid/missing session, save conflict/failure, cancellation, timeout, and required-sandbox-unavailable have documented structured errors and exit codes;
> - streaming events are versioned and terminal exactly once;
> - a CI fixture uses headless mode end-to-end;
> - TUI remains optional and cannot contain loop business logic.

### V1 — stdout 在 JSON 模式下只包含协议输出

**现状差距**

- 没有 `--json` / `--json-stream` flag；
- one-shot 默认把 `final_text` 写 stdout；
- `--doctor` / `--help` 写 stdout；
- REPL 在 headless 场景下不适用，但 CLI 不会拒绝。

**需要的代码/文档变更**

| 文件 | 变更 |
|------|------|
| `packages/zag-cli/src/cli.zig` | 新增解析 `--json`、`--json-stream`；one-shot 路径改用 headless writer；REPL 路径在检测到 headless flag 时 `exit(2)`。 |
| `packages/zag-cli/src/cli.zig` | `--doctor` 在 headless 模式下输出 JSON 版 doctor report（或仅 stderr 报错 + exit 2），避免人类文本混入协议 stdout。 |
| `packages/zag-cli/src/headless_writer.zig`（建议新增） | 集中处理 JSON envelope / NDJSON 事件流、redaction、错误序列化。 |
| `docs/modules/headless-contract.md`（建议新增） | 定义 stdout 协议：NDJSON，每行一个对象，`protocol_version` 字段。 |
| `docs/phases/C9-product-shell.md` | 更新“TUI/headless 共享正确性”条，指明 headless 是更早的 Gate。 |
| `docs/packaging.md` | 更新 Headless Gate 状态。 |
| `docs/maturity.md` | Headless/Process SDK 行从 L1 升级到 L2（闭合后）。 |

**推荐的 headless 模式形态**

- `--json`：stdout 只输出**一行** JSON，要么是 result envelope，要么是 error envelope。示例：
  ```json
  {"protocol_version":"headless-v1","type":"result","ok":true,"stop_reason":"completed","turns":1,"final_text":"...","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15},"estimated_usd":null}
  ```
- `--json-stream`：stdout 输出 NDJSON 事件流，包含 `run_start`、`assistant_text`/`assistant_delta`、`tool_call`、`tool_result`、`permission`、`usage`、`run_end`（或 `error`）。每行一个对象，保证最终有且仅有一个 terminal 事件。
- `--stream`（现有 SSE provider 流）与 `--json-stream` 是**不同维度**：前者控制 provider 是否使用 SSE；后者控制 CLI 对外输出的事件流。可在 `--json-stream` 时内部默认启用 SSE 以获得增量文本，但协议事件仍由 CLI 生成。

### V2 — auth/session/save/cancel/timeout/sandbox 有结构化错误与 exit code

**现状差距**

- `ai.resolve` 错误现在走人类 stderr + `exit(1)`；
- `Agent.completeWithSession` 错误统一走 `std.log.err("agent failed: {s}", .{@errorName(err)})` + `exit(1)`；
- session save 失败返回 `session_store.Error`（如 `IoFailed`、`SessionBusy`），但 CLI 只把它当作普通 error 打印 Zig error name；
- `timeout` / `unsupported_control` 目前作为成功 exit；
- clean `cancelled` 没有独立 exit code；
- 没有 `required_sandbox_unavailable` 概念。

**需要的代码/文档变更**

| 文件 | 变更 |
|------|------|
| `packages/zag-cli/src/cli.zig` | 把 `ai.resolve` catch、`Agent.completeWithSession` catch 统一映射到一个 `HeadlessError`（或 `HeadlessTerminal`）结构，再交给 headless writer。 |
| `packages/zag-cli/src/cli.zig` | 对 `--json` / `--json-stream` 输出错误 JSON；对人类模式保留现有 stderr 文本。 |
| `packages/zag-agent-core/src/session_store.zig` | 错误集合已足够细分（`SessionNotFound`、`SessionAlreadyExists`、`SessionBusy`、`InvalidSession`、`UnsupportedSchema`、`IoFailed`、`InvalidPath`、`OutOfMemory`），CLI 只需映射，无需新增错误类型。 |
| `docs/modules/headless-contract.md` | 错误 code 表与 retryable 标志。 |
| `docs/modules/session-store.md` | 确认“save 错误通过 headless structured output 暴露”已满足底层能力，只需 CLI 层实现。 |

**推荐设计**

- `auth` 类错误（missing key、unknown provider、unsupported style、missing base url）使用 code `provider_configuration`；运行时 provider 失败使用 `provider_error`。
- session 类错误保留独立 code：`session_not_found`、`session_already_exists`、`session_invalid`、`session_unsupported_schema`、`session_busy`、`session_io_failed`。
- `save conflict` 映射到 `session_busy`（写入锁冲突）或 `session_io_failed`（I/O 失败）；两者都归入 session 错误族。
- `timeout` / `unsupported_control` 不是错误 envelope，而是 `ok=false` 的 terminal result envelope，携带 `stop_reason`。
- `required_sandbox_unavailable` 作为保留 code，用于将来“请求了必须 sandbox 的模式但当前平台/构建未提供”的场景；当前实现可直接返回该 code + exit 22。

### V3 — streaming 事件版本化且 terminal 恰好一次

**现状差距**

- `--stream` 只影响 provider 内部 SSE 行为；CLI 没有对外事件协议；
- `Observer.Event` 只在进程内回调，未序列化到 stdout；
- `Trace` 写入文件，不是 stdout；
- 没有 `protocol_version` 字段。

**需要的代码/文档变更**

| 文件 | 变更 |
|------|------|
| `packages/zag-coding-agent/src/agent.zig` | `Options.observer` 已存在，CLI 可以注入一个 headless observer 来转发事件。 |
| `packages/zag-cli/src/headless_writer.zig` | 把 `Observer.Event` 映射为公共 headless event schema；缓冲增量文本；保证 `run_end` / `error` 只写一次。 |
| `packages/zag-agent-core/src/trace.zig` | 内部 trace 仍负责 audit 级别的 `run_end`；headless 协议 terminal 由 CLI 在 `Agent.reply` 返回后根据 `Result` / error 写出，避免与 trace 事件重复。 |
| `docs/modules/headless-contract.md` | 事件 schema + `protocol_version` + terminal 规则。 |

**推荐：是否复用 Observer Event 还是独立协议？**

**推荐独立 public schema**，理由：

1. `Observer.Event` 是 in-process union，包含 borrowed 切片和内部类型（如 `message.Usage`、`message.ToolCall`），不适合直接 `std.json.stringify` 作为跨进程协议。
2. `Trace` schema 是 audit log，包含大量内部事件（`jail_deny`、`shell_deny`、`provider_retry`、`compaction`），对 headless 调用方并非都需要，且其字段命名面向审计而非交互。
3. Headless 协议需要增量 `assistant_delta`、受控 redaction、明确 terminal。独立 schema 可以只暴露调用方需要的事件，同时保留与 Observer/Trace 的语义对应关系。

建议映射：

| Headless event | 来源 | 说明 |
|---------------|------|------|
| `run_start` | `Agent.beginRun` / trace run_start | 含 `protocol_version`、`zag_version`、`permission`、`shell_policy`。 |
| `assistant_text` / `assistant_delta` | Observer `assistant_text` 或 SSE delta | 非流模式可合并为单个 `assistant_text`；流模式输出 delta。 |
| `tool_call` | Observer `tool_call` | id、name、arguments（已 redact）。 |
| `tool_result` | Observer `tool_result` | name、body（已 redact）。 |
| `permission` | Observer `permission` | tool_name、allowed、remembered、risk。 |
| `usage` | Observer `usage` | prompt/completion/total tokens。 |
| `run_end` | `Agent.reply` 返回的 `Result` | ok、stop_reason、turns、usage。 |
| `error` | 任何 harness 错误 | 在 `--json-stream` 中作为 terminal 替代 `run_end`。 |

### V4 — CI fixture 端到端使用 headless 模式

**现状差距**

- 已有 `doctor_process_fixture` 模式，但针对 `--doctor`（无 provider）；
- 没有 headless 模式 fixture。

**需要的代码/文档变更**

| 文件 | 变更 |
|------|------|
| `packages/zag-cli/src/headless_process_fixture.zig`（新增） | 仿 `doctor_process_fixture.zig`，用 empty env + 隔离 cwd 运行真实 `zag` 二进制；需要一个 mock provider（可用 fixture 内临时 HTTP server 或新 preset）。 |
| `build.zig` | 添加 `headless_fixture_options` + `headless_process_tests`，挂到 `test` step。 |
| `docs/quality/evals.md` | 更新 Headless E2E 行状态。 |

**推荐 fixture 形态**

参考 `packages/zag-cli/src/doctor_process_fixture.zig`：

```startLine:1:22:packages/zag-cli/src/doctor_process_fixture.zig
//! Process-level h-doctor-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `doctor_fixture_options.zag_bin` and runs this file as a test artifact under
//! `zig build test` (std and curl backends rebuild `zag` accordingly).
//!
//! Spawns real product processes under isolated cwd + empty environment (no
//! provider/API-key/config) and asserts:
//! - exit 0 + complete fixed-field stdout for default and yolo/off/no-project;
//! - legal session/trace paths do not create files (session/trace not entered);
//! - invalid session paths fail before doctor with generic error (no path leak).
```

headless fixture 需要额外：

1. 在 fixture 内启动一个 OpenAI-compatible mock HTTP server；
2. 设置环境变量 `ZAG_API_KEY=fake`、`ZAG_BASE_URL=http://127.0.0.1:<port>`、`ZAG_PROVIDER` 为空或自定义；
3. 运行 `zag --json "hi"` 或 `zag --json-stream "hi"`；
4. 断言：stdout 每行都是合法 JSON；最终为 `run_end`/`error`；exit code 符合矩阵；stderr 不出现 secret/path；session/trace 文件按需创建。

或者，如果担心 fixture 里开 TCP server 的复杂度，可在 `zag-ai` 里加一个仅测试 preset 的 mock provider（但这样跑的不是真实产品二进制，fixture 意义变弱）。**推荐 process fixture 用真实二进制 + 临时 mock server**，与 doctor fixture 保持一致的“黑盒产品进程”理念。

### V5 — TUI 保持可选且不包含 loop 业务逻辑

**现状差距**

- 目前没有 TUI；C9 明确 TUI 在 headless Gate 之后。
- 需要防止未来 TUI 代码污染 Kernel 或 CLI 默认构建。

**需要的代码/文档变更**

| 文件 | 变更 |
|------|------|
| `build.zig` / `build.zig.zon` | 添加 `-Dtui` 选项，默认 false；TUI 依赖设为 lazy。 |
| `docs/phases/C9-product-shell.md` | 更新 acceptance 条，明确“headless Gate 在 TUI 开启/关闭时均保持绿色”。 |
| `docs/architecture.md` | 强调产品 shell 只组装 Kernel API，不实现 loop/permission/session。 |

**检查方式**

- `zig build test`（默认 `-Dtui=false`）全绿；
- 一个静态检查测试：扫描 `packages/zag-coding-agent/src/` 和 `packages/zag-agent-core/src/` 源码，确认没有 import TUI 包；
- 一个 CI 步骤：`zig build -Dtui`（或单独 `tui` step）至少能编译，但不在默认 `test` step 中。

---

## 3. 稳定 exit code 矩阵设计

### 3.1 建议矩阵（仅 headless 模式生效）

| 场景 | exit code | 说明 |
|------|:---------:|------|
| `completed` | 0 | 成功完成。 |
| `max_turns` | 10 | 正常返回 Result，但达到 turn 上限；不是 harness 失败，但调用方通常需要知道。 |
| `cancelled` | 11 | 干净的合作式取消；ok=true。 |
| `timeout` | 20 | 端到端 deadline 触发；ok=false。 |
| `unsupported_control` | 21 | 后端无法执行所需的 deadline/active-cancel；ok=false。 |
| `required_sandbox_unavailable` | 22 | 请求了必须 sandbox 的运行模式，但当前构建/平台未提供；ok=false。 |
| `provider_configuration`（missing key / unknown provider / unsupported style / missing base url） | 30 | 配置/认证类错误；retryable=false。 |
| `provider_error`（runtime provider/auth/network/model） | 31 | provider 运行时错误；retryable 视情况而定（如 rate limit 可重试，但 CLI 不重试）。 |
| `invalid_toolset` | 32 | loop 启动前 toolset 校验失败。 |
| `invalid_context` | 33 | history/context 校验失败。 |
| `out_of_memory` | 40 | 分配失败。 |
| `session_not_found` | 50 | resume 时 session 文件不存在。 |
| `session_already_exists` | 51 | create_new 时目标已存在。 |
| `session_invalid` | 52 | 解析失败。 |
| `session_unsupported_schema` | 53 | schema 版本不支持。 |
| `session_busy` | 54 | 写锁冲突（save conflict 也归此类）。 |
| `session_io_failed` | 55 | session 保存 I/O 失败。 |
| `trace_error` / `trace_io_failed` | 60 | trace 持久化/序列化失败。 |
| invalid CLI args | 2 | 保持 Unix 惯例（unknown flag、missing value、非法 session path 等）。 |
| unexpected/internal | 70 | 断言失败、Zig 不可恢复错误等。 |

### 3.2 与现有 CLI 行为的兼容策略

- **默认模式（无 `--json` / `--json-stream`）**：保持当前 0/1/2 行为，避免破坏现有“把 stdout 当最终文本”的脚本。`timeout` / `unsupported_control` 在默认模式下可继续 exit 0（遗留债务），但在 headless 模式下必须按矩阵返回。
- **headless 模式**：使用上述完整矩阵。实现时把 exit code 计算集中到 `headless_writer.zig` 的 `emitResult` / `emitError`，`run()` 最后调用 `std.process.exit(code)`。
- **`--help`**：headless 模式下可以返回 JSON help 或仍 exit 0 但把 help 写 stderr；推荐后者，保持 stdout 干净。
- **`--doctor`**：默认模式保持现有 stdout 文本；headless 模式下输出 JSON doctor report 到 stdout。
- **REPL**：遇到 `--json` / `--json-stream` 直接 `exit(2)`，因为 REPL 不是 headless 协议。

---

## 4. 错误 schema 设计

### 4.1 结构化错误 JSON

在 `--json` 模式下，失败时 stdout 只输出：

```json
{
  "protocol_version": "headless-v1",
  "type": "error",
  "error": {
    "code": "provider_configuration",
    "message": "Missing API key.",
    "retryable": false,
    "category": "auth"
  }
}
```

字段定义：

| 字段 | 类型 | 说明 |
|------|------|------|
| `protocol_version` | string | 协议版本，固定 `headless-v1`。 |
| `type` | string | 固定 `error`。 |
| `error.code` | string | 稳定机器码，见第 3 节矩阵。 |
| `error.message` | string | 人类可读，但必须经过 redactor，不得包含 secret/path。 |
| `error.retryable` | bool | 是否适合调用方重试。 |
| `error.category` | string | 分组：`auth`、`session`、`provider`、`runtime`、`argument`。 |

### 4.2 与 `tool_error` / `stop_reason` 的映射

- **Harness 级错误**（CLI 入口到 `Agent.reply` 之间的错误）使用上述 error envelope。
- **Tool 软错误**仍按现有 `tool_error` 格式出现在 `tool_result` event 的 body 中：
  ```text
  error: code=<CODE> message=<human>
  ```
  headless 协议的 `tool_result` 事件原样传递 body（已 redact），调用方可解析 `code=`。
- **Terminal stop reasons**（`completed` / `max_turns` / `cancelled` / `timeout` / `unsupported_control` / `provider_error` / `session_error` / `trace_error` / `out_of_memory` / `invalid_toolset` / `invalid_context`）不单独走 error envelope，而是出现在 result envelope 或 `run_end` 事件的 `stop_reason` 字段中，与 `loop.StopReason` 同名。

```startLine:82:121:packages/zag-agent-core/src/loop.zig
pub const StopReason = enum {
    completed,
    max_turns,
    cancelled,
    /// End-to-end provider deadline fired (ok=false).
    timeout,
    /// Backend cannot enforce required deadline/active-cancel (ok=false).
    unsupported_control,
    provider_error,
    /// Session save failed after loop Result; terminal ok=false (facade).
    session_error,
    /// Trace persistence/preflight failure category for terminals (facade).
    trace_error,
    /// Allocator exhaustion after run_start (facade).
    out_of_memory,
    /// Toolset failed closed validation (facade).
    invalid_toolset,
    /// Malformed tool-call/result history or context policy (h-context-001).
    invalid_context,
```

### 4.3 Redaction 要求

- 所有 headless 输出在序列化前必须经过与 Trace/Session 相同的 redactor（`Agent.activeRedactor()`）。
- 错误 message 中不得出现：API key、session/trace 路径、绝对路径、模型/Provider 细节中可能包含的 secret。
- 现有 CLI 已经遵守：例如 `invalidPermissionModeMessage()` 不插入选中的 argv token；`formatVerboseStartup()` 只输出枚举/数字。headless 模式需要把这条规则扩展到 JSON 字段。
- `tool_result` body 已经由 Agent 在写入 transcript/trace 前 redact；headless 直接复用该 body。

---

## 5. 验收物与测试形态

### 5.1 Process-level fixture

建议新增 `packages/zag-cli/src/headless_process_fixture.zig`，结构与 `doctor_process_fixture.zig` 对齐：

```text
packages/zag-cli/src/headless_process_fixture.zig
build.zig 新增 headless_fixture_options + run_headless_process_tests
```

Fixture 必须满足：

1. **Empty env**：`std.process.Environ.Map` 为空，避免真实 API key 干扰；
2. **隔离 cwd**：`std.testing.tmpDir`；
3. **真实二进制**：`addOptionPath("zag_bin", exe.getEmittedBin())`；
4. **mock provider**：fixture 内起 OpenAI-compatible HTTP server；
5. **断言内容**：
   - stdout 每行可解析为 JSON；
   - `--json` 输出恰好一行，且为 `result`/`error`；
   - `--json-stream` 最后一行为 `run_end` 或 `error`；
   - exit code 与 stop_reason / error code 对应；
   - stderr 不出现 secret / 绝对路径；
   - 缺失 API key、非法 session path、save conflict 等路径返回预期 JSON + exit code。

`build.zig` 挂接方式参考 doctor fixture：

```startLine:322:350:build.zig
    const doctor_fixture_opts = b.addOptions();
    doctor_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
    const doctor_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/doctor_process_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doctor_fixture_options", .module = doctor_fixture_opts.createModule() },
            },
        }),
    });
    const run_doctor_process_tests = b.addRunArtifact(doctor_process_tests);
    const doctor_fixture_step = b.step(
        "doctor-process-fixture",
        "Process-level zag --doctor no-key / session-validation fixture",
    );
    doctor_fixture_step.dependOn(&run_doctor_process_tests.step);

    const test_step = b.step("test", "Run all tests + openai coverage + catalog + docs lint");
    ...
    test_step.dependOn(&run_doctor_process_tests.step);
```

### 5.2 TUI 保持可选的检查方式

- **构建选项**：`zig build -Dtui` 开启，默认关闭；root `test` step 不依赖 TUI。
- **静态隔离测试**：一个单元测试扫描源码，确认 `zag-agent-core` 和 `zag-coding-agent` 没有 import TUI 包。
- **文档检查**：`docs/phases/C9-product-shell.md` 与 `docs/architecture.md` 明确 TUI 不实现 loop/session/permission 业务逻辑；docs lint 保证引用一致。

---

## 6. 明确不做

| 不做项 | 理由 / 当前状态 |
|--------|----------------|
| **TUI 实现** | 属于 C9，在 headless Gate 之后；本任务只保证 TUI 不破坏 headless 协议。 |
| **ACP / editor 协议** | D-008 明确 ACP/editor 集成基于已存在的 process contract 再做；headless 是前置 Gate。 |
| **SDK 语义变化** | `sdk-contract-001` 已在 `ebdd7ab` 闭合；headless 使用现有 `Agent.Options.observer` / `toolset` / `Session` / `stop_reason`，不扩展 in-process SDK contract。 |
| **新增 C ABI / dynamic plugin ABI** | 已由 D-008 排除；跨语言宿主走 process protocol。 |
| **OS sandbox 实现** | 属于 C7；headless 只预留 `required_sandbox_unavailable` error code。 |
| **mid-flight Tool/shell 抢占** | loop-turn.md 已声明为 post-H process work，不影响 headless 协议。 |

---

## 7. 风险与顺序

### 7.1 stdout 纯净性改造是否影响现有用户

**结论：风险可控。**

- 当前默认模式的 stdout 仅包含最终文本；verbose、cost、错误都已走 stderr。headless 改造只是：
  1. 新增 `--json` / `--json-stream` 分支；
  2. 在这些分支下把最终文本包进 JSON，不再输出纯文本；
  3. 把 `--doctor` / `--help` 在 headless 模式下从 stdout 移除或转成 JSON。
- 没有 `--json` flag 的用户不会观察到任何 stdout 变化。
- 需要新增的约束：**headless 模式下禁止任何 `std.log.info/warn/err` 写 stdout**，只能写 stderr。由于 Zig 的 `std.log` 默认就是 stderr，只需注意不要调用 `writeStdout` 输出日志即可。

### 7.2 REPL 不受影响

- REPL 遇到 `--json` / `--json-stream` 应直接 `exit(2)`，因为 REPL 是交互产品壳，不是 headless 协议。
- 默认 REPL 的 stdout 行为保持不变。

### 7.3 推荐提交顺序

1. **docs-first 协议设计**
   - 新增 `docs/modules/headless-contract.md`（protocol version、event schema、error schema、exit code 矩阵、redaction 规则）。
   - 更新 `docs/phases/C9-product-shell.md`、`docs/packaging.md`、`docs/architecture.md`、`docs/maturity.md`（Headless 行待闭合）。

2. **CLI headless flag + JSON envelope**
   - `packages/zag-cli/src/cli.zig`：解析 `--json` / `--json-stream`；one-shot 输出 result/error envelope； doctor/help 在 headless 下不污染 stdout。
   - `packages/zag-cli/src/headless_writer.zig`：新增 writer，负责 redaction、序列化、exit code 计算。

3. **Streaming 事件 + terminal 唯一性**
   - 通过 `Agent.Options.observer` 注入 headless observer，映射到 NDJSON 事件流；`run_end` / `error` 由 CLI 在 `Agent.reply` 返回后只写一次。
   - 单元测试：验证 terminal 事件唯一、事件 schema version 存在。

4. **结构化错误与 exit code 矩阵**
   - 把 `ai.resolve` 错误、`session_store.Error`、`loop.RunError` / `ReplyError` 映射到 headless error schema。
   - 在 headless fixture 中覆盖 missing key、illegal session path、save conflict、cancel、timeout。

5. **Process fixture + CI 挂接**
   - 新增 `packages/zag-cli/src/headless_process_fixture.zig` 和 `build.zig` step。
   - 跑 `zig build test` 全量回归。

6. **TUI optional gate 验证**
   - 添加 `-Dtui` 构建选项（默认 false）；静态测试确保 Kernel 不依赖 TUI；文档更新。

---

## 8. 对任务书 `headless-001.md` 的 spec 缺口与修订建议

任务书本身只有 high-level verification，没有实现细节。以下建议**不修改任务书**，供后续实现 commit 时参考：

1. **缺少 flag 名称**。建议明确 headless 入口为 `--json`（单结果 envelope）和 `--json-stream`（NDJSON 事件流）。
2. **缺少 protocol version**。建议写入 `protocol_version: "headless-v1"`，与 trace schema version（`trace.current_schema_version = 1`）解耦。
3. **未说明错误输出位置**。建议明确：headless 模式下所有协议输出（result / error / event）走 stdout；日志/诊断走 stderr。
4. **未定义事件 schema**。建议新增独立 `docs/modules/headless-contract.md`，说明 public event 与内部 Observer/Trace 的映射关系，而不是直接序列化 Observer。
5. **`required-sandbox-unavailable` 尚无实现基础**。当前代码没有任何 sandbox 开关，建议在任务书中注明这是“为将来 required-sandbox 运行模式预留的错误 code 和 exit code”，当前实现只需保留映射即可。
6. **CI fixture 形态未说明**。建议仿照 `doctor_process_fixture`：真实 `zag` 二进制、empty env、隔离 cwd、mock provider、root `test` step 挂接。
7. **TUI optional 验收标准模糊**。建议补充为：`-Dtui` 构建选项默认 false，默认 `zig build test` 不依赖 TUI，且 Kernel 源码不 import TUI 包。

---

## 参考文件清单（绝对路径）

- `/Users/davirian/orca/zag/docs/plan/tasks/headless-001.md`
- `/Users/davirian/orca/zag/docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `/Users/davirian/orca/zag/docs/phases/C9-product-shell.md`
- `/Users/davirian/orca/zag/docs/modules/trace-observability.md`
- `/Users/davirian/orca/zag/docs/modules/loop-turn.md`
- `/Users/davirian/orca/zag/docs/modules/session-store.md`
- `/Users/davirian/orca/zag/docs/modules/sdk-contract.md`
- `/Users/davirian/orca/zag/docs/plan/analysis/2026-07-24-production-floor-assessment.md`
- `/Users/davirian/orca/zag/docs/plan/analysis/2026-07-25-sdk-contract-plan.md`
- `/Users/davirian/orca/zag/docs/maturity.md`
- `/Users/davirian/orca/zag/packages/zag-cli/src/cli.zig`
- `/Users/davirian/orca/zag/packages/zag-cli/src/doctor_process_fixture.zig`
- `/Users/davirian/orca/zag/packages/zag-coding-agent/src/agent.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/loop.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/observer.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/trace.zig`
- `/Users/davirian/orca/zag/packages/zag-agent-core/src/tool_error.zig`
- `/Users/davirian/orca/zag/build.zig`
