const std = @import("std");
const transport_mod = @import("../transport/http.zig");
const errors = @import("../errors.zig");

pub const StreamDoneHandler = *const fn (?*anyopaque) errors.Error!void;

/// Send a JSON request and parse into the provided type.
pub inline fn sendJsonTyped(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    value: anytype,
    comptime T: type,
) errors.Error!std.json.Parsed(T) {
    return sendJsonTypedWithOptions(transport, allocator, method, path, value, T, null);
}

pub inline fn sendJsonTypedWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    value: anytype,
    comptime T: type,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!std.json.Parsed(T) {
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    var json_stream: std.json.Stringify = .{
        .writer = &body_writer.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    json_stream.write(value) catch {
        return errors.Error.SerializeError;
    };
    const payload = body_writer.written();

    const resp = try transport.requestWithOptions(method, path, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    }, payload, req_opts);
    const body = resp.body;
    defer transport.allocator.free(body);

    const parsed = std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errors.Error.DeserializeError;
    };
    return parsed;
}

/// Send a request without a body and parse into the provided type.
pub inline fn sendNoBodyTyped(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    comptime T: type,
) errors.Error!std.json.Parsed(T) {
    return sendNoBodyTypedWithOptions(transport, allocator, method, path, T, null);
}

pub inline fn sendRawJsonTyped(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    payload: ?[]const u8,
    comptime T: type,
) errors.Error!std.json.Parsed(T) {
    return sendRawJsonTypedWithOptions(transport, allocator, method, path, payload, T, null);
}

pub fn sendRawJsonTypedWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    payload: ?[]const u8,
    comptime T: type,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!std.json.Parsed(T) {
    const resp = try transport.requestWithOptions(method, path, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    }, payload, req_opts);

    const body = resp.body;
    defer transport.allocator.free(body);

    const parsed = std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errors.Error.DeserializeError;
    };
    return parsed;
}

pub fn sendMultipartTyped(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    payload: anytype,
    comptime T: type,
) errors.Error!std.json.Parsed(T) {
    return sendMultipartTypedWithOptions(transport, allocator, method, path, payload, T, null);
}

pub fn sendMultipartTypedWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    payload: anytype,
    comptime T: type,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!std.json.Parsed(T) {
    const resp = try transport.requestWithOptions(
        method,
        path,
        &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = payload.content_type },
        },
        payload.body,
        req_opts,
    );
    const body = resp.body;
    defer transport.allocator.free(body);

    const parsed = std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errors.Error.DeserializeError;
    };
    return parsed;
}

pub inline fn sendNoBodyTypedWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    comptime T: type,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!std.json.Parsed(T) {
    const resp = try transport.requestWithOptions(method, path, &.{
        .{ .name = "Accept", .value = "application/json" },
    }, null, req_opts);
    const body = resp.body;
    defer transport.allocator.free(body);

    const parsed = std.json.parseFromSlice(T, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errors.Error.DeserializeError;
    };
    return parsed;
}

/// Send a request and return raw response bytes (binary or text payload).
pub inline fn sendBinary(
    transport: *transport_mod.Transport,
    method: std.http.Method,
    path: []const u8,
) errors.Error![]u8 {
    return sendBinaryWithOptions(transport, method, path, &.{}, null, null);
}

/// Send a request with custom headers/payload and return raw response bytes.
pub fn sendBinaryWithOptions(
    transport: *transport_mod.Transport,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error![]u8 {
    const resp = try transport.requestWithOptions(method, path, headers, body, req_opts);
    return resp.body;
}

/// Send a JSON request and parse into std.json.Value, treating empty body as null.
pub fn sendValueOrNullWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!std.json.Parsed(std.json.Value) {
    const resp = try transport.requestWithOptions(method, path, headers, body, req_opts);
    const response_body = resp.body;
    defer transport.allocator.free(response_body);

    const body_to_parse = if (response_body.len == 0) "null" else response_body;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body_to_parse, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return errors.Error.DeserializeError;
    };
    return parsed;
}

/// Send a JSON request and parse into std.json.Value, treating empty body as null.
pub inline fn sendValueOrNull(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
) errors.Error!std.json.Parsed(std.json.Value) {
    return sendValueOrNullWithOptions(transport, allocator, method, path, headers, body, null);
}

