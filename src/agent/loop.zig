//! Agent harness loop — business only.
//!
//! ```
//! transcript ──► provider.chat ──► assistant
//!      ▲                               │
//!      │                          tool_calls?
//!      │                          no → done
//!      │                          yes ↓
//!      └──────── tool results ────────┘
//! ```
//!
//! Who decides to call a tool? The **model**.
//! Who executes it? The **harness** (this file).
//! Where do results go? Back into the **transcript** as `role=tool`.

const std = @import("std");
const message = @import("message.zig");
const tool = @import("tool.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const observer_mod = @import("observer.zig");
const toolset_mod = @import("toolset.zig");

pub const default_max_turns: u32 = 20;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
    observer: observer_mod.Observer = .none(),
};

pub const RunError = error{
    MaxTurnsExceeded,
    ProviderFailed,
    OutOfMemory,
};

pub const Result = struct {
    /// Borrowed from the transcript arena — valid until the session arena dies.
    final_text: []const u8,
    turns: u32,
};

/// Dependencies for one loop invocation (assembled by `Agent`).
pub const Deps = struct {
    gpa: std.mem.Allocator,
    provider: provider_mod.Provider,
    toolset: toolset_mod.Toolset,
    tool_ctx: tool.Context,
    options: Options = .{},
};

/// Run until the model stops requesting tools or `max_turns` is hit.
pub fn run(deps: Deps, transcript: *transcript_mod.Transcript) RunError!Result {
    var turns: u32 = 0;
    var last_text: []const u8 = "";

    while (turns < deps.options.max_turns) {
        turns += 1;

        // Per-turn scratch for provider JSON; durable data is copied into transcript.
        var turn_arena_impl: std.heap.ArenaAllocator = .init(deps.gpa);
        defer turn_arena_impl.deinit();
        const scratch = turn_arena_impl.allocator();

        const turn = deps.provider.chat(
            scratch,
            transcript.items(),
            deps.toolset.tools,
        ) catch return error.ProviderFailed;

        // Copy assistant turn into the long-lived transcript.
        try transcript.appendAssistantTurn(turn);
        last_text = transcript.items()[transcript.items().len - 1].content;
        deps.options.observer.emit(.{ .assistant_text = last_text });

        if (!turn.wantsTools()) {
            return .{ .final_text = last_text, .turns = turns };
        }

        // Prefer arena-owned tool_calls from the transcript (not scratch).
        const last_msg = transcript.items()[transcript.items().len - 1];
        const calls = last_msg.tool_calls orelse {
            return .{ .final_text = last_text, .turns = turns };
        };

        const registry = deps.toolset.registry();
        for (calls) |call| {
            deps.options.observer.emit(.{ .tool_call = call });

            const raw = registry.execute(deps.tool_ctx, call.name, call.arguments) catch
                return error.OutOfMemory;
            defer deps.tool_ctx.allocator.free(raw);

            deps.options.observer.emit(.{
                .tool_result = .{ .name = call.name, .body = raw },
            });
            try transcript.appendToolResult(call.id, raw);
        }
    }

    return error.MaxTurnsExceeded;
}

test "loop stops when model returns text only" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var storage = toolset_mod.Phase0Storage.init();
    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = storage.toolset(),
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), result.turns);
}
