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
    /// Transient HTTP retries (passed to openai-zig transport).
    max_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    timeout_ms: ?u64 = null,
};

/// Provider-facing errors. Prefer `types.isRetryableError` for policy.
pub const Error = error{
    HttpFailed,
    BadStatus,
    InvalidResponse,
    OutOfMemory,
    WriteFailed,
    Unexpected,
    StreamFailed,
    AuthenticationFailed,
    PermissionDenied,
    RateLimited,
    Timeout,
    ServerError,
    BadRequest,
};

pub const ChatOptions = types.ChatOptions;
pub const ToolChoice = types.ToolChoice;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    sdk: openai.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Client {
        const sdk = openai.initClient(allocator, .{
            .io = io,
            .base_url = config.base_url,
            .api_key = config.api_key,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
            .timeout_ms = config.timeout_ms,
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

    /// Call chat completions with default options.
    pub fn chat(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
    ) Error!types.AssistantTurn {
        return self.chatWithOptions(arena, messages, tools, .{});
    }

    /// Call chat completions with per-request knobs.
    pub fn chatWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        const chat_messages = try toChatMessages(arena, messages);
        const chat_tools = try toChatTools(arena, tools);
        const req = try buildChatRequest(self.config.model, chat_messages, chat_tools, opts, false);

        var parsed = self.sdk.chat().create_chat_completion(arena, req) catch |err| {
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

pub fn buildChatRequest(
    model: []const u8,
    messages: []const chat_res.ChatMessage,
    tools: []const chat_res.ChatTool,
    opts: ChatOptions,
    stream: bool,
) Error!chat_res.CreateChatCompletionRequest {
    var req: chat_res.CreateChatCompletionRequest = .{
        .model = model,
        .messages = messages,
        .tools = if (tools.len > 0) tools else null,
        .stream = if (stream) true else null,
        .temperature = opts.temperature,
        .top_p = opts.top_p,
        .max_tokens = opts.max_tokens,
        .max_completion_tokens = opts.max_completion_tokens,
        .parallel_tool_calls = opts.parallel_tool_calls,
        .user = opts.user,
        .seed = opts.seed,
        .extra_body = opts.extra_body,
    };
    if (opts.tool_choice) |tc| {
        req.tool_choice = try toolChoiceToChat(tc);
    }
    return req;
}

fn toolChoiceToChat(tc: ToolChoice) Error!chat_res.ChatToolChoice {
    return switch (tc) {
        .auto => chat_res.ChatToolChoice.forAuto(),
        .none => chat_res.ChatToolChoice.forNone(),
        .required => chat_res.ChatToolChoice.forRequired(),
        .function => |name| chat_res.ChatToolChoice.forFunction(name),
    };
}

pub fn mapSdkError(err: anyerror) Error {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "AuthenticationError")) return error.AuthenticationFailed;
    if (std.mem.eql(u8, name, "PermissionDeniedError")) return error.PermissionDenied;
    if (std.mem.eql(u8, name, "RateLimitError")) return error.RateLimited;
    if (std.mem.eql(u8, name, "Timeout") or std.mem.eql(u8, name, "TimeoutError")) return error.Timeout;
    if (std.mem.eql(u8, name, "InternalServerError")) return error.ServerError;
    if (std.mem.eql(u8, name, "BadRequestError") or
        std.mem.eql(u8, name, "UnprocessableEntityError") or
        std.mem.eql(u8, name, "NotFoundError") or
        std.mem.eql(u8, name, "ConflictError"))
        return error.BadRequest;
    if (std.mem.eql(u8, name, "DeserializeError") or std.mem.eql(u8, name, "SerializeError"))
        return error.InvalidResponse;
    if (std.mem.eql(u8, name, "WriteFailed")) return error.WriteFailed;
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

fn usageFromResponse(resp: gen.CreateChatCompletionResponse) ?types.Usage {
    const u = resp.usage orelse return null;
    var out = types.Usage.fromCounts(u.prompt_tokens, u.completion_tokens, u.total_tokens);
    if (u.completion_tokens_details) |d| {
        if (d.reasoning_tokens) |rt| {
            if (rt > 0 and rt < std.math.maxInt(u32)) {
                out.reasoning_tokens = @intCast(rt);
            }
        }
    }
    return out;
}

pub fn turnFromResponse(arena: std.mem.Allocator, resp: gen.CreateChatCompletionResponse) Error!types.AssistantTurn {
    const choices = resp.choices;
    if (choices.len == 0) return error.InvalidResponse;
    const choice = choices[0];
    const finish_reason = try arena.dupe(u8, optionalSlice(choice.finish_reason));
    const usage = usageFromResponse(resp);
    const msg = choice.message orelse {
        return .{
            .content = try arena.dupe(u8, ""),
            .tool_calls = &.{},
            .finish_reason = finish_reason,
            .usage = usage,
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
        .usage = usage,
    };
}

/// Build JSON body for streaming requests (tests + fallbacks).
pub fn buildRequestBodyForStream(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
) Error![]u8 {
    return buildRequestBody(allocator, model, messages, tools, .{}, true);
}

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    opts: ChatOptions,
    stream: bool,
) Error![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    s.beginObject() catch return error.WriteFailed;
    s.objectField("model") catch return error.WriteFailed;
    s.write(model) catch return error.WriteFailed;
    if (stream) {
        s.objectField("stream") catch return error.WriteFailed;
        s.write(true) catch return error.WriteFailed;
    }
    if (opts.temperature) |t| {
        s.objectField("temperature") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.top_p) |t| {
        s.objectField("top_p") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.max_tokens) |t| {
        s.objectField("max_tokens") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.max_completion_tokens) |t| {
        s.objectField("max_completion_tokens") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.parallel_tool_calls) |t| {
        s.objectField("parallel_tool_calls") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.user) |u| {
        s.objectField("user") catch return error.WriteFailed;
        s.write(u) catch return error.WriteFailed;
    }
    if (opts.seed) |seed| {
        s.objectField("seed") catch return error.WriteFailed;
        s.write(seed) catch return error.WriteFailed;
    }
    if (opts.tool_choice) |tc| {
        s.objectField("tool_choice") catch return error.WriteFailed;
        try writeToolChoiceLegacy(&s, tc);
    }

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

    if (opts.extra_body) |extra| {
        if (extra == .object) {
            var it = extra.object.iterator();
            while (it.next()) |entry| {
                s.objectField(entry.key_ptr.*) catch return error.WriteFailed;
                s.write(entry.value_ptr.*) catch return error.WriteFailed;
            }
        }
    }

    s.endObject() catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeToolChoiceLegacy(s: *std.json.Stringify, tc: ToolChoice) Error!void {
    switch (tc) {
        .auto => s.write("auto") catch return error.WriteFailed,
        .none => s.write("none") catch return error.WriteFailed,
        .required => s.write("required") catch return error.WriteFailed,
        .function => |name| {
            s.beginObject() catch return error.WriteFailed;
            s.objectField("type") catch return error.WriteFailed;
            s.write("function") catch return error.WriteFailed;
            s.objectField("function") catch return error.WriteFailed;
            s.beginObject() catch return error.WriteFailed;
            s.objectField("name") catch return error.WriteFailed;
            s.write(name) catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
        },
    }
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
    try std.testing.expect(turn.usage == null);
}

test "turnFromResponse tool_calls and usage" {
    const gpa = std.testing.allocator;
    const turn = try turnFromResponse(gpa, .{
        .choices = &.{
            .{
                .finish_reason = "tool_calls",
                .message = .{
                    .content = null,
                    .tool_calls = &.{
                        .{
                            .id = "call_1",
                            .@"type" = "function",
                            .function = .{
                                .name = "list_dir",
                                .arguments = "{\"path\":\".\"}",
                            },
                        },
                    },
                },
            },
        },
        .usage = .{
            .prompt_tokens = 12,
            .completion_tokens = 8,
            .total_tokens = 20,
            .completion_tokens_details = .{
                .reasoning_tokens = 3,
            },
        },
    });
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
        for (turn.tool_calls) |tc| {
            gpa.free(tc.id);
            gpa.free(tc.name);
            gpa.free(tc.arguments);
        }
        if (turn.tool_calls.len > 0) gpa.free(turn.tool_calls);
    }
    try std.testing.expect(turn.wantsTools());
    try std.testing.expectEqualStrings("list_dir", turn.tool_calls[0].name);
    try std.testing.expectEqualStrings("call_1", turn.tool_calls[0].id);
    const u = turn.usage.?;
    try std.testing.expectEqual(@as(u32, 12), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), u.completion_tokens);
    try std.testing.expectEqual(@as(u32, 20), u.total_tokens);
    try std.testing.expectEqual(@as(u32, 3), u.reasoning_tokens);
}

test "buildRequestBody includes options" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{types.Message.user("hi")};
    const tools = [_]types.ToolDefinition{.{
        .name = "list_dir",
        .description = "list",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
    }};
    const body = try buildRequestBody(gpa, "test-model", &msgs, &tools, .{
        .temperature = 0.2,
        .max_tokens = 128,
        .tool_choice = .required,
        .parallel_tool_calls = false,
    }, false);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "list_dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\"") == null);
}

test "buildRequestBodyForStream sets stream true" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{types.Message.user("hi")};
    const body = try buildRequestBodyForStream(gpa, "m", &msgs, &.{});
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "mapSdkError classifies auth and rate limit" {
    try std.testing.expectEqual(error.AuthenticationFailed, mapSdkError(error.AuthenticationError));
    try std.testing.expectEqual(error.RateLimited, mapSdkError(error.RateLimitError));
    try std.testing.expectEqual(error.ServerError, mapSdkError(error.InternalServerError));
    try std.testing.expectEqual(error.Timeout, mapSdkError(error.TimeoutError));
    try std.testing.expectEqual(error.BadRequest, mapSdkError(error.BadRequestError));
    try std.testing.expect(types.isRetryableError(error.RateLimited));
    try std.testing.expect(!types.isRetryableError(error.AuthenticationFailed));
}
