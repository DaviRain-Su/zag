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
const protocol_history = @import("protocol_history.zig");

// D-011 required seams.
const tool_policy_mod = @import("tool_policy.zig");
const jail_mod = @import("jail.zig");
const shell_policy_mod = @import("shell_policy.zig");
const context_view_mod = @import("context_view.zig");
const loop_event_mod = @import("loop_event.zig");
const control_input_mod = @import("control_input.zig");

pub const default_max_turns: u32 = 20;

pub const ToolPolicy = tool_policy_mod.ToolPolicy;
pub const Jail = jail_mod.Jail;
pub const ShellPolicy = shell_policy_mod.ShellPolicy;
pub const ContextView = context_view_mod.ContextView;
pub const LoopEventSink = loop_event_mod.LoopEventSink;
pub const LoopEvent = loop_event_mod.LoopEvent;
pub const ControlInput = control_input_mod.ControlInput;

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
    /// harness-steering-001 required control seam. Low-level hosts write
    /// `.control_input = .none()` explicitly; product installs a Session adapter.
    /// No default — missing is a compile error, not a silent empty queue.
    control_input: ControlInput,
    options: Options = .{},
};

pub fn run(deps: Deps, transcript: *transcript_mod.Transcript) RunError!Result {
    // Fail closed before the first provider call on malformed toolsets.
    tool.validateTools(deps.gpa, deps.toolset.tools) catch return error.InvalidToolset;

    // The workspace root is resolved by the product facade (Agent.reply) and
    // threaded as a borrowed `tool_ctx.workspace_root_real` slice whose address/
    // bytes cover the entire synchronous `loop.run`. Core does not resolve the
    // workspace root itself — that is product-owned behavior. When null, file-tool
    // handlers / product jail adapters lazy-resolve from `cwd` (fail closed on error).
    const deps_run = deps;

    var turns: u32 = 0;
    var last_text: []const u8 = "";
    var usage_total: message.Usage = .{};
    // One-at-a-time: a boundary that injects control suppresses the immediately
    // following pre-turn poll so one control message feeds one provider turn.
    var suppress_pre_turn: bool = false;

    while (turns < deps_run.options.max_turns) {
        if (isCancelled(deps_run.options)) {
            return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .cancelled,
            };
        }

        // ── pre-turn boundary (cancel-before-peek) ──────────────────────────
        // `turns` is the completed count; the upcoming provider turn is turns+1.
        if (suppress_pre_turn) {
            suppress_pre_turn = false;
        } else {
            if (isCancelled(deps_run.options)) {
                return .{
                    .final_text = last_text,
                    .turns = turns,
                    .usage = usage_total,
                    .stop_reason = .cancelled,
                };
            }
            if (deps_run.control_input.peek(.pre_turn)) |item| {
                // Another provider turn is available (loop condition). next_turn
                // cannot overflow past max_turns.
                const next_turn = turns + 1;
                try applyOrdinaryControl(deps_run, transcript, item, next_turn);
            }
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
        // Independent Core gate: validate the protocol-visible body of the
        // projected view **before** any compaction fact is emitted or
        // Provider.chat, regardless of how the product ContextView built it
        // (D-011 core-context-ownership-001). The view may carry leading
        // system layers; those are skipped. This catches a hostile/malformed
        // ContextView that returns an invalid bundle even when the product
        // algorithm would have validated internally. A malformed projection is
        // not a "successfully accepted final view" — Session/Trace must not see
        // a compaction fact or advance generation before this gate passes.
        protocol_history.validateViewBody(v.messages) catch return error.InvalidContext;

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
        deps_run.event_sink.emit(.{ .assistant_message = .{
            .text = last_text,
            .has_tools = turn.wantsTools(),
            .reasoning = turn.reasoning,
        } }) catch |err| return mapSinkEmit(err);
        if (turn.usage) |u| {
            // usage: Trace usage, then user Observer/ledger/verbose/cost.
            deps_run.event_sink.emit(.{ .usage = u }) catch |err| return mapSinkEmit(err);
            usage_total.add(u);
        }

        if (!turn.wantsTools()) {
            // ── would-complete boundary ─────────────────────────────────────
            // Non-destructive atomic peek first. Empty → existing completed
            // without a new late-cancel classification. Non-null → recheck
            // cancel before append/commit; observed cancel wins and retains.
            const item = deps_run.control_input.peek(.would_complete);
            if (item == null) {
                return .{
                    .final_text = last_text,
                    .turns = turns,
                    .usage = usage_total,
                    .stop_reason = .completed,
                };
            }
            if (isCancelled(deps_run.options)) {
                return .{
                    .final_text = last_text,
                    .turns = turns,
                    .usage = usage_total,
                    .stop_reason = .cancelled,
                };
            }
            // Another provider turn available only when turns < max_turns.
            if (turns < deps_run.options.max_turns) {
                const next_turn = turns + 1;
                try applyOrdinaryControl(deps_run, transcript, item.?, next_turn);
                suppress_pre_turn = true;
                continue;
            }
            // Last turn: do not consume; host may inspect pending counts.
            return .{
                .final_text = last_text,
                .turns = turns,
                .usage = usage_total,
                .stop_reason = .max_turns,
            };
        }

        const last_msg = transcript.items()[transcript.items().len - 1];
        const calls = last_msg.tool_calls orelse {
            // No calls despite wantsTools — treat as would-complete empty.
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
        var steered_mid_batch = false;
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

            // Between-tools: only when another provider turn remains. On the
            // last turn, finish the Tool batch normally and leave steering queued.
            if (turns < deps_run.options.max_turns) {
                if (deps_run.control_input.peek(.between_tools)) |item| {
                    // Prepare before any steered side effect.
                    const remaining = calls[call_index..];
                    const reserve_rows = remaining.len + 1;
                    const prepared = transcript.prepareUser(item.text, reserve_rows) catch
                        return error.OutOfMemory;
                    try finishRemainingSteered(deps_run, transcript, remaining);
                    transcript.appendPreparedUser(prepared);
                    deps_run.control_input.commit(item.kind);
                    const next_turn = turns + 1;
                    // text is transcript-owned (last message content).
                    const applied_text = transcript.items()[transcript.items().len - 1].content;
                    deps_run.event_sink.emit(.{ .control_applied = .{
                        .kind = item.kind,
                        .next_turn = next_turn,
                        .text = applied_text,
                    } }) catch |err| return mapSinkEmit(err);
                    suppress_pre_turn = true;
                    steered_mid_batch = true;
                    break;
                }
            }

            const call = calls[call_index];
            try executeOneTool(deps_run, transcript, registry, call);
        }
        if (steered_mid_batch) continue;
        // After a normal Tool batch: return to outer pre-turn boundary.
    }

    return .{
        .final_text = last_text,
        .turns = turns,
        .usage = usage_total,
        .stop_reason = .max_turns,
    };
}

