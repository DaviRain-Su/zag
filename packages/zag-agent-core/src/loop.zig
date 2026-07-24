//! Agent harness loop — business only.
//!
//! ```
//! transcript ──► context.view ──► provider.chat (definitions only)
//!      ▲                               │
//!      │                          tool_calls?
//!      │                          no → done
//!      │                          yes ↓
//!      │         find descriptor → permission → jail → shell policy
//!      │                     deny → soft tool error
//!      │                     allow → execute (serial in H1)
//!      └──────── tool results ────────┘
//! ```
//!
//! **Parallelism (H1 / L2):** tools in one assistant message run **serially** in
//! call order. Spec allows future parallel read-only batches; write/shell must
//! stay serial. See test "tools execute serially in call order".
//!
//! Permission / jail / shell selection use `ToolDescriptor` capabilities only
//! (D-007). Unknown model-requested tools soft-fail without name-based risk.

const std = @import("std");
const zt = @import("zag-types");
const message = @import("message.zig");
const tool = @import("tool.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const observer_mod = @import("observer.zig");
const permissions = @import("permissions.zig");
const context_mod = @import("context.zig");
const workspace = @import("workspace.zig");
const shell_policy = @import("shell_policy.zig");
const trace_mod = @import("trace.zig");
const tool_error = @import("tool_error.zig");
const cancel_mod = @import("cancel.zig");

pub const default_max_turns: u32 = 20;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
    observer: observer_mod.Observer = .none(),
    permission_gate: permissions.Gate = .yolo(),
    context: context_mod.Options = .{},
    /// Four prompt layers for the model view (H4). Used when `get_layers` is null.
    layers: context_mod.Layers = .{},
    /// Optional live layers (e.g. Session after compaction). Prefer over `layers`.
    get_layers: ?*const fn (ctx: ?*anyopaque) context_mod.Layers = null,
    layers_ctx: ?*anyopaque = null,
    shell_policy: shell_policy.Mode = .protect,
    /// Optional structured audit log (not freed by loop).
    trace: ?*trace_mod.Trace = null,
    /// Extra chat attempts on retryable provider errors (0 = no loop-level retry).
    /// Timeout and Cancelled are never retried; deadline budget is end-to-end.
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    /// Cooperative cancel (SIGINT / tests). Checked between turns/tools and
    /// threaded into provider request control for in-flight abort.
    cancel: ?*cancel_mod.Flag = null,
    /// End-to-end provider deadline (ms) for one chatWithRetry cycle; null = none.
    /// Shared across attempts (not reset per retry). 0 = immediate Timeout.
    provider_timeout_ms: ?u64 = null,
    /// Optional sink when view compaction fires (summary is turn-arena owned — sink must dupe).
    /// Must return `error.OutOfMemory` on failure so the loop does not emit a
    /// compaction event to trace without a matching session update (h-context-001).
    on_compaction: ?*const fn (ctx: ?*anyopaque, event: context_mod.CompactionEvent) error{OutOfMemory}!void = null,
    compaction_ctx: ?*anyopaque = null,
};

pub const RunError = error{
    /// Prefer Result.stop_reason=.max_turns; kept for callers that still match this error.
    MaxTurnsExceeded,
    ProviderFailed,
    OutOfMemory,
    /// Toolset failed closed validation before any provider call.
    InvalidToolset,
    /// Mid-run trace event emission failed (not a silent drop).
    /// Distinct from explicit-path flush failure (`trace.Error.TraceIoFailed`) owned by the facade.
    TraceFailed,
    /// Malformed transcript history / context policy fail-closed (h-context-001).
    /// Not a provider error — no model call for the failed turn.
    InvalidContext,
};

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

    pub fn name(self: StopReason) []const u8 {
        return switch (self) {
            .completed => "completed",
            .max_turns => "max_turns",
            .cancelled => "cancelled",
            .timeout => "timeout",
            .unsupported_control => "unsupported_control",
            .provider_error => "provider_error",
            .session_error => "session_error",
            .trace_error => "trace_error",
            .out_of_memory => "out_of_memory",
            .invalid_toolset => "invalid_toolset",
            .invalid_context => "invalid_context",
        };
    }
};

/// Map in-memory trace emit failures into the loop error set (never swallow).
fn mapTraceEmit(err: trace_mod.Error) RunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TraceIoFailed, error.InvalidPath, error.TraceSerializationFailed => error.TraceFailed,
    };
}

pub const Result = struct {
    final_text: []const u8,
    turns: u32,
    /// Sum of provider-reported usage across chat turns (zeros if none reported).
    usage: message.Usage = .{},
    stop_reason: StopReason = .completed,
};

pub const Deps = struct {
    gpa: std.mem.Allocator,
    provider: provider_mod.Provider,
    toolset: tool.Toolset,
    tool_ctx: tool.Context,
    options: Options = .{},
};

