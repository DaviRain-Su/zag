//! Model catalog — **JSON for maintenance**, **comptime table for use**.
//!
//! Source of truth: `data/models/<provider>.json`
//! Generated:      `src/catalog_data.zig` (+ `data/catalog.json` for tooling)
//!
//!   python3 packages/zag-ai/scripts/generate_catalog.py
//!
//! `std.json` cannot allocate at Zig 0.16 comptime, so the generator freezes
//! the table into a pure Zig `[]const ModelInfo`. Runtime: zero parse, zero heap.
//!
//! JSON inspect / roundtrip uses [comptime-serde](https://github.com/jiacai2050/comptime-serde)
//! in `catalog_serde.zig` (type dispatch at comptime; parse still runtime).

const std = @import("std");
const data = @import("catalog_data.zig");

pub const CostRates = data.CostRates;
pub const ModelInfo = data.ModelInfo;

/// Compile-time model table (from JSON via generate_catalog.py).
pub const models: []const ModelInfo = data.models;

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

/// Unknown ids are still allowed at resolve/wire time — catalog is for budgets/cost/flags.
/// This helper answers only: is the id present in the compile-time table?
pub fn isKnownModel(provider: []const u8, id: []const u8) bool {
    return lookup(provider, id) != null;
}

/// Prefer (provider, id), then id-only.
pub fn lookup(provider: []const u8, id: []const u8) ?ModelInfo {
    if (find(provider, id)) |m| return m;
    return findById(id);
}

/// Soft char budget from catalog token window (~3 chars/token, 15% margin).
pub fn contextBudgetChars(info: ?ModelInfo, default_max_chars: usize) usize {
    const m = info orelse return default_max_chars;
    const chars_per_token: u64 = 3;
    const window: u64 = m.context_window;
    const reserve_out: u64 = @min(m.max_output_tokens, window / 4);
    const usable_tokens = if (window > reserve_out) window - reserve_out else window / 2;
    const raw = usable_tokens * chars_per_token;
    const budget = (raw * 85) / 100;
    if (budget == 0) return default_max_chars;
    if (budget > std.math.maxInt(usize)) return std.math.maxInt(usize);
    return @intCast(budget);
}

pub fn suggestedMaxOutputTokens(info: ?ModelInfo) ?u32 {
    const m = info orelse return null;
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

test "catalog cost rates for openai mini" {
    const m = find("openai", "gpt-4o-mini").?;
    try std.testing.expect(m.cost != null);
    try std.testing.expect(m.cost.?.input > 0);
    try std.testing.expect(m.cost.?.output > 0);
}

test "models table is comptime-known length" {
    // Touching models.len in a const context proves compile-time data.
    comptime {
        if (models.len < 30) @compileError("catalog too small");
    }
    try std.testing.expect(models.len >= 30);
}

test "isKnownModel is catalog membership only" {
    try std.testing.expect(isKnownModel("openai", "gpt-4o-mini"));
    try std.testing.expect(isKnownModel("unknown-provider", "gpt-4o")); // id fallback
    try std.testing.expect(!isKnownModel("custom", "totally-made-up-model-xyz"));
}
