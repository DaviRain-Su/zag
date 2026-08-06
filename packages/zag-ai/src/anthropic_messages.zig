//! Anthropic Messages API WireAdapter (`POST /v1/messages`).
//!
//! Canonical messages → Anthropic JSON; responses / SSE → `AssistantTurn`.
//! Uses shared `config.Config` + neutral `http.Client` (not openai_compat).

const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const wire = @import("wire.zig");
const config_mod = @import("config.zig");
const http = @import("http.zig");

pub const Error = wire.Error;
pub const Config = config_mod.Config;
pub const ChatOptions = types.ChatOptions;

/// Default Anthropic API version header.
pub const default_api_version = "2023-06-01";

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    http: http.Client,
    owned_by_wire: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Error!Client {
        var cfg = config;
        cfg.api_style = .anthropic_messages;
        if (cfg.base_url.len == 0) {
            cfg.base_url = "https://api.anthropic.com";
        }

        const http_client = try http.Client.initHeaderAuth(
            allocator,
            io,
            cfg,
            "x-api-key",
            &.{
                .{ .name = "anthropic-version", .value = default_api_version },
            },
        );

        return .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .http = http_client,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn asWire(self: *Client) wire.WireAdapter {
        return .{ .ptr = self, .vtable = &borrowed_vtable };
    }

    pub fn asWireOwned(self: *Client, gpa: std.mem.Allocator) wire.WireAdapter {
        _ = gpa;
        self.owned_by_wire = true;
        return .{ .ptr = self, .vtable = &owned_vtable };
    }

    /// `retry_after_out` (retry-after-wire-001): optional capture slot for
    /// the `Retry-After` header (ms). Written ONLY on terminal error returns
    /// where `mapHttpStatus` yields RateLimited/ServerError (429, 500..599)
    /// and the header parsed as integer seconds; cleared to null otherwise.
    /// The transport already wrote the parsed value (or null) for those
    /// statuses; non-rate-limit/server errors are nulled here.
    pub fn chatWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        const body = try buildRequestBody(arena, self.config.model, messages, tools, opts, false);

        // Agent path: loop owns retries.
        const saved_retries = self.http.max_retries;
        self.http.max_retries = 0;
        defer self.http.max_retries = saved_retries;

        const resp = self.http.postJsonControl("/v1/messages", body, opts.control, retry_after_out) catch |err| {
            if (retry_after_out) |out| {
                if (err != error.RateLimited and err != error.ServerError) out.* = null;
            }
            return err;
        };
        defer self.http.freeBody(resp.body);

        if (resp.status < 200 or resp.status >= 300) {
            return http.Client.mapHttpStatus(resp.status);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();

        const turn = try turnFromAnthropicValue(arena, parsed.value);
        try types.validateCompleteToolCalls(arena, turn.tool_calls);
        return turn;
    }

    /// See `chatWithOptions` for `retry_after_out` semantics (stream variant).
    pub fn chatStreamWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        const body = try buildRequestBody(arena, self.config.model, messages, tools, opts, true);

        var state: StreamState = .{
            .arena = arena,
            .handler = handler,
            .handler_ctx = handler_ctx,
        };

        const saved_retries = self.http.max_retries;
        self.http.max_retries = 0;
        defer self.http.max_retries = saved_retries;

        // On cancel/timeout/incomplete, partial state is discarded (never finish()).
        self.http.postJsonStreamControl("/v1/messages", body, onHttpChunk, &state, opts.control, retry_after_out) catch |err| {
            if (state.err) |e| {
                // SSE-level failures never carry Retry-After (retry-after-wire-001).
                if (retry_after_out) |out| out.* = null;
                return e;
            }
            if (retry_after_out) |out| {
                if (err != error.RateLimited and err != error.ServerError) out.* = null;
            }
            return err;
        };

        if (state.err) |e| return e;
        // Leftover unterminated SSE line → incomplete stream.
        if (state.line_buf.items.len > 0) return error.InvalidResponse;
        if (!state.saw_message_stop) return error.InvalidResponse;
        const turn = state.finish() catch return error.OutOfMemory;
        try types.validateCompleteToolCalls(arena, turn.tool_calls);
        return turn;
    }

    /// Anthropic has no public embeddings API on this wire.
    pub fn embed(
        _: *Client,
        _: std.mem.Allocator,
        _: []const []const u8,
        _: types.EmbedOptions,
    ) Error!types.EmbeddingResult {
        return error.NotSupported;
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

    fn wireApiStyle(_: *anyopaque) wire.ApiStyle {
        return .anthropic_messages;
    }

    fn wireNameFn(_: *anyopaque) []const u8 {
        return "anthropic_messages";
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
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.chatWithOptions(arena, messages, tools, opts, retry_after_out);
    }

    fn wireChatStream(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.chatStreamWithOptions(arena, messages, tools, handler, handler_ctx, opts, retry_after_out);
    }

    fn wireEmbed(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        inputs: []const []const u8,
        opts: types.EmbedOptions,
    ) Error!types.EmbeddingResult {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.embed(arena, inputs, opts);
    }
};