pub fn sendStreamTyped(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    comptime T: type,
    on_event: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
    user_ctx: ?*anyopaque,
) errors.Error!void {
    return sendStreamTypedWithDone(
        transport,
        allocator,
        method,
        path,
        headers,
        payload,
        T,
        on_event,
        user_ctx,
        null,
        null,
        null,
    );
}

pub fn sendStreamTypedWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    comptime T: type,
    on_event: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
    user_ctx: ?*anyopaque,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!void {
    return sendStreamTypedWithDoneWithOptions(
        transport,
        allocator,
        method,
        path,
        headers,
        payload,
        T,
        on_event,
        user_ctx,
        null,
        null,
        req_opts,
    );
}

pub fn sendStreamTypedWithDone(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    comptime T: type,
    on_event: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
    user_ctx: ?*anyopaque,
    on_done: ?StreamDoneHandler,
    done_ctx: ?*anyopaque,
) errors.Error!void {
    return sendStreamTypedWithDoneWithOptions(
        transport,
        allocator,
        method,
        path,
        headers,
        payload,
        T,
        on_event,
        user_ctx,
        on_done,
        done_ctx,
        null,
    );
}

pub fn sendStreamTypedWithDoneWithOptions(
    transport: *transport_mod.Transport,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    headers: []const std.http.Header,
    payload: ?[]const u8,
    comptime T: type,
    on_event: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
    user_ctx: ?*anyopaque,
    on_done: ?StreamDoneHandler,
    done_ctx: ?*anyopaque,
    req_opts: ?transport_mod.Transport.RequestOptions,
) errors.Error!void {
    var parser = try StreamEventParser(T).initWithDone(
        allocator,
        on_event,
        user_ctx,
        on_done,
        done_ctx,
    );
    defer parser.deinit();

    try transport.requestStreamWithOptions(
        method,
        path,
        headers,
        payload,
        StreamEventParser(T).onTransportChunk,
        &parser,
        req_opts,
    );
    try parser.flush();
}