/// Ordinary (pre-turn / would-complete) apply: append user → commit → control_applied.
/// Append OOM does not commit and leaves the item pending.
fn applyOrdinaryControl(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    item: control_input_mod.Item,
    next_turn: u32,
) RunError!void {
    try transcript.appendUser(item.text);
    deps.control_input.commit(item.kind);
    const applied_text = transcript.items()[transcript.items().len - 1].content;
    deps.event_sink.emit(.{ .control_applied = .{
        .kind = item.kind,
        .next_turn = next_turn,
        .text = applied_text,
    } }) catch |err| return mapSinkEmit(err);
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

fn finishRemainingSteered(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    remaining: []const message.ToolCall,
) RunError!void {
    // End-only: no synthetic tool_start. Body is the stable steered string.
    for (remaining) |call| {
        try finishTool(deps, transcript, call, tool_error.steered_body);
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
        // ToolPolicy.deniedBody: fallible body renderer called only after deny.
        // Uses the caller's allocator; the loop frees the owned slice immediately.
        const denied = deps.tool_policy.deniedBody(
            deps.tool_ctx.allocator,
            desc,
            outcome,
        ) catch return error.OutOfMemory;
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
            // ShellPolicy.deniedBody: fallible body renderer called only after deny.
            const deny_body = deps.shell_policy.deniedBody(
                deps.tool_ctx.allocator,
                command,
            ) catch return error.OutOfMemory;
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

/// Context for the loop-owned delta handler: the event sink plus a latch for
/// the first sink failure (the handler itself is infallible `void`; the error
/// is propagated by chatWithRetry after the provider call returns — the sink
/// contract says emit errors stop the run, never swallow).
const DeltaEmitCtx = struct {
    sink: LoopEventSink,
    err: ?loop_event_mod.SinkError = null,
};

/// Loop-owned content/thinking-delta handler: forwards each delta to the
/// event sink. `reasoning_delta` null → content-only chunk (no thinking
/// event); non-null → emit `thinking_delta` (tui-thinking-streaming-001).
fn deltaHandler(ctx: *anyopaque, content_delta: []const u8, reasoning_delta: ?[]const u8) void {
    const self: *DeltaEmitCtx = @ptrCast(@alignCast(ctx));
    if (self.err != null) return; // first error wins; sink already failing
    if (content_delta.len > 0) {
        self.sink.emit(.{ .assistant_delta = content_delta }) catch |err| {
            self.err = err;
            return;
        };
    }
    if (reasoning_delta) |rd| {
        self.sink.emit(.{ .thinking_delta = rd }) catch |err| {
            self.err = err;
        };
    }
}

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

        // tui-streaming-001: use chat_stream whenever present (falls back to
        // chat — byte-identical — when the slot is absent). Deltas are emitted
        // synchronously, in-order, through the same event sink; a sink failure
        // during delta emission aborts the run like any other sink failure.
        const streaming_attempt = deps.provider.vtable.chat_stream != null;
        const result = if (deps.provider.vtable.chat_stream) |chat_stream| blk: {
            var emit_ctx = DeltaEmitCtx{ .sink = deps.event_sink };
            const r = chat_stream(
                deps.provider.ptr,
                scratch,
                messages,
                defs,
                control,
                deltaHandler,
                &emit_ctx,
            );
            if (emit_ctx.err) |serr| return mapSinkEmit(serr);
            break :blk r;
        } else deps.provider.chat(scratch, messages, defs, control);
        if (result) |turn| {
            return .{ .turn = turn };
        } else |err| {
            // Retry honesty (tui-streaming-001): erase any deltas the failed
            // attempt streamed — exactly once, before retry or terminal — so
            // retry garbage never accumulates in the UI. Guarded to streaming
            // attempts so a chat-only provider stays facade byte-identical.
            if (streaming_attempt) {
                deps.event_sink.emit(.{ .assistant_delta_clear = {} }) catch |serr| return mapSinkEmit(serr);
            }
            switch (err) {
                error.Cancelled => return .{ .cancelled = {} },
                error.Timeout => return .{ .timeout = {} },
                error.UnsupportedControl => return .{ .unsupported_control = {} },
                else => {},
            }
            const retryable = shouldRetry(err);
            const more = attempt + 1 < max_attempts;
            if (!retryable or !more) {
                // Surface the real ChatError tag once before collapsing to
                // ProviderFailed (stable @errorName only — never raw bodies).
                deps.event_sink.emit(.{
                    .provider_failed = .{ .err_name = @errorName(err) },
                }) catch |serr| return mapSinkEmit(serr);
                return error.ProviderFailed;
            }

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
    // Unreachable when max_attempts ≥ 1 (default); keep for empty budget edge.
    deps.event_sink.emit(.{
        .provider_failed = .{ .err_name = "ProviderFailed" },
    }) catch |serr| return mapSinkEmit(serr);
    return error.ProviderFailed;
}

/// Total retry decision table over every ChatError tag (m4-sampler-resilience-001).
///
/// Retryable: rate-limit (429/529 → ServerError class), 5xx, and transient
/// transport failures (HttpFailed network class, BadStatus, WriteFailed,
/// Unexpected, NotSupported, StreamFailed — hyper retries mid-stream).
/// Terminal: auth (401/403), BadRequest (invalid request), InvalidResponse
/// (fatal), Timeout (isRetryableError(Timeout)=false today AND the shared
/// end-to-end deadline makes retry meaningless), Cancelled,
/// UnsupportedControl, OutOfMemory (sink-level, never retried).
///
/// Cancelled / Timeout / UnsupportedControl return their clean ChatOutcome in
/// chatWithRetry before this table runs. Exhaustive over the closed ChatError
/// set — no else fallthrough: a tag added to ChatError without a prong here
/// is a compile error.
pub fn shouldRetry(err: zt.ChatError) bool {
    return switch (err) {
        error.HttpFailed, error.BadStatus, error.WriteFailed, error.Unexpected,
        error.StreamFailed, error.RateLimited, error.ServerError, error.NotSupported => true,
        error.InvalidResponse, error.OutOfMemory, error.AuthenticationFailed,
        error.PermissionDenied, error.Timeout, error.Cancelled, error.BadRequest,
        error.UnsupportedControl => false,
    };
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
        .tool_end = .{ .id = call.id, .name = call.name, .body = body },
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

/// Recording sink for loop tests: counts event kinds and captures last payload
/// values for correlation assertions (has_tools, tool_end id).
const RecordingSink = struct {
    turn_starts: u32 = 0,
    assistant_messages: u32 = 0,
    last_assistant_has_tools: bool = false,
    /// assistant_delta count / assistant_delta_clear count (tui-streaming-001).
    assistant_deltas: u32 = 0,
    delta_clears: u32 = 0,
    /// thinking_delta count (tui-thinking-streaming-001).
    thinking_deltas: u32 = 0,
    /// In-order delta-path tags: 'd' delta, 't' thinking delta, 'c' clear,
    /// 'm' assistant_message.
    delta_tags: [64]u8 = undefined,
    delta_tags_len: usize = 0,
    /// Captured delta content (copy made at emit time — proves borrowed
    /// slices were valid during emit even when the provider reuses a buffer).
    delta_buf: [512]u8 = undefined,
    delta_buf_len: usize = 0,
    /// Captured thinking-delta content (same borrow-validity discipline).
    think_buf: [256]u8 = undefined,
    think_buf_len: usize = 0,
    /// Captured assistant_message reasoning (copy made at emit time — the
    /// turn arena is freed when run() returns, so borrowed pointers must not
    /// survive the assertion).
    reason_buf: [128]u8 = undefined,
    reason_buf_len: usize = 0,
    last_reasoning_set: bool = false,
    /// OR of every assistant_message.has_tools (multi-turn runs may end text-only).
    any_assistant_has_tools: bool = false,
    usages: u32 = 0,
    tool_starts: u32 = 0,
    tool_ends: u32 = 0,
    last_tool_end_id: []const u8 = "",
    last_tool_end_body: []const u8 = "",
    policy_decisions: u32 = 0,
    jail_decisions: u32 = 0,
    shell_decisions: u32 = 0,
    provider_retries: u32 = 0,
    provider_faileds: u32 = 0,
    last_provider_failed_err: []const u8 = "",
    context_compactions: u32 = 0,
    control_applieds: u32 = 0,
    last_control_kind: ?control_input_mod.Kind = null,
    last_control_next_turn: u32 = 0,
    last_control_text: []const u8 = "",
    fail_next: ?loop_event_mod.SinkError = null,
    /// Fail only on control_applied (post-commit sink fault fixture).
    fail_on_control_applied: ?loop_event_mod.SinkError = null,
    /// After this many successful `code=steered` tool_end emissions, the next
    /// steered tool_end fails (mid-batch backfill hard-failure fixture).
    steered_tool_ends_ok_before_fail: ?u32 = null,
    steered_tool_ends_seen: u32 = 0,

    fn sink(self: *RecordingSink) LoopEventSink {
        return .{ .ptr = self, .vtable = &recording_vtable };
    }

    fn recordDeltaTag(self: *RecordingSink, tag: u8) void {
        if (self.delta_tags_len < self.delta_tags.len) {
            self.delta_tags[self.delta_tags_len] = tag;
            self.delta_tags_len += 1;
        }
    }

    fn emit(ptr: ?*anyopaque, event: LoopEvent) loop_event_mod.SinkError!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        if (self.fail_next) |e| {
            self.fail_next = null;
            return e;
        }
        switch (event) {
            .turn_start => self.turn_starts += 1,
            .assistant_message => |am| {
                self.assistant_messages += 1;
                self.last_assistant_has_tools = am.has_tools;
                if (am.has_tools) self.any_assistant_has_tools = true;
                self.last_reasoning_set = am.reasoning != null;
                if (am.reasoning) |r| {
                    const cap = @min(r.len, self.reason_buf.len);
                    @memcpy(self.reason_buf[0..cap], r[0..cap]);
                    self.reason_buf_len = cap;
                } else {
                    self.reason_buf_len = 0;
                }
                self.recordDeltaTag('m');
            },
            .assistant_delta => |d| {
                self.assistant_deltas += 1;
                self.recordDeltaTag('d');
                const cap = @min(d.len, self.delta_buf.len - self.delta_buf_len);
                @memcpy(self.delta_buf[self.delta_buf_len..][0..cap], d[0..cap]);
                self.delta_buf_len += cap;
            },
            .thinking_delta => |d| {
                self.thinking_deltas += 1;
                self.recordDeltaTag('t');
                const cap = @min(d.len, self.think_buf.len - self.think_buf_len);
                @memcpy(self.think_buf[self.think_buf_len..][0..cap], d[0..cap]);
                self.think_buf_len += cap;
            },
            .assistant_delta_clear => {
                self.delta_clears += 1;
                self.recordDeltaTag('c');
            },
            .usage => self.usages += 1,
            .tool_start => self.tool_starts += 1,
            .tool_end => |te| {
                if (tool_error.hasCode(te.body, .steered)) {
                    if (self.steered_tool_ends_ok_before_fail) |ok_n| {
                        if (self.steered_tool_ends_seen >= ok_n) {
                            return error.SinkFailed;
                        }
                    }
                    self.steered_tool_ends_seen += 1;
                }
                self.tool_ends += 1;
                self.last_tool_end_id = te.id;
                self.last_tool_end_body = te.body;
            },
            .policy_decision => self.policy_decisions += 1,
            .jail_decision => self.jail_decisions += 1,
            .shell_decision => self.shell_decisions += 1,
            .provider_retry => self.provider_retries += 1,
            .provider_failed => |pf| {
                self.provider_faileds += 1;
                self.last_provider_failed_err = pf.err_name;
            },
            .context_compaction => self.context_compactions += 1,
            .control_applied => |c| {
                if (self.fail_on_control_applied) |e| {
                    self.fail_on_control_applied = null;
                    return e;
                }
                self.control_applieds += 1;
                self.last_control_kind = c.kind;
                self.last_control_next_turn = c.next_turn;
                self.last_control_text = c.text;
            },
        }
    }
};

const recording_vtable: loop_event_mod.LoopEventSinkVTable = .{
    .emit = RecordingSink.emit,
};

/// Sink that fails once on the first assistant_delta (tui-streaming-001:
/// a delta-emit sink failure must abort the run, never be swallowed).
const FailDeltaSink = struct {
    fail_on_delta: bool = true,
    fn sink(self: *@This()) LoopEventSink {
        return .{ .ptr = self, .vtable = &fail_delta_vtable };
    }
    fn emit(ptr: ?*anyopaque, event: LoopEvent) loop_event_mod.SinkError!void {
        const self: *FailDeltaSink = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .assistant_delta => {
                if (self.fail_on_delta) {
                    self.fail_on_delta = false;
                    return error.OutOfMemory;
                }
            },
            else => {},
        }
    }
};
const fail_delta_vtable: loop_event_mod.LoopEventSinkVTable = .{
    .emit = FailDeltaSink.emit,
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
        .control_input = ControlInput.none(),
    };
}

// ── harness-steering-001 test ControlInput (in-memory dual queue) ────────────

const TestControlQueue = struct {
    steering: std.ArrayListUnmanaged([]const u8) = .empty,
    follow_up: std.ArrayListUnmanaged([]const u8) = .empty,
    gpa: std.mem.Allocator,
    /// Commit/peek counters for retention fixtures (queue itself never induces OOM).
    commits: u32 = 0,
    peeks: u32 = 0,

    fn deinit(self: *TestControlQueue) void {
        for (self.steering.items) |s| self.gpa.free(s);
        for (self.follow_up.items) |s| self.gpa.free(s);
        self.steering.deinit(self.gpa);
        self.follow_up.deinit(self.gpa);
    }

    fn pushSteering(self: *TestControlQueue, text: []const u8) !void {
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.steering.append(self.gpa, owned);
    }

    fn pushFollowUp(self: *TestControlQueue, text: []const u8) !void {
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.follow_up.append(self.gpa, owned);
    }

    fn controlInput(self: *TestControlQueue) ControlInput {
        return .{ .ptr = self, .vtable = &test_control_vtable };
    }

    fn peek(ptr: ?*anyopaque, boundary: control_input_mod.Boundary) ?control_input_mod.Item {
        const self: *TestControlQueue = @ptrCast(@alignCast(ptr.?));
        self.peeks += 1;
        switch (boundary) {
            .pre_turn, .between_tools => {
                if (self.steering.items.len == 0) return null;
                return .{ .kind = .steering, .text = self.steering.items[0] };
            },
            .would_complete => {
                if (self.steering.items.len > 0) {
                    return .{ .kind = .steering, .text = self.steering.items[0] };
                }
                if (self.follow_up.items.len > 0) {
                    return .{ .kind = .follow_up, .text = self.follow_up.items[0] };
                }
                return null;
            },
        }
    }

    fn commit(ptr: ?*anyopaque, kind: control_input_mod.Kind) void {
        const self: *TestControlQueue = @ptrCast(@alignCast(ptr.?));
        self.commits += 1;
        switch (kind) {
            .steering => {
                std.debug.assert(self.steering.items.len > 0);
                const owned = self.steering.orderedRemove(0);
                self.gpa.free(owned);
            },
            .follow_up => {
                std.debug.assert(self.follow_up.items.len > 0);
                const owned = self.follow_up.orderedRemove(0);
                self.gpa.free(owned);
            },
        }
    }
};

const test_control_vtable: control_input_mod.ControlInputVTable = .{
    .peek = TestControlQueue.peek,
    .commit = TestControlQueue.commit,
};

// File-local fake jail for loop tests: denies any non-null path with a generic
// `jail_deny` body (simulates Guard rejecting an absolute/escaping path). Not
// exported publicly; real Guard composition evidence lives in Coding tests.
const fake_jail_vtable: jail_mod.JailVTable = .{
    .check = fakeJailCheck,
};
fn fakeJailCheck(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: std.Io.Dir,
    _: ?[]const u8,
    _: []const u8,
    path: ?[]const u8,
) jail_mod.JailError!jail_mod.Check {
    if (path == null) return .{ .verdict = .allow };
    return .{ .verdict = .deny, .deny_body = try jail_mod.genericDeniedBody(allocator) };
}

// File-local fake shell policy for loop tests: denies commands containing
// known-dangerous substrings (simulates product `protect` denylist). Not
// exported publicly; real shell policy evidence lives in Coding tests.
const deny_dangerous_shell_vtable: shell_policy_mod.ShellPolicyVTable = .{
    .check = denyDangerousCheck,
    .deniedBody = denyDangerousDeniedBody,
};
fn denyDangerousCheck(_: ?*anyopaque, command: []const u8) shell_policy_mod.Decision {
    if (std.mem.indexOf(u8, command, "rm -rf /") != null) return .deny;
    return .allow;
}
fn denyDangerousDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    command: []const u8,
) error{OutOfMemory}![]u8 {
    return shell_policy_mod.genericDeniedBody(allocator, command);
}

