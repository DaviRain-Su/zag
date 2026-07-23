//! OpenAI-compatible SSE streaming for chat completions (via openai-zig).

const std = @import("std");
const openai = @import("openai_zig");
const types = @import("types.zig");
const openai_compat = @import("openai_compat.zig");

const chat_res = openai.resources.chat;

pub const Error = openai_compat.Error;
pub const Handler = types.StreamHandler;

const StreamState = struct {
    arena: std.mem.Allocator,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
    content: std.ArrayList(u8) = .empty,
    tool_ids: std.ArrayList([]const u8) = .empty,
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_args: std.ArrayList(std.ArrayList(u8)) = .empty,
    finish_reason: []const u8 = "",
    err: ?Error = null,

    fn ensureToolSlot(self: *StreamState, index: usize) !void {
        while (self.tool_ids.items.len <= index) {
            try self.tool_ids.append(self.arena, "");
            try self.tool_names.append(self.arena, "");
            try self.tool_args.append(self.arena, .empty);
        }
    }

    fn finish(self: *StreamState) !types.AssistantTurn {
        const content = try self.arena.dupe(u8, self.content.items);
        const fr = try self.arena.dupe(u8, self.finish_reason);
        if (self.tool_ids.items.len == 0) {
            return .{ .content = content, .tool_calls = &.{}, .finish_reason = fr, .usage = null };
        }
        const calls = try self.arena.alloc(types.ToolCall, self.tool_ids.items.len);
        for (0..self.tool_ids.items.len) |i| {
            calls[i] = .{
                .id = try self.arena.dupe(u8, self.tool_ids.items[i]),
                .name = try self.arena.dupe(u8, self.tool_names.items[i]),
                .arguments = try self.arena.dupe(u8, self.tool_args.items[i].items),
            };
        }
        return .{ .content = content, .tool_calls = calls, .finish_reason = fr, .usage = null };
    }
};

fn onSdkEvent(user_ctx: ?*anyopaque, event: std.json.Parsed(chat_res.CreateChatCompletionStreamResponse)) openai.errors.Error!void {
    const state: *StreamState = @ptrCast(@alignCast(user_ctx.?));
    defer event.deinit();

    for (event.value.choices) |choice| {
        const index: usize = blk: {
            const raw = choice.index;
            // Hand-written stream choice uses i64; generated chunks may use ?i64.
            const v: i64 = if (@TypeOf(raw) == ?i64) (raw orelse 0) else raw;
            break :blk if (v > 0) @intCast(v) else 0;
        };

        if (choice.delta.content) |content| {
            if (content.len > 0) {
                state.content.appendSlice(state.arena, content) catch {
                    state.err = error.OutOfMemory;
                    return openai.errors.Error.HttpError;
                };
                if (state.handler) |h| {
                    h(state.handler_ctx, .{ .content_delta = content }) catch {
                        state.err = error.StreamFailed;
                        return openai.errors.Error.HttpError;
                    };
                }
            }
        }

        if (choice.delta.tool_calls) |tcs| {
            for (tcs) |tc| {
                const tc_index: usize = blk: {
                    const raw = tc.index;
                    const v: i64 = if (@TypeOf(raw) == ?i64) (raw orelse 0) else raw;
                    break :blk if (v > 0) @intCast(v) else index;
                };
                state.ensureToolSlot(tc_index) catch {
                    state.err = error.OutOfMemory;
                    return openai.errors.Error.HttpError;
                };
                if (tc.id) |id| {
                    if (id.len > 0) {
                        state.tool_ids.items[tc_index] = state.arena.dupe(u8, id) catch {
                            state.err = error.OutOfMemory;
                            return openai.errors.Error.HttpError;
                        };
                    }
                }
                if (tc.function) |fn_obj| {
                    if (fn_obj.name) |name| {
                        if (name.len > 0) {
                            state.tool_names.items[tc_index] = state.arena.dupe(u8, name) catch {
                                state.err = error.OutOfMemory;
                                return openai.errors.Error.HttpError;
                            };
                        }
                    }
                    if (fn_obj.arguments) |args| {
                        if (args.len > 0) {
                            state.tool_args.items[tc_index].appendSlice(state.arena, args) catch {
                                state.err = error.OutOfMemory;
                                return openai.errors.Error.HttpError;
                            };
                        }
                    }
                }
                if (state.handler) |h| {
                    h(state.handler_ctx, .{
                        .tool_call_delta = .{
                            .index = tc_index,
                            .id = if (tc.id) |id| id else "",
                            .name = if (tc.function) |f| (f.name orelse "") else "",
                            .arguments_delta = if (tc.function) |f| (f.arguments orelse "") else "",
                        },
                    }) catch {
                        state.err = error.StreamFailed;
                        return openai.errors.Error.HttpError;
                    };
                }
            }
        }

        if (choice.finish_reason) |fr| {
            if (fr.len > 0) {
                state.finish_reason = state.arena.dupe(u8, fr) catch {
                    state.err = error.OutOfMemory;
                    return openai.errors.Error.HttpError;
                };
                if (state.handler) |h| {
                    h(state.handler_ctx, .{ .finish_reason = fr }) catch {
                        state.err = error.StreamFailed;
                        return openai.errors.Error.HttpError;
                    };
                }
            }
        }
    }
}

fn onSdkDone(user_ctx: ?*anyopaque) openai.errors.Error!void {
    const state: *StreamState = @ptrCast(@alignCast(user_ctx.?));
    if (state.handler) |h| {
        h(state.handler_ctx, .done) catch {
            state.err = error.StreamFailed;
            return openai.errors.Error.HttpError;
        };
    }
}

/// Stream a chat completion; returns the assembled final turn (strings in `arena`).
pub fn chatStream(
    client: *openai_compat.Client,
    arena: std.mem.Allocator,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
) Error!types.AssistantTurn {
    return chatStreamWithOptions(client, arena, messages, tools, handler, handler_ctx, .{});
}

/// Stream with per-request options (temperature, tool_choice, …).
pub fn chatStreamWithOptions(
    client: *openai_compat.Client,
    arena: std.mem.Allocator,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
    opts: openai_compat.ChatOptions,
) Error!types.AssistantTurn {
    const chat_messages = try openai_compat.toChatMessages(arena, messages);
    const chat_tools = try openai_compat.toChatTools(arena, tools);
    const req = try openai_compat.buildChatRequest(client.config.model, chat_messages, chat_tools, opts, true);

    var state: StreamState = .{
        .arena = arena,
        .handler = handler,
        .handler_ctx = handler_ctx,
    };

    client.sdk.chat().create_chat_completion_stream_with_done(
        arena,
        req,
        onSdkEvent,
        &state,
        onSdkDone,
        &state,
    ) catch |err| {
        if (state.err) |e| return e;
        return openai_compat.mapSdkError(err);
    };

    if (state.err) |e| return e;
    return state.finish() catch return error.OutOfMemory;
}
