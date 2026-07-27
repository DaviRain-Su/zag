//! Product-internal SignalHost port (CLI implements over sigint.Guard).
//! Defined here so zag-tui never imports zag-cli / sigint.zig.

const std = @import("std");
const posix = std.posix;

/// Borrowed host port: CLI wraps the live Guard after Guard.install succeeds.
pub const SignalHost = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Guard self-pipe read end (or -1 when inert/unsupported).
        wake_fd: *const fn (ptr: *anyopaque) posix.fd_t,
        /// Drain Guard wake pipe (nonblocking). No allocation / no render.
        drain_wake: *const fn (ptr: *anyopaque) void,
        /// True when Guard state is pending (unacknowledged interrupt).
        pending_interrupt: *const fn (ptr: *anyopaque) bool,
        /// Map to Guard.acknowledgeCancel — pending → idle after a run consumed interrupt.
        acknowledge_cancel: *const fn (ptr: *anyopaque) void,
    };

    pub fn wakeFd(self: SignalHost) posix.fd_t {
        return self.vtable.wake_fd(self.ptr);
    }

    pub fn drainWake(self: SignalHost) void {
        self.vtable.drain_wake(self.ptr);
    }

    pub fn pendingInterrupt(self: SignalHost) bool {
        return self.vtable.pending_interrupt(self.ptr);
    }

    pub fn acknowledgeCancel(self: SignalHost) void {
        self.vtable.acknowledge_cancel(self.ptr);
    }
};
