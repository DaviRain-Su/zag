//! Headless JSON/NDJSON protocol writer for `zag --json` / `--json-stream`.
//!
//! Public schema version: `headless-v1`. This module is the single place that
//! decides envelope shape, event vocabulary, redaction, and exit-code mapping.
//! It does **not** serialize internal Observer/Trace types directly; it maps
//! them onto the public contract defined in `docs/modules/headless-contract.md`.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");
const redact_mod = coding.redact;
const observer_mod = coding.observer;
const message = core.message;
const loop = core.loop;

pub const HeadlessMode = enum {
    json,
    json_stream,
};

pub const protocol_version = "headless-v1";

/// Stable headless error codes. Each code maps to exactly one exit code.
pub const ErrorCode = enum {
    provider_configuration,
    provider_error,
    invalid_toolset,
    invalid_context,
    out_of_memory,
    session_not_found,
    session_already_exists,
    session_invalid,
    session_unsupported_schema,
    session_busy,
    session_io_failed,
    trace_error,
    required_sandbox_unavailable,

    pub fn jsonName(self: ErrorCode) []const u8 {
        return @tagName(self);
    }

    pub fn exitCode(self: ErrorCode) u8 {
        return switch (self) {
            .provider_configuration => 30,
            .provider_error => 31,
            .invalid_toolset => 32,
            .invalid_context => 33,
            .out_of_memory => 40,
            .session_not_found => 50,
            .session_already_exists => 51,
            .session_invalid => 52,
            .session_unsupported_schema => 53,
            .session_busy => 54,
            .session_io_failed => 55,
            .trace_error => 60,
            .required_sandbox_unavailable => 22,
        };
    }

    pub fn retryable(self: ErrorCode) bool {
        return switch (self) {
            .provider_error => true,
            else => false,
        };
    }

    pub fn category(self: ErrorCode) []const u8 {
        return switch (self) {
            .provider_configuration => "auth",
            .provider_error => "provider",
            .invalid_toolset, .invalid_context => "runtime",
            .out_of_memory => "runtime",
            .session_not_found, .session_already_exists, .session_invalid,
            .session_unsupported_schema, .session_busy, .session_io_failed => "session",
            .trace_error => "runtime",
            .required_sandbox_unavailable => "runtime",
        };
    }
};

/// Terminal/harness error carried through the CLI before serialization.
pub const HeadlessError = struct {
    code: ErrorCode,
    message: []const u8,
};

/// Result terminal `ok` bit. Clean cooperative cancel is ok=true.
pub fn resultOk(stop_reason: loop.StopReason) bool {
    return switch (stop_reason) {
        .completed, .max_turns, .cancelled => true,
        .timeout, .unsupported_control, .provider_error, .session_error,
        .trace_error, .out_of_memory, .invalid_toolset, .invalid_context => false,
    };
}

/// Exit code for a terminal `stop_reason` (headless mode only).
pub fn exitCodeForStopReason(stop_reason: loop.StopReason) u8 {
    return switch (stop_reason) {
        .completed => 0,
        .max_turns => 10,
        .cancelled => 11,
        .timeout => 20,
        .unsupported_control => 21,
        .provider_error => 31,
        .session_error => 55,
        .trace_error => 60,
        .out_of_memory => 40,
        .invalid_toolset => 32,
        .invalid_context => 33,
    };
}

