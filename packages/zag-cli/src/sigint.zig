//! CLI SIGINT lifecycle (cli-sigint-001).
//!
//! Owned by `zag-cli` only. Installs a process-wide SIGINT handler that:
//!   * on the first signal — transitions the process-local interrupt state to
//!     `pending`, sets the cooperative cancel flag (if bound), AND writes one
//!     byte into a self-pipe so a blocking read can be woken. The flag/byte are
//!     observed by the REPL loop (idle) or the agent loop (active cooperative).
//!   * on a second signal while the interrupt is still `pending` (i.e. not yet
//!     acknowledged by the run loop) — hard-exits with the conventional status
//!     `130` via a raw exit syscall, which bypasses session/trace flush
//!     (documented in cli-interaction.md as the explicit abandonment path).
//!
//! The handler performs only async-signal-safe work: a `cmpxchg` on a seq_cst
//! atomic state word, an optional `CancelFlag.request`, a raw `write(2)` of one
//! byte, and a raw exit. No allocation, logging, formatting, or buffered I/O.
//!
//! # Signal-safety / lifecycle (cli-sigint-001 review item 2)
//!
//! The interrupt *state* lives in a process-lifetime atomic word, NOT in the
//! Agent's `CancelFlag`. This is deliberate: the second-interrupt predicate
//! must be the SIGINT handler's own unacknowledged state, so a programmatic
//! cancel (e.g. a test or SDK caller setting the flag) is never misread as a
//! "second Ctrl+C". The Agent flag is only the cooperative-cancel channel.
//!
//! A process-lifetime singleton self-pipe is created once and NEVER closed
//! while the process runs. `Guard.deinit` only restores the previous SIGINT
//! disposition; it does not close the pipe, so there is no close/fd-reuse
//! window in which a stale handler could write a recycled fd. The OS reclaims
//! at most 2 leaked fds on process exit — a fixed, bounded, safe leak.
//! NONBLOCK + CLOEXEC are set on both ends so exec and blocking never interact.
//!
//! Concurrent/nested `Guard` installation is rejected: only one owner at a
//! time (sequential install/reinstall is fine and is how the REPL reuses it).
//! The previous `sigaction` is captured on install and restored on teardown;
//! the bound flag/state stay live until teardown so a signal delivered
//! mid-restore observes a consistent (restored-default) disposition.
//!
//! # Linux non-libc (review item 1)
//!
//! No `std.c.*` libc dependency is introduced on Linux. Raw fd syscalls go
//! through `std.posix.system` (=`std.os.linux` without libc, =`std.c` on
//! macOS/BSD). The product executable is therefore never forced to `link_libc`
//! by this module. macOS always has libc available (it is the platform ABI).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const core = @import("zag-agent-core");

pub const Flag = core.cancel.Flag;

const fd_t = posix.fd_t;

/// OS targets that own a real SIGINT handler + self-pipe. Other targets get
/// an inert guard (no signal machinery) so cross-compiles still build.
const supported = builtin.os.tag == .linux or
    builtin.os.tag == .macos or builtin.os.tag == .ios or
    builtin.os.tag == .tvos or builtin.os.tag == .watchos or
    builtin.os.tag == .visionos or builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or builtin.os.tag == .dragonfly or
    builtin.os.tag == .openbsd;

// ---------------------------------------------------------------------------
// Raw, libc-free syscall shims (review item 1).
//
// `std.posix.system` resolves to `std.os.linux` (no libc) on Linux and to
// `std.c` (libc) on macOS/BSD. The two return-type conventions differ
// (linux raw syscalls return usize with errno encoded; libc returns c_int and
// sets errno), but `std.posix.errno(rc)` normalises both. Each shim returns a
// simple ok/err so callers stay platform-agnostic.
// ---------------------------------------------------------------------------

