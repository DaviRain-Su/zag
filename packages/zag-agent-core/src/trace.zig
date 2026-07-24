//! Structured run trace — versioned JSONL audit log for one agent run.
//!
//! Lifecycle (h-trace-001):
//! - `run_start` carries `schema_version` + Zag version.
//! - Exactly one `run_end` per open run; the coding-agent facade owns terminals.
//! - Explicit path persistence is fail-closed: flush/preflight return `TraceIoFailed`.
//! - `deinit` only releases memory; it never invents a successful terminal.
//!
//! Compatibility: additive fields OK within a schema version; unknown
//! `schema_version` must fail in strict readers (this package only writes).

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const workspace = @import("workspace.zig");

/// Stable exported trace schema version written on every `run_start`.
pub const current_schema_version: u32 = 1;

/// Public trace errors. Filesystem failures are **not** mapped to OutOfMemory.
pub const Error = error{
    OutOfMemory,
    /// Explicit trace path create/write/flush failed (or parent dir unwritable).
    TraceIoFailed,
    /// Trace path is absolute, escapes workspace, empty, or otherwise invalid.
    InvalidPath,
};

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
    /// Relative path for JSONL output; null = memory-only (tests / no audit file).
    path: ?[]const u8 = null,
    /// Accumulated lines (each ends with \n). May hold multiple completed runs.
    buf: std.ArrayList(u8) = .empty,
    event_count: u32 = 0,
    /// True between a successful `emitRunStart` and its matching `emitRunEnd`.
    run_open: bool = false,
    /// True after at least one `run_end` was written (for this Trace instance).
    finished: bool = false,
    /// Count of `run_end` events written (duplicate-terminal guard metric).
    terminal_count: u32 = 0,
    /// Preflight completed successfully for an explicit path (or memory-only).
    preflight_ok: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) Trace {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    /// Release buffers only. Never invents `run_end` / success.
    pub fn deinit(self: *Trace) void {
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// Lexical workspace-safe relative path (same rules as session paths).
    /// Does not claim OS sandbox / TOCTOU guarantees.
    pub fn validatePath(path: []const u8) Error!void {
        workspace.checkToolPath(path) catch return error.InvalidPath;
    }

    /// Fail-closed check before provider work when an explicit path is set.
    /// Creates parent dirs and probes writeability. Memory-only traces no-op.
    /// Idempotent after first success.
    pub fn preflight(self: *Trace) Error!void {
        if (self.preflight_ok) return;
        const p = self.path orelse {
            self.preflight_ok = true;
            return;
        };
        try validatePath(p);
        if (std.fs.path.dirname(p)) |dir_path| {
            if (dir_path.len > 0) {
                Io.Dir.cwd().createDirPath(self.io, dir_path) catch return error.TraceIoFailed;
            }
        }
        // Probe: open/create truncate then write empty — proves path is a writable file.
        Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = p,
            .data = "",
            .flags = .{ .truncate = true },
        }) catch return error.TraceIoFailed;
        self.preflight_ok = true;
    }

    pub fn emitRunStart(self: *Trace, meta: struct {
        version: []const u8,
        permission: []const u8,
        shell_policy: []const u8,
        session: ?[]const u8 = null,
    }) Error!void {
        if (self.run_open) return; // already open — no second start mid-run
        try self.writeObj(.{
            .kind = .run_start,
            .schema_version = current_schema_version,
            .version = meta.version,
            .permission = meta.permission,
            .shell_policy = meta.shell_policy,
            .session = meta.session,
        });
        self.run_open = true;
        self.finished = false;
    }

    pub fn emitTurn(self: *Trace, turn: u32) Error!void {
        try self.writeObj(.{ .kind = .turn, .turn = turn });
    }

    pub fn emitAssistant(self: *Trace, text: []const u8) Error!void {
        try self.writeObj(.{ .kind = .assistant, .text = truncate(text, 500) });
    }

    pub fn emitUsage(self: *Trace, usage: message.AssistantTurn) Error!void {
        const u = usage.usage orelse return;
        try self.writeObj(.{
            .kind = .usage,
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
            .reasoning_tokens = u.reasoning_tokens,
        });
    }

    pub fn emitProviderRetry(self: *Trace, attempt: u32, err_name: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .provider_retry,
            .attempt = attempt,
            .error_name = err_name,
        });
    }

    pub fn emitToolCall(self: *Trace, call: message.ToolCall) Error!void {
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
    ) Error!void {
        try self.writeObj(.{
            .kind = .permission,
            .name = tool_name,
            .risk = risk,
            .allowed = allowed,
            .remembered = remembered,
        });
    }

    pub fn emitJailDeny(self: *Trace, tool_name: []const u8, path: []const u8) Error!void {
        try self.writeObj(.{ .kind = .jail_deny, .name = tool_name, .path = path });
    }

    pub fn emitShellDeny(self: *Trace, command: []const u8) Error!void {
        try self.writeObj(.{ .kind = .shell_deny, .command = truncate(command, 200) });
    }

    pub fn emitToolResult(self: *Trace, name: []const u8, body: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .tool_result,
            .name = name,
            .body = truncate(body, 500),
        });
    }

    pub fn emitCompaction(self: *Trace, dropped: usize, summary: []const u8) Error!void {
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

    /// Emit exactly one terminal for the open run. Duplicate calls are no-ops
    /// (do not write a second `run_end`). Never invents success when no run is open.
    pub fn emitRunEnd(self: *Trace, info: RunEndInfo) Error!void {
        if (!self.run_open) return;
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
        self.run_open = false;
        self.finished = true;
        self.terminal_count += 1;
        try self.flush();
    }

    /// Persist buffer to the explicit path. Memory-only no-ops.
    /// Fail-closed: I/O errors → `TraceIoFailed` (never swallowed).
    pub fn flush(self: *Trace) Error!void {
        const p = self.path orelse return;
        if (std.fs.path.dirname(p)) |dir_path| {
            if (dir_path.len > 0) {
                Io.Dir.cwd().createDirPath(self.io, dir_path) catch return error.TraceIoFailed;
            }
        }
        Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = p,
            .data = self.buf.items,
            .flags = .{ .truncate = true },
        }) catch return error.TraceIoFailed;
    }

    /// Count occurrences of `"kind":"run_end"` in the in-memory buffer.
    pub fn countKind(self: *const Trace, kind_name: []const u8) u32 {
        var count: u32 = 0;
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"kind\":\"{s}\"", .{kind_name}) catch return 0;
        var rest = self.buf.items;
        while (std.mem.indexOf(u8, rest, needle)) |idx| {
            count += 1;
            rest = rest[idx + needle.len ..];
        }
        return count;
    }

    fn writeObj(self: *Trace, fields: anytype) Error!void {
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

// ── Unit tests ──────────────────────────────────────────────────────────────

test "trace accumulates json lines with schema_version" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null);
    defer t.deinit();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitTurn(1);
    try t.emitToolCall(.{ .id = "c1", .name = "list_dir", .arguments = "{}" });
    try t.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });
    try std.testing.expect(t.event_count == 4);
    try std.testing.expect(t.terminal_count == 1);
    try std.testing.expect(!t.run_open);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "run_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "schema_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "list_dir") != null);
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_end"));
    // schema_version value is current
    var expected: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expected, "\"schema_version\":{d}", .{current_schema_version});
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, needle) != null);
}

