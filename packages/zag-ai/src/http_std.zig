//! HTTP client backend: Zig `std.http.Client` (default).
//!
//! Selected when `-Dhttp_backend=std` (or unset). See `http.zig` facade.
//!
//! ## Deadline / cancel (h-provider-001)
//!
//! - `timeout_ms` and `RequestControl` are **enforced**, not stored silently.
//! - Monotonic deadline checks before each attempt and between body reads.
//! - A watchdog thread shuts down the connection socket when cancel/deadline
//!   trips mid-request so blocked `receiveHead`/body IO unblocks within ~25–50ms
//!   poll granularity plus OS scheduling (documented bound).
//! - Default `timeout_ms=null` imposes **no** timeout (unlike older curl path).
//! - `error.Timeout` vs `error.Cancelled` vs auth/transport remain distinct.
//!
//! Trusted-host only: socket shutdown is cooperative interrupt, not an OS sandbox.

const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const config_mod = @import("config.zig");
const rc = @import("request_control.zig");

pub const Error = wire.Error;
pub const Config = config_mod.Config;
pub const RequestControl = rc.RequestControl;

pub const Response = struct {
    status: u16,
    body: []u8,
};

/// Streaming body callback — uses **wire.Error**, not any vendor SDK error set.
pub const StreamChunk = *const fn (ctx: ?*anyopaque, chunk: []const u8) Error!void;

