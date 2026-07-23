//! Built-in provider presets (table-driven).
//!
//! Adding a vendor: append one `ProviderSpec` — no change to resolve logic.
//! Wire family is `api_style` (today all builtins are `openai_compat`).

const std = @import("std");
const wire = @import("wire.zig");

/// Declarative provider identity + env auth + defaults (pi-style createProvider input).
pub const ProviderSpec = struct {
    id: []const u8,
    name: []const u8,
    base_url: []const u8,
    /// Env vars tried in order for the API key.
    env_keys: []const []const u8,
    default_model: []const u8,
    /// Which WireAdapter implementation to use after resolve.
    api_style: wire.ApiStyle = .openai_compat,
};

/// Detection order when no `ZAG_PROVIDER` is set: first matching env key wins.
pub const builtin: []const ProviderSpec = &.{
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .env_keys = &.{ "DEEPSEEK_API_KEY" },
        .default_model = "deepseek-v4-flash",
    },
    .{
        .id = "xai",
        .name = "xAI",
        .base_url = "https://api.x.ai/v1",
        .env_keys = &.{ "XAI_API_KEY" },
        .default_model = "grok-4-latest",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .env_keys = &.{ "OPENAI_API_KEY" },
        .default_model = "gpt-4o-mini",
    },
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com",
        .env_keys = &.{ "ANTHROPIC_API_KEY" },
        .default_model = "claude-sonnet-4-20250514",
        .api_style = .anthropic_messages,
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .env_keys = &.{ "OPENROUTER_API_KEY" },
        .default_model = "openai/gpt-4o-mini",
    },
    .{
        .id = "together",
        .name = "Together AI",
        .base_url = "https://api.together.xyz/v1",
        .env_keys = &.{ "TOGETHER_API_KEY" },
        .default_model = "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .env_keys = &.{ "GROQ_API_KEY" },
        .default_model = "llama-3.3-70b-versatile",
    },
};

pub fn find(id: []const u8) ?ProviderSpec {
    for (builtin) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

test "find deepseek preset" {
    const s = find("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", s.name);
    try std.testing.expect(s.env_keys.len == 1);
}

test "unknown preset" {
    try std.testing.expect(find("nope") == null);
}