pub fn createWire(gpa: std.mem.Allocator, io: Io, config: Config) Error!wire.WireAdapter {
    const client = gpa.create(Client) catch return error.OutOfMemory;
    client.* = try Client.init(gpa, io, config);
    return client.asWireOwned(gpa);
}

// --- SSE stream assembly ---

pub const StreamState = struct {
    arena: std.mem.Allocator,
    handler: ?types.StreamHandler,
    handler_ctx: ?*anyopaque,
    line_buf: std.ArrayList(u8) = .empty,
    content: std.ArrayList(u8) = .empty,
    /// Reasoning/thinking accumulator (tui-thinking-streaming-001): thinking
    /// block-start text joined with `\n` (mirrors non-stream
    /// appendReasoningLine), thinking_delta text appended raw; final turn
    /// `.reasoning` comes from here (null when empty).
    reasoning: std.ArrayList(u8) = .empty,
    /// Partial tool_use blocks keyed by content block index.
    tool_ids: std.ArrayList([]const u8) = .empty,
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_args: std.ArrayList(std.ArrayList(u8)) = .empty,
    /// Map content-block index → tool slot (only for tool_use blocks).
    block_to_tool: std.AutoHashMapUnmanaged(usize, usize) = .{},
    finish_reason: []const u8 = "",
    usage: ?types.Usage = null,
    /// Explicit Anthropic `message_stop` required (never fabricate).
    saw_message_stop: bool = false,
    err: ?Error = null,

    fn ensureToolSlot(self: *StreamState) !usize {
        const i = self.tool_ids.items.len;
        try self.tool_ids.append(self.arena, "");
        try self.tool_names.append(self.arena, "");
        try self.tool_args.append(self.arena, .empty);
        return i;
    }

    fn finish(self: *StreamState) !types.AssistantTurn {
        // Do not invent finish_reason=stop; empty means incomplete protocol.
        if (self.finish_reason.len == 0 and self.tool_ids.items.len == 0 and self.content.items.len == 0) {
            // Allowed: empty content stop if message_stop + stop_reason mapped empty?
            // Require either content, tools, or explicit stop_reason from message_delta.
        }
        const fr = try self.arena.dupe(u8, if (self.finish_reason.len > 0) self.finish_reason else "end_turn");
        const content = try self.arena.dupe(u8, self.content.items);
        // Reasoning from the accumulated buffer; null when the stream carried
        // no thinking blocks (tui-thinking-streaming-001).
        const reasoning = if (self.reasoning.items.len > 0)
            try self.arena.dupe(u8, self.reasoning.items)
        else
            null;
        if (self.tool_ids.items.len == 0) {
            return .{
                .content = content,
                .tool_calls = &.{},
                .finish_reason = fr,
                .usage = self.usage,
                .reasoning = reasoning,
            };
        }
        const calls = try self.arena.alloc(types.ToolCall, self.tool_ids.items.len);
        for (0..self.tool_ids.items.len) |i| {
            calls[i] = .{
                .id = try self.arena.dupe(u8, self.tool_ids.items[i]),
                .name = try self.arena.dupe(u8, self.tool_names.items[i]),
                .arguments = try self.arena.dupe(u8, self.tool_args.items[i].items),
            };
        }
        return .{
            .content = content,
            .tool_calls = calls,
            .finish_reason = fr,
            .usage = self.usage,
            .reasoning = reasoning,
        };
    }
};

fn onHttpChunk(ctx: ?*anyopaque, chunk: []const u8) Error!void {
    const state: *StreamState = @ptrCast(@alignCast(ctx.?));
    feedSseBytes(state, chunk) catch |err| {
        state.err = err;
        return err;
    };
}

