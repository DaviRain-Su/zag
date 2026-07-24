//! Structured run trace — JSONL audit log for one agent run.
//!
//! Enables replaying tool sequence after the fact (Phase 3 observability).

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");

pub const EventKind = enum {
    run_start,
    turn,
    assistant,
    usage,
    tool_call,
    permission,
    jail_deny,
    shell_deny,
    tool_result,
    provider_retry,
    compaction,
    run_end,

    pub fn jsonName(self: EventKind) []const u8 {
        return switch (self) {
            .run_start => "run_start",
            .turn => "turn",
            .assistant => "assistant",
            .usage => "usage",
            .tool_call => "tool_call",
            .permission => "permission",
            .jail_deny => "jail_deny",
            .shell_deny => "shell_deny",
            .tool_result => "tool_result",
            .provider_retry => "provider_retry",
            .compaction => "compaction",
            .run_end => "run_end",
        };
    }
};

pub const Trace = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Relative path for JSONL output; null = memory-only (tests).
    path: ?[]const u8 = null,
    /// Accumulated lines (each ends with \n).
    buf: std.ArrayList(u8) = .empty,
    event_count: u32 = 0,
    finished: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) Trace {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(self: *Trace) void {
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// Emit run_end once if the trace was started but not closed.
    pub fn finishIfOpen(self: *Trace) void {
        if (self.finished or self.event_count == 0) return;
        self.emitRunEnd(.{ .turns = 0, .ok = true }) catch {};
    }

    pub fn emitRunStart(self: *Trace, meta: struct {
        version: []const u8,
        permission: []const u8,
        shell_policy: []const u8,
        session: ?[]const u8 = null,
    }) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .run_start,
            .version = meta.version,
            .permission = meta.permission,
            .shell_policy = meta.shell_policy,
            .session = meta.session,
        });
    }

    pub fn emitTurn(self: *Trace, turn: u32) std.mem.Allocator.Error!void {
        try self.writeObj(.{ .kind = .turn, .turn = turn });
    }

    pub fn emitAssistant(self: *Trace, text: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{ .kind = .assistant, .text = truncate(text, 500) });
    }

    pub fn emitUsage(self: *Trace, usage: message.AssistantTurn) std.mem.Allocator.Error!void {
        const u = usage.usage orelse return;
        try self.writeObj(.{
            .kind = .usage,
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
            .reasoning_tokens = u.reasoning_tokens,
        });
    }

    pub fn emitProviderRetry(self: *Trace, attempt: u32, err_name: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .provider_retry,
            .attempt = attempt,
            .error_name = err_name,
        });
    }

    pub fn emitToolCall(self: *Trace, call: message.ToolCall) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .tool_call,
            .id = call.id,
            .name = call.name,
            .arguments = truncate(call.arguments, 800),
        });
    }

    pub fn emitPermission(
        self: *Trace,
        tool_name: []const u8,
        risk: []const u8,
        allowed: bool,
        remembered: bool,
    ) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .permission,
            .name = tool_name,
            .risk = risk,
            .allowed = allowed,
            .remembered = remembered,
        });
    }

    pub fn emitJailDeny(self: *Trace, tool_name: []const u8, path: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{ .kind = .jail_deny, .name = tool_name, .path = path });
    }

    pub fn emitShellDeny(self: *Trace, command: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{ .kind = .shell_deny, .command = truncate(command, 200) });
    }

    pub fn emitToolResult(self: *Trace, name: []const u8, body: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .tool_result,
            .name = name,
            .body = truncate(body, 500),
        });
    }

    pub fn emitCompaction(self: *Trace, dropped: usize, summary: []const u8) std.mem.Allocator.Error!void {
        try self.writeObj(.{
            .kind = .compaction,
            .dropped = dropped,
            .summary = truncate(summary, 500),
        });
    }

    pub const RunEndInfo = struct {
        turns: u32,
        ok: bool,
        prompt_tokens: u64 = 0,
        completion_tokens: u64 = 0,
        total_tokens: u64 = 0,
        /// Present when catalog rates made a USD estimate possible.
        estimated_usd: ?f64 = null,
        stop_reason: ?[]const u8 = null,
    };

    pub fn emitRunEnd(self: *Trace, info: RunEndInfo) std.mem.Allocator.Error!void {
        if (self.finished) return;
        try self.writeObj(.{
            .kind = .run_end,
            .turns = info.turns,
            .ok = info.ok,
            .prompt_tokens = if (info.prompt_tokens != 0) info.prompt_tokens else null,
            .completion_tokens = if (info.completion_tokens != 0) info.completion_tokens else null,
            .total_tokens = if (info.total_tokens != 0) info.total_tokens else null,
            .estimated_usd = info.estimated_usd,
            .stop_reason = info.stop_reason,
        });
        self.finished = true;
        try self.flush();
    }

    pub fn flush(self: *Trace) std.mem.Allocator.Error!void {
        const p = self.path orelse return;
        if (std.fs.path.dirname(p)) |dir_path| {
            if (dir_path.len > 0) {
                Io.Dir.cwd().createDirPath(self.io, dir_path) catch return;
            }
        }
        Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = p,
            .data = self.buf.items,
            .flags = .{ .truncate = true },
        }) catch {};
    }

    fn writeObj(self: *Trace, fields: anytype) std.mem.Allocator.Error!void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };

        s.beginObject() catch return error.OutOfMemory;
        s.objectField("seq") catch return error.OutOfMemory;
        s.write(self.event_count) catch return error.OutOfMemory;
        self.event_count += 1;

        inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| {
            const value = @field(fields, f.name);
            if (comptime std.mem.eql(u8, f.name, "kind")) {
                const kind: EventKind = value;
                s.objectField("kind") catch return error.OutOfMemory;
                s.write(kind.jsonName()) catch return error.OutOfMemory;
                continue;
            }
            const T = @TypeOf(value);
            if (@typeInfo(T) == .optional) {
                if (value) |v| {
                    s.objectField(f.name) catch return error.OutOfMemory;
                    s.write(v) catch return error.OutOfMemory;
                }
            } else {
                s.objectField(f.name) catch return error.OutOfMemory;
                s.write(value) catch return error.OutOfMemory;
            }
        }
        s.endObject() catch return error.OutOfMemory;
        out.writer.writeAll("\n") catch return error.OutOfMemory;

        self.buf.appendSlice(self.gpa, out.written()) catch return error.OutOfMemory;
    }
};

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

test "trace accumulates json lines" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null);
    defer t.deinit();
    try t.emitRunStart(.{
        .version = "0.3.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitTurn(1);
    try t.emitToolCall(.{ .id = "c1", .name = "list_dir", .arguments = "{}" });
    try t.emitRunEnd(.{ .turns = 1, .ok = true });
    try std.testing.expect(t.event_count == 4);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "run_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "list_dir") != null);
}
