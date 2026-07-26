//! Canonical Core source event contract (D-011).
//!
//! Core emits only facts it directly witnesses during one synchronous
//! `loop.run`: turn start, complete assistant message, usage, tool start/end,
//! policy/jail/shell decisions, provider retry, and context compaction.
//!
//! `LoopEvent` is borrowed, synchronous, ordered, and fallible. Payload slices
//! are valid only during `emit`; consumers copy data they retain. There is no
//! product `run_start` / `run_terminal` in this union — those remain facade-owned.
//!
//! The loop emits through `LoopEventSink` only; it no longer writes Trace or
//! Observer directly. A product fan-out adapter implements the sink and keeps
//! the existing per-event ordering (see docs/modules/trace-observability.md).

const std = @import("std");
const message = @import("message.zig");
const context_mod = @import("context.zig");

/// One Core source fact. Variants mirror the existing trace/observer facts
/// the loop already produced (D-011 module: loop-turn / trace-observability).
pub const LoopEvent = union(enum) {
    /// Turn counter increment (trace `turn`).
    turn_start: u32,
    /// Complete validated assistant message text (observer `assistant_text` +
    /// trace `assistant`).
    assistant_message: []const u8,
    /// Provider-reported usage for the just-appended assistant turn.
    usage: message.Usage,
    /// Tool dispatch start (observer `tool_call` + trace `tool_call`).
    tool_start: message.ToolCall,
    /// Tool dispatch end (observer `tool_result` + trace `tool_result`).
    tool_end: struct {
        name: []const u8,
        body: []const u8,
    },
    /// Permission policy decision (observer `permission` + trace `permission`).
    policy_decision: struct {
        tool_name: []const u8,
        allowed: bool,
        remembered: bool = false,
        /// Descriptor-derived risk name (`read` / `write` / `execute`) when known.
        risk: ?[]const u8 = null,
    },
    /// Workspace jail decision (trace `jail_deny` + generic warning).
    jail_decision: struct {
        tool_name: []const u8,
        path: []const u8,
    },
    /// Shell policy decision (trace `shell_deny` + generic warning).
    /// `command` is the validated command string; adapters log only a generic
    /// warning (never raw) — same as the prior loop behavior.
    shell_decision: []const u8,
    /// Provider retry attempt (trace `provider_retry` + generic warning).
    provider_retry: struct {
        attempt: u32,
        err_name: []const u8,
    },
    /// Context projection/compaction fact (session note + trace `compaction`).
    context_compaction: context_mod.CompactionEvent,
};

/// Sink errors. `OutOfMemory` is a typed allocator failure; `SinkFailed` is a
/// visible durable-adapter failure (e.g. trace serialization/path fault) that
/// the loop maps to the existing `RunError.TraceFailed` terminal category.
pub const SinkError = error{
    OutOfMemory,
    SinkFailed,
};

pub const LoopEventSinkVTable = struct {
    /// Emit one borrowed event. Slices inside `event` are valid only for the
    /// duration of this call. Return `SinkError` to stop the run (never swallow).
    emit: *const fn (ptr: ?*anyopaque, event: LoopEvent) SinkError!void,
};

/// Borrowed, fallible source-event sink. Required dependency of `loop.run`.
/// A low-level host may explicitly install a discard sink; missing is not
/// silently normalized to discard.
pub const LoopEventSink = struct {
    ptr: ?*anyopaque = null,
    vtable: *const LoopEventSinkVTable,

    pub fn emit(self: LoopEventSink, event: LoopEvent) SinkError!void {
        return self.vtable.emit(self.ptr, event);
    }

    /// Explicitly-named discard sink: drops every event. A low-level trusted
    /// host selects this explicitly; the product Agent never uses it.
    pub fn discard() LoopEventSink {
        return .{
            .ptr = null,
            .vtable = &discard_vtable,
        };
    }
};

const discard_vtable: LoopEventSinkVTable = .{
    .emit = discardEmit,
};

fn discardEmit(_: ?*anyopaque, _: LoopEvent) SinkError!void {
    return;
}

test "discard sink swallows events without error" {
    const sink = LoopEventSink.discard();
    try sink.emit(.{ .turn_start = 1 });
    try sink.emit(.{ .assistant_message = "hi" });
}