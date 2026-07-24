//! Shared request lifecycle helpers for openai-zig transports (no zag-types dep).
//!
//! Hosts (zag-ai) install cancel flag + monotonic deadline via Transport methods.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const errors = @import("../errors.zig");

/// Borrowed cancel + absolute mono deadline for one in-flight request.
pub const Control = struct {
    /// Points at host-owned `std.atomic.Value(bool)` (e.g. CancelFlag.cancelled).
    cancel_atomic: ?*const std.atomic.Value(bool) = null,
    deadline_mono_ns: ?u64 = null,

    pub fn none() Control {
        return .{};
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
    };
}

/// Watchdog: shuts down stream when cancel/deadline trips.
pub const AbortWatch = struct {
    control: Control,
    io: std.Io,
    stream_ptr: std.atomic.Value(?*std.Io.net.Stream) = .init(null),
    stop: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *AbortWatch) !std.Thread {
        return std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn finish(self: *AbortWatch, thread: ?std.Thread) void {
        self.stop.store(true, .seq_cst);
        if (thread) |t| t.join();
        self.stream_ptr.store(null, .seq_cst);
    }

    fn threadMain(self: *AbortWatch) void {
        while (!self.stop.load(.seq_cst)) {
            const now = monoNowNs();
            if (self.control.isCancelled() or self.control.isExpired(now)) {
                if (self.stream_ptr.load(.seq_cst)) |s| {
                    s.shutdown(self.io, .both) catch {};
                }
                return;
            }
            const duration: std.Io.Duration = .{ .nanoseconds = 25 * std.time.ns_per_ms };
            std.Io.sleep(self.io, duration, .awake) catch {};
        }
    }
};
