//! Provider port — what the harness needs from a model backend.
//!
//! Concrete HTTP/JSON lives under `src/provider/`. The loop only calls `chat`.

const std = @import("std");
const message = @import("message.zig");
const tool = @import("tool.zig");

pub const ChatError = error{
    HttpFailed,
    BadStatus,
    InvalidResponse,
    OutOfMemory,
    WriteFailed,
    Unexpected,
};

pub const VTable = struct {
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn,
};

/// Type-erased model backend.
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
