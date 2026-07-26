//! Slow OpenAI-compatible loopback mock for the cli-sigint-001 process fixture.
//!
//! Like `headless_mock_server.zig` but deliberately stalls **before** writing the
//! HTTP response head, so a std-backend provider request remains blocked in
//! `receiveHead` (the response-head phase). This lets the process fixture
//! exercise the active second-SIGINT hard-exit (130) path without real network
//! or credentials.
//!
//! Flags: `--port-file PATH` writes the ephemeral port; `--stall-ms N` sets the
//! pre-response-head stall (default 20000ms). Handles exactly one request.

const std = @import("std");
const Io = std.Io;

const json_response_body =
    \\{"id":"slow-1","object":"chat.completion","created":1,"model":"slow","choices":[{"index":0,"message":{"role":"assistant","content":"slow"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
;

fn usage() void {
    std.log.err("usage: sigint-slow-mock --port-file PATH [--stall-ms N]", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var port_file: ?[]const u8 = null;
    var stall_ms: u64 = 20_000;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port-file")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return error.MissingPortFile;
            }
            port_file = args[i];
        } else if (std.mem.eql(u8, a, "--stall-ms")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return error.MissingStallMs;
            }
            stall_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                usage();
                return error.BadStallMs;
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            usage();
            return error.UnknownFlag;
        } else {
            usage();
            return error.UnknownArg;
        }
    }
    const pf = port_file orelse {
        usage();
        return error.MissingPortFile;
    };

    var addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    {
        const port_text = try std.fmt.allocPrint(gpa, "{d}\n", .{port});
        defer gpa.free(port_text);
        var file = try Io.Dir.cwd().createFile(io, pf, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, port_text);
    }

    var conn = try server.accept(io);
    defer conn.close(io);

    // Read request headers until the empty CRLF line.
    var req_buf: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.reader(conn, io, &req_buf);
    var expect_100_continue = false;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const is_empty_crlf = line.len == 2 and std.mem.eql(u8, line, "\r\n");
        if (is_empty_crlf) break;
        if (line.len == 1 and line[0] == '\n') break;
        if (std.mem.indexOf(u8, line, "Expect: 100-continue") != null) {
            expect_100_continue = true;
        }
    }

    var write_buf: [8192]u8 = undefined;
    if (expect_100_continue) {
        var continue_writer = std.Io.net.Stream.writer(conn, io, &write_buf);
        try continue_writer.interface.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        try continue_writer.interface.flush();
    }

    // Deterministic stall: block before the response head so a std-backend
    // request stays in receiveHead. Real-time (not awake) so it advances even
    // when the process is otherwise idle.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(stall_ms)), .real) catch {};

    const response = try std.fmt.allocPrint(gpa,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ json_response_body.len, json_response_body },
    );
    defer gpa.free(response);

    var writer = std.Io.net.Stream.writer(conn, io, &write_buf);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}