fn StreamEventParser(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        handler: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
        user_ctx: ?*anyopaque,
        on_done: ?StreamDoneHandler,
        done_ctx: ?*anyopaque,
        done: bool = false,
        has_dispatched_events: bool = false,
        line_buf: std.ArrayList(u8),
        data_buf: std.ArrayList(u8),
        ready_to_dispatch: bool = false,

        fn init(
            ctx_allocator: std.mem.Allocator,
            handler: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
            callback_ctx: ?*anyopaque,
        ) errors.Error!@This() {
            return @This().initWithDone(ctx_allocator, handler, callback_ctx, null, null);
        }

        fn initWithDone(
            ctx_allocator: std.mem.Allocator,
            handler: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
            callback_ctx: ?*anyopaque,
            on_done: ?StreamDoneHandler,
            done_ctx: ?*anyopaque,
        ) errors.Error!@This() {
            return @This(){
                .allocator = ctx_allocator,
                .handler = handler,
                .user_ctx = callback_ctx,
                .on_done = on_done,
                .done_ctx = done_ctx,
                .line_buf = std.ArrayList(u8).initCapacity(ctx_allocator, 0) catch {
                    return errors.Error.HttpError;
                },
                .data_buf = std.ArrayList(u8).initCapacity(ctx_allocator, 0) catch {
                    return errors.Error.HttpError;
                },
            };
        }

        fn deinit(self: *@This()) void {
            self.line_buf.deinit(self.allocator);
            self.data_buf.deinit(self.allocator);
        }

        fn onTransportChunk(context: ?*anyopaque, chunk: []const u8) errors.Error!void {
            const parser: *@This() = @ptrCast(@alignCast(context.?));
            return parser.onChunk(chunk);
        }

        fn onChunk(self: *@This(), chunk: []const u8) errors.Error!void {
            for (chunk) |byte| {
                if (byte == '\n') {
                    const line = @This().trimLine(self.line_buf.items);
                    try self.consumeLine(line);
                    self.line_buf.clearRetainingCapacity();
                    continue;
                }

                if (byte == '\r') continue;
                self.line_buf.append(self.allocator, byte) catch {
                    return errors.Error.HttpError;
                };
            }
        }

        fn flush(self: *@This()) errors.Error!void {
            // Finish any incomplete line, then dispatch a pending data buffer once
            // (servers often omit a trailing blank line after the final data frame).
            if (self.line_buf.items.len > 0) {
                const line = @This().trimLine(self.line_buf.items);
                try self.consumeLine(line);
                self.line_buf.clearRetainingCapacity();
            }
            if (self.ready_to_dispatch and self.data_buf.items.len > 0) {
                try self.dispatch();
                self.data_buf.clearRetainingCapacity();
                self.ready_to_dispatch = false;
            }
            if (self.data_buf.items.len > 0) {
                // Still holding bytes without a complete frame.
                return errors.Error.HttpError;
            }

            // Strict: require explicit `[DONE]`. Do not fabricate completion.
            if (!self.done) {
                return errors.Error.HttpError;
            }
        }

        fn trimLine(line: []const u8) []const u8 {
            var start: usize = 0;
            while (start < line.len and (line[start] == ' ' or line[start] == '\t')) {
                start += 1;
            }

            var end: usize = line.len;
            while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t')) {
                end -= 1;
            }

            return line[start..end];
        }

        fn consumeLine(self: *@This(), line: []const u8) errors.Error!void {
            if (line.len == 0) {
                if (self.ready_to_dispatch) {
                    try self.dispatch();
                    self.data_buf.clearRetainingCapacity();
                    self.ready_to_dispatch = false;
                }
                return;
            }

            // SSE comments may appear after DONE (EOF padding); ignore only comments/empty.
            if (std.mem.startsWith(u8, line, ":")) return;

            if (!std.mem.startsWith(u8, line, "data:")) {
                // After explicit [DONE], any non-comment protocol line is an error.
                if (self.done) return errors.Error.HttpError;
                return;
            }

            const raw_event_payload = line[5..];
            const event_payload = std.mem.trimStart(u8, raw_event_payload, " \t");
            if (event_payload.len == 0) return;

            // After [DONE], any non-empty data payload is protocol error.
            if (self.done) return errors.Error.HttpError;

            if (self.data_buf.items.len > 0) {
                self.data_buf.append(self.allocator, '\n') catch {
                    return errors.Error.HttpError;
                };
            }
            self.data_buf.appendSlice(self.allocator, event_payload) catch {
                return errors.Error.HttpError;
            };
            self.ready_to_dispatch = true;
        }

        fn dispatch(self: *@This()) errors.Error!void {
            if (self.data_buf.items.len == 0) return;

            const event_payload = std.mem.trim(u8, self.data_buf.items, " \t");
            if (event_payload.len == 0) {
                self.data_buf.clearRetainingCapacity();
                self.ready_to_dispatch = false;
                return;
            }

            if (self.done) return errors.Error.HttpError;

            self.has_dispatched_events = true;

            if (std.mem.eql(u8, event_payload, "[DONE]")) {
                // Exactly once: second [DONE] is an error (done already set above check).
                self.done = true;
                if (self.on_done) |handler| {
                    try handler(self.done_ctx);
                }
                self.data_buf.clearRetainingCapacity();
                self.ready_to_dispatch = false;
                return;
            }

            const parsed = std.json.parseFromSlice(T, self.allocator, event_payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch {
                return errors.Error.DeserializeError;
            };
            defer parsed.deinit();

            try self.handler(self.user_ctx, parsed);
        }
    };
}

/// Test/public helper: feed SSE bytes through the same strict StreamEventParser
/// used by chat completion streams. `T` is the event JSON type.
pub fn feedStrictSseForTest(
    allocator: std.mem.Allocator,
    comptime T: type,
    bytes: []const u8,
    on_event: *const fn (?*anyopaque, std.json.Parsed(T)) errors.Error!void,
    user_ctx: ?*anyopaque,
    on_done: ?StreamDoneHandler,
    done_ctx: ?*anyopaque,
) errors.Error!void {
    var parser = try StreamEventParser(T).initWithDone(allocator, on_event, user_ctx, on_done, done_ctx);
    defer parser.deinit();
    try parser.onChunk(bytes);
    try parser.flush();
}

const SseProbeEvent = struct {
    id: ?[]const u8 = null,
};

fn noopSseEvent(_: ?*anyopaque, p: std.json.Parsed(SseProbeEvent)) errors.Error!void {
    // Parser owns Parsed lifetime (defer deinit in dispatch).
    _ = p;
}

