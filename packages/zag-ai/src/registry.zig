//! Provider registry — resolve which endpoint + wire style to use from env.
//!
//! Inspired by pi-ai `Models` / `createProvider` + env key maps, without OAuth.

const std = @import("std");
const auth_env = @import("auth_env.zig");
const presets = @import("presets.zig");
const config_mod = @import("config.zig");
const wire = @import("wire.zig");
const factory = @import("factory.zig");

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
    config: config_mod.Config,
    /// Wire adapter family (from preset or env `ZAG_API_STYLE`).
    api_style: wire.ApiStyle = .openai_compat,

    pub fn presetName(self: Resolved) []const u8 {
        return self.spec_id;
    }

    /// Build a WireAdapter for this resolution (heap client; call `adapter.deinit()`).
    pub fn createWire(self: Resolved, gpa: std.mem.Allocator, io: std.Io) wire.Error!wire.WireAdapter {
        return factory.createWire(gpa, io, self.config, self.api_style);
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
/// Optional: `ZAG_API_STYLE=openai_compat|anthropic_messages`.
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
        return wire.ApiStyle.parse(s) orelse error.UnsupportedApiStyle;
    }
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
            var resolved = try resolvePreset(getter, pid, zag_model);
            if (zag_base) |b| resolved.config.base_url = b;
            return resolved;
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

fn keySourceForSpec(getter: anytype, spec: presets.ProviderSpec) Error!auth_env.KeySource {
    const zag_key = getter.get("ZAG_API_KEY");
    if (auth_env.resolveApiKeySource(getter, spec.env_keys)) |src| return src;
    if (zag_key) |k| {
        if (k.len > 0) return .{ .key = k, .source = "ZAG_API_KEY" };
    }
    if (spec.env_keys.len == 0) return .{ .key = "", .source = "keyless" };
    return error.MissingApiKey;
}

/// Resolve one builtin preset without applying `ZAG_PROVIDER` / `ZAG_MODEL` /
/// `ZAG_BASE_URL` process overrides. Used by TUI `/model` to switch hosts
/// in-session (each row carries its own spec + model).
pub fn resolvePreset(getter: anytype, spec_id: []const u8, model_override: ?[]const u8) Error!Resolved {
    const spec = presets.find(spec_id) orelse return error.UnknownProvider;
    const key_src = try keySourceForSpec(getter, spec);
    const style = try styleFromGetter(getter, spec.api_style);
    return .{
        .spec_id = spec.id,
        .display_name = spec.name,
        .api_key_source = key_src.source,
        .api_style = style,
        .config = .{
            .api_key = key_src.key,
            .base_url = spec.base_url,
            .model = model_override orelse spec.default_model,
            .api_style = style,
        },
    };
}

/// Presets whose env key is set (keyless local Ollama is omitted).
/// Order matches `presets.builtin` so the picker stays stable.
pub fn listConfigured(getter: anytype, out: *std.ArrayList(presets.ProviderSpec), gpa: std.mem.Allocator) !void {
    for (presets.builtin) |spec| {
        if (spec.env_keys.len == 0) continue;
        if (auth_env.resolveApiKeySource(getter, spec.env_keys) != null) {
            try out.append(gpa, spec);
        }
    }
}

/// TUI `/model` row key: `spec_id` + unit separator + `model_id`.
/// A bare model id (no separator) means "keep the current provider".
pub const picker_sep: u8 = 0x1f;

pub fn parsePickerKey(encoded: []const u8) struct { spec_id: []const u8, model_id: []const u8 } {
    if (std.mem.indexOfScalar(u8, encoded, picker_sep)) |i| {
        return .{ .spec_id = encoded[0..i], .model_id = encoded[i + 1 ..] };
    }
    return .{ .spec_id = "", .model_id = encoded };
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

test "api style anthropic from env" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ANTHROPIC_API_KEY", "sk-ant" },
        .{ "ZAG_PROVIDER", "anthropic" },
    } });
    try std.testing.expect(r.api_style == .anthropic_messages);
    try std.testing.expectEqualStrings("anthropic", r.spec_id);
}

test "unsupported api style garbage" {
    try std.testing.expectError(error.UnsupportedApiStyle, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk" },
        .{ "ZAG_API_STYLE", "not-a-style" },
    } }));
}

