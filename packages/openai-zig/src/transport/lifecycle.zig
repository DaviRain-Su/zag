//! Shared request lifecycle helpers for openai-zig transports (no zag-types dep).
//!
//! Hosts (zag-ai) install cancel flag + monotonic deadline via Transport methods.
//!
//! ## Capability truth
//!
//! - **curl**: can enforce active deadline + active cancel.
//! - **std**: ordinary requests OK; deadline / require_active_cancel → fail closed
//!   with `error.Timeout` mapping via Cancelled/Timeout path is not used — use
//!   `assertSupported` → `error.Unimplemented` is wrong; we map to a distinct
//!   transport error. openai-zig uses `errors.Error.Unimplemented` historically;
//!   Agent maps UnsupportedControl from zag-ai before calling SDK when possible.
//!
//! No cross-thread connection shutdown (removed: UAF race).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const errors = @import("../errors.zig");
const build_options = @import("openai_build_options");

/// Borrowed cancel + absolute mono deadline for one in-flight request.
pub const Control = struct {
    /// Points at host-owned `std.atomic.Value(bool)` (e.g. CancelFlag.cancelled).
    cancel_atomic: ?*const std.atomic.Value(bool) = null,
    deadline_mono_ns: ?u64 = null,
    /// Demand active mid-request abort (curl only).
    require_active_cancel: bool = false,

    pub fn none() Control {
        return .{};
    }

    pub fn hasDeadline(self: Control) bool {
        return self.deadline_mono_ns != null;
    }

    pub fn needsEnforcedLifecycle(self: Control) bool {
        return self.hasDeadline() or self.require_active_cancel;
    }

    pub fn isCancelled(self: Control) bool {
        return if (self.cancel_atomic) |a| a.load(.seq_cst) else false;
    }

    pub fn isExpired(self: Control, now: u64) bool {
        return if (self.deadline_mono_ns) |d| now >= d else false;
    }

    pub fn check(self: Control, now: u64) errors.Error!void {
        if (self.isCancelled()) return error.Cancelled;
        if (self.isExpired(now)) return error.Timeout;
    }

    pub fn checkNow(self: Control) errors.Error!void {
        return self.check(monoNowNs());
    }

    pub fn remainingMs(self: Control, now: u64) ?u64 {
        const d = self.deadline_mono_ns orelse return null;
        if (now >= d) return 0;
        return (d - now) / std.time.ns_per_ms;
    }

    pub fn curlTimeoutMs(self: Control, now: u64, configured_ms: ?u64) u64 {
        const from_deadline = self.remainingMs(now);
        if (from_deadline) |rem| {
            if (rem == 0) return 1;
            if (configured_ms) |cfg| return @min(cfg, rem);
            return rem;
        }
        return configured_ms orelse 0;
    }
};

pub fn backendSupportsActiveLifecycle() bool {
    return build_options.http_backend == .curl;
}

/// Fail closed before network when std cannot enforce required control.
pub fn assertSupported(control: Control) errors.Error!void {
    if (!control.needsEnforcedLifecycle()) return;
    if (backendSupportsActiveLifecycle()) return;
    return error.UnsupportedControl;
}

pub fn monoNowNs() u64 {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd => {
            const clock_id: posix.clockid_t = switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
                else => posix.CLOCK.MONOTONIC,
            };
            var ts: posix.timespec = undefined;
            switch (posix.errno(posix.system.clock_gettime(clock_id, &ts))) {
                .SUCCESS => {
                    const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch
                        return std.math.maxInt(u64);
                    return sec_ns +| @as(u64, @intCast(ts.nsec));
                },
                else => return 0,
            }
        },
        else => {
            const Static = struct {
                var timer: ?std.time.Timer = null;
                var mu: std.Thread.Mutex = .{};
            };
            Static.mu.lock();
            defer Static.mu.unlock();
            if (Static.timer == null) {
                Static.timer = std.time.Timer.start() catch return 0;
            }
            return Static.timer.?.read();
        },
    }
}

pub fn mergeConfiguredTimeout(control: Control, timeout_ms: ?u64) Control {
    if (control.deadline_mono_ns != null) return control;
    if (timeout_ms == null) return control;
    const ms = timeout_ms.?;
    const now = monoNowNs();
    const add_ns = std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    return .{
        .cancel_atomic = control.cancel_atomic,
        .deadline_mono_ns = now +| add_ns,
        .require_active_cancel = control.require_active_cancel,
    };
}
