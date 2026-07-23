//! OpenAI Chat Completions via monorepo `openai-zig` SDK.
//!
//! Keeps a thin zag-facing API (`Config` / `Client` / `AssistantTurn`) while
//! transport, retries, streaming, and resource surface live in openai-zig.

const std = @import("std");
const Io = std.Io;
const openai = @import("openai_zig");
const types = @import("types.zig");

const chat_res = openai.resources.chat;
const gen = openai.generated;

pub const Config = struct {
    /// e.g. "https://api.openai.com/v1" or "https://api.deepseek.com/v1"
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub const Error = error{
    HttpFailed,
    BadStatus,
    InvalidResponse,
    OutOfMemory,
    WriteFailed,
    Unexpected,
    StreamFailed,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    sdk: openai.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Client {
        // initClient only fails on allocation; surface OOM later if needed.
        const sdk = openai.initClient(allocator, .{
            .io = io,
            .base_url = config.base_url,
            .api_key = config.api_key,
            .max_retries = 2,
            .retry_base_delay_ms = 500,
        }) catch |err| {
            std.debug.panic("openai-zig client init failed: {s}", .{@errorName(err)});
        };
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .sdk = sdk,
        };
    }

    pub fn deinit(self: *Client) void {
        self.sdk.deinit();
    }

    /// Call chat completions. Prefer `provider()` from harness code.
    pub fn chat(
        self: *Client,
        /// Scratch allocator for the request/response parse (arena recommended).
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
    ) Error!types.AssistantTurn {
        const chat_messages = try toChatMessages(arena, messages);
        const chat_tools = try toChatTools(arena, tools);

        var parsed = self.sdk.chat().create_chat_completion(arena, .{
            .model = self.config.model,
            .messages = chat_messages,
            .tools = if (chat_tools.len > 0) chat_tools else null,
        }) catch |err| {
            return mapSdkError(err);
        };
        defer parsed.deinit();

        return try turnFromResponse(arena, parsed.value);
    }

    /// Access the full openai-zig client (models, files, responses, …).
    pub fn sdkClient(self: *Client) *openai.Client {
        return &self.sdk;
    }
};

pub fn mapSdkError(err: anyerror) Error {
    // openai.errors.Error is an error set; compare by name for portability.
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "AuthenticationError") or
        std.mem.eql(u8, name, "PermissionDeniedError") or
        std.mem.eql(u8, name, "BadRequestError") or
        std.mem.eql(u8, name, "NotFoundError") or
        std.mem.eql(u8, name, "ConflictError") or
        std.mem.eql(u8, name, "UnprocessableEntityError") or
        std.mem.eql(u8, name, "RateLimitError") or
        std.mem.eql(u8, name, "InternalServerError"))
        return error.BadStatus;
    if (std.mem.eql(u8, name, "DeserializeError") or std.mem.eql(u8, name, "SerializeError"))
        return error.InvalidResponse;
    return error.HttpFailed;
}

pub fn toChatMessages(arena: std.mem.Allocator, messages: []const types.Message) Error![]const chat_res.ChatMessage {
    const out = try arena.alloc(chat_res.ChatMessage, messages.len);
    for (messages, 0..) |msg, i| {
        out[i] = try toChatMessage(arena, msg);
    }
    return out;
}

fn toChatMessage(arena: std.mem.Allocator, msg: types.Message) Error!chat_res.ChatMessage {
    var m: chat_res.ChatMessage = .{
        .role = msg.role.jsonName(),
        .content = if (msg.content.len > 0) msg.content else null,
    };
    switch (msg.role) {
        .tool => {
            m.tool_call_id = msg.tool_call_id;
            m.content = msg.content;
        },
        .assistant => {
            if (msg.content.len == 0 and msg.tool_calls != null) {
                m.content = null;
            }
            if (msg.tool_calls) |calls| {
                const tc = try arena.alloc(gen.ChatCompletionMessageToolCall, calls.len);
                for (calls, 0..) |call, i| {
                    tc[i] = .{
                        .id = call.id,
                        .@"type" = "function",
                        .function = .{
                            .name = call.name,
                            .arguments = call.arguments,
                        },
                    };
                }
                m.tool_calls = tc;
            }
        },
        .system, .user => {},
    }
    return m;
}

pub fn toChatTools(arena: std.mem.Allocator, tools: []const types.ToolDefinition) Error![]const chat_res.ChatTool {
    if (tools.len == 0) return &.{};
    const out = try arena.alloc(chat_res.ChatTool, tools.len);
    for (tools, 0..) |t, i| {
        const parsed = std.json.parseFromSlice(std.json.Value, arena, t.parameters_json, .{}) catch
            return error.WriteFailed;
        // Parsed lives in arena; no separate deinit needed for arena-backed parse.
        out[i] = .{
            .@"type" = "function",
            .function = .{
                .name = t.name,
                .description = t.description,
                .parameters = gen.FunctionParameters.forSchema(parsed.value),
                .strict = null,
            },
        };
    }
    return out;
}

fn optionalSlice(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8) return value;
    if (T == ?[]const u8) return value orelse "";
    return "";
}