test "ollama local keyless via ZAG_PROVIDER" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "ollama" },
    } });
    try std.testing.expectEqualStrings("ollama", r.spec_id);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", r.config.base_url);
    try std.testing.expectEqualStrings("deepseek-v4-flash:0731", r.config.model);
    try std.testing.expectEqualStrings("keyless", r.api_key_source);
    try std.testing.expectEqual(@as(usize, 0), r.config.api_key.len);
    try std.testing.expect(r.api_style == .openai_compat);
}

test "ollama local ZAG_BASE_URL override" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "ollama" },
        .{ "ZAG_BASE_URL", "http://192.168.1.100:11434/v1" },
        .{ "ZAG_MODEL", "qwen2.5-coder:7b" },
    } });
    try std.testing.expectEqualStrings("http://192.168.1.100:11434/v1", r.config.base_url);
    try std.testing.expectEqualStrings("qwen2.5-coder:7b", r.config.model);
}

test "ollama cloud with API key" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "OLLAMA_API_KEY", "ollama-cloud-key" },
    } });
    try std.testing.expectEqualStrings("https://ollama.com/v1", r.config.base_url);
    try std.testing.expectEqualStrings("ollama-cloud-key", r.config.api_key);
}

test "ollama cloud via ZAG_PROVIDER" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "ollama-cloud" },
        .{ "OLLAMA_API_KEY", "my-key" },
    } });
    try std.testing.expectEqualStrings("ollama-cloud", r.spec_id);
    try std.testing.expectEqualStrings("my-key", r.config.api_key);
}

test "ollama cloud missing key fails" {
    try std.testing.expectError(error.MissingApiKey, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "ollama-cloud" },
    } }));
}

test "opencode-go via OPENCODE_API_KEY auto-detect" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "OPENCODE_API_KEY", "oc-key" },
    } });
    try std.testing.expectEqualStrings("opencode-go", r.spec_id);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/go/v1", r.config.base_url);
    try std.testing.expectEqualStrings("oc-key", r.config.api_key);
    try std.testing.expectEqualStrings("deepseek-v4-flash", r.config.model);
}

test "opencode-zen via ZAG_PROVIDER" {
    const r = try resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "opencode-zen" },
        .{ "OPENCODE_API_KEY", "oc-key" },
        .{ "ZAG_MODEL", "claude-sonnet-4-5" },
    } });
    try std.testing.expectEqualStrings("opencode-zen", r.spec_id);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", r.config.base_url);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", r.config.model);
}

test "opencode-go missing key fails" {
    try std.testing.expectError(error.MissingApiKey, resolveFromGet(TestEnv{ .pairs = &.{
        .{ "ZAG_PROVIDER", "opencode-go" },
    } }));
}

test "listConfigured returns every keyed preset" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(presets.ProviderSpec) = .empty;
    defer out.deinit(gpa);
    try listConfigured(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-d" },
        .{ "OLLAMA_API_KEY", "sk-o" },
        .{ "KIMI_API_KEY", "sk-k" },
        .{ "OPENCODE_API_KEY", "sk-oc" },
    } }, &out, gpa);
    try std.testing.expectEqual(@as(usize, 5), out.items.len);
    try std.testing.expectEqualStrings("deepseek", out.items[0].id);
    try std.testing.expectEqualStrings("opencode-go", out.items[1].id);
    try std.testing.expectEqualStrings("opencode-zen", out.items[2].id);
    try std.testing.expectEqualStrings("ollama-cloud", out.items[3].id);
    try std.testing.expectEqualStrings("kimi-coding", out.items[4].id);
}

test "resolvePreset switches host without ZAG_PROVIDER" {
    const r = try resolvePreset(TestEnv{ .pairs = &.{
        .{ "DEEPSEEK_API_KEY", "sk-d" },
        .{ "KIMI_API_KEY", "sk-k" },
        .{ "ZAG_PROVIDER", "deepseek" },
        .{ "ZAG_MODEL", "deepseek-v4-pro" },
    } }, "kimi-coding", "kimi-for-coding");
    try std.testing.expectEqualStrings("kimi-coding", r.spec_id);
    try std.testing.expectEqualStrings("kimi-for-coding", r.config.model);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding", r.config.base_url);
    try std.testing.expect(r.api_style == .anthropic_messages);
}

test "parsePickerKey splits spec and model" {
    const p = parsePickerKey("kimi-coding\x1fkimi-for-coding");
    try std.testing.expectEqualStrings("kimi-coding", p.spec_id);
    try std.testing.expectEqualStrings("kimi-for-coding", p.model_id);
    const bare = parsePickerKey("deepseek-v4-flash");
    try std.testing.expectEqualStrings("", bare.spec_id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", bare.model_id);
}
