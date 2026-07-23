//! Provider port — pure Agent Core surface over any model backend.
//!
//! Core never imports wire clients (`openai_compat.Client`, etc.).
//! Coding-agent / shell bind a `zag-ai.WireAdapter` via `providerFromWire`.

const std = @import("std");
const ai = @import("zag-ai");
const message = @import("message.zig");
const tool = @import("tool.zig");

/// Neutral error set for chat (matches `zag-ai.wire.Error`).
pub const ChatError = ai.wire.Error;

pub const VTable = struct {
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn,
};

/// Type-erased model chat port used by the loop.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn chat(
        self: Provider,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn {
        return self.vtable.chat(self.ptr, arena, messages, tools);
    }
};
