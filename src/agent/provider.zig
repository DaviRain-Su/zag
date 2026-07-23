//! Provider port — harness-facing vtable over monorepo `zag-ai` wire adapters.
//!
//! Harness sees only canonical messages. Wire protocol (OpenAI-compat today)
//! lives behind `zag-ai.WireAdapter` / `Client`.

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

/// Wraps `zag-ai.Client` (OpenAI-compat wire) for the agent loop.
/// Prefer `fromWire` when constructing from `resolve().createWire()`.
pub const Adapter = struct {
    /// Borrowed OpenAI client when `owns_wire` is false.
    client: ?ai.Client = null,
    /// Type-erased wire (OpenAI or future). When set, used instead of `client`.
    wire: ?ai.WireAdapter = null,
    /// When true, `deinit` calls `wire.deinit()` (heap client from createWire).
    owns_wire: bool = false,
    /// When true, use SSE streaming (still returns a full AssistantTurn).
    stream: bool = false,
    /// Per-request chat knobs (temperature, max_tokens, tool_choice, …).
    chat_options: ai.ChatOptions = .{},
    /// Optional live content callback (e.g. print deltas to stderr/stdout).
    on_event: ?ai.stream.Handler = null,
    on_event_ctx: ?*anyopaque = null,

    pub fn init(client: ai.Client, stream_mode: bool) Adapter {
        return .{ .client = client, .stream = stream_mode };
    }

    /// Wrap a WireAdapter (e.g. from `Resolved.createWire`). Takes ownership if `owns`.
    pub fn fromWire(w: ai.WireAdapter, stream_mode: bool, owns: bool) Adapter {
        return .{
            .wire = w,
            .owns_wire = owns,
            .stream = stream_mode,
        };
    }

    pub fn deinit(self: *Adapter) void {
        if (self.owns_wire) {
            if (self.wire) |w| w.deinit();
        } else if (self.client) |*c| {
            c.deinit();
        }
        self.* = .{};
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

        if (self.wire) |w| {
            if (self.stream) {
                return w.chatStream(arena, messages, defs, self.on_event, self.on_event_ctx, self.chat_options);
            }
            return w.chat(arena, messages, defs, self.chat_options);
        }

        var client = self.client orelse return error.Unexpected;
        if (self.stream) {
            return client.chatStreamWithOptions(
                arena,
                messages,
                defs,
                self.on_event,
                self.on_event_ctx,
                self.chat_options,
            );
        }
        return client.chatWithOptions(arena, messages, defs, self.chat_options);
    }
};
