//! Workspace path jail — refuse tools that escape the working tree.
//!
//! Phase 3 rule: all path arguments must be **relative** and must not climb
//! above the workspace root via `..`. Absolute paths are rejected.
//!
//! Which tools claim a path is decided by `ToolDescriptor.capabilities.workspace`,
//! not a built-in name list (D-007). Symlink-aware containment is h-workspace-001.
//!
//! When `workspace = path_field`, the named JSON field is **required** and must
//! be a string — missing/non-string/malformed JSON → `error.InvalidArguments`
//! (loop turns this into a soft `invalid_arguments` tool result before the handler).

const std = @import("std");
const zt = @import("zag-types");

pub const Error = error{
    OutsideWorkspace,
    InvalidPath,
};

pub const PathExtractError = error{
    OutOfMemory,
    InvalidArguments,
};

/// Validate a tool path against the workspace jail (string-level, no IO).
pub fn checkToolPath(path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    // Absolute paths leave the relative workspace model.
    if (std.fs.path.isAbsolute(path)) return error.OutsideWorkspace;

    // Windows drive / UNC-ish prefixes even if not absolute on this host.
    if (path.len >= 2 and path[1] == ':') return error.OutsideWorkspace;
    if (std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//"))
        return error.OutsideWorkspace;

    var depth: i32 = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return error.OutsideWorkspace;
            continue;
        }
        depth += 1;
    }
}

/// Soft error string for the model (caller owns with allocator).
pub fn deniedMessage(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    const tool_error = @import("tool_error.zig");
    const msg = try std.fmt.allocPrint(
        allocator,
        "path outside workspace jail: '{s}'. Use relative paths under the working directory; '..' escapes and absolute paths are denied.",
        .{path},
    );
    defer allocator.free(msg);
    return tool_error.format(allocator, .jail_deny, msg);
}

/// Extract a required string field from JSON tool arguments.
pub fn requireStringArgument(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
) PathExtractError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return error.InvalidArguments;
    if (val != .string) return error.InvalidArguments;
    return try allocator.dupe(u8, val.string);
}

/// Extract path using descriptor workspace metadata.
///
/// - `workspace.none` → `null` (no path claim).
/// - `workspace.path_field` → required string field; missing/non-string/bad JSON → `InvalidArguments`.
pub fn pathFromDescriptor(
    allocator: std.mem.Allocator,
    capabilities: zt.ToolCapabilities,
    arguments_json: []const u8,
) PathExtractError!?[]const u8 {
    const field = capabilities.workspace.pathField() orelse return null;
    const path = try requireStringArgument(allocator, arguments_json, field);
    return path;
}

test "jail allows relative paths" {
    try checkToolPath(".");
    try checkToolPath("src/main.zig");
    try checkToolPath("a/b/../c");
}

test "jail rejects absolute and escape" {
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("/etc/passwd"));
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("../secret"));
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("a/../../b"));
    try std.testing.expectError(error.InvalidPath, checkToolPath(""));
}

test "pathFromDescriptor respects workspace access" {
    const gpa = std.testing.allocator;
    const none_caps: zt.ToolCapabilities = .{
        .risk = .execute,
        .workspace = .none,
        .cancellation = .none,
        .shell = .command_argument,
    };
    try std.testing.expect(try pathFromDescriptor(gpa, none_caps, "{\"path\":\"x\"}") == null);

    const path_caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field = "path" },
        .cancellation = .none,
        .shell = .none,
    };
    const p = try pathFromDescriptor(gpa, path_caps, "{\"path\":\"src/a.zig\"}");
    defer if (p) |s| gpa.free(s);
    try std.testing.expectEqualStrings("src/a.zig", p.?);
}

test "pathFromDescriptor requires string field when path claimed" {
    const gpa = std.testing.allocator;
    const path_caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field = "path" },
        .cancellation = .none,
        .shell = .none,
    };
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{\"path\":1}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "not-json"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "[]"));
}
