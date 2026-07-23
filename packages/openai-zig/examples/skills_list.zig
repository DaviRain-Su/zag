const std = @import("std");
const sdk = @import("openai_zig");
const config = @import("config");
const compat = @import("provider_compat");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var conf = try config.loadFromEnvMap(gpa, io, "config/config.toml", init.environ_map);
    defer conf.deinit(gpa);

    if (conf.api_key.len == 0) {
        std.debug.print("API key missing; set OPENAI_API_KEY or config/config.toml\n", .{});
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

    if (compat.skipIfDeepSeek(conf.base_url, "skills")) return;

    var listed = client.skills().list(gpa, .{ .limit = 20 }) catch |err| {
        std.debug.print("Skills list failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer listed.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stream.write(listed.value);
    std.debug.print("Skills list:\n{s}\n", .{out.written()});
}
