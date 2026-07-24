//! Cooperative cancel for the harness loop (H1 + h-provider-001).
//!
//! SIGINT (or tests) flip a flag. The loop checks between turns / tool calls and
//! passes the same flag into provider request control so in-flight HTTP can abort.
//! Open tool_call pairs finish with `code=cancelled` so transcript stays resume-safe.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const zt = @import("zag-types");

/// L0 cancel flag (thread-/signal-safe). Re-exported for Agent/loop/CLI.
pub const Flag = zt.CancelFlag;

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
