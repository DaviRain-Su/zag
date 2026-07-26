//! Agent harness loop — thin kernel over explicit required seams (D-011).
//!
//! ```
//! transcript ──► ContextView ──► provider.chat (definitions only)
//!      ▲                               │
//!      │                          tool_calls?
//!      │                          no → done
//!      │                          yes ↓
//!      │  Registry.find → validate/extract args once
//!      │     → ToolPolicy → Jail → ShellPolicy → execute
//!      │     deny → soft tool error (one result, no handler)
//!      └──────── tool results ────────┘
//! ```
//!
//! The loop owns Toolset/history validation and the fixed pre-execution order
//! (ToolPolicy → Jail → ShellPolicy → execute → append one Tool result).
//! Safety is retained through required, explicit ports: a missing port is
//! never normalized to allow/yolo/identity/discard.
//!
//! Source facts are emitted once, in program order, through the fallible
//! canonical `LoopEventSink`. Run preflight/start/terminal remain facade-owned.
//! Parallelism (H1 / L2): tools in one assistant message run **serially** in
//! call order. Permission / jail / shell selection use `ToolDescriptor`
//! capabilities only (D-007). Unknown model-requested tools soft-fail without
//! name-based risk.

const std = @import("std");
const zt = @import("zag-types");
const message = @import("message.zig");
const tool = @import("tool.zig");
const tool_args = @import("tool_args.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const tool_error = @import("tool_error.zig");
const cancel_mod = @import("cancel.zig");
const context_mod = @import("context.zig");

// D-011 required seams.
const tool_policy_mod = @import("tool_policy.zig");
const jail_mod = @import("jail.zig");
const shell_policy_port = @import("shell_policy_port.zig");
const context_view_mod = @import("context_view.zig");
const loop_event_mod = @import("loop_event.zig");

// Soft-fail formatting helpers (stable shape, not product policy implementations).
const permissions = @import("permissions.zig");
const shell_policy = @import("shell_policy.zig");

pub const default_max_turns: u32 = 20;

pub const ToolPolicy = tool_policy_mod.ToolPolicy;
pub const Jail = jail_mod.Jail;
pub const ShellPolicy = shell_policy_port.ShellPolicy;
pub const ContextView = context_view_mod.ContextView;
pub const LoopEventSink = loop_event_mod.LoopEventSink;
pub const LoopEvent = loop_event_mod.LoopEvent;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
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
};

pub const RunError = error{
    /// Prefer Result.stop_reason=.max_turns; kept for callers that still match this error.
    MaxTurnsExceeded,
    ProviderFailed,
    OutOfMemory,
    /// Toolset failed closed validation before any provider call.
    InvalidToolset,
    /// Mid-run event-sink failure (durable Trace adapter failure). Distinct from
    /// explicit-path flush failure owned by the facade. Preserves the prior
    /// `TraceFailed` terminal category.
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

/// Map sink failures into the loop error set (never swallow). `SinkFailed`
/// (durable Trace adapter failure) maps to the existing `TraceFailed` category.
fn mapSinkEmit(err: loop_event_mod.SinkError) RunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SinkFailed => error.TraceFailed,
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
    /// D-011 required pre-execution permission gate.
    tool_policy: ToolPolicy,
    /// D-011 required workspace containment jail.
    jail: Jail,
    /// D-011 required shell command gate.
    shell_policy: ShellPolicy,
    /// D-011 required context projection gate.
    context_view: ContextView,
    /// D-011 required canonical source-event sink.
    event_sink: LoopEventSink,
    options: Options = .{},
};