test "sink failure during assistant_delta aborts the run" {
    // The delta handler is infallible `void`; a sink failure during a delta
    // emit must still stop the run (never swallowed) — the latch propagates
    // through chatWithRetry like any other sink failure.
    const gpa = std.testing.allocator;

    const StreamMock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "hi"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chatStream(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            handler(handler_ctx, "delta", null);
            return .{
                .content = try arena.dupe(u8, "hi"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = StreamMock.chat, .chat_stream = StreamMock.chatStream },
    };

    var sink: FailDeltaSink = .{};
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);
    try std.testing.expectError(error.OutOfMemory, result);
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
    try std.testing.expectEqual(@as(u32, 1), sink.assistant_messages);
    try std.testing.expect(!sink.last_assistant_has_tools);
    // Provider fallback (tui-streaming-001): no chat_stream slot → no delta
    // events at all; the complete assistant_message path is byte-identical.
    try std.testing.expectEqual(@as(u32, 0), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 0), sink.delta_clears);
    try std.testing.expectEqualStrings("m", sink.delta_tags[0..sink.delta_tags_len]);
}

test "chat_stream forwards deltas in order before assistant_message" {
    const gpa = std.testing.allocator;

    const StreamingMock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "Hello world"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chatStream(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            // Reuse ONE buffer per chunk: the handler must consume the slice
            // during emit (borrowed validity) — the sink copies at emit time.
            const chunks = [_][]const u8{ "Hel", "lo ", "wor", "ld" };
            var buf: [16]u8 = undefined;
            for (chunks) |ch| {
                @memcpy(buf[0..ch.len], ch);
                handler(handler_ctx, buf[0..ch.len], null);
            }
            return .{
                .content = try arena.dupe(u8, "Hello world"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = StreamingMock.chat, .chat_stream = StreamingMock.chatStream },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    try std.testing.expectEqualStrings("Hello world", result.final_text);
    // 4 deltas, in order, then exactly one complete assistant_message.
    try std.testing.expectEqual(@as(u32, 4), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 0), sink.delta_clears);
    try std.testing.expectEqualStrings("ddddm", sink.delta_tags[0..sink.delta_tags_len]);
    // The sink copied at emit time from a buffer the provider reused per
    // chunk; the captured concatenation proves per-emit borrow validity.
    try std.testing.expectEqualStrings("Hello world", sink.delta_buf[0..sink.delta_buf_len]);
    try std.testing.expectEqual(@as(u32, 1), sink.assistant_messages);
}

test "terminal provider failure emits provider_failed with ChatError tag" {
    const gpa = std.testing.allocator;

    const FailMock = struct {
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return error.AuthenticationFailed;
        }
    };

    const provider = provider_mod.Provider{
        .ptr = undefined,
        .vtable = &.{ .chat = FailMock.chat },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.options.chat_retries = 0;
    try std.testing.expectError(error.ProviderFailed, run(deps, &transcript));
    try std.testing.expectEqual(@as(u32, 1), sink.provider_faileds);
    try std.testing.expectEqualStrings("AuthenticationFailed", sink.last_provider_failed_err);
    try std.testing.expectEqual(@as(u32, 0), sink.provider_retries);
}

test "failed streaming attempt emits delta_clear before retry deltas" {
    const gpa = std.testing.allocator;

    const RetryStreamMock = struct {
        attempts: u32 = 0,
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chatStream(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            if (self.attempts == 1) {
                // Attempt 1: 3 deltas, then a retryable failure.
                for ([_][]const u8{ "one", " two", " three" }) |ch| {
                    handler(handler_ctx, ch, null);
                }
                return error.RateLimited;
            }
            // Attempt 2: 2 deltas, then success.
            handler(handler_ctx, "final", null);
            handler(handler_ctx, " answer", null);
            return .{
                .content = try arena.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: RetryStreamMock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = RetryStreamMock.chat, .chat_stream = RetryStreamMock.chatStream },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    try std.testing.expectEqualStrings("final answer", result.final_text);
    try std.testing.expectEqual(@as(u32, 5), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 1), sink.delta_clears);
    // Order: attempt-1 deltas → clear → attempt-2 deltas → complete message.
    // No delta after the terminal message ('m' is last).
    try std.testing.expectEqualStrings("dddcddm", sink.delta_tags[0..sink.delta_tags_len]);
    try std.testing.expectEqual(@as(u32, 1), sink.provider_retries);
    // Captured delta content: attempt-1 deltas are erased from the UI, but the
    // sink still observed them (honest stream). The complete turn is correct.
    try std.testing.expectEqualStrings("one two threefinal answer", sink.delta_buf[0..sink.delta_buf_len]);
    try std.testing.expectEqual(@as(u32, 1), sink.assistant_messages);
}

test "cancelled streaming attempt emits delta_clear (no partial text under terminal)" {
    const gpa = std.testing.allocator;

    const CancelStreamMock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "never"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chatStream(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            // Partial deltas, then a user cancel (non-retryable).
            handler(handler_ctx, "partial ", null);
            handler(handler_ctx, "text", null);
            _ = arena;
            return error.Cancelled;
        }
    };

    var mock: CancelStreamMock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = CancelStreamMock.chat, .chat_stream = CancelStreamMock.chatStream },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    // Cancelled run: the loop reports cancellation truthfully; the sink saw
    // the partial deltas AND the clear that erases them; no assistant_message
    // terminal (the run did not complete).
    try std.testing.expect(result.stop_reason == .cancelled);
    try std.testing.expectEqual(@as(u32, 2), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 1), sink.delta_clears);
    try std.testing.expectEqualStrings("ddc", sink.delta_tags[0..sink.delta_tags_len]);
    try std.testing.expectEqual(@as(u32, 0), sink.assistant_messages);
}

