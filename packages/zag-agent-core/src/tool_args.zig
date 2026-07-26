//! Neutral kernel module for descriptor-driven argument extraction.
//!
//! Single source for path/command extraction so `tool.zig` (registration
//! validation), `workspace.zig` (jail), and the loop policy/jail seams share
//! one parser and cannot drift. This module imports only `zag-types` so it
//! forms no cycle with `tool.zig` or `workspace.zig`.
//!
//! Extraction semantics (D-007 / tool-runtime.md):
//! - `workspace.none` → `null` (no path claim).
//! - `workspace.path_field` → required non-empty string field; missing/empty/
//!   non-string/malformed JSON → `InvalidArguments`.
//! - `workspace.path_field_default` → missing field or present empty string
//!   returns an owned default; present non-empty string is used as-is;
//!   non-string/malformed → `InvalidArguments`.
//! - shell `command_argument` → required non-empty string `command` field;
//!   missing/empty/non-string/malformed → `InvalidArguments`.

const std = @import("std");
const zt = @import("zag-types");

pub const ExtractError = error{
    OutOfMemory,
    InvalidArguments,
};

/// Extract the path using descriptor `capabilities.workspace` metadata.
/// Returns an owned slice (caller frees with `allocator`) or `null` when the
/// descriptor claims no path field. Missing/empty/non-string/malformed args
/// for a claimed field → `InvalidArguments` (handler never runs).
pub fn pathFromDescriptor(
    allocator: std.mem.Allocator,
    capabilities: zt.ToolCapabilities,
    arguments_json: []const u8,
) ExtractError!?[]const u8 {
    return switch (capabilities.workspace) {
        .none => null,
        .path_field => |field| try requireStringArgument(allocator, arguments_json, field),
        .path_field_default => |d| try optionalStringArgumentsOrDefault(
            allocator,
            arguments_json,
            d.field,
            d.default_path,
        ),
    };
}

/// Extract a required non-empty string `command` field for shell tools.
pub fn commandFromArguments(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) ExtractError![]const u8 {
    return requireStringArgument(allocator, arguments_json, "command");
}

/// Required non-empty string field from a flat JSON object. Owned by caller.
pub fn requireStringArgument(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
) ExtractError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return error.InvalidArguments;
    if (val != .string) return error.InvalidArguments;
    if (val.string.len == 0) return error.InvalidArguments;
    return try allocator.dupe(u8, val.string);
}

/// Optional string field yielding an owned default when missing/empty.
fn optionalStringArgumentsOrDefault(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
    default_path: []const u8,
) ExtractError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return try allocator.dupe(u8, default_path);
    if (val != .string) return error.InvalidArguments;
    if (val.string.len == 0) return try allocator.dupe(u8, default_path);
    return try allocator.dupe(u8, val.string);
}

test "pathFromDescriptor none returns null" {
    const gpa = std.testing.allocator;
    const none_caps: zt.ToolCapabilities = .{
        .risk = .execute,
        .workspace = .none,
        .cancellation = .none,
        .shell = .command_argument,
    };
    try std.testing.expect(try pathFromDescriptor(gpa, none_caps, "{\"path\":\"x\"}") == null);
}

test "pathFromDescriptor path_field requires non-empty string" {
    const gpa = std.testing.allocator;
    const path_caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field = "path" },
        .cancellation = .none,
        .shell = .none,
    };
    const p = try pathFromDescriptor(gpa, path_caps, "{\"path\":\"src/a.zig\"}");
    defer if (p) |s| gpa.free(s);
    try std.testing.expectEqualStrings("src/a.zig", p.?);

    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{\"path\":\"\"}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{\"path\":1}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "not-json"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "[]"));
}

test "pathFromDescriptor defaulted path handles missing empty explicit and invalid" {
    const gpa = std.testing.allocator;
    const caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field_default = .{ .field = "path", .default_path = "." } },
        .cancellation = .none,
        .shell = .none,
    };
    {
        const p = try pathFromDescriptor(gpa, caps, "{}");
        defer if (p) |s| gpa.free(s);
        try std.testing.expectEqualStrings(".", p.?);
    }
    {
        const p = try pathFromDescriptor(gpa, caps, "{\"path\":\"\"}");
        defer if (p) |s| gpa.free(s);
        try std.testing.expectEqualStrings(".", p.?);
    }
    {
        const p = try pathFromDescriptor(gpa, caps, "{\"path\":\"src/a.zig\"}");
        defer if (p) |s| gpa.free(s);
        try std.testing.expectEqualStrings("src/a.zig", p.?);
    }
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, caps, "{\"path\":1}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, caps, "not-json"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, caps, "[]"));
}

test "commandFromArguments requires non-empty command field" {
    const gpa = std.testing.allocator;
    const c = try commandFromArguments(gpa, "{\"command\":\"ls\"}");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("ls", c);

    try std.testing.expectError(error.InvalidArguments, commandFromArguments(gpa, "{}"));
    try std.testing.expectError(error.InvalidArguments, commandFromArguments(gpa, "{\"command\":\"\"}"));
    try std.testing.expectError(error.InvalidArguments, commandFromArguments(gpa, "{\"command\":1}"));
    try std.testing.expectError(error.InvalidArguments, commandFromArguments(gpa, "not-json"));
}