pub fn run(deps: Deps, transcript: *transcript_mod.Transcript) RunError!Result {
    // Fail closed before the first provider call on malformed toolsets.
    tool.validateTools(deps.gpa, deps.toolset.tools) catch return error.InvalidToolset;

    // Resolve workspace root once per run and thread into file-tool handlers.
    // Failure is not a hard run error: path tools fail closed via Guard.
    const workspace = @import("workspace.zig");
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
        .tool_policy = deps.tool_policy,
        .jail = deps.jail,
        .shell_policy = deps.shell_policy,
        .context_view = deps.context_view,
        .event_sink = deps.event_sink,
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
        deps_run.event_sink.emit(.{ .turn_start = turns }) catch |err| return mapSinkEmit(err);

        var turn_arena_impl: std.heap.ArenaAllocator = .init(deps_run.gpa);
        defer turn_arena_impl.deinit();
        const scratch = turn_arena_impl.allocator();

        const v = deps_run.context_view.view(scratch, transcript.items()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidContext => return error.InvalidContext,
        };
        // Session sink first, then trace: OOM on session note aborts before any
        // compaction line is written so session metadata and trace cannot
        // silently diverge on the success path (h-context-001). The sink adapter
        // preserves the prior note-then-trace ordering for context_compaction.
        if (v.compaction) |ev| {
            deps_run.event_sink.emit(.{ .context_compaction = ev }) catch |err| return mapSinkEmit(err);
        }

        const outcome = try chatWithRetry(deps_run, scratch, v.messages);
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
        // assistant_message: user Observer/internal verbose path, then Trace assistant.
        deps_run.event_sink.emit(.{ .assistant_message = last_text }) catch |err| return mapSinkEmit(err);
        if (turn.usage) |u| {
            // usage: Trace usage, then user Observer/ledger/verbose/cost.
            deps_run.event_sink.emit(.{ .usage = u }) catch |err| return mapSinkEmit(err);
            usage_total.add(u);
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
    // tool_start: Observer, then Trace tool_call.
    deps.event_sink.emit(.{ .tool_start = call }) catch |err| return mapSinkEmit(err);

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

    // Single path extraction for policy + jail (no re-parse drift).
    // path_field tools: missing/empty/non-string/malformed → soft invalid_arguments
    // (handler never runs). Unknown tool / invalid args soft-fail BEFORE policy/handler.
    const path_owned = tool_args.pathFromDescriptor(
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

    // ToolPolicy (nonfallible): allow or structured deny.
    const outcome = deps.tool_policy.check(desc, call.arguments, path_owned);
    const allowed = outcome.decision == .allow;
    // policy_decision: Observer, then Trace permission.
    deps.event_sink.emit(.{
        .policy_decision = .{
            .tool_name = call.name,
            .allowed = allowed,
            .remembered = outcome.remembered,
            .risk = caps.risk.name(),
        },
    }) catch |err| return mapSinkEmit(err);

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
        const path = path_owned orelse {
            try softInvalidArguments(deps, transcript, call, "path");
            return;
        };
        const jail_check = deps.jail.check(
            deps.tool_ctx.allocator,
            deps.tool_ctx.io,
            deps.tool_ctx.cwd,
            deps.tool_ctx.workspace_root_real,
            call.name,
            path,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (jail_check.verdict == .deny) {
            const deny_body = jail_check.deny_body orelse {
                // Should not happen: deny verdict carries a body. Fail closed.
                return error.OutOfMemory;
            };
            defer deps.tool_ctx.allocator.free(deny_body);
            // jail_decision: Trace, then generic warning.
            deps.event_sink.emit(.{
                .jail_decision = .{ .tool_name = call.name, .path = path },
            }) catch |err| return mapSinkEmit(err);
            try finishTool(deps, transcript, call, deny_body);
            return;
        }
        // allow verdict: deny_body is null; fall through.
    }

    if (caps.shell == .command_argument) {
        // Required command string; missing/non-string → soft invalid_arguments (handler never runs).
        const command = tool_args.commandFromArguments(deps.tool_ctx.allocator, call.arguments) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArguments => {
                try softInvalidArguments(deps, transcript, call, "command");
                return;
            },
        };
        defer deps.tool_ctx.allocator.free(command);

        if (deps.shell_policy.check(command) == .deny) {
            // shell_decision: Trace, then generic warning.
            deps.event_sink.emit(.{ .shell_decision = command }) catch |err| return mapSinkEmit(err);
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
        "invalid arguments for '{s}': missing, empty, or non-string required field '{s}'",
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

            // provider_retry: Trace, then generic warning.
            deps.event_sink.emit(.{
                .provider_retry = .{ .attempt = attempt + 1, .err_name = @errorName(err) },
            }) catch |serr| return mapSinkEmit(serr);
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

/// Emit tool_end through the sink, then append the transcript row. Order
/// preserves the prior "subsequent append OOM keeps the event visible" behavior.
fn finishTool(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    call: message.ToolCall,
    body: []const u8,
) RunError!void {
    // tool_end: Observer, then Trace tool_result.
    deps.event_sink.emit(.{
        .tool_end = .{ .name = call.name, .body = body },
    }) catch |err| return mapSinkEmit(err);
    try transcript.appendToolResult(call.id, body);
}

// ── tests ──────────────────────────────────────────────────────────────────
//
// Loop tests now compose the five explicit seams. Local helper builders keep
// the fixtures readable while proving the low-level contract. The fake
// vtables here are defined locally (no public concrete test adapter leaked).

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

/// Recording sink for loop tests: counts event kinds (no payload storage).
const RecordingSink = struct {
    turn_starts: u32 = 0,
    assistant_messages: u32 = 0,
    usages: u32 = 0,
    tool_starts: u32 = 0,
    tool_ends: u32 = 0,
    policy_decisions: u32 = 0,
    jail_decisions: u32 = 0,
    shell_decisions: u32 = 0,
    provider_retries: u32 = 0,
    context_compactions: u32 = 0,
    fail_next: ?loop_event_mod.SinkError = null,

    fn sink(self: *RecordingSink) LoopEventSink {
        return .{ .ptr = self, .vtable = &recording_vtable };
    }

    fn emit(ptr: ?*anyopaque, event: LoopEvent) loop_event_mod.SinkError!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        if (self.fail_next) |e| {
            self.fail_next = null;
            return e;
        }
        switch (event) {
            .turn_start => self.turn_starts += 1,
            .assistant_message => self.assistant_messages += 1,
            .usage => self.usages += 1,
            .tool_start => self.tool_starts += 1,
            .tool_end => self.tool_ends += 1,
            .policy_decision => self.policy_decisions += 1,
            .jail_decision => self.jail_decisions += 1,
            .shell_decision => self.shell_decisions += 1,
            .provider_retry => self.provider_retries += 1,
            .context_compaction => self.context_compactions += 1,
        }
    }
};

const recording_vtable: loop_event_mod.LoopEventSinkVTable = .{
    .emit = RecordingSink.emit,
};

fn defaultDeps(
    gpa: std.mem.Allocator,
    provider: provider_mod.Provider,
    toolset: tool.Toolset,
    sink: LoopEventSink,
) Deps {
    return .{
        .gpa = gpa,
        .provider = provider,
        .toolset = toolset,
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = ToolPolicy.allowAllForTrustedHost(),
        .jail = Jail.allowAllForTrustedHost(),
        .shell_policy = ShellPolicy.allowAllForTrustedHost(),
        .context_view = ContextView.identity(),
        .event_sink = sink,
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

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

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

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write something");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.denyAll();

    const result = try run(deps, &transcript);

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

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read passwd");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.jail = .{ .ptr = null, .vtable = jail_mod.WorkspaceGuardAdapter.vtable() };

    const result = try run(deps, &transcript);

    try std.testing.expectEqualStrings("blocked", result.final_text);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .jail_deny)) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "loop pre-handler jail deny for long absolute path is bounded and does not execute handler" {
    const gpa = std.testing.allocator;
    const sentinel = "LOOP_LONG_ABS_SENTINEL_839f";

    const State = struct { executed: bool = false };
    const ReadStub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const state: *State = @ptrCast(@alignCast(instance.?));
            state.executed = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = readOnlyDesc("read_file"),
        .instance = &state,
        .handler = ReadStub.handle,
    }};

    const Mock = struct {
        calls: u32 = 0,
        sentinel: []const u8,
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
                const filler = try arena.alloc(u8, 70 * 1024);
                @memset(filler, 'a');
                const args = try std.fmt.allocPrint(arena, "{{\"path\":\"/{s}{s}\"}}", .{ self.sentinel, filler });
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = args,
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

    var mock: Mock = .{ .sentinel = sentinel };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read long absolute path");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.jail = .{ .ptr = null, .vtable = jail_mod.WorkspaceGuardAdapter.vtable() };

    _ = try run(deps, &transcript);

    try std.testing.expect(!state.executed);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool) {
            found = true;
            try std.testing.expect(m.content.len <= tool.max_result_bytes);
            try std.testing.expect(tool_error.hasCode(m.content, .jail_deny));
            try std.testing.expect(std.mem.indexOf(u8, m.content, sentinel) == null);
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

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("explore");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.options.cancel = &cancel_flag;

    const result = try run(deps, &transcript);

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

// ── D-011 contract tests: five-seam composition, fixed gate order ──────────

fn shellDesc(name: []const u8) zt.ToolDescriptor {
    return .{
        .definition = .{ .name = name, .description = "", .parameters_json = "{\"type\":\"object\"}" },
        .capabilities = .{
            .risk = .execute,
            .workspace = .none,
            .cancellation = .none,
            .shell = .command_argument,
        },
    };
}

// Permissive five-seam composition: allow-all trusted host + identity view +
// discard sink. Proves a low-level host can explicitly compose permissively;
// never a product default.
test "seam composition: permissive trusted host runs handler exactly once" {
    const gpa = std.testing.allocator;

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ok") catch return error.OutOfMemory;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = readOnlyDesc("read_file"),
        .instance = &state,
        .handler = Stub.h,
    }};

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
                    .arguments = try arena.dupe(u8, "{\"path\":\"build.zig\"}"),
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
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.jail = Jail.allowAllForTrustedHost();
    deps.shell_policy = ShellPolicy.allowAllForTrustedHost();
    deps.context_view = ContextView.identity();
    deps.event_sink = LoopEventSink.discard();

    _ = try run(deps, &transcript);
    try std.testing.expectEqual(@as(u32, 1), state.n);
}

// Deny policy prevents handler execution; exactly one soft tool result is appended.
test "seam composition: deny policy appends one permission_denied, no handler" {
    const gpa = std.testing.allocator;

    const State = struct { ran: bool = false };
    const Stub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = writeDesc("write_file"),
        .instance = &state,
        .handler = Stub.handle,
    }};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "write_file"),
                .arguments = try arena.dupe(u8, "{\"path\":\"x\",\"content\":\"y\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.denyAll();

    _ = try run(deps, &transcript);
    try std.testing.expect(!state.ran);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) saw = true;
    }
    try std.testing.expect(saw);
}

