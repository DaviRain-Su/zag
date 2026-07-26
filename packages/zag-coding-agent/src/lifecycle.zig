//! Public SDK lifecycle events — coding-agent adapter over Core source facts
//! and facade run facts (harness-events-001).
//!
//! This is a **product optional observer**, not a replacement for the required
//! Core `LoopEventSink`. It is synchronous, callback-borrowed, and infallible
//! (`void`): the callback cannot stop execution. Payload slices are borrowed
//! and valid only during the callback; consumers copy data they retain. Panic
//! and re-entry from the callback are host responsibility.
//!
//! `StopReason` is an alias of the existing Core `loop.StopReason` enum.
//! `usage` uses the canonical `message.Usage` from `zag-types`, converted from
//! the facade's `u64` ledger with explicit saturating conversion (including
//! reasoning tokens, no overflow).
//!
//! Source-truth contract:
//! - Ordinary / soft-result / deny / jail / shell / handler-failure / invalid-
//!   arguments / unknown-tool calls that **enter serial execution** emit
//!   `tool_start` then `tool_end`.
//! - Pending accepted calls cancelled **between tools** never enter serial
//!   execution: they emit `tool_end` only (no fabricated `tool_start`).
//! - A hard failure (OOM / sink failure) after `tool_start` and before a
//!   result does not fabricate `tool_end`; the run ends with a truthful
//!   `run_terminal`.

const std = @import("std");
const core = @import("zag-agent-core");
const message = core.message;
const loop = core.loop;

/// Alias of the Core `StopReason` enum. The lifecycle adapter does not redefine
/// stop categories; it projects the facade's truthful terminal category.
pub const StopReason = loop.StopReason;

/// One public lifecycle event. Payload slices are borrowed for the duration of
/// the callback only.
pub const LifecycleEvent = union(enum) {
    /// Emitted once after run preflight + durable-start succeeded and before
    /// `appendUser`. `session_configured` is true when a durable session path
    /// is active for this run.
    run_start: struct {
        session_configured: bool,
    },
    /// Emitted after a complete validated assistant turn is appended.
    /// `turn` is the 1-based turn counter. `has_tools` is `turn.wantsTools()`.
    assistant_message: struct {
        turn: u32,
        text: []const u8,
        has_tools: bool,
    },
    /// Emitted when an accepted Tool call enters serial execution.
    /// `turn` is the current 1-based turn; `call_index` is the 0-based index
    /// within the turn's tool-call batch.
    tool_start: struct {
        turn: u32,
        call_index: u32,
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    /// Emitted when a Tool call has a final body (ordinary, soft-result, deny,
    /// jail, shell, handler failure, invalid arguments, unknown tool, or
    /// pending-cancel between tools). Pending-cancel calls emit `tool_end`
    /// **only** (no preceding `tool_start`).
    tool_end: struct {
        turn: u32,
        call_index: u32,
        id: []const u8,
        name: []const u8,
        body: []const u8,
    },
    /// Emitted exactly once as the final lifecycle callback after session/Trace
    /// outcome precedence is known. `ok` reflects the truthful final outcome.
    /// `usage` is the cumulative provider usage for the run, converted from the
    /// facade's `u64` ledger with saturating conversion (no overflow).
    run_terminal: struct {
        turns: u32,
        ok: bool,
        stop_reason: StopReason,
        usage: message.Usage,
    },
};

/// Optional synchronous lifecycle observer. The callback is invoked in program
/// order during `Agent.reply`. A `null` `on_event` is silently ignored.
///
/// The observer value is copied into `Agent.Options`; the pointer/data it
/// references must remain valid for the lifetime of every `Agent.reply` call.
pub const LifecycleObserver = struct {
    ptr: ?*anyopaque = null,
    on_event: ?*const fn (ptr: ?*anyopaque, event: LifecycleEvent) void = null,

    pub fn emit(self: LifecycleObserver, event: LifecycleEvent) void {
        if (self.on_event) |f| f(self.ptr, event);
    }

    pub fn none() LifecycleObserver {
        return .{};
    }
};

/// Convert the facade's `u64` ledger values to the canonical `message.Usage`
/// with explicit saturating conversion (no overflow). Includes reasoning tokens.
pub fn usageFromLedger(
    prompt: u64,
    completion: u64,
    total: u64,
    reasoning: u64,
) message.Usage {
    return .{
        .prompt_tokens = saturateU32(prompt),
        .completion_tokens = saturateU32(completion),
        .total_tokens = saturateU32(total),
        .reasoning_tokens = saturateU32(reasoning),
    };
}

fn saturateU32(v: u64) u32 {
    if (v >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(v);
}

test "usageFromLedger saturates without overflow" {
    const u = usageFromLedger(
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
    );
    try std.testing.expectEqual(std.math.maxInt(u32), u.prompt_tokens);
    try std.testing.expectEqual(std.math.maxInt(u32), u.completion_tokens);
    try std.testing.expectEqual(std.math.maxInt(u32), u.total_tokens);
    try std.testing.expectEqual(std.math.maxInt(u32), u.reasoning_tokens);

    const small = usageFromLedger(10, 5, 15, 2);
    try std.testing.expectEqual(@as(u32, 10), small.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 5), small.completion_tokens);
    try std.testing.expectEqual(@as(u32, 15), small.total_tokens);
    try std.testing.expectEqual(@as(u32, 2), small.reasoning_tokens);
}

test "LifecycleObserver.none has null callback" {
    const obs = LifecycleObserver.none();
    try std.testing.expect(obs.on_event == null);
    // Emit is a no-op when on_event is null.
    obs.emit(.{ .run_start = .{ .session_configured = false } });
}

test "LifecycleObserver emit invokes callback" {
    const Recorder = struct {
        seen: bool = false,
        fn cb(ptr: ?*anyopaque, event: LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .run_start => |rs| {
                    if (rs.session_configured) self.seen = true;
                },
                else => {},
            }
        }
    };
    var rec: Recorder = .{};
    const obs: LifecycleObserver = .{ .ptr = &rec, .on_event = Recorder.cb };
    obs.emit(.{ .run_start = .{ .session_configured = true } });
    try std.testing.expect(rec.seen);
}