pub fn run(deps: Deps, transcript: *transcript_mod.Transcript) RunError!Result {
    // Fail closed before the first provider call on malformed toolsets.
    tool.validateTools(deps.gpa, deps.toolset.tools) catch return error.InvalidToolset;

    // Resolve workspace root once per run and thread into file-tool handlers.
    // Failure is not a hard run error: path tools fail closed via Guard.
    var root_owned: ?[]u8 = null;
    defer if (root_owned) |r| deps.gpa.free(r);
    if (deps.tool_ctx.workspace_root_real == null) {
        root_owned = workspace.resolveCwdReal(deps.gpa, deps.tool_ctx.io, deps.tool_ctx.cwd) catch null;
    }
    var tool_ctx = deps.tool_ctx;
    if (root_owned) |r| {
        tool_ctx.workspace_root_real = r;
    }
    // Shadow deps with the threaded context for the rest of the run.
    const deps_run: Deps = .{
        .gpa = deps.gpa,
        .provider = deps.provider,
        .toolset = deps.toolset,
        .tool_ctx = tool_ctx,
        .options = deps.options,
    };

    var turns: u32 = 0;
    var last_text: []const u8 = "";
    var usage_total: message.Usage = .{};

    while (turns < deps_run.options.max_turns) {
        if (isCancelled(deps_run.options)) {
            return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .cancelled,
            };
        }

        turns += 1;
        if (deps_run.options.trace) |tr| {
            tr.emitTurn(turns) catch |err| return mapTraceEmit(err);
        }

        var turn_arena_impl: std.heap.ArenaAllocator = .init(deps_run.gpa);
        defer turn_arena_impl.deinit();
        const scratch = turn_arena_impl.allocator();

        const layers = if (deps_run.options.get_layers) |gl|
            gl(deps_run.options.layers_ctx)
        else
            deps_run.options.layers;
        const view = context_mod.viewForModel(
            scratch,
            transcript.items(),
            deps_run.options.context,
            layers,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidContext => return error.InvalidContext,
        };
        // Session sink first, then trace: OOM on session note aborts before any
        // compaction line is written so session metadata and trace cannot
        // silently diverge on the success path (h-context-001). Both receive
        // the same final event when both succeed. If note succeeds and a later
        // mid-run trace emit fails, session may already hold the new gen —
        // that is a visible run failure, not silent equality.
        if (view.compaction) |ev| {
            if (deps_run.options.on_compaction) |cb| {
                cb(deps_run.options.compaction_ctx, ev) catch return error.OutOfMemory;
            }
            if (deps_run.options.trace) |tr| {
                tr.emitCompactionEvent(ev) catch |err| return mapTraceEmit(err);
            }
        }

        const outcome = try chatWithRetry(deps_run, scratch, view.messages);
        const turn = switch (outcome) {
            .turn => |t| t,
            .cancelled => return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .cancelled,
            },
            .timeout => return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .timeout,
            },
            .unsupported_control => return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .unsupported_control,
            },
        };

        // Only complete validated AssistantTurn crosses the provider boundary.
        try transcript.appendAssistantTurn(turn);
        last_text = transcript.items()[transcript.items().len - 1].content;
        deps_run.options.observer.emit(.{ .assistant_text = last_text });
        if (deps_run.options.trace) |tr| {
            tr.emitAssistant(last_text) catch |err| return mapTraceEmit(err);
            tr.emitUsage(turn) catch |err| return mapTraceEmit(err);
        }
        if (turn.usage) |u| {
            usage_total.add(u);
            deps_run.options.observer.emit(.{ .usage = u });
        }

        if (!turn.wantsTools()) {
            return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .completed,
            };
        }

        const last_msg = transcript.items()[transcript.items().len - 1];
        const calls = last_msg.tool_calls orelse {
            return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .completed,
            };
        };

        // Serial execution (H1): one tool at a time, call-list order.
        const registry = deps_run.toolset.registry();
        var call_index: u32 = 0;
        while (call_index < calls.len) : (call_index += 1) {
            if (isCancelled(deps_run.options)) {
                try finishRemainingCancelled(deps_run, transcript, calls[call_index..]);
                return .{
                    .final_text = last_text,
                    .turns = turns,
                    .usage = usage_total,
                    .stop_reason = .cancelled,
                };
            }

            const call = calls[call_index];
            try executeOneTool(deps_run, transcript, registry, call);
        }
    }

    return .{
        .final_text = last_text,
        .turns = turns,
        .usage = usage_total,
        .stop_reason = .max_turns,
    };
}

fn isCancelled(opts: Options) bool {
    const flag = opts.cancel orelse return false;
    return flag.isSet();
}

fn cancelledBody(gpa: std.mem.Allocator) RunError![]u8 {
    return tool_error.format(
        gpa,
        .cancelled,
        "run cancelled; pending tool did not execute. Resume or re-issue after checking transcript.",
    ) catch return error.OutOfMemory;
}

