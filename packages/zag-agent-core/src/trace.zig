//! Structured run trace — versioned JSONL audit log for one agent reply-run.
//!
//! Lifecycle (h-trace-001):
//! - `run_start` carries `schema_version` + Zag version.
//! - Exactly one `run_end` per open run; the coding-agent facade owns terminals.
//! - Explicit path: symlink-aware Guard jail, non-destructive preflight, atomic replace.
//! - Per-reply buffer: durable file holds the **latest completed reply** only.
//! - Events serialize on a stack fixed buffer (no heap for JSON).
//! - Nonterminal appends preserve a dedicated terminal reserve in `buf`; terminal
//!   appends consume only that pre-reserved capacity (no alloc after run_start).
//! - `writeObj` is transactional (seq/buffer unchanged on failure).
//! - `deinit` only releases memory; it never invents a successful terminal.
//!
//! Containment is software check-time on a trusted host (same as workspace tools).
//! Residual TOCTOU between Guard check and createFileAtomic is documented — not
//! an OS sandbox.
//!
//! Unavoidable limit: an unwritable filesystem cannot durably record its own
//! failure. On final-persist failure after a normal outcome, memory holds a
//! single `ok=false, stop_reason=trace_error` terminal; prior durable bytes unchanged.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const message = @import("message.zig");
const workspace = @import("workspace.zig");

/// Stable exported trace schema version written on every `run_start`.
pub const current_schema_version: u32 = 1;

/// Stack buffer for one event JSON line (fields are truncated to fit).
const event_stack_size: usize = 2048;
/// Pre-reserved free capacity for a failure/success `run_end` (no post-start alloc).
pub const terminal_reserve: usize = 384;
/// Bound stop_reason so terminal line is provably ≤ terminal_reserve.
const max_stop_reason_len: usize = 48;

