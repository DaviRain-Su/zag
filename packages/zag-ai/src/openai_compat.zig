//! OpenAI Chat Completions **WireAdapter** via monorepo `openai-zig` SDK.
//!
//! This is the default (and currently only) wire implementation of
//! `wire.ApiStyle.openai_compat`. Canonical messages live in `types.zig`;
//! conversion to OpenAI chat resources is private to this module.

const std = @import("std");
const Io = std.Io;
const openai = @import("openai_zig");
const types = @import("types.zig");
const wire = @import("wire.zig");
const config_mod = @import("config.zig");

const chat_res = openai.resources.chat;
const gen = openai.generated;

/// Shared wire config (same shape for all adapters).
pub const Config = config_mod.Config;

/// Provider-facing errors (alias of `wire.Error` — shared across all adapters).
pub const Error = wire.Error;

pub const ChatOptions = types.ChatOptions;
pub const ToolChoice = types.ToolChoice;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    sdk: openai.Client,
    /// When true, `asWireOwned` deinit frees this Client via allocator.
    owned_by_wire: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Client {
        var cfg = config;
        cfg.api_style = .openai_compat;
        const sdk = openai.initClient(allocator, .{
            .io = io,
            .base_url = cfg.base_url,
            .api_key = cfg.api_key,
            .max_retries = cfg.max_retries,
            .retry_base_delay_ms = cfg.retry_base_delay_ms,
            .timeout_ms = cfg.timeout_ms,
        }) catch |err| {
            std.debug.panic("openai-zig client init failed: {s}", .{@errorName(err)});
        };
        return .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .sdk = sdk,
        };
    }

    pub fn deinit(self: *Client) void {
        self.sdk.deinit();
    }

    pub fn apiStyle(_: *const Client) wire.ApiStyle {
        return .openai_compat;
    }

    pub fn wireName(_: *const Client) []const u8 {
        return "openai_compat";
    }

    /// Borrow as WireAdapter; `WireAdapter.deinit` is a no-op (caller owns Client).
    pub fn asWire(self: *Client) wire.WireAdapter {
        return .{
            .ptr = self,
            .vtable = &borrowed_vtable,
        };
    }

    /// Owned as WireAdapter; `WireAdapter.deinit` calls `Client.deinit` and frees heap.
    pub fn asWireOwned(self: *Client, gpa: std.mem.Allocator) wire.WireAdapter {
        _ = gpa;
        self.owned_by_wire = true;
        return .{
            .ptr = self,
            .vtable = &owned_vtable,
        };
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

        // Agent path: loop owns retries (exactly chat_retries+1 network attempts).
        const saved_retries = self.sdk.transport.max_retries;
        self.sdk.transport.max_retries = 0;
        defer self.sdk.transport.max_retries = saved_retries;

        self.sdk.transport.setRequestControl(toSdkControl(opts.control));
        defer self.sdk.transport.clearRequestControl();

        var parsed = self.sdk.chat().create_chat_completion(arena, req) catch |err| {
            return mapSdkError(err);
        };
        defer parsed.deinit();

        const turn = try turnFromResponse(arena, parsed.value);
        try types.validateCompleteToolCalls(arena, turn.tool_calls);
        return turn;
    }

    /// OpenAI Chat Completions SSE stream; returns assembled turn.
    /// (Anthropic streaming lives in `anthropic_messages.Client`, not here.)
    pub fn chatStreamWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        const chat_messages = try toChatMessages(arena, messages);
        const chat_tools = try toChatTools(arena, tools);
        const req = try buildChatRequest(self.config.model, chat_messages, chat_tools, opts, true);

        var state: OpenAiStreamState = .{
            .arena = arena,
            .handler = handler,
            .handler_ctx = handler_ctx,
        };

        const saved_retries = self.sdk.transport.max_retries;
        self.sdk.transport.max_retries = 0;
        defer self.sdk.transport.max_retries = saved_retries;

        self.sdk.transport.setRequestControl(toSdkControl(opts.control));
        defer self.sdk.transport.clearRequestControl();

        // On cancel/timeout/incomplete, partial state is discarded (never finish()).
        self.sdk.chat().create_chat_completion_stream_with_done(
            arena,
            req,
            onOpenAiSdkEvent,
            &state,
            onOpenAiSdkDone,
            &state,
        ) catch |err| {
            if (state.err) |e| return e;
            return mapSdkError(err);
        };

        if (state.err) |e| return e;
        if (!state.saw_protocol_done) return error.InvalidResponse;
        const turn = state.finish() catch return error.OutOfMemory;
        try types.validateCompleteToolCalls(arena, turn.tool_calls);
        return turn;
    }

    pub fn chatStream(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
    ) Error!types.AssistantTurn {
        return self.chatStreamWithOptions(arena, messages, tools, handler, handler_ctx, .{});
    }

    /// Create embeddings for one or more input strings (OpenAI-compatible `/embeddings`).
    /// Vectors and strings are allocated on `arena`.
    pub fn embed(
        self: *Client,
        arena: std.mem.Allocator,
        inputs: []const []const u8,
        opts: EmbedOptions,
    ) Error!EmbeddingResult {
        if (inputs.len == 0) return error.BadRequest;
        const model = opts.model orelse self.config.model;

        const input_val: std.json.Value = blk: {
            if (inputs.len == 1) break :blk .{ .string = inputs[0] };
            var arr = std.json.Array.init(arena);
            errdefer arr.deinit();
            for (inputs) |s| {
                try arr.append(.{ .string = s });
            }
            break :blk .{ .array = arr };
        };

        const req: gen.CreateEmbeddingRequest = .{
            .input = input_val,
            .model = .{ .string = model },
            .dimensions = if (opts.dimensions) |d| @as(i64, @intCast(d)) else null,
            .encoding_format = opts.encoding_format,
            .user = opts.user,
        };

        var parsed = self.sdk.embeddings().create(arena, req) catch |err| {
            return mapSdkError(err);
        };
        defer parsed.deinit();

        const data = parsed.value.data;
        const vectors = try arena.alloc([]const f64, data.len);
        for (data, 0..) |row, i| {
            const vec = try arena.alloc(f64, row.embedding.len);
            @memcpy(vec, row.embedding);
            vectors[i] = vec;
        }

        var usage: ?types.Usage = null;
        if (parsed.value.usage) |u| {
            usage = types.Usage.fromCounts(u.prompt_tokens, 0, u.total_tokens);
        }

        return .{
            .model = try arena.dupe(u8, optionalSlice(parsed.value.model)),
            .vectors = vectors,
            .usage = usage,
        };
    }

    /// Access the full openai-zig client (models, files, responses, …).
    pub fn sdkClient(self: *Client) *openai.Client {
        return &self.sdk;
    }

    const borrowed_vtable: wire.VTable = .{
        .api_style = wireApiStyle,
        .name = wireNameFn,
        .deinit = wireDeinitNoop,
        .chat = wireChat,
        .chat_stream = wireChatStream,
        .embed = wireEmbed,
    };

    const owned_vtable: wire.VTable = .{
        .api_style = wireApiStyle,
        .name = wireNameFn,
        .deinit = wireDeinitOwned,
        .chat = wireChat,
        .chat_stream = wireChatStream,
        .embed = wireEmbed,
    };

    fn wireApiStyle(ptr: *anyopaque) wire.ApiStyle {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.apiStyle();
    }

    fn wireNameFn(ptr: *anyopaque) []const u8 {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.wireName();
    }

    fn wireDeinitNoop(_: *anyopaque) void {}

    fn wireDeinitOwned(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        const gpa = self.allocator;
        self.deinit();
        gpa.destroy(self);
    }

    fn wireChat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.chatWithOptions(arena, messages, tools, opts);
    }

    fn wireChatStream(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.chatStreamWithOptions(arena, messages, tools, handler, handler_ctx, opts);
    }

    fn wireEmbed(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        inputs: []const []const u8,
        opts: EmbedOptions,
    ) Error!EmbeddingResult {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.embed(arena, inputs, opts);
    }
};