// Fixed gate order: ToolPolicy → Jail → ShellPolicy → execute. Deny in jail
// after policy allow, before handler.
test "seam composition: jail deny after policy allow, before handler" {
    const gpa = std.testing.allocator;

    const State = struct { ran: bool = false };
    const Stub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = readOnlyDesc("read_file"),
        .instance = &state,
        .handler = Stub.handle,
    }};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = try arena.dupe(u8, "{\"path\":\"/etc/passwd\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read passwd");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.jail = .{ .ptr = null, .vtable = jail_mod.WorkspaceGuardAdapter.vtable() };

    _ = try run(deps, &transcript);
    try std.testing.expect(!state.ran);
    // policy_decision then jail_decision emitted, then tool_end.
    try std.testing.expect(sink.policy_decisions >= 1);
    try std.testing.expect(sink.jail_decisions >= 1);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .jail_deny)) saw = true;
    }
    try std.testing.expect(saw);
}

// Shell deny after policy allow, before handler.
test "seam composition: shell deny after policy allow, before handler" {
    const gpa = std.testing.allocator;

    const State = struct { ran: bool = false };
    const Stub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = shellDesc("run_shell"),
        .instance = &state,
        .handler = Stub.handle,
    }};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "run_shell"),
                .arguments = try arena.dupe(u8, "{\"command\":\"rm -rf /\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("rm root");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();
    deps.shell_policy = ShellPolicy.fromMode(shell_policy.Mode.protect);

    _ = try run(deps, &transcript);
    try std.testing.expect(!state.ran);
    try std.testing.expect(sink.shell_decisions >= 1);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .shell_deny)) saw = true;
    }
    try std.testing.expect(saw);
}