/// Public trace errors. Filesystem failures are **not** mapped to OutOfMemory.
pub const Error = error{
    OutOfMemory,
    /// Explicit path create/write/flush/replace failed (or parent unwritable).
    TraceIoFailed,
    /// Path absolute/escape/symlink-escape/dangling/resolve-fail (fail-closed).
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
    /// Workspace root directory for path jail + atomic I/O (typically `Dir.cwd()`).
    cwd: Io.Dir,
    /// Relative path for JSONL output; null = memory-only.
    path: ?[]const u8 = null,
    /// Current reply-run lines only.
    buf: std.ArrayList(u8) = .empty,
    event_count: u32 = 0,
    run_open: bool = false,
    finished: bool = false,
    terminal_count: u32 = 0,
    /// Last successfully emitted turn number (0 if none); used by facade failRun.
    last_emitted_turn: u32 = 0,
    fail_before_replace: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    pub fn init(gpa: std.mem.Allocator, io: Io, path: ?[]const u8, cwd: Io.Dir) Trace {
        return .{ .gpa = gpa, .io = io, .path = path, .cwd = cwd };
    }

    pub fn deinit(self: *Trace) void {
        self.buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// Lexical relative-path check only (no symlink resolve). Prefer Guard for I/O paths.
    pub fn validatePath(path: []const u8) Error!void {
        workspace.checkToolPath(path) catch return error.InvalidPath;
    }

    pub fn resetForReply(self: *Trace) void {
        self.buf.clearRetainingCapacity();
        self.event_count = 0;
        self.run_open = false;
        self.finished = false;
        self.terminal_count = 0;
        self.last_emitted_turn = 0;
    }

    /// Symlink-aware create containment relative to workspace `cwd`.
    /// Maps escape/dangling/resolve to `InvalidPath`; OOM preserved.
    /// Trusted-host check-time only — residual TOCTOU before createFileAtomic.
    fn assertPathContained(self: *Trace, p: []const u8) Error!void {
        var guard = workspace.guardFrom(self.gpa, self.io, self.cwd, null) catch |err| {
            return mapContain(err);
        };
        defer guard.deinit(self.gpa);
        guard.checkCreate(self.gpa, self.io, self.cwd, p) catch |err| {
            return mapContain(err);
        };
    }

    /// Non-destructive preflight: Guard jail → createFileAtomic → deinit without replace.
    pub fn preflight(self: *Trace) Error!void {
        const p = self.path orelse return;
        try validatePath(p);
        try self.assertPathContained(p);
        var atomic = self.cwd.createFileAtomic(self.io, p, .{
            .make_path = true,
            .replace = true,
        }) catch return error.TraceIoFailed;
        atomic.deinit(self.io);
    }

    /// Reset, preflight, reserve terminal capacity (pre-start allocations only).
    pub fn beginReply(self: *Trace) Error!void {
        self.resetForReply();
        try self.preflight();
        // Guarantee free space for a later terminal append without allocating.
        self.buf.ensureTotalCapacity(self.gpa, terminal_reserve) catch return error.OutOfMemory;
    }

    pub fn emitRunStart(self: *Trace, meta: struct {
        version: []const u8,
        permission: []const u8,
        shell_policy: []const u8,
        session: ?[]const u8 = null,
    }) Error!void {
        if (self.run_open) return;
        try self.writeObj(.{
            .kind = .run_start,
            .schema_version = current_schema_version,
            .version = truncate(meta.version, 64),
            .permission = truncate(meta.permission, 16),
            .shell_policy = truncate(meta.shell_policy, 16),
            .session = if (meta.session) |s| truncate(s, 200) else null,
        }, .normal);
        self.run_open = true;
        self.finished = false;
    }

    pub fn emitTurn(self: *Trace, turn: u32) Error!void {
        try self.writeObj(.{ .kind = .turn, .turn = turn }, .normal);
        self.last_emitted_turn = turn;
    }

    pub fn emitAssistant(self: *Trace, text: []const u8) Error!void {
        try self.writeObj(.{ .kind = .assistant, .text = truncate(text, 500) }, .normal);
    }

    pub fn emitUsage(self: *Trace, usage: message.AssistantTurn) Error!void {
        const u = usage.usage orelse return;
        try self.writeObj(.{
            .kind = .usage,
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
            .reasoning_tokens = u.reasoning_tokens,
        }, .normal);
    }

    pub fn emitProviderRetry(self: *Trace, attempt: u32, err_name: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .provider_retry,
            .attempt = attempt,
            .error_name = truncate(err_name, 64),
        }, .normal);
    }

    pub fn emitToolCall(self: *Trace, call: message.ToolCall) Error!void {
        try self.writeObj(.{
            .kind = .tool_call,
            .id = truncate(call.id, 64),
            .name = truncate(call.name, 64),
            .arguments = truncate(call.arguments, 800),
        }, .normal);
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
            .name = truncate(tool_name, 64),
            .risk = truncate(risk, 16),
            .allowed = allowed,
            .remembered = remembered,
        }, .normal);
    }

    pub fn emitJailDeny(self: *Trace, tool_name: []const u8, path: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .jail_deny,
            .name = truncate(tool_name, 64),
            .path = truncate(path, 200),
        }, .normal);
    }

    pub fn emitShellDeny(self: *Trace, command: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .shell_deny,
            .command = truncate(command, 200),
        }, .normal);
    }

    pub fn emitToolResult(self: *Trace, name: []const u8, body: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .tool_result,
            .name = truncate(name, 64),
            .body = truncate(body, 500),
        }, .normal);
    }

    pub fn emitCompaction(self: *Trace, dropped: usize, summary: []const u8) Error!void {
        try self.writeObj(.{
            .kind = .compaction,
            .dropped = dropped,
            .summary = truncate(summary, 500),
        }, .normal);
    }

    pub const RunEndInfo = struct {
        turns: u32,
        ok: bool,
        prompt_tokens: u64 = 0,
        completion_tokens: u64 = 0,
        total_tokens: u64 = 0,
        estimated_usd: ?f64 = null,
        stop_reason: ?[]const u8 = null,
    };

    pub fn emitRunEnd(self: *Trace, info: RunEndInfo) Error!void {
        if (!self.run_open or self.finished) return;

        const snap_len = self.buf.items.len;
        const snap_seq = self.event_count;

        try self.appendRunEndLine(info);

        self.persistAtomic() catch {
            self.buf.shrinkRetainingCapacity(snap_len);
            self.event_count = snap_seq;

            const mem_info: RunEndInfo = if (info.ok) .{
                .turns = info.turns,
                .ok = false,
                .prompt_tokens = info.prompt_tokens,
                .completion_tokens = info.completion_tokens,
                .total_tokens = info.total_tokens,
                .estimated_usd = info.estimated_usd,
                .stop_reason = "trace_error",
            } else info;

            self.appendRunEndLine(mem_info) catch |werr| return werr;
            self.markTerminalCommitted();
            return error.TraceIoFailed;
        };

        self.markTerminalCommitted();
    }

    fn markTerminalCommitted(self: *Trace) void {
        self.run_open = false;
        self.finished = true;
        self.terminal_count = 1;
    }

    fn appendRunEndLine(self: *Trace, info: RunEndInfo) Error!void {
        const reason: ?[]const u8 = if (info.stop_reason) |r| truncate(r, max_stop_reason_len) else null;
        try self.writeObj(.{
            .kind = .run_end,
            .turns = info.turns,
            .ok = info.ok,
            .prompt_tokens = if (info.prompt_tokens != 0) info.prompt_tokens else null,
            .completion_tokens = if (info.completion_tokens != 0) info.completion_tokens else null,
            .total_tokens = if (info.total_tokens != 0) info.total_tokens else null,
            .estimated_usd = info.estimated_usd,
            .stop_reason = reason,
        }, .terminal);
    }

    /// Re-check Guard, then atomic write+replace. Destination unchanged on failure.
    pub fn persistAtomic(self: *Trace) Error!void {
        const p = self.path orelse return;
        try self.assertPathContained(p);

        var atomic = self.cwd.createFileAtomic(self.io, p, .{
            .make_path = true,
            .replace = true,
        }) catch return error.TraceIoFailed;
        defer atomic.deinit(self.io);

        var buffer: [4096]u8 = undefined;
        var file_writer = atomic.file.writer(self.io, &buffer);
        const w = &file_writer.interface;
        w.writeAll(self.buf.items) catch return error.TraceIoFailed;
        file_writer.flush() catch return error.TraceIoFailed;

        if (builtin.is_test and self.fail_before_replace) return error.TraceIoFailed;

        atomic.replace(self.io) catch return error.TraceIoFailed;
    }

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

    const WriteMode = enum {
        /// May grow buf via gpa, always leaving `terminal_reserve` free after append.
        normal,
        /// Consume only pre-reserved free capacity; never allocates.
        terminal,
    };

    /// Stack-serialize a complete line, then capacity-check, then mutate.
    /// On failure: buffer length and `event_count` unchanged.
    fn writeObj(self: *Trace, fields: anytype, mode: WriteMode) Error!void {
        var stack: [event_stack_size]u8 = undefined;
        var w: Io.Writer = .fixed(&stack);
        var s: std.json.Stringify = .{ .writer = &w };

        const seq = self.event_count;
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("seq") catch return error.OutOfMemory;
        s.write(seq) catch return error.OutOfMemory;

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
        w.writeAll("\n") catch return error.OutOfMemory;

        const line = w.buffered();

        switch (mode) {
            .normal => {
                // After append, keep terminal_reserve free for a no-alloc run_end.
                self.buf.ensureUnusedCapacity(self.gpa, line.len + terminal_reserve) catch
                    return error.OutOfMemory;
                self.buf.appendSliceAssumeCapacity(line);
            },
            .terminal => {
                // No allocation: only use capacity already reserved.
                if (line.len > terminal_reserve) return error.OutOfMemory;
                const free = self.buf.capacity - self.buf.items.len;
                if (free < line.len) return error.OutOfMemory;
                self.buf.appendSliceAssumeCapacity(line);
            },
        }
        self.event_count = seq + 1;
    }
};

