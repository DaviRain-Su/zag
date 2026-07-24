//! HTTP client backend: zig-curl (libcurl bindings).
//!
//! Selected when `-Dhttp_backend=curl`. Same `Client` surface as `http_std.zig`
//! so wire adapters never import Easy/Multi. See D-005.
//!
//! ## Deadline / cancel (h-provider-001)
//!
//! - `CURLOPT_TIMEOUT_MS` uses remaining monotonic budget (0 = no timeout when unset).
//! - Progress/xferinfo callback aborts when cancel is requested or deadline expires.
//! - Callback context lives on the stack for the duration of `perform` only.
//! - Default does **not** impose a 60s timeout when `timeout_ms` is null.

const std = @import("std");
const Io = std.Io;
const curl = @import("curl");
const libcurl = curl.libcurl;
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

/// Stable stack context for curl write + progress callbacks (must outlive perform).
const CallbackCtx = struct {
    control: RequestControl,
    on_chunk: ?StreamChunk = null,
    chunk_ctx: ?*anyopaque = null,
    body_writer: ?*Io.Writer.Allocating = null,
    failed: bool = false,
    err: Error = error.HttpFailed,
    /// Abort reason when progress callback stops transfer.
    aborted: enum { none, cancelled, timeout } = .none,
};

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
        method: curl.Easy.Method,
        path: []const u8,
        extra: []const Header,
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
        const url_z = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(url_z);

        var attempt: u8 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            try rc.preflight(control);
            const result = self.attemptOnce(method, url_z, extra, body, stream, on_chunk, chunk_ctx, control) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.StreamFailed) return error.StreamFailed;
                if (err == error.Cancelled) return error.Cancelled;
                if (err == error.Timeout) return error.Timeout;
                if (attempt == self.max_retries) return err;
                try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
                continue;
            };

            if (result.status < 200 or result.status >= 300) {
                if (isRetryableStatus(result.status) and attempt < self.max_retries) {
                    if (result.body.len > 0) self.allocator.free(result.body);
                    try rc.sleepRetryBounded(self.io, self.retry_base_delay_ms, attempt, control);
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
        control: RequestControl,
    ) Error!Response {
        // default_timeout_ms=0 → no curl default; we set CURLOPT_TIMEOUT_MS below.
        var easy = curl.Easy.init(.{
            .ca_bundle = self.ca_bundle,
            .default_timeout_ms = 0,
        }) catch return error.HttpFailed;
        defer easy.deinit();

        const timeout_ms = control.curlTimeoutMs(rc.monoNowNs(), self.timeout_ms);
        // When deadline/config present, always set TIMEOUT_MS (including 1ms when expired).
        if (timeout_ms > 0 or control.deadline_mono_ns != null or self.timeout_ms != null) {
            const t: c_long = @intCast(@min(timeout_ms, std.math.maxInt(c_long)));
            _ = libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_TIMEOUT_MS, t);
        }

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

        // Progress/xferinfo for cooperative cancel — context lives on this stack frame.
        var cb_ctx: CallbackCtx = .{
            .control = control,
            .on_chunk = on_chunk,
            .chunk_ctx = chunk_ctx,
        };
        _ = libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_XFERINFODATA, @as(?*anyopaque, @ptrCast(&cb_ctx)));
        _ = libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_XFERINFOFUNCTION, xferInfo);

        if (stream) {
            const cb = on_chunk orelse return error.Unexpected;
            cb_ctx.on_chunk = cb;
            easy.setWritedata(@ptrCast(&cb_ctx)) catch return error.HttpFailed;
            easy.setWritefunction(streamWrite) catch return error.HttpFailed;

            const resp = easy.perform() catch {
                if (cb_ctx.aborted == .cancelled or cb_ctx.failed and cb_ctx.err == error.Cancelled)
                    return error.Cancelled;
                if (cb_ctx.aborted == .timeout or cb_ctx.failed and cb_ctx.err == error.Timeout)
                    return error.Timeout;
                if (cb_ctx.failed) return cb_ctx.err;
                return mapCurlDiag(easy.diagnostics, control);
            };
            if (cb_ctx.failed) return cb_ctx.err;
            if (cb_ctx.aborted == .cancelled) return error.Cancelled;
            if (cb_ctx.aborted == .timeout) return error.Timeout;
            return .{ .status = @intCast(resp.status_code), .body = &.{} };
        }

        var body_writer: Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();
        cb_ctx.body_writer = &body_writer;
        easy.setWriter(&body_writer.writer) catch return error.HttpFailed;
        const resp = easy.perform() catch {
            if (cb_ctx.aborted == .cancelled) return error.Cancelled;
            if (cb_ctx.aborted == .timeout) return error.Timeout;
            return mapCurlDiag(easy.diagnostics, control);
        };
        body_writer.writer.flush() catch {};
        const bytes = body_writer.toOwnedSlice() catch return error.OutOfMemory;
        return .{ .status = @intCast(resp.status_code), .body = bytes };
    }
};

fn streamWrite(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    const real_size = size * nmemb;
    const state: *CallbackCtx = @ptrCast(@alignCast(user_data));
    if (state.control.isCancelled()) {
        state.failed = true;
        state.err = error.Cancelled;
        state.aborted = .cancelled;
        return 0;
    }
    if (state.control.isExpired(rc.monoNowNs())) {
        state.failed = true;
        state.err = error.Timeout;
        state.aborted = .timeout;
        return 0;
    }
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    const cb = state.on_chunk orelse {
        state.failed = true;
        state.err = error.Unexpected;
        return 0;
    };
    cb(state.chunk_ctx, data) catch |err| {
        state.failed = true;
        state.err = err;
        return 0;
    };
    return real_size;
}

/// libcurl xferinfo: return non-zero to abort transfer.
fn xferInfo(
    clientp: ?*anyopaque,
    dltotal: libcurl.curl_off_t,
    dlnow: libcurl.curl_off_t,
    ultotal: libcurl.curl_off_t,
    ulnow: libcurl.curl_off_t,
) callconv(.c) c_int {
    _ = dltotal;
    _ = dlnow;
    _ = ultotal;
    _ = ulnow;
    const state: *CallbackCtx = @ptrCast(@alignCast(clientp.?));
    if (state.control.isCancelled()) {
        state.aborted = .cancelled;
        return 1;
    }
    if (state.control.isExpired(rc.monoNowNs())) {
        state.aborted = .timeout;
        return 1;
    }
    return 0;
}

fn mapCurlDiag(diag: curl.Diagnostics, control: RequestControl) Error {
    if (control.isCancelled()) return error.Cancelled;
    if (control.isExpired(rc.monoNowNs())) return error.Timeout;
    if (diag.error_code) |ec| {
        switch (ec) {
            .code => |code| {
                if (code == libcurl.CURLE_OPERATION_TIMEDOUT) return error.Timeout;
                if (code == libcurl.CURLE_ABORTED_BY_CALLBACK) {
                    if (control.isCancelled()) return error.Cancelled;
                    return error.Timeout;
                }
            },
            .m_code => {},
        }
    }
    return error.HttpFailed;
}

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

test "curl buildUrl joins base and path" {
    const gpa = std.testing.allocator;
    const url_a = try buildUrl(gpa, "https://api.anthropic.com/", "/v1/messages");
    defer gpa.free(url_a);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url_a);
}

test "curl preflight cancel before network" {
    var flag: rc.CancelFlag = .{};
    flag.request();
    try std.testing.expectError(error.Cancelled, rc.preflight(RequestControl.none().withCancel(&flag)));
}