// ── m4-sampler-resilience-001: total retry decision table ───────────────────

test "shouldRetry is total over all ChatError tags" {
    // Retryable: rate-limit / 5xx / transient transport (incl. HttpFailed
    // network class and NotSupported, which now reaches the table instead of
    // the clean-outcome intercept).
    try std.testing.expect(shouldRetry(error.HttpFailed));
    try std.testing.expect(shouldRetry(error.BadStatus));
    try std.testing.expect(shouldRetry(error.WriteFailed));
    try std.testing.expect(shouldRetry(error.Unexpected));
    try std.testing.expect(shouldRetry(error.StreamFailed));
    try std.testing.expect(shouldRetry(error.RateLimited));
    try std.testing.expect(shouldRetry(error.ServerError));
    try std.testing.expect(shouldRetry(error.NotSupported));
    // Terminal: auth, invalid request/response, cancel/deadline control, OOM.
    try std.testing.expect(!shouldRetry(error.AuthenticationFailed));
    try std.testing.expect(!shouldRetry(error.PermissionDenied));
    try std.testing.expect(!shouldRetry(error.BadRequest));
    try std.testing.expect(!shouldRetry(error.InvalidResponse));
    try std.testing.expect(!shouldRetry(error.OutOfMemory));
    try std.testing.expect(!shouldRetry(error.Timeout));
    try std.testing.expect(!shouldRetry(error.Cancelled));
    try std.testing.expect(!shouldRetry(error.UnsupportedControl));
    // Equivalence: the previously-retried set keeps the old verdict (no regression).
    try std.testing.expectEqual(zt.isRetryableError(error.RateLimited), shouldRetry(error.RateLimited));
    try std.testing.expectEqual(zt.isRetryableError(error.ServerError), shouldRetry(error.ServerError));
    try std.testing.expectEqual(zt.isRetryableError(error.HttpFailed), shouldRetry(error.HttpFailed));
}

test "retryable error exhausts attempts then provider_failed once" {
    const gpa = std.testing.allocator;

    const RetryFailMock = struct {
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
            return error.RateLimited;
        }
    };

    var mock: RetryFailMock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = RetryFailMock.chat },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.options.chat_retries = 2; // 3 attempts total
    deps.options.retry_base_delay_ms = 1; // keep the backoff slices fast
    try std.testing.expectError(error.ProviderFailed, run(deps, &transcript));
    // Attempt accounting: 3 calls, 2 provider_retry, exactly one provider_failed.
    try std.testing.expectEqual(@as(u32, 3), mock.calls);
    try std.testing.expectEqual(@as(u32, 2), sink.provider_retries);
    try std.testing.expectEqual(@as(u32, 1), sink.provider_faileds);
    try std.testing.expectEqualStrings("RateLimited", sink.last_provider_failed_err);
}

test "newly retryable tags reach the table and retry to success" {
    const gpa = std.testing.allocator;

    const RetryThenOkMock = struct {
        err: zt.ChatError,
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
            if (self.calls == 1) return self.err;
            return .{
                .content = try arena.dupe(u8, "recovered"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    // BadStatus was terminal under the old isRetryableError gate; NotSupported
    // was a clean unsupported_control outcome. Both are retryable per the
    // contract's transient transport class and must reach the table.
    const cases = [_]zt.ChatError{ error.BadStatus, error.NotSupported };
    for (cases) |err| {
        var mock: RetryThenOkMock = .{ .err = err };
        const provider = provider_mod.Provider{
            .ptr = &mock,
            .vtable = &.{ .chat = RetryThenOkMock.chat },
        };

        var sink: RecordingSink = .{};

        var arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer arena_impl.deinit();
        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        try transcript.appendUser("hi");

        var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
        deps.options.retry_base_delay_ms = 1;
        const result = try run(deps, &transcript);

        try std.testing.expectEqualStrings("recovered", result.final_text);
        try std.testing.expectEqual(@as(u32, 2), mock.calls);
        try std.testing.expectEqual(@as(u32, 1), sink.provider_retries);
        try std.testing.expectEqual(@as(u32, 0), sink.provider_faileds);
    }
}

test "terminal error-set tag emits provider_failed once with retry budget available" {
    const gpa = std.testing.allocator;

    const FailMock = struct {
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
            return error.InvalidResponse;
        }
    };

    var mock: FailMock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = FailMock.chat },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.options.chat_retries = 2; // budget exists but a terminal tag must not use it
    try std.testing.expectError(error.ProviderFailed, run(deps, &transcript));
    try std.testing.expectEqual(@as(u32, 1), mock.calls);
    try std.testing.expectEqual(@as(u32, 0), sink.provider_retries);
    try std.testing.expectEqual(@as(u32, 1), sink.provider_faileds);
    try std.testing.expectEqualStrings("InvalidResponse", sink.last_provider_failed_err);
}

test "clean ChatOutcomes never emit provider_failed" {
    const gpa = std.testing.allocator;

    const ErrMock = struct {
        err: zt.ChatError,
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
            return self.err;
        }
    };

    const cases = [_]struct { err: zt.ChatError, want: StopReason }{
        .{ .err = error.Cancelled, .want = .cancelled },
        .{ .err = error.Timeout, .want = .timeout },
        .{ .err = error.UnsupportedControl, .want = .unsupported_control },
    };
    for (cases) |c| {
        var mock: ErrMock = .{ .err = c.err };
        const provider = provider_mod.Provider{
            .ptr = &mock,
            .vtable = &.{ .chat = ErrMock.chat },
        };

        var sink: RecordingSink = .{};

        var arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer arena_impl.deinit();
        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        try transcript.appendUser("hi");

        var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
        deps.options.chat_retries = 2; // retry budget exists but must not be touched
        const result = try run(deps, &transcript);

        try std.testing.expect(result.stop_reason == c.want);
        try std.testing.expectEqual(@as(u32, 1), mock.calls);
        try std.testing.expectEqual(@as(u32, 0), sink.provider_retries);
        try std.testing.expectEqual(@as(u32, 0), sink.provider_faileds);
    }
}

