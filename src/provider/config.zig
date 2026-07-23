//! Back-compat facade over `registry.resolveFromEnv`.
//!
//! Prefer importing `provider/registry.zig` in new code.

const std = @import("std");
const registry = @import("registry.zig");
const openai_compat = @import("openai_compat.zig");

pub const Error = registry.Error;

/// Historical name — maps to registry.spec_id.
pub const Preset = struct {
    id: []const u8,

    pub fn name(self: Preset) []const u8 {
        return self.id;
    }
};

pub const Resolved = struct {
    config: openai_compat.Config,
    preset: Preset,
    /// Env var that provided the API key.
    api_key_source: []const u8 = "",
    display_name: []const u8 = "",
};

pub fn resolve(env: *const std.process.Environ.Map) Error!Resolved {
    const r = try registry.resolveFromEnv(env);
    return fromRegistry(r);
}

pub fn resolveFromGet(getter: anytype) Error!Resolved {
    const r = try registry.resolveFromGet(getter);
    return fromRegistry(r);
}

fn fromRegistry(r: registry.Resolved) Resolved {
    return .{
        .config = r.config,
        .preset = .{ .id = r.spec_id },
        .api_key_source = r.api_key_source,
        .display_name = r.display_name,
    };
}

test "config facade deepseek" {
    const Env = struct {
        pub fn get(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "DEEPSEEK_API_KEY")) return "sk";
            return null;
        }
    };
    const r = try resolveFromGet(Env{});
    try std.testing.expectEqualStrings("deepseek", r.preset.name());
}
