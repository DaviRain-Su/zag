//! Anthropic Messages API WireAdapter (`POST /v1/messages`).
//!
//! Converts zag-ai canonical `Message` / `ToolDefinition` to Anthropic wire JSON
//! and maps responses back to `AssistantTurn`. Transport reuses openai-zig HTTP
//! (with `x-api-key` + `anthropic-version`, not Bearer).

const std = @import("std");
const Io = std.Io;
const openai = @import("openai_zig");
const types = @import("types.zig");
const wire = @import("wire.zig");
const openai_compat = @import("openai_compat.zig");

const transport_mod = openai.transport;

pub const Error = wire.Error;
pub const Config = openai_compat.Config;
pub const ChatOptions = types.ChatOptions;

/// Default Anthropic API version header.
pub const default_api_version = "2023-06-01";

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    transport: transport_mod.Transport,
    /// Owned header value buffers for x-api-key / version.
    api_key_hdr: []u8,
    api_version_hdr: []const u8,
    owned_by_wire: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Error!Client {
        var cfg = config;
        cfg.api_style = .anthropic_messages;
        if (cfg.base_url.len == 0) {
            cfg.base_url = "https://api.anthropic.com";
        }

        const key_copy = allocator.dupe(u8, cfg.api_key) catch return error.OutOfMemory;
        errdefer allocator.free(key_copy);

        const headers = allocator.alloc(std.http.Header, 2) catch return error.OutOfMemory;
        errdefer allocator.free(headers);
        headers[0] = .{ .name = "x-api-key", .value = key_copy };
        headers[1] = .{ .name = "anthropic-version", .value = default_api_version };

        const transport = transport_mod.Transport.init(allocator, io, .{
            .base_url = cfg.base_url,
            .api_key = null, // do not send Bearer
            .extra_headers = headers,
            .timeout_ms = cfg.timeout_ms,
            .max_retries = cfg.max_retries,
            .retry_base_delay_ms = cfg.retry_base_delay_ms,
        }) catch return error.HttpFailed;

        // Transport owns a copy of headers slice; free our temporary array but
        // not the key_copy if transport duped header structs only (values are pointers).
        // Transport.dupes the Header slice but not string contents — key_copy must
        // outlive transport. We store it on Client and free on deinit.
        // Transport also dupes the Header array; the value pointers still point at key_copy.
        allocator.free(headers);

        return .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .transport = transport,
            .api_key_hdr = key_copy,
            .api_version_hdr = default_api_version,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.allocator.free(self.api_key_hdr);
    }

    pub fn asWire(self: *Client) wire.WireAdapter {
        return .{ .ptr = self, .vtable = &borrowed_vtable };
    }

    pub fn asWireOwned(self: *Client, gpa: std.mem.Allocator) wire.WireAdapter {
        _ = gpa;
        self.owned_by_wire = true;
        return .{ .ptr = self, .vtable = &owned_vtable };
    }

    pub fn chatWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        const body = try buildRequestBody(arena, self.config.model, messages, tools, opts);

        const resp = self.transport.requestWithOptions(
            .POST,
            "/v1/messages",
            &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            body,
            null,
        ) catch |err| {
            return mapTransportError(err);
        };
        defer self.transport.allocator.free(resp.body);

        if (resp.status < 200 or resp.status >= 300) {
            return mapHttpStatus(resp.status);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();

        return try turnFromAnthropicValue(arena, parsed.value);
    }

    fn mapHttpStatus(status: u16) Error {
        return switch (status) {
            401 => error.AuthenticationFailed,
            403 => error.PermissionDenied,
            429 => error.RateLimited,
            400, 404, 409, 422 => error.BadRequest,
            408 => error.Timeout,
            500...599 => error.ServerError,
            else => error.BadStatus,
        };
    }

    pub fn chatStreamWithOptions(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        // Streaming SSE not yet implemented: non-stream chat + synthetic deltas.
        const turn = try self.chatWithOptions(arena, messages, tools, opts);
        if (handler) |h| {
            if (turn.content.len > 0) {
                h(handler_ctx, .{ .content_delta = turn.content }) catch return error.StreamFailed;
            }
            if (turn.finish_reason.len > 0) {
                h(handler_ctx, .{ .finish_reason = turn.finish_reason }) catch return error.StreamFailed;
            }
            h(handler_ctx, .done) catch return error.StreamFailed;
        }
        return turn;
    }

    const borrowed_vtable: wire.VTable = .{
        .api_style = wireApiStyle,
        .name = wireNameFn,
        .deinit = wireDeinitNoop,
        .chat = wireChat,
        .chat_stream = wireChatStream,
    };

    const owned_vtable: wire.VTable = .{
        .api_style = wireApiStyle,
        .name = wireNameFn,
        .deinit = wireDeinitOwned,
        .chat = wireChat,
        .chat_stream = wireChatStream,
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
};

pub fn createWire(gpa: std.mem.Allocator, io: Io, config: Config) Error!wire.WireAdapter {
    const client = gpa.create(Client) catch return error.OutOfMemory;
    client.* = try Client.init(gpa, io, config);
    return client.asWireOwned(gpa);
}

fn mapTransportError(err: anyerror) Error {
    return openai_compat.mapSdkError(err);
}

/// Build Anthropic Messages JSON body (arena-allocated).
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    opts: ChatOptions,
) Error![]u8 {
    var out: Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

    s.beginObject() catch return error.WriteFailed;
    s.objectField("model") catch return error.WriteFailed;
    s.write(model) catch return error.WriteFailed;

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
    };
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
    });
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
    const body = try buildRequestBody(gpa, "claude-3", &msgs, &.{}, .{ .max_tokens = 100 });
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
