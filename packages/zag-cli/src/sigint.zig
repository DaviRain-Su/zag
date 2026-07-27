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
//! The handler performs only async-signal-safe work: a `fetchAdd` on an
//! in-flight counter, a `cmpxchg` on a seq_cst atomic state word, an atomic
//! load of the bound flag pointer, an optional `CancelFlag.request`, a raw
//! `write(2)` of one byte, and a raw exit. No locks, allocation, logging,
//! formatting, or buffered I/O.
//!
//! # Signal-safety / lifecycle (cli-sigint-001 review item 2 / P1 final)
//!
//! The interrupt *state* lives in a process-lifetime atomic word, NOT in the
//! Agent's `CancelFlag`. This is deliberate: the second-interrupt predicate
//! must be the SIGINT handler's own unacknowledged state, so a programmatic
//! cancel (e.g. a test or SDK caller setting the flag) is never misread as a
//! "second Ctrl+C". The Agent flag is only the cooperative-cancel channel.
//!
//! Proof of race-freedom for teardown (P1 final — no teardown→reinstall ABA):
//!   * `write_fd` is a process-lifetime immutable value. It is written exactly
//!     once (on first pipe creation) and NEVER mutated by `deinit`. A handler
//!     can therefore always read a stable, valid fd; there is no close/fd-reuse
//!     window (the pipe is never closed while the process runs; the OS reclaims
//!     at most 2 fds at exit).
//!   * `flag` is a lock-free atomic address (`std.atomic.Value(usize)`, 0=null).
//!     The handler loads it atomically; `deinit` stores null atomically. No
//!     plain-field concurrent read/write — no Zig memory-model UB.
//!   * `in_flight` is a lock-free atomic counter. The handler `fetchAdd(1)` on
//!     entry and `fetchSub(1)` on normal return (the hard-exit path does NOT
//!     decrement because the process is leaving). `deinit` sets `state=
//!     disabled` (so new entries return immediately without touching flag/pipe),
//!     atomically unbinds the flag, restores the previous sigaction, then spins
//!     until `in_flight == 0` (UNbounded — see below) — draining any handler
//!     that entered before/during those steps and may still touch the (now-null)
//!     flag. A handler that enters after `disabled` is visible sees `disabled`,
//!     decrements, and returns without touching the flag — safe.
//!   * The `in_flight` drain is unbounded because the handler does ONLY
//!     lock-free atomics + a nonblocking one-byte `write`; a normal-path
//!     handler is therefore bounded and MUST complete before the Agent
//!     proceeds to later destroy the flag. A handler that already loaded the
//!     old flag before `deinit` stored null will finish its atomic work in a
//!     bounded number of instructions. There is no allocation/lock/IO to stall
//!     on, so the wait cannot deadlock in practice.
//!   * ONE-SHOT install (P1 final ABA fix): `ever_installed` is a one-way
//!     atomic. The first successful `install` sets it permanently; `deinit`
//!     restores the previous sigaction but does NOT clear it. Any later
//!     `install` returns `error.SigintInitFailed`. This eliminates the
//!     teardown→reinstall ABA: POSIX does not guarantee that an old handler
//!     already committed but not yet executing its first instruction cannot
//!     enter AFTER `sigaction(restore)` returns, and a userspace
//!     generation/in_flight counter cannot distinguish an old-generation entry
//!     from a new one. The CLI has exactly one Guard for the whole process
//!     lifetime, so reinstall is unnecessary; forbidding it removes the ABA.
//!   * Concurrent/nested `Guard` installation is also rejected (one owner).
//!
//! NONBLOCK + CLOEXEC are set on both pipe ends so exec and blocking never
//! interact.
//!
//! # Linux non-libc (review item 1 + ci-hang-sigint-linux-errno-001)
//!
//! No `std.c.*` libc dependency is introduced on Linux. Product Linux path uses
//! raw `std.os.linux` syscalls so this module never forces `link_libc`. Raw
//! kernel returns are decoded with `std.os.linux.errno` / `linuxRawErrno` only
//! — never `std.posix.errno` (libc-shaped when `link_libc`, e.g. curl builds).
//! macOS/BSD uses libc (`std.c`) return conventions (platform ABI).

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
// Raw syscall shims (review item 1 + ci-hang-sigint-linux-errno-001).
//
// Linux product path: raw `std.os.linux.*` returning kernel `usize`. Errors are
// encoded as negative errno in the signed window `(-4096, 0)` — **not** as
// libc's `-1` + thread errno. Decode those results with `linuxRawErrno` /
// `std.os.linux.errno` only. Do **not** pass them to `std.posix.errno` /
// `std.c.errno`: when `builtin.link_libc` is true (curl-linked builds),
// `posix.errno` is libc-shaped and misclassifies raw `-EAGAIN` as `.SUCCESS`,
// which makes `sys.read` return a huge "byte count" and hangs `drainWake`.
//
// macOS/BSD product path: libc (`std.c`) return conventions (`-1` + thread
// errno / existing c patterns). Never mix libc decode onto raw Linux results.
// ---------------------------------------------------------------------------

