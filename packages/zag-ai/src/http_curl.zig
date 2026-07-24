//! HTTP client backend: zig-curl (libcurl bindings).
//!
//! Selected when `-Dhttp_backend=curl`. Same `Client` surface as `http_std.zig`
//! so wire adapters never import Easy/Multi. See D-005.

const std = @import("std");
const Io = std.Io;
const curl = @import("curl");
const wire = @import("wire.zig");
const config_mod = @import("config.zig");

pub const Error = wire.Error;
pub const Config = config_mod.Config;

pub const Response = struct {
    status: u16,
    body: []u8,
};

pub const StreamChunk = *const fn (ctx: ?*anyopaque, chunk: []const u8) Error!void;

const Header = struct {
    name: []const u8,
    value: []const u8,
};

var curl_global_ready: std.atomic.Value(bool) = .init(false);

fn ensureCurlGlobal() void {
    if (curl_global_ready.load(.acquire)) return;
    curl.globalInit() catch {};
    curl_global_ready.store(true, .release);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []u8,
    max_retries: u8,
    retry_base_delay_ms: u64,
    timeout_ms: ?u64,
    owned_key: ?[]u8 = null,
    default_headers: []Header = &.{},
    owns_default_headers: bool = false,
    /// Owned PEM blob for CURLOPT_CAINFO_BLOB (from zig-curl allocCABundle).
    ca_bundle: std.ArrayList(u8),

    pub fn initBearer(allocator: std.mem.Allocator, io: Io, config: Config) Error!Client {
        const base = try allocator.dupe(u8, config.base_url);
        errdefer allocator.free(base);
        const key = try allocator.dupe(u8, config.api_key);
        errdefer allocator.free(key);

        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        errdefer allocator.free(auth);
        allocator.free(key);

        const headers = try allocator.alloc(Header, 1);
        headers[0] = .{ .name = "Authorization", .value = auth };

        return try finishInit(allocator, io, config, base, auth, headers);
    }

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

        const headers = try allocator.alloc(Header, 1 + extra.len);
        errdefer allocator.free(headers);
        headers[0] = .{ .name = header_name, .value = key };
        for (extra, 0..) |h, i| {
            headers[1 + i] = .{ .name = h.name, .value = h.value };
        }

        return try finishInit(allocator, io, config, base, key, headers);
    }

    fn finishInit(
        allocator: std.mem.Allocator,
        io: Io,
        config: Config,
        base: []u8,
        owned_key: []u8,
        headers: []Header,
    ) Error!Client {
        ensureCurlGlobal();
        var ca_bundle = curl.allocCABundle(allocator, io) catch return error.HttpFailed;
        errdefer ca_bundle.deinit(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .base_url = base,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
            .timeout_ms = config.timeout_ms,
            .owned_key = owned_key,
            .default_headers = headers,
            .owns_default_headers = true,
            .ca_bundle = ca_bundle,
        };
    }

    pub fn deinit(self: *Client) void {
        self.ca_bundle.deinit(self.allocator);
        if (self.owns_default_headers) {
            self.allocator.free(self.default_headers);
        }
        if (self.owned_key) |k| self.allocator.free(k);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn postJson(self: *Client, path: []const u8, body: []const u8) Error!Response {
        return self.request(.POST, path, &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body, false, null, null);
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
        _ = try self.request(.POST, path, &.{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body, true, on_chunk, chunk_ctx);
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
        method: curl.Easy.Method,
        path: []const u8,
        extra: []const Header,
        body: ?[]const u8,
        stream: bool,
        on_chunk: ?StreamChunk,
        chunk_ctx: ?*anyopaque,
    ) Error!Response {
        const url = try buildUrl(self.allocator, self.base_url, path);
        defer self.allocator.free(url);
        const url_z = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(url_z);

        var attempt: u8 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            const result = self.attemptOnce(method, url_z, extra, body, stream, on_chunk, chunk_ctx) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.StreamFailed) return error.StreamFailed;
                if (attempt == self.max_retries) return err;
                sleepRetry(self.io, self.retry_base_delay_ms, attempt);
                continue;
            };

            if (result.status < 200 or result.status >= 300) {
                if (isRetryableStatus(result.status) and attempt < self.max_retries) {
                    if (result.body.len > 0) self.allocator.free(result.body);
                    sleepRetry(self.io, self.retry_base_delay_ms, attempt);
                    continue;
                }
                if (result.body.len > 0) self.allocator.free(result.body);
                return mapHttpStatus(result.status);
            }

            if (stream) return .{ .status = result.status, .body = &.{} };
            return result;
        }
        return error.HttpFailed;
    }

    fn attemptOnce(
        self: *Client,
        method: curl.Easy.Method,
        url_z: [:0]const u8,
        extra: []const Header,
        body: ?[]const u8,
        stream: bool,
        on_chunk: ?StreamChunk,
        chunk_ctx: ?*anyopaque,
    ) Error!Response {
        var easy = curl.Easy.init(.{
            .ca_bundle = self.ca_bundle,
            .default_timeout_ms = self.timeout_ms orelse 60_000,
        }) catch return error.HttpFailed;
        defer easy.deinit();

        var header_list: curl.Easy.Headers = .{};
        defer header_list.deinit();

        var owned_header_lines: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned_header_lines.items) |line| self.allocator.free(line);
            owned_header_lines.deinit(self.allocator);
        }

        const addHeader = struct {
            fn go(
                alloc: std.mem.Allocator,
                list: *curl.Easy.Headers,
                owned: *std.ArrayList([:0]u8),
                name: []const u8,
                value: []const u8,
            ) Error!void {
                const line = std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ name, value }, 0) catch
                    return error.OutOfMemory;
                errdefer alloc.free(line);
                owned.append(alloc, line) catch {
                    alloc.free(line);
                    return error.OutOfMemory;
                };
                list.add(line) catch return error.HttpFailed;
            }
        }.go;

        for (self.default_headers) |h| {
            try addHeader(self.allocator, &header_list, &owned_header_lines, h.name, h.value);
        }
        for (extra) |h| {
            try addHeader(self.allocator, &header_list, &owned_header_lines, h.name, h.value);
        }

        easy.setUrl(url_z) catch return error.HttpFailed;
        easy.setMethod(method) catch return error.HttpFailed;
        easy.setHeaders(header_list) catch return error.HttpFailed;
        if (body) |payload| {
            easy.setPostFields(payload) catch return error.HttpFailed;
        }

        if (stream) {
            const cb = on_chunk orelse return error.Unexpected;
            var stream_state: StreamState = .{
                .on_chunk = cb,
                .chunk_ctx = chunk_ctx,
            };
            easy.setWritedata(@ptrCast(&stream_state)) catch return error.HttpFailed;
            easy.setWritefunction(streamWrite) catch return error.HttpFailed;

            const resp = easy.perform() catch {
                if (stream_state.failed) return stream_state.err;
                return error.HttpFailed;
            };
            if (stream_state.failed) return stream_state.err;
            return .{ .status = @intCast(resp.status_code), .body = &.{} };
        }

        var body_writer: Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();
        easy.setWriter(&body_writer.writer) catch return error.HttpFailed;
        const resp = easy.perform() catch return error.HttpFailed;
        body_writer.writer.flush() catch {};
        const bytes = body_writer.toOwnedSlice() catch return error.OutOfMemory;
        return .{ .status = @intCast(resp.status_code), .body = bytes };
    }
};