fn finishRemainingCancelled(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    remaining: []const message.ToolCall,
) RunError!void {
    for (remaining) |call| {
        const body = try cancelledBody(deps.tool_ctx.allocator);
        defer deps.tool_ctx.allocator.free(body);
        try finishTool(deps, transcript, call, body);
    }
}

fn executeOneTool(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    registry: tool.Registry,
    call: message.ToolCall,
) RunError!void {
    deps.options.observer.emit(.{ .tool_call = call });
    if (deps.options.trace) |tr| {
        tr.emitToolCall(call) catch |err| return mapTraceEmit(err);
    }

    // Unknown model-requested tool: soft-fail without name-based permission/jail.
    const found = registry.find(call.name) orelse {
        const body = registry.execute(deps.tool_ctx, call.name, call.arguments) catch
            return error.OutOfMemory;
        defer deps.tool_ctx.allocator.free(body);
        try finishTool(deps, transcript, call, body);
        return;
    };

    const desc = found.descriptor;
    const caps = desc.capabilities;

    // Single path extraction for permission + jail (no re-parse drift).
    // path_field tools: missing/non-string/malformed → soft invalid_arguments (handler never runs).
    const path_owned = workspace.pathFromDescriptor(
        deps.tool_ctx.allocator,
        caps,
        call.arguments,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => {
            try softInvalidArguments(deps, transcript, call, "path");
            return;
        },
    };
    defer if (path_owned) |p| deps.tool_ctx.allocator.free(p);

    const outcome = deps.options.permission_gate.check(desc, call.arguments, path_owned);
    const allowed = outcome.decision == .allow;
    deps.options.observer.emit(.{
        .permission = .{
            .tool_name = call.name,
            .allowed = allowed,
            .remembered = outcome.remembered,
            .risk = caps.risk.name(),
        },
    });
    if (deps.options.trace) |tr| {
        tr.emitPermission(call.name, caps.risk.name(), allowed, outcome.remembered) catch |err| return mapTraceEmit(err);
    }

    if (!allowed) {
        const denied = if (outcome.plan_blocked)
            permissions.deniedMessageWithReason(deps.tool_ctx.allocator, call.name, .plan_mode) catch
                return error.OutOfMemory
        else
            permissions.deniedMessage(deps.tool_ctx.allocator, call.name) catch
                return error.OutOfMemory;
        defer deps.tool_ctx.allocator.free(denied);
        try finishTool(deps, transcript, call, denied);
        return;
    }

    if (caps.workspace.usesPath()) {
        // path_owned is required when path_field is declared (validated above).
        const path = path_owned orelse {
            try softInvalidArguments(deps, transcript, call, "path");
            return;
        };
        if (try pathJailCheckOwned(deps, call.name, path)) |deny_body| {
            defer deps.tool_ctx.allocator.free(deny_body);
            try finishTool(deps, transcript, call, deny_body);
            return;
        }
    }

    if (caps.shell == .command_argument) {
        // Required command string; missing/non-string → soft invalid_arguments (handler never runs).
        const command = tool.requireStringField(deps.tool_ctx.allocator, call.arguments, "command") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArguments, error.ToolFailed => {
                try softInvalidArguments(deps, transcript, call, "command");
                return;
            },
        };
        defer deps.tool_ctx.allocator.free(command);

        if (shell_policy.check(deps.options.shell_policy, command) == .deny) {
            if (deps.options.trace) |tr| {
                tr.emitShellDeny(command) catch |err| return mapTraceEmit(err);
            }
            if (deps.options.observer.on_event != null) {
                std.log.warn("shell policy deny: {s}", .{command});
            }
            const deny_body = shell_policy.deniedMessage(deps.tool_ctx.allocator, command) catch
                return error.OutOfMemory;
            defer deps.tool_ctx.allocator.free(deny_body);
            try finishTool(deps, transcript, call, deny_body);
            return;
        }
    }

    const raw = registry.executeTool(deps.tool_ctx, found, call.arguments) catch
        return error.OutOfMemory;
    defer deps.tool_ctx.allocator.free(raw);
    try finishTool(deps, transcript, call, raw);
}

fn softInvalidArguments(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    call: message.ToolCall,
    field: []const u8,
) RunError!void {
    const detail = std.fmt.allocPrint(
        deps.tool_ctx.allocator,
        "invalid arguments for '{s}': missing or non-string required field '{s}'",
        .{ call.name, field },
    ) catch return error.OutOfMemory;
    defer deps.tool_ctx.allocator.free(detail);
    const body = tool_error.format(deps.tool_ctx.allocator, .invalid_arguments, detail) catch
        return error.OutOfMemory;
    defer deps.tool_ctx.allocator.free(body);
    try finishTool(deps, transcript, call, body);
}

