const std = @import("std");
const sdk = @import("openai_zig");
const errors = sdk.errors;
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var conf = try config.loadFromEnvMap(gpa, io, "config/config.toml", init.environ_map);
    defer conf.deinit(gpa);

    if (conf.api_key.len == 0) {
        std.debug.print("API key missing; set OPENAI_API_KEY / DEEPSEEK_API_KEY or config/config.toml\n", .{});
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

    var models = client.models().list_models(gpa) catch |err| {
        if (err == errors.Error.HttpError) {
            std.debug.print("HTTP error (check API key/base URL)\n", .{});
            return;
        }
        return err;
    };
    defer models.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stream.write(models.value);
    std.debug.print("Models list JSON:\n{s}\n", .{out.written()});

    const messages = [_]sdk.resources.chat.ChatMessage{
        .{ .role = "user", .content = "who are you?" },
    };
    var chat = client.chat().create_chat_completion(gpa, .{
        .model = conf.model,
        .messages = &messages,
    }) catch |err| {
        if (err == errors.Error.HttpError) {
            std.debug.print("Chat call failed (HTTP error)\n", .{});
            return;
        }
        return err;
    };
    defer chat.deinit();

    var chat_out: std.Io.Writer.Allocating = .init(gpa);
    defer chat_out.deinit();
    var chat_stream: std.json.Stringify = .{ .writer = &chat_out.writer, .options = .{} };
    try chat_stream.write(chat.value);
    std.debug.print("Chat completion JSON:\n{s}\n", .{chat_out.written()});
}

test "client init/deinit" {
    var client = try sdk.initClient(std.testing.allocator, .{
        .io = std.testing.io,
        .base_url = "https://api.openai.com/v1",
        .api_key = null,
    });
    defer client.deinit();
}
