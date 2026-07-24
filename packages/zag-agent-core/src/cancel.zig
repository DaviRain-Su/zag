//! Cooperative cancel for the harness loop (H1).
//!
//! SIGINT (or tests) flip a flag; the loop checks between turns / tool calls and
//! finishes any open tool_call pair with `code=cancelled` so transcript stays
//! resume-safe. Chat/provider calls already in flight are not preempted.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Flag = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *Flag) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isSet(self: *const Flag) bool {
        return self.cancelled.load(.seq_cst);
    }

    pub fn clear(self: *Flag) void {
        self.cancelled.store(false, .seq_cst);
    }
};

var sigint_target: ?*Flag = null;

fn onSigInt(_: posix.SIG) callconv(.c) void {
    if (sigint_target) |flag| {
        flag.request();
    }
}

/// Install a process-wide SIGINT handler that requests `flag`.
/// No-op on platforms without POSIX signals. Replaces any prior Zag handler.
pub fn installSigInt(flag: *Flag) void {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd => {},
        else => return,
    }

    sigint_target = flag;

    var act: posix.Sigaction = .{
        .handler = .{ .handler = onSigInt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    // SA_RESTART would hide EINTR from blocking IO; we want cancel to surface.
    posix.sigaction(posix.SIG.INT, &act, null);
}

test "flag request and clear" {
    // Goal: cooperative cancel is sticky until cleared.
    var flag: Flag = .{};
    try std.testing.expect(!flag.isSet());
    flag.request();
    try std.testing.expect(flag.isSet());
    flag.clear();
    try std.testing.expect(!flag.isSet());
}