fn buildRequestControl(opts: Options) zt.RequestControl {
    var control = zt.RequestControl.withTimeoutMs(zt.monoNowNs(), opts.provider_timeout_ms);
    if (opts.cancel) |flag| {
        control = control.withCancel(flag);
    }
    return control;
}

/// Chat outcome that may be a clean cancel/timeout Result rather than ProviderFailed.
const ChatOutcome = union(enum) {
    turn: message.AssistantTurn,
    cancelled: void,
    timeout: void,
    unsupported_control: void,
};

fn chatWithRetry(
    deps: Deps,
    scratch: std.mem.Allocator,
    messages: []const message.Message,
) RunError!ChatOutcome {
    const defs = tool.Registry.definitions(
        deps.toolset.registry(),
        scratch,
    ) catch return error.OutOfMemory;

    // One end-to-end control for all attempts (deadline not reset per retry).
    const control = buildRequestControl(deps.options);

    const max_attempts: u32 = @as(u32, deps.options.chat_retries) + 1;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        // Fail fast if budget already spent or cancel requested between attempts.
        control.checkNow() catch |e| switch (e) {
            error.Cancelled => return .{ .cancelled = {} },
            error.Timeout => return .{ .timeout = {} },
        };

        const result = deps.provider.chat(
            scratch,
            messages,
            defs,
            control,
        );
        if (result) |turn| {
            return .{ .turn = turn };
        } else |err| {
            switch (err) {
                error.Cancelled => return .{ .cancelled = {} },
                error.Timeout => return .{ .timeout = {} },
                error.UnsupportedControl, error.NotSupported => return .{ .unsupported_control = {} },
                else => {},
            }
            const retryable = zt.isRetryableError(err);
            const more = attempt + 1 < max_attempts;
            if (!retryable or !more) return error.ProviderFailed;

            // Overflow-safe delay, clamped to remaining deadline, sliced ≤25ms.
            var delay_ms = retryDelayMsSaturating(deps.options.retry_base_delay_ms, attempt);
            if (control.remainingMs(zt.monoNowNs())) |rem| {
                if (rem == 0) return .{ .timeout = {} };
                delay_ms = @min(delay_ms, rem);
            }

            if (deps.options.trace) |tr| {
                tr.emitProviderRetry(attempt + 1, @errorName(err)) catch |terr| return mapTraceEmit(terr);
            }
            if (deps.options.observer.on_event != null) {
                std.log.warn(
                    "provider retry {d}/{d} after {s}",
                    .{ attempt + 1, deps.options.chat_retries, @errorName(err) },
                );
            }
            sleepSliced(deps.tool_ctx.io, delay_ms, control) catch |se| switch (se) {
                error.Cancelled => return .{ .cancelled = {} },
                error.Timeout => return .{ .timeout = {} },
            };
        }
    }
    return error.ProviderFailed;
}

fn retryDelayMsSaturating(base_ms: u64, attempt: u32) u64 {
    const shift: u6 = @intCast(@min(attempt, 4));
    const factor: u64 = @as(u64, 1) << shift;
    return std.math.mul(u64, base_ms, factor) catch std.math.maxInt(u64);
}

/// Short-sliced sleep so cancel is observed promptly during long backoff.
fn sleepSliced(io: std.Io, delay_ms: u64, control: zt.RequestControl) error{ Cancelled, Timeout }!void {
    const slice_ms: u64 = 25;
    var left = delay_ms;
    while (left > 0) {
        control.checkNow() catch |e| return e;
        const step = @min(left, slice_ms);
        const ns: i96 = @intCast(@as(u64, step) *% std.time.ns_per_ms);
        const duration: std.Io.Duration = .{ .nanoseconds = ns };
        std.Io.sleep(io, duration, .real) catch {
            if (control.isCancelled()) return error.Cancelled;
        };
        left -|= step;
    }
    control.checkNow() catch |e| return e;
}

fn finishTool(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    call: message.ToolCall,
    body: []const u8,
) RunError!void {
    deps.options.observer.emit(.{
        .tool_result = .{ .name = call.name, .body = body },
    });
    if (deps.options.trace) |tr| {
        tr.emitToolResult(call.name, body) catch |err| return mapTraceEmit(err);
    }
    try transcript.appendToolResult(call.id, body);
}

