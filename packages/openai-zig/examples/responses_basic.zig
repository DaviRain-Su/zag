const std = @import("std");
const sdk = @import("openai_zig");
const errors = sdk.errors;
const config = @import("config");
const compat = @import("provider_compat");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var conf = try config.loadFromEnvMap(gpa, io, "config/config.toml", init.environ_map);
    defer conf.deinit(gpa);

    if (conf.api_key.len == 0) {
        std.debug.print("API key missing; set config/config.toml\n", .{});
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

    if (compat.skipIfDeepSeek(conf.base_url, "responses")) return;

    const request: sdk.generated.CreateResponse = .{
        .model = .{ .string = conf.model },
        .input = .{ .string = "用中文写一个三行短诗" },
        .stream = .{ .bool = false },
    };

    const response = client.responses().create(gpa, request) catch |err| {
        switch (err) {
            errors.Error.NotFoundError => {
                std.debug.print("responses endpoint unavailable on this provider (HTTP 404).\n", .{});
                return;
            },
            errors.Error.BadRequestError => {
                std.debug.print("responses request invalid (check model/input schema).\n", .{});
                return;
            },
            errors.Error.HttpError => {
                std.debug.print("responses request failed with HTTP-level error.\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer response.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stream.write(response.value);

    std.debug.print("Responses create:\n{s}\n", .{out.written()});
}