const sys = struct {
    /// Create a self-pipe with both ends NONBLOCK + CLOEXEC. Returns the fds.
    fn pipe() error{PipeFailed}![2]fd_t {
        if (builtin.os.tag == .linux) {
            // pipe2 with O.NONBLOCK | O.CLOEXEC is one syscall, atomic.
            var fds: [2]i32 = .{ -1, -1 };
            var flags: std.os.linux.O = .{};
            flags.NONBLOCK = true;
            flags.CLOEXEC = true;
            const rc = std.os.linux.pipe2(&fds, flags);
            switch (posix.errno(rc)) {
                .SUCCESS => return .{ fds[0], fds[1] },
                else => return error.PipeFailed,
            }
        }
        // macOS / BSD: pipe(2) then fcntl each end for NONBLOCK + CLOEXEC.
        var fds: [2]fd_t = .{ -1, -1 };
        const prc = std.c.pipe(&fds);
        if (prc != 0) return error.PipeFailed;
        if (setNonblock(fds[0]) or setNonblock(fds[1]) or
            setCloexec(fds[0]) or setCloexec(fds[1]))
        {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
            return error.PipeFailed;
        }
        return fds;
    }

    /// Raw write of one byte; used from the signal handler. Async-signal-safe.
    /// Returns nothing; errors are ignored (EAGAIN/EINTR are acceptable).
    fn writeWake(wfd: fd_t) void {
        const buf = [_]u8{1};
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.write(wfd, &buf, 1);
        } else {
            _ = std.c.write(wfd, &buf, 1);
        }
    }

    /// Hard, bypass-everything exit with `status`. Async-signal-safe.
    /// On Linux this is the exit_group syscall (kills the whole thread group,
    /// matching the "abandonment" semantics); on macOS it is libc `_exit`.
    fn hardExit(status: u8) noreturn {
        if (builtin.os.tag == .linux) {
            std.os.linux.exit_group(status);
        } else {
            std.c._exit(status);
        }
    }

    fn close(fd: fd_t) void {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.close(fd);
        } else {
            _ = std.c.close(fd);
        }
    }

    /// Raw read into `buf`; returns bytes read (0 = EOF / would-block on
    /// nonblocking fd). EINTR loops internally (no recursion). Used outside
    /// the signal handler only.
    fn read(fd: fd_t, buf: []u8) error{ReadFailed}!usize {
        while (true) {
            const rc = if (builtin.os.tag == .linux)
                std.os.linux.read(fd, buf.ptr, buf.len)
            else
                std.c.read(fd, buf.ptr, buf.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return 0,
                else => return error.ReadFailed,
            }
        }
    }

    fn setNonblock(fd: fd_t) bool {
        return setFlagStatus(fd, true);
    }

    fn setCloexec(fd: fd_t) bool {
        if (builtin.os.tag == .linux) {
            const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
            if (posix.errno(cur) != .SUCCESS) return true;
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
            return posix.errno(rc) != .SUCCESS;
        }
        const cur = std.c.fcntl(fd, std.c.F.GETFD);
        if (cur < 0) return true;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return true;
        return false;
    }

    /// Set/clear NONBLOCK via F_GETFL/F_SETFL. Returns true on failure.
    /// Uses raw bit constants so no packed-struct layout assumptions leak.
    fn setFlagStatus(fd: fd_t, nonblock: bool) bool {
        if (builtin.os.tag == .linux) {
            const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
            if (posix.errno(cur) != .SUCCESS) return true;
            const cur_u: u32 = @intCast(cur);
            const nonblock_bit: u32 = O_NONBLOCK_LINUX;
            const new_u: u32 = if (nonblock) (cur_u | nonblock_bit) else (cur_u & ~nonblock_bit);
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, new_u);
            return posix.errno(rc) != .SUCCESS;
        }
        // macOS: O_NONBLOCK is a plain integer flag on libc.
        const cur = std.c.fcntl(fd, std.c.F.GETFL);
        if (cur < 0) return true;
        const nonblock_bit: c_int = O_NONBLOCK_MAC;
        const new_flags: c_int = if (nonblock) (cur | nonblock_bit) else (cur & ~nonblock_bit);
        if (std.c.fcntl(fd, std.c.F.SETFL, new_flags) < 0) return true;
        return false;
    }
};

// O_NONBLOCK bit values. Linux: 0o4000 (0x800). macOS: 0x0004 (O_NONBLOCK).
const O_NONBLOCK_LINUX: u32 = 0o4000;
const O_NONBLOCK_MAC: c_int = 0x0004;

