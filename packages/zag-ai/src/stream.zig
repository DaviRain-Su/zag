//! OpenAI-compatible SSE streaming for chat completions.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const types = @import("types.zig");
const openai_compat = @import("openai_compat.zig");

pub const Error = openai_compat.Error;
pub const Handler = *const fn (ctx: ?*anyopaque, event: types.StreamEvent) anyerror!void;

/// Stream a chat completion; returns the assembled final turn (strings in `arena`).
pub fn chatStream(
    client: *openai_compat.Client,
    arena: std.mem.Allocator,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
) Error!types.AssistantTurn {
    const body = try openai_compat.buildRequestBodyForStream(arena, client.config.model, messages, tools);
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
        trimTrailingSlash(client.config.base_url),
    });
    const auth_value = try std.fmt.allocPrint(arena, "Bearer {s}", .{client.config.api_key});

    const uri = std.Uri.parse(url) catch return error.Unexpected;
    var req = client.http_client.request(.POST, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_value },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "text/event-stream" },
        },
    }) catch return error.HttpFailed;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var send_body = req.sendBodyUnflushed(&.{}) catch return error.HttpFailed;
    send_body.writer.writeAll(body) catch return error.HttpFailed;
    send_body.end() catch return error.HttpFailed;
    req.connection.?.flush() catch return error.HttpFailed;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpFailed;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;

    var transfer_buf: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &.{});

    var acc = Accumulator.init(arena);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(client.allocator);

    while (true) {
        var tmp: [1024]u8 = undefined;
        const n = reader.readSliceShort(&tmp) catch return error.StreamFailed;
        if (n == 0) break;
        appendAndProcess(client.allocator, &line_buf, tmp[0..n], &acc, handler, handler_ctx) catch
            return error.StreamFailed;
    }
    if (line_buf.items.len > 0) {
        processSseLine(line_buf.items, &acc, handler, handler_ctx) catch return error.StreamFailed;
    }

    if (handler) |h| {
        h(handler_ctx, .done) catch return error.StreamFailed;
    }

    return acc.finish(arena) catch return error.OutOfMemory;
}

const Accumulator = struct {
    content: std.ArrayList(u8) = .empty,
    tool_ids: std.ArrayList([]const u8) = .empty,
    tool_names: std.ArrayList([]const u8) = .empty,
    tool_args: std.ArrayList(std.ArrayList(u8)) = .empty,
    finish_reason: []const u8 = "",
    arena: std.mem.Allocator,

    fn init(arena: std.mem.Allocator) Accumulator {
        return .{ .arena = arena };
    }

    fn ensureToolSlot(self: *Accumulator, index: usize) !void {
        while (self.tool_ids.items.len <= index) {
            try self.tool_ids.append(self.arena, "");
            try self.tool_names.append(self.arena, "");
            try self.tool_args.append(self.arena, .empty);
        }
    }

    fn finish(self: *Accumulator, arena: std.mem.Allocator) !types.AssistantTurn {
        const content = try arena.dupe(u8, self.content.items);
        const fr = try arena.dupe(u8, self.finish_reason);
        if (self.tool_ids.items.len == 0) {
            return .{ .content = content, .tool_calls = &.{}, .finish_reason = fr };
        }
        const calls = try arena.alloc(types.ToolCall, self.tool_ids.items.len);
        for (0..self.tool_ids.items.len) |i| {
            calls[i] = .{
                .id = try arena.dupe(u8, self.tool_ids.items[i]),
                .name = try arena.dupe(u8, self.tool_names.items[i]),
                .arguments = try arena.dupe(u8, self.tool_args.items[i].items),
            };
        }
        return .{ .content = content, .tool_calls = calls, .finish_reason = fr };
    }
};

fn appendAndProcess(
    gpa: std.mem.Allocator,
    line_buf: *std.ArrayList(u8),
    chunk: []const u8,
    acc: *Accumulator,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
) Error!void {
    line_buf.appendSlice(gpa, chunk) catch return error.OutOfMemory;
    while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl| {
        var line = line_buf.items[0..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try processSseLine(line, acc, handler, handler_ctx);
        const rest = line_buf.items[nl + 1 ..];
        std.mem.copyForwards(u8, line_buf.items, rest);
        line_buf.shrinkRetainingCapacity(rest.len);
    }
}

fn processSseLine(
    line: []const u8,
    acc: *Accumulator,
    handler: ?Handler,
    handler_ctx: ?*anyopaque,
) Error!void {
    if (line.len == 0) return;
    if (!std.mem.startsWith(u8, line, "data:")) return;
    const data = std.mem.trim(u8, line["data:".len..], " \t");
    if (std.mem.eql(u8, data, "[DONE]")) return;

    const root = std.json.parseFromSliceLeaky(std.json.Value, acc.arena, data, .{}) catch return;
    if (root != .object) return;
    const choices = root.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const first = choices.array.items[0];
    if (first != .object) return;

    if (first.object.get("finish_reason")) |fr| {
        if (fr == .string and fr.string.len > 0) {
            acc.finish_reason = try acc.arena.dupe(u8, fr.string);
            if (handler) |h| {
                h(handler_ctx, .{ .finish_reason = acc.finish_reason }) catch return error.StreamFailed;
            }
        }
    }

    const delta = first.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            acc.content.appendSlice(acc.arena, c.string) catch return error.OutOfMemory;
            if (handler) |h| {
                h(handler_ctx, .{ .content_delta = c.string }) catch return error.StreamFailed;
            }
        }
    }

    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs != .array) return;
        for (tcs.array.items) |item| {
            if (item != .object) continue;
            const idx_v = item.object.get("index") orelse continue;
            const index: usize = switch (idx_v) {
                .integer => |i| @intCast(i),
                else => continue,
            };
            acc.ensureToolSlot(index) catch return error.OutOfMemory;

            if (item.object.get("id")) |idv| {
                if (idv == .string and idv.string.len > 0) {
                    acc.tool_ids.items[index] = try acc.arena.dupe(u8, idv.string);
                }
            }
            if (item.object.get("function")) |fnv| {
                if (fnv != .object) continue;
                if (fnv.object.get("name")) |nv| {
                    if (nv == .string and nv.string.len > 0) {
                        acc.tool_names.items[index] = try acc.arena.dupe(u8, nv.string);
                    }
                }
                if (fnv.object.get("arguments")) |av| {
                    if (av == .string and av.string.len > 0) {
                        acc.tool_args.items[index].appendSlice(acc.arena, av.string) catch
                            return error.OutOfMemory;
                        if (handler) |h| {
                            h(handler_ctx, .{
                                .tool_call_delta = .{
                                    .index = index,
                                    .id = acc.tool_ids.items[index],
                                    .name = acc.tool_names.items[index],
                                    .arguments_delta = av.string,
                                },
                            }) catch return error.StreamFailed;
                        }
                    }
                }
            }
        }
    }
}

fn trimTrailingSlash(url: []const u8) []const u8 {
    if (url.len > 0 and url[url.len - 1] == '/') return url[0 .. url.len - 1];
    return url;
}

test "process content delta sse line" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    var acc = Accumulator.init(arena);
    const line =
        \\data: {"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}
    ;
    try processSseLine(line, &acc, null, null);
    try std.testing.expectEqualStrings("hi", acc.content.items);
}
