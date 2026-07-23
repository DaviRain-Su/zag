//! Environment-variable API key resolution (no OAuth / interactive login).
//!
//! Mirrors pi-ai `envApiKeyAuth` resolve path only: first non-empty env wins.

const std = @import("std");

pub const KeySource = struct {
    key: []const u8,
    source: []const u8,
};

/// Return the first non-empty value among `env_keys`, or null.
pub fn resolveApiKey(getter: anytype, env_keys: []const []const u8) ?[]const u8 {
    if (resolveApiKeySource(getter, env_keys)) |s| return s.key;
    return null;
}

/// Which env var supplied the key (for logging / trace).
pub fn resolveApiKeySource(getter: anytype, env_keys: []const []const u8) ?KeySource {
    for (env_keys) |name| {
        if (getter.get(name)) |val| {
            if (val.len > 0) return .{ .key = val, .source = name };
        }
    }
    return null;
}

test "resolveApiKey order" {
    const Env = struct {
        pub fn get(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "A")) return null;
            if (std.mem.eql(u8, k, "B")) return "from-b";
            return null;
        }
    };
    const env = Env{};
    const k = resolveApiKey(env, &.{ "A", "B", "C" });
    try std.testing.expectEqualStrings("from-b", k.?);
    const src = resolveApiKeySource(env, &.{ "A", "B" });
    try std.testing.expectEqualStrings("B", src.?.source);
}