// ---------------------------------------------------------------------------
// Process-lifetime interrupt state (review item 2).
// ---------------------------------------------------------------------------

/// Interrupt state observed by the async-signal-safe handler. The second
/// SIGINT predicate is `pending` (the handler's own unacknowledged state),
/// NOT the Agent's cancel flag.
const State = enum(u32) {
    idle = 0,
    pending = 1,
    escaped = 2,
};

/// Process-global handler state. All fields are async-signal-safe:
///   * `state` — a seq_cst atomic word, the only thing the handler mutates.
///   * `flag`  — a pointer written BEFORE `sigaction` installs the handler and
///     read-only thereafter; the handler only calls `request` (atomic store).
///   * `write_fd` — a fixed fd written BEFORE install and read-only thereafter;
///     the pipe is process-lifetime and never closed while the process runs,
///     so the fd is never recycled under a stale handler.
var handler_state: struct {
    state: std.atomic.Value(u32) = .init(0),
    flag: ?*Flag = null,
    write_fd: fd_t = -1,
} = .{};

/// Async-signal-safe SIGINT handler.
///   IDLE     -> PENDING : request cancel (if bound) + write one wake byte.
///   PENDING  -> ESCAPED : hard exit 130 (second interrupt, abandonment).
///   ESCAPED  -> (none)  : a third signal while exiting is a no-op.
fn onSigInt(_: posix.SIG) callconv(.c) void {
    const cur: State = @enumFromInt(handler_state.state.load(.seq_cst));
    if (cur == .idle) {
        const swapped = handler_state.state.cmpxchgStrong(
            @intFromEnum(State.idle),
            @intFromEnum(State.pending),
            .seq_cst,
            .seq_cst,
        );
        if (swapped == null) {
            // Won the IDLE->PENDING transition: cooperative cancel + wake.
            if (handler_state.flag) |flag| flag.request();
            const wfd = handler_state.write_fd;
            if (wfd >= 0) sys.writeWake(wfd);
            return;
        }
        // Lost the race: someone else moved to pending/escaped. Fall through.
    }
    // We are at least `pending` (or raced into it). A second unacknowledged
    // interrupt is the explicit abandonment path.
    const now: State = @enumFromInt(handler_state.state.load(.seq_cst));
    if (now == .pending) {
        const swapped = handler_state.state.cmpxchgStrong(
            @intFromEnum(State.pending),
            @intFromEnum(State.escaped),
            .seq_cst,
            .seq_cst,
        );
        if (swapped == null) {
            sys.hardExit(130);
        }
    }
    // Either escaped already, or lost the race to escape; do nothing further.
}

// ---------------------------------------------------------------------------
// Guard: install/restore the SIGINT disposition against a cancel flag.
// ---------------------------------------------------------------------------

/// Errors from installing the guard. Distinct from `OutOfMemory` (review item
/// 7): a pipe/fcntl/sigaction failure is an initialization fault, not memory
/// exhaustion. Callers map this to an honest init error, not OOM.
pub const InstallError = error{SigintInitFailed};

/// Process-lifetime singleton guard ownership flag. Prevents concurrent/nested
/// Guard installation (sequential reinstall is allowed once `deinit` clears).
var guard_owned: std.atomic.Value(bool) = .init(false);

/// Process-lifetime self-pipe. Created on first `install`, never closed. At
/// most 2 fds leak to process exit, reclaimed by the OS — bounded and safe.
var lifetime_pipe: [2]fd_t = .{ -1, -1 };
var pipe_created: bool = false;