fn mapContain(err: workspace.ContainError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Escape, dangling, resolve, lexical — fail closed as InvalidPath.
        error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed, error.NotFound => error.InvalidPath,
    };
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

pub const testing = struct {
    pub fn setFailBeforeReplace(t: *Trace, enabled: bool) void {
        if (builtin.is_test) t.fail_before_replace = enabled;
    }
};

// ── Unit tests ──────────────────────────────────────────────────────────────

test "trace accumulates json lines with schema_version" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    defer t.deinit();
    try t.beginReply();
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
    try std.testing.expectEqual(@as(u32, 1), t.last_emitted_turn);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "schema_version") != null);
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_end"));
}

test "duplicate run_end does not write a second terminal" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    defer t.deinit();
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });
    try t.emitRunEnd(.{ .turns = 99, .ok = true, .stop_reason = "completed" });
    try std.testing.expectEqual(@as(u32, 1), t.terminal_count);
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_end"));
}

test "deinit does not invent a terminal" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitTurn(1);
    try std.testing.expect(t.run_open);
    try std.testing.expectEqual(@as(u32, 0), t.terminal_count);
    t.deinit();
}

test "validatePath rejects absolute and escape paths" {
    try std.testing.expectError(error.InvalidPath, Trace.validatePath("/tmp/x.jsonl"));
    try std.testing.expectError(error.InvalidPath, Trace.validatePath("../outside.jsonl"));
    try Trace.validatePath(".zag/traces/latest.jsonl");
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

    var t = Trace.init(gpa, io, bad_path, Io.Dir.cwd());
    defer t.deinit();
    // Guard or createFileAtomic may fail; either is fail-closed.
    const err = t.preflight();
    try std.testing.expect(err == error.TraceIoFailed or err == error.InvalidPath);
}

