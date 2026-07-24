//! Static model catalog (multi-vendor; ids + context windows + budgets).
//!
//! Curated (not a full mirror of pi-ai generated tables). Prefer these ids when
//! setting `ZAG_MODEL`. Unknown ids still work — servers add models often.

const std = @import("std");
const presets = @import("presets.zig");

pub const ModelInfo = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    context_window: u32,
    max_output_tokens: u32,
    /// Model exposes thinking / reasoning modes (informational).
    reasoning: bool = false,
    /// Accepts image content parts (informational).
    vision: bool = false,
};

/// Curated catalog for coding-agent use. Not exhaustive.
pub const models: []const ModelInfo = &.{
    // ── DeepSeek ──────────────────────────────────────────────────────
    .{ .id = "deepseek-v4-flash", .name = "DeepSeek V4 Flash", .provider = "deepseek", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    .{ .id = "deepseek-v4-pro", .name = "DeepSeek V4 Pro", .provider = "deepseek", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    .{ .id = "deepseek-chat", .name = "DeepSeek Chat (legacy)", .provider = "deepseek", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── xAI ───────────────────────────────────────────────────────────
    .{ .id = "grok-4-latest", .name = "Grok 4 Latest", .provider = "xai", .context_window = 256_000, .max_output_tokens = 64_000, .reasoning = true },
    .{ .id = "grok-4.5", .name = "Grok 4.5", .provider = "xai", .context_window = 256_000, .max_output_tokens = 64_000, .reasoning = true },
    .{ .id = "grok-3", .name = "Grok 3", .provider = "xai", .context_window = 131_072, .max_output_tokens = 16_384 },
    // ── OpenAI ────────────────────────────────────────────────────────
    .{ .id = "gpt-4o", .name = "GPT-4o", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16_384, .vision = true },
    .{ .id = "gpt-4o-mini", .name = "GPT-4o mini", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16_384, .vision = true },
    .{ .id = "gpt-4.1", .name = "GPT-4.1", .provider = "openai", .context_window = 1_047_576, .max_output_tokens = 32_768, .vision = true },
    .{ .id = "gpt-4.1-mini", .name = "GPT-4.1 mini", .provider = "openai", .context_window = 1_047_576, .max_output_tokens = 32_768, .vision = true },
    .{ .id = "o4-mini", .name = "o4-mini", .provider = "openai", .context_window = 200_000, .max_output_tokens = 100_000, .reasoning = true },
    .{ .id = "o3", .name = "o3", .provider = "openai", .context_window = 200_000, .max_output_tokens = 100_000, .reasoning = true },
    // ── Anthropic ─────────────────────────────────────────────────────
    .{ .id = "claude-sonnet-4-20250514", .name = "Claude Sonnet 4", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true, .reasoning = true },
    .{ .id = "claude-opus-4-20250514", .name = "Claude Opus 4", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 32_000, .vision = true, .reasoning = true },
    .{ .id = "claude-haiku-4-5-20251001", .name = "Claude Haiku 4.5", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true },
    .{ .id = "claude-sonnet-4-5", .name = "Claude Sonnet 4.5", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true, .reasoning = true },
    // ── OpenRouter (examples) ─────────────────────────────────────────
    .{ .id = "openai/gpt-4o-mini", .name = "GPT-4o mini (OpenRouter)", .provider = "openrouter", .context_window = 128_000, .max_output_tokens = 16_384, .vision = true },
    .{ .id = "deepseek/deepseek-v4-flash", .name = "DeepSeek V4 Flash (OpenRouter)", .provider = "openrouter", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    .{ .id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4 (OpenRouter)", .provider = "openrouter", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true },
    // ── Together ──────────────────────────────────────────────────────
    .{ .id = "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo", .name = "Llama 3.1 8B Turbo", .provider = "together", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", .name = "Llama 3.1 70B Turbo", .provider = "together", .context_window = 131_072, .max_output_tokens = 8_192 },
    // ── Groq ──────────────────────────────────────────────────────────
    .{ .id = "llama-3.3-70b-versatile", .name = "Llama 3.3 70B", .provider = "groq", .context_window = 128_000, .max_output_tokens = 32_768 },
    .{ .id = "llama-3.1-8b-instant", .name = "Llama 3.1 8B Instant", .provider = "groq", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── Cerebras ──────────────────────────────────────────────────────
    .{ .id = "llama-3.3-70b", .name = "Llama 3.3 70B (Cerebras)", .provider = "cerebras", .context_window = 128_000, .max_output_tokens = 8_192 },
    .{ .id = "qwen-3-32b", .name = "Qwen 3 32B (Cerebras)", .provider = "cerebras", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── NVIDIA NIM ────────────────────────────────────────────────────
    .{ .id = "meta/llama-3.3-70b-instruct", .name = "Llama 3.3 70B (NVIDIA)", .provider = "nvidia", .context_window = 128_000, .max_output_tokens = 16_384 },
    .{ .id = "deepseek-ai/deepseek-v3.1", .name = "DeepSeek V3.1 (NVIDIA)", .provider = "nvidia", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── Fireworks ─────────────────────────────────────────────────────
    .{ .id = "accounts/fireworks/models/llama-v3p3-70b-instruct", .name = "Llama 3.3 70B (Fireworks)", .provider = "fireworks", .context_window = 128_000, .max_output_tokens = 16_384 },
    .{ .id = "accounts/fireworks/models/deepseek-v3p1", .name = "DeepSeek V3.1 (Fireworks)", .provider = "fireworks", .context_window = 128_000, .max_output_tokens = 16_384 },
    // ── Hugging Face ──────────────────────────────────────────────────
    .{ .id = "meta-llama/Meta-Llama-3.1-8B-Instruct", .name = "Llama 3.1 8B (HF)", .provider = "huggingface", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── Moonshot ──────────────────────────────────────────────────────
    .{ .id = "kimi-k2.5", .name = "Kimi K2.5", .provider = "moonshotai", .context_window = 256_000, .max_output_tokens = 16_384, .reasoning = true },
    .{ .id = "kimi-k2-thinking", .name = "Kimi K2 Thinking", .provider = "moonshotai", .context_window = 256_000, .max_output_tokens = 16_384, .reasoning = true },
    .{ .id = "kimi-k2.5", .name = "Kimi K2.5 (CN)", .provider = "moonshotai-cn", .context_window = 256_000, .max_output_tokens = 16_384, .reasoning = true },
    // ── Z.AI / GLM ────────────────────────────────────────────────────
    .{ .id = "glm-4.7", .name = "GLM-4.7", .provider = "zai", .context_window = 200_000, .max_output_tokens = 16_384 },
    .{ .id = "glm-4.7", .name = "GLM-4.7 (Coding CN)", .provider = "zai-coding-cn", .context_window = 200_000, .max_output_tokens = 16_384 },
    // ── Xiaomi ────────────────────────────────────────────────────────
    .{ .id = "mimo-v2-flash", .name = "MiMo V2 Flash", .provider = "xiaomi", .context_window = 128_000, .max_output_tokens = 8_192 },
    // ── Kimi For Coding (Anthropic wire) ──────────────────────────────
    .{ .id = "kimi-for-coding", .name = "Kimi For Coding", .provider = "kimi-coding", .context_window = 256_000, .max_output_tokens = 32_768, .reasoning = true },
    // ── MiniMax (Anthropic wire) ──────────────────────────────────────
    .{ .id = "MiniMax-M2.5", .name = "MiniMax M2.5", .provider = "minimax", .context_window = 200_000, .max_output_tokens = 16_384 },
    .{ .id = "MiniMax-M2.5", .name = "MiniMax M2.5 (CN)", .provider = "minimax-cn", .context_window = 200_000, .max_output_tokens = 16_384 },
    // ── Vercel AI Gateway (Anthropic wire) ────────────────────────────
    .{ .id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4 (Vercel)", .provider = "vercel-ai-gateway", .context_window = 200_000, .max_output_tokens = 64_000, .vision = true },
};

pub fn find(provider: []const u8, id: []const u8) ?ModelInfo {
    for (models) |m| {
        if (std.mem.eql(u8, m.provider, provider) and std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

pub fn findById(id: []const u8) ?ModelInfo {
    for (models) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

pub fn listForProvider(provider: []const u8, out: *std.ArrayList(ModelInfo), gpa: std.mem.Allocator) !void {
    for (models) |m| {
        if (std.mem.eql(u8, m.provider, provider)) try out.append(gpa, m);
    }
}

/// If model id is known, optionally tighten nothing — used for validation warnings.
pub fn isKnownModel(provider: []const u8, id: []const u8) bool {
    if (find(provider, id) != null) return true;
    // allow any model on custom / openrouter-style freeform ids
    if (std.mem.eql(u8, provider, "custom") or std.mem.eql(u8, provider, "openrouter")) return true;
    // still allow unknown ids (servers add models often)
    _ = presets.find(provider);
    return true;
}

/// Look up model: prefer (provider, id), then id-only.
pub fn lookup(provider: []const u8, id: []const u8) ?ModelInfo {
    if (find(provider, id)) |m| return m;
    return findById(id);
}

/// Soft char budget for context view from catalog token window.
///
/// Rough rule: ~3 chars/token, reserve output headroom and 15% safety margin.
/// Falls back to `default_max_chars` when model is unknown.
pub fn contextBudgetChars(info: ?ModelInfo, default_max_chars: usize) usize {
    const m = info orelse return default_max_chars;
    const chars_per_token: u64 = 3;
    const window: u64 = m.context_window;
    const reserve_out: u64 = @min(m.max_output_tokens, window / 4);
    const usable_tokens = if (window > reserve_out) window - reserve_out else window / 2;
    const raw = usable_tokens * chars_per_token;
    // 85% safety margin
    const budget = (raw * 85) / 100;
    if (budget == 0) return default_max_chars;
    if (budget > std.math.maxInt(usize)) return std.math.maxInt(usize);
    return @intCast(budget);
}

/// Suggested max_completion_tokens / max_tokens cap from catalog (clamped).
pub fn suggestedMaxOutputTokens(info: ?ModelInfo) ?u32 {
    const m = info orelse return null;
    // Keep agent turns bounded even when catalog allows huge outputs.
    const cap: u32 = 16_384;
    return @min(m.max_output_tokens, cap);
}

pub fn count() usize {
    return models.len;
}

test "catalog has deepseek flash" {
    const m = find("deepseek", "deepseek-v4-flash").?;
    try std.testing.expect(m.context_window >= 128_000);
}

test "list deepseek models" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(ModelInfo) = .empty;
    defer list.deinit(gpa);
    try listForProvider("deepseek", &list, gpa);
    try std.testing.expect(list.items.len >= 2);
}

test "context budget from catalog" {
    const m = find("openai", "gpt-4o-mini").?;
    const budget = contextBudgetChars(m, 120_000);
    try std.testing.expect(budget > 10_000);
    try std.testing.expect(budget < m.context_window * 4);
    try std.testing.expectEqual(@as(usize, 120_000), contextBudgetChars(null, 120_000));
}

test "lookup falls back to id" {
    const m = lookup("unknown-provider", "gpt-4o").?;
    try std.testing.expectEqualStrings("openai", m.provider);
}

test "vision and reasoning flags" {
    const o = find("openai", "gpt-4o-mini").?;
    try std.testing.expect(o.vision);
    const r = find("openai", "o4-mini").?;
    try std.testing.expect(r.reasoning);
}

test "catalog covers new presets" {
    try std.testing.expect(find("cerebras", "llama-3.3-70b") != null);
    try std.testing.expect(find("kimi-coding", "kimi-for-coding") != null);
    try std.testing.expect(find("minimax", "MiniMax-M2.5") != null);
    try std.testing.expect(count() >= 30);
}