/// Kernel signed-window errno decode for raw Linux `usize` syscall results.
/// Product path for every audited `std.os.linux` site below. Independent of
/// `builtin.link_libc` — always kernel semantics.
fn linuxRawErrno(rc: usize) std.os.linux.E {
    return std.os.linux.errno(rc);
}

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
            switch (linuxRawErrno(rc)) {
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
    /// Does NOT return; therefore does NOT decrement `in_flight` (the process
    /// is leaving, so the counter is irrelevant).
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
    /// the signal handler only. A typed `ReadFailed` is returned for unexpected
    /// errors (P2 hygiene: not masqueraded as success).
    fn read(fd: fd_t, buf: []u8) error{ReadFailed}!usize {
        while (true) {
            if (builtin.os.tag == .linux) {
                const rc = std.os.linux.read(fd, buf.ptr, buf.len);
                switch (linuxRawErrno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return 0,
                    else => return error.ReadFailed,
                }
            } else {
                // Libc: success is byte count; errors are `-1` + thread errno.
                const rc = std.c.read(fd, buf.ptr, buf.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return 0,
                    else => return error.ReadFailed,
                }
            }
        }
    }

    fn setNonblock(fd: fd_t) bool {
        return setFlagStatus(fd, true);
    }

    fn setCloexec(fd: fd_t) bool {
        if (builtin.os.tag == .linux) {
            const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
            if (linuxRawErrno(cur) != .SUCCESS) return true;
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
            return linuxRawErrno(rc) != .SUCCESS;
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
            if (linuxRawErrno(cur) != .SUCCESS) return true;
            const cur_u: u32 = @intCast(cur);
            const nonblock_bit: u32 = O_NONBLOCK_LINUX;
            const new_u: u32 = if (nonblock) (cur_u | nonblock_bit) else (cur_u & ~nonblock_bit);
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, new_u);
            return linuxRawErrno(rc) != .SUCCESS;
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
// Process-lifetime interrupt state (review item 2 / P1 final).
//
// All fields are lock-free atomics or process-lifetime immutable values. No
// plain field is read by the handler while a non-handler thread might write
// it — eliminating the Zig memory-model UB flagged in the P1 review.
// ---------------------------------------------------------------------------

/// Interrupt state observed by the async-signal-safe handler. `disabled` is
/// the initial/teardown state: a handler that observes it returns immediately.
/// The second-SIGINT predicate is `pending` (the handler's own unacknowledged
/// state), NOT the Agent's cancel flag.
const State = enum(u32) {
    disabled = 0,
    idle = 1,
    pending = 2,
    escaped = 3,
};

/// Process-global handler state. Every field is async-signal-safe:
///   * `state`    — seq_cst atomic word; the only control flow the handler
///     branches on. `disabled` makes a new entry a no-op.
///   * `flag`     — lock-free atomic address of the bound `*Flag` (0 = unbound).
///     The handler loads it atomically; `deinit` stores 0 atomically. No
///     plain-field race.
///   * `in_flight` — lock-free atomic counter of handlers that have entered but
///     not yet returned. `deinit` drains it to zero before returning.
var handler_state: struct {
    state: std.atomic.Value(u32) = .init(@intFromEnum(State.disabled)),
    flag: std.atomic.Value(usize) = .init(0),
    in_flight: std.atomic.Value(u32) = .init(0),
} = .{};

/// Process-lifetime self-pipe write fd. Written exactly once on first pipe
/// creation; NEVER mutated by `deinit`. A handler can always read a stable,
/// valid fd — no close/fd-reuse window.
var lifetime_write_fd: fd_t = -1;
/// Process-lifetime self-pipe read fd (companion; also immutable after create).
var lifetime_read_fd: fd_t = -1;
var pipe_created: bool = false;

/// One-shot install latch (P1 final ABA fix). Set permanently on the first
/// successful `install`; NEVER cleared by `deinit`. Any later `install`
/// (including after teardown) returns `error.SigintInitFailed`. This removes
/// the teardown→reinstall ABA: an old-generation handler committed but not yet
/// executing cannot be confused with a new-generation entry.
var ever_installed: std.atomic.Value(bool) = .init(false);

/// Async-signal-safe SIGINT handler.
///   disabled -> (no-op)        : teardown in progress; return without touching flag/pipe.
///   IDLE     -> PENDING        : request cancel (if bound) + write one wake byte.
///   PENDING  -> ESCAPED        : hard exit 130 (second interrupt, abandonment).
///   ESCAPED  -> (no-op)        : a third signal while exiting.
/// `in_flight` is incremented on entry and decremented on normal return; the
/// hard-exit path does NOT decrement (the process is leaving).
fn onSigInt(_: posix.SIG) callconv(.c) void {
    // Count ourselves so deinit's drain cannot complete while we might still
    // touch the flag/pipe. Decrement only on normal return.
    _ = handler_state.in_flight.fetchAdd(1, .seq_cst);

    const cur: State = @enumFromInt(handler_state.state.load(.seq_cst));
    if (cur == .disabled or cur == .escaped) {
        _ = handler_state.in_flight.fetchSub(1, .seq_cst);
        return;
    }
    if (cur == .idle) {
        const swapped = handler_state.state.cmpxchgStrong(
            @intFromEnum(State.idle),
            @intFromEnum(State.pending),
            .seq_cst,
            .seq_cst,
        );
        if (swapped == null) {
            // Won the IDLE->PENDING transition: cooperative cancel + wake.
            const flag_addr = handler_state.flag.load(.seq_cst);
            if (flag_addr != 0) {
                const flag: *Flag = @ptrFromInt(flag_addr);
                flag.request();
            }
            if (lifetime_write_fd >= 0) sys.writeWake(lifetime_write_fd);
            _ = handler_state.in_flight.fetchSub(1, .seq_cst);
            return;
        }
        // Lost the race: someone else moved to pending/escaped. Reload below.
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
            // Does not return; does NOT decrement in_flight (process is leaving).
            sys.hardExit(130);
        }
    }
    // Either escaped already, or lost the race to escape; normal return.
    _ = handler_state.in_flight.fetchSub(1, .seq_cst);
}

// ---------------------------------------------------------------------------
// Guard: install/restore the SIGINT disposition against a cancel flag.
// ---------------------------------------------------------------------------

/// Errors from installing the guard. Distinct from `OutOfMemory` (review item
/// 7): a pipe/fcntl/sigaction failure, a concurrent/nested install, OR an
/// attempt to reinstall after the one-shot install already succeeded — all are
/// initialization faults, not memory exhaustion. Callers map this to an honest
/// init error, not OOM.
pub const InstallError = error{SigintInitFailed};

/// Process-lifetime singleton guard ownership flag. Prevents concurrent/nested
/// Guard installation (one owner at a time).
var guard_owned: std.atomic.Value(bool) = .init(false);

pub const Guard = struct {
    read_fd: fd_t,
    prev: posix.Sigaction,
    installed: bool,

    const invalid: fd_t = -1;

    /// `flag` must outlive every `reply`/`run` made under this guard (it is
    /// the Agent's cancel flag, owned by the Agent). Installation is ONE-SHOT
    /// per process (P1 final ABA fix): the first successful `install` latches
    /// `ever_installed` permanently; `deinit` restores the previous sigaction
    /// but a later `install` returns `error.SigintInitFailed`. The CLI has
    /// exactly one Guard for the process lifetime and never reinstalls.
    /// Concurrent/nested install is also rejected with `error.SigintInitFailed`.
    pub fn install(flag: ?*Flag) InstallError!Guard {
        if (!supported) {
            return .{ .read_fd = invalid, .prev = undefined, .installed = false };
        }

        // One-shot latch: once any install has succeeded, never again.
        if (ever_installed.load(.seq_cst)) return error.SigintInitFailed;
        // Reject concurrent/nested ownership.
        if (guard_owned.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            return error.SigintInitFailed;
        }

        // Create the process-lifetime self-pipe once. The write fd is stored
        // in a process-lifetime immutable variable (never rewritten by deinit).
        errdefer guard_owned.store(false, .seq_cst);
        if (!pipe_created) {
            const fds = sys.pipe() catch {
                return error.SigintInitFailed;
            };
            lifetime_read_fd = fds[0];
            lifetime_write_fd = fds[1];
            pipe_created = true;
        }

        // Safe bind order: flag first, then state=idle, THEN install the
        // sigaction. A signal delivered the instant after sigaction returns
        // observes a bound flag and an idle state.
        handler_state.flag.store(if (flag) |f| @intFromPtr(f) else 0, .seq_cst);
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

        // One-shot latch: mark permanently installed. This is intentionally
        // NOT cleared by deinit, so a later install cannot ABA onto a stale
        // old-generation handler.
        ever_installed.store(true, .seq_cst);

        return .{ .read_fd = lifetime_read_fd, .prev = prev, .installed = true };
    }

    /// Restore the previous disposition with a race-free teardown (P1 final):
    ///   1. state=disabled  — new handler entries return immediately.
    ///   2. flag=null       — atomic unbind (no plain-field race).
    ///   3. restore sigaction — signals after this go to the previous handler.
    ///   4. wait in_flight to 0 (UNbounded spin) — handlers that entered before
    ///      steps 1-3 and may still touch the (now-null) flag finish first.
    ///      The handler does only lock-free atomics + a nonblocking one-byte
    ///      write, so a normal-path entry is bounded and cannot deadlock here.
    ///      A handler that already loaded the old flag will finish its atomic
    ///      work before the Agent later destroys the flag.
    ///   5. clear guard ownership (but NOT `ever_installed` — install is one-shot).
    /// The self-pipe is process-lifetime and NEVER closed here, so `write_fd`
    /// stays valid for any in-flight handler (no fd-reuse window). Reinstall is
    /// forbidden (one-shot), so a late old-generation handler that enters after
    /// step 3 sees disabled + atomic flag=0 and cannot ABA to a new generation.
    pub fn deinit(self: *Guard) void {
        if (!supported or !self.installed) return;

        // 1. Disable: new entries see disabled and return without touching
        //    flag/pipe.
        handler_state.state.store(@intFromEnum(State.disabled), .seq_cst);
        // 2. Atomic unbind of the flag.
        handler_state.flag.store(0, .seq_cst);
        // 3. Restore the previous disposition.
        posix.sigaction(posix.SIG.INT, &self.prev, null);
        // 4. Drain in-flight handlers. UNbounded: the handler is lock-free +
        //    nonblocking-write only, so every in-flight entry is bounded and
        //    MUST complete. No allocation/lock/IO can stall it, so this cannot
        //    deadlock in practice.
        while (handler_state.in_flight.load(.seq_cst) != 0) {
            std.atomic.spinLoopHint();
        }
        // 5. Release ownership (but NOT ever_installed — install is one-shot).
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
// A persistent pending buffer retains same-batch input across two calls: if a
// raw read returns "first\nsecond\n", the first call returns "first" and
// retains "second\n" for the next call. EINTR loops (no recursion). The
// poll/self-pipe path returns `.interrupted` on SIGINT and never surfaces a
// `ReadFailed`/stack trace to the user.
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
///
/// A pending SIGINT is checked BEFORE consuming retained input, so an idle
/// Ctrl+C always wins over a queued next line (P2 hygiene). An unexpected
/// `poll` error is mapped to a typed `ReadFailed` (no infinite `continue`).
pub fn readInterruptibleLine(
    guard: *const Guard,
    lb: *LineBuffer,
    stdin_fd: fd_t,
    buffer: []u8,
    poll_timeout_ms: i32,
) error{ WouldBlockBufferTooSmall, ReadFailed }!IdleRead {
    if (!supported or !guard.installed) return error.WouldBlockBufferTooSmall;

    // Pending SIGINT takes priority over queued/retained input: an idle Ctrl+C
    // must interrupt even if a full next line is already buffered.
    if (@as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .pending) {
        drainWake(guard.read_fd);
        return .interrupted;
    }

    // Then serve any retained same-batch input from a prior call.
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
        // std.posix.poll auto-restarts on EINTR; a timeout (0) just re-checks.
        // An unexpected error is typed (no infinite continue) — P2 hygiene.
        _ = posix.poll(&fds, poll_timeout_ms) catch return error.ReadFailed;

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
        const got_eof = try appendStdin(lb, stdin_fd);
        if (!got_eof) {
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
        // Pending SIGINT re-check before handing a freshly-read line back, so
        // a signal that landed during the read still wins.
        if (@as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .pending) {
            drainWake(guard.read_fd);
            return .interrupted;
        }
        switch (consumePending(lb, buffer)) {
            .none => {},
            .too_small => return error.WouldBlockBufferTooSmall,
            .out => |out| return out,
        }
        // No newline yet in this batch: keep polling for more stdin/wake.
    }
}

/// Append one stdin read into the pending buffer. Returns true on data (or
/// would-block with no data), false on EOF. `ReadFailed` is a typed error
/// (P2 hygiene: not masqueraded as success). EINTR loops internally.
fn appendStdin(lb: *LineBuffer, stdin_fd: fd_t) error{ WouldBlockBufferTooSmall, ReadFailed }!bool {
    if (lb.pending_len >= lb.pending.len) return error.WouldBlockBufferTooSmall;
    const room = lb.pending[lb.pending_len..];
    const got = sys.read(stdin_fd, room) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
    };
    if (got == 0) return false; // EOF
    lb.pending_len += got;
    return true;
}

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
// Test-only reset hook (P1 final).
//
// Because `install` is one-shot per process, unit tests that need to exercise
// multiple install scenarios MUST reset the process-global latch/state. This
// hook is gated on `builtin.is_test` and compiles to a `@compileError` in the
// product executable, so it is NOT present/callable in the final product.
// It MUST only be called when no real signal is in flight and `in_flight == 0`
// (i.e. between tests, with the previous Guard deinit'd). It is NOT a product
// API and never appears in the shipped binary.
// ---------------------------------------------------------------------------

const testing_internal = if (builtin.is_test) struct {
    /// Reset the one-shot latch + globals so a subsequent test can `install`
    /// again. Caller guarantees no real signal delivery is in progress and
    /// `in_flight == 0` (the prior Guard has been deinit'd). NOT a product API.
    fn resetForTesting() void {
        assert(handler_state.in_flight.load(.seq_cst) == 0);
        assert(@as(State, @enumFromInt(handler_state.state.load(.seq_cst))) == .disabled);
        handler_state.state.store(@intFromEnum(State.disabled), .seq_cst);
        handler_state.flag.store(0, .seq_cst);
        ever_installed.store(false, .seq_cst);
        guard_owned.store(false, .seq_cst);
        pipe_created = false;
        lifetime_read_fd = -1;
        lifetime_write_fd = -1;
    }
} else struct {
    fn resetForTesting() callconv(.c) noreturn {
        @compileError("resetForTesting is a test-only hook and must not be called in the product binary");
    }
};

const assert = std.debug.assert;

/// Public test namespace. Only available under `builtin.is_test`; in the
/// product executable it triggers a `@compileError` on any use.
pub const testing = if (builtin.is_test) struct {
    pub const resetForTesting = testing_internal.resetForTesting;
    pub const State_ = State;
    pub const handlerStateSnapshot = struct {
        pub fn state() State {
            return @enumFromInt(handler_state.state.load(.seq_cst));
        }
        pub fn flagAddr() usize {
            return handler_state.flag.load(.seq_cst);
        }
        pub fn inFlight() u32 {
            return handler_state.in_flight.load(.seq_cst);
        }
        pub fn everInstalled() bool {
            return ever_installed.load(.seq_cst);
        }
        pub fn guardOwned() bool {
            return guard_owned.load(.seq_cst);
        }
    };
} else struct {
    pub const resetForTesting = testing_internal.resetForTesting;
};

// ---------------------------------------------------------------------------
// Tests
//
// Strategy (P1 final): the product `install` is one-shot per process, so tests
// that need multiple install scenarios call `testing.resetForTesting()` between
// scenarios (only when no real signal is in flight and in_flight==0). This keeps
// the product binary free of reinstall support while still allowing focused
// unit tests. Real Guard install is minimised where possible.
// ---------------------------------------------------------------------------

test "Guard install/restore is a no-op disposition round-trip on signal-capable OS" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    try std.testing.expect(guard.read_fd >= 0);
    try std.testing.expect(!flag.isSet());
    try std.testing.expect(!guard.pendingInterrupt());
}

test "first signal requests flag and wakes pipe; second signal predicate is handler state" {
    if (!supported) return;
    testing.resetForTesting();
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
    // The handler loads the flag atomically; simulate that path.
    const flag_addr = handler_state.flag.load(.seq_cst);
    try std.testing.expect(flag_addr != 0);
    const flag_ptr: *Flag = @ptrFromInt(flag_addr);
    flag_ptr.request();
    sys.writeWake(lifetime_write_fd);
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
    flag.clear();
}

test "deinit sets disabled and unbinds flag atomically; in_flight drains; install is one-shot" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    // Simulate one in-flight handler entry then a normal decrement so the
    // drain loop has work to observe.
    _ = handler_state.in_flight.fetchAdd(1, .seq_cst);
    _ = handler_state.in_flight.fetchSub(1, .seq_cst);
    guard.deinit();
    // After deinit: state is disabled, flag is unbound, ownership released.
    const end_state: State = @enumFromInt(handler_state.state.load(.seq_cst));
    try std.testing.expectEqual(State.disabled, end_state);
    try std.testing.expectEqual(@as(usize, 0), handler_state.flag.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), handler_state.in_flight.load(.seq_cst));
    try std.testing.expect(!testing.handlerStateSnapshot.guardOwned());
    // P1 final: install is ONE-SHOT. ever_installed stays true after deinit,
    // so a later install must FAIL (no teardown->reinstall ABA).
    try std.testing.expect(testing.handlerStateSnapshot.everInstalled());
    const again = Guard.install(&flag);
    try std.testing.expectError(error.SigintInitFailed, again);
}

