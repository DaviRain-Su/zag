const std = @import("std");

/// Shared error set for client operations.
pub const Error = error{
    HttpError,
    BadRequestError,
    AuthenticationError,
    PermissionDeniedError,
    NotFoundError,
    ConflictError,
    UnprocessableEntityError,
    RateLimitError,
    TimeoutError,
    InternalServerError,
    DeserializeError,
    SerializeError,
    Timeout,
    /// Cooperative cancel observed mid-request (h-provider-001).
    Cancelled,
    /// Backend cannot enforce required deadline/active-cancel control.
    UnsupportedControl,
    Unimplemented,
};

/// HTTP-level error payload, if the API returns a JSON error object.
pub const ApiError = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

pub const ParsedApiError = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

const ApiErrorEnvelope = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

const ApiErrorResponse = struct {
    @"error": ?ApiErrorEnvelope = null,
    detail: ?[]const u8 = null,
};

/// Response wrapper that keeps both status and body text for diagnostics.
pub const HttpErrorDetail = struct {
    status: u16,
    body: []const u8,
    request_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const hint_msg_cap: usize = 240;
pub const hint_field_cap: usize = 64;

/// Last HTTP error fields (fixed buffers; no heap). Product code copies this
/// into zag-ai `provider_diag` — never the raw body.
pub const LastHttpHint = struct {
    status: u16 = 0,
    body_len: usize = 0,
    err_type: [hint_field_cap]u8 = undefined,
    err_type_len: u8 = 0,
    code: [hint_field_cap]u8 = undefined,
    code_len: u8 = 0,
    param: [hint_field_cap]u8 = undefined,
    param_len: u8 = 0,
    message: [hint_msg_cap]u8 = undefined,
    message_len: u8 = 0,

    pub fn typeSlice(self: *const LastHttpHint) []const u8 {
        return self.err_type[0..self.err_type_len];
    }
    pub fn codeSlice(self: *const LastHttpHint) []const u8 {
        return self.code[0..self.code_len];
    }
    pub fn paramSlice(self: *const LastHttpHint) []const u8 {
        return self.param[0..self.param_len];
    }
    pub fn messageSlice(self: *const LastHttpHint) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub var last_http_hint: LastHttpHint = .{};

/// Pure HTTP diagnostic formatter (status + body length only).
/// Never interpolates body bytes, Authorization, or message text.
pub fn formatHttpStatusBodyLen(buf: []u8, status: u16, body_len: usize) []const u8 {
    return std.fmt.bufPrint(buf, "http status {d}, body: {}\n", .{ status, body_len }) catch "http status ?, body: ?\n";
}

fn copyHintField(dest: []u8, dest_len: *u8, src: []const u8) void {
    var n: usize = 0;
    for (src) |c| {
        if (n >= dest.len) break;
        if (c == '\n' or c == '\r' or c == '\t') {
            dest[n] = ' ';
            n += 1;
            continue;
        }
        if (c < 0x20) continue;
        dest[n] = c;
        n += 1;
    }
    dest_len.* = @intCast(n);
}

fn fillLastHint(detail: HttpErrorDetail) void {
    last_http_hint = .{
        .status = detail.status,
        .body_len = detail.body.len,
    };
    if (detail.type) |t| copyHintField(&last_http_hint.err_type, &last_http_hint.err_type_len, t);
    if (detail.code) |c| copyHintField(&last_http_hint.code, &last_http_hint.code_len, c);
    if (detail.param) |p| copyHintField(&last_http_hint.param, &last_http_hint.param_len, p);
    if (detail.message) |m| copyHintField(&last_http_hint.message, &last_http_hint.message_len, m);
    if (detail.body.len == 0) return;
    if (last_http_hint.err_type_len > 0 or last_http_hint.message_len > 0) return;

    const parsed = std.json.parseFromSlice(ApiErrorResponse, std.heap.page_allocator, detail.body, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value.@"error") |e| {
        if (e.type) |t| copyHintField(&last_http_hint.err_type, &last_http_hint.err_type_len, t);
        if (e.code) |c| copyHintField(&last_http_hint.code, &last_http_hint.code_len, c);
        if (e.param) |p| copyHintField(&last_http_hint.param, &last_http_hint.param_len, p);
        if (e.message) |m| copyHintField(&last_http_hint.message, &last_http_hint.message_len, m);
    } else if (parsed.value.detail) |d| {
        copyHintField(&last_http_hint.message, &last_http_hint.message_len, d);
    }
}

/// Map HTTP status to a typed error. Prints status + body length (never the
/// raw body). Parsed error fields are stored on `last_http_hint` for the
/// product diagnostic file — not printed here (message may echo secrets).
pub fn unexpectedStatus(detail: HttpErrorDetail) Error {
    fillLastHint(detail);
    var diag_buf: [64]u8 = undefined;
    const diag = formatHttpStatusBodyLen(&diag_buf, detail.status, detail.body.len);
    std.debug.print("{s}", .{diag});
    return classifyStatus(detail.status);
}

pub fn unimplemented(comptime feature: []const u8) Error {
    std.debug.print("feature not implemented: {s}\n", .{feature});
    return Error.Unimplemented;
}

fn classifyStatus(status: u16) Error {
    return switch (status) {
        400 => Error.BadRequestError,
        401 => Error.AuthenticationError,
        403 => Error.PermissionDeniedError,
        404 => Error.NotFoundError,
        409 => Error.ConflictError,
        422 => Error.UnprocessableEntityError,
        429 => Error.RateLimitError,
        408 => Error.TimeoutError,
        500...599 => Error.InternalServerError,
        else => Error.HttpError,
    };
}

pub fn parseApiError(body: []const u8) ?ParsedApiError {
    const parsed = std.json.parseFromSlice(
        ApiErrorResponse,
        std.heap.page_allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return null;
    };
    const detail = parsed.value;
    const clone = std.heap.page_allocator;

    const cloneSlice = struct {
        fn run(src: []const u8) ?[]const u8 {
            const out = clone.alloc(u8, src.len) catch null;
            if (out) |buf| {
                std.mem.copyForwards(u8, buf, src);
            }
            return out;
        }
    }.run;

    if (detail.@"error") |api_err| {
        const message = if (api_err.message) |value| cloneSlice(value) else null;
        const typ = if (api_err.type) |value| cloneSlice(value) else null;
        const param = if (api_err.param) |value| cloneSlice(value) else null;
        const code = if (api_err.code) |value| cloneSlice(value) else null;
        parsed.deinit();
        return ParsedApiError{
            .message = message,
            .type = typ,
            .param = param,
            .code = code,
            .detail = null,
        };
    }
    if (detail.detail) |msg| {
        const detail_text = cloneSlice(msg);
        parsed.deinit();
        return ParsedApiError{ .detail = detail_text };
    }
    parsed.deinit();
    return null;
}

test "unexpectedStatus maps http status to specific errors" {
    const cases = [_]struct {
        status: u16,
        expect: Error,
    }{
        .{ .status = 400, .expect = Error.BadRequestError },
        .{ .status = 401, .expect = Error.AuthenticationError },
        .{ .status = 403, .expect = Error.PermissionDeniedError },
        .{ .status = 404, .expect = Error.NotFoundError },
        .{ .status = 409, .expect = Error.ConflictError },
        .{ .status = 422, .expect = Error.UnprocessableEntityError },
        .{ .status = 429, .expect = Error.RateLimitError },
        .{ .status = 408, .expect = Error.TimeoutError },
        .{ .status = 500, .expect = Error.InternalServerError },
        .{ .status = 502, .expect = Error.InternalServerError },
        .{ .status = 999, .expect = Error.HttpError },
    };

    inline for (cases) |case| {
        // unexpectedStatus returns an Error value (not an error-union).
        const got = unexpectedStatus(.{ .status = case.status, .body = "{}" });
        try std.testing.expectEqual(case.expect, got);
    }
}

test "unexpectedStatus stores parsed hint without printing body" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const body = "{\"error\":{\"message\":\"The reasoning_content must be passed back\",\"type\":\"invalid_request_error\",\"code\":\"invalid_request_error\"}}";
    const first = unexpectedStatus(.{ .status = 400, .body = body });
    try std.testing.expectEqual(Error.BadRequestError, first);
    try std.testing.expectEqual(@as(u16, 400), last_http_hint.status);
    try std.testing.expectEqualStrings("invalid_request_error", last_http_hint.typeSlice());
    try std.testing.expect(std.mem.indexOf(u8, last_http_hint.messageSlice(), "reasoning_content") != null);
    const second = unexpectedStatus(.{
        .status = 401,
        .body = "{\"error\":{\"message\":\"invalid api key " ++ secret ++ "\",\"type\":\"auth\"}}",
    });
    try std.testing.expectEqual(Error.AuthenticationError, second);
    try std.testing.expectEqual(@as(u16, 401), last_http_hint.status);
    try std.testing.expectEqualStrings("auth", last_http_hint.typeSlice());
}

test "formatHttpStatusBodyLen never includes secret body bytes" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const body = "{\"error\":{\"message\":\"invalid api key " ++ secret ++ "\",\"type\":\"auth\"}}";
    var buf: [64]u8 = undefined;
    const out = formatHttpStatusBodyLen(&buf, 401, body.len);
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "invalid api key") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "401") != null);
    // Length is numeric only.
    var expect_buf: [32]u8 = undefined;
    const expect_len = try std.fmt.bufPrint(&expect_buf, "body: {}", .{body.len});
    try std.testing.expect(std.mem.indexOf(u8, out, expect_len) != null);
}
