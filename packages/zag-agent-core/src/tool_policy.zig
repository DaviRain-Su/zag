//! ToolPolicy port — required pre-execution permission gate (D-011).
//!
//! Replaces the loop's direct dependency on `permissions.Gate` with an
//! explicit, borrowed port. The decision (allow/deny) is **nonfallible**:
//! policy does not mask a host failure as OOM. Denial-message allocation is
//! owned by the caller (the loop), preserving the existing soft Tool result
//! shape and the `permission_denied` code.
//!
//! `zag-coding-agent.Agent` always installs the product ask gate (or an
//! explicit documented mode). A low-level host may explicitly install a
//! permissive policy because it already controls arbitrary Provider/Tool
//! function pointers; missing is never implicitly allow/yolo.

const std = @import("std");
const zt = @import("zag-types");

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

const allow_all_vtable: ToolPolicyVTable = .{
    .check = allowAllCheck,
};
fn allowAllCheck(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8, _: ?[]const u8) Outcome {
    return .{ .decision = .allow };
}

const deny_all_vtable: ToolPolicyVTable = .{
    .check = denyAllCheck,
};
fn denyAllCheck(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8, _: ?[]const u8) Outcome {
    return .{ .decision = .deny };
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