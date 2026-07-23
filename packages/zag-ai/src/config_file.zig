//! File-based config for zag-ai (JSON). Env vars still override secrets.
//!
//! Search order (first found wins):
//! 1. explicit path / `ZAG_CONFIG`
//! 2. `.zag/config.json`
//! 3. `zag.json`

const std = @import("std");
const Io = std.Io;

pub const FileConfig = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    stream: bool = false,
    api_key_env: ?[]const u8 = null,
    /// When true, caller must free string fields with `gpa`.
    owns_strings: bool = false,

    pub fn deinit(self: *FileConfig, gpa: std.mem.Allocator) void {
        if (!self.owns_strings) return;
        if (self.provider) |p| gpa.free(p);
        if (self.model) |m| gpa.free(m);
        if (self.base_url) |b| gpa.free(b);
        if (self.api_key_env) |a| gpa.free(a);
        self.* = .{};
    }
};

pub const Error = error{
    OutOfMemory,
    IoFailed,
    InvalidConfig,
};

pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    explicit_path: ?[]const u8,
) Error!?FileConfig {
    const path = explicit_path orelse blk: {
        if (fileExists(io, cwd, ".zag/config.json")) break :blk ".zag/config.json";
        if (fileExists(io, cwd, "zag.json")) break :blk "zag.json";
        return null;
    };

    const raw = cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(raw);

    return try parseOwned(gpa, raw);
}

pub fn parseOwned(gpa: std.mem.Allocator, raw: []const u8) Error!FileConfig {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch
        return error.InvalidConfig;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfig;
    const o = parsed.value.object;

    var cfg: FileConfig = .{ .owns_strings = true };
    errdefer cfg.deinit(gpa);

    if (o.get("provider")) |v| {
        if (v == .string) cfg.provider = try gpa.dupe(u8, v.string);
    }
    if (o.get("model")) |v| {
        if (v == .string) cfg.model = try gpa.dupe(u8, v.string);
    }
    if (o.get("base_url")) |v| {
        if (v == .string) cfg.base_url = try gpa.dupe(u8, v.string);
    }
    if (o.get("api_key_env")) |v| {
        if (v == .string) cfg.api_key_env = try gpa.dupe(u8, v.string);
    }
    if (o.get("stream")) |v| {
        if (v == .bool) cfg.stream = v.bool;
    }
    return cfg;
}

fn fileExists(io: Io, cwd: Io.Dir, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

test "parse config json" {
    const gpa = std.testing.allocator;
    var cfg = try parseOwned(gpa,
        \\{"provider":"deepseek","model":"deepseek-v4-pro","stream":true}
    );
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("deepseek", cfg.provider.?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", cfg.model.?);
    try std.testing.expect(cfg.stream);
}