test "sse strict: missing DONE is HttpError" {
    const gpa = std.testing.allocator;
    feedStrictSseForTest(gpa, SseProbeEvent,
        \\data: {"id":"1"}
        \\
    , noopSseEvent, null, null, null) catch |err| {
        try std.testing.expect(err == error.HttpError);
        return;
    };
    return error.TestUnexpectedResult;
}

test "sse strict: DONE then more data is HttpError" {
    const gpa = std.testing.allocator;
    feedStrictSseForTest(gpa, SseProbeEvent,
        \\data: {"id":"1"}
        \\
        \\data: [DONE]
        \\
        \\data: {"id":"2"}
        \\
    , noopSseEvent, null, null, null) catch |err| {
        try std.testing.expect(err == error.HttpError);
        return;
    };
    return error.TestUnexpectedResult;
}

test "sse strict: clean DONE succeeds and on_done once" {
    const gpa = std.testing.allocator;
    var done_count: u32 = 0;
    try feedStrictSseForTest(gpa, SseProbeEvent,
        \\data: {"id":"1"}
        \\
        \\data: [DONE]
        \\
    , noopSseEvent, null, struct {
        fn d(ctx: ?*anyopaque) errors.Error!void {
            const c: *u32 = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
        }
    }.d, &done_count);
    try std.testing.expectEqual(@as(u32, 1), done_count);
}

test "sse strict: unterminated event at EOF is HttpError" {
    const gpa = std.testing.allocator;
    feedStrictSseForTest(gpa, SseProbeEvent,
        \\data: {"id":"1"}
    , noopSseEvent, null, null, null) catch |err| {
        try std.testing.expect(err == error.HttpError);
        return;
    };
    return error.TestUnexpectedResult;
}

test "sse strict: malformed JSON is DeserializeError" {
    const gpa = std.testing.allocator;
    feedStrictSseForTest(gpa, SseProbeEvent,
        \\data: {not-json
        \\
        \\data: [DONE]
        \\
    , noopSseEvent, null, null, null) catch |err| {
        try std.testing.expect(err == error.DeserializeError);
        return;
    };
    return error.TestUnexpectedResult;
}

pub fn appendQueryParam(
    writer: anytype,
    first: *bool,
    key: []const u8,
    value: []const u8,
) errors.Error!void {
    if (first.*) {
        writer.writeAll("?") catch {
            return errors.Error.SerializeError;
        };
        first.* = false;
    } else {
        writer.writeAll("&") catch {
            return errors.Error.SerializeError;
        };
    }
    try writeQueryComponent(writer, key);
    writer.writeAll("=") catch {
        return errors.Error.SerializeError;
    };
    try writeQueryComponent(writer, value);
}

fn writeQueryComponent(
    writer: anytype,
    component: []const u8,
) errors.Error!void {
    const hexdigits = "0123456789ABCDEF";
    for (component) |byte| {
        if (isQueryUnreserved(byte)) {
            writer.writeByte(byte) catch {
                return errors.Error.SerializeError;
            };
            continue;
        }

        const encoded = [_]u8{
            '%',
            hexdigits[(byte >> 4) & 0x0f],
            hexdigits[byte & 0x0f],
        };
        writer.writeAll(&encoded) catch {
            return errors.Error.SerializeError;
        };
    }
}

fn isQueryUnreserved(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '.' or
        byte == '_' or
        byte == '~';
}

pub fn appendOptionalQueryParam(
    writer: anytype,
    first: *bool,
    key: []const u8,
    value: ?[]const u8,
) errors.Error!void {
    if (value) |v| {
        try appendQueryParam(writer, first, key, v);
    }
}

pub fn appendOptionalQueryParamU64(
    writer: anytype,
    first: *bool,
    key: []const u8,
    value: ?u64,
) errors.Error!void {
    if (value) |v| {
        var buf: [32]u8 = undefined;
        const token = std.fmt.bufPrint(&buf, "{d}", .{v}) catch {
            return errors.Error.SerializeError;
        };
        try appendQueryParam(writer, first, key, token);
    }
}

pub fn appendOptionalQueryParamBool(
    writer: anytype,
    first: *bool,
    key: []const u8,
    value: ?bool,
) errors.Error!void {
    if (value) |v| {
        if (v) {
            try appendQueryParam(writer, first, key, "true");
        } else {
            try appendQueryParam(writer, first, key, "false");
        }
    }
}

pub fn appendOptionalQueryParamList(
    writer: anytype,
    first: *bool,
    key: []const u8,
    values: ?[]const []const u8,
) errors.Error!void {
    if (values) |vals| {
        for (vals) |v| {
            try appendQueryParam(writer, first, key, v);
        }
    }
}

pub const MultipartBuilder = struct {
    allocator: std.mem.Allocator,
    boundary: []const u8,
    out: std.ArrayList(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        boundary: []const u8,
    ) errors.Error!@This() {
        const out = std.ArrayList(u8).initCapacity(allocator, 0) catch {
            return errors.Error.HttpError;
        };
        return @This(){
            .allocator = allocator,
            .boundary = boundary,
            .out = out,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.out.deinit(self.allocator);
    }

    pub fn appendTextField(
        self: *@This(),
        name: []const u8,
        value: []const u8,
    ) errors.Error!void {
        self.out.appendSlice(self.allocator, "--") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, self.boundary) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, name) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\"\r\n\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, value) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
    }

    pub fn appendJsonField(
        self: *@This(),
        name: []const u8,
        value: []const u8,
        content_type: []const u8,
    ) errors.Error!void {
        self.out.appendSlice(self.allocator, "--") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, self.boundary) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, name) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\"\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "Content-Type: ") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, content_type) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, value) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
    }

    pub fn appendFileField(
        self: *@This(),
        name: []const u8,
        filename: []const u8,
        content_type: []const u8,
        data: []const u8,
    ) errors.Error!void {
        self.out.appendSlice(self.allocator, "--") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, self.boundary) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "Content-Disposition: form-data; name=\"") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, name) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\"; filename=\"") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, filename) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\"\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "Content-Type: ") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, content_type) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n\r\n") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, data) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "\r\n") catch return errors.Error.SerializeError;
    }

    pub fn appendFooter(self: *@This()) errors.Error!void {
        self.out.appendSlice(self.allocator, "--") catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, self.boundary) catch return errors.Error.SerializeError;
        self.out.appendSlice(self.allocator, "--\r\n") catch return errors.Error.SerializeError;
    }

    pub fn toOwnedSlice(self: *@This()) errors.Error![]u8 {
        return self.out.toOwnedSlice(self.allocator) catch {
            return errors.Error.SerializeError;
        };
    }
};

