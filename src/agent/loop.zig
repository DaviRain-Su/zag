//! The agent harness loop (Phase 0).
//!
//! ```
//! messages ──► provider.chat ──► assistant
//!                 ▲                 │
//!                 │            tool_calls?
//!                 │            no → done
//!                 │            yes ↓
//!                 └──── tool results ──┘
//! ```
//!
//! Who decides to call a tool? The **model**.
//! Who executes it? The **harness** (this loop).
//! Where do results go? Back into `messages` as `role=tool`.

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const openai = @import("../provider/openai.zig");

pub const default_max_turns: u32 = 20;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
    /// When true, print tool calls / results to stderr for debugging.
    verbose: bool = false,
};

pub const RunError = error{
    MaxTurnsExceeded,
    ProviderFailed,
    OutOfMemory,
    WriteFailed,
};

pub const Result = struct {
    /// Final assistant text (may be empty if the model only used tools).
    final_text: []const u8,
    /// Number of provider round-trips.
    turns: u32,
};

/// Run until the model stops requesting tools or `max_turns` is hit.
///
/// `messages` is the mutable transcript. Caller owns it; this function appends
/// assistant + tool messages using `arena` for all new string storage.
pub fn run(
    arena: std.mem.Allocator,
    provider: *openai.Client,
    registry: tool.Registry,
    tool_ctx: tool.Context,
    messages: *std.ArrayList(message.Message),
    tools: []const tool.Tool,
    options: Options,
) RunError!Result {
    var turns: u32 = 0;
    var last_text: []const u8 = "";

    while (turns < options.max_turns) {
        turns += 1;

        // Per-turn scratch for HTTP JSON parse; copy durable pieces into `arena`.
        var turn_arena_impl: std.heap.ArenaAllocator = .init(provider.allocator);
        defer turn_arena_impl.deinit();
        const turn_arena = turn_arena_impl.allocator();

        const turn = provider.chat(turn_arena, messages.items, tools) catch {
            return error.ProviderFailed;
        };

        // Persist assistant message into the long-lived arena.
        const content_copy = arena.dupe(u8, turn.content) catch return error.OutOfMemory;
        last_text = content_copy;

        var persisted_calls: ?[]message.ToolCall = null;
        if (turn.tool_calls.len > 0) {
            const calls = arena.alloc(message.ToolCall, turn.tool_calls.len) catch
                return error.OutOfMemory;
            for (turn.tool_calls, 0..) |c, i| {
                calls[i] = .{
                    .id = arena.dupe(u8, c.id) catch return error.OutOfMemory,
                    .name = arena.dupe(u8, c.name) catch return error.OutOfMemory,
                    .arguments = arena.dupe(u8, c.arguments) catch return error.OutOfMemory,
                };
            }
            persisted_calls = calls;
        }

        if (persisted_calls) |calls| {
            messages.append(arena, message.Message.assistantToolCalls(content_copy, calls)) catch
                return error.OutOfMemory;
        } else {
            messages.append(arena, message.Message.assistantText(content_copy)) catch
                return error.OutOfMemory;
        }

        if (options.verbose) {
            if (content_copy.len > 0) {
                std.log.info("assistant: {s}", .{content_copy});
            }
        }

        const calls = persisted_calls orelse {
            // No tools → model is done.
            return .{ .final_text = last_text, .turns = turns };
        };

        if (calls.len == 0) {
            return .{ .final_text = last_text, .turns = turns };
        }

        // Execute each tool and append results.
        for (calls) |call| {
            if (options.verbose) {
                std.log.info("tool_call {s}({s})", .{ call.name, call.arguments });
            }

            // Tool results allocated with tool_ctx.allocator; re-home into arena.
            const raw = registry.execute(tool_ctx, call.name, call.arguments) catch
                return error.OutOfMemory;
            defer tool_ctx.allocator.free(raw);

            const result_copy = arena.dupe(u8, raw) catch return error.OutOfMemory;
            if (options.verbose) {
                const preview_len = @min(result_copy.len, 200);
                std.log.info("tool_result {s}: {s}{s}", .{
                    call.name,
                    result_copy[0..preview_len],
                    if (result_copy.len > preview_len) "…" else "",
                });
            }

            messages.append(arena, message.Message.toolResult(call.id, result_copy)) catch
                return error.OutOfMemory;
        }
    }

    return error.MaxTurnsExceeded;
}

/// Convenience: one user prompt → final text, managing transcript on an arena.
pub fn runPrompt(
    gpa: std.mem.Allocator,
    io: Io,
    provider: *openai.Client,
    system_prompt: []const u8,
    user_prompt: []const u8,
    options: Options,
) RunError!Result {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var tools_storage = @import("../runtime/fs_tools.zig").phase0Tools();
    const tools: []const tool.Tool = &tools_storage;
    const registry: tool.Registry = .{ .tools = tools };

    var messages: std.ArrayList(message.Message) = .empty;
    messages.append(arena, message.Message.system(arena.dupe(u8, system_prompt) catch return error.OutOfMemory)) catch
        return error.OutOfMemory;
    messages.append(arena, message.Message.user(arena.dupe(u8, user_prompt) catch return error.OutOfMemory)) catch
        return error.OutOfMemory;

    const tool_ctx: tool.Context = .{
        .allocator = gpa,
        .io = io,
        .cwd = Io.Dir.cwd(),
    };

    // Result final_text lives in arena; dupe to gpa before arena dies.
    const result = try run(arena, provider, registry, tool_ctx, &messages, tools, options);
    const owned = gpa.dupe(u8, result.final_text) catch return error.OutOfMemory;
    return .{ .final_text = owned, .turns = result.turns };
}