/// Jail check on an already-extracted path (lexical + real containment).
/// Returns owned deny message, or null if path is OK for the handler to proceed.
/// Ordinary `NotFound` is allowed through — handlers report ToolFailed, not jail_deny.
fn pathJailCheckOwned(
    deps: Deps,
    tool_name: []const u8,
    path: []const u8,
) RunError!?[]u8 {
    var guard = workspace.guardFrom(
        deps.tool_ctx.allocator,
        deps.tool_ctx.io,
        deps.tool_ctx.cwd,
        deps.tool_ctx.workspace_root_real,
    ) catch {
        return @as(?[]u8, try emitJailDeny(deps, tool_name, path));
    };
    defer guard.deinit(deps.tool_ctx.allocator);

    // Pre-handler gate: lexical + existing-target containment when the path
    // already resolves. Missing paths pass (create tools need them; read tools
    // fail later). Escaping/dangling symlinks deny.
    guard.checkExisting(deps.tool_ctx.io, deps.tool_ctx.cwd, path) catch |err| switch (err) {
        error.NotFound => {
            // Still enforce create-style ancestor walk so escaping parents cannot
            // sneak past the loop gate for write tools. Read tools get NotFound.
            guard.checkCreate(
                deps.tool_ctx.allocator,
                deps.tool_ctx.io,
                deps.tool_ctx.cwd,
                path,
            ) catch |cerr| switch (cerr) {
                error.NotFound => {},
                error.OutOfMemory => return error.OutOfMemory,
                error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
                    return @as(?[]u8, try emitJailDeny(deps, tool_name, path));
                },
            };
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
            return @as(?[]u8, try emitJailDeny(deps, tool_name, path));
        },
    };
    return null;
}

fn emitJailDeny(deps: Deps, tool_name: []const u8, path: []const u8) RunError![]u8 {
    if (deps.options.trace) |tr| {
        tr.emitJailDeny(tool_name, path) catch |err| return mapTraceEmit(err);
    }
    if (deps.options.observer.on_event != null) {
        std.log.warn("jail deny {s} path={s}", .{ tool_name, path });
    }
    return workspace.deniedMessage(deps.tool_ctx.allocator, path) catch return error.OutOfMemory;
}

fn readOnlyDesc(name: []const u8) zt.ToolDescriptor {
    return .{
        .definition = .{ .name = name, .description = "", .parameters_json = "{\"type\":\"object\"}" },
        .capabilities = .{
            .risk = .read,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
    };
}

fn writeDesc(name: []const u8) zt.ToolDescriptor {
    return .{
        .definition = .{ .name = name, .description = "", .parameters_json = "{\"type\":\"object\"}" },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
    };
}

test "loop stops when model returns text only" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), result.turns);
}

test "permission deny yields tool error without executing" {
    const gpa = std.testing.allocator;

    const WriteStub = struct {
        fn handle(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    };
    const tools = [_]tool.Tool{tool.stateless(writeDesc("write_file"), WriteStub.handle)};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"x\",\"content\":\"y\"}"),
                };
                return .{
                    .content = "",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            _ = messages;
            return .{
                .content = try arena.dupe(u8, "understood, not writing"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write something");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{
            .permission_gate = .denyAllDangerous(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("understood, not writing", result.final_text);
    var found_deny = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) {
            found_deny = true;
        }
    }
    try std.testing.expect(found_deny);
}

test "jail deny absolute path without writing" {
    const gpa = std.testing.allocator;

    const ReadStub = struct {
        fn handle(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    };
    const tools = [_]tool.Tool{tool.stateless(readOnlyDesc("read_file"), ReadStub.handle)};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"/etc/passwd\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "blocked"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read passwd");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expectEqualStrings("blocked", result.final_text);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .jail_deny)) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "cancel after chat completes open tool pairs" {
    // Goal: chat returns two tool_calls; cancel before tools → both get cancelled bodies.
    const gpa = std.testing.allocator;

    const Mock = struct {
        calls: u32 = 0,
        cancel_ptr: *cancel_mod.Flag,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            // Request cancel after the model has "spoken" with tool_calls.
            self.cancel_ptr.request();
            const tc = try arena.alloc(message.ToolCall, 2);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "list_dir"),
                .arguments = try arena.dupe(u8, "{\"path\":\".\"}"),
            };
            tc[1] = .{
                .id = try arena.dupe(u8, "c2"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = try arena.dupe(u8, "{\"path\":\"build.zig\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };

    var cancel_flag: cancel_mod.Flag = .{};
    var mock: Mock = .{ .cancel_ptr = &cancel_flag };
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("explore");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{
            .permission_gate = .yolo(),
            .cancel = &cancel_flag,
        },
    }, &transcript);

    try std.testing.expect(result.stop_reason == .cancelled);
    try std.testing.expect(result.turns == 1);

    var cancelled_tools: u32 = 0;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .cancelled)) {
            cancelled_tools += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), cancelled_tools);
}

