//! Optional side-channel for harness events (logging, tests, later tracing).
//! The loop emits events; it does not format logs itself.
//!
//! Verbose logging (h-redact-001): prefer `logEventRedacted` so tool args/results
//! and assistant text never print configured secrets. On redaction OOM the log
//! line is **dropped** (never raw fallback).

const std = @import("std");
const message = @import("message.zig");
const redact_mod = @import("redact.zig");

pub const Event = union(enum) {
    assistant_text: []const u8,
    usage: message.Usage,
    tool_call: message.ToolCall,
    tool_result: struct {
        name: []const u8,
        body: []const u8,
    },
    permission: struct {
        tool_name: []const u8,
        allowed: bool,
        remembered: bool = false,
        /// Descriptor-derived risk name (`read` / `write` / `execute`), when known.
        risk: ?[]const u8 = null,
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

    /// Stderr logger suitable for CLI `-v` **without** redaction (low-level).
    /// Product path uses `logEventRedacted` via Agent.
    pub fn stderrLog() Observer {
        return .{
            .ptr = null,
            .on_event = logToStderr,
        };
    }
};

fn logToStderr(_: ?*anyopaque, event: Event) void {
    // Low-level: no redactor. Prefer logEventRedacted on the product path.
    logEventRaw(event);
}

fn logEventRaw(event: Event) void {
    switch (event) {
        .assistant_text => |text| {
            if (text.len > 0) std.log.info("assistant: {s}", .{text});
        },
        .usage => |u| {
            std.log.info(
                "usage prompt={d} completion={d} total={d}",
                .{ u.prompt_tokens, u.completion_tokens, u.total_tokens },
            );
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
            const risk = p.risk orelse "?";
            if (p.allowed) {
                if (p.remembered) {
                    std.log.info("permission allow {s} risk={s} (remembered)", .{ p.tool_name, risk });
                } else {
                    std.log.info("permission allow {s} risk={s}", .{ p.tool_name, risk });
                }
            } else {
                std.log.warn("permission deny {s} risk={s}", .{ p.tool_name, risk });
            }
        },
    }
}

/// Log one observer event with redaction. On redaction OOM, **drops** the line
/// (verbose is optional) — never prints raw secret-bearing text.
pub fn logEventRedacted(
    gpa: std.mem.Allocator,
    redactor: ?*const redact_mod.Redactor,
    event: Event,
) void {
    switch (event) {
        .assistant_text => |text| {
            if (text.len == 0) return;
            const red = redact_mod.redactOptional(redactor, gpa, text) catch return;
            defer gpa.free(red);
            std.log.info("assistant: {s}", .{red});
        },
        .usage => |u| {
            // Numeric only — no secret surface.
            std.log.info(
                "usage prompt={d} completion={d} total={d}",
                .{ u.prompt_tokens, u.completion_tokens, u.total_tokens },
            );
        },
        .tool_call => |call| {
            const name = redact_mod.redactOptional(redactor, gpa, call.name) catch return;
            defer gpa.free(name);
            const args = redact_mod.redactOptional(redactor, gpa, call.arguments) catch return;
            defer gpa.free(args);
            std.log.info("tool_call {s}({s})", .{ name, args });
        },
        .tool_result => |r| {
            const name = redact_mod.redactOptional(redactor, gpa, r.name) catch return;
            defer gpa.free(name);
            const body = redact_mod.redactOptional(redactor, gpa, r.body) catch return;
            defer gpa.free(body);
            const preview_len = @min(body.len, 200);
            std.log.info("tool_result {s}: {s}{s}", .{
                name,
                body[0..preview_len],
                if (body.len > preview_len) "…" else "",
            });
        },
        .permission => |p| {
            const risk = p.risk orelse "?";
            const tname = redact_mod.redactOptional(redactor, gpa, p.tool_name) catch return;
            defer gpa.free(tname);
            if (p.allowed) {
                if (p.remembered) {
                    std.log.info("permission allow {s} risk={s} (remembered)", .{ tname, risk });
                } else {
                    std.log.info("permission allow {s} risk={s}", .{ tname, risk });
                }
            } else {
                std.log.warn("permission deny {s} risk={s}", .{ tname, risk });
            }
        },
    }
}