pub fn turnFromResponse(arena: std.mem.Allocator, resp: gen.CreateChatCompletionResponse) Error!types.AssistantTurn {
    const choices = resp.choices;
    if (choices.len == 0) return error.InvalidResponse;
    const choice = choices[0];
    const finish_reason = try arena.dupe(u8, optionalSlice(choice.finish_reason));
    const msg = choice.message orelse {
        return .{
            .content = try arena.dupe(u8, ""),
            .tool_calls = &.{},
            .finish_reason = finish_reason,
        };
    };

    const content = try arena.dupe(u8, optionalSlice(msg.content));
    var tool_calls: []types.ToolCall = &.{};
    if (msg.tool_calls) |tcs| {
        if (tcs.len > 0) {
            const slice = try arena.alloc(types.ToolCall, tcs.len);
            for (tcs, 0..) |tc, i| {
                const name: []const u8 = if (tc.function) |fn_obj| optionalSlice(fn_obj.name) else "";
                const args: []const u8 = if (tc.function) |fn_obj| optionalSlice(fn_obj.arguments) else "";
                slice[i] = .{
                    .id = try arena.dupe(u8, optionalSlice(tc.id)),
                    .name = try arena.dupe(u8, name),
                    .arguments = try arena.dupe(u8, args),
                };
            }
            tool_calls = slice;
        }
    }

    return .{
        .content = content,
        .tool_calls = tool_calls,
        .finish_reason = finish_reason,
    };
}

/// Build request body with `"stream": true` — retained for stream.zig fallback paths.
pub fn buildRequestBodyForStream(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
) Error![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    s.beginObject() catch return error.WriteFailed;
    s.objectField("model") catch return error.WriteFailed;
    s.write(model) catch return error.WriteFailed;
    s.objectField("stream") catch return error.WriteFailed;
    s.write(true) catch return error.WriteFailed;

    s.objectField("messages") catch return error.WriteFailed;
    s.beginArray() catch return error.WriteFailed;
    for (messages) |msg| {
        try writeMessageLegacy(&s, msg);
    }
    s.endArray() catch return error.WriteFailed;

    if (tools.len > 0) {
        s.objectField("tools") catch return error.WriteFailed;
        s.beginArray() catch return error.WriteFailed;
        for (tools) |t| {
            try writeToolDefLegacy(&s, t);
        }
        s.endArray() catch return error.WriteFailed;
    }

    s.endObject() catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeMessageLegacy(s: *std.json.Stringify, msg: types.Message) Error!void {
    s.beginObject() catch return error.WriteFailed;
    s.objectField("role") catch return error.WriteFailed;
    s.write(msg.role.jsonName()) catch return error.WriteFailed;
    switch (msg.role) {
        .tool => {
            const id = msg.tool_call_id orelse return error.WriteFailed;
            s.objectField("tool_call_id") catch return error.WriteFailed;
            s.write(id) catch return error.WriteFailed;
            s.objectField("content") catch return error.WriteFailed;
            s.write(msg.content) catch return error.WriteFailed;
        },
        .assistant => {
            s.objectField("content") catch return error.WriteFailed;
            if (msg.content.len == 0 and msg.tool_calls != null) {
                s.write(null) catch return error.WriteFailed;
            } else {
                s.write(msg.content) catch return error.WriteFailed;
            }
            if (msg.tool_calls) |calls| {
                s.objectField("tool_calls") catch return error.WriteFailed;
                s.beginArray() catch return error.WriteFailed;
                for (calls) |call| {
                    s.beginObject() catch return error.WriteFailed;
                    s.objectField("id") catch return error.WriteFailed;
                    s.write(call.id) catch return error.WriteFailed;
                    s.objectField("type") catch return error.WriteFailed;
                    s.write("function") catch return error.WriteFailed;
                    s.objectField("function") catch return error.WriteFailed;
                    s.beginObject() catch return error.WriteFailed;
                    s.objectField("name") catch return error.WriteFailed;
                    s.write(call.name) catch return error.WriteFailed;
                    s.objectField("arguments") catch return error.WriteFailed;
                    s.write(call.arguments) catch return error.WriteFailed;
                    s.endObject() catch return error.WriteFailed;
                    s.endObject() catch return error.WriteFailed;
                }
                s.endArray() catch return error.WriteFailed;
            }
        },
        .system, .user => {
            s.objectField("content") catch return error.WriteFailed;
            s.write(msg.content) catch return error.WriteFailed;
        },
    }
    s.endObject() catch return error.WriteFailed;
}

fn writeToolDefLegacy(s: *std.json.Stringify, def: types.ToolDefinition) Error!void {
    s.beginObject() catch return error.WriteFailed;
    s.objectField("type") catch return error.WriteFailed;
    s.write("function") catch return error.WriteFailed;
    s.objectField("function") catch return error.WriteFailed;
    s.beginObject() catch return error.WriteFailed;
    s.objectField("name") catch return error.WriteFailed;
    s.write(def.name) catch return error.WriteFailed;
    s.objectField("description") catch return error.WriteFailed;
    s.write(def.description) catch return error.WriteFailed;
    s.objectField("parameters") catch return error.WriteFailed;
    s.print("{s}", .{def.parameters_json}) catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
}

test "turnFromResponse text" {
    const gpa = std.testing.allocator;
    const turn = try turnFromResponse(gpa, .{
        .choices = &.{
            .{
                .finish_reason = "stop",
                .message = .{
                    .content = "hello",
                },
            },
        },
    });
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
    }
    try std.testing.expectEqualStrings("hello", turn.content);
}


test "buildRequestBodyForStream sets stream true" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{types.Message.user("hi")};
    const body = try buildRequestBodyForStream(gpa, "m", &msgs, &.{});
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}
