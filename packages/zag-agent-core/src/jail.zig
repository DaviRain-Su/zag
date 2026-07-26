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

const std = @import("std");
const Io = std.Io;
const zt = @import("zag-types");
const workspace = @import("workspace.zig");
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

/// Adapter over the existing `workspace.Guard` containment logic. This is the
/// product path implementation that `zag-coding-agent` installs. It lives in
/// Core during the seam migration (D-011 step 1) and moves to coding-agent in
/// a later ownership task; behavior is byte-identical to the prior inline loop
/// gate (`pathJailCheckOwned` + `emitJailDeny`).
pub const WorkspaceGuardAdapter = struct {
    pub fn vtable() *const JailVTable {
        return &guard_vtable;
    }

    fn check(
        _: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        workspace_root_real: ?[]const u8,
        tool_name: []const u8,
        path: ?[]const u8,
    ) JailError!Check {
        const p = path orelse return .{ .verdict = .allow };
        if (try guardCheckOwned(allocator, io, cwd, workspace_root_real, tool_name, p)) |deny_body| {
            return .{ .verdict = .deny, .deny_body = deny_body };
        }
        return .{ .verdict = .allow };
    }
};

const guard_vtable: JailVTable = .{
    .check = WorkspaceGuardAdapter.check,
};

/// Jail check on an already-extracted path (lexical + real containment).
/// Returns an owned deny message, or null if path is OK for the handler.
/// Ordinary `NotFound` is allowed through — handlers report ToolFailed, not
/// jail_deny. Behavior matches the prior inline `pathJailCheckOwned`.
fn guardCheckOwned(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    workspace_root_real: ?[]const u8,
    _: []const u8,
    path: []const u8,
) JailError!?[]u8 {
    var guard = workspace.guardFrom(allocator, io, cwd, workspace_root_real) catch {
        return @as(?[]u8, try workspace.deniedMessage(allocator));
    };
    defer guard.deinit(allocator);

    guard.checkExisting(io, cwd, path) catch |err| switch (err) {
        error.NotFound => {
            guard.checkCreate(allocator, io, cwd, path) catch |cerr| switch (cerr) {
                error.NotFound => {},
                error.OutOfMemory => return error.OutOfMemory,
                error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
                    return @as(?[]u8, try workspace.deniedMessage(allocator));
                },
            };
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
            return @as(?[]u8, try workspace.deniedMessage(allocator));
        },
    };
    return null;
}

test "allowAllForTrustedHost permits any path" {
    const gpa = std.testing.allocator;
    const jail = Jail.allowAllForTrustedHost();
    const r = try jail.check(gpa, std.testing.io, std.Io.Dir.cwd(), null, "x", "/etc/passwd");
    try std.testing.expect(r.verdict == .allow);
    try std.testing.expect(r.deny_body == null);
}