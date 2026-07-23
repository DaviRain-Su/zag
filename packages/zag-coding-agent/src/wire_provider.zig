//! Binds `zag-ai.WireAdapter` to Agent Core's pure `Provider` port.
//!
//! Lives in coding-agent (assembly), not in agent-core.

const std = @import("std");
const ai = @import("zag-ai");
const core = @import("zag-agent-core");

const message = core.message;
const tool = core.tool;
const provider_mod = core.provider;

pub const ChatError = provider_mod.ChatError;
pub const Provider = provider_mod.Provider;

/// Stateful bridge: WireAdapter + stream flags + chat options.
pub const WireProvider = struct {
    wire: ai.WireAdapter,
    /// When true, `deinit` calls `wire.deinit()`.
    owns_wire: bool = false,
    stream: bool = false,
    chat_options: ai.ChatOptions = .{},
    on_event: ?ai.types.StreamHandler = null,
    on_event_ctx: ?*anyopaque = null,

    pub fn init(w: ai.WireAdapter, stream_mode: bool, owns: bool) WireProvider {
        return .{
            .wire = w,
            .owns_wire = owns,
            .stream = stream_mode,
        };
    }

    pub fn deinit(self: *WireProvider) void {
        if (self.owns_wire) self.wire.deinit();
        self.* = undefined;
    }

    /// Expose core Provider port for the loop / Agent facade.
    pub fn asProvider(self: *WireProvider) Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Alias for asProvider (historical name).
    pub fn provider(self: *WireProvider) Provider {
        return self.asProvider();
    }

    const vtable: provider_mod.VTable = .{ .chat = chatImpl };

    fn chatImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) ChatError!message.AssistantTurn {
        const self: *WireProvider = @ptrCast(@alignCast(ptr));
        const defs = try arena.alloc(ai.ToolDefinition, tools.len);
        for (tools, 0..) |t, i| {
            defs[i] = t.definition;
        }
        if (self.stream) {
            return self.wire.chatStream(
                arena,
                messages,
                defs,
                self.on_event,
                self.on_event_ctx,
                self.chat_options,
            );
        }
        return self.wire.chat(arena, messages, defs, self.chat_options);
    }
};

/// Back-compat name used by older docs / main.
pub const Adapter = WireProvider;