pub const Guard = struct {
    read_fd: fd_t,
    write_fd: fd_t,
    prev: posix.Sigaction,
    installed: bool,

    const invalid: fd_t = -1;

    /// `flag` must outlive every `reply`/`run` made under this guard (it is
    /// the Agent's cancel flag, owned by the Agent). Sequential reinstall is
    /// supported (deinit then install again); concurrent/nested install is
    /// rejected with `error.SigintInitFailed`.
    pub fn install(flag: ?*Flag) InstallError!Guard {
        if (!supported) {
            return .{ .read_fd = invalid, .write_fd = invalid, .prev = undefined, .installed = false };
        }

        // Reject concurrent/nested ownership. Sequential reuse is fine.
        if (guard_owned.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            return error.SigintInitFailed;
        }

        // Create the process-lifetime self-pipe once.
        if (!pipe_created) {
            const fds = sys.pipe() catch {
                guard_owned.store(false, .seq_cst);
                return error.SigintInitFailed;
            };
            lifetime_pipe = fds;
            pipe_created = true;
        }
        const read_fd = lifetime_pipe[0];
        const write_fd = lifetime_pipe[1];

        // Bind handler state BEFORE installing the handler so a signal
        // delivered the instant after sigaction returns observes a consistent
        // flag/fd. The pipe fd is process-lifetime (never closed), so it is
        // never recycled under a stale handler.
        handler_state.flag = flag;
        handler_state.write_fd = write_fd;
        handler_state.state.store(@intFromEnum(State.idle), .seq_cst);

        var act: posix.Sigaction = .{
            .handler = .{ .handler = onSigInt },
            .mask = posix.sigemptyset(),
            // No SA_RESTART: blocking syscalls surface EINTR so the self-pipe
            // wake is observed. std.posix.poll auto-restarts on EINTR, but the
            // pipe byte makes it return promptly anyway.
            .flags = 0,
        };
        var prev: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.INT, &act, &prev);

        return .{ .read_fd = read_fd, .write_fd = write_fd, .prev = prev, .installed = true };
    }

    /// Restore the previous disposition. Does NOT close the self-pipe
    /// (process-lifetime; OS reclaims on exit — no close/fd-reuse window).
    /// The bound flag/state are cleared so a stray signal after restore is a
    /// no-op. Safe on the inert (unsupported-OS) guard.
    pub fn deinit(self: *Guard) void {
        if (!supported or !self.installed) return;

        // Clear handler state first so a signal delivered mid-restore cannot
        // touch a stale flag/fd. Then restore the previous disposition.
        handler_state.flag = null;
        handler_state.write_fd = -1;
        handler_state.state.store(@intFromEnum(State.idle), .seq_cst);
        posix.sigaction(posix.SIG.INT, &self.prev, null);

        guard_owned.store(false, .seq_cst);
        self.installed = false;
    }

    // -- run-loop cooperation (review item 3) -------------------------------

    /// True when a SIGINT has moved the state to `pending` and the run loop
    /// has not yet acknowledged it. Used to detect a pre-run pending interrupt
    /// so it applies to the current run instead of being silently cleared.
    pub fn pendingInterrupt(self: *const Guard) bool {
        if (!supported or !self.installed) return false;
        return @as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .pending;
    }

    /// Acknowledge that the run loop has consumed the pending interrupt (i.e.
    /// the cooperative cancel has been observed and acted on). Resets
    /// `pending` -> `idle` so the NEXT interaction can use Ctrl+C again. Only
    /// transitions from `pending`; `escaped` is terminal (process is exiting).
    pub fn acknowledgeCancel(self: *const Guard) void {
        if (!supported or !self.installed) return;
        _ = handler_state.state.cmpxchgStrong(
            @intFromEnum(State.pending),
            @intFromEnum(State.idle),
            .seq_cst,
            .seq_cst,
        );
    }
};

// ---------------------------------------------------------------------------
// Interruptible line read (review item 4).
//
// A persistent pending buffer on the Guard-side keeps same-batch input across
// two calls: if a raw read returns "first\nsecond\n", the first call returns
// "first" and retains "second\n" for the next call. EINTR loops (no recursion).
// The poll/self-pipe path returns `.interrupted` on SIGINT and never surfaces
// a `ReadFailed`/stack trace to the user.
// ---------------------------------------------------------------------------

/// Outcome of an interruptible line read.
pub const IdleRead = union(enum) {
    /// A full line (without trailing newline). Empty = a submitted blank line.
    line: []const u8,
    /// End of input (Ctrl-D / closed stdin).
    eof,
    /// SIGINT was observed; the caller should exit cleanly with code 0.
    interrupted,
};