test "concurrent/nested Guard install is rejected" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    // A second install while the first is still owned must fail.
    const second = Guard.install(&flag);
    try std.testing.expectError(error.SigintInitFailed, second);
    guard.deinit();
    // After deinit, install is STILL rejected (one-shot, not sequential reinstall).
    const again = Guard.install(&flag);
    try std.testing.expectError(error.SigintInitFailed, again);
}

test "readInterruptibleLine returns eof on closed stdin" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    sys.close(fds[1]); // close write end -> read end sees EOF
    defer sys.close(fds[0]);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    try std.testing.expect(out == .eof);
}

test "readInterruptibleLine reads a line" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
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
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    _ = handler_state.state.cmpxchgStrong(
        @intFromEnum(State.idle),
        @intFromEnum(State.pending),
        .seq_cst,
        .seq_cst,
    );
    sys.writeWake(lifetime_write_fd);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    try std.testing.expect(out == .interrupted);
    guard.acknowledgeCancel();
}

test "readInterruptibleLine: pending SIGINT wins over retained next line (P2 hygiene)" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    // Plant a retained line in the buffer as if read in a prior batch.
    const retained = "queued\n";
    @memcpy(lb.pending[0..retained.len], retained);
    lb.pending_len = retained.len;
    // Now set pending (simulate a SIGINT that landed before the next read).
    _ = handler_state.state.cmpxchgStrong(
        @intFromEnum(State.idle),
        @intFromEnum(State.pending),
        .seq_cst,
        .seq_cst,
    );
    sys.writeWake(lifetime_write_fd);
    // A pipe whose write end is kept open but never written: poll never sees
    // readable/EOF, so the pending-interrupt path is exercised cleanly. Both
    // ends are closed on scope exit (no fd leak).
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var buf: [128]u8 = undefined;
    const out = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    try std.testing.expect(out == .interrupted);
    // The retained line is still in the buffer (not consumed).
    try std.testing.expectEqual(@as(usize, retained.len), lb.pending_len);
    guard.acknowledgeCancel();
}

