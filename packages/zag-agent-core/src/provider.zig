//! Provider port — pure Agent Core surface over any model backend.
//!
//! Core never imports wire clients (`openai_compat.Client`, etc.).
//! Coding-agent / shell bind a `zag-ai.WireAdapter` via WireProvider.
//!
//! The model plane receives only `[]const ToolDefinition` — never runtime
//! Tool/descriptor/capabilities/instance.
//!
//! `RequestControl` (cancel + monotonic deadline) is required on every chat so
//! in-flight backends can observe lifecycle, not only pre/post checks.

const std = @import("std");
const zt = @import("zag-types");
const message = @import("message.zig");
const tool = @import("tool.zig");

/// Neutral error set (L0) — adapters map vendor errors here.
pub const ChatError = zt.ChatError;
pub const RequestControl = zt.RequestControl;

pub const VTable = struct {
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: RequestControl,
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
        tools: []const tool.Definition,
        control: RequestControl,
    ) ChatError!message.AssistantTurn {
        return self.vtable.chat(self.ptr, arena, messages, tools, control);
    }
};