/// Persistent pending-input buffer retained across calls. Lives on the stack
/// of the REPL loop; one instance per REPL session.
pub const LineBuffer = struct {
    pending: [4096]u8 = undefined,
    pending_len: usize = 0,

    pub fn init() LineBuffer {
        return .{};
    }
};

/// Read one line from stdin, waking from `poll` when:
///   * stdin becomes readable,
///   * the self-pipe becomes readable (SIGINT fired),
///   * the interrupt state is `pending`, or
///   * the poll timeout elapses (re-check state).
///
/// `lb` retains bytes after the first newline for the next call (review item
/// 4). `buffer` receives the returned line bytes. On `interrupted`/`eof` the
/// buffer contents are unspecified. Bounded by `poll_timeout_ms` per iteration.
pub fn readInterruptibleLine(
    guard: *const Guard,
    lb: *LineBuffer,
    stdin_fd: fd_t,
    buffer: []u8,
    poll_timeout_ms: i32,
) error{WouldBlockBufferTooSmall}!IdleRead {
    if (!supported or !guard.installed) return error.WouldBlockBufferTooSmall;

    // First, drain any retained same-batch input from a prior call.
    switch (consumePending(lb, buffer)) {
        .none => {},
        .too_small => return error.WouldBlockBufferTooSmall,
        .out => |out| return out,
    }

    while (true) {
        // Observe a pending interrupt promptly (covers pre-run pending + wake).
        if (@as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .pending) {
            drainWake(guard.read_fd);
            return .interrupted;
        }

        var fds: [2]posix.pollfd = .{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = guard.read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, poll_timeout_ms) catch continue;
        // std.posix.poll auto-restarts on EINTR; a timeout (0) just re-checks.

        // Wake pipe fired → SIGINT. Drain and report interrupted (never
        // ReadFailed — review item 4).
        if (fds[1].revents != 0) {
            drainWake(guard.read_fd);
            if (@as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .pending) {
                return .interrupted;
            }
            continue; // spurious
        }
        if (fds[0].revents == 0) continue;

        // stdin readable: read available bytes into the pending buffer, then
        // serve complete lines from it (retaining leftovers for next call).
        if (!try appendStdin(lb, stdin_fd)) {
            // EOF on stdin. Serve any trailing pending first.
            if (lb.pending_len > 0) {
                if (buffer.len < lb.pending_len) return error.WouldBlockBufferTooSmall;
                @memcpy(buffer[0..lb.pending_len], lb.pending[0..lb.pending_len]);
                const n = lb.pending_len;
                lb.pending_len = 0;
                return .{ .line = buffer[0..n] };
            }
            return .eof;
        }
        switch (consumePending(lb, buffer)) {
            .none => {},
            .too_small => return error.WouldBlockBufferTooSmall,
            .out => |out| return out,
        }
        // No newline yet in this batch: keep polling for more stdin/wake.
    }
}

/// Append one stdin read into the pending buffer. Returns false on EOF.
fn appendStdin(lb: *LineBuffer, stdin_fd: fd_t) error{WouldBlockBufferTooSmall}!bool {
    while (true) {
        if (lb.pending_len >= lb.pending.len) return error.WouldBlockBufferTooSmall;
        const room = lb.pending[lb.pending_len..];
        const got = sys.read(stdin_fd, room) catch return true; // transient err: retry next poll
        if (got == 0) return false; // EOF
        lb.pending_len += got;
        return true;
    }
}

/// If the pending buffer contains a newline, copy the first line (without it)
/// into `buffer` and shift the remainder to the front. Returns:
///   * `null` — no newline present (caller should read more).
///   * `?IdleRead` payload — a line, or an out-error if the line exceeds the
///     caller's `buffer`.
const ConsumeResult = union(enum) {
    none: void,
    out: IdleRead,
    too_small: void,
};