test "readInterruptibleLine retains same-batch bytes across two calls (review item 4)" {
    if (!supported) return;
    testing.resetForTesting();
    var flag: Flag = .{};
    var guard = try Guard.install(&flag);
    defer guard.deinit();
    var lb = LineBuffer.init();
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    const two = "first\nsecond\n";
    _ = if (builtin.os.tag == .linux)
        std.os.linux.write(fds[1], two.ptr, two.len)
    else
        std.c.write(fds[1], two.ptr, two.len);
    var buf: [128]u8 = undefined;
    const out1 = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    switch (out1) {
        .line => |l| try std.testing.expectEqualStrings("first", l),
        else => return error.TestUnexpectedResult,
    }
    const out2 = try readInterruptibleLine(&guard, &lb, fds[0], &buf, 50);
    switch (out2) {
        .line => |l| try std.testing.expectEqualStrings("second", l),
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// ci-hang-sigint-linux-errno-001 fixtures (F1 / F2)
// ---------------------------------------------------------------------------

/// Kernel raw encoding of a negative Linux errno as `usize` (signed-window).
fn syntheticLinuxRc(err: std.os.linux.E) usize {
    const neg: isize = -@as(isize, @intFromEnum(err));
    return @bitCast(neg);
}

test "F1: raw Linux -EAGAIN decodes via linuxRawErrno independent of link_libc" {
    // Pure unit: no host thread errno, no real syscall. Exercises the same
    // helper every audited Linux product site uses (pipe2/read/fcntl).
    const again_rc = syntheticLinuxRc(.AGAIN);
    const intr_rc = syntheticLinuxRc(.INTR);
    try std.testing.expectEqual(std.os.linux.E.AGAIN, linuxRawErrno(again_rc));
    try std.testing.expectEqual(std.os.linux.E.INTR, linuxRawErrno(intr_rc));
    try std.testing.expect(linuxRawErrno(again_rc) != .SUCCESS);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, linuxRawErrno(0));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, linuxRawErrno(64));

    // Under link_libc, libc-shaped posix.errno only treats rc == -1 as error.
    // Kernel -EAGAIN is a large unsigned value, not -1 — so posix.errno would
    // falsely report SUCCESS (the hang class this fixture locks out).
    if (builtin.link_libc) {
        try std.testing.expect(posix.errno(again_rc) == .SUCCESS);
    }
    // Record link_libc so dual-backend Gate (std vs curl) both exercise this.
    _ = builtin.link_libc;
}

test "F2: empty nonblocking wake-pipe drain terminates" {
    if (!supported) return;
    // NONBLOCK pipe with no data: sys.read must return 0 (would-block), and
    // drainWake must not spin. Bounded by the syscall itself — no sleeps.
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var buf: [8]u8 = undefined;
    const got = try sys.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), got);
    drainWake(fds[0]);
    const got2 = try sys.read(fds[0], &buf);
    try std.testing.expectEqual(@as(usize, 0), got2);
}
