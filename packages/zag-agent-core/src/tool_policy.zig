//! ToolPolicy port — required pre-execution permission gate (D-011).
//!
//! The decision (allow/deny) is **nonfallible**: policy does not mask a host
//! failure as OOM. The denial body is rendered by a fallible `deniedBody`
//! vtable entry called only after a deny decision; it returns an owned
//! non-optional body allocated with the caller's allocator, which the loop
//! frees immediately after appending the single Tool result.
//!
//! `zag-coding-agent.Agent` always installs the product ask gate (or an
//! explicit documented mode). A low-level host may explicitly install a
//! permissive policy because it already controls arbitrary Provider/Tool
//! function pointers; missing is never implicitly allow/yolo.
//!
//! Explicit low-level `allowAllForTrustedHost` / `denyAll` test vtables must
//! implement a generic Core renderer (`tool_error.format`). The allow helper
//! also implements a renderer but it is normally unreachable.

const std = @import("std");
const zt = @import("zag-types");
const tool_error = @import("tool_error.zig");

pub const Decision = enum { allow, deny };

pub const Outcome = struct {
    decision: Decision,
    /// True when ask-mode write was skipped because the path was remembered.
    remembered: bool = false,
    /// True when deny came from a plan-mode overlay (not a user prompt).
    plan_blocked: bool = false,
};

pub const ToolPolicyVTable = struct {
    /// Nonfallible decision. `path` is the same single-extracted path shared
    /// with the jail (descriptor-driven, already validated/extracted).
    check: *const fn (
        ptr: ?*anyopaque,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
        path: ?[]const u8,
    ) Outcome,

    /// Fallible body renderer called only after a `deny` decision. Returns an
    /// owned non-optional body allocated with `allocator`; the loop frees it.
    /// `descriptor` carries the tool name used in the product deny body.
    /// `outcome` is the structured deny result (carries `plan_blocked` etc.).
    deniedBody: *const fn (
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        descriptor: zt.ToolDescriptor,
        outcome: Outcome,
    ) error{OutOfMemory}![]u8,
};

/// Borrowed, required pre-execution permission gate.
pub const ToolPolicy = struct {
    ptr: ?*anyopaque = null,
    vtable: *const ToolPolicyVTable,

    pub fn check(
        self: ToolPolicy,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
        path: ?[]const u8,
    ) Outcome {
        return self.vtable.check(self.ptr, descriptor, arguments_json, path);
    }

    /// Render the deny body (called only after a deny decision). Owned by the
    /// caller; the loop frees the slice immediately after use.
    pub fn deniedBody(
        self: ToolPolicy,
        allocator: std.mem.Allocator,
        descriptor: zt.ToolDescriptor,
        outcome: Outcome,
    ) error{OutOfMemory}![]u8 {
        return self.vtable.deniedBody(self.ptr, allocator, descriptor, outcome);
    }

    /// Explicitly-named permissive policy for trusted low-level hosts only.
    /// Never selected by product defaults. Hosts that select this already
    /// control arbitrary Provider/Tool function pointers.
    pub fn allowAllForTrustedHost() ToolPolicy {
        return .{
            .ptr = null,
            .vtable = &allow_all_vtable,
        };
    }

    /// Explicitly-named deny-all policy (tests / fail-closed composition).
    pub fn denyAll() ToolPolicy {
        return .{
            .ptr = null,
            .vtable = &deny_all_vtable,
        };
    }
};

const generic_denied_message_user =
    "The user rejected this operation. Do not retry the same call; explain what you wanted to do and wait for guidance.";
const generic_denied_message_plan =
    "Session is in plan mode: only read tools and writing plan.md / .zag/plan.md are allowed. Switch to agent mode for general edits or shell.";