test "cancel during backoff returns cancelled" {
    const gpa = std.testing.allocator;

    const RetryMock = struct {
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return error.RateLimited;
        }
    };

    var cancel_flag: cancel_mod.Flag = .{};
    const provider = provider_mod.Provider{
        .ptr = undefined,
        .vtable = &.{ .chat = RetryMock.chat },
    };

    // Arm a thread that flips the flag ~10ms into the 500ms backoff sleep
    // (first slice is 25ms, so the cancel lands mid-sleep deterministically).
    const Arm = struct {
        flag: *cancel_mod.Flag,
        fn go(self: *@This()) void {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            self.flag.request();
        }
    };
    var arm: Arm = .{ .flag = &cancel_flag };
    const thr = try std.Thread.spawn(.{}, Arm.go, .{&arm});
    defer thr.join();

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.options.cancel = &cancel_flag;
    const result = try run(deps, &transcript);

    try std.testing.expect(result.stop_reason == .cancelled);
    try std.testing.expectEqual(@as(u32, 1), sink.provider_retries);
    try std.testing.expectEqual(@as(u32, 0), sink.provider_faileds);
}

// ── tui-thinking-streaming-001: reasoning deltas through the loop ───────────

test "thinking deltas emit in order with content deltas" {
    const gpa = std.testing.allocator;

    const ThinkingStreamMock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "Hello world"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "Why then"),
            };
        }
        fn chatStream(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            // Interleaved content + reasoning chunks, in provider order.
            handler(handler_ctx, "Hel", null);
            handler(handler_ctx, "", "Why");
            handler(handler_ctx, "lo", null);
            handler(handler_ctx, "", " then");
            handler(handler_ctx, " world", null);
            return .{
                .content = try arena.dupe(u8, "Hello world"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "Why then"),
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = ThinkingStreamMock.chat, .chat_stream = ThinkingStreamMock.chatStream },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    try std.testing.expectEqualStrings("Hello world", result.final_text);
    // In-order interleave: content, thinking, content, thinking, content, message.
    try std.testing.expectEqual(@as(u32, 3), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 2), sink.thinking_deltas);
    try std.testing.expectEqual(@as(u32, 0), sink.delta_clears);
    try std.testing.expectEqualStrings("dtdtdm", sink.delta_tags[0..sink.delta_tags_len]);
    try std.testing.expectEqualStrings("Hello world", sink.delta_buf[0..sink.delta_buf_len]);
    try std.testing.expectEqualStrings("Why then", sink.think_buf[0..sink.think_buf_len]);
    // The complete turn still carries reasoning on assistant_message.
    try std.testing.expectEqual(@as(u32, 1), sink.assistant_messages);
    try std.testing.expect(sink.last_reasoning_set);
    try std.testing.expectEqualStrings("Why then", sink.reason_buf[0..sink.reason_buf_len]);
}

test "failed streaming attempt clears thinking deltas with ONE clear" {
    const gpa = std.testing.allocator;

    const RetryThinkMock = struct {
        attempts: u32 = 0,
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "think b"),
            };
        }
        fn chatStream(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            if (self.attempts == 1) {
                // Attempt 1: thinking + content deltas, then a retryable failure.
                handler(handler_ctx, "", "think a");
                handler(handler_ctx, "partial", null);
                return error.RateLimited;
            }
            // Attempt 2: thinking + content deltas, then success.
            handler(handler_ctx, "", "think b");
            handler(handler_ctx, "final answer", null);
            return .{
                .content = try arena.dupe(u8, "final answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "think b"),
            };
        }
    };

    var mock: RetryThinkMock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = RetryThinkMock.chat, .chat_stream = RetryThinkMock.chatStream },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    try std.testing.expectEqualStrings("final answer", result.final_text);
    // ONE clear erases BOTH content and thinking UI text between attempts.
    try std.testing.expectEqual(@as(u32, 1), sink.delta_clears);
    try std.testing.expectEqual(@as(u32, 2), sink.thinking_deltas);
    try std.testing.expectEqual(@as(u32, 2), sink.assistant_deltas);
    try std.testing.expectEqualStrings("tdctdm", sink.delta_tags[0..sink.delta_tags_len]);
    try std.testing.expectEqualStrings("think athink b", sink.think_buf[0..sink.think_buf_len]);
    try std.testing.expectEqual(@as(u32, 1), sink.provider_retries);
    try std.testing.expectEqual(@as(u32, 1), sink.assistant_messages);
    try std.testing.expect(sink.last_reasoning_set);
    try std.testing.expectEqualStrings("think b", sink.reason_buf[0..sink.reason_buf_len]);
}

test "non-stream provider emits no thinking deltas; turn reasoning on assistant_message" {
    const gpa = std.testing.allocator;

    const ThinkChatOnlyMock = struct {
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
                .reasoning = try arena.dupe(u8, "offline thinking"),
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = ThinkChatOnlyMock.chat },
    };

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    // No chat_stream slot → no delta events at all (byte-identical fallback).
    try std.testing.expectEqual(@as(u32, 0), sink.assistant_deltas);
    try std.testing.expectEqual(@as(u32, 0), sink.thinking_deltas);
    try std.testing.expectEqualStrings("m", sink.delta_tags[0..sink.delta_tags_len]);
    // Turn reasoning still flows through assistant_message.
    try std.testing.expect(sink.last_reasoning_set);
    try std.testing.expectEqualStrings("offline thinking", sink.reason_buf[0..sink.reason_buf_len]);
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
    // Turn 1 requested tools; turn 2 is text-only (last_assistant_has_tools=false).
    try std.testing.expect(sink.any_assistant_has_tools);
    try std.testing.expect(!sink.last_assistant_has_tools);
    try std.testing.expectEqual(@as(u32, 2), sink.assistant_messages);
    try std.testing.expectEqual(@as(u32, 1), sink.tool_starts);
    try std.testing.expectEqual(@as(u32, 1), sink.tool_ends);
    try std.testing.expectEqualStrings("c1", sink.last_tool_end_id);
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
    deps.jail = .{ .ptr = null, .vtable = &fake_jail_vtable };

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
    deps.jail = .{ .ptr = null, .vtable = &fake_jail_vtable };

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
    try std.testing.expect(sink.last_assistant_has_tools);
    // Both accepted calls were cancelled before serial execution: truthful
    // end-only facts, with no fabricated tool_start.
    try std.testing.expectEqual(@as(u32, 0), sink.tool_starts);
    try std.testing.expectEqual(@as(u32, 2), sink.tool_ends);
    try std.testing.expectEqualStrings("c2", sink.last_tool_end_id);

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
    deps.jail = .{ .ptr = null, .vtable = &fake_jail_vtable };

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
    deps.shell_policy = .{ .ptr = null, .vtable = &deny_dangerous_shell_vtable };

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

// ── core-policy-ownership-001 regression tests ──────────────────────────────
//
// These tests prove the deniedBody port renderer contract: policy/shell
// `check` is nonfallible; the `deniedBody` renderer is called only after a
// deny decision; it may fail with OutOfMemory; when it does, policy_decision
// (or shell_decision) has already been emitted and the run returns
// RunError.OutOfMemory with no tool result appended.

/// File-local ToolPolicy vtable whose deniedBody always fails with OutOfMemory.
const oom_policy_vtable: tool_policy_mod.ToolPolicyVTable = .{
    .check = oomPolicyCheck,
    .deniedBody = oomPolicyDeniedBody,
};
fn oomPolicyCheck(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8, _: ?[]const u8) tool_policy_mod.Outcome {
    return .{ .decision = .deny };
}
fn oomPolicyDeniedBody(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: zt.ToolDescriptor,
    _: tool_policy_mod.Outcome,
) error{OutOfMemory}![]u8 {
    return error.OutOfMemory;
}

