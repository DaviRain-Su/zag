const std = @import("std");
const sdk = @import("openai_zig");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var conf = try config.loadFromEnvMap(gpa, io, "config/config.toml", init.environ_map);
    defer conf.deinit(gpa);

    if (conf.api_key.len == 0) {
        std.debug.print("API key missing\n", .{});
        return;
    }

    var client = try sdk.initClient(gpa, .{
        .io = io,
        .base_url = conf.base_url,
        .api_key = conf.api_key,
        .timeout_ms = conf.timeout_ms,
        .organization = conf.organization,
        .project = conf.project,
        .max_retries = conf.max_retries,
        .retry_base_delay_ms = conf.retry_base_delay_ms,
    });
    defer client.deinit();

    const messages = [_]sdk.resources.chat.ChatMessage{ .{ .role = "user", .content = "用中文说你是谁" } };
    var body_writer: std.Io.Writer.Allocating = .init(gpa);
    defer body_writer.deinit();
    const req = struct {
        model: []const u8,
        messages: []const sdk.resources.chat.ChatMessage,
    }{ .model = conf.model, .messages = &messages };
    { var __js: std.json.Stringify = .{ .writer = &body_writer.writer, .options = .{} }; try __js.write(req); }
    const payload = body_writer.written();

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const transport = client.raw_transport();
    const resp = try transport.request(.POST, "/chat/completions", &headers, payload);
    defer transport.allocator.free(resp.body);

    std.debug.print("status={d}\n", .{resp.status});
    std.debug.print("body={s}\n", .{resp.body});

    const val = try std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{ .ignore_unknown_fields = true });
    defer val.deinit();

    const typed = std.json.parseFromSlice(sdk.generated.CreateChatCompletionResponse, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("typed parse err: {}\\n", .{err});
        return;
    };
    defer typed.deinit();

    std.debug.print("typed ok id={s} choices={d}\n", .{ typed.value.id, typed.value.choices.len });
}
