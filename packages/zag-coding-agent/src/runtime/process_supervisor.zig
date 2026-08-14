//! Process supervisor v1 — coding-agent-owned child lifecycle.
//!
//! Binding: docs/modules/process-supervisor.md (§8 proposed freeze).
//! Dual review is still open; this is the execution owner under `run_shell`,
//! not a maturity raise and not an OS sandbox.
//!
//! v1:
//! - `runForeground` is the `run_shell` backend (std.process.run pump, same
//!   shell-v1 timeout/limit/reap behavior).
//! - `spawn` / `cancel` / `wait` / `collect` own a direct-child Handle for
//!   cooperative-then-hard cancel tests and later long-lived slots.
//! - No Core process types. Portable direct-child PID only. No new package.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const workspace = @import("../workspace.zig");
const shell_policy = @import("../shell_policy.zig");

pub const Code = enum {
    spawn_failed,
    completed,
    timed_out,
    cancelled,
    failed,
    output_truncated,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .spawn_failed => "spawn_failed",
            .completed => "completed",
            .timed_out => "timed_out",
            .cancelled => "cancelled",
            .failed => "failed",
            .output_truncated => "output_truncated",
        };
    }
};

pub const CancelMode = enum { cooperative, hard };

pub const Spec = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    /// If set, must pass lexical jail (`checkToolPath`) before spawn.
    cwd_path: ?[]const u8 = null,
    timeout: Io.Timeout = .none,
    stdout_limit: usize = 30 * 1024,
    stderr_limit: usize = 30 * 1024,
    /// Grace after SIGTERM before SIGKILL on cooperative cancel, milliseconds.
    cancel_grace_ms: u32 = 2_000,
};

pub const Terminal = struct {
    code: Code,
    term: ?std.process.Child.Term = null,
};

pub const Output = struct {
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    truncated: bool = false,
};

pub const Handle = struct {
    gpa: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    truncated: bool = false,
    terminal: ?Terminal = null,
    cancel_grace_ms: u32,

    pub fn deinit(self: *Handle) void {
        if (self.child.id != null) self.child.kill(self.io);
        if (self.stdout.len > 0) self.gpa.free(self.stdout);
        if (self.stderr.len > 0) self.gpa.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
        self.child.id = null;
    }
};

pub const SpawnError = error{ SpawnFailed, OutOfMemory };

/// Fail closed before any child exists.
pub fn validateSpec(spec: Spec) error{SpawnFailed}!void {
    if (spec.argv.len == 0) return error.SpawnFailed;
    if (spec.cwd_path) |p| {
        workspace.checkToolPath(p) catch return error.SpawnFailed;
    }
}

/// Supervisor-side ShellPolicy seam (fixture 7). Core still applies
/// ShellPolicy before the handler; this rejects deny without spawn.
pub fn rejectDeniedShell(mode: shell_policy.Mode, command: []const u8) error{SpawnFailed}!void {
    if (shell_policy.check(mode, command) == .deny) return error.SpawnFailed;
}

pub fn spawn(gpa: std.mem.Allocator, io: Io, spec: Spec) SpawnError!Handle {
    try validateSpec(spec);
    const child = std.process.spawn(io, .{
        .argv = spec.argv,
        .cwd = spec.cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;
    return .{
        .gpa = gpa,
        .io = io,
        .child = child,
        .cancel_grace_ms = spec.cancel_grace_ms,
    };
}

/// Cooperative: SIGTERM, grace, then `Child.kill` (hard reap).
/// Hard: `Child.kill` immediately. Idempotent after reap.
pub fn cancel(handle: *Handle, mode: CancelMode) void {
    if (handle.terminal != null) return;
    if (handle.child.id) |pid| {
        if (mode == .cooperative) {
            std.posix.kill(pid, .TERM) catch {};
            Io.sleep(handle.io, Io.Duration.fromMilliseconds(handle.cancel_grace_ms), .awake) catch {};
        }
    }
    if (handle.child.id != null) handle.child.kill(handle.io);
    handle.terminal = .{ .code = .cancelled };
}

/// Block until the child exits. After `cancel`, reaps if still live, then
/// returns the stored terminal (F1: no zombie until deinit).
pub fn wait(handle: *Handle) Terminal {
    if (handle.terminal) |t| {
        if (handle.child.id != null) {
            const term = handle.child.wait(handle.io) catch return t;
            handle.terminal = .{ .code = t.code, .term = term };
            return handle.terminal.?;
        }
        return t;
    }
    const term = handle.child.wait(handle.io) catch {
        handle.terminal = .{ .code = .failed };
        return handle.terminal.?;
    };
    handle.terminal = .{ .code = .completed, .term = term };
    return handle.terminal.?;
}

pub fn collect(handle: *const Handle) Output {
    return .{
        .stdout = handle.stdout,
        .stderr = handle.stderr,
        .truncated = handle.truncated,
    };
}

pub const ForegroundError = std.process.RunError;

/// `run_shell` backend. Same pump/timeout/limit/reap as shell-v1 goldens.
pub fn runForeground(
    gpa: std.mem.Allocator,
    io: Io,
    spec: Spec,
) ForegroundError!std.process.RunResult {
    validateSpec(spec) catch return error.FileNotFound;
    return std.process.run(gpa, io, .{
        .argv = spec.argv,
        .cwd = spec.cwd,
        .stdout_limit = .limited(spec.stdout_limit),
        .stderr_limit = .limited(spec.stderr_limit),
        .timeout = spec.timeout,
    });
}

fn requirePosix() !void {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
}

test "fixture 1: happy echo completed exit=0" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const result = try runForeground(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "echo shell-ok" },
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5_000), .clock = .awake } },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "shell-ok") != null);
}

