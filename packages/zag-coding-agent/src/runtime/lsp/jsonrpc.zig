//! Minimal JSON-RPC 2.0 framing for the LSP base protocol (lsp-001).
//!
//! Hand-rolled, MIT-clean (no vendored LSP client): header framing
//! (`Content-Length: <N>\r\n\r\n` + body), a streaming decoder with hard
//! caps (header line 4 KiB, message 8 MiB), and message classification
//! (request / response / notification). No pipelining: ids are strictly
//! increasing integers starting at 1, one outstanding request at a time.
//!
//! Owned by `zag-coding-agent` (D-012 law — nothing here reaches
//! `zag-agent-core`).
//!
//! Ownership: `Message` variants own their parsed JSON tree (`parsed`) and
//! duped method strings. `deinitMessage` frees them. A response whose tree
//! was moved out (matched a pending request) has `parsed == null`; callers
//! transfer the whole response struct and eventually call `deinitResponse`.

const std = @import("std");

pub const max_header_line_bytes: usize = 4 * 1024;
pub const max_message_bytes: usize = 8 * 1024 * 1024;
pub const framing_header = "Content-Length: ";

pub const RpcError = struct {
    code: i64,
    message: []const u8,
};

pub const Request = struct {
    id: u64,
    method: []u8,
    params: ?std.json.Value,
    parsed: ?std.json.Parsed(std.json.Value),
};

pub const Response = struct {
    id: u64,
    result: ?std.json.Value,
    err: ?RpcError,
    /// Owned parsed tree; null when moved out by the dispatcher.
    parsed: ?std.json.Parsed(std.json.Value),
};

pub const Notification = struct {
    method: []u8,
    params: ?std.json.Value,
    parsed: ?std.json.Parsed(std.json.Value),
};

pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

/// JSON `null` values are normalized to absent (`null` optional) so callers
/// treat explicit `"result": null` exactly like a missing field.
fn normalizeNull(v: ?std.json.Value) ?std.json.Value {
    const val = v orelse return null;
    if (val == .null) return null;
    return val;
}

pub fn deinitMessage(gpa: std.mem.Allocator, msg: Message) void {
    switch (msg) {
        .request => |r| {
            gpa.free(r.method);
            if (r.parsed) |*p| p.deinit();
        },
        .notification => |n| {
            gpa.free(n.method);
            if (n.parsed) |*p| p.deinit();
        },
        .response => |r| deinitResponse(gpa, r),
    }
}

pub fn deinitResponse(gpa: std.mem.Allocator, r: Response) void {
    if (r.err) |e| gpa.free(e.message);
    if (r.parsed) |*p| p.deinit();
}

/// Streaming frame decoder: feed raw pipe bytes in, get complete messages
/// out. Bounded: header line > 4 KiB or body > 8 MiB → `ProtocolError`.
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,
    parse_start: usize = 0,
    content_length: usize = 0,
    phase: Phase = .header,

    const Phase = enum { header, sep, body };

    pub const Error = error{
        OutOfMemory,
        ProtocolError,
    };

    pub fn deinit(self: *Decoder, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
        self.* = undefined;
    }

    pub fn push(self: *Decoder, gpa: std.mem.Allocator, bytes: []const u8) Error!void {
        try self.buf.appendSlice(gpa, bytes);
    }

    /// Extract the next complete message, or null when more bytes are needed.
    pub fn next(self: *Decoder, gpa: std.mem.Allocator) Error!?Message {
        while (true) {
            switch (self.phase) {
                .header => {
                    const rest = self.buf.items[self.parse_start..];
                    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                        if (rest.len > max_header_line_bytes) return error.ProtocolError;
                        return null;
                    };
                    if (line_end > max_header_line_bytes) return error.ProtocolError;
                    const line = std.mem.trim(u8, rest[0 .. line_end + 1], "\r\n");
                    if (!std.mem.startsWith(u8, line, framing_header)) return error.ProtocolError;
                    const value = line[framing_header.len..];
                    const n = std.fmt.parseInt(usize, value, 10) catch return error.ProtocolError;
                    if (n > max_message_bytes) return error.ProtocolError;
                    self.content_length = n;
                    self.parse_start += line_end + 1;
                    self.phase = .sep;
                },
                .sep => {
                    // Blank separator line after the header (may straddle
                    // chunk boundaries; LSP framing is strict otherwise).
                    var sep = self.buf.items[self.parse_start..];
                    if (sep.len == 0) return null;
                    if (sep[0] == '\r') {
                        self.parse_start += 1;
                        sep = self.buf.items[self.parse_start..];
                        if (sep.len == 0) return null;
                        if (sep[0] != '\n') return error.ProtocolError;
                        self.parse_start += 1;
                    } else if (sep[0] == '\n') {
                        self.parse_start += 1;
                    } else {
                        return error.ProtocolError;
                    }
                    self.phase = .body;
                },
                .body => {
                    if (self.buf.items.len - self.parse_start < self.content_length) return null;
                    const body = self.buf.items[self.parse_start .. self.parse_start + self.content_length];
                    self.parse_start += self.content_length;
                    self.phase = .header;
                    self.compact(gpa);
                    const parsed_msg = try parseMessage(gpa, body);
                    return parsed_msg;
                },
            }
        }
    }

    /// Drop already-consumed bytes when the prefix grows (amortized).
    fn compact(self: *Decoder, gpa: std.mem.Allocator) void {
        _ = gpa;
        if (self.parse_start > 64 * 1024) {
            std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - self.parse_start], self.buf.items[self.parse_start..]);
            self.buf.items.len -= self.parse_start;
            self.parse_start = 0;
        }
    }
};