test "tools execute serially in call order" {
    // Goal / policy: H1 keeps tool execution serial. Assert result order matches
    // call order. Parallel read-only is L3 — not implemented here.
    const gpa = std.testing.allocator;

    const Echo = struct {
        fn handle(ctx: tool.Context, _: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
            const label = try tool.requireStringField(ctx.allocator, arguments_json, "label");
            defer ctx.allocator.free(label);
            return std.fmt.allocPrint(ctx.allocator, "ok:{s}", .{label}) catch return error.OutOfMemory;
        }
    };

    const tools = [_]tool.Tool{tool.stateless(.{
        .definition = .{
            .name = "echo",
            .description = "echo",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
    }, Echo.handle)};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 3);
            tc[0] = .{
                .id = try arena.dupe(u8, "a"),
                .name = try arena.dupe(u8, "echo"),
                .arguments = try arena.dupe(u8, "{\"label\":\"1\"}"),
            };
            tc[1] = .{
                .id = try arena.dupe(u8, "b"),
                .name = try arena.dupe(u8, "echo"),
                .arguments = try arena.dupe(u8, "{\"label\":\"2\"}"),
            };
            tc[2] = .{
                .id = try arena.dupe(u8, "c"),
                .name = try arena.dupe(u8, "echo"),
                .arguments = try arena.dupe(u8, "{\"label\":\"3\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };

    // Second chat: model finishes after seeing ordered results.
    const Mock2 = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            msgs: []const message.Message,
            defs: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) return Mock.chat(ptr, arena, msgs, defs, .{});
            // Verify tool results arrived as 1,2,3 in transcript order.
            var labels: [3]?[]const u8 = .{ null, null, null };
            var li: usize = 0;
            for (msgs) |m| {
                if (m.role == .tool) {
                    if (li < 3) {
                        labels[li] = m.content;
                        li += 1;
                    }
                }
            }
            if (li != 3) return error.InvalidResponse;
            if (!std.mem.eql(u8, labels[0].?, "ok:1")) return error.InvalidResponse;
            if (!std.mem.eql(u8, labels[1].?, "ok:2")) return error.InvalidResponse;
            if (!std.mem.eql(u8, labels[2].?, "ok:3")) return error.InvalidResponse;
            return .{
                .content = try arena.dupe(u8, "ordered"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock2 = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock2.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("echo three");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expectEqualStrings("ordered", result.final_text);
    try std.testing.expect(result.stop_reason == .completed);
}

test "custom write tool denied by denyAllDangerous" {
    const gpa = std.testing.allocator;

    const Mut = struct {
        ran: bool = false,
        fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return ctx.allocator.dupe(u8, "should-not-run") catch return error.OutOfMemory;
        }
    };
    var mut: Mut = .{};
    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "custom_mutate",
            .description = "dangerous custom",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &mut,
        .handler = Mut.handle,
    })};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "custom_mutate"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"x.txt\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "denied ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("mutate");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .denyAllDangerous() },
    }, &transcript);

    try std.testing.expectEqualStrings("denied ok", result.final_text);
    try std.testing.expect(!mut.ran);
    var denied = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) denied = true;
    }
    try std.testing.expect(denied);
}

test "stateful tool increments instance without globals" {
    const gpa = std.testing.allocator;

    const Counter = struct {
        n: u32 = 0,
        fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.n += 1;
            return std.fmt.allocPrint(ctx.allocator, "n={d}", .{self.n}) catch return error.OutOfMemory;
        }
    };
    var counter: Counter = .{};
    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "tick",
            .description = "counter",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &counter,
        .handler = Counter.handle,
    })};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls <= 2) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, if (self.calls == 1) "a" else "b"),
                    .name = try arena.dupe(u8, "tick"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("tick twice");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 2), counter.n);
}

test "missing capabilities cannot enter run; invalid toolset skips provider" {
    const gpa = std.testing.allocator;

    // Registration boundary rejects missing capabilities.
    const noop = struct {
        fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    }.h;
    try std.testing.expectError(error.MissingCapabilities, tool.buildTool(gpa, .{
        .definition = .{
            .name = "bad",
            .description = "",
            .parameters_json = "{}",
        },
        .capabilities = null,
        .handler = noop,
    }));

    // Duplicate toolset fails before provider (call count stays 0).
    const t = try tool.buildTool(gpa, .{
        .definition = .{
            .name = "dup",
            .description = "",
            .parameters_json = "{}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .handler = noop,
    });
    const tools = [_]tool.Tool{ t, t };

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return error.Unexpected;
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const err = run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);
    try std.testing.expectError(error.InvalidToolset, err);
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
}

test "custom path tool jails without built-in name" {
    const gpa = std.testing.allocator;

    const PathTool = struct {
        fn handle(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    };
    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "my_path_reader",
            .description = "custom",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .handler = PathTool.handle,
    })};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "my_path_reader"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"../escape\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "jailed"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("escape");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expectEqualStrings("jailed", result.final_text);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .jail_deny)) found = true;
    }
    try std.testing.expect(found);
}