test "duplicate run_end does not write a second terminal" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null);
    defer t.deinit();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });
    try t.emitRunEnd(.{ .turns = 99, .ok = true, .stop_reason = "completed" });
    try std.testing.expectEqual(@as(u32, 1), t.terminal_count);
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_end"));
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "\"turns\":99") == null);
}

test "deinit does not invent a terminal" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null);
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitTurn(1);
    // Abandon without run_end.
    try std.testing.expect(t.run_open);
    try std.testing.expectEqual(@as(u32, 0), t.terminal_count);
    t.deinit();
}

test "validatePath rejects absolute and escape paths" {
    try std.testing.expectError(error.InvalidPath, Trace.validatePath("/tmp/x.jsonl"));
    try std.testing.expectError(error.InvalidPath, Trace.validatePath("../outside.jsonl"));
    try Trace.validatePath(".zag/traces/latest.jsonl");
    try Trace.validatePath("out/run.jsonl");
}

test "preflight fails when parent path is a file (not a directory)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-preflight";
    const blocker = ".zag-test-trace-preflight/not-a-dir";
    const bad_path = ".zag-test-trace-preflight/not-a-dir/trace.jsonl";

    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blocker, .data = "file-not-dir" });

    var t = Trace.init(gpa, io, bad_path);
    defer t.deinit();
    try std.testing.expectError(error.TraceIoFailed, t.preflight());
    try std.testing.expect(!t.preflight_ok);
}

test "preflight + flush roundtrip to relative path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-ok";
    const path = ".zag-test-trace-ok/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var t = Trace.init(gpa, io, path);
    defer t.deinit();
    try t.preflight();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 0, .ok = true, .stop_reason = "completed" });

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "run_end") != null);
}

test "current_schema_version is stable exported constant" {
    try std.testing.expectEqual(@as(u32, 1), current_schema_version);
}
