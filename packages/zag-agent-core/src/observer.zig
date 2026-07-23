//! Optional side-channel for harness events (logging, tests, later tracing).
//! The loop emits events; it does not format logs itself.

const std = @import("std");
const message = @import("message.zig");

pub const Event = union(enum) {
    assistant_text: []const u8,
    tool_call: message.ToolCall,
    tool_result: struct {
        name: []const u8,
        body: []const u8,
    },
    permission: struct {
        tool_name: []const u8,
        allowed: bool,
    },
};

pub const Observer = struct {
    ptr: ?*anyopaque = null,
    on_event: ?*const fn (ptr: ?*anyopaque, event: Event) void = null,

    pub fn emit(self: Observer, event: Event) void {
        if (self.on_event) |f| f(self.ptr, event);
    }

    pub fn none() Observer {
        return .{};
    }

    /// Stderr logger suitable for CLI `-v`.
    pub fn stderrLog() Observer {
        return .{
            .ptr = null,
            .on_event = logToStderr,
        };
    }
};

fn logToStderr(_: ?*anyopaque, event: Event) void {
    switch (event) {
        .assistant_text => |text| {
            if (text.len > 0) std.log.info("assistant: {s}", .{text});
        },
        .tool_call => |call| {
            std.log.info("tool_call {s}({s})", .{ call.name, call.arguments });
        },
        .tool_result => |r| {
            const preview_len = @min(r.body.len, 200);
            std.log.info("tool_result {s}: {s}{s}", .{
                r.name,
                r.body[0..preview_len],
                if (r.body.len > preview_len) "…" else "",
            });
        },
        .permission => |p| {
            if (p.allowed) {
                std.log.info("permission allow {s}", .{p.tool_name});
            } else {
                std.log.warn("permission deny {s}", .{p.tool_name});
            }
        },
    }
}