const StreamState = struct {
    on_chunk: StreamChunk,
    chunk_ctx: ?*anyopaque,
    failed: bool = false,
    err: Error = error.HttpFailed,
};

fn streamWrite(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    const real_size = size * nmemb;
    const state: *StreamState = @ptrCast(@alignCast(user_data));
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    state.on_chunk(state.chunk_ctx, data) catch |err| {
        state.failed = true;
        state.err = err;
        return 0;
    };
    return real_size;
}

fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 429 or status >= 500;
}

fn sleepRetry(io: Io, base_ms: u64, attempt: u8) void {
    const shift: u6 = @intCast(@min(attempt, 4));
    const delay_ms = base_ms * (@as(u64, 1) << shift);
    const duration: Io.Duration = .{ .nanoseconds = @intCast(delay_ms * std.time.ns_per_ms) };
    Io.sleep(io, duration, .real) catch {};
}

fn buildUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) Error![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    if (path.len == 0) return allocator.dupe(u8, base) catch return error.OutOfMemory;
    if (path[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path }) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path }) catch return error.OutOfMemory;
}

test "curl buildUrl joins base and path" {
    const gpa = std.testing.allocator;
    const url_a = try buildUrl(gpa, "https://api.anthropic.com/", "/v1/messages");
    defer gpa.free(url_a);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url_a);
}
