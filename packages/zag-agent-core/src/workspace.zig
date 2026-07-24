//! Workspace path jail — refuse tools that escape the working tree.
//!
//! Phase 3 rule: all `path` arguments must be **relative** and must not climb
//! above the workspace root via `..`. Absolute paths are rejected.

const std = @import("std");

pub const Error = error{
    OutsideWorkspace,
    InvalidPath,
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
    return std.fmt.allocPrint(
        allocator,
        "error: path outside workspace jail: '{s}'. Use relative paths under the working directory; '..' escapes and absolute paths are denied.",
        .{path},
    );
}

/// Extract `path` from JSON tool arguments when present.
pub fn pathArgument(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("path") orelse return null;
    if (val != .string) return null;
    return try allocator.dupe(u8, val.string);
}

pub fn toolUsesPath(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "list_dir") or
        std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "search_replace") or
        std.mem.eql(u8, tool_name, "grep") or
        std.mem.eql(u8, tool_name, "glob");
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
