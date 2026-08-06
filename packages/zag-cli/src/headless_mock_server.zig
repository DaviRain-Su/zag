//! OpenAI-compatible loopback mock HTTP server for the headless-001 fixture.
//!
//! Built as a standalone binary by root `build.zig` and driven by
//! `headless_process_fixture.zig`. Handles exactly one request, writes the
//! ephemeral port to `--port-file`, then exits after responding.
//!
//! This is a separate process so that the fixture can run the real `zag`
//! binary against a loopback server without needing external network or
//! threading the Zig 0.16 `Io.Threaded` runtime.

const std = @import("std");
const Io = std.Io;

const json_response_body =
    \\{"id":"mock-1","object":"chat.completion","created":1,"model":"mock-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello from mock"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":5,"total_tokens":6}}
;

const stream_response_body =
    \\data: {"id":"mock-1","object":"chat.completion.chunk","created":1,"model":"mock-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello from mock"},"finish_reason":null}]}
    \\
    \\data: {"id":"mock-1","object":"chat.completion.chunk","created":1,"model":"mock-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    \\
    \\data: [DONE]
    \\
;

fn buildResponse(gpa: std.mem.Allocator, stream: bool) ![]u8 {
    const body = if (stream) stream_response_body else json_response_body;
    return std.fmt.allocPrint(
        gpa,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{
            if (stream) "text/event-stream" else "application/json",
            body.len,
            body,
        },
    );
}

fn usage() void {
    std.log.err("usage: headless-mock-server --port-file PATH [--stream] [--max-requests N]", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var port_file: ?[]const u8 = null;
    var force_stream = false;
    var max_requests: usize = 1; // legacy default: single request then exit
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
        } else if (std.mem.eql(u8, a, "--stream")) {
            force_stream = true;
        } else if (std.mem.eql(u8, a, "--max-requests")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return error.MissingMaxRequests;
            }
            max_requests = std.fmt.parseInt(usize, args[i], 10) catch {
                usage();
                return error.InvalidMaxRequests;
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

    // Publish the ephemeral port so the parent fixture can point `zag` at it.
    {
        const port_text = try std.fmt.allocPrint(gpa, "{d}\n", .{port});
        defer gpa.free(port_text);
        var file = try Io.Dir.cwd().createFile(io, pf, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, port_text);
    }

    // Serve up to max_requests (0 = until killed): the TUI startup /models
    // probe (curl backend) consumes one request before the fixture's chat
    // request — a single-shot server would exit after the probe and drop
    // the chat connection (gate33 curl regression).
    var served: usize = 0;
    while (max_requests == 0 or served < max_requests) : (served += 1) {
        var conn = try server.accept(io);
        defer conn.close(io);

        // Read headers line-by-line until the empty CRLF line. `takeDelimiterInclusive`
        // is efficient with the reader's internal buffer, unlike byte-at-a-time reads.
        var req_buf: [8192]u8 = undefined;
        var reader = std.Io.net.Stream.reader(conn, io, &req_buf);
        var expect_100_continue = false;
        var content_length: usize = 0;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            // Empty line marks end of headers: "\r\n" or "\n".
            const is_empty_crlf = line.len == 2 and std.mem.eql(u8, line, "\r\n");
            if (is_empty_crlf) break;
            if (line.len == 1 and line[0] == '\n') break;
            if (std.ascii.indexOfIgnoreCase(line, "expect: 100-continue") != null) {
                expect_100_continue = true;
            }
            if (std.ascii.indexOfIgnoreCase(line, "content-length:")) |idx| {
                content_length = std.fmt.parseInt(
                    usize,
                    std.mem.trim(u8, line[idx + "content-length:".len ..], " \r\n"),
                    10,
                ) catch 0;
            }
        }

        var write_buf: [8192]u8 = undefined;

        // Some HTTP clients (e.g. Zig's std.http) send `Expect: 100-continue` on
        // POST requests and wait for a provisional response before uploading the
        // body. Reply with `100 Continue` so the client sends the rest.
        if (expect_100_continue) {
            var continue_writer = std.Io.net.Stream.writer(conn, io, &write_buf);
            try continue_writer.interface.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
            try continue_writer.interface.flush();
        }

        // Mirror real providers: the client streams by default (tui-streaming-001),
        // so a request asking for `"stream":true` gets the SSE response. `--stream`
        // still forces SSE regardless of the request body.
        var wants_stream = force_stream;
        if (content_length > 0 and content_length <= 1024 * 1024) {
            const body = try gpa.alloc(u8, content_length);
            defer gpa.free(body);
            const full_body = blk: {
                reader.interface.readSliceAll(body) catch |err| switch (err) {
                    error.EndOfStream => break :blk false,
                    else => return err,
                };
                break :blk true;
            };
            if (full_body) {
                wants_stream = wants_stream or
                    std.mem.indexOf(u8, body, "\"stream\":true") != null or
                    std.mem.indexOf(u8, body, "\"stream\": true") != null;
            }
        }

        const response = try buildResponse(gpa, wants_stream);
        defer gpa.free(response);

        var writer = std.Io.net.Stream.writer(conn, io, &write_buf);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
        // Give the client a moment to drain the kernel socket buffer before we
        // close the connection; this avoids spurious ECONNRESET during streaming.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
    }
}
