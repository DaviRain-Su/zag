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

    /// Low-level stderr logger **without** redaction (explicit bypass).
    /// Product Agent/CLI paths must use `logEventRedacted` instead.
    /// Named `*Unredacted` so silent raw bypass is not a default-looking API.
    pub fn stderrLogUnredacted() Observer {
        return .{
            .ptr = null,
            .on_event = logToStderrUnredacted,
        };
    }
};

fn logToStderrUnredacted(_: ?*anyopaque, event: Event) void {
    logEventRaw(event);
}

/// Private raw formatter for the unredacted stderr observer only.
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

/// Owned redacted fields prepared for one verbose log line.
/// On OOM preparation returns null and the line must be dropped (never raw).
pub const PreparedLogLine = struct {
    kind: enum { assistant, usage, tool_call, tool_result, permission_info, permission_warn },
    /// Formatted line without trailing newline (heap-owned when non-null text).
    text: ?[]u8 = null,
    /// Usage-only numeric payload (no heap).
    usage: ?message.Usage = null,

    pub fn deinit(self: *PreparedLogLine, gpa: std.mem.Allocator) void {
        if (self.text) |t| gpa.free(t);
        self.* = undefined;
    }
};

/// Pure preparation helper actually called by `logEventRedacted`.
/// Returns null on redaction OOM → caller drops the line (fail-closed, never raw).
pub fn prepareEventLogLine(
    gpa: std.mem.Allocator,
    redactor: ?*const redact_mod.Redactor,
    event: Event,
) ?PreparedLogLine {
    switch (event) {
        .assistant_text => |text| {
            if (text.len == 0) return .{ .kind = .assistant, .text = null };
            const red = redact_mod.redactOptional(redactor, gpa, text) catch return null;
            errdefer gpa.free(red);
            const line = std.fmt.allocPrint(gpa, "assistant: {s}", .{red}) catch {
                gpa.free(red);
                return null;
            };
            gpa.free(red);
            return .{ .kind = .assistant, .text = line };
        },
        .usage => |u| {
            return .{ .kind = .usage, .usage = u };
        },
        .tool_call => |call| {
            const name = redact_mod.redactOptional(redactor, gpa, call.name) catch return null;
            defer gpa.free(name);
            const args = redact_mod.redactOptional(redactor, gpa, call.arguments) catch return null;
            defer gpa.free(args);
            const line = std.fmt.allocPrint(gpa, "tool_call {s}({s})", .{ name, args }) catch return null;
            return .{ .kind = .tool_call, .text = line };
        },
        .tool_result => |r| {
            const name = redact_mod.redactOptional(redactor, gpa, r.name) catch return null;
            defer gpa.free(name);
            const body = redact_mod.redactOptional(redactor, gpa, r.body) catch return null;
            defer gpa.free(body);
            const preview_len = @min(body.len, 200);
            const line = std.fmt.allocPrint(gpa, "tool_result {s}: {s}{s}", .{
                name,
                body[0..preview_len],
                if (body.len > preview_len) "…" else "",
            }) catch return null;
            return .{ .kind = .tool_result, .text = line };
        },
        .permission => |p| {
            const risk = p.risk orelse "?";
            const tname = redact_mod.redactOptional(redactor, gpa, p.tool_name) catch return null;
            defer gpa.free(tname);
            if (p.allowed) {
                const line = if (p.remembered)
                    std.fmt.allocPrint(gpa, "permission allow {s} risk={s} (remembered)", .{ tname, risk }) catch return null
                else
                    std.fmt.allocPrint(gpa, "permission allow {s} risk={s}", .{ tname, risk }) catch return null;
                return .{ .kind = .permission_info, .text = line };
            } else {
                const line = std.fmt.allocPrint(gpa, "permission deny {s} risk={s}", .{ tname, risk }) catch return null;
                return .{ .kind = .permission_warn, .text = line };
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
    var prepared = prepareEventLogLine(gpa, redactor, event) orelse return;
    defer prepared.deinit(gpa);
    switch (prepared.kind) {
        .usage => {
            const u = prepared.usage orelse return;
            std.log.info(
                "usage prompt={d} completion={d} total={d}",
                .{ u.prompt_tokens, u.completion_tokens, u.total_tokens },
            );
        },
        .permission_warn => {
            if (prepared.text) |t| std.log.warn("{s}", .{t});
        },
        else => {
            if (prepared.text) |t| std.log.info("{s}", .{t});
        },
    }
}

test "prepareEventLogLine redacts configured key and common patterns" {
    const gpa = std.testing.allocator;
    const secret = redact_mod.testing.fake_api_key;
    var r = try redact_mod.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();

    {
        var line = prepareEventLogLine(gpa, &r, .{ .assistant_text = "hold " ++ secret }) orelse
            return error.TestUnexpectedResult;
        defer line.deinit(gpa);
        try std.testing.expect(std.mem.indexOf(u8, line.text.?, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, line.text.?, redact_mod.marker) != null);
    }
    {
        const args = "{\"token\":\"" ++ redact_mod.testing.fake_aws ++ "\"}";
        var line = prepareEventLogLine(gpa, &r, .{
            .tool_call = .{ .id = "1", .name = "run", .arguments = args },
        }) orelse return error.TestUnexpectedResult;
        defer line.deinit(gpa);
        try std.testing.expect(std.mem.indexOf(u8, line.text.?, redact_mod.testing.fake_aws) == null);
        try std.testing.expect(std.mem.indexOf(u8, line.text.?, redact_mod.marker) != null);
    }
    {
        const body = "result " ++ redact_mod.testing.fake_github;
        var line = prepareEventLogLine(gpa, &r, .{
            .tool_result = .{ .name = "list_dir", .body = body },
        }) orelse return error.TestUnexpectedResult;
        defer line.deinit(gpa);
        try std.testing.expect(std.mem.indexOf(u8, line.text.?, redact_mod.testing.fake_github) == null);
    }
}

test "prepareEventLogLine OOM drops without raw secret" {
    const gpa = std.testing.allocator;
    const secret = redact_mod.testing.fake_api_key;
    var r = try redact_mod.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const out = prepareEventLogLine(failing.allocator(), &r, .{
        .assistant_text = "leak " ++ secret,
    });
    try std.testing.expect(out == null);
    try std.testing.expect(failing.has_induced_failure);
}

test "stderrLogUnredacted is explicit bypass Observer" {
    // Named *Unredacted so raw logging is not a silent default-looking API.
    const obs = Observer.stderrLogUnredacted();
    try std.testing.expect(obs.on_event != null);
}
