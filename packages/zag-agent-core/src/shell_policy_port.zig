//! ShellPolicy port — required pre-execution shell command gate (D-011).
//!
//! Replaces the loop's direct dependency on `shell_policy.check` with an
//! explicit, borrowed port. The decision (allow/deny) is **nonfallible**:
//! policy does not mask a host failure as OOM. Denial-message allocation is
//! owned by the caller (the loop), preserving the existing soft Tool result
//! shape and the `shell_deny` code.
//!
//! A non-shell tool must return an explicit not-applicable verdict (`allow`)
//! from the implementation; there is no implicit allow. `zag-coding-agent.Agent`
//! always installs the product `protect` policy.

const std = @import("std");
const shell_policy = @import("shell_policy.zig");

pub const Decision = enum { allow, deny };

pub const ShellPolicyVTable = struct {
    /// Nonfallible decision on a validated command string. The loop only
    /// invokes this for descriptors declaring `shell = .command_argument`.
    check: *const fn (ptr: ?*anyopaque, command: []const u8) Decision,
};

/// Borrowed, required shell command gate.
pub const ShellPolicy = struct {
    ptr: ?*anyopaque = null,
    vtable: *const ShellPolicyVTable,

    pub fn check(self: ShellPolicy, command: []const u8) Decision {
        return self.vtable.check(self.ptr, command);
    }

    /// Explicitly-named permissive shell policy for trusted low-level hosts.
    /// Never selected by product defaults.
    pub fn allowAllForTrustedHost() ShellPolicy {
        return .{
            .ptr = null,
            .vtable = &allow_all_vtable,
        };
    }

    /// Adapter over the existing `shell_policy` denylist (product `protect`
    /// default). Lives in Core during the seam migration (D-011 step 1).
    pub fn fromMode(mode: shell_policy.Mode) ShellPolicy {
        return switch (mode) {
            .protect => .{ .ptr = null, .vtable = &protect_vtable },
            .off => .{ .ptr = null, .vtable = &allow_all_vtable },
        };
    }
};

const allow_all_vtable: ShellPolicyVTable = .{
    .check = allowAllCheck,
};
fn allowAllCheck(_: ?*anyopaque, _: []const u8) Decision {
    return .allow;
}

const protect_vtable: ShellPolicyVTable = .{
    .check = protectCheck,
};
fn protectCheck(_: ?*anyopaque, command: []const u8) Decision {
    return switch (shell_policy.check(.protect, command)) {
        .allow => .allow,
        .deny => .deny,
    };
}

// (no per-instance state: protect/off are vtable-selected and stateless).

test "allowAllForTrustedHost permits any command" {
    const p = ShellPolicy.allowAllForTrustedHost();
    try std.testing.expect(p.check("rm -rf /") == .allow);
}

test "fromMode protect denies catastrophic command" {
    const p = ShellPolicy.fromMode(.protect);
    try std.testing.expect(p.check("rm -rf /") == .deny);
    try std.testing.expect(p.check("zig build test") == .allow);
}

test "fromMode off allows deny-list command" {
    const p = ShellPolicy.fromMode(.off);
    try std.testing.expect(p.check("rm -rf /") == .allow);
}