/// Public for tests: feed raw SSE bytes into stream state.
pub fn feedSseBytes(state: *StreamState, chunk: []const u8) Error!void {
    try state.line_buf.appendSlice(state.arena, chunk);
    while (true) {
        const nl = std.mem.indexOfScalar(u8, state.line_buf.items, '\n') orelse break;
        var line = state.line_buf.items[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // Copy line before mutating buffer (handleSseLine may allocate; line is in buffer).
        const line_owned = try state.arena.dupe(u8, line);
        const rest_start = nl + 1;
        const rest_len = state.line_buf.items.len - rest_start;
        if (rest_len > 0) {
            std.mem.copyForwards(u8, state.line_buf.items[0..rest_len], state.line_buf.items[rest_start..]);
        }
        state.line_buf.shrinkRetainingCapacity(rest_len);
        try handleSseLine(state, line_owned);
    }
}

fn handleSseLine(state: *StreamState, line: []const u8) Error!void {
    if (line.len == 0) return;
    if (std.mem.startsWith(u8, line, ":")) return; // comment
    // After message_stop, only blank/comment lines are allowed.
    if (state.saw_message_stop) {
        if (std.mem.startsWith(u8, line, "event:") or std.mem.startsWith(u8, line, "data:")) {
            state.err = error.InvalidResponse;
            return error.InvalidResponse;
        }
        return;
    }
    if (std.mem.startsWith(u8, line, "event:")) return; // type is also in data JSON
    if (!std.mem.startsWith(u8, line, "data:")) return;
    const data = std.mem.trim(u8, line["data:".len..], " \t");
    if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) return;

    const parsed = std.json.parseFromSlice(std.json.Value, state.arena, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Malformed SSE JSON fails the whole uncommitted turn.
        state.err = error.InvalidResponse;
        return error.InvalidResponse;
    };
    defer parsed.deinit();
    try handleSseEvent(state, parsed.value);
}

