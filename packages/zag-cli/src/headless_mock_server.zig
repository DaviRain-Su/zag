//! OpenAI-compatible loopback mock HTTP server for the headless-001 and
//! rpc-v1-001 fixtures.
//!
//! Built as a standalone binary by root `build.zig` and driven by
//! `headless_process_fixture.zig` / `rpc_process_fixture.zig`. Writes the
//! ephemeral port to `--port-file`, then serves requests until `--max-requests`
//! is exhausted (0 = until killed).
//!
//! This is a separate process so that the fixture can run the real `zag`
//! binary against a loopback server without needing external network or
//! threading the Zig 0.16 `Io.Threaded` runtime.
//!
/// Modes (additive; default behavior is byte-identical to the original):
///   `--echo`        respond with the LAST user message content from the
///                   request body (stream and non-stream), so a fixture can
///                   prove steered text reached the next model turn.
///   `--tool-call`   request #1 responds with a `write_file` tool call whose
///                   arguments carry the echoed user text; every later
///                   request responds with the echoed final text ("tool done").
///                   Drives the rpc permission-gate flow end to end.
///   `--stall-ms N`  sleep N ms before writing the response head (default 0);
///                   pairs with `--ready-file` for deterministic busy timing.
///   `--ready-file`  write a one-line marker AFTER the full request is
///                   consumed and any 100-continue handshake is sent, but
///                   BEFORE the stall — the fixture's in-flight handshake.

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

/// Last user message content from an OpenAI-style chat request body.
fn lastUserText(gpa: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const msgs = root.object.get("messages") orelse return null;
    if (msgs != .array) return null;
    var last: ?[]const u8 = null;
    for (msgs.array.items) |m| {
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = m.object.get("content") orelse continue;
        if (content != .string) continue;
        last = content.string;
    }
    return last;
}

/// Explicit empty OBJECT for SSE deltas — an anonymous `{}` literal would
/// infer as an empty tuple and serialize as `[]` (invalid for delta).
const EmptyDelta = struct {};

fn writeSseData(out: *std.Io.Writer.Allocating, value: anytype) !void {
    try out.writer.writeAll("data: ");
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
    try out.writer.writeAll("\n\n");
}

fn writeJson(out: *std.Io.Writer.Allocating, value: anytype) !void {
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
}

/// JSON body for a tool-call request: `{"path": "rpc_fixture_out.txt",
/// "content": "<echoed>"}`.
fn toolArgsJson(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("path");
    try jw.write("rpc_fixture_out.txt");
    try jw.objectField("content");
    try jw.write(text);
    try jw.endObject();
    return gpa.dupe(u8, out.written());
}

