//! OpenAI Chat Completions wire format — the **only** API implementation in Zag.
//!
//! Inspired by pi-ai's `openai-completions` api layer: many vendors (DeepSeek,
//! xAI, OpenRouter, …) share this HTTP+JSON shape. Vendor identity lives in
//! `presets.zig` / `registry.zig`; this file only speaks the wire protocol.
//!
//! Endpoint: `{base_url}/chat/completions` with tools + tool_calls.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const message = @import("../agent/message.zig");
const tool = @import("../agent/tool.zig");
const agent_provider = @import("../agent/provider.zig");

pub const Config = struct {
    /// e.g. "https://api.openai.com/v1" or "https://api.deepseek.com/v1"
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub const Error = agent_provider.ChatError;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    http_client: http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http_client = .{
                .allocator = allocator,
                .io = io,
            },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Type-erased handle for the agent harness (`agent.Provider`).
    pub fn provider(self: *Client) agent_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: agent_provider.VTable = .{
        .chat = chatVtable,
    };

    fn chatVtable(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) agent_provider.ChatError!message.AssistantTurn {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.chat(arena, messages, tools);
    }

    /// Call chat completions. Prefer `provider()` from harness code.
    pub fn chat(
        self: *Client,
        /// Scratch allocator for the request/response parse (arena recommended).
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Tool,
    ) Error!message.AssistantTurn {
        const body = try buildRequestBody(arena, self.config.model, messages, tools);
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
            trimTrailingSlash(self.config.base_url),
        });

        const auth_value = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.config.api_key});

        var response_body: Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &response_body.writer,
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
            },
        }) catch return error.HttpFailed;

        const status_int = @intFromEnum(result.status);
        if (status_int < 200 or status_int >= 300) {
            std.log.err("provider HTTP {d}: {s}", .{ status_int, response_body.written() });
            return error.BadStatus;
        }

        return parseAssistantTurn(arena, response_body.written()) catch return error.InvalidResponse;
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    if (url.len > 0 and url[url.len - 1] == '/') return url[0 .. url.len - 1];
    return url;
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const message.Message,
    tools: []const tool.Tool,
) Error![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer };

    s.beginObject() catch return error.WriteFailed;
    s.objectField("model") catch return error.WriteFailed;
    s.write(model) catch return error.WriteFailed;

    s.objectField("messages") catch return error.WriteFailed;
    s.beginArray() catch return error.WriteFailed;
    for (messages) |msg| {
        try writeMessage(&s, msg);
    }
    s.endArray() catch return error.WriteFailed;

    if (tools.len > 0) {
        s.objectField("tools") catch return error.WriteFailed;
        s.beginArray() catch return error.WriteFailed;
        for (tools) |t| {
            try writeToolDef(&s, t.definition);
        }
        s.endArray() catch return error.WriteFailed;
    }

    s.endObject() catch return error.WriteFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeMessage(s: *std.json.Stringify, msg: message.Message) Error!void {
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
            // OpenAI accepts content null or string when tool_calls are present.
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

fn writeToolDef(s: *std.json.Stringify, def: tool.Definition) Error!void {
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
    // Embed pre-serialized schema without re-escaping structure incorrectly:
    // write as raw JSON value.
    s.print("{s}", .{def.parameters_json}) catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
}

fn parseAssistantTurn(allocator: std.mem.Allocator, body: []const u8) !message.AssistantTurn {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    // Intentionally not deinit'ing: we dupe what we need into `allocator` which
    // is typically an arena that frees everything together. If using GPA, the
    // Parsed arena would leak — callers must pass an arena.
    //
    // We still need Parsed's allocations for nested string slices during copy.
    // parseFromSlice with arena allocator: both Parsed and dupes use same arena.
    // So skip explicit deinit when allocator is arena-backed.
    // For safety with GPA tests, deinit after copying:
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidResponse;

    const first = choices.array.items[0];
    if (first != .object) return error.InvalidResponse;

    const finish_reason = blk: {
        if (first.object.get("finish_reason")) |fr| {
            if (fr == .string) break :blk try allocator.dupe(u8, fr.string);
        }
        break :blk try allocator.dupe(u8, "");
    };

    const msg_val = first.object.get("message") orelse return error.InvalidResponse;
    if (msg_val != .object) return error.InvalidResponse;

    const content = blk: {
        if (msg_val.object.get("content")) |c| {
            switch (c) {
                .string => |s| break :blk try allocator.dupe(u8, s),
                .null => break :blk try allocator.dupe(u8, ""),
                else => return error.InvalidResponse,
            }
        }
        break :blk try allocator.dupe(u8, "");
    };

    var tool_calls: []message.ToolCall = &.{};
    if (msg_val.object.get("tool_calls")) |tc_val| {
        if (tc_val == .array and tc_val.array.items.len > 0) {
            const slice = try allocator.alloc(message.ToolCall, tc_val.array.items.len);
            for (tc_val.array.items, 0..) |item, i| {
                if (item != .object) return error.InvalidResponse;
                const id = item.object.get("id") orelse return error.InvalidResponse;
                if (id != .string) return error.InvalidResponse;
                const fn_val = item.object.get("function") orelse return error.InvalidResponse;
                if (fn_val != .object) return error.InvalidResponse;
                const name = fn_val.object.get("name") orelse return error.InvalidResponse;
                if (name != .string) return error.InvalidResponse;
                const args = fn_val.object.get("arguments") orelse return error.InvalidResponse;
                if (args != .string) return error.InvalidResponse;

                slice[i] = .{
                    .id = try allocator.dupe(u8, id.string),
                    .name = try allocator.dupe(u8, name.string),
                    .arguments = try allocator.dupe(u8, args.string),
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

test "parse assistant text turn" {
    const gpa = std.testing.allocator;
    const body =
        \\{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"hello"}}]}
    ;
    const turn = try parseAssistantTurn(gpa, body);
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
    try std.testing.expectEqualStrings("hello", turn.content);
    try std.testing.expectEqual(@as(usize, 0), turn.tool_calls.len);
}

test "parse assistant tool_calls turn" {
    const gpa = std.testing.allocator;
    const body =
        \\{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"list_dir","arguments":"{\"path\":\".\"}"}}]}}]}
    ;
    const turn = try parseAssistantTurn(gpa, body);
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
}

test "buildRequestBody includes tools" {
    const gpa = std.testing.allocator;
    const tools = [_]tool.Tool{.{
        .definition = .{
            .name = "list_dir",
            .description = "list",
            .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        },
        .handler = undefined,
    }};
    const msgs = [_]message.Message{message.Message.user("hi")};
    const body = try buildRequestBody(gpa, "test-model", &msgs, &tools);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "list_dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "test-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}