test "preflight preserves existing destination bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-preflight-preserve";
    const path = ".zag-test-trace-preflight-preserve/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const original = "{\"kind\":\"prior\"}\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    var t = Trace.init(gpa, io, path, Io.Dir.cwd());
    defer t.deinit();
    try t.preflight();

    const after = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "atomic flush replaces destination; fail-before-replace preserves prior and no temp residue" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-atomic";
    const path = ".zag-test-trace-atomic/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const original = "{\"kind\":\"old\"}\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    {
        var t = Trace.init(gpa, io, path, Io.Dir.cwd());
        defer t.deinit();
        try t.beginReply();
        try t.emitRunStart(.{
            .version = "0.5.0",
            .permission = "ask",
            .shell_policy = "protect",
        });
        testing.setFailBeforeReplace(&t, true);
        try std.testing.expectError(error.TraceIoFailed, t.emitRunEnd(.{
            .turns = 1,
            .ok = true,
            .stop_reason = "completed",
        }));
        try std.testing.expectEqual(@as(u32, 1), t.terminal_count);
        try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "trace_error") != null);
        try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "\"ok\":true") == null);

        const after = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(original, after);

        // No leftover atomic temp files (hex names) in the directory.
        var dir = try Io.Dir.cwd().openDir(io, dir_name, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file) {
                try std.testing.expect(std.mem.eql(u8, entry.name, "run.jsonl"));
            }
        }
    }

    {
        var t = Trace.init(gpa, io, path, Io.Dir.cwd());
        defer t.deinit();
        try t.beginReply();
        try t.emitRunStart(.{
            .version = "0.5.0",
            .permission = "ask",
            .shell_policy = "protect",
        });
        try t.emitRunEnd(.{ .turns = 0, .ok = true, .stop_reason = "completed" });
        const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
        defer gpa.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"old\"") == null);
    }
}

/// Reduce free capacity to exactly `terminal_reserve` so the next normal write must grow.
fn padToTerminalReserveOnly(t: *Trace) !void {
    const free = t.buf.capacity - t.buf.items.len;
    if (free > terminal_reserve) {
        const pad = free - terminal_reserve;
        try t.buf.appendNTimes(t.gpa, ' ', pad);
    }
}

