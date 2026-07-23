//! Static model catalog (multi-vendor; ids + context windows + budgets).
//!
//! Inspired by pi-ai `*.models.ts` tables. Includes OpenAI-compat hosts and Anthropic.

const std = @import("std");
const presets = @import("presets.zig");

pub const ModelInfo = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    context_window: u32,
    max_output_tokens: u32,
};

/// Curated catalog (not exhaustive). Prefer these ids when setting ZAG_MODEL.
pub const models: []const ModelInfo = &.{
    // DeepSeek
    .{ .id = "deepseek-v4-flash", .name = "DeepSeek V4 Flash", .provider = "deepseek", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    .{ .id = "deepseek-v4-pro", .name = "DeepSeek V4 Pro", .provider = "deepseek", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    .{ .id = "deepseek-chat", .name = "DeepSeek Chat (legacy)", .provider = "deepseek", .context_window = 128_000, .max_output_tokens = 8_192 },
    // xAI
    .{ .id = "grok-4-latest", .name = "Grok 4 Latest", .provider = "xai", .context_window = 256_000, .max_output_tokens = 64_000 },
    .{ .id = "grok-3", .name = "Grok 3", .provider = "xai", .context_window = 131_072, .max_output_tokens = 16_384 },
    // OpenAI
    .{ .id = "gpt-4o", .name = "GPT-4o", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16_384 },
    .{ .id = "gpt-4o-mini", .name = "GPT-4o mini", .provider = "openai", .context_window = 128_000, .max_output_tokens = 16_384 },
    .{ .id = "o4-mini", .name = "o4-mini", .provider = "openai", .context_window = 200_000, .max_output_tokens = 100_000 },
    // Anthropic (Messages API)
    .{ .id = "claude-sonnet-4-20250514", .name = "Claude Sonnet 4", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 64_000 },
    .{ .id = "claude-opus-4-20250514", .name = "Claude Opus 4", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 32_000 },
    .{ .id = "claude-haiku-4-5-20251001", .name = "Claude Haiku 4.5", .provider = "anthropic", .context_window = 200_000, .max_output_tokens = 64_000 },
    // OpenRouter (examples)
    .{ .id = "openai/gpt-4o-mini", .name = "GPT-4o mini (OpenRouter)", .provider = "openrouter", .context_window = 128_000, .max_output_tokens = 16_384 },
    .{ .id = "deepseek/deepseek-v4-flash", .name = "DeepSeek V4 Flash (OpenRouter)", .provider = "openrouter", .context_window = 1_000_000, .max_output_tokens = 384_000 },
    // Together
    .{ .id = "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo", .name = "Llama 3.1 8B Turbo", .provider = "together", .context_window = 131_072, .max_output_tokens = 8_192 },
    .{ .id = "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo", .name = "Llama 3.1 70B Turbo", .provider = "together", .context_window = 131_072, .max_output_tokens = 8_192 },
    // Groq
    .{ .id = "llama-3.3-70b-versatile", .name = "Llama 3.3 70B", .provider = "groq", .context_window = 128_000, .max_output_tokens = 32_768 },
    .{ .id = "llama-3.1-8b-instant", .name = "Llama 3.1 8B Instant", .provider = "groq", .context_window = 128_000, .max_output_tokens = 8_192 },
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
