//! Built-in provider presets (table-driven).
//!
//! Adding a vendor that speaks an existing wire: append one `ProviderSpec`.
//! New wire protocols need a new `ApiStyle` + adapter module — do not branch
//! in Agent Core.
//!
//! Scope (intentional): only `openai_compat` and `anthropic_messages`.
//! Deferred: Google / Mistral-native / Bedrock / OAuth / Responses / images.

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
/// Put common coding providers first; regional twins last (same env key → global wins).
pub const builtin: []const ProviderSpec = &.{
    // ── Core (openai_compat) ──────────────────────────────────────────
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .env_keys = &.{"DEEPSEEK_API_KEY"},
        .default_model = "deepseek-v4-flash",
    },
    .{
        .id = "xai",
        .name = "xAI",
        .base_url = "https://api.x.ai/v1",
        .env_keys = &.{"XAI_API_KEY"},
        .default_model = "grok-4-latest",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .env_keys = &.{"OPENAI_API_KEY"},
        .default_model = "gpt-4o-mini",
    },
    // ── Core (anthropic_messages) ─────────────────────────────────────
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com",
        .env_keys = &.{"ANTHROPIC_API_KEY"},
        .default_model = "claude-sonnet-4-20250514",
        .api_style = .anthropic_messages,
    },
    // ── Gateways / multi-model hosts (openai_compat) ──────────────────
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .env_keys = &.{"OPENROUTER_API_KEY"},
        .default_model = "openai/gpt-4o-mini",
    },
    .{
        .id = "together",
        .name = "Together AI",
        .base_url = "https://api.together.xyz/v1",
        .env_keys = &.{"TOGETHER_API_KEY"},
        .default_model = "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .env_keys = &.{"GROQ_API_KEY"},
        .default_model = "llama-3.3-70b-versatile",
    },
    .{
        .id = "cerebras",
        .name = "Cerebras",
        .base_url = "https://api.cerebras.ai/v1",
        .env_keys = &.{"CEREBRAS_API_KEY"},
        .default_model = "llama-3.3-70b",
    },
    .{
        .id = "nvidia",
        .name = "NVIDIA NIM",
        .base_url = "https://integrate.api.nvidia.com/v1",
        .env_keys = &.{"NVIDIA_API_KEY"},
        .default_model = "meta/llama-3.3-70b-instruct",
    },
    .{
        .id = "fireworks",
        .name = "Fireworks",
        .base_url = "https://api.fireworks.ai/inference/v1",
        .env_keys = &.{"FIREWORKS_API_KEY"},
        .default_model = "accounts/fireworks/models/llama-v3p3-70b-instruct",
    },
    .{
        .id = "huggingface",
        .name = "Hugging Face",
        .base_url = "https://router.huggingface.co/v1",
        .env_keys = &.{"HF_TOKEN"},
        .default_model = "meta-llama/Meta-Llama-3.1-8B-Instruct",
    },
    // ── Regional coding hosts (openai_compat) ─────────────────────────
    .{
        .id = "moonshotai",
        .name = "Moonshot AI",
        .base_url = "https://api.moonshot.ai/v1",
        .env_keys = &.{"MOONSHOT_API_KEY"},
        .default_model = "kimi-k2.5",
    },
    .{
        .id = "moonshotai-cn",
        .name = "Moonshot AI CN",
        .base_url = "https://api.moonshot.cn/v1",
        .env_keys = &.{"MOONSHOT_API_KEY"},
        .default_model = "kimi-k2.5",
    },
    .{
        .id = "zai",
        .name = "Z.AI",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .env_keys = &.{"ZAI_API_KEY"},
        .default_model = "glm-4.7",
    },
    .{
        .id = "zai-coding-cn",
        .name = "Z.AI Coding CN",
        .base_url = "https://open.bigmodel.cn/api/coding/paas/v4",
        .env_keys = &.{"ZAI_CODING_CN_API_KEY"},
        .default_model = "glm-4.7",
    },
    .{
        .id = "xiaomi",
        .name = "Xiaomi MiMo",
        .base_url = "https://api.xiaomimimo.com/v1",
        .env_keys = &.{"XIAOMI_API_KEY"},
        .default_model = "mimo-v2-flash",
    },
    // ── Anthropic-compatible hosts ────────────────────────────────────
    .{
        .id = "kimi-coding",
        .name = "Kimi For Coding",
        .base_url = "https://api.kimi.com/coding",
        .env_keys = &.{"KIMI_API_KEY"},
        .default_model = "kimi-for-coding",
        .api_style = .anthropic_messages,
    },
    .{
        .id = "minimax",
        .name = "MiniMax",
        .base_url = "https://api.minimax.io/anthropic",
        .env_keys = &.{"MINIMAX_API_KEY"},
        .default_model = "MiniMax-M2.5",
        .api_style = .anthropic_messages,
    },
    .{
        .id = "minimax-cn",
        .name = "MiniMax CN",
        .base_url = "https://api.minimaxi.com/anthropic",
        .env_keys = &.{"MINIMAX_CN_API_KEY"},
        .default_model = "MiniMax-M2.5",
        .api_style = .anthropic_messages,
    },
    .{
        .id = "vercel-ai-gateway",
        .name = "Vercel AI Gateway",
        .base_url = "https://ai-gateway.vercel.sh",
        .env_keys = &.{"AI_GATEWAY_API_KEY"},
        .default_model = "anthropic/claude-sonnet-4",
        .api_style = .anthropic_messages,
    },
};

pub fn find(id: []const u8) ?ProviderSpec {
    for (builtin) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// Number of built-in providers (for tests / docs).
pub fn count() usize {
    return builtin.len;
}

test "find deepseek preset" {
    const s = find("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", s.name);
    try std.testing.expect(s.env_keys.len == 1);
}

test "unknown preset" {
    try std.testing.expect(find("nope") == null);
}

test "anthropic style on anthropic-family presets" {
    try std.testing.expect(find("anthropic").?.api_style == .anthropic_messages);
    try std.testing.expect(find("kimi-coding").?.api_style == .anthropic_messages);
    try std.testing.expect(find("minimax").?.api_style == .anthropic_messages);
    try std.testing.expect(find("openai").?.api_style == .openai_compat);
    try std.testing.expect(find("cerebras").?.api_style == .openai_compat);
}

test "builtin count is stable enough" {
    try std.testing.expect(count() >= 15);
}
