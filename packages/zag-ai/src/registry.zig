//! Provider registry — resolve which endpoint + wire style to use from env.
//!
//! Inspired by pi-ai `Models` / `createProvider` + env key maps, without OAuth.

const std = @import("std");
const auth_env = @import("auth_env.zig");
const presets = @import("presets.zig");
const openai_compat = @import("openai_compat.zig");
const wire = @import("wire.zig");

pub const Error = error{
    MissingApiKey,
    UnknownProvider,
    MissingBaseUrl,
    UnsupportedApiStyle,
};

pub const Resolved = struct {
    /// Preset id, or "custom" when using ZAG_API_KEY without a known preset.
    spec_id: []const u8,
    display_name: []const u8,
    /// Env var that supplied the key (for logs).
    api_key_source: []const u8,
    config: openai_compat.Config,
    /// Wire adapter family (from preset or env `ZAG_API_STYLE`).
    api_style: wire.ApiStyle = .openai_compat,

    pub fn presetName(self: Resolved) []const u8 {
        return self.spec_id;
    }

    /// Build a WireAdapter for this resolution (heap client; call `adapter.deinit()`).
    pub fn createWire(self: Resolved, gpa: std.mem.Allocator, io: std.Io) openai_compat.Error!wire.WireAdapter {
        return openai_compat.createWire(gpa, io, self.config, self.api_style);
    }
};

/// Resolve endpoint from environment.
///
/// Order:
/// 1. `ZAG_PROVIDER=<id>` → that preset (key from its env_keys or ZAG_API_KEY)
/// 2. `ZAG_API_KEY` → custom (needs `ZAG_BASE_URL`; model from ZAG_MODEL or fallback)
/// 3. First builtin preset whose env key is set (table order in presets.zig)
///
/// Overrides: `ZAG_BASE_URL`, `ZAG_MODEL` always win when set.
/// Optional: `ZAG_API_STYLE=openai_compat|anthropic` (anthropic not implemented).
pub fn resolveFromEnv(env: *const std.process.Environ.Map) Error!Resolved {
    return resolveFromGet(struct {
        env: *const std.process.Environ.Map,
        pub fn get(self: @This(), key: []const u8) ?[]const u8 {
            return self.env.get(key);
        }
    }{ .env = env });
}

fn styleFromGetter(getter: anytype, preset_style: wire.ApiStyle) Error!wire.ApiStyle {
    if (getter.get("ZAG_API_STYLE")) |s| {
        const parsed = wire.ApiStyle.parse(s) orelse return error.UnsupportedApiStyle;
        if (parsed == .anthropic_messages) return error.UnsupportedApiStyle;
        return parsed;
    }
    if (preset_style == .anthropic_messages) return error.UnsupportedApiStyle;
    return preset_style;
}

pub fn resolveFromGet(getter: anytype) Error!Resolved {
    const zag_key = getter.get("ZAG_API_KEY");
    const zag_base = getter.get("ZAG_BASE_URL");
    const zag_model = getter.get("ZAG_MODEL");
    const zag_provider = getter.get("ZAG_PROVIDER");

    // Explicit provider id
    if (zag_provider) |pid| {
        if (pid.len > 0) {
            const spec = presets.find(pid) orelse return error.UnknownProvider;
            const key_src: auth_env.KeySource = auth_env.resolveApiKeySource(getter, spec.env_keys) orelse
                if (zag_key) |k|
                    if (k.len > 0)
                        auth_env.KeySource{ .key = k, .source = "ZAG_API_KEY" }
                    else
                        return error.MissingApiKey
                else
                    return error.MissingApiKey;
            const style = try styleFromGetter(getter, spec.api_style);
            return .{
                .spec_id = spec.id,
                .display_name = spec.name,
                .api_key_source = key_src.source,
                .api_style = style,
                .config = .{
                    .api_key = key_src.key,
                    .base_url = zag_base orelse spec.base_url,
                    .model = zag_model orelse spec.default_model,
                    .api_style = style,
                },
            };
        }
    }

    // Custom endpoint via ZAG_API_KEY
    if (zag_key) |k| {
        if (k.len > 0) {
            const base = zag_base orelse return error.MissingBaseUrl;
            const style = try styleFromGetter(getter, .openai_compat);
            return .{
                .spec_id = "custom",
                .display_name = "custom",
                .api_key_source = "ZAG_API_KEY",
                .api_style = style,
                .config = .{
                    .api_key = k,
                    .base_url = base,
                    .model = zag_model orelse "gpt-4o-mini",
                    .api_style = style,
                },
            };
        }
    }

    // Auto-detect first preset with a configured env key
    for (presets.builtin) |spec| {
        if (auth_env.resolveApiKeySource(getter, spec.env_keys)) |key_src| {
            const style = try styleFromGetter(getter, spec.api_style);
            return .{
                .spec_id = spec.id,
                .display_name = spec.name,
                .api_key_source = key_src.source,
                .api_style = style,
                .config = .{
                    .api_key = key_src.key,
                    .base_url = zag_base orelse spec.base_url,
                    .model = zag_model orelse spec.default_model,
                    .api_style = style,
                },
            };
        }
    }

    return error.MissingApiKey;
}

// --- tests ---

const TestEnv = struct {
    pairs: []const struct { []const u8, []const u8 },
    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], key)) return p[1];
        }
        return null;
    }
};

test "auto-detect deepseek" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
    } });
    try std.testing.expectEqualStrings("deepseek", r.spec_id);
    try std.testing.expectEqualStrings("sk-deep", r.config.api_key);
    try std.testing.expectEqualStrings("https://api.deepseek.com/v1", r.config.base_url);
    try std.testing.expectEqualStrings("deepseek-v4-flash", r.config.model);
    try std.testing.expect(r.api_style == .openai_compat);
}

test "ZAG_MODEL overrides preset default" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
        .{ "ZAG_MODEL", "deepseek-v4-pro" },
    } });
    try std.testing.expectEqualStrings("deepseek-v4-pro", r.config.model);
}

test "ZAG_PROVIDER selects openai even if deepseek key present" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
        .{ "OPENAI_API_KEY", "sk-oai" },
        .{ "ZAG_PROVIDER", "openai" },
    } });
    try std.testing.expectEqualStrings("openai", r.spec_id);
    try std.testing.expectEqualStrings("sk-oai", r.config.api_key);
}

test "custom ZAG_API_KEY requires base url" {
    try std.testing.expectError(error.MissingBaseUrl, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_API_KEY", "sk-custom" },
    } }));
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_API_KEY", "sk-custom" },
        .{ "ZAG_BASE_URL", "https://example.com/v1" },
        .{ "ZAG_MODEL", "my-model" },
    } });
    try std.testing.expectEqualStrings("custom", r.spec_id);
    try std.testing.expectEqualStrings("my-model", r.config.model);
}

test "unknown ZAG_PROVIDER" {
    try std.testing.expectError(error.UnknownProvider, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "nope" },
        .{ "ZAG_API_KEY", "x" },
    } }));
}

test "missing key" {
    try std.testing.expectError(error.MissingApiKey, resolveFromGet(TestEnv{ .pairs = &.{} }));
}

test "unsupported api style anthropic" {
    try std.testing.expectError(error.UnsupportedApiStyle, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk" },
        .{ "ZAG_API_STYLE", "anthropic" },
    } }));
}