test "core-policy-ownership-001: policy deny body OOM — policy_decision emitted, renderer called, run returns OutOfMemory, no tool result" {
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
    try transcript.appendUser("write something");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.tool_policy = .{ .ptr = null, .vtable = &oom_policy_vtable };

    // The run must fail with OutOfMemory (deniedBody OOM).
    const result_err = run(deps, &transcript);
    try std.testing.expectError(error.OutOfMemory, result_err);

    // Handler never executed (deny path).
    try std.testing.expect(!state.ran);

    // policy_decision event was emitted BEFORE the renderer OOM.
    try std.testing.expect(sink.policy_decisions >= 1);

    // No tool_end event (no tool result appended on OOM).
    try std.testing.expectEqual(@as(u32, 0), sink.tool_ends);

    // No tool result in the transcript.
    for (transcript.items()) |m| {
        if (m.role == .tool) return error.TestUnexpectedResult;
    }
}

/// File-local ShellPolicy vtable whose deniedBody always fails with OutOfMemory.
const oom_shell_vtable: shell_policy_mod.ShellPolicyVTable = .{
    .check = oomShellCheck,
    .deniedBody = oomShellDeniedBody,
};
fn oomShellCheck(_: ?*anyopaque, command: []const u8) shell_policy_mod.Decision {
    if (std.mem.indexOf(u8, command, "rm -rf /") != null) return .deny;
    return .allow;
}
fn oomShellDeniedBody(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) error{OutOfMemory}![]u8 {
    return error.OutOfMemory;
}

test "core-policy-ownership-001: shell deny body OOM — shell_decision emitted before renderer OOM, run returns OutOfMemory" {
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
    deps.shell_policy = .{ .ptr = null, .vtable = &oom_shell_vtable };

    // The run must fail with OutOfMemory (shell deniedBody OOM).
    const result_err = run(deps, &transcript);
    try std.testing.expectError(error.OutOfMemory, result_err);

    // Handler never executed.
    try std.testing.expect(!state.ran);

    // shell_decision event was emitted BEFORE the renderer OOM.
    try std.testing.expect(sink.shell_decisions >= 1);

    // No tool_end event.
    try std.testing.expectEqual(@as(u32, 0), sink.tool_ends);

    // No tool result in the transcript.
    for (transcript.items()) |m| {
        if (m.role == .tool) return error.TestUnexpectedResult;
    }
}

// ── core-context-ownership-001 regression tests ────────────────────────────
//
// The loop must independently validate the protocol-visible body of the
// ContextView projection **before** any Provider.chat, regardless of how the
// product built the view. These tests prove:
// 1. identity view passes through a valid transcript (explicit low-level
//    composition, not a missing-state fallback);
// 2. a hostile ContextView that returns a malformed Tool bundle is rejected
//    with InvalidContext and the provider is never called (provider call
//    count = 0).

test "core-context-001: identity view passes valid transcript to provider" {
    const gpa = std.testing.allocator;

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
            // Identity view: provider sees the full transcript unchanged.
            if (messages.len < 3) return error.InvalidResponse;
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

    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    try transcript.appendAssistantTurn(.{
        .content = "hello",
        .tool_calls = &.{},
        .finish_reason = "stop",
    });
    try transcript.appendUser("again");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.context_view = ContextView.identity();

    const result = try run(deps, &transcript);
    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), mock.calls);
}

test "core-context-001: hostile ContextView malformed bundle → InvalidContext, provider=0" {
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
            return .{
                .content = try arena.dupe(u8, "should-not-reach"),
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
    try transcript.appendUser("hi");

    // Hostile ContextView: returns a view with a malformed tool bundle
    // (orphan tool result with no preceding assistant tool_calls). The loop
    // must reject this before calling the provider.
    const HostileView = struct {
        fn view(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
        ) context_view_mod.ContextViewError!context_view_mod.View {
            const msgs = try arena.alloc(message.Message, 2);
            msgs[0] = message.Message.user("ask");
            msgs[1] = message.Message.toolResult("orphan-id", "no-carrier");
            return .{ .messages = msgs, .compaction = null };
        }
    };
    const hostile_vtable: context_view_mod.ContextViewVTable = .{
        .view = HostileView.view,
    };

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.context_view = .{ .ptr = null, .vtable = &hostile_vtable };

    const err = run(deps, &transcript);
    try std.testing.expectError(error.InvalidContext, err);
    // Provider must never have been called.
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
    // No assistant event emitted (provider was not called).
    try std.testing.expectEqual(@as(u32, 0), sink.assistant_messages);
}

test "core-context-001: hostile ContextView with leading system layers then malformed body → InvalidContext" {
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
            return .{
                .content = try arena.dupe(u8, "should-not-reach"),
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
    try transcript.appendUser("hi");

    // Hostile ContextView: leading system layers (valid) then a malformed body
    // (incomplete tool bundle — assistant with 2 calls but only 1 result).
    const HostileView = struct {
        fn view(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
        ) context_view_mod.ContextViewError!context_view_mod.View {
            const calls = try arena.alloc(message.ToolCall, 2);
            calls[0] = .{ .id = "c1", .name = "list_dir", .arguments = "{}" };
            calls[1] = .{ .id = "c2", .name = "read_file", .arguments = "{}" };
            const msgs = try arena.alloc(message.Message, 4);
            msgs[0] = message.Message.system("base-sys");
            msgs[1] = message.Message.user("ask");
            msgs[2] = message.Message.assistantToolCalls("tools", calls);
            msgs[3] = message.Message.toolResult("c1", "only-one"); // missing c2
            return .{ .messages = msgs, .compaction = null };
        }
    };
    const hostile_vtable: context_view_mod.ContextViewVTable = .{
        .view = HostileView.view,
    };

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.context_view = .{ .ptr = null, .vtable = &hostile_vtable };

    const err = run(deps, &transcript);
    try std.testing.expectError(error.InvalidContext, err);
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
}

// P3-5 regression: a hostile ContextView that returns BOTH a compaction fact
// AND a malformed body must be rejected with InvalidContext before the sink
// sees any context_compaction event. The validation gate runs before the
// compaction emit, so Session/Trace cannot advance generation on a malformed
// projection. This test fails under the old ordering (compaction emit before
// validateViewBody) because the sink would receive the context_compaction event.
test "core-context-001: hostile ContextView compaction + malformed body → InvalidContext, no compaction emit, provider=0" {
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
            return .{
                .content = try arena.dupe(u8, "should-not-reach"),
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
    try transcript.appendUser("hi");

    // Hostile ContextView: returns a compaction fact AND a malformed body
    // (orphan tool result with no preceding assistant tool_calls). Under the
    // old ordering the sink would receive context_compaction before the
    // validation gate rejects the body. Under the new ordering validation
    // runs first, so no compaction event is emitted.
    const HostileView = struct {
        fn view(
            _: ?*anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
        ) context_view_mod.ContextViewError!context_view_mod.View {
            const msgs = try arena.alloc(message.Message, 2);
            msgs[0] = message.Message.user("ask");
            msgs[1] = message.Message.toolResult("orphan-id", "no-carrier");
            const summary = try arena.dupe(u8, "[compaction] 5 earlier messages omitted.");
            return .{
                .messages = msgs,
                .compaction = .{ .dropped = 5, .summary = summary },
            };
        }
    };
    const hostile_vtable: context_view_mod.ContextViewVTable = .{
        .view = HostileView.view,
    };

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.context_view = .{ .ptr = null, .vtable = &hostile_vtable };

    const err = run(deps, &transcript);
    try std.testing.expectError(error.InvalidContext, err);
    // Provider must never have been called.
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
    // No context_compaction event reached the sink (validation ran first).
    try std.testing.expectEqual(@as(u32, 0), sink.context_compactions);
    // No assistant event (provider was not called).
    try std.testing.expectEqual(@as(u32, 0), sink.assistant_messages);
    // turn_start was emitted before the view/validation gate (expected).
    try std.testing.expectEqual(@as(u32, 1), sink.turn_starts);
}

// ── harness-steering-001 Core fixtures ──────────────────────────────────────

test "harness-steering: none() preserves completed text-only" {
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
    var sink: RecordingSink = .{};
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    const result = try run(defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink()), &transcript);
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
}

test "harness-steering: pre-turn steering before turn 1; one-at-a-time" {
    const gpa = std.testing.allocator;
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
                // First provider turn must already see steering user after explicit user.
                var users: u32 = 0;
                for (messages) |m| {
                    if (m.role == .user) users += 1;
                }
                if (users < 2) return error.InvalidResponse;
                if (!std.mem.eql(u8, messages[messages.len - 1].content, "steer-1"))
                    return error.InvalidResponse;
                return .{
                    .content = try arena.dupe(u8, "acked-steer"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            return .{
                .content = try arena.dupe(u8, "second"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("steer-1");
    try q.pushSteering("steer-2");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("explicit");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.max_turns = 4;

    const result = try run(deps, &transcript);
    // First would-complete peeks remaining steer-2 and continues the run.
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), mock.calls);
    try std.testing.expectEqual(@as(u32, 2), sink.control_applieds);
    // Last apply was would-complete → next_turn = 2 (turns was 1).
    try std.testing.expectEqual(@as(u32, 2), sink.last_control_next_turn);
    try std.testing.expectEqual(@as(usize, 0), q.steering.items.len);
}

test "harness-steering: mid-batch steered exact body + prepared user" {
    const gpa = std.testing.allocator;

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
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
                const tc = try arena.alloc(message.ToolCall, 2);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"a\"}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "c2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"b\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "after-steer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("go");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.options.max_turns = 4;

    // Skip pre_turn (and first between_tools) so Tool 1 runs; second between_tools
    // yields steering — simulates enqueue during Tool 1 execution.
    try q.pushSteering("mid-steer");
    const Delayed = struct {
        inner: *TestControlQueue,
        between_skips: u32 = 1,
        fn peek(ptr: ?*anyopaque, boundary: control_input_mod.Boundary) ?control_input_mod.Item {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (boundary == .pre_turn) return null;
            if (boundary == .between_tools and self.between_skips > 0) {
                self.between_skips -= 1;
                return null;
            }
            return TestControlQueue.peek(self.inner, boundary);
        }
        fn commit(ptr: ?*anyopaque, kind: control_input_mod.Kind) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            TestControlQueue.commit(self.inner, kind);
        }
    };
    var delayed: Delayed = .{ .inner = &q };
    const delayed_vtable: control_input_mod.ControlInputVTable = .{
        .peek = Delayed.peek,
        .commit = Delayed.commit,
    };
    deps.control_input = .{ .ptr = &delayed, .vtable = &delayed_vtable };

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), state.n); // only tool 1 ran
    try std.testing.expectEqual(@as(u32, 1), sink.tool_starts);
    try std.testing.expectEqual(@as(u32, 2), sink.tool_ends);
    try std.testing.expectEqualStrings("c2", sink.last_tool_end_id);
    try std.testing.expectEqualStrings(tool_error.steered_body, sink.last_tool_end_body);
    try std.testing.expectEqual(@as(u32, 1), sink.control_applieds);
    try std.testing.expectEqual(@as(u32, 2), sink.last_control_next_turn);
    try std.testing.expectEqualStrings("mid-steer", sink.last_control_text);

    // Transcript protocol legal: tool c1 body, tool c2 steered, then user.
    var saw_steered = false;
    var saw_user_steer = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .steered)) {
            saw_steered = true;
            try std.testing.expectEqualStrings(tool_error.steered_body, m.content);
        }
        if (m.role == .user and std.mem.eql(u8, m.content, "mid-steer")) saw_user_steer = true;
    }
    try std.testing.expect(saw_steered);
    try std.testing.expect(saw_user_steer);
    try std.testing.expectEqual(@as(usize, 0), q.steering.items.len);
}

