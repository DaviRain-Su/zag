//! Provider port — harness-facing vtable over monorepo `zag-ai` client.
//!
//! Supports non-streaming and SSE streaming (OpenAI Chat Completions only).

const std = @import("std");
const ai = @import("zag-ai");
const message = @import("message.zig");
const tool = @import("tool.zig");

pub const ChatError = ai.openai_compat.Error;

pub const VTable = struct {
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn,
};

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

/// Wraps `zag-ai.Client` for the agent loop.
pub const Adapter = struct {
    client: ai.Client,
    /// When true, use SSE streaming (still returns a full AssistantTurn).
    stream: bool = false,
    /// Per-request chat knobs (temperature, max_tokens, tool_choice, …).
    chat_options: ai.ChatOptions = .{},
    /// Optional live content callback (e.g. print deltas to stderr/stdout).
    on_event: ?ai.stream.Handler = null,
    on_event_ctx: ?*anyopaque = null,

    pub fn init(client: ai.Client, stream: bool) Adapter {
        return .{ .client = client, .stream = stream };
    }

    pub fn deinit(self: *Adapter) void {
        self.client.deinit();
    }

    pub fn provider(self: *Adapter) Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: VTable = .{ .chat = chatImpl };

    fn chatImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        const defs = try arena.alloc(ai.ToolDefinition, tools.len);
        for (tools, 0..) |t, i| {
            defs[i] = t.definition;
        }
        if (self.stream) {
            return ai.stream.chatStreamWithOptions(
                &self.client,
                arena,
                messages,
                defs,
                self.on_event,
                self.on_event_ctx,
                self.chat_options,
            );
        }
        return self.client.chatWithOptions(arena, messages, defs, self.chat_options);
    }
};