fn handleSseEvent(state: *StreamState, root: std.json.Value) Error!void {
    if (root != .object) return;
    // No state mutation after terminal message_stop.
    if (state.saw_message_stop) {
        state.err = error.InvalidResponse;
        return error.InvalidResponse;
    }
    const o = root.object;
    const typ = if (o.get("type")) |t| (if (t == .string) t.string else "") else "";

    if (std.mem.eql(u8, typ, "content_block_start")) {
        const index: usize = @intCast(jsonInt(o.get("index")));
        if (o.get("content_block")) |cb| {
            if (cb == .object) {
                const cbo = cb.object;
                const bt = if (cbo.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, bt, "tool_use")) {
                    const slot = try state.ensureToolSlot();
                    try state.block_to_tool.put(state.arena, index, slot);
                    if (cbo.get("id")) |id| {
                        if (id == .string) state.tool_ids.items[slot] = try state.arena.dupe(u8, id.string);
                    }
                    if (cbo.get("name")) |name| {
                        if (name == .string) state.tool_names.items[slot] = try state.arena.dupe(u8, name.string);
                    }
                    if (state.handler) |h| {
                        h(state.handler_ctx, .{
                            .tool_call_delta = .{
                                .index = slot,
                                .id = state.tool_ids.items[slot],
                                .name = state.tool_names.items[slot],
                            },
                        }) catch {
                            state.err = error.StreamFailed;
                        };
                    }
                } else if (std.mem.eql(u8, bt, "thinking")) {
                    // Block-initial thinking text (some providers put the first
                    // segment here, rest arrives as thinking_delta). Join rule:
                    // `\n` before block-initial text when the buffer is
                    // non-empty; deltas append raw.
                    if (cbo.get("thinking")) |tx| {
                        if (tx == .string and tx.string.len > 0) {
                            try appendReasoningLine(state.arena, &state.reasoning, tx.string);
                            if (state.handler) |h| {
                                h(state.handler_ctx, .{ .reasoning_delta = tx.string }) catch {
                                    state.err = error.StreamFailed;
                                };
                            }
                        }
                    }
                } else if (std.mem.eql(u8, bt, "redacted_thinking")) {
                    // Redacted thinking blocks carry their payload in `data`
                    // (opaque base64-ish text); same join rule as thinking.
                    if (cbo.get("data")) |tx| {
                        if (tx == .string and tx.string.len > 0) {
                            try appendReasoningLine(state.arena, &state.reasoning, tx.string);
                            if (state.handler) |h| {
                                h(state.handler_ctx, .{ .reasoning_delta = tx.string }) catch {
                                    state.err = error.StreamFailed;
                                };
                            }
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, typ, "content_block_delta")) {
        const index: usize = @intCast(jsonInt(o.get("index")));
        if (o.get("delta")) |d| {
            if (d == .object) {
                const dtyp = if (d.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, dtyp, "text_delta")) {
                    if (d.object.get("text")) |tx| {
                        if (tx == .string and tx.string.len > 0) {
                            try state.content.appendSlice(state.arena, tx.string);
                            if (state.handler) |h| {
                                h(state.handler_ctx, .{ .content_delta = tx.string }) catch {
                                    state.err = error.StreamFailed;
                                };
                            }
                        }
                    }
                } else if (std.mem.eql(u8, dtyp, "thinking_delta")) {
                    // Continuation of a thinking block (tui-thinking-streaming-001):
                    // appended raw (no separator — the block-start join rule owns
                    // inter-block spacing). content_block_stop for thinking blocks
                    // is a no-op (already falls through below).
                    if (d.object.get("thinking")) |tx| {
                        if (tx == .string and tx.string.len > 0) {
                            try state.reasoning.appendSlice(state.arena, tx.string);
                            if (state.handler) |h| {
                                h(state.handler_ctx, .{ .reasoning_delta = tx.string }) catch {
                                    state.err = error.StreamFailed;
                                };
                            }
                        }
                    }
                } else if (std.mem.eql(u8, dtyp, "input_json_delta")) {
                    if (state.block_to_tool.get(index)) |slot| {
                        if (d.object.get("partial_json")) |pj| {
                            if (pj == .string and pj.string.len > 0) {
                                try state.tool_args.items[slot].appendSlice(state.arena, pj.string);
                                if (state.handler) |h| {
                                    h(state.handler_ctx, .{
                                        .tool_call_delta = .{
                                            .index = slot,
                                            .arguments_delta = pj.string,
                                        },
                                    }) catch {
                                        state.err = error.StreamFailed;
                                    };
                                }
                            }
                        }
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, typ, "message_delta")) {
        if (o.get("delta")) |d| {
            if (d == .object) {
                if (d.object.get("stop_reason")) |sr| {
                    if (sr == .string) {
                        state.finish_reason = mapStopReason(sr.string);
                        if (state.handler) |h| {
                            h(state.handler_ctx, .{ .finish_reason = state.finish_reason }) catch {
                                state.err = error.StreamFailed;
                            };
                        }
                    }
                }
            }
        }
        if (o.get("usage")) |u| {
            if (u == .object) {
                const completion = jsonInt(u.object.get("output_tokens"));
                // input tokens often only on message_start; merge if present
                const prompt = if (state.usage) |ex| ex.prompt_tokens else @as(u32, @intCast(jsonInt(u.object.get("input_tokens"))));
                const comp_u: u32 = @intCast(if (completion < 0) 0 else completion);
                state.usage = .{
                    .prompt_tokens = prompt,
                    .completion_tokens = comp_u,
                    .total_tokens = prompt +% comp_u,
                };
            }
        }
    } else if (std.mem.eql(u8, typ, "message_start")) {
        if (o.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("usage")) |u| {
                    if (u == .object) {
                        const prompt = jsonInt(u.object.get("input_tokens"));
                        state.usage = types.Usage.fromCounts(prompt, 0, prompt);
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, typ, "message_stop")) {
        if (state.saw_message_stop) {
            state.err = error.InvalidResponse;
            return error.InvalidResponse;
        }
        state.saw_message_stop = true;
        if (state.handler) |h| {
            h(state.handler_ctx, .done) catch {
                state.err = error.StreamFailed;
            };
        }
    } else if (std.mem.eql(u8, typ, "error")) {
        state.err = error.ServerError;
    }
}

/// Build Anthropic Messages JSON body (arena-allocated).
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    opts: ChatOptions,
    stream: bool,
) Error![]u8 {
    var out: Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

    s.beginObject() catch return error.WriteFailed;
    s.objectField("model") catch return error.WriteFailed;
    s.write(model) catch return error.WriteFailed;

    if (stream) {
        s.objectField("stream") catch return error.WriteFailed;
        s.write(true) catch return error.WriteFailed;
    }

    // max_tokens is required by Anthropic
    const max_tok: u32 = opts.max_tokens orelse opts.max_completion_tokens orelse 4096;
    s.objectField("max_tokens") catch return error.WriteFailed;
    s.write(max_tok) catch return error.WriteFailed;

    if (opts.temperature) |t| {
        s.objectField("temperature") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.top_p) |t| {
        s.objectField("top_p") catch return error.WriteFailed;
        s.write(t) catch return error.WriteFailed;
    }
    if (opts.user) |u| {
        s.objectField("metadata") catch return error.WriteFailed;
        s.beginObject() catch return error.WriteFailed;
        s.objectField("user_id") catch return error.WriteFailed;
        s.write(u) catch return error.WriteFailed;
        s.endObject() catch return error.WriteFailed;
    }

    // system prompt(s)
    var system_parts: std.ArrayList([]const u8) = .empty;
    defer system_parts.deinit(arena);
    for (messages) |m| {
        if (m.role == .system and m.content.len > 0) {
            try system_parts.append(arena, m.content);
        }
    }
    if (system_parts.items.len > 0) {
        s.objectField("system") catch return error.WriteFailed;
        if (system_parts.items.len == 1) {
            s.write(system_parts.items[0]) catch return error.WriteFailed;
        } else {
            const joined = try std.mem.join(arena, "\n\n", system_parts.items);
            s.write(joined) catch return error.WriteFailed;
        }
    }

    // messages (skip system)
    s.objectField("messages") catch return error.WriteFailed;
    s.beginArray() catch return error.WriteFailed;
    for (messages) |m| {
        if (m.role == .system) continue;
        try writeAnthropMessage(&s, arena, m);
    }
    s.endArray() catch return error.WriteFailed;

    if (tools.len > 0) {
        s.objectField("tools") catch return error.WriteFailed;
        s.beginArray() catch return error.WriteFailed;
        for (tools) |t| {
            try writeAnthropTool(&s, t);
        }
        s.endArray() catch return error.WriteFailed;
    }

    if (opts.tool_choice) |tc| {
        s.objectField("tool_choice") catch return error.WriteFailed;
        try writeAnthropToolChoice(&s, tc);
    }

    s.endObject() catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeAnthropToolChoice(s: *std.json.Stringify, tc: types.ToolChoice) Error!void {
    switch (tc) {
        .auto => s.write("auto") catch return error.WriteFailed,
        .none => {
            s.beginObject() catch return error.WriteFailed;
            s.objectField("type") catch return error.WriteFailed;
            s.write("none") catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
        },
        .required => {
            s.beginObject() catch return error.WriteFailed;
            s.objectField("type") catch return error.WriteFailed;
            s.write("any") catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
        },
        .function => |name| {
            s.beginObject() catch return error.WriteFailed;
            s.objectField("type") catch return error.WriteFailed;
            s.write("tool") catch return error.WriteFailed;
            s.objectField("name") catch return error.WriteFailed;
            s.write(name) catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
        },
    }
}

fn writeAnthropTool(s: *std.json.Stringify, t: types.ToolDefinition) Error!void {
    s.beginObject() catch return error.WriteFailed;
    s.objectField("name") catch return error.WriteFailed;
    s.write(t.name) catch return error.WriteFailed;
    s.objectField("description") catch return error.WriteFailed;
    s.write(t.description) catch return error.WriteFailed;
    s.objectField("input_schema") catch return error.WriteFailed;
    // parameters_json is a JSON object string — emit raw
    s.print("{s}", .{t.parameters_json}) catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
}

fn writeAnthropMessage(s: *std.json.Stringify, arena: std.mem.Allocator, m: types.Message) Error!void {
    s.beginObject() catch return error.WriteFailed;
    switch (m.role) {
        .user => {
            s.objectField("role") catch return error.WriteFailed;
            s.write("user") catch return error.WriteFailed;
            s.objectField("content") catch return error.WriteFailed;
            if (m.content_parts) |parts| {
                try writeUserContentParts(s, parts);
            } else {
                s.write(m.content) catch return error.WriteFailed;
            }
        },
        .assistant => {
            s.objectField("role") catch return error.WriteFailed;
            s.write("assistant") catch return error.WriteFailed;
            s.objectField("content") catch return error.WriteFailed;
            s.beginArray() catch return error.WriteFailed;
            if (m.content.len > 0) {
                s.beginObject() catch return error.WriteFailed;
                s.objectField("type") catch return error.WriteFailed;
                s.write("text") catch return error.WriteFailed;
                s.objectField("text") catch return error.WriteFailed;
                s.write(m.content) catch return error.WriteFailed;
                s.endObject() catch return error.WriteFailed;
            }
            if (m.tool_calls) |calls| {
                for (calls) |call| {
                    s.beginObject() catch return error.WriteFailed;
                    s.objectField("type") catch return error.WriteFailed;
                    s.write("tool_use") catch return error.WriteFailed;
                    s.objectField("id") catch return error.WriteFailed;
                    s.write(call.id) catch return error.WriteFailed;
                    s.objectField("name") catch return error.WriteFailed;
                    s.write(call.name) catch return error.WriteFailed;
                    s.objectField("input") catch return error.WriteFailed;
                    // arguments is JSON object string
                    if (call.arguments.len > 0) {
                        s.print("{s}", .{call.arguments}) catch return error.WriteFailed;
                    } else {
                        s.write(std.json.Value{ .object = .empty }) catch return error.WriteFailed;
                    }
                    s.endObject() catch return error.WriteFailed;
                }
            }
            s.endArray() catch return error.WriteFailed;
        },
        .tool => {
            // Anthropic: tool results are user messages with tool_result blocks
            s.objectField("role") catch return error.WriteFailed;
            s.write("user") catch return error.WriteFailed;
            s.objectField("content") catch return error.WriteFailed;
            s.beginArray() catch return error.WriteFailed;
            s.beginObject() catch return error.WriteFailed;
            s.objectField("type") catch return error.WriteFailed;
            s.write("tool_result") catch return error.WriteFailed;
            s.objectField("tool_use_id") catch return error.WriteFailed;
            s.write(m.tool_call_id orelse "") catch return error.WriteFailed;
            s.objectField("content") catch return error.WriteFailed;
            s.write(m.content) catch return error.WriteFailed;
            s.endObject() catch return error.WriteFailed;
            s.endArray() catch return error.WriteFailed;
            _ = arena;
        },
        .system => {},
    }
    s.endObject() catch return error.WriteFailed;
}

fn writeUserContentParts(s: *std.json.Stringify, parts: []const types.ContentPart) Error!void {
    s.beginArray() catch return error.WriteFailed;
    for (parts) |p| {
        s.beginObject() catch return error.WriteFailed;
        switch (p) {
            .text => |t| {
                s.objectField("type") catch return error.WriteFailed;
                s.write("text") catch return error.WriteFailed;
                s.objectField("text") catch return error.WriteFailed;
                s.write(t) catch return error.WriteFailed;
            },
            .image_url => |img| {
                // Anthropic prefers source.base64 or url — map url form
                s.objectField("type") catch return error.WriteFailed;
                s.write("image") catch return error.WriteFailed;
                s.objectField("source") catch return error.WriteFailed;
                s.beginObject() catch return error.WriteFailed;
                s.objectField("type") catch return error.WriteFailed;
                s.write("url") catch return error.WriteFailed;
                s.objectField("url") catch return error.WriteFailed;
                s.write(img.url) catch return error.WriteFailed;
                s.endObject() catch return error.WriteFailed;
                _ = img.detail;
            },
        }
        s.endObject() catch return error.WriteFailed;
    }
    s.endArray() catch return error.WriteFailed;
}

/// Parse Anthropic Messages response Value → AssistantTurn.
pub fn turnFromAnthropicValue(arena: std.mem.Allocator, root: std.json.Value) Error!types.AssistantTurn {
    if (root != .object) return error.InvalidResponse;
    const o = root.object;

    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(arena);
    var reasoning_buf: std.ArrayList(u8) = .empty;
    defer reasoning_buf.deinit(arena);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(arena);

    if (o.get("content")) |c| {
        if (c == .array) {
            for (c.array.items) |block| {
                if (block != .object) continue;
                const b = block.object;
                const typ = if (b.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, typ, "text")) {
                    if (b.get("text")) |tx| {
                        if (tx == .string) try content_buf.appendSlice(arena, tx.string);
                    }
                } else if (std.mem.eql(u8, typ, "thinking")) {
                    if (b.get("thinking")) |tx| {
                        if (tx == .string) try appendReasoningLine(arena, &reasoning_buf, tx.string);
                    }
                } else if (std.mem.eql(u8, typ, "redacted_thinking")) {
                    if (b.get("data")) |tx| {
                        if (tx == .string) try appendReasoningLine(arena, &reasoning_buf, tx.string);
                    }
                } else if (std.mem.eql(u8, typ, "tool_use")) {
                    const id = if (b.get("id")) |v| (if (v == .string) v.string else "") else "";
                    const name = if (b.get("name")) |v| (if (v == .string) v.string else "") else "";
                    var args_json: []const u8 = "{}";
                    if (b.get("input")) |inp| {
                        var aw: Io.Writer.Allocating = .init(arena);
                        defer aw.deinit();
                        var js: std.json.Stringify = .{ .writer = &aw.writer };
                        js.write(inp) catch return error.WriteFailed;
                        args_json = aw.toOwnedSlice() catch return error.OutOfMemory;
                    }
                    try tool_calls.append(arena, .{
                        .id = try arena.dupe(u8, id),
                        .name = try arena.dupe(u8, name),
                        .arguments = args_json,
                    });
                }
            }
        }
    }

    const stop_reason_raw = if (o.get("stop_reason")) |sr|
        (if (sr == .string) sr.string else "")
    else
        "";
    const finish = mapStopReason(stop_reason_raw);

    var usage: ?types.Usage = null;
    if (o.get("usage")) |u| {
        if (u == .object) {
            const prompt = jsonInt(u.object.get("input_tokens"));
            const completion = jsonInt(u.object.get("output_tokens"));
            usage = types.Usage.fromCounts(prompt, completion, prompt + completion);
        }
    }

    return .{
        .content = try arena.dupe(u8, content_buf.items),
        .tool_calls = if (tool_calls.items.len > 0)
            try arena.dupe(types.ToolCall, tool_calls.items)
        else
            &.{},
        .finish_reason = try arena.dupe(u8, finish),
        .usage = usage,
        .reasoning = if (reasoning_buf.items.len > 0)
            try arena.dupe(u8, reasoning_buf.items)
        else
            null,
    };
}

/// Append a thinking/redacted_thinking block's text to the reasoning buffer,
/// joining blocks with a single `\n` (per binding: text joined "\n").
fn appendReasoningLine(
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
) Error!void {
    if (buf.items.len > 0) try buf.append(arena, '\n');
    try buf.appendSlice(arena, text);
}

fn mapStopReason(sr: []const u8) []const u8 {
    if (std.mem.eql(u8, sr, "end_turn") or std.mem.eql(u8, sr, "stop_sequence")) return "stop";
    if (std.mem.eql(u8, sr, "tool_use")) return "tool_calls";
    if (std.mem.eql(u8, sr, "max_tokens")) return "length";
    if (sr.len == 0) return "stop";
    return sr;
}

fn jsonInt(v: ?std.json.Value) i64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

// --- tests (no network) ---

test "anthropic request body encodes system and tools" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{
        types.Message.system("be helpful"),
        types.Message.user("hi"),
    };
    const tools = [_]types.ToolDefinition{.{
        .name = "list_dir",
        .description = "list",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
    }};
    const body = try buildRequestBody(gpa, "claude-sonnet-4-0", &msgs, &tools, .{
        .max_tokens = 256,
        .temperature = 0.2,
    }, false);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-sonnet-4-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":256") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"be helpful\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "list_dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "input_schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
}

test "anthropic request body tool_result and tool_use" {
    const gpa = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "toolu_1",
        .name = "read_file",
        .arguments = "{\"path\":\"a.zig\"}",
    }};
    const msgs = [_]types.Message{
        types.Message.user("read it"),
        types.Message.assistantToolCalls("", &calls),
        types.Message.toolResult("toolu_1", "ok"),
    };
    const body = try buildRequestBody(gpa, "claude-3", &msgs, &.{}, .{ .max_tokens = 100 }, false);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_use") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "toolu_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "read_file") != null);
}