test "provider receives definitions only (no risk field)" {
    const gpa = std.testing.allocator;

    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "secret_write",
            .description = "d",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .cooperative,
            .shell = .none,
        },
        .handler = struct {
            fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                return error.ToolFailed;
            }
        }.h,
    })};

    const Mock = struct {
        saw: bool = false,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            defs: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.saw = true;
            if (defs.len != 1) return error.InvalidResponse;
            if (!std.mem.eql(u8, defs[0].name, "secret_write")) return error.InvalidResponse;
            // Serialize definition shape and ensure local capability tokens absent.
            var out: std.Io.Writer.Allocating = .init(arena);
            var s: std.json.Stringify = .{ .writer = &out.writer };
            s.write(.{
                .name = defs[0].name,
                .description = defs[0].description,
                .parameters_json = defs[0].parameters_json,
            }) catch return error.InvalidResponse;
            const body = out.written();
            // Capability / policy tokens must not appear in model-facing serialization.
            if (std.mem.indexOf(u8, body, "\"risk\"") != null) return error.InvalidResponse;
            if (std.mem.indexOf(u8, body, "capabilities") != null) return error.InvalidResponse;
            if (std.mem.indexOf(u8, body, "cooperative") != null) return error.InvalidResponse;
            if (std.mem.indexOf(u8, body, "path_field") != null) return error.InvalidResponse;
            if (std.mem.indexOf(u8, body, "command_argument") != null) return error.InvalidResponse;
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);

    try std.testing.expect(mock.saw);
    try std.testing.expectEqualStrings("ok", result.final_text);
}

test "unknown model tool soft-fails without permission inference" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "totally_unknown"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "soft"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("call unknown");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .denyAllDangerous() },
    }, &transcript);

    try std.testing.expectEqualStrings("soft", result.final_text);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .unknown_tool)) found = true;
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(found);
}

