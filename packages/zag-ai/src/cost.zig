//! Token → USD cost estimates from catalog rates + Usage.
//!
//! Rates are USD per 1M tokens (`catalog.CostRates`). When rates are missing
//! or zero, estimates return 0 (unknown), not an error — agent should still run.

const std = @import("std");
const catalog = @import("catalog.zig");
const types = @import("types.zig");

pub const CostRates = catalog.CostRates;

/// USD breakdown for one usage sample.
pub const CostBreakdown = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,
    /// False when rates were missing/zero (total still 0).
    known: bool = false,

    pub fn add(self: *CostBreakdown, other: CostBreakdown) void {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
        self.total += other.total;
        self.known = self.known or other.known;
    }
};

/// Session / run accumulator (not thread-safe).
pub const Ledger = struct {
    turns: u32 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    cost: CostBreakdown = .{},

    pub fn record(self: *Ledger, usage: types.Usage, rates: ?CostRates) void {
        self.turns += 1;
        self.prompt_tokens += usage.prompt_tokens;
        self.completion_tokens += usage.completion_tokens;
        self.total_tokens += if (usage.total_tokens != 0)
            usage.total_tokens
        else
            usage.prompt_tokens + usage.completion_tokens;
        self.reasoning_tokens += usage.reasoning_tokens;
        self.cost.add(estimate(usage, rates));
    }

    pub fn recordModel(self: *Ledger, usage: types.Usage, info: ?catalog.ModelInfo) void {
        const rates = if (info) |m| m.cost else null;
        self.record(usage, rates);
    }
};

/// Estimate USD cost for `usage` given optional rates.
///
/// Uses prompt_tokens as input and completion_tokens as output.
/// Cache-specific fields on Usage are not yet populated by wires; cache rates
/// are reserved for when adapters expose them.
pub fn estimate(usage: types.Usage, rates: ?CostRates) CostBreakdown {
    const r = rates orelse return .{};
    if (r.isZero()) return .{};

    const mtok: f64 = 1_000_000.0;
    const input = (@as(f64, @floatFromInt(usage.prompt_tokens)) / mtok) * r.input;
    const output = (@as(f64, @floatFromInt(usage.completion_tokens)) / mtok) * r.output;
    // reasoning tokens are usually billed as output; do not double-count unless
    // completion_tokens already excludes them (vendor-dependent). Prefer completion.
    return .{
        .input = input,
        .output = output,
        .cache_read = 0,
        .cache_write = 0,
        .total = input + output,
        .known = true,
    };
}

pub fn estimateModel(usage: types.Usage, info: ?catalog.ModelInfo) CostBreakdown {
    return estimate(usage, if (info) |m| m.cost else null);
}

test "estimate gpt-4o-mini rough cost" {
    const m = catalog.find("openai", "gpt-4o-mini").?;
    const usage = types.Usage{
        .prompt_tokens = 1_000_000,
        .completion_tokens = 500_000,
        .total_tokens = 1_500_000,
    };
    const c = estimateModel(usage, m);
    try std.testing.expect(c.known);
    // 1M * 0.15 + 0.5M * 0.60 = 0.15 + 0.30 = 0.45
    try std.testing.expect(@abs(c.total - 0.45) < 0.001);
}

test "estimate unknown model is zero" {
    const c = estimate(.{ .prompt_tokens = 100, .completion_tokens = 50 }, null);
    try std.testing.expect(!c.known);
    try std.testing.expect(c.total == 0);
}

test "ledger accumulates" {
    var led: Ledger = .{};
    const m = catalog.find("openai", "gpt-4o-mini").?;
    led.recordModel(.{ .prompt_tokens = 1000, .completion_tokens = 500, .total_tokens = 1500 }, m);
    led.recordModel(.{ .prompt_tokens = 1000, .completion_tokens = 500, .total_tokens = 1500 }, m);
    try std.testing.expectEqual(@as(u32, 2), led.turns);
    try std.testing.expectEqual(@as(u64, 2000), led.prompt_tokens);
    try std.testing.expect(led.cost.known);
    try std.testing.expect(led.cost.total > 0);
}