test "anthropic turnFrom response tool_use" {
    const gpa = std.testing.allocator;
    const raw =
        \\{
        \\  "content": [
        \\    {"type": "text", "text": "calling"},
        \\    {"type": "tool_use", "id": "tu1", "name": "list_dir", "input": {"path": "."}}
        \\  ],
        \\  "stop_reason": "tool_use",
        \\  "usage": {"input_tokens": 10, "output_tokens": 5}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const turn = try turnFromAnthropicValue(gpa, parsed.value);
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
    try std.testing.expectEqualStrings("calling", turn.content);
    try std.testing.expectEqualStrings("tool_calls", turn.finish_reason);
    try std.testing.expect(turn.wantsTools());
    try std.testing.expectEqualStrings("list_dir", turn.tool_calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, turn.tool_calls[0].arguments, "path") != null);
    try std.testing.expectEqual(@as(u32, 15), turn.usage.?.total_tokens);
}

test "anthropic turnFrom response captures thinking + redacted_thinking joined" {
    const gpa = std.testing.allocator;
    const raw =
        \\{
        \\  "content": [
        \\    {"type": "thinking", "thinking": "first thought", "signature": "sig-1"},
        \\    {"type": "redacted_thinking", "data": "opaque-block"},
        \\    {"type": "text", "text": "visible answer"}
        \\  ],
        \\  "stop_reason": "end_turn",
        \\  "usage": {"input_tokens": 10, "output_tokens": 5}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const turn = try turnFromAnthropicValue(gpa, parsed.value);
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
        gpa.free(turn.reasoning.?);
    }
    try std.testing.expectEqualStrings("visible answer", turn.content);
    try std.testing.expectEqualStrings("first thought\nopaque-block", turn.reasoning.?);
    try std.testing.expectEqualStrings("stop", turn.finish_reason);
    try std.testing.expect(!turn.wantsTools());
}