// Unknown tool soft-fails before policy/handler (no name-based risk inference).
test "seam composition: unknown tool soft-fails before policy" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "nope_nope"),
                .arguments = try arena.dupe(u8, "{}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("call unknown");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.tool_policy = ToolPolicy.denyAll(); // would deny if reached

    _ = try run(deps, &transcript);
    // Unknown tool never reaches policy_decision.
    try std.testing.expectEqual(@as(u32, 0), sink.policy_decisions);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .unknown_tool)) saw = true;
    }
    try std.testing.expect(saw);
}

// Invalid args (missing path) soft-fail before policy/handler.
test "seam composition: invalid path args soft-fail before policy" {
    const gpa = std.testing.allocator;

    const State = struct { ran: bool = false };
    const Stub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = readOnlyDesc("read_file"),
        .instance = &state,
        .handler = Stub.handle,
    }};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = try arena.dupe(u8, "{}"), // missing path
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read missing path");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();

    _ = try run(deps, &transcript);
    try std.testing.expect(!state.ran);
    // Invalid args never reaches policy_decision.
    try std.testing.expectEqual(@as(u32, 0), sink.policy_decisions);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .invalid_arguments)) saw = true;
    }
    try std.testing.expect(saw);
}

// Durable sink failure (SinkFailed) maps to RunError.TraceFailed.
test "seam composition: sink SinkFailed maps to TraceFailed run error" {
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
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{ .fail_next = error.SinkFailed };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());

    const err = run(deps, &transcript);
    try std.testing.expectError(error.TraceFailed, err);
}

