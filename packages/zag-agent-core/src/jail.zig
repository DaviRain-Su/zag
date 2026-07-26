//! Jail port — required pre-execution workspace containment gate (D-011).
//!
//! Replaces the loop's direct dependency on `workspace.Guard` with an
//! explicit, borrowed port. A non-file tool must return an explicit
//! not-applicable verdict (`allow`) from the implementation; there is no
//! implicit allow. Host allocation failure (`OutOfMemory`) is a typed run
//! failure; escape/dangling/resolve failures produce a soft `jail_deny`
//! verdict whose body the loop appends as the single Tool result.
//!
//! The same single-extracted path is passed to policy and jail (descriptor
//! driven, extracted once by `tool_args.pathFromDescriptor`).
//!
//! The concrete `WorkspaceGuardAdapter` / `guardCheck` and all filesystem
//! containment logic (Guard, Root, realpath, symlink checks) live in
//! `zag-coding-agent` (moved from Core by core-policy-ownership-001). Core
//! retains only the port, the explicit `allowAllForTrustedHost` helper, and
//! a generic deny body renderer for low-level test vtables.

const std = @import("std");
const Io = std.Io;
const tool_error = @import("tool_error.zig");

pub const JailError = error{
    OutOfMemory,
};

pub const Verdict = enum {
    /// Path is inside the workspace (or tool declares no path claim). Handler may run.
    allow,
    /// Path escapes the workspace jail. Loop appends one soft `jail_deny` result.
    deny,
};

pub const Check = struct {
    verdict: Verdict,
    /// Owned deny body when `verdict == .deny` (caller frees with `allocator`).
    /// `null` when allowed.
    deny_body: ?[]u8 = null,
};

pub const JailVTable = struct {
    /// Check an already-extracted path against workspace containment.
    /// `path` is `null` when the descriptor declares no path field; the
    /// implementation returns `allow` for non-file tools (explicit N/A).
    check: *const fn (
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        workspace_root_real: ?[]const u8,
        tool_name: []const u8,
        path: ?[]const u8,
    ) JailError!Check,
};

/// Borrowed, required workspace jail gate.
pub const Jail = struct {
    ptr: ?*anyopaque = null,
    vtable: *const JailVTable,

    pub fn check(
        self: Jail,
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        workspace_root_real: ?[]const u8,
        tool_name: []const u8,
        path: ?[]const u8,
    ) JailError!Check {
        return self.vtable.check(self.ptr, allocator, io, cwd, workspace_root_real, tool_name, path);
    }

    /// Explicitly-named permissive jail for trusted low-level hosts only.
    /// Never selected by product defaults.
    pub fn allowAllForTrustedHost() Jail {
        return .{
            .ptr = null,
            .vtable = &allow_all_vtable,
        };
    }
};

const jail_deny_message = "path outside workspace jail. Use relative paths under the working directory; absolute paths, '..' escapes, and symlink/alias escapes are denied.";

/// Generic Core deny body renderer (used by explicit low-level test vtables).
/// Product adapters in `zag-coding-agent` call the moved `workspace.deniedMessage`
/// so product body bytes stay identical.
pub fn genericDeniedBody(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return tool_error.format(allocator, .jail_deny, jail_deny_message);
}

const allow_all_vtable: JailVTable = .{
    .check = allowAllCheck,
};
fn allowAllCheck(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: Io,
    _: Io.Dir,
    _: ?[]const u8,
    _: []const u8,
    _: ?[]const u8,
) JailError!Check {
    return .{ .verdict = .allow };
}

/// Explicitly-named deny-all jail for low-level tests. Renders a generic
/// `jail_deny` body. Not exported publicly; file-local only.
const deny_all_vtable: JailVTable = .{
    .check = denyAllCheck,
};
fn denyAllCheck(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: Io,
    _: Io.Dir,
    _: ?[]const u8,
    _: []const u8,
    path: ?[]const u8,
) JailError!Check {
    // Non-file tools (path == null) are explicitly allowed (N/A).
    if (path == null) return .{ .verdict = .allow };
    return .{ .verdict = .deny, .deny_body = try genericDeniedBody(allocator) };
}

test "allowAllForTrustedHost permits any path" {
    const gpa = std.testing.allocator;
    const jail = Jail.allowAllForTrustedHost();
    const r = try jail.check(gpa, std.testing.io, std.Io.Dir.cwd(), null, "x", "/etc/passwd");
    try std.testing.expect(r.verdict == .allow);
    try std.testing.expect(r.deny_body == null);
}

test "denyAll denies file paths and allows non-file tools" {
    const gpa = std.testing.allocator;
    const jail: Jail = .{ .ptr = null, .vtable = &deny_all_vtable };
    // Non-file tool (path == null) → allow (explicit N/A).
    const r1 = try jail.check(gpa, std.testing.io, std.Io.Dir.cwd(), null, "x", null);
    try std.testing.expect(r1.verdict == .allow);
    // File tool → deny with generic body.
    const r2 = try jail.check(gpa, std.testing.io, std.Io.Dir.cwd(), null, "x", "/etc/passwd");
    try std.testing.expect(r2.verdict == .deny);
    try std.testing.expect(r2.deny_body != null);
    defer gpa.free(r2.deny_body.?);
    try std.testing.expect(tool_error.hasCode(r2.deny_body.?, .jail_deny));
}

test "generic deny body is generic bounded and path-free" {
    const gpa = std.testing.allocator;
    const sentinel = "ULTRA_LONG_PATH_SENTINEL_6fe0";
    const body = try genericDeniedBody(gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("error: code=jail_deny message=" ++ jail_deny_message, body);
    try std.testing.expect(body.len < 512);
    try std.testing.expect(std.mem.indexOf(u8, body, sentinel) == null);
}