pub const HeadlessWriter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    mode: HeadlessMode,
    redactor: ?*const redact_mod.Redactor,
    halted: bool = false,
    halt_error: HeadlessError = undefined,
    terminal_written: bool = false,
    last_assistant_len: usize = 0,

    const Self = @This();

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        out: *Io.Writer,
        mode: HeadlessMode,
        redactor: ?*const redact_mod.Redactor,
    ) Self {
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .mode = mode,
            .redactor = redactor,
        };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn setRedactor(self: *Self, r: ?*const redact_mod.Redactor) void {
        self.redactor = r;
    }

    pub fn flush(self: *Self) !void {
        try self.out.flush();
    }

    pub fn isHalted(self: *const Self) bool {
        return self.halted;
    }

    pub fn setHalted(self: *Self, err: HeadlessError) void {
        if (!self.halted) {
            self.halted = true;
            self.halt_error = err;
        }
    }

    pub fn haltError(self: *const Self) ?HeadlessError {
        return if (self.halted) self.halt_error else null;
    }

    pub fn hasTerminal(self: *const Self) bool {
        return self.terminal_written;
    }

    /// Stream only: run_start metadata. No secret/path fields.
    pub fn emitRunStart(
        self: *Self,
        zag_version: []const u8,
        permission: []const u8,
        shell_policy: []const u8,
    ) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "run_start",
            .zag_version = zag_version,
            .permission = permission,
            .shell_policy = shell_policy,
        });
    }

    /// Stream only: incremental assistant text since the last event.
    pub fn emitAssistantDelta(self: *Self, full_text: []const u8) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        if (full_text.len <= self.last_assistant_len) return;
        const delta = full_text[self.last_assistant_len..full_text.len];
        const red = try redact_mod.redactOptional(self.redactor, self.gpa, delta);
        defer self.gpa.free(red);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "assistant_delta",
            .text = red,
        });
        self.last_assistant_len = full_text.len;
    }

    /// Stream only: a model-requested tool call (arguments redacted).
    pub fn emitToolCall(self: *Self, call: message.ToolCall) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        const name = try redact_mod.redactOptional(self.redactor, self.gpa, call.name);
        defer self.gpa.free(name);
        const args = try redact_mod.redactOptional(self.redactor, self.gpa, call.arguments);
        defer self.gpa.free(args);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "tool_call",
            .id = call.id,
            .name = name,
            .arguments = args,
        });
    }

    /// Stream only: tool execution result (body redacted).
    pub fn emitToolResult(self: *Self, name: []const u8, body: []const u8) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        const rname = try redact_mod.redactOptional(self.redactor, self.gpa, name);
        defer self.gpa.free(rname);
        const rbody = try redact_mod.redactOptional(self.redactor, self.gpa, body);
        defer self.gpa.free(rbody);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "tool_result",
            .name = rname,
            .body = rbody,
        });
    }

    /// Stream only: permission decision.
    pub fn emitPermission(
        self: *Self,
        tool_name: []const u8,
        allowed: bool,
        remembered: bool,
        risk: ?[]const u8,
    ) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        const tname = try redact_mod.redactOptional(self.redactor, self.gpa, tool_name);
        defer self.gpa.free(tname);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "permission",
            .tool_name = tname,
            .allowed = allowed,
            .remembered = remembered,
            .risk = risk orelse "?",
        });
    }

    /// Stream only: usage report from provider.
    pub fn emitUsage(self: *Self, usage: message.Usage) !void {
        if (self.mode != .json_stream) return;
        if (self.halted or self.terminal_written) return;
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "usage",
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
            .total_tokens = usage.total_tokens,
        });
    }

    /// Dispatch an internal Observer event to the headless stream.
    pub fn dispatchEvent(self: *Self, event: observer_mod.Event) !void {
        switch (event) {
            .assistant_text => |t| try self.emitAssistantDelta(t),
            // Deltas are UI-visible only: headless-v1 output stays byte-identical
            // (tui-streaming-001 — the complete assistant_text still carries the
            // full text in the existing event).
            .assistant_delta, .assistant_delta_clear => {},
            .usage => |u| try self.emitUsage(u),
            .tool_call => |c| try self.emitToolCall(c),
            .tool_result => |r| try self.emitToolResult(r.name, r.body),
            .permission => |p| try self.emitPermission(p.tool_name, p.allowed, p.remembered, p.risk),
        }
    }

    /// `--json`: single result envelope. Terminal.
    pub fn writeResult(self: *Self, result: anytype) !void {
        if (self.terminal_written) return;
        const final = try redact_mod.redactOptional(self.redactor, self.gpa, result.final_text);
        defer self.gpa.free(final);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "result",
            .ok = resultOk(result.stop_reason),
            .stop_reason = result.stop_reason.name(),
            .turns = result.turns,
            .final_text = final,
            .usage = .{
                .prompt_tokens = result.usage.prompt_tokens,
                .completion_tokens = result.usage.completion_tokens,
                .total_tokens = result.usage.total_tokens,
            },
        });
        self.terminal_written = true;
    }

    /// `--json-stream`: terminal run_end event derived from a completed reply.
    /// If the stream was already halted mid-run, emits the halt error terminal
    /// instead so callers still satisfy "exactly one terminal".
    pub fn writeRunEnd(self: *Self, result: anytype) !void {
        if (self.terminal_written) return;
        if (self.halted) {
            try self.writeError(self.halt_error);
            return;
        }
        const final = try redact_mod.redactOptional(self.redactor, self.gpa, result.final_text);
        defer self.gpa.free(final);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "run_end",
            .ok = resultOk(result.stop_reason),
            .stop_reason = result.stop_reason.name(),
            .turns = result.turns,
            .final_text = final,
            .usage = .{
                .prompt_tokens = result.usage.prompt_tokens,
                .completion_tokens = result.usage.completion_tokens,
                .total_tokens = result.usage.total_tokens,
            },
        });
        self.terminal_written = true;
    }

    /// Terminal error envelope for both `--json` and `--json-stream`.
    pub fn writeError(self: *Self, err: HeadlessError) !void {
        if (self.terminal_written) return;
        const msg = try redact_mod.redactOptional(self.redactor, self.gpa, err.message);
        defer self.gpa.free(msg);
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "error",
            .@"error" = .{
                .code = err.code.jsonName(),
                .message = msg,
                .retryable = err.code.retryable(),
                .category = err.code.category(),
            },
        });
        self.terminal_written = true;
    }

    /// `--doctor` headless JSON report (not a run terminal).
    pub fn writeDoctorReport(self: *Self, report: coding.doctor.Report) !void {
        try self.writeEvent(.{
            .protocol_version = protocol_version,
            .@"type" = "doctor",
            .doctor = .{
                .project_instructions = report.project_instructions.name(),
                .test_entry = report.test_entry.name(),
                .permission = report.permission.name(),
                .shell_policy = report.shell_policy.name(),
                .real_file_containment = report.real_file_containment.name(),
                .lexical_file_jail = "enforced",
                .secret_redaction = "enabled_on_agent_run",
                .provider_key_redaction = "deferred_until_provider_resolve",
                .os_sandbox = "not_implemented",
                .shell_containment = "not_path_contained",
            },
        });
    }

    fn writeEvent(self: *Self, event: anytype) !void {
        var body_writer: std.Io.Writer.Allocating = .init(self.gpa);
        defer body_writer.deinit();
        var json_stream: std.json.Stringify = .{
            .writer = &body_writer.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        json_stream.write(event) catch return error.OutOfMemory;
        const payload = body_writer.written();
        try self.out.writeAll(payload);
        try self.out.writeAll("\n");
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "resultOk matches public ok semantics" {
    try std.testing.expect(resultOk(.completed));
    try std.testing.expect(resultOk(.max_turns));
    try std.testing.expect(resultOk(.cancelled));
    try std.testing.expect(!resultOk(.timeout));
    try std.testing.expect(!resultOk(.unsupported_control));
    try std.testing.expect(!resultOk(.provider_error));
}

test "exit codes match headless contract matrix" {
    try std.testing.expectEqual(@as(u8, 0), exitCodeForStopReason(.completed));
    try std.testing.expectEqual(@as(u8, 10), exitCodeForStopReason(.max_turns));
    try std.testing.expectEqual(@as(u8, 11), exitCodeForStopReason(.cancelled));
    try std.testing.expectEqual(@as(u8, 20), exitCodeForStopReason(.timeout));
    try std.testing.expectEqual(@as(u8, 21), exitCodeForStopReason(.unsupported_control));
    try std.testing.expectEqual(@as(u8, 31), exitCodeForStopReason(.provider_error));
    try std.testing.expectEqual(@as(u8, 55), exitCodeForStopReason(.session_error));
    try std.testing.expectEqual(@as(u8, 60), exitCodeForStopReason(.trace_error));
    try std.testing.expectEqual(@as(u8, 40), exitCodeForStopReason(.out_of_memory));
}

test "error code exit codes match matrix" {
    try std.testing.expectEqual(@as(u8, 30), ErrorCode.provider_configuration.exitCode());
    try std.testing.expectEqual(@as(u8, 31), ErrorCode.provider_error.exitCode());
    try std.testing.expectEqual(@as(u8, 32), ErrorCode.invalid_toolset.exitCode());
    try std.testing.expectEqual(@as(u8, 33), ErrorCode.invalid_context.exitCode());
    try std.testing.expectEqual(@as(u8, 40), ErrorCode.out_of_memory.exitCode());
    try std.testing.expectEqual(@as(u8, 50), ErrorCode.session_not_found.exitCode());
    try std.testing.expectEqual(@as(u8, 51), ErrorCode.session_already_exists.exitCode());
    try std.testing.expectEqual(@as(u8, 52), ErrorCode.session_invalid.exitCode());
    try std.testing.expectEqual(@as(u8, 53), ErrorCode.session_unsupported_schema.exitCode());
    try std.testing.expectEqual(@as(u8, 54), ErrorCode.session_busy.exitCode());
    try std.testing.expectEqual(@as(u8, 55), ErrorCode.session_io_failed.exitCode());
    try std.testing.expectEqual(@as(u8, 60), ErrorCode.trace_error.exitCode());
    try std.testing.expectEqual(@as(u8, 22), ErrorCode.required_sandbox_unavailable.exitCode());
}

test "HeadlessWriter JSON result envelope contains protocol_version and type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var hw = HeadlessWriter.init(gpa, io, &out.writer, .json, null);
    defer hw.deinit();

    const result = .{
        .final_text = "hello",
        .turns = @as(u32, 1),
        .usage = message.Usage{ .prompt_tokens = 2, .completion_tokens = 1, .total_tokens = 3 },
        .stop_reason = loop.StopReason.completed,
    };
    try hw.writeResult(result);
    const text = std.mem.trim(u8, out.written(), " \n");
    try std.testing.expect(std.mem.startsWith(u8, text, "{"));
    try std.testing.expect(std.mem.endsWith(u8, text, "}"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"protocol_version\":\"headless-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"stop_reason\":\"completed\"") != null);
}

test "HeadlessWriter NDJSON stream emits terminal run_end exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var hw = HeadlessWriter.init(gpa, io, &out.writer, .json_stream, null);
    defer hw.deinit();

    try hw.emitRunStart("0.5.0", "ask", "protect");
    try hw.emitAssistantDelta("hello ");
    try hw.emitAssistantDelta("hello world");
    try hw.emitUsage(.{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 });

    const result = .{
        .final_text = "hello world",
        .turns = @as(u32, 1),
        .usage = message.Usage{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .stop_reason = loop.StopReason.completed,
    };
    try hw.writeRunEnd(result);

    const text = std.mem.trim(u8, out.written(), " \n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var terminal_count: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "{"));
        if (std.mem.indexOf(u8, line, "\"type\":\"run_end\"") != null) terminal_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), terminal_count);
}

test "HeadlessWriter halted stream then success still emits one error terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var hw = HeadlessWriter.init(gpa, io, &out.writer, .json_stream, null);
    defer hw.deinit();

    try hw.emitRunStart("0.5.0", "ask", "protect");
    hw.setHalted(.{
        .code = .out_of_memory,
        .message = "JSON serialization failed.",
    });

    const result = .{
        .final_text = "should not appear as run_end",
        .turns = @as(u32, 1),
        .usage = message.Usage{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .stop_reason = loop.StopReason.completed,
    };
    try hw.writeRunEnd(result);

    try std.testing.expect(hw.hasTerminal());
    try std.testing.expect(hw.isHalted());
    const text = std.mem.trim(u8, out.written(), " \n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var run_end_count: u32 = 0;
    var error_count: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"type\":\"run_end\"") != null) run_end_count += 1;
        if (std.mem.indexOf(u8, line, "\"type\":\"error\"") != null) error_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), run_end_count);
    try std.testing.expectEqual(@as(u32, 1), error_count);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"code\":\"out_of_memory\"") != null);
}