test "terminal still commits after post-start ensureUnusedCapacity OOM" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    defer t.deinit();
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try std.testing.expect(t.run_open);
    try std.testing.expect(t.buf.capacity - t.buf.items.len >= terminal_reserve);

    // Leave only terminal_reserve free so emitTurn must allocate to grow.
    try padToTerminalReserveOnly(&t);
    try std.testing.expectEqual(terminal_reserve, t.buf.capacity - t.buf.items.len);

    var failing_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const prev = t.gpa;
    t.gpa = failing_state.allocator();
    try std.testing.expectError(error.OutOfMemory, t.emitTurn(1));
    // State unchanged after failed nonterminal (seq/len from pad, not turn).
    const len_after_fail = t.buf.items.len;
    const seq_after_fail = t.event_count;

    // Terminal: stack serialize + pre-reserved free only — works under failing gpa.
    try t.emitRunEnd(.{ .turns = 0, .ok = false, .stop_reason = "out_of_memory" });
    t.gpa = prev;

    try std.testing.expectEqual(@as(u32, 1), t.terminal_count);
    try std.testing.expect(t.buf.items.len > len_after_fail);
    try std.testing.expect(t.event_count == seq_after_fail + 1);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "out_of_memory") != null);
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_end"));
}

test "writeObj is transactional under capacity OOM" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    defer t.deinit();
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try padToTerminalReserveOnly(&t);
    const len_before = t.buf.items.len;
    const seq_before = t.event_count;

    var failing_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const prev = t.gpa;
    t.gpa = failing_state.allocator();
    try std.testing.expectError(error.OutOfMemory, t.emitTurn(1));
    t.gpa = prev;

    try std.testing.expectEqual(len_before, t.buf.items.len);
    try std.testing.expectEqual(seq_before, t.event_count);
    // Restore capacity headroom with real gpa then succeed.
    try t.emitTurn(1);
    try std.testing.expectEqual(seq_before + 1, t.event_count);
}

test "parent symlink outside workspace denied before atomic; outside bytes unchanged" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Nest under tmpDir: Guard root = ws, outside is sibling (same as workspace fixtures).
    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.jsonl", .data = "OUTSIDE-KEEP\n" });

    var ws = try parent.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    ws.symLink(io, "../outside", "escape", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => |e| return e,
    };

    var t = Trace.init(gpa, io, "escape/trace.jsonl", ws);
    defer t.deinit();
    try std.testing.expectError(error.InvalidPath, t.preflight());

    const after = try parent.dir.readFileAlloc(io, "outside/secret.jsonl", gpa, .limited(64));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("OUTSIDE-KEEP\n", after);

    var outside = try parent.dir.openDir(io, "outside", .{ .iterate = true });
    defer outside.close(io);
    var it = outside.iterate();
    var file_count: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            file_count += 1;
            try std.testing.expectEqualStrings("secret.jsonl", entry.name);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), file_count);
}

test "contained parent symlink allows preflight and persist" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/real_dir");
    var ws = try parent.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    ws.symLink(io, "real_dir", "link_dir", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => |e| return e,
    };

    var t = Trace.init(gpa, io, "link_dir/run.jsonl", ws);
    defer t.deinit();
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 0, .ok = true, .stop_reason = "completed" });

    const raw = try ws.readFileAlloc(io, "link_dir/run.jsonl", gpa, .limited(8 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "run_end") != null);
    const via_real = try ws.readFileAlloc(io, "real_dir/run.jsonl", gpa, .limited(8 * 1024));
    defer gpa.free(via_real);
    try std.testing.expectEqualStrings(raw, via_real);
}

test "resetForReply clears buffer for latest-run semantics" {
    const gpa = std.testing.allocator;
    var t = Trace.init(gpa, std.testing.io, null, std.Io.Dir.cwd());
    defer t.deinit();
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });
    try t.beginReply();
    try std.testing.expectEqual(@as(u32, 0), t.event_count);
    try std.testing.expectEqual(@as(usize, 0), t.buf.items.len);
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try t.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });
    try std.testing.expectEqual(@as(u32, 1), t.countKind("run_start"));
    try std.testing.expect(std.mem.indexOf(u8, t.buf.items, "\"seq\":0") != null);
}

test "current_schema_version is stable exported constant" {
    try std.testing.expectEqual(@as(u32, 1), current_schema_version);
}