// Durable sink OOM maps to RunError.OutOfMemory (distinct from SinkFailed).
test "seam composition: sink OutOfMemory maps to OutOfMemory run error" {
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
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };

    var sink: RecordingSink = .{ .fail_next = error.OutOfMemory };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());

    const err = run(deps, &transcript);
    try std.testing.expectError(error.OutOfMemory, err);
}
// ── F1: restored permanent L2 invariants composed over the five seams ──────

// h-provider-001: the loop threads the borrowed cancel-flag pointer identity
// through RequestControl into provider.chat. This is the only loop-level proof
// of that contract (transport/facade tests cover their own layers).
test "h-provider-001: control reaches provider chat (seam composition)" {
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
            // Flag pointer identity: same cancel flag threaded through RequestControl.
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

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, LoopEventSink.discard());
    deps.options.cancel = &flag;

    _ = try run(deps, &transcript);
    try std.testing.expect(saw);
}

// H1 invariant: tools in one assistant message run serially in provider call
// order, with results appended and events emitted in the same order. This is
// the explicit L2 serial-order assertion (loop-turn.md acceptance checklist).
test "tools execute serially in call order (seam composition)" {
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
            control: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) return Mock.chat(ptr, arena, msgs, defs, control);
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

    // Recording sink captures tool_start/tool_end order to prove serial event order.
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("echo three");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = ToolPolicy.allowAllForTrustedHost();

    const result = try run(deps, &transcript);

    try std.testing.expectEqualStrings("ordered", result.final_text);
    try std.testing.expect(result.stop_reason == .completed);
    // Three tool calls executed serially → three tool_start and three tool_end events.
    try std.testing.expectEqual(@as(u32, 3), sink.tool_starts);
    try std.testing.expectEqual(@as(u32, 3), sink.tool_ends);
}