/// Generic Core deny body renderer (used by explicit low-level vtables).
/// Product adapters in `zag-coding-agent` call the moved `permissions.deniedMessage`
/// / `permissions.deniedMessageWithReason` so product body bytes stay identical.
pub fn genericDeniedBody(
    allocator: std.mem.Allocator,
    descriptor: zt.ToolDescriptor,
    outcome: Outcome,
) error{OutOfMemory}![]u8 {
    const detail: []const u8 = if (outcome.plan_blocked)
        generic_denied_message_plan
    else
        generic_denied_message_user;
    const msg = try std.fmt.allocPrint(
        allocator,
        "permission denied for tool '{s}'. {s}",
        .{ descriptor.definition.name, detail },
    );
    defer allocator.free(msg);
    return tool_error.format(allocator, .permission_denied, msg);
}

const allow_all_vtable: ToolPolicyVTable = .{
    .check = allowAllCheck,
    .deniedBody = allowAllDeniedBody,
};
fn allowAllCheck(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8, _: ?[]const u8) Outcome {
    return .{ .decision = .allow };
}
fn allowAllDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    descriptor: zt.ToolDescriptor,
    outcome: Outcome,
) error{OutOfMemory}![]u8 {
    // Normally unreachable (allow never denies). Use generic renderer.
    return genericDeniedBody(allocator, descriptor, outcome);
}

const deny_all_vtable: ToolPolicyVTable = .{
    .check = denyAllCheck,
    .deniedBody = denyAllDeniedBody,
};
fn denyAllCheck(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8, _: ?[]const u8) Outcome {
    return .{ .decision = .deny };
}
fn denyAllDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    descriptor: zt.ToolDescriptor,
    outcome: Outcome,
) error{OutOfMemory}![]u8 {
    return genericDeniedBody(allocator, descriptor, outcome);
}

test "allowAllForTrustedHost permits any descriptor" {
    const p = ToolPolicy.allowAllForTrustedHost();
    const desc: zt.ToolDescriptor = .{
        .definition = .{ .name = "x", .description = "", .parameters_json = "{}" },
        .capabilities = .{ .risk = .write, .workspace = .none, .cancellation = .none, .shell = .none },
    };
    try std.testing.expect(p.check(desc, "{}", null).decision == .allow);
}

test "denyAll denies any descriptor" {
    const p = ToolPolicy.denyAll();
    const desc: zt.ToolDescriptor = .{
        .definition = .{ .name = "x", .description = "", .parameters_json = "{}" },
        .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
    };
    try std.testing.expect(p.check(desc, "{}", null).decision == .deny);
}

test "generic deny body is stable and name-bearing" {
    const gpa = std.testing.allocator;
    const desc: zt.ToolDescriptor = .{
        .definition = .{ .name = "write_file", .description = "", .parameters_json = "{}" },
        .capabilities = .{ .risk = .write, .workspace = .none, .cancellation = .none, .shell = .none },
    };
    const body = try genericDeniedBody(gpa, desc, .{ .decision = .deny });
    defer gpa.free(body);
    try std.testing.expect(tool_error.hasCode(body, .permission_denied));
    try std.testing.expect(std.mem.indexOf(u8, body, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "user rejected") != null);
}

test "generic deny body plan_blocked uses plan message" {
    const gpa = std.testing.allocator;
    const desc: zt.ToolDescriptor = .{
        .definition = .{ .name = "run_shell", .description = "", .parameters_json = "{}" },
        .capabilities = .{ .risk = .execute, .workspace = .none, .cancellation = .none, .shell = .none },
    };
    const body = try genericDeniedBody(gpa, desc, .{ .decision = .deny, .plan_blocked = true });
    defer gpa.free(body);
    try std.testing.expect(tool_error.hasCode(body, .permission_denied));
    try std.testing.expect(std.mem.indexOf(u8, body, "plan mode") != null);
}

test "denyAll deniedBody renders generic body" {
    const gpa = std.testing.allocator;
    const p = ToolPolicy.denyAll();
    const desc: zt.ToolDescriptor = .{
        .definition = .{ .name = "x", .description = "", .parameters_json = "{}" },
        .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
    };
    const body = try p.deniedBody(gpa, desc, .{ .decision = .deny });
    defer gpa.free(body);
    try std.testing.expect(tool_error.hasCode(body, .permission_denied));
}