test "anthropic turnFrom response reasoning null when no thinking blocks" {
    const gpa = std.testing.allocator;
    const raw =
        \\{
        \\  "content": [{"type": "text", "text": "plain"}],
        \\  "stop_reason": "end_turn"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const turn = try turnFromAnthropicValue(gpa, parsed.value);
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
    }
    try std.testing.expect(turn.reasoning == null);
    try std.testing.expectEqualStrings("plain", turn.content);
}

test "anthropic request body stream true" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{types.Message.user("hi")};
    const body = try buildRequestBody(gpa, "claude-3", &msgs, &.{}, .{ .max_tokens = 64 }, true);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "anthropic SSE text and tool_use assembly" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var state: StreamState = .{
        .arena = arena,
        .handler = null,
        .handler_ctx = null,
    };

    const sse =
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"list_dir"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\".\"}"}}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}
        \\
        \\event: message_stop
        \\data: {"type":"message_stop"}
        \\
    ;
    try feedSseBytes(&state, sse);
    const turn = try state.finish();
    try std.testing.expectEqualStrings("Hi", turn.content);
    try std.testing.expectEqualStrings("tool_calls", turn.finish_reason);
    try std.testing.expectEqual(@as(usize, 1), turn.tool_calls.len);
    try std.testing.expectEqualStrings("list_dir", turn.tool_calls[0].name);
    try std.testing.expectEqualStrings("tu1", turn.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\".\"}", turn.tool_calls[0].arguments);
    try std.testing.expectEqual(@as(u32, 3), turn.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), turn.usage.?.completion_tokens);
}

