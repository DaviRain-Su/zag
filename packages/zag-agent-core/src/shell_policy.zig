//! ShellPolicy port — required pre-execution shell command gate (D-011).
//!
//! The decision (allow/deny) is **nonfallible**: policy does not mask a host
//! failure as OOM. The denial body is rendered by a fallible `deniedBody`
//! vtable entry called only after a deny decision; it returns an owned
//! non-optional body allocated with the caller's allocator, which the loop
//! frees immediately after appending the single Tool result.
//!
//! A non-shell tool must return an explicit not-applicable verdict (`allow`)
//! from the implementation; there is no implicit allow.
//! `zag-coding-agent.Agent` always installs the product `protect` policy;
//! the concrete denylist, `fromMode`, and `protectCheck` live in
//! `zag-coding-agent` (moved from Core by core-policy-ownership-001).
//!
//! Explicit low-level `allowAllForTrustedHost` / `denyAll` test vtables must
//! implement a generic Core renderer (`tool_error.format`). The allow helper
//! also implements a renderer but it is normally unreachable.

const std = @import("std");
const tool_error = @import("tool_error.zig");

pub const Decision = enum { allow, deny };

pub const ShellPolicyVTable = struct {
    /// Nonfallible decision on a validated command string. The loop only
    /// invokes this for descriptors declaring `shell = .command_argument`.
    check: *const fn (ptr: ?*anyopaque, command: []const u8) Decision,

    /// Fallible body renderer called only after a `deny` decision. Returns an
    /// owned non-optional body allocated with `allocator`; the loop frees it.
    /// `command` is the validated command string (may be used by product
    /// adapters but must never appear in the generic Core renderer).
    deniedBody: *const fn (
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        command: []const u8,
    ) error{OutOfMemory}![]u8,
};

/// Borrowed, required shell command gate.
pub const ShellPolicy = struct {
    ptr: ?*anyopaque = null,
    vtable: *const ShellPolicyVTable,

    pub fn check(self: ShellPolicy, command: []const u8) Decision {
        return self.vtable.check(self.ptr, command);
    }

    /// Render the deny body (called only after a deny decision). Owned by the
    /// caller; the loop frees the slice immediately after use.
    pub fn deniedBody(
        self: ShellPolicy,
        allocator: std.mem.Allocator,
        command: []const u8,
    ) error{OutOfMemory}![]u8 {
        return self.vtable.deniedBody(self.ptr, allocator, command);
    }

    /// Explicitly-named permissive shell policy for trusted low-level hosts.
    /// Never selected by product defaults.
    pub fn allowAllForTrustedHost() ShellPolicy {
        return .{
            .ptr = null,
            .vtable = &allow_all_vtable,
        };
    }

    /// Explicitly-named deny-all shell policy (tests / fail-closed composition).
    pub fn denyAll() ShellPolicy {
        return .{
            .ptr = null,
            .vtable = &deny_all_vtable,
        };
    }
};

const generic_shell_denied_message =
    "shell command blocked by policy; use a safer command or ask the user to adjust policy";

/// Generic Core deny body renderer (used by explicit low-level vtables).
/// Product adapters in `zag-coding-agent` call the moved `shell_policy.deniedMessage`
/// so product body bytes stay identical.
pub fn genericDeniedBody(
    allocator: std.mem.Allocator,
    command: []const u8,
) error{OutOfMemory}![]u8 {
    _ = command;
    return tool_error.format(allocator, .shell_deny, generic_shell_denied_message);
}

const allow_all_vtable: ShellPolicyVTable = .{
    .check = allowAllCheck,
    .deniedBody = allowAllDeniedBody,
};
fn allowAllCheck(_: ?*anyopaque, _: []const u8) Decision {
    return .allow;
}
fn allowAllDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    command: []const u8,
) error{OutOfMemory}![]u8 {
    // Normally unreachable (allow never denies). Use generic renderer.
    return genericDeniedBody(allocator, command);
}

const deny_all_vtable: ShellPolicyVTable = .{
    .check = denyAllCheck,
    .deniedBody = denyAllDeniedBody,
};
fn denyAllCheck(_: ?*anyopaque, _: []const u8) Decision {
    return .deny;
}
fn denyAllDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    command: []const u8,
) error{OutOfMemory}![]u8 {
    return genericDeniedBody(allocator, command);
}

test "allowAllForTrustedHost permits any command" {
    const p = ShellPolicy.allowAllForTrustedHost();
    try std.testing.expect(p.check("rm -rf /") == .allow);
}

test "denyAll denies any command" {
    const p = ShellPolicy.denyAll();
    try std.testing.expect(p.check("zig build test") == .deny);
}

test "generic deny body is fixed and omits command" {
    const gpa = std.testing.allocator;
    const sentinel = "rm -rf / # SHELL_DENY_COMMAND_SENTINEL";
    const body = try genericDeniedBody(gpa, sentinel);
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=shell_deny message=shell command blocked by policy; use a safer command or ask the user to adjust policy",
        body,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "SHELL_DENY_COMMAND_SENTINEL") == null);
}

test "denyAll deniedBody renders generic body" {
    const gpa = std.testing.allocator;
    const p = ShellPolicy.denyAll();
    const body = try p.deniedBody(gpa, "rm -rf /");
    defer gpa.free(body);
    try std.testing.expect(tool_error.hasCode(body, .shell_deny));
}

test "allowAll deniedBody renders generic body (normally unreachable)" {
    const gpa = std.testing.allocator;
    const p = ShellPolicy.allowAllForTrustedHost();
    const body = try p.deniedBody(gpa, "anything");
    defer gpa.free(body);
    try std.testing.expect(tool_error.hasCode(body, .shell_deny));
}