/// Watchdog: polls control and shuts down the live stream to abort in-flight IO.
const AbortWatch = struct {
    control: RequestControl,
    io: Io,
    /// Pointer to `Connection.stream_reader.stream` for the active request.
    stream_ptr: std.atomic.Value(?*Io.net.Stream) = .init(null),
    stop: std.atomic.Value(bool) = .init(false),

    fn start(self: *AbortWatch) !std.Thread {
        return std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn finish(self: *AbortWatch, thread: ?std.Thread) void {
        self.stop.store(true, .seq_cst);
        if (thread) |t| t.join();
        self.stream_ptr.store(null, .seq_cst);
    }

    fn threadMain(self: *AbortWatch) void {
        while (!self.stop.load(.seq_cst)) {
            const now = rc.monoNowNs();
            if (self.control.isCancelled() or self.control.isExpired(now)) {
                if (self.stream_ptr.load(.seq_cst)) |s| {
                    s.shutdown(self.io, .both) catch {};
                }
                return;
            }
            const duration: Io.Duration = .{ .nanoseconds = 25 * std.time.ns_per_ms };
            Io.sleep(self.io, duration, .awake) catch {};
        }
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    http: std.http.Client,
    base_url: []u8,
    max_retries: u8,
    retry_base_delay_ms: u64,
    timeout_ms: ?u64,
    /// Owned stable auth value (e.g. api key for header).
    owned_key: ?[]u8 = null,
    /// Default headers for every request (may reference owned_key).
    default_headers: []std.http.Header = &.{},
    owns_default_headers: bool = false,

    /// `Authorization: Bearer <api_key>`.
    pub fn initBearer(allocator: std.mem.Allocator, io: Io, config: Config) Error!Client {
        const base = try allocator.dupe(u8, config.base_url);
        errdefer allocator.free(base);
        const key = try allocator.dupe(u8, config.api_key);
        errdefer allocator.free(key);

        // "Bearer " + key
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        errdefer allocator.free(auth);
        allocator.free(key);

        const headers = try allocator.alloc(std.http.Header, 1);
        headers[0] = .{ .name = "Authorization", .value = auth };

        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
            .base_url = base,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
            .timeout_ms = config.timeout_ms,
            .owned_key = auth,
            .default_headers = headers,
            .owns_default_headers = true,
        };
    }

    /// Custom header auth (Anthropic: `x-api-key`) + optional static extras.
    /// `extra` value strings must outlive the client (literals OK).
    pub fn initHeaderAuth(
        allocator: std.mem.Allocator,
        io: Io,
        config: Config,
        header_name: []const u8,
        extra: []const std.http.Header,
    ) Error!Client {
        const base = try allocator.dupe(u8, config.base_url);
        errdefer allocator.free(base);
        const key = try allocator.dupe(u8, config.api_key);
        errdefer allocator.free(key);

        const headers = try allocator.alloc(std.http.Header, 1 + extra.len);
        errdefer allocator.free(headers);
        headers[0] = .{ .name = header_name, .value = key };
        @memcpy(headers[1..], extra);

        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
            .base_url = base,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
            .timeout_ms = config.timeout_ms,
            .owned_key = key,
            .default_headers = headers,
            .owns_default_headers = true,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.owns_default_headers) {
            self.allocator.free(self.default_headers);
        }
        if (self.owned_key) |k| self.allocator.free(k);
        self.allocator.free(self.base_url);
        self.http.deinit();
        self.* = undefined;
    }

    pub fn postJson(self: *Client, path: []const u8, body: []const u8) Error!Response {
        return self.postJsonControl(path, body, .{});
    }

    pub fn postJsonControl(self: *Client, path: []const u8, body: []const u8, control: RequestControl) Error!Response {
        return self.request(.POST, path, &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body, false, null, null, control);
    }

    pub fn freeBody(self: *Client, body: []u8) void {
        self.allocator.free(body);
    }

    pub fn postJsonStream(
        self: *Client,
        path: []const u8,
        body: []const u8,
        on_chunk: StreamChunk,
        chunk_ctx: ?*anyopaque,
    ) Error!void {
        return self.postJsonStreamControl(path, body, on_chunk, chunk_ctx, .{});
    }

    pub fn postJsonStreamControl(
        self: *Client,
        path: []const u8,
        body: []const u8,
        on_chunk: StreamChunk,
        chunk_ctx: ?*anyopaque,
        control: RequestControl,
    ) Error!void {
        _ = try self.request(.POST, path, &.{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body, true, on_chunk, chunk_ctx, control);
    }

    pub fn mapHttpStatus(status: u16) Error {
        return switch (status) {
            401 => error.AuthenticationFailed,
            403 => error.PermissionDenied,
            429 => error.RateLimited,
            400, 404, 409, 422 => error.BadRequest,
            408 => error.Timeout,
            500...599 => error.ServerError,
            else => error.BadStatus,
        };
    }

    fn request(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        extra: []const std.http.Header,
        body: ?[]const u8,
        stream: bool,
        on_chunk: ?StreamChunk,
        chunk_ctx: ?*anyopaque,
        control_in: RequestControl,
    ) Error!Response {
        const control = rc.mergeConfiguredTimeout(control_in, self.timeout_ms);
        try rc.preflight(control);

        const url = try buildUrl(self.allocator, self.base_url, path);
        defer self.allocator.free(url);
        const uri = std.Uri.parse(url) catch return error.HttpFailed;

        var attempt: u8 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            try rc.preflight(control);

            var headers: std.ArrayList(std.http.Header) = .empty;
            defer headers.deinit(self.allocator);
            try headers.appendSlice(self.allocator, self.default_headers);
            try headers.appendSlice(self.allocator, extra);

            var watch: AbortWatch = .{
                .control = control,
                .io = self.io,
            };
            const watch_thread = if (control.cancel != null or control.deadline_mono_ns != null)
                watch.start() catch null
            else
                null;
            defer watch.finish(watch_thread);

            var req = self.http.request(method, uri, .{
                .extra_headers = headers.items,
                .keep_alive = false,
            }) catch |err| {
                if (control.isCancelled()) return error.Cancelled;
                if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                if (err == error.Canceled) return error.Cancelled;
                if (attempt == self.max_retries) return error.HttpFailed;
                try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                continue;
            };
            defer req.deinit();

            if (req.connection) |conn| {
                watch.stream_ptr.store(&conn.stream_reader.stream, .seq_cst);
            }

            if (body) |payload| {
                req.transfer_encoding = .{ .content_length = payload.len };
                var body_writer = req.sendBodyUnflushed(&.{}) catch {
                    if (control.isCancelled()) return error.Cancelled;
                    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                    if (attempt == self.max_retries) return error.HttpFailed;
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                };
                body_writer.writer.writeAll(payload) catch {
                    if (control.isCancelled()) return error.Cancelled;
                    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                    if (attempt == self.max_retries) return error.HttpFailed;
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                };
                body_writer.end() catch {
                    if (control.isCancelled()) return error.Cancelled;
                    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                    if (attempt == self.max_retries) return error.HttpFailed;
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                };
                req.connection.?.flush() catch {
                    if (control.isCancelled()) return error.Cancelled;
                    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                    if (attempt == self.max_retries) return error.HttpFailed;
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                };
            } else {
                req.sendBodiless() catch {
                    if (control.isCancelled()) return error.Cancelled;
                    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                    if (attempt == self.max_retries) return error.HttpFailed;
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                };
            }

            var redirect_buffer: [8 * 1024]u8 = undefined;
            var response = req.receiveHead(&redirect_buffer) catch {
                if (control.isCancelled()) return error.Cancelled;
                if (control.isExpired(rc.monoNowNs())) return error.Timeout;
                if (attempt == self.max_retries) return error.HttpFailed;
                try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                continue;
            };

            const status: u16 = @intFromEnum(response.head.status);

            if (stream) {
                if (status < 200 or status >= 300) {
                    // drain error body
                    const err_body = readAllBody(self.allocator, &response, control) catch &.{};
                    defer if (err_body.len > 0) self.allocator.free(err_body);
                    if (isRetryableStatus(status) and attempt < self.max_retries) {
                        try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                        continue;
                    }
                    return mapHttpStatus(status);
                }
                const cb = on_chunk orelse return error.Unexpected;
                streamBody(&response, self.allocator, cb, chunk_ctx, control) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (err == error.StreamFailed) return error.StreamFailed;
                    if (err == error.Cancelled) return error.Cancelled;
                    if (err == error.Timeout) return error.Timeout;
                    return error.HttpFailed;
                };
                return .{ .status = status, .body = &.{} };
            }

            const response_bytes = readAllBody(self.allocator, &response, control) catch |err| {
                if (err == error.Cancelled) return error.Cancelled;
                if (err == error.Timeout) return error.Timeout;
                if (attempt == self.max_retries) return error.HttpFailed;
                try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                continue;
            };

            if (status < 200 or status >= 300) {
                if (isRetryableStatus(status) and attempt < self.max_retries) {
                    self.allocator.free(response_bytes);
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                    continue;
                }
                self.allocator.free(response_bytes);
                return mapHttpStatus(status);
            }

            return .{ .status = status, .body = response_bytes };
        }
        return error.HttpFailed;
    }
};

fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 429 or status >= 500;
}

fn buildUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) Error![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    if (path.len == 0) return allocator.dupe(u8, base) catch return error.OutOfMemory;
    if (path[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path }) catch return error.OutOfMemory;
}

fn readAllBody(allocator: std.mem.Allocator, response: *std.http.Client.Response, control: RequestControl) Error![]u8 {
    var body_writer: Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();
    // Stream into allocating writer with control checks via streamBody-style loop.
    const content_encoding = response.head.content_encoding;
    var decompression_buffer: []u8 = &.{};
    var owns_decomp = false;
    if (content_encoding == .zstd) {
        decompression_buffer = allocator.alloc(u8, std.compress.zstd.default_window_len) catch return error.OutOfMemory;
        owns_decomp = true;
    } else if (content_encoding == .deflate or content_encoding == .gzip) {
        decompression_buffer = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
        owns_decomp = true;
    } else if (content_encoding == .compress) {
        return error.HttpFailed;
    }
    defer if (owns_decomp) allocator.free(decompression_buffer);

    var transfer_buffer: [8192]u8 = undefined;
    var decompressor: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompressor, decompression_buffer);

    while (true) {
        try rc.preflight(control);
        var tmp: [4096]u8 = undefined;
        const n = reader.readSliceShort(&tmp) catch |err| {
            if (control.isCancelled()) return error.Cancelled;
            if (control.isExpired(rc.monoNowNs())) return error.Timeout;
            if (err == error.ReadFailed) {
                if (response.bodyErr()) |_| return error.HttpFailed;
            }
            return error.HttpFailed;
        };
        if (n == 0) break;
        body_writer.writer.writeAll(tmp[0..n]) catch return error.HttpFailed;
    }
    return body_writer.toOwnedSlice() catch return error.OutOfMemory;
}

fn streamBody(
    response: *std.http.Client.Response,
    allocator: std.mem.Allocator,
    on_chunk: StreamChunk,
    chunk_ctx: ?*anyopaque,
    control: RequestControl,
) Error!void {
    const content_encoding = response.head.content_encoding;
    var decompression_buffer: []u8 = &.{};
    var owns_decomp = false;
    if (content_encoding == .zstd) {
        decompression_buffer = allocator.alloc(u8, std.compress.zstd.default_window_len) catch return error.OutOfMemory;
        owns_decomp = true;
    } else if (content_encoding == .deflate or content_encoding == .gzip) {
        decompression_buffer = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
        owns_decomp = true;
    } else if (content_encoding == .compress) {
        return error.HttpFailed;
    }
    defer if (owns_decomp) allocator.free(decompression_buffer);

    var transfer_buffer: [8192]u8 = undefined;
    var decompressor: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompressor, decompression_buffer);

    while (true) {
        try rc.preflight(control);
        var tmp: [4096]u8 = undefined;
        const n = reader.readSliceShort(&tmp) catch |err| {
            if (control.isCancelled()) return error.Cancelled;
            if (control.isExpired(rc.monoNowNs())) return error.Timeout;
            if (err == error.ReadFailed) {
                if (response.bodyErr()) |_| return error.HttpFailed;
            }
            return error.HttpFailed;
        };
        if (n == 0) break;
        try on_chunk(chunk_ctx, tmp[0..n]);
    }
}

test "buildUrl joins base and path" {
    const gpa = std.testing.allocator;
    const url_a = try buildUrl(gpa, "https://api.anthropic.com/", "/v1/messages");
    defer gpa.free(url_a);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url_a);
    const url_b = try buildUrl(gpa, "https://api.example.com/v1", "chat/completions");
    defer gpa.free(url_b);
    try std.testing.expectEqualStrings("https://api.example.com/v1/chat/completions", url_b);
}

test "std preflight cancel before network" {
    var flag: rc.CancelFlag = .{};
    flag.request();
    const control = RequestControl.none().withCancel(&flag);
    try std.testing.expectError(error.Cancelled, rc.preflight(control));
}

test "std preflight timeout before network" {
    const control = RequestControl.withTimeoutMs(rc.monoNowNs(), 0);
    try std.testing.expectError(error.Timeout, rc.preflight(control));
}