test "anthropic SSE thinking deltas assemble reasoning joined by newline" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Deltas are borrowed only during the callback (the per-line JSON parse
    // is freed right after); copy into fixed buffers at emit time.
    const Rec = struct {
        reasoning_deltas: [8][64]u8 = undefined,
        reasoning_lens: [8]usize = [_]usize{0} ** 8,
        n: usize = 0,
        content_deltas: [8][64]u8 = undefined,
        content_lens: [8]usize = [_]usize{0} ** 8,
        cn: usize = 0,
        fn onEvent(ctx: ?*anyopaque, event: types.StreamEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .reasoning_delta => |rd| {
                    if (self.n < self.reasoning_deltas.len) {
                        const cap = @min(rd.len, self.reasoning_deltas[self.n].len);
                        @memcpy(self.reasoning_deltas[self.n][0..cap], rd[0..cap]);
                        self.reasoning_lens[self.n] = cap;
                        self.n += 1;
                    }
                },
                .content_delta => |cd| {
                    if (self.cn < self.content_deltas.len) {
                        const cap = @min(cd.len, self.content_deltas[self.cn].len);
                        @memcpy(self.content_deltas[self.cn][0..cap], cd[0..cap]);
                        self.content_lens[self.cn] = cap;
                        self.cn += 1;
                    }
                },
                else => {},
            }
        }
    };

    var rec: Rec = .{};
    var state: StreamState = .{
        .arena = arena,
        .handler = Rec.onEvent,
        .handler_ctx = &rec,
    };

    const sse =
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"first thought"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" continues"}}
        \\
        \\event: content_block_stop
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":2,"content_block":{"type":"redacted_thinking","data":"opaque-block"}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"tu1","name":"list_dir"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\".\"}"}}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}
        \\
        \\event: message_stop
        \\data: {"type":"message_stop"}
        \\
    ;
    try feedSseBytes(&state, sse);
    // Turn bytes are arena-allocated (state.finish uses state.arena); the
    // arena deinit below frees everything.
    const turn = try state.finish();
    // Thinking blocks joined with '\n'; text deltas unaffected; tool_use
    // ordering preserved (thinking came first on the wire).
    try std.testing.expectEqualStrings("Hi", turn.content);
    try std.testing.expectEqualStrings("first thought continues\nopaque-block", turn.reasoning.?);
    try std.testing.expectEqualStrings("tool_calls", turn.finish_reason);
    try std.testing.expectEqual(@as(usize, 1), turn.tool_calls.len);
    try std.testing.expectEqualStrings("list_dir", turn.tool_calls[0].name);
    // Handler saw reasoning deltas in wire order (block-start + delta + redacted).
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expectEqualStrings("first thought", rec.reasoning_deltas[0][0..rec.reasoning_lens[0]]);
    try std.testing.expectEqualStrings(" continues", rec.reasoning_deltas[1][0..rec.reasoning_lens[1]]);
    try std.testing.expectEqualStrings("opaque-block", rec.reasoning_deltas[2][0..rec.reasoning_lens[2]]);
    try std.testing.expectEqual(@as(usize, 1), rec.cn);
    try std.testing.expectEqualStrings("Hi", rec.content_deltas[0][0..rec.content_lens[0]]);
}
