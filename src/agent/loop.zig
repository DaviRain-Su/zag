//! Agent harness loop — business only.
//!
//! ```
//! transcript ──► provider.chat ──► assistant
//!      ▲                               │
//!      │                          tool_calls?
//!      │                          no → done
//!      │                          yes ↓
//!      │                     permission gate
//!      │                     deny → tool error string
//!      │                     allow → execute
//!      └──────── tool results ────────┘
//! ```
//!
//! Who decides to call a tool? The **model**.
//! Who executes it? The **harness** (after permissions).
//! Where do results go? Back into the **transcript** as `role=tool`.

const std = @import("std");
const message = @import("message.zig");
const tool = @import("tool.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const observer_mod = @import("observer.zig");
const toolset_mod = @import("toolset.zig");
const permissions = @import("permissions.zig");
const context_mod = @import("context.zig");

pub const default_max_turns: u32 = 20;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
    observer: observer_mod.Observer = .none(),
    /// Default yolo for tests; production CLI uses ask.
    permission_gate: permissions.Gate = .yolo(),
    /// What slice of the transcript is sent to the model each turn.
    context: context_mod.Options = .{},
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

        var turn_arena_impl: std.heap.ArenaAllocator = .init(deps.gpa);
        defer turn_arena_impl.deinit();
        const scratch = turn_arena_impl.allocator();

        // Full transcript stays in session; model only sees a context view.
        const view = context_mod.viewForModel(
            scratch,
            transcript.items(),
            deps.options.context,
        ) catch return error.OutOfMemory;

        const turn = deps.provider.chat(
            scratch,
            view.messages,
            deps.toolset.tools,
        ) catch return error.ProviderFailed;

        try transcript.appendAssistantTurn(turn);
        last_text = transcript.items()[transcript.items().len - 1].content;
        deps.options.observer.emit(.{ .assistant_text = last_text });

        if (!turn.wantsTools()) {
            return .{ .final_text = last_text, .turns = turns };
        }

        const last_msg = transcript.items()[transcript.items().len - 1];
        const calls = last_msg.tool_calls orelse {
            return .{ .final_text = last_text, .turns = turns };
        };

        const registry = deps.toolset.registry();
        for (calls) |call| {
            deps.options.observer.emit(.{ .tool_call = call });

            // Permission gate (business): deny → soft tool error, model can adapt.
            const decision = deps.options.permission_gate.decide(call.name, call.arguments);
            const allowed = decision == .allow;
            deps.options.observer.emit(.{
                .permission = .{ .tool_name = call.name, .allowed = allowed },
            });

            if (!allowed) {
                const denied = permissions.deniedMessage(deps.tool_ctx.allocator, call.name) catch
                    return error.OutOfMemory;
                defer deps.tool_ctx.allocator.free(denied);
                deps.options.observer.emit(.{
                    .tool_result = .{ .name = call.name, .body = denied },
                });
                try transcript.appendToolResult(call.id, denied);
                continue;
            }

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

test "permission deny yields tool error without executing" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"x\",\"content\":\"y\"}"),
                };
                return .{
                    .content = "",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            // Second turn: model should see permission denied in transcript.
            _ = messages;
            return .{
                .content = try arena.dupe(u8, "understood, not writing"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write something");

    var storage = toolset_mod.Phase1Storage.init();
    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = storage.toolset(),
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{
            .permission_gate = .denyAllDangerous(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("understood, not writing", result.final_text);
    // Transcript should contain a tool message with permission denied.
    var found_deny = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and std.mem.indexOf(u8, m.content, "permission denied") != null) {
            found_deny = true;
        }
    }
    try std.testing.expect(found_deny);
}