test "stringify skips null optional fields by default" {
    const Payload = struct {
        keep: []const u8 = "keep-me",
        drop: ?[]const u8 = null,
    };

    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var stream: std.json.Stringify = .{
        .writer = &writer.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try stream.write(Payload{});
    const body = writer.written();
    try std.testing.expectEqualStrings("{\"keep\":\"keep-me\"}", body);
}

test "multipart builder emits boundary and fields consistently" {
    var builder = try MultipartBuilder.init(std.testing.allocator, "----unit");
    defer builder.deinit();

    try builder.appendTextField("field", "value");
    try builder.appendFileField(
        "file",
        "payload.bin",
        "application/octet-stream",
        "DATA",
    );
    try builder.appendFooter();

    const body = try builder.toOwnedSlice();
    defer std.testing.allocator.free(body);

    const expected =
        "--" ++ "----unit" ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n\r\n" ++
        "value\r\n" ++
        "--" ++ "----unit" ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"payload.bin\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n" ++
        "DATA\r\n--" ++ "----unit" ++ "--\r\n";
    try std.testing.expectEqualStrings(expected, body);
}

test "sse parser dispatches on blank line, supports multi data: lines, and [DONE]" {
    const EventPayload = struct {
        a: i64,
        b: i64,
    };

    const State = struct {
        count: usize = 0,
        a: i64 = 0,
        b: i64 = 0,
    };

    var state = State{};

    const Handler = struct {
        fn onEvent(ctx: ?*anyopaque, parsed: std.json.Parsed(EventPayload)) errors.Error!void {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.count += 1;
            s.a = parsed.value.a;
            s.b = parsed.value.b;
        }
    };

    var parser = try StreamEventParser(EventPayload).init(
        std.testing.allocator,
        Handler.onEvent,
        &state,
    );
    defer parser.deinit();

    // SSE multi-line events use multiple `data:` lines (joined with \n).
    try parser.onChunk("data: { \"a\": 1,\r\n");
    try parser.onChunk("data:  \"b\": 2 }\r\n");
    try parser.onChunk("\r\n");
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(@as(i64, 1), state.a);
    try std.testing.expectEqual(@as(i64, 2), state.b);

    try parser.onChunk("data: [DONE]\r\n");
    try parser.onChunk("\r\n");
    try std.testing.expect(parser.done);
    try std.testing.expectEqual(@as(usize, 1), state.count);
}

test "sse parser reports stream completion via done callback" {
    const EventPayload = struct {
        value: i64,
    };

    const State = struct {
        done_called: usize = 0,
        value: i64 = 0,
    };

    var state = State{};

    const Handler = struct {
        fn onEvent(ctx: ?*anyopaque, parsed: std.json.Parsed(EventPayload)) errors.Error!void {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.value = parsed.value.value;
        }
    };

    const DoneHandler = struct {
        fn onDone(ctx: ?*anyopaque) errors.Error!void {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.done_called += 1;
        }
    };

    var parser = try StreamEventParser(EventPayload).initWithDone(
        std.testing.allocator,
        Handler.onEvent,
        &state,
        DoneHandler.onDone,
        &state,
    );
    defer parser.deinit();

    try parser.onChunk("data: {\"value\": 100}\r\n");
    try parser.onChunk("\r\n");
    try parser.onChunk("data: [DONE]\r\n");
    try parser.onChunk("\r\n");
    try std.testing.expectEqual(@as(i64, 100), state.value);
    try std.testing.expectEqual(@as(usize, 1), state.done_called);
    try std.testing.expect(parser.done);
}

test "sse parser requires [DONE]; flush without marker is HttpError" {
    const EventPayload = struct {
        value: i64,
    };

    const State = struct {
        done_called: usize = 0,
        value: i64 = 0,
    };

    var state = State{};

    const Handler = struct {
        fn onEvent(ctx: ?*anyopaque, parsed: std.json.Parsed(EventPayload)) errors.Error!void {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.value = parsed.value.value;
        }
    };

    const DoneHandler = struct {
        fn onDone(ctx: ?*anyopaque) errors.Error!void {
            const s: *State = @ptrCast(@alignCast(ctx.?));
            s.done_called += 1;
        }
    };

    var parser = try StreamEventParser(EventPayload).initWithDone(
        std.testing.allocator,
        Handler.onEvent,
        &state,
        DoneHandler.onDone,
        &state,
    );
    defer parser.deinit();

    try parser.onChunk("data: {\"value\": 100}\r\n");
    try parser.onChunk("\r\n");
    // Strict: do not fabricate completion on EOF without [DONE].
    try std.testing.expectError(error.HttpError, parser.flush());
    try std.testing.expectEqual(@as(i64, 100), state.value);
    try std.testing.expectEqual(@as(usize, 0), state.done_called);
    try std.testing.expect(!parser.done);
}

test "sse parser propagates callback errors" {
    const EventPayload = struct {
        value: []const u8,
    };

    const Handler = struct {
        fn onEvent(_: ?*anyopaque, _: std.json.Parsed(EventPayload)) errors.Error!void {
            return errors.Error.HttpError;
        }
    };

    var parser = try StreamEventParser(EventPayload).init(
        std.testing.allocator,
        Handler.onEvent,
        null,
    );
    defer parser.deinit();

    try std.testing.expectError(
        errors.Error.HttpError,
        parser.onChunk("data: {\"value\":\"boom\"}\r\n\r\n"),
    );
}

test "sse parser converts invalid JSON to DeserializeError" {
    const EventPayload = struct {
        value: i64,
    };

    const ParseState = struct { calls: usize = 0 };
    var parse_state = ParseState{};

    const Handler = struct {
        fn onEvent(ctx: ?*anyopaque, _: std.json.Parsed(EventPayload)) errors.Error!void {
            const state: *ParseState = @ptrCast(@alignCast(ctx.?));
            state.calls += 1;
        }
    };

    var parser = try StreamEventParser(EventPayload).init(
        std.testing.allocator,
        Handler.onEvent,
        &parse_state,
    );
    defer parser.deinit();

    try std.testing.expectError(
        errors.Error.DeserializeError,
        parser.onChunk("data: {\"value\":x}\r\n\r\n"),
    );
    try std.testing.expectEqual(@as(usize, 0), parse_state.calls);
}
