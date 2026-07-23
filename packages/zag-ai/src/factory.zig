//! Neutral WireAdapter factory (not owned by any single vendor adapter).

const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const config_mod = @import("config.zig");
const openai_compat = @import("openai_compat.zig");
const anthropic_messages = @import("anthropic_messages.zig");

pub const Error = wire.Error;
pub const Config = config_mod.Config;

/// Build a heap-owned WireAdapter for `style`. Caller must `adapter.deinit()`.
pub fn createWire(
    gpa: std.mem.Allocator,
    io: Io,
    config: Config,
    style: wire.ApiStyle,
) Error!wire.WireAdapter {
    var cfg = config;
    cfg.api_style = style;
    return switch (style) {
        .openai_compat => openai_compat.createOpenAiCompatWire(gpa, io, cfg),
        .anthropic_messages => anthropic_messages.createWire(gpa, io, cfg),
    };
}
