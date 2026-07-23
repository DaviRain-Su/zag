//! Static model catalog (OpenAI-compatible providers only).
//!
//! Inspired by pi-ai `*.models.ts` tables — ids, context windows, defaults.

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
