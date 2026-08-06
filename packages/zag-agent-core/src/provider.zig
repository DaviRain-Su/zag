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

/// Handler for one content delta from a streaming chat (tui-streaming-001).
/// `content_delta` is borrowed and valid only during the call; consumers that
/// retain it must copy. Called synchronously, in-order, once per chunk.
/// `reasoning_delta` (tui-thinking-streaming-001) is the optional
/// reasoning/thinking chunk for the same callback slot: null → this call
/// carries no thinking text (no thinking event); non-null → the chunk carries
/// reasoning text (content_delta may be empty for reasoning-only chunks).
pub const DeltaHandler = *const fn (ctx: *anyopaque, content_delta: []const u8, reasoning_delta: ?[]const u8) void;

pub const VTable = struct {
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: RequestControl,
    ) ChatError!message.AssistantTurn,
    /// Optional streaming variant (shape mirrors the zag-ai WireAdapter
    /// two-slot precedent wire.zig:59-63). Content deltas are forwarded to
    /// `handler` as they arrive; the complete `AssistantTurn` is still
    /// returned. When null, the loop falls back to `chat` and behavior is
    /// byte-identical to the pre-streaming port.
    chat_stream: ?*const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: RequestControl,
        handler: DeltaHandler,
        handler_ctx: *anyopaque,
    ) ChatError!message.AssistantTurn = null,
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

    /// Streaming chat when the provider implements `chat_stream`; otherwise
    /// `error.NotSupported` (the loop checks slot presence and falls back to
    /// `chat` — this method is for direct port users).
    pub fn chatStream(
        self: Provider,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: RequestControl,
        handler: DeltaHandler,
        handler_ctx: *anyopaque,
    ) ChatError!message.AssistantTurn {
        const f = self.vtable.chat_stream orelse return error.NotSupported;
        return f(self.ptr, arena, messages, tools, control, handler, handler_ctx);
    }
};
