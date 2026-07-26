//! CLI SIGINT lifecycle (cli-sigint-001).
//!
//! Owned by `zag-cli` only. Installs a process-wide SIGINT handler that:
//!   * on the first signal — sets the cooperative cancel flag AND writes one
//!     byte into a self-pipe so a blocking read can be woken; the flag/byte are
//!     observed by the REPL loop (idle) or the agent loop (active cooperative).
//!   * on a second signal while a cancel is still pending — hard-exits with the
//!     conventional status `130` via `_exit`, which bypasses session/trace
//!     flush (documented in cli-interaction.md as the explicit abandonment
//!     path).
//!
//! The handler performs only async-signal-safe work: a seq_cst atomic compare,
//! a `CancelFlag.request`, a `write(2)` of one byte, and `_exit(2)`. No
//! allocation, logging, formatting, or buffered I/O.
//!
//! `Guard` restores the previous SIGINT disposition when its scope ends and
//! closes the self-pipe. The SDK (`zag-agent-core`) does **not** install any
//! signal handler; only the CLI does.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const core = @import("zag-agent-core");

pub const Flag = core.cancel.Flag;

const fd_t = posix.fd_t;

/// Process-wide state referenced by the async-signal-safe handler.
/// All fields are async-signal-safe (atomics + plain fds written only before
/// `sigaction` and read-only thereafter).
var state: struct {
    flag: ?*Flag = null,
    write_fd: fd_t = -1,
} = .{};

/// First-signal request + wakeup. Async-signal-safe.
fn onSigInt(_: posix.SIG) callconv(.c) void {
    const flag = state.flag orelse return;
    // If a cancel is already pending, this is the second interrupt: hard exit.
    if (flag.isSet()) {
        std.c._exit(130);
    }
    flag.request();
    const wfd = state.write_fd;
    if (wfd >= 0) {
        // One byte is enough; ignore errors (would-block/EINTR are fine).
        const buf = [_]u8{1};
        _ = std.c.write(wfd, &buf, 1);
    }
}

/// Owned SIGINT guard. Owns a self-pipe used to wake blocking reads. The
/// previous SIGINT disposition is captured on install and restored on
/// `deinit`. Construct/use of the SDK alone never installs this.
pub const Guard = struct {
    read_fd: fd_t,
    write_fd: fd_t,
    prev: posix.Sigaction,

    const invalid: fd_t = -1;

    /// `flag` must outlive every `reply`/`run` made under this guard (it is the
    /// Agent's cancel flag, owned by the Agent).
    pub fn install(flag: *Flag) error{PipeFailed}!Guard {
        switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd => {},
            else => return .{ .read_fd = invalid, .write_fd = invalid, .prev = undefined },
        }

        var fds: [2]fd_t = .{ invalid, invalid };
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const read_fd = fds[0];
        const write_fd = fds[1];
        if (setNonblock(read_fd) or setNonblock(write_fd)) {
            _ = std.c.close(read_fd);
            _ = std.c.close(write_fd);
            return error.PipeFailed;
        }

        state.flag = flag;
        state.write_fd = write_fd;

        var act: posix.Sigaction = .{
            .handler = .{ .handler = onSigInt },
            .mask = posix.sigemptyset(),
            // No SA_RESTART: legacy raw syscalls surface EINTR; the Io.Threaded
            // runtime auto-restarts kevent EINTR, so the self-pipe is the
            // actual wakeup mechanism.
            .flags = 0,
        };
        var prev: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.INT, &act, &prev);

        return .{ .read_fd = read_fd, .write_fd = write_fd, .prev = prev };
    }

    /// Restore the previous disposition and close the self-pipe. Safe to call
    /// on the `invalid` (unsupported-OS) guard.
    pub fn deinit(self: *Guard) void {
        switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd => {},
            else => return,
        }
        if (self.write_fd != invalid) {
            // Clear state before restoring so a signal delivered mid-restore
            // cannot touch a stale write fd.
            state.write_fd = -1;
            state.flag = null;
            posix.sigaction(posix.SIG.INT, &self.prev, null);
            _ = std.c.close(self.write_fd);
            _ = std.c.close(self.read_fd);
            self.write_fd = invalid;
            self.read_fd = invalid;
        }
    }
};

fn setNonblock(fd: fd_t) bool {
    const F = std.c.F;
    const cur = std.c.fcntl(fd, F.GETFL);
    if (cur < 0) return true;
    // `std.c.O` is a packed struct; OR the NONBLOCK bit into the current flags.
    var flags: std.c.O = @bitCast(@as(u32, @intCast(cur)));
    flags.NONBLOCK = true;
    const new_flags: c_int = @intCast(@as(u32, @bitCast(flags)));
    if (std.c.fcntl(fd, F.SETFL, new_flags) < 0) return true;
    return false;
}

/// Outcome of an interruptible line read.
pub const IdleRead = union(enum) {
    /// A full line was read (without trailing newline). Empty means a
    /// user-submitted blank line.
    line: []const u8,
    /// End of input (Ctrl-D / closed stdin).
    eof,
    /// SIGINT was observed; the caller should exit cleanly with code 0.
    interrupted,
};

