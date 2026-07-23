//! File-based config for zag-ai (JSON). Env vars still override secrets.
//!
//! Search order (first found wins):
//! 1. explicit path / `ZAG_CONFIG`
//! 2. `.zag/config.json`
//! 3. `zag.json`

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

pub const FileConfig = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    stream: bool = false,
    api_key_env: ?[]const u8 = null,

    // Transport / client
    max_retries: ?u8 = null,
    retry_base_delay_ms: ?u64 = null,
    timeout_ms: ?u64 = null,

    // Per-request chat knobs
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    parallel_tool_calls: ?bool = null,
    user: ?[]const u8 = null,
    seed: ?u64 = null,

    // Harness-facing (resolved by zag-ai.resolve, consumed by main/agent)
    max_turns: ?u32 = null,
    /// Loop-level retries on retryable chat errors (after transport retries).
    chat_retries: ?u8 = null,
    context_max_chars: ?usize = null,
    context_max_tail_messages: ?usize = null,

    /// When true, caller must free string fields with `gpa`.
    owns_strings: bool = false,

    pub fn deinit(self: *FileConfig, gpa: std.mem.Allocator) void {
        if (!self.owns_strings) return;
        if (self.provider) |p| gpa.free(p);
        if (self.model) |m| gpa.free(m);
        if (self.base_url) |b| gpa.free(b);
        if (self.api_key_env) |a| gpa.free(a);
        if (self.user) |u| gpa.free(u);
        self.* = .{};
    }

    /// Build ChatOptions from file fields (string refs borrowed from FileConfig).
    pub fn chatOptions(self: FileConfig) types.ChatOptions {
        return .{
            .temperature = self.temperature,
            .top_p = self.top_p,
            .max_tokens = self.max_tokens,
            .max_completion_tokens = self.max_completion_tokens,
            .parallel_tool_calls = self.parallel_tool_calls,
            .user = self.user,
            .seed = self.seed,
        };
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
    if (o.get("user")) |v| {
        if (v == .string) cfg.user = try gpa.dupe(u8, v.string);
    }

    cfg.max_retries = try optionalU8(o, "max_retries");
    cfg.retry_base_delay_ms = try optionalU64(o, "retry_base_delay_ms");
    cfg.timeout_ms = try optionalU64(o, "timeout_ms");
    cfg.temperature = try optionalF64(o, "temperature");
    cfg.top_p = try optionalF64(o, "top_p");
    cfg.max_tokens = try optionalU32(o, "max_tokens");
    cfg.max_completion_tokens = try optionalU32(o, "max_completion_tokens");
    cfg.seed = try optionalU64(o, "seed");
    cfg.max_turns = try optionalU32(o, "max_turns");
    cfg.chat_retries = try optionalU8(o, "chat_retries");
    cfg.context_max_chars = try optionalUsize(o, "context_max_chars");
    cfg.context_max_tail_messages = try optionalUsize(o, "context_max_tail_messages");

    if (o.get("parallel_tool_calls")) |v| {
        if (v == .bool) cfg.parallel_tool_calls = v.bool;
    }

    return cfg;
}

fn optionalF64(o: std.json.ObjectMap, key: []const u8) Error!?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => error.InvalidConfig,
    };
}

fn optionalU8(o: std.json.ObjectMap, key: []const u8) Error!?u8 {
    const n = try optionalU64(o, key) orelse return null;
    if (n > std.math.maxInt(u8)) return error.InvalidConfig;
    return @intCast(n);
}

fn optionalU32(o: std.json.ObjectMap, key: []const u8) Error!?u32 {
    const n = try optionalU64(o, key) orelse return null;
    if (n > std.math.maxInt(u32)) return error.InvalidConfig;
    return @intCast(n);
}

fn optionalUsize(o: std.json.ObjectMap, key: []const u8) Error!?usize {
    const n = try optionalU64(o, key) orelse return null;
    if (n > std.math.maxInt(usize)) return error.InvalidConfig;
    return @intCast(n);
}

fn optionalU64(o: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| blk: {
            if (i < 0) return error.InvalidConfig;
            break :blk @intCast(i);
        },
        .float => |f| blk: {
            if (f < 0 or f > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidConfig;
            break :blk @intFromFloat(f);
        },
        else => error.InvalidConfig,
    };
}

fn fileExists(io: Io, cwd: Io.Dir, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

test "parse config json basic" {
    const gpa = std.testing.allocator;
    var cfg = try parseOwned(gpa,
        \\{"provider":"deepseek","model":"deepseek-v4-pro","stream":true}
    );
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("deepseek", cfg.provider.?);
    try std.testing.expectEqualStrings("deepseek-v4-pro", cfg.model.?);
    try std.testing.expect(cfg.stream);
}

test "parse config chat and transport options" {
    const gpa = std.testing.allocator;
    var cfg = try parseOwned(gpa,
        \\{
        \\  "provider": "openai",
        \\  "temperature": 0.2,
        \\  "max_tokens": 2048,
        \\  "max_retries": 3,
        \\  "timeout_ms": 60000,
        \\  "chat_retries": 2,
        \\  "context_max_chars": 80000,
        \\  "parallel_tool_calls": false,
        \\  "user": "zag-dev"
        \\}
    );
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 0.2), cfg.temperature.?);
    try std.testing.expectEqual(@as(u32, 2048), cfg.max_tokens.?);
    try std.testing.expectEqual(@as(u8, 3), cfg.max_retries.?);
    try std.testing.expectEqual(@as(u64, 60000), cfg.timeout_ms.?);
    try std.testing.expectEqual(@as(u8, 2), cfg.chat_retries.?);
    try std.testing.expectEqual(@as(usize, 80000), cfg.context_max_chars.?);
    try std.testing.expectEqual(false, cfg.parallel_tool_calls.?);
    try std.testing.expectEqualStrings("zag-dev", cfg.user.?);
    const opts = cfg.chatOptions();
    try std.testing.expectEqual(@as(f64, 0.2), opts.temperature.?);
    try std.testing.expectEqualStrings("zag-dev", opts.user.?);
}