test "forged invalid capabilities skip provider" {
    const gpa = std.testing.allocator;
    const noop = struct {
        fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    }.h;

    // Direct Tool literal with empty path_field — not via buildTool.
    const forged: tool.Tool = .{
        .descriptor = .{
            .definition = .{ .name = "forged_path", .description = "", .parameters_json = "{}" },
            .capabilities = .{
                .risk = .read,
                .workspace = .{ .path_field = "" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .handler = noop,
    };
    try std.testing.expectError(error.InvalidCapabilities, tool.validateTools(gpa, &[_]tool.Tool{forged}));

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return error.Unexpected;
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    try std.testing.expectError(error.InvalidToolset, run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &[_]tool.Tool{forged} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript));
    try std.testing.expectEqual(@as(u32, 0), mock.calls);

    // shell/risk mismatch also blocked.
    const shell_read: tool.Tool = .{
        .descriptor = .{
            .definition = .{ .name = "bad_shell", .description = "", .parameters_json = "{}" },
            .capabilities = .{
                .risk = .read,
                .workspace = .none,
                .cancellation = .none,
                .shell = .command_argument,
            },
        },
        .handler = noop,
    };
    mock.calls = 0;
    try std.testing.expectError(error.InvalidToolset, run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &[_]tool.Tool{shell_read} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript));
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
}

test "custom path tool missing path soft invalid_arguments without handler" {
    const gpa = std.testing.allocator;

    const PathTool = struct {
        ran: bool = false,
        fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };
    var state: PathTool = .{};
    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "my_path_reader",
            .description = "custom",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &state,
        .handler = PathTool.handle,
    })};

    const cases = [_][]const u8{
        "{}",
        "{\"path\":1}",
        "not-json",
        "[]",
    };

    for (cases) |args| {
        state.ran = false;
        const Mock = struct {
            calls: u32 = 0,
            args: []const u8,
            fn chat(
                ptr: *anyopaque,
                arena: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.calls += 1;
                if (self.calls == 1) {
                    const tc = try arena.alloc(message.ToolCall, 1);
                    tc[0] = .{
                        .id = try arena.dupe(u8, "c1"),
                        .name = try arena.dupe(u8, "my_path_reader"),
                        .arguments = try arena.dupe(u8, self.args),
                    };
                    return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
                }
                return .{
                    .content = try arena.dupe(u8, "soft"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
        };
        var mock: Mock = .{ .args = args };
        const provider = provider_mod.Provider{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        };
        var arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer arena_impl.deinit();
        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        try transcript.appendUser("x");
        const result = try run(.{
            .gpa = gpa,
            .provider = provider,
            .toolset = .{ .tools = &tools },
            .tool_ctx = .{
                .allocator = gpa,
                .io = std.testing.io,
                .cwd = std.Io.Dir.cwd(),
            },
            .options = .{ .permission_gate = .yolo() },
        }, &transcript);
        try std.testing.expectEqualStrings("soft", result.final_text);
        try std.testing.expect(!state.ran);
        var found = false;
        for (transcript.items()) |m| {
            if (m.role == .tool and tool_error.hasCode(m.content, .invalid_arguments)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "custom shell tool policy is descriptor driven not name" {
    const gpa = std.testing.allocator;

    const ShellTool = struct {
        ran: bool = false,
        fn handle(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            const cmd = try tool.requireStringField(ctx.allocator, arguments_json, "command");
            defer ctx.allocator.free(cmd);
            self.ran = true;
            return std.fmt.allocPrint(ctx.allocator, "ran:{s}", .{cmd}) catch return error.OutOfMemory;
        }
    };
    var state: ShellTool = .{};

    // Intentionally not named run_shell — policy comes from shell=.command_argument.
    const tools = [_]tool.Tool{try tool.buildTool(gpa, .{
        .definition = .{
            .name = "my_exec",
            .description = "custom shell",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .execute,
            .workspace = .none,
            .cancellation = .none,
            .shell = .command_argument,
        },
        .instance = &state,
        .handler = ShellTool.handle,
    })};

    const Case = struct {
        args: []const u8,
        expect_code: []const u8,
        expect_ran: bool,
    };
    const cases = [_]Case{
        .{ .args = "{}", .expect_code = "invalid_arguments", .expect_ran = false },
        .{ .args = "{\"command\":1}", .expect_code = "invalid_arguments", .expect_ran = false },
        .{ .args = "{\"command\":\"rm -rf /\"}", .expect_code = "shell_deny", .expect_ran = false },
        .{ .args = "{\"command\":\"echo ok\"}", .expect_code = "", .expect_ran = true },
    };

    for (cases) |c| {
        state.ran = false;
        const Mock = struct {
            calls: u32 = 0,
            args: []const u8,
            fn chat(
                ptr: *anyopaque,
                arena: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.calls += 1;
                if (self.calls == 1) {
                    const tc = try arena.alloc(message.ToolCall, 1);
                    tc[0] = .{
                        .id = try arena.dupe(u8, "c1"),
                        .name = try arena.dupe(u8, "my_exec"),
                        .arguments = try arena.dupe(u8, self.args),
                    };
                    return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
                }
                return .{
                    .content = try arena.dupe(u8, "done"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
        };
        var mock: Mock = .{ .args = c.args };
        const provider = provider_mod.Provider{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        };
        var arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer arena_impl.deinit();
        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        try transcript.appendUser("shell");
        const result = try run(.{
            .gpa = gpa,
            .provider = provider,
            .toolset = .{ .tools = &tools },
            .tool_ctx = .{
                .allocator = gpa,
                .io = std.testing.io,
                .cwd = std.Io.Dir.cwd(),
            },
            .options = .{
                .permission_gate = .yolo(),
                .shell_policy = .protect,
            },
        }, &transcript);
        try std.testing.expectEqualStrings("done", result.final_text);
        try std.testing.expect(state.ran == c.expect_ran);
        if (c.expect_code.len > 0) {
            var found = false;
            for (transcript.items()) |m| {
                if (m.role == .tool and std.mem.indexOf(u8, m.content, c.expect_code) != null) found = true;
            }
            try std.testing.expect(found);
        } else {
            var found_ok = false;
            for (transcript.items()) |m| {
                if (m.role == .tool and std.mem.indexOf(u8, m.content, "ran:echo ok") != null) found_ok = true;
            }
            try std.testing.expect(found_ok);
        }
    }
}

test "h-provider-001: provider Timeout becomes stop_reason timeout" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return error.Timeout;
        }
    };
    const provider = provider_mod.Provider{
        .ptr = undefined,
        .vtable = &.{ .chat = Mock.chat },
    };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .chat_retries = 2 },
    }, &transcript);
    try std.testing.expect(result.stop_reason == .timeout);
    // Partial assistant never appended
    try std.testing.expectEqual(@as(usize, 1), transcript.items().len);
}

test "h-provider-001: provider Cancelled becomes stop_reason cancelled" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return error.Cancelled;
        }
    };
    const provider = provider_mod.Provider{
        .ptr = undefined,
        .vtable = &.{ .chat = Mock.chat },
    };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{},
    }, &transcript);
    try std.testing.expect(result.stop_reason == .cancelled);
    try std.testing.expectEqual(@as(usize, 1), transcript.items().len);
}

test "h-provider-001: Timeout is not retried as generic provider failure" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return error.Timeout;
        }
    };
    var calls: u32 = 0;
    var mock: Mock = .{ .calls = &calls };
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .chat_retries = 5 },
    }, &transcript);
    try std.testing.expect(result.stop_reason == .timeout);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "h-provider-001: control reaches provider chat" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        saw_cancel: *bool,
        flag: *cancel_mod.Flag,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            control: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.saw_cancel.* = control.cancel != null and control.cancel.?.isSet() == false;
            // Flag pointer identity: same cancel flag threaded through.
            self.saw_cancel.* = control.cancel == self.flag;
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var flag: cancel_mod.Flag = .{};
    var saw = false;
    var mock: Mock = .{ .saw_cancel = &saw, .flag = &flag };
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    _ = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .cancel = &flag },
    }, &transcript);
    try std.testing.expect(saw);
}