test "HeadlessWriter error envelope redacts configured secrets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;
    var r = try redact_mod.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var hw = HeadlessWriter.init(gpa, io, &out.writer, .json, &r);
    defer hw.deinit();

    try hw.writeError(.{
        .code = .provider_configuration,
        .message = "missing key " ++ secret,
    });
    const text = std.mem.trim(u8, out.written(), " \n");
    try std.testing.expect(std.mem.indexOf(u8, text, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, redact_mod.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"error\"") != null);
}

test "Kernel packages do not import TUI packages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var agent_core_dir = try openExistingDir(io, &.{
        "packages/zag-agent-core/src",
        "../zag-agent-core/src",
    });
    defer agent_core_dir.close(io);
    var coding_dir = try openExistingDir(io, &.{
        "packages/zag-coding-agent/src",
        "../zag-coding-agent/src",
    });
    defer coding_dir.close(io);

    try assertNoTuiImports(gpa, io, agent_core_dir);
    try assertNoTuiImports(gpa, io, coding_dir);
}

fn openExistingDir(io: Io, candidates: []const []const u8) !Io.Dir {
    for (candidates) |p| {
        if (Io.Dir.cwd().openDir(io, p, .{ .iterate = true })) |dir| {
            return dir;
        } else |_| {}
    }
    return error.TuiScanDirNotFound;
}

fn assertNoTuiImports(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try assertNoTuiImportsInDir(gpa, io, sub);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const content = try dir.readFileAlloc(io, entry.name, gpa, .limited(2 * 1024 * 1024));
            defer gpa.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-tui\")") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"tui\")") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "zag_tui") == null);
        }
    }
}

fn assertNoTuiImportsInDir(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try assertNoTuiImportsInDir(gpa, io, sub);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const content = try dir.readFileAlloc(io, entry.name, gpa, .limited(2 * 1024 * 1024));
            defer gpa.free(content);
            try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-tui\")") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"tui\")") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "zag_tui") == null);
        }
    }
}