test "harness-steering: would-complete steering priority over follow-up" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        calls: u32 = 0,
        q: *TestControlQueue,
        first_control: ?[]const u8 = null,
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
                // Enqueue during provider so pre-turn cannot consume them.
                self.q.pushFollowUp("F") catch return error.InvalidResponse;
                self.q.pushSteering("S") catch return error.InvalidResponse;
                return .{
                    .content = try arena.dupe(u8, "first"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            // First post-turn-1 control user must be steering "S".
            if (self.first_control == null) {
                const last = messages[messages.len - 1];
                if (last.role != .user) return error.InvalidResponse;
                self.first_control = last.content;
            }
            return .{
                .content = try arena.dupe(u8, "cont"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    var mock: Mock = .{ .q = &q };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.max_turns = 4;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
    try std.testing.expectEqualStrings("S", mock.first_control.?);
    // First control_applied is steering; both eventually drained in one run.
    try std.testing.expectEqual(@as(u32, 2), sink.control_applieds);
    try std.testing.expectEqual(@as(usize, 0), q.steering.items.len);
    try std.testing.expectEqual(@as(usize, 0), q.follow_up.items.len);
}

test "harness-steering: follow-up alone continues same run" {
    const gpa = std.testing.allocator;
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
                return .{
                    .content = try arena.dupe(u8, "first"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            const last = messages[messages.len - 1];
            if (!std.mem.eql(u8, last.content, "more")) return error.InvalidResponse;
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
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushFollowUp("more");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.max_turns = 3;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u32, 1), sink.control_applieds);
    try std.testing.expectEqual(control_input_mod.Kind.follow_up, sink.last_control_kind.?);
    try std.testing.expectEqual(@as(u32, 2), sink.last_control_next_turn);
}

test "harness-steering: cancel before pre-turn leaves queue uncommitted" {
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
                .content = try arena.dupe(u8, "should-not"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("pending");

    var flag: cancel_mod.Flag = .{};
    flag.request();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.cancel = &flag;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.cancelled, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    try std.testing.expectEqual(@as(u32, 0), q.commits);
}

test "harness-steering: cancel after non-null would-complete peek retains item" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        flag: *cancel_mod.Flag,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // After chat returns text-only, would-complete peeks then rechecks cancel.
            self.flag.request();
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var flag: cancel_mod.Flag = .{};
    var mock: Mock = .{ .flag = &flag };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushFollowUp("later");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.cancel = &flag;
    deps.options.max_turns = 4;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.cancelled, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(usize, 1), q.follow_up.items.len);
}

test "harness-steering: empty would-complete returns completed (no late cancel)" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        flag: *cancel_mod.Flag,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Cancel after chat: empty would-complete must still complete (no new late-cancel check).
            self.flag.request();
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var flag: cancel_mod.Flag = .{};
    var mock: Mock = .{ .flag = &flag };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.options.cancel = &flag;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.completed, result.stop_reason);
}

test "harness-steering: max_turns retains pending control" {
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
                .content = try arena.dupe(u8, "only"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushFollowUp("no-room");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.max_turns = 1;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.max_turns, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(usize, 1), q.follow_up.items.len);
}

test "harness-steering: last-turn tools finish; steering retained" {
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
        q: *TestControlQueue,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            // Enqueue mid-provider so pre-turn cannot consume; last turn refuses apply.
            self.q.pushSteering("late") catch return error.InvalidResponse;
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = try arena.dupe(u8, "{\"path\":\"x\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    var mock: Mock = .{ .q = &q };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("go");

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.max_turns = 1;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.max_turns, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), state.n);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    // No steered codes — tools finished normally.
    for (transcript.items()) |m| {
        if (m.role == .tool) {
            try std.testing.expect(!tool_error.hasCode(m.content, .steered));
        }
    }
}

test "harness-steering: multi-tool cancel still uses code=cancelled never steered" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        cancel_ptr: *cancel_mod.Flag,
        q: *TestControlQueue,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Enqueue during chat so pre-turn cannot consume; cancel before tools.
            self.q.pushSteering("ignored-on-cancel") catch return error.InvalidResponse;
            self.cancel_ptr.request();
            const tc = try arena.alloc(message.ToolCall, 2);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "list_dir"),
                .arguments = try arena.dupe(u8, "{}"),
            };
            tc[1] = .{
                .id = try arena.dupe(u8, "c2"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = try arena.dupe(u8, "{}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };
    var cancel_flag: cancel_mod.Flag = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    var mock: Mock = .{ .cancel_ptr = &cancel_flag, .q = &q };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("explore");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();
    deps.options.cancel = &cancel_flag;
    deps.options.max_turns = 4;

    const result = try run(deps, &transcript);
    try std.testing.expectEqual(StopReason.cancelled, result.stop_reason);
    var cancelled_n: u32 = 0;
    for (transcript.items()) |m| {
        if (m.role == .tool) {
            try std.testing.expect(tool_error.hasCode(m.content, .cancelled));
            try std.testing.expect(!tool_error.hasCode(m.content, .steered));
            cancelled_n += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), cancelled_n);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
}

test "harness-steering: post-commit control_applied sink failure leaves applied row" {
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
                .content = try arena.dupe(u8, "never"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{ .fail_on_control_applied = error.SinkFailed };
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("applied-once");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();

    const err = run(deps, &transcript);
    try std.testing.expectError(error.TraceFailed, err);
    // Committed: queue empty; transcript has the user row.
    try std.testing.expectEqual(@as(usize, 0), q.steering.items.len);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, "applied-once")) found = true;
    }
    try std.testing.expect(found);
}