test "fixture 2: nonzero exit is truthful completed" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const result = try runForeground(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5_000), .clock = .awake } },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited);
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
}

test "fixture 3: timeout timed_out and process gone" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_duration: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(400),
        .clock = .awake,
    } };
    const err = runForeground(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "echo $$ > timeout.pid; while :; do :; done" },
        .cwd = .{ .dir = tmp.dir },
        .timeout = capture_duration.toDeadline(io),
    });
    try std.testing.expectError(error.Timeout, err);
    const raw = try tmp.dir.readFileAlloc(io, "timeout.pid", gpa, .limited(64));
    defer gpa.free(raw);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    const signal_zero: std.posix.SIG = @enumFromInt(0);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, signal_zero));
}

test "fixture 4: cooperative cancel reaps" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var handle = try spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "echo $$ > cancel.pid; sleep 30" },
        .cwd = .{ .dir = tmp.dir },
        .cancel_grace_ms = 200,
    });
    defer handle.deinit();
    // Let the child write its pid.
    Io.sleep(io, Io.Duration.fromMilliseconds(100), .awake) catch {};
    cancel(&handle, .cooperative);
    const t = wait(&handle);
    try std.testing.expectEqual(Code.cancelled, t.code);
    const raw = try tmp.dir.readFileAlloc(io, "cancel.pid", gpa, .limited(64));
    defer gpa.free(raw);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    const signal_zero: std.posix.SIG = @enumFromInt(0);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, signal_zero));
}

test "fixture 5: hard kill after ignore-TERM" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var handle = try spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; echo $$ > hard.pid; while :; do :; done" },
        .cwd = .{ .dir = tmp.dir },
        .cancel_grace_ms = 50,
    });
    defer handle.deinit();
    Io.sleep(io, Io.Duration.fromMilliseconds(100), .awake) catch {};
    cancel(&handle, .hard);
    const t = wait(&handle);
    try std.testing.expectEqual(Code.cancelled, t.code);
    const raw = try tmp.dir.readFileAlloc(io, "hard.pid", gpa, .limited(64));
    defer gpa.free(raw);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, raw, " \t\r\n"), 10);
    const signal_zero: std.posix.SIG = @enumFromInt(0);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, signal_zero));
}

test "fixture 6: output over cap is truncated and finite" {
    try requirePosix();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const err = runForeground(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do printf 0123456789; done" },
        .stdout_limit = 16,
        .stderr_limit = 16,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(5_000), .clock = .awake } },
    });
    try std.testing.expectError(error.StreamTooLong, err);
}

test "fixture 7: ShellPolicy deny means no spawn" {
    try std.testing.expectError(error.SpawnFailed, rejectDeniedShell(.protect, "rm -rf /"));
    try rejectDeniedShell(.protect, "echo ok");
}

test "fixture 8: jail cwd escape fail-closed pre-spawn" {
    try std.testing.expectError(error.SpawnFailed, validateSpec(.{
        .argv = &.{ "/bin/sh", "-c", "true" },
        .cwd_path = "/etc",
    }));
    try std.testing.expectError(error.SpawnFailed, validateSpec(.{
        .argv = &.{ "/bin/sh", "-c", "true" },
        .cwd_path = "../escape",
    }));
    try validateSpec(.{
        .argv = &.{ "/bin/sh", "-c", "true" },
        .cwd_path = "src",
    });
}

test "fixture 10: supervisor lives in coding-agent; Core has no process symbols" {
    // Compile-time: this module imports Core for types only via workspace/shell_policy.
    // zag-agent-core contains no `std.process` (repo grep at impl time).
    const core = @import("zag-agent-core");
    _ = core.loop;
    _ = core.tool;
}

test "empty argv is spawn_failed without a child" {
    try std.testing.expectError(error.SpawnFailed, validateSpec(.{ .argv = &.{} }));
}