fn consumePending(lb: *LineBuffer, buffer: []u8) ConsumeResult {
    if (lb.pending_len == 0) return .none;
    const nl = std.mem.indexOfScalar(u8, lb.pending[0..lb.pending_len], '\n') orelse return .none;
    const line_len = nl;
    if (buffer.len < line_len) return .too_small;
    @memcpy(buffer[0..line_len], lb.pending[0..line_len]);
    // Shift remainder (after the newline) to the front.
    const rest = lb.pending_len - (nl + 1);
    if (rest > 0) {
        std.mem.copyForwards(u8, lb.pending[0..rest], lb.pending[nl + 1 .. lb.pending_len]);
    }
    lb.pending_len = rest;
    return .{ .out = .{ .line = buffer[0..line_len] } };
}

fn drainWake(read_fd: fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const got = sys.read(read_fd, &buf) catch return;
        if (got == 0) return;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Guard install/restore is a no-op disposition round-trip on signal-capable OS" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    try std.testing.expect(guard.read_fd >= 0);
    try std.testing.expect(guard.write_fd >= 0);
    try std.testing.expect(!flag.isSet());
    try std.testing.expect(!guard.pendingInterrupt());
}

test "first signal requests flag and wakes pipe; second signal predicate is handler state" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    try std.testing.expect(!flag.isSet());

    // Simulate the first-signal handler path: IDLE -> PENDING, request, wake.
    const swapped = handler_state.state.cmpxchgStrong(
        @intFromEnum(State.idle),
        @intFromEnum(State.pending),
        .seq_cst,
        .seq_cst,
    );
    try std.testing.expect(swapped == null);
    flag.request();
    sys.writeWake(guard.write_fd);
    try std.testing.expect(flag.isSet());
    try std.testing.expect(guard.pendingInterrupt());

    // The pipe is readable.
    var byte: [1]u8 = .{0};
    const got = try sys.read(guard.read_fd, &byte);
    try std.testing.expectEqual(@as(usize, 1), got);

    // Second-signal predicate is the handler's own pending state, NOT the
    // flag. Acknowledging clears pending so a programmatic cancel (flag still
    // set) is NOT misread as a second Ctrl+C.
    guard.acknowledgeCancel();
    try std.testing.expect(!guard.pendingInterrupt());
    // Flag may still be set from the programmatic request; that must NOT
    // count as a pending second interrupt.
    flag.clear();
}

test "readInterruptibleLine returns eof on closed stdin" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    var pair: [2]fd_t = .{ 0, 0 };
    const fds = try sys.pipe();
    pair = fds;
    sys.close(pair[1]); // close write end -> read end sees EOF
    defer sys.close(pair[0]);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, pair[0], &buf, 50);
    try std.testing.expect(out == .eof);
}

test "readInterruptibleLine reads a line" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    // Write "hello\n" into the write end.
    _ = if (builtin.os.tag == .linux)
        std.os.linux.write(fds[1], "hello\n", 6)
    else
        std.c.write(fds[1], "hello\n", 6);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    switch (out) {
        .line => |l| try std.testing.expectEqualStrings("hello", l),
        else => return error.TestUnexpectedResult,
    }
}

test "readInterruptibleLine observes a pending interrupt without stdin input" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    // Simulate first SIGINT: move to pending + write wake byte.
    _ = handler_state.state.cmpxchgStrong(
        @intFromEnum(State.idle),
        @intFromEnum(State.pending),
        .seq_cst,
        .seq_cst,
    );
    sys.writeWake(guard.write_fd);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    try std.testing.expect(out == .interrupted);
    guard.acknowledgeCancel();
}

test "readInterruptibleLine retains same-batch bytes across two calls (review item 4)" {
    if (!supported) return;
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    // Write two lines in one batch: "first\nsecond\n".
    const two = "first\nsecond\n";
    _ = if (builtin.os.tag == .linux)
        std.os.linux.write(fds[1], two.ptr, two.len)
    else
        std.c.write(fds[1], two.ptr, two.len);
    var buf: [128]u8 = undefined;
    // First call: returns "first", retains "second\n".
    const out1 = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    switch (out1) {
        .line => |l| try std.testing.expectEqualStrings("first", l),
        else => return error.TestUnexpectedResult,
    }
    // Second call: serves "second" from the retained pending buffer (no new
    // stdin read needed).
    const out2 = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    switch (out2) {
        .line => |l| try std.testing.expectEqualStrings("second", l),
        else => return error.TestUnexpectedResult,
    }
}