test "harness-steering: ordinary appendUser OOM does not commit or emit control_applied" {
    // Transcript arena is a fixed buffer; exhaust after seed user so pre-turn
    // appendUser OOM leaves the queue uncommitted and no control_applied.
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
            return .{
                .content = try arena.dupe(u8, "should-not-run"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("oom-steer");

    var storage: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var transcript = transcript_mod.Transcript.init(fba.allocator());
    try transcript.appendUser("hi");
    // Exhaust remaining transcript arena capacity.
    while (fba.allocator().alloc(u8, 1)) |_| {} else |_| {}

    var deps = defaultDeps(gpa, provider, .{ .tools = &.{} }, sink.sink());
    deps.control_input = q.controlInput();

    const err = run(deps, &transcript);
    try std.testing.expectError(error.OutOfMemory, err);
    try std.testing.expectEqual(@as(u32, 0), mock.calls);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(u32, 0), q.commits);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    for (transcript.items()) |m| {
        if (m.role == .user) {
            try std.testing.expect(!std.mem.eql(u8, m.content, "oom-steer"));
        }
    }
}

test "harness-steering: mid-batch prepareUser OOM before any steered side effect" {
    // Fault injection is timed precisely:
    //   provider turn + Tool1 start/end + tool result append complete
    //   → between_tools peek returns steering
    //   → (peek hook exhausts transcript fixed arena here)
    //   → prepareUser OOM (no steered side effect, no commit).
    // Exhaustion is NOT done in the Tool1 handler (that could OOM appendToolResult).
    const gpa = std.testing.allocator;

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };

    var storage: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const transcript_alloc = fba.allocator();
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
                const tc = try arena.alloc(message.ToolCall, 2);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"a\"}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "c2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"b\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "should-not"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var sink: RecordingSink = .{};
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("prep-oom");

    var transcript = transcript_mod.Transcript.init(transcript_alloc);
    try transcript.appendUser("go");

    // Path markers on the ControlInput peek hook (test-only; no production change).
    const Delayed = struct {
        inner: *TestControlQueue,
        transcript_alloc: std.mem.Allocator,
        /// Skip first between_tools so Tool1 executes fully first.
        between_skips: u32 = 1,
        between_tools_peeks: u32 = 0,
        /// Non-null steering returns from between_tools after Tool1.
        steering_returns: u32 = 0,
        exhausted_before_steering_return: bool = false,

        fn peek(ptr: ?*anyopaque, boundary: control_input_mod.Boundary) ?control_input_mod.Item {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (boundary == .pre_turn) return null;
            if (boundary == .between_tools) {
                self.between_tools_peeks += 1;
                if (self.between_skips > 0) {
                    self.between_skips -= 1;
                    return null;
                }
                // Tool1 result is already in the transcript when this second peek
                // runs. Exhaust the fixed transcript arena *after* that success and
                // immediately before returning steering so the next fallible Core
                // step is prepareUser (not appendToolResult for Tool1).
                while (self.transcript_alloc.alloc(u8, 1)) |_| {} else |_| {}
                self.exhausted_before_steering_return = true;
                const item = TestControlQueue.peek(self.inner, boundary);
                if (item != null) self.steering_returns += 1;
                return item;
            }
            return TestControlQueue.peek(self.inner, boundary);
        }
        fn commit(ptr: ?*anyopaque, kind: control_input_mod.Kind) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            TestControlQueue.commit(self.inner, kind);
        }
    };
    var delayed: Delayed = .{
        .inner = &q,
        .transcript_alloc = transcript_alloc,
    };
    const delayed_vtable: control_input_mod.ControlInputVTable = .{
        .peek = Delayed.peek,
        .commit = Delayed.commit,
    };

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.control_input = .{ .ptr = &delayed, .vtable = &delayed_vtable };
    deps.options.max_turns = 4;

    const err = run(deps, &transcript);
    try std.testing.expectError(error.OutOfMemory, err);

    // Path proof: provider + Tool1 completed before the prepare-stage OOM.
    try std.testing.expectEqual(@as(u32, 1), mock.calls);
    try std.testing.expectEqual(@as(u32, 1), state.n);
    try std.testing.expectEqual(@as(u32, 1), sink.tool_starts);
    try std.testing.expectEqual(@as(u32, 1), sink.tool_ends); // ordinary Tool1 end only
    try std.testing.expectEqualStrings("c1", sink.last_tool_end_id);
    try std.testing.expect(!tool_error.hasCode(sink.last_tool_end_body, .steered));
    var saw_tool1_result = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and std.mem.eql(u8, m.content, "ran")) saw_tool1_result = true;
    }
    try std.testing.expect(saw_tool1_result);

    // between_tools peeked twice (skip then steering return); arena exhausted at return.
    try std.testing.expectEqual(@as(u32, 2), delayed.between_tools_peeks);
    try std.testing.expectEqual(@as(u32, 1), delayed.steering_returns);
    try std.testing.expect(delayed.exhausted_before_steering_return);

    // Prepare-stage failure: no steered ends, no prepared user, no commit/event.
    try std.testing.expectEqual(@as(u32, 0), sink.steered_tool_ends_seen);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(u32, 0), q.commits);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    for (transcript.items()) |m| {
        if (m.role == .tool) {
            try std.testing.expect(!tool_error.hasCode(m.content, .steered));
        }
        if (m.role == .user) {
            try std.testing.expect(!std.mem.eql(u8, m.content, "prep-oom"));
        }
    }
}

test "harness-steering: mid-batch backfill sink fault leaves partial steered + hidden prepared" {
    // Two remaining tools after Tool 1: first steered end succeeds (partial
    // evidence), second steered tool_end sink-fails before append. Prepared
    // user stays hidden; queue uncommitted; no control_applied.
    const gpa = std.testing.allocator;

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
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
                const tc = try arena.alloc(message.ToolCall, 3);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"a\"}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "c2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"b\"}"),
                };
                tc[2] = .{
                    .id = try arena.dupe(u8, "c3"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"c\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "should-not"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    // Allow one steered tool_end (c2), fail on the next steered (c3).
    var sink: RecordingSink = .{ .steered_tool_ends_ok_before_fail = 1 };
    var q: TestControlQueue = .{ .gpa = gpa };
    defer q.deinit();
    try q.pushSteering("backfill-fault");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("go");

    const Delayed = struct {
        inner: *TestControlQueue,
        between_skips: u32 = 1,
        fn peek(ptr: ?*anyopaque, boundary: control_input_mod.Boundary) ?control_input_mod.Item {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (boundary == .pre_turn) return null;
            if (boundary == .between_tools and self.between_skips > 0) {
                self.between_skips -= 1;
                return null;
            }
            return TestControlQueue.peek(self.inner, boundary);
        }
        fn commit(ptr: ?*anyopaque, kind: control_input_mod.Kind) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            TestControlQueue.commit(self.inner, kind);
        }
    };
    var delayed: Delayed = .{ .inner = &q };
    const delayed_vtable: control_input_mod.ControlInputVTable = .{
        .peek = Delayed.peek,
        .commit = Delayed.commit,
    };

    var deps = defaultDeps(gpa, provider, .{ .tools = &tools }, sink.sink());
    deps.control_input = .{ .ptr = &delayed, .vtable = &delayed_vtable };
    deps.options.max_turns = 4;

    const err = run(deps, &transcript);
    try std.testing.expectError(error.TraceFailed, err);
    try std.testing.expectEqual(@as(u32, 1), state.n);
    try std.testing.expectEqual(@as(u32, 0), sink.control_applieds);
    try std.testing.expectEqual(@as(u32, 0), q.commits);
    try std.testing.expectEqual(@as(usize, 1), q.steering.items.len);
    // Partial: exactly one steered tool row (c2); c3 not appended; prepared user hidden.
    var steered_rows: u32 = 0;
    var saw_prepared = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .steered)) {
            steered_rows += 1;
            try std.testing.expectEqualStrings(tool_error.steered_body, m.content);
        }
        if (m.role == .user and std.mem.eql(u8, m.content, "backfill-fault")) saw_prepared = true;
    }
    try std.testing.expectEqual(@as(u32, 1), steered_rows);
    try std.testing.expect(!saw_prepared);
    try std.testing.expectEqual(@as(u32, 1), sink.steered_tool_ends_seen);
}