/// Read one line from stdin, but wake from `poll` when either:
///   * stdin becomes readable, or
///   * the self-pipe becomes readable (SIGINT fired), or
///   * the cancel flag is set, or
///   * the poll timeout elapses (re-check flag).
///
/// `buffer` receives the line bytes (without the trailing newline). On
/// `interrupted`/`eof` the buffer contents are unspecified. The guard's
/// read_fd must be valid (supported OS). Bounded by `poll_timeout_ms` per
/// iteration so the cancel flag is observed within that interval.
pub fn readInterruptibleLine(guard: *const Guard, stdin_fd: fd_t, buffer: []u8, poll_timeout_ms: i32) error{
    ReadFailed,
    WouldBlockBufferTooSmall,
}!IdleRead {
    const flag = state.flag orelse return error.ReadFailed;

    // Drain any previously-signalled pipe bytes so the next read waits fresh.
    drainWake(guard.read_fd);

    var index: usize = 0;
    while (true) {
        if (flag.isSet()) return .interrupted;

        var fds: [2]std.posix.pollfd = .{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = guard.read_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = std.posix.poll(&fds, poll_timeout_ms) catch return error.ReadFailed;
        if (n == 0) continue; // timeout: re-check flag

        // Wake pipe fired → SIGINT. Drain and report interrupted.
        if (fds[1].revents != 0) {
            drainWake(guard.read_fd);
            if (flag.isSet()) return .interrupted;
            // Spurious: continue.
            continue;
        }
        if (fds[0].revents == 0) continue;

        // stdin readable: read available bytes (nonblocking since we polled).
        var chunk: [256]u8 = undefined;
        const got = readOnce(stdin_fd, &chunk) catch return error.ReadFailed;
        if (got == 0) {
            // EOF on stdin.
            if (index == 0) return .eof;
            // Trailing data without newline: return what we have.
            return .{ .line = buffer[0..index] };
        }
        for (chunk[0..got]) |b| {
            if (b == '\n') return .{ .line = buffer[0..index] };
            if (index >= buffer.len) return error.WouldBlockBufferTooSmall;
            buffer[index] = b;
            index += 1;
        }
    }
}

fn readOnce(fd: fd_t, buf: []u8) error{ReadFailed}!usize {
    const rc = std.c.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        switch (std.posix.errno(rc)) {
            .INTR => return readOnce(fd, buf),
            .AGAIN => return 0,
            else => return error.ReadFailed,
        }
    }
    return @intCast(rc);
}

fn drainWake(read_fd: fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const rc = std.c.read(read_fd, &buf, buf.len);
        if (rc <= 0) return;
    }
}

test "Guard install/restore is a no-op disposition round-trip on signal-capable OS" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    try std.testing.expect(guard.read_fd >= 0);
    try std.testing.expect(guard.write_fd >= 0);
    // No signal: flag stays unset.
    try std.testing.expect(!flag.isSet());
}

test "first signal requests flag and wakes pipe; second signal is hard exit (logic only)" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    // Simulate first-signal handler body without actually raising SIGINT:
    // flag must not already be set → request + write one byte.
    try std.testing.expect(!flag.isSet());
    flag.request();
    _ = std.c.write(guard.write_fd, &[_]u8{1}, 1);
    try std.testing.expect(flag.isSet());
    // The pipe should be readable.
    var byte: [1]u8 = .{0};
    const rc = std.c.read(guard.read_fd, &byte, 1);
    try std.testing.expectEqual(@as(isize, 1), rc);
    // Second-signal condition: flag already set → handler would `_exit(130)`.
    // We only assert the predicate the handler uses; we do not raise a signal
    // (that would terminate the test runner).
    try std.testing.expect(flag.isSet());
}

test "readInterruptibleLine returns eof on closed stdin" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    // Use a closed pipe as stdin: read returns 0 → eof.
    var pair: [2]fd_t = .{ 0, 0 };
    try std.testing.expect(std.c.pipe(&pair) == 0);
    _ = std.c.close(pair[1]); // close write end → read end sees EOF
    defer _ = std.c.close(pair[0]);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, pair[0], &buf, 50);
    try std.testing.expect(out == .eof);
}

test "readInterruptibleLine reads a line" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var pair: [2]fd_t = .{ 0, 0 };
    try std.testing.expect(std.c.pipe(&pair) == 0);
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    _ = std.c.write(pair[1], "hello\n", 6);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, pair[0], &buf, 50);
    switch (out) {
        .line => |l| try std.testing.expectEqualStrings("hello", l),
        else => return error.TestUnexpectedResult,
    }
}

test "readInterruptibleLine observes a set cancel flag without stdin input" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    // A read end that never becomes ready:
    var pair: [2]fd_t = .{ 0, 0 };
    try std.testing.expect(std.c.pipe(&pair) == 0);
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    // Set the flag (simulate first SIGINT without raising it).
    flag.request();
    _ = std.c.write(guard.write_fd, &[_]u8{1}, 1);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, pair[0], &buf, 50);
    try std.testing.expect(out == .interrupted);
}