/// Build one chat response body. `echo_text` is the last user content
/// (when --echo / --tool-call); `serve_index` counts accepted connections.
fn buildResponseBody(
    gpa: std.mem.Allocator,
    stream: bool,
    echo_text: ?[]const u8,
    tool_call: bool,
    serve_index: usize,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const wants_tool_call = tool_call and serve_index == 0;
    const text = echo_text orelse "Hello from mock";
    var final_text: []const u8 = text;
    var owned_final: ?[]u8 = null;
    if (tool_call) {
        owned_final = try std.fmt.allocPrint(gpa, "tool done: {s}", .{text});
        final_text = owned_final.?;
    }
    defer if (owned_final) |f| gpa.free(f);

    if (wants_tool_call) {
        const args_json = try toolArgsJson(gpa, text);
        defer gpa.free(args_json);
        if (stream) {
            try writeSseData(&body, .{
                .id = "r1", .object = "chat.completion.chunk", .created = @as(u32, 1), .model = "mock-model",
                .choices = &.{.{ .index = @as(u32, 0), .delta = .{
                    .role = "assistant",
                    .tool_calls = &.{.{ .index = @as(u32, 0), .id = "call_rpc_1", .type = "function", .function = .{ .name = "write_file", .arguments = "" } } },
                }, .finish_reason = null } },
            });
            try writeSseData(&body, .{
                .id = "r1", .object = "chat.completion.chunk", .created = @as(u32, 1), .model = "mock-model",
                .choices = &.{.{ .index = @as(u32, 0), .delta = .{
                    .tool_calls = &.{.{ .index = @as(u32, 0), .function = .{ .arguments = args_json } } },
                }, .finish_reason = null } },
            });
            try writeSseData(&body, .{
                .id = "r1", .object = "chat.completion.chunk", .created = @as(u32, 1), .model = "mock-model",
                .choices = &.{.{ .index = @as(u32, 0), .delta = EmptyDelta{}, .finish_reason = "tool_calls" } },
            });
            try body.writer.writeAll("data: [DONE]\n\n");
        } else {
            try writeJson(&body, .{
                .id = "r1", .object = "chat.completion", .created = @as(u32, 1), .model = "mock-model",
                .choices = &.{.{ .index = @as(u32, 0), .message = .{
                    .role = "assistant", .content = "",
                    .tool_calls = &.{.{ .id = "call_rpc_1", .type = "function", .function = .{ .name = "write_file", .arguments = args_json } } },
                }, .finish_reason = "tool_calls" } },
            });
        }
        return gpa.dupe(u8, body.written());
    }

    if (stream) {
        try writeSseData(&body, .{
            .id = "r1", .object = "chat.completion.chunk", .created = @as(u32, 1), .model = "mock-model",
            .choices = &.{.{ .index = @as(u32, 0), .delta = .{ .role = "assistant", .content = final_text }, .finish_reason = null } },
        });
        try writeSseData(&body, .{
            .id = "r1", .object = "chat.completion.chunk", .created = @as(u32, 1), .model = "mock-model",
            .choices = &.{.{ .index = @as(u32, 0), .delta = EmptyDelta{}, .finish_reason = "stop" } },
        });
        try body.writer.writeAll("data: [DONE]\n\n");
    } else {
        try writeJson(&body, .{
            .id = "r1", .object = "chat.completion", .created = @as(u32, 1), .model = "mock-model",
            .choices = &.{.{ .index = @as(u32, 0), .message = .{ .role = "assistant", .content = final_text }, .finish_reason = "stop" } },
            .usage = .{ .prompt_tokens = @as(u32, 1), .completion_tokens = @as(u32, 1), .total_tokens = @as(u32, 2) },
        });
    }
    return gpa.dupe(u8, body.written());
}

fn buildResponse(
    gpa: std.mem.Allocator,
    stream: bool,
    echo_text: ?[]const u8,
    tool_call: bool,
    serve_index: usize,
) ![]u8 {
    const body = try buildResponseBody(gpa, stream, echo_text, tool_call, serve_index);
    defer gpa.free(body);
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
    std.log.err("usage: headless-mock-server --port-file PATH [--stream] [--max-requests N] [--echo] [--tool-call] [--stall-ms N] [--ready-file PATH]", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var port_file: ?[]const u8 = null;
    var force_stream = false;
    var max_requests: usize = 1; // legacy default: single request then exit
    var echo_mode = false;
    var tool_call_mode = false;
    var stall_ms: u64 = 0;
    var ready_file: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--echo")) {
            echo_mode = true;
        } else if (std.mem.eql(u8, a, "--tool-call")) {
            tool_call_mode = true;
        } else if (std.mem.eql(u8, a, "--stall-ms")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return error.MissingStallMs;
            }
            stall_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                usage();
                return error.InvalidStallMs;
            };
        } else if (std.mem.eql(u8, a, "--ready-file")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return error.MissingReadyFile;
            }
            ready_file = args[i];
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
        var echo_text: ?[]const u8 = null;
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
                if (echo_mode or tool_call_mode) {
                    echo_text = lastUserText(gpa, body);
                }
            }
        }

        // Deterministic in-flight handshake (sigint_slow_mock pattern): the
        // marker appears AFTER the full request is consumed and the
        // 100-continue is sent, but BEFORE the stall — the fixture waits on it
        // to know the provider request is now in flight.
        if (ready_file) |rf| {
            const ready_text = "ready\n";
            var rfile = try Io.Dir.cwd().createFile(io, rf, .{});
            defer rfile.close(io);
            try rfile.writeStreamingAll(io, ready_text);
        }

        if (stall_ms > 0) {
            // Block before the response head so a std-backend request stays in
            // receiveHead (real-time so it advances while the process idles).
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(stall_ms)), .real) catch {};
        }

        const response = try buildResponse(gpa, wants_stream, echo_text, tool_call_mode, served);
        defer gpa.free(response);

        var writer = std.Io.net.Stream.writer(conn, io, &write_buf);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
        // Give the client a moment to drain the kernel socket buffer before we
        // close the connection; this avoids spurious ECONNRESET during streaming.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
    }
}