/// Parse a message body per JSON-RPC 2.0 classification:
/// - has `id` + `method` → request (server → client; we reply MethodNotFound)
/// - has `id` → response
/// - else → notification
pub fn parseMessage(gpa: std.mem.Allocator, body: []const u8) Decoder.Error!Message {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return error.ProtocolError;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.ProtocolError;
    const obj = parsed.value.object;

    const id_val = obj.get("id");
    if (id_val) |v| {
        const id = switch (v) {
            .integer => |i| if (i < 0) return error.ProtocolError else @as(u64, @intCast(i)),
            .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.ProtocolError,
            else => return error.ProtocolError,
        };
        if (obj.get("method")) |m| {
            if (m != .string) return error.ProtocolError;
            return .{ .request = .{
                .id = id,
                .method = try gpa.dupe(u8, m.string),
                .params = obj.get("params"),
                .parsed = parsed,
            } };
        }
        return .{ .response = .{
            .id = id,
            .result = normalizeNull(obj.get("result")),
            .err = blk: {
                const e = obj.get("error") orelse break :blk null;
                if (e != .object) return error.ProtocolError;
                const code = e.object.get("code") orelse return error.ProtocolError;
                if (code != .integer) return error.ProtocolError;
                const msg = e.object.get("message") orelse return error.ProtocolError;
                if (msg != .string) return error.ProtocolError;
                break :blk .{ .code = code.integer, .message = try gpa.dupe(u8, msg.string) };
            },
            .parsed = parsed,
        } };
    }
    const method = obj.get("method") orelse return error.ProtocolError;
    if (method != .string) return error.ProtocolError;
    return .{ .notification = .{
        .method = try gpa.dupe(u8, method.string),
        .params = obj.get("params"),
        .parsed = parsed,
    } };
}

// ── writing ─────────────────────────────────────────────────────────────

pub fn writeRequest(gpa: std.mem.Allocator, id: u64, method: []const u8, params_json: []const u8) std.mem.Allocator.Error![]u8 {
    const m = try jsonString(gpa, method);
    defer gpa.free(m);
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{s},\"params\":{s}}}", .{ id, m, params_json });
}

pub fn writeNotification(gpa: std.mem.Allocator, method: []const u8, params_json: []const u8) std.mem.Allocator.Error![]u8 {
    const m = try jsonString(gpa, method);
    defer gpa.free(m);
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}", .{ m, params_json });
}

pub fn writeErrorResponse(gpa: std.mem.Allocator, id: u64, code: i64, message: []const u8) std.mem.Allocator.Error![]u8 {
    const m = try jsonString(gpa, message);
    defer gpa.free(m);
    return std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id, code, m });
}

/// Frame a body with the LSP Content-Length header; caller owns the result.
pub fn frame(gpa: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// JSON string literal (escaped, quoted). Caller owns the result.
pub fn jsonString(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(gpa, "\\u{x:0>4}", .{c});
                defer gpa.free(esc);
                try out.appendSlice(gpa, esc);
            },
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

// ── tests ───────────────────────────────────────────────────────────────

test "frame and parse round trip" {
    const gpa = std.testing.allocator;
    const body = try writeRequest(gpa, 1, "initialize", "{}");
    defer gpa.free(body);
    const framed = try frame(gpa, body);
    defer gpa.free(framed);

    var dec: Decoder = .{};
    defer dec.deinit(gpa);
    try dec.push(gpa, framed);
    const msg = (try dec.next(gpa)).?;
    defer deinitMessage(gpa, msg);
    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(u64, 1), msg.request.id);
    try std.testing.expectEqualStrings("initialize", msg.request.method);
    try std.testing.expect(msg.request.params != null);
}

test "decoder handles chunked writes" {
    const gpa = std.testing.allocator;
    const body = try writeNotification(gpa, "initialized", "{}");
    defer gpa.free(body);
    const framed = try frame(gpa, body);
    defer gpa.free(framed);

    var dec: Decoder = .{};
    defer dec.deinit(gpa);
    var i: usize = 0;
    var saw = false;
    while (i < framed.len) : (i += 1) {
        try dec.push(gpa, framed[i .. i + 1]);
        if (try dec.next(gpa)) |msg| {
            defer deinitMessage(gpa, msg);
            try std.testing.expect(msg == .notification);
            try std.testing.expectEqualStrings("initialized", msg.notification.method);
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "decoder rejects oversized header and body" {
    const gpa = std.testing.allocator;
    {
        var dec: Decoder = .{};
        defer dec.deinit(gpa);
        var big: [max_header_line_bytes + 16]u8 = undefined;
        @memset(&big, 'a');
        try dec.push(gpa, &big);
        try std.testing.expectError(error.ProtocolError, dec.next(gpa));
    }
    {
        var dec: Decoder = .{};
        defer dec.deinit(gpa);
        const hdr = "Content-Length: 999999999\r\n\r\n";
        try dec.push(gpa, hdr);
        try std.testing.expectError(error.ProtocolError, dec.next(gpa));
    }
}

test "decoder rejects malformed header" {
    const gpa = std.testing.allocator;
    var dec: Decoder = .{};
    defer dec.deinit(gpa);
    try dec.push(gpa, "Content-Type: application/json\r\n\r\n");
    try std.testing.expectError(error.ProtocolError, dec.next(gpa));
}

test "response with null result parses as null value" {
    const gpa = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}";
    const msg = try parseMessage(gpa, body);
    defer deinitMessage(gpa, msg);
    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(u64, 2), msg.response.id);
    try std.testing.expect(msg.response.result == null);
    try std.testing.expect(msg.response.err == null);
}

test "jsonString escapes quotes backslashes and control chars" {
    const gpa = std.testing.allocator;
    const s = try jsonString(gpa, "a\"b\\c\nd\x01");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", s);
}