/// Heap-owned OpenAI-compat wire (used by `factory.createWire`).
pub fn createOpenAiCompatWire(gpa: std.mem.Allocator, io: Io, config: Config) Error!wire.WireAdapter {
    const client = gpa.create(Client) catch return error.OutOfMemory;
    client.* = Client.init(gpa, io, config);
    return client.asWireOwned(gpa);
}

/// Borrow an existing OpenAI client as WireAdapter (caller owns Client lifetime).
pub fn openAiCompatFromClient(client: *Client) wire.WireAdapter {
    return client.asWire();
}

// --- OpenAI Chat Completions SSE assembly (private to this adapter) ---

const OpenAiStreamState = struct {
    arena: std.mem.Allocator,
    handler: ?types.StreamHandler,
    handler_ctx: ?*anyopaque,
    content: std.ArrayList(u8) = .empty,
    tool_ids: std.ArrayList([]const u8) = .empty,
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_args: std.ArrayList(std.ArrayList(u8)) = .empty,
    finish_reason: []const u8 = "",
    /// Set only on explicit SSE `[DONE]` via on_done (never fabricated).
    saw_protocol_done: bool = false,
    err: ?Error = null,

    fn ensureToolSlot(self: *OpenAiStreamState, index: usize) !void {
        while (self.tool_ids.items.len <= index) {
            try self.tool_ids.append(self.arena, "");
            try self.tool_names.append(self.arena, "");
            try self.tool_args.append(self.arena, .empty);
        }
    }

    fn finish(self: *OpenAiStreamState) !types.AssistantTurn {
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

fn onOpenAiSdkEvent(
    user_ctx: ?*anyopaque,
    event: std.json.Parsed(chat_res.CreateChatCompletionStreamResponse),
) openai.errors.Error!void {
    const state: *OpenAiStreamState = @ptrCast(@alignCast(user_ctx.?));
    defer event.deinit();

    for (event.value.choices) |choice| {
        const index: usize = blk: {
            const raw = choice.index;
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

fn onOpenAiSdkDone(user_ctx: ?*anyopaque) openai.errors.Error!void {
    const state: *OpenAiStreamState = @ptrCast(@alignCast(user_ctx.?));
    // Invoked only after explicit `[DONE]` (strict SSE parser).
    state.saw_protocol_done = true;
    if (state.handler) |h| {
        h(state.handler_ctx, .done) catch {
            state.err = error.StreamFailed;
            return openai.errors.Error.HttpError;
        };
    }
}

pub const EmbedOptions = types.EmbedOptions;
pub const EmbeddingResult = types.EmbeddingResult;

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

/// Map L0 RequestControl onto openai-zig transport lifecycle (no zag-types dep in SDK).
fn toSdkControl(control: types.RequestControl) openai.transport.lifecycle.Control {
    return .{
        .cancel_atomic = if (control.cancel) |f| &f.cancelled else null,
        .deadline_mono_ns = control.deadline_mono_ns,
        .require_active_cancel = control.require_active_cancel,
    };
}

/// Map **openai-zig SDK** errors into shared `wire.Error`.
/// Only used by this OpenAI adapter — Anthropic uses `http` + `wire.Error` directly.
pub fn mapSdkError(err: anyerror) Error {
    const name = @errorName(err);
    // openai-zig error names
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "AuthenticationError")) return error.AuthenticationFailed;
    if (std.mem.eql(u8, name, "PermissionDeniedError")) return error.PermissionDenied;
    if (std.mem.eql(u8, name, "RateLimitError")) return error.RateLimited;
    if (std.mem.eql(u8, name, "Timeout") or std.mem.eql(u8, name, "TimeoutError")) return error.Timeout;
    if (std.mem.eql(u8, name, "Cancelled") or std.mem.eql(u8, name, "Canceled")) return error.Cancelled;
    if (std.mem.eql(u8, name, "UnsupportedControl")) return error.UnsupportedControl;
    if (std.mem.eql(u8, name, "InternalServerError")) return error.ServerError;
    if (std.mem.eql(u8, name, "BadRequestError") or
        std.mem.eql(u8, name, "UnprocessableEntityError") or
        std.mem.eql(u8, name, "NotFoundError") or
        std.mem.eql(u8, name, "ConflictError"))
        return error.BadRequest;
    if (std.mem.eql(u8, name, "DeserializeError") or std.mem.eql(u8, name, "SerializeError"))
        return error.InvalidResponse;
    if (std.mem.eql(u8, name, "WriteFailed")) return error.WriteFailed;
    // Already wire.Error (pass-through by name)
    if (std.mem.eql(u8, name, "AuthenticationFailed")) return error.AuthenticationFailed;
    if (std.mem.eql(u8, name, "PermissionDenied")) return error.PermissionDenied;
    if (std.mem.eql(u8, name, "RateLimited")) return error.RateLimited;
    if (std.mem.eql(u8, name, "ServerError")) return error.ServerError;
    if (std.mem.eql(u8, name, "BadRequest")) return error.BadRequest;
    if (std.mem.eql(u8, name, "InvalidResponse")) return error.InvalidResponse;
    if (std.mem.eql(u8, name, "StreamFailed")) return error.StreamFailed;
    if (std.mem.eql(u8, name, "BadStatus")) return error.BadStatus;
    if (std.mem.eql(u8, name, "NotSupported")) return error.NotSupported;
    if (std.mem.eql(u8, name, "UnsupportedControl")) return error.UnsupportedControl;
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
        .content = null,
    };

    if (msg.content_parts) |parts| {
        m.content_json = try contentPartsToJson(arena, parts);
    } else if (msg.content.len > 0) {
        m.content = msg.content;
    }

    switch (msg.role) {
        .tool => {
            m.tool_call_id = msg.tool_call_id;
            // Tool results are always plain text in the agent harness.
            m.content = msg.content;
            m.content_json = null;
        },
        .assistant => {
            if (msg.content_parts == null and msg.content.len == 0 and msg.tool_calls != null) {
                m.content = null;
            }
            if (msg.tool_calls) |calls| {
                const tc = try arena.alloc(gen.ChatCompletionMessageToolCall, calls.len);
                for (calls, 0..) |call, i| {
                    tc[i] = .{
                        .id = call.id,
                        .type = "function",
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

fn contentPartsToJson(arena: std.mem.Allocator, parts: []const types.ContentPart) Error!std.json.Value {
    var arr = std.json.Array.init(arena);
    errdefer arr.deinit();
    for (parts) |part| {
        try arr.append(try contentPartToJson(arena, part));
    }
    return .{ .array = arr };
}

fn contentPartToJson(arena: std.mem.Allocator, part: types.ContentPart) Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(arena);
    switch (part) {
        .text => |t| {
            try obj.put(arena, "type", .{ .string = "text" });
            try obj.put(arena, "text", .{ .string = t });
        },
        .image_url => |img| {
            try obj.put(arena, "type", .{ .string = "image_url" });
            var inner: std.json.ObjectMap = .empty;
            errdefer inner.deinit(arena);
            try inner.put(arena, "url", .{ .string = img.url });
            if (img.detail) |d| {
                try inner.put(arena, "detail", .{ .string = d });
            }
            try obj.put(arena, "image_url", .{ .object = inner });
        },
    }
    return .{ .object = obj };
}

pub fn toChatTools(arena: std.mem.Allocator, tools: []const types.ToolDefinition) Error![]const chat_res.ChatTool {
    if (tools.len == 0) return &.{};
    const out = try arena.alloc(chat_res.ChatTool, tools.len);
    for (tools, 0..) |t, i| {
        const parsed = std.json.parseFromSlice(std.json.Value, arena, t.parameters_json, .{}) catch
            return error.WriteFailed;
        out[i] = .{
            .type = "function",
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
            if (msg.content_parts == null and msg.content.len == 0 and msg.tool_calls != null) {
                s.write(null) catch return error.WriteFailed;
            } else if (msg.content_parts) |parts| {
                try writeContentPartsLegacy(s, parts);
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
            if (msg.content_parts) |parts| {
                try writeContentPartsLegacy(s, parts);
            } else {
                s.write(msg.content) catch return error.WriteFailed;
            }
        },
    }
    s.endObject() catch return error.WriteFailed;
}

fn writeContentPartsLegacy(s: *std.json.Stringify, parts: []const types.ContentPart) Error!void {
    s.beginArray() catch return error.WriteFailed;
    for (parts) |part| {
        s.beginObject() catch return error.WriteFailed;
        switch (part) {
            .text => |t| {
                s.objectField("type") catch return error.WriteFailed;
                s.write("text") catch return error.WriteFailed;
                s.objectField("text") catch return error.WriteFailed;
                s.write(t) catch return error.WriteFailed;
            },
            .image_url => |img| {
                s.objectField("type") catch return error.WriteFailed;
                s.write("image_url") catch return error.WriteFailed;
                s.objectField("image_url") catch return error.WriteFailed;
                s.beginObject() catch return error.WriteFailed;
                s.objectField("url") catch return error.WriteFailed;
                s.write(img.url) catch return error.WriteFailed;
                if (img.detail) |d| {
                    s.objectField("detail") catch return error.WriteFailed;
                    s.write(d) catch return error.WriteFailed;
                }
                s.endObject() catch return error.WriteFailed;
            },
        }
        s.endObject() catch return error.WriteFailed;
    }
    s.endArray() catch return error.WriteFailed;
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
                            .type = "function",
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

test "buildRequestBody encodes multimodal content_parts" {
    const gpa = std.testing.allocator;
    const parts = [_]types.ContentPart{
        .{ .text = "what is this?" },
        .{ .image_url = .{ .url = "https://example.com/a.png", .detail = "low" } },
    };
    const msgs = [_]types.Message{types.Message.userMultimodal(&parts)};
    const body = try buildRequestBody(gpa, "gpt-4o", &msgs, &.{}, .{}, false);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "what is this?") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "example.com/a.png") != null);
}
