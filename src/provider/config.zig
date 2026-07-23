//! Resolve provider config from environment.
//!
//! Wire format is always OpenAI-compatible chat completions. Host/model/key
//! come from env so the same binary can target xAI, DeepSeek, OpenAI, etc.
//!
//! Explicit `ZAG_*` always wins when set. Otherwise the first present vendor
//! key picks a preset:
//!
//! 1. `ZAG_API_KEY` (+ optional `ZAG_BASE_URL` / `ZAG_MODEL`)
//! 2. `DEEPSEEK_API_KEY` → DeepSeek
//! 3. `XAI_API_KEY` → xAI
//! 4. `OPENAI_API_KEY` → OpenAI

const std = @import("std");
const openai = @import("openai.zig");

pub const Error = error{MissingApiKey};

pub const Preset = enum {
    zag_explicit,
    deepseek,
    xai,
    openai,

    pub fn name(self: Preset) []const u8 {
        return switch (self) {
            .zag_explicit => "zag",
            .deepseek => "deepseek",
            .xai => "xai",
            .openai => "openai",
        };
    }
};

pub const Resolved = struct {
    config: openai.Config,
    preset: Preset,
};

const deepseek_base = "https://api.deepseek.com/v1";
const deepseek_model = "deepseek-chat";
const xai_base = "https://api.x.ai/v1";
const xai_model = "grok-4-latest";
const openai_base = "https://api.openai.com/v1";
const openai_model = "gpt-4o-mini";

/// Read provider settings from a process environ map (Juicy Main).
pub fn resolve(env: *const std.process.Environ.Map) Error!Resolved {
    return resolveFromGet(struct {
        env: *const std.process.Environ.Map,
        fn get(self: @This(), key: []const u8) ?[]const u8 {
            return self.env.get(key);
        }
    }{ .env = env });
}

/// Testable core: any bag that can look up env-style keys.
pub fn resolveFromGet(getter: anytype) Error!Resolved {
    const zag_key = getter.get("ZAG_API_KEY");
    const deepseek_key = getter.get("DEEPSEEK_API_KEY");
    const xai_key = getter.get("XAI_API_KEY");
    const openai_key = getter.get("OPENAI_API_KEY");

    const zag_base = getter.get("ZAG_BASE_URL");
    const zag_model = getter.get("ZAG_MODEL");

    // Explicit ZAG_API_KEY: full control; base/model fall back to xAI defaults
    // unless ZAG_BASE_URL / ZAG_MODEL override (or a lone DeepSeek-style base is set).
    if (zag_key) |key| {
        return .{
            .preset = .zag_explicit,
            .config = .{
                .api_key = key,
                .base_url = zag_base orelse xai_base,
                .model = zag_model orelse xai_model,
            },
        };
    }

    if (deepseek_key) |key| {
        return .{
            .preset = .deepseek,
            .config = .{
                .api_key = key,
                .base_url = zag_base orelse deepseek_base,
                .model = zag_model orelse deepseek_model,
            },
        };
    }

    if (xai_key) |key| {
        return .{
            .preset = .xai,
            .config = .{
                .api_key = key,
                .base_url = zag_base orelse xai_base,
                .model = zag_model orelse xai_model,
            },
        };
    }

    if (openai_key) |key| {
        return .{
            .preset = .openai,
            .config = .{
                .api_key = key,
                .base_url = zag_base orelse openai_base,
                .model = zag_model orelse openai_model,
            },
        };
    }

    return error.MissingApiKey;
}

// --- tests ---

const TestEnv = struct {
    pairs: []const struct { []const u8, []const u8 },

    fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], key)) return p[1];
        }
        return null;
    }
};

test "resolve DeepSeek preset" {
    const env = TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
    } };
    const r = try resolveFromGet(env);
    try std.testing.expect(r.preset == .deepseek);
    try std.testing.expectEqualStrings("sk-deep", r.config.api_key);
    try std.testing.expectEqualStrings(deepseek_base, r.config.base_url);
    try std.testing.expectEqualStrings(deepseek_model, r.config.model);
}

test "resolve DeepSeek with model override" {
    const env = TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
        .{ "ZAG_MODEL", "deepseek-reasoner" },
    } };
    const r = try resolveFromGet(env);
    try std.testing.expect(r.preset == .deepseek);
    try std.testing.expectEqualStrings("deepseek-reasoner", r.config.model);
    try std.testing.expectEqualStrings(deepseek_base, r.config.base_url);
}

test "ZAG_API_KEY beats DEEPSEEK_API_KEY" {
    const env = TestEnv{ .pairs = &.{
        .{ "ZAG_API_KEY", "sk-zag" },
        .{ "DEEPSEEK_API_KEY", "sk-deep" },
        .{ "ZAG_BASE_URL", "https://example.com/v1" },
        .{ "ZAG_MODEL", "custom-model" },
    } };
    const r = try resolveFromGet(env);
    try std.testing.expect(r.preset == .zag_explicit);
    try std.testing.expectEqualStrings("sk-zag", r.config.api_key);
    try std.testing.expectEqualStrings("https://example.com/v1", r.config.base_url);
    try std.testing.expectEqualStrings("custom-model", r.config.model);
}

test "missing key errors" {
    const env = TestEnv{ .pairs = &.{} };
    try std.testing.expectError(error.MissingApiKey, resolveFromGet(env));
}
