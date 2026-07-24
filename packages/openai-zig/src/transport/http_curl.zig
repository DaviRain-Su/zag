//! HTTP transport backend: zig-curl / libcurl.
//!
//! Selected when `-Dhttp_backend=curl`. Same `Transport` surface as `http_std.zig`.
//! Reuses URL/retry helpers from `http_std.zig`. Proxy uses CURLOPT_PROXY (string).

const std = @import("std");
const Io = std.Io;
const curl = @import("curl");
const libcurl = curl.libcurl;
const errors = @import("../errors.zig");
const shared = @import("http_std.zig");
const lifecycle = @import("lifecycle.zig");

var curl_global_ready: std.atomic.Value(bool) = .init(false);

fn ensureCurlGlobal() void {
    if (curl_global_ready.load(.acquire)) return;
    curl.globalInit() catch {};
    curl_global_ready.store(true, .release);
}

fn mapMethod(method: std.http.Method) !curl.Easy.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .HEAD => .HEAD,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        else => error.Unsupported,
    };
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    base_url: []const u8,
    api_key: ?[]const u8,
    organization: ?[]const u8,
    project: ?[]const u8,
    proxy_url: ?[]const u8,
    owns_base_url: bool,
    owns_api_key: bool,
    owns_organization: bool,
    owns_project: bool,
    timeout_ms: ?u64 = null,
    max_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    extra_headers: []const std.http.Header,
    owns_extra_headers: bool,
    ca_bundle: std.ArrayList(u8),
    request_control: lifecycle.Control = .{},

    pub const Options = shared.Transport.Options;
    pub const RequestOptions = shared.Transport.RequestOptions;
    pub const ActiveRequestOptions = shared.Transport.ActiveRequestOptions;
    pub const Response = struct {
        status: u16,
        body: []u8,
    };
    pub const StreamChunk = *const fn (ctx: ?*anyopaque, chunk: []const u8) errors.Error!void;

    pub fn init(allocator: std.mem.Allocator, io: Io, opts: Options) !Transport {
        ensureCurlGlobal();
        const ExtraConfig = struct { headers: []const std.http.Header, owns: bool };
        const extra_config = if (opts.extra_headers) |headers| blk: {
            const duped = try allocator.dupe(std.http.Header, headers);
            break :blk ExtraConfig{ .headers = duped, .owns = true };
        } else blk: {
            break :blk ExtraConfig{ .headers = &.{}, .owns = false };
        };

        const base_url = try allocator.dupe(u8, opts.base_url);
        errdefer allocator.free(base_url);
        const api_key = if (opts.api_key) |key| try allocator.dupe(u8, key) else null;
        errdefer if (api_key) |k| allocator.free(k);
        const organization = if (opts.organization) |o| try allocator.dupe(u8, o) else null;
        errdefer if (organization) |o| allocator.free(o);
        const project = if (opts.project) |p| try allocator.dupe(u8, p) else null;
        errdefer if (project) |p| allocator.free(p);
        const proxy_url = if (opts.proxy) |url| try allocator.dupe(u8, url) else null;
        errdefer if (proxy_url) |u| allocator.free(u);

        var ca_bundle = try curl.allocCABundle(allocator, io);
        errdefer ca_bundle.deinit(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .base_url = base_url,
            .api_key = api_key,
            .organization = organization,
            .project = project,
            .proxy_url = proxy_url,
            .owns_base_url = true,
            .owns_api_key = api_key != null,
            .owns_organization = organization != null,
            .owns_project = project != null,
            .timeout_ms = opts.timeout_ms,
            .max_retries = opts.max_retries,
            .retry_base_delay_ms = opts.retry_base_delay_ms,
            .extra_headers = extra_config.headers,
            .owns_extra_headers = extra_config.owns,
            .ca_bundle = ca_bundle,
        };
    }

    pub fn setRequestControl(self: *Transport, control: lifecycle.Control) void {
        self.request_control = control;
    }

    pub fn clearRequestControl(self: *Transport) void {
        self.request_control = .{};
    }

    pub fn deinit(self: *Transport) void {
        self.ca_bundle.deinit(self.allocator);
        if (self.owns_base_url) self.allocator.free(self.base_url);
        if (self.owns_api_key) if (self.api_key) |k| self.allocator.free(k);
        if (self.owns_organization) if (self.organization) |o| self.allocator.free(o);
        if (self.owns_project) if (self.project) |p| self.allocator.free(p);
        if (self.proxy_url) |u| self.allocator.free(u);
        if (self.owns_extra_headers) self.allocator.free(self.extra_headers);
        self.* = undefined;
    }

    pub fn resolveRequestOptions(self: *const Transport, req_opts: ?RequestOptions) ActiveRequestOptions {
        if (req_opts) |opts| {
            return .{
                .base_url = opts.base_url orelse self.base_url,
                .api_key = opts.api_key orelse self.api_key,
                .organization = opts.organization orelse self.organization,
                .project = opts.project orelse self.project,
                .timeout_ms = opts.timeout_ms orelse self.timeout_ms,
                .max_retries = opts.max_retries orelse self.max_retries,
                .retry_base_delay_ms = opts.retry_base_delay_ms orelse self.retry_base_delay_ms,
                .extra_headers = opts.extra_headers,
            };
        }
        return .{
            .base_url = self.base_url,
            .api_key = self.api_key,
            .organization = self.organization,
            .project = self.project,
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .retry_base_delay_ms = self.retry_base_delay_ms,
            .extra_headers = null,
        };
    }

    pub fn request(
        self: *Transport,
        method: std.http.Method,
        path: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
    ) errors.Error!Response {
        return self.requestWithOptions(method, path, headers, body, null);
    }

    pub fn requestWithOptions(
        self: *Transport,
        method: std.http.Method,
        path: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        req_opts: ?RequestOptions,
    ) errors.Error!Response {
        return self.requestInternal(method, path, headers, body, false, null, null, req_opts);
    }

    pub fn requestStream(
        self: *Transport,
        method: std.http.Method,
        path: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        on_chunk: StreamChunk,
        chunk_ctx: ?*anyopaque,
    ) errors.Error!void {
        return self.requestStreamWithOptions(method, path, headers, body, on_chunk, chunk_ctx, null);
    }

    pub fn requestStreamWithOptions(
        self: *Transport,
        method: std.http.Method,
        path: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        on_chunk: StreamChunk,
        chunk_ctx: ?*anyopaque,
        req_opts: ?RequestOptions,
    ) errors.Error!void {
        _ = try self.requestInternal(method, path, headers, body, true, on_chunk, chunk_ctx, req_opts);
    }

    fn requestInternal(
        self: *Transport,
        method: std.http.Method,
        path: []const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        stream: bool,
        on_chunk: ?StreamChunk,
        chunk_ctx: ?*anyopaque,
        req_opts: ?RequestOptions,
    ) errors.Error!Response {
        const active_opts = self.resolveRequestOptions(req_opts);
        const control = lifecycle.mergeConfiguredTimeout(self.request_control, active_opts.timeout_ms);
        try lifecycle.assertSupported(control);
        try control.checkNow();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const request_base_url = shared.resolveRequestBaseUrl(alloc, active_opts.base_url, path, body) catch {
            return errors.Error.HttpError;
        };
        const url = shared.buildUrl(alloc, request_base_url, path) catch return errors.Error.HttpError;
        const url_z = alloc.dupeZ(u8, url) catch return errors.Error.HttpError;
        const curl_method = mapMethod(method) catch return errors.Error.HttpError;

        var attempt: u8 = 0;
        while (attempt <= active_opts.max_retries) : (attempt += 1) {
            try control.checkNow();
            const outcome = self.attemptOnce(
                alloc,
                curl_method,
                url_z,
                headers,
                body,
                stream,
                on_chunk,
                chunk_ctx,
                active_opts,
                control,
            ) catch |err| {
                if (err == error.Cancelled or err == error.Timeout) return shared.mapTransportError(err);
                if (!shared.isRetryableMethod(method) or attempt == active_opts.max_retries) {
                    return shared.mapTransportError(err);
                }
                shared.sleepForRetry(self.io, attempt, null, active_opts);
                continue;
            };

            if (outcome.status < 200 or outcome.status >= 300) {
                if (shared.isRetryableStatus(outcome.status) and attempt < active_opts.max_retries and shared.isRetryableMethod(method)) {
                    if (outcome.body.len > 0) self.allocator.free(outcome.body);
                    shared.sleepForRetry(self.io, attempt, outcome.retry_after_ms, active_opts);
                    continue;
                }
                const err = errors.unexpectedStatus(.{
                    .status = outcome.status,
                    .body = outcome.body,
                    .request_id = outcome.request_id,
                });
                if (outcome.body.len > 0) self.allocator.free(outcome.body);
                return err;
            }

            if (stream) {
                if (outcome.body.len > 0) self.allocator.free(outcome.body);
                return .{ .status = outcome.status, .body = &.{} };
            }
            return .{ .status = outcome.status, .body = outcome.body };
        }
        return errors.Error.HttpError;
    }

    const AttemptOutcome = struct {
        status: u16,
        body: []u8,
        retry_after_ms: ?u64 = null,
        request_id: ?[]const u8 = null,
    };

    fn attemptOnce(
        self: *Transport,
        arena: std.mem.Allocator,
        method: curl.Easy.Method,
        url_z: [:0]const u8,
        headers: []const std.http.Header,
        body: ?[]const u8,
        stream: bool,
        on_chunk: ?StreamChunk,
        chunk_ctx: ?*anyopaque,
        active_opts: ActiveRequestOptions,
        control: lifecycle.Control,
    ) anyerror!AttemptOutcome {
        // 0 = no curl default; set remaining budget explicitly below.
        var easy = try curl.Easy.init(.{
            .ca_bundle = self.ca_bundle,
            .default_timeout_ms = 0,
        });
        defer easy.deinit();

        const timeout_ms = control.curlTimeoutMs(lifecycle.monoNowNs(), active_opts.timeout_ms);
        if (timeout_ms > 0 or control.deadline_mono_ns != null or active_opts.timeout_ms != null) {
            const t: c_long = @intCast(@min(timeout_ms, std.math.maxInt(c_long)));
            if (libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_TIMEOUT_MS, t) != libcurl.CURLE_OK)
                return errors.Error.HttpError;
        }

        // Progress callback context lives for this attempt only; setopt must succeed.
        var life_ctx: CurlLifeCtx = .{ .control = control };
        if (libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_NOPROGRESS, @as(c_long, 0)) != libcurl.CURLE_OK)
            return errors.Error.HttpError;
        if (libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_XFERINFODATA, @as(?*anyopaque, @ptrCast(&life_ctx))) != libcurl.CURLE_OK)
            return errors.Error.HttpError;
        if (libcurl.curl_easy_setopt(easy.handle, libcurl.CURLOPT_XFERINFOFUNCTION, curlXferInfo) != libcurl.CURLE_OK)
            return errors.Error.HttpError;

        if (self.proxy_url) |proxy| {
            const proxy_z = try arena.dupeZ(u8, proxy);
            try curl.checkCode(
                curl.libcurl.curl_easy_setopt(easy.handle, curl.libcurl.CURLOPT_PROXY, proxy_z.ptr),
                &easy.diagnostics,
            );
        }

        var header_list: curl.Easy.Headers = .{};
        defer header_list.deinit();
        var owned_lines: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned_lines.items) |line| self.allocator.free(line);
            owned_lines.deinit(self.allocator);
        }

        const addHeader = struct {
            fn go(
                gpa: std.mem.Allocator,
                list: *curl.Easy.Headers,
                owned: *std.ArrayList([:0]u8),
                name: []const u8,
                value: []const u8,
            ) !void {
                const line = try std.fmt.allocPrintSentinel(gpa, "{s}: {s}", .{ name, value }, 0);
                errdefer gpa.free(line);
                try owned.append(gpa, line);
                try list.add(line);
            }
        }.go;

        for (self.extra_headers) |h| {
            try addHeader(self.allocator, &header_list, &owned_lines, h.name, h.value);
        }
        if (active_opts.extra_headers) |extra| {
            for (extra) |h| {
                try addHeader(self.allocator, &header_list, &owned_lines, h.name, h.value);
            }
        }
        for (headers) |h| {
            try addHeader(self.allocator, &header_list, &owned_lines, h.name, h.value);
        }
        if (active_opts.api_key) |raw_key| {
            const key = std.mem.trim(u8, raw_key, " ");
            const bearer_prefix = "Bearer ";
            const header_value = if (std.mem.startsWith(u8, key, bearer_prefix))
                key
            else
                try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
            try addHeader(self.allocator, &header_list, &owned_lines, "Authorization", header_value);
        }
        if (active_opts.organization) |org| {
            const value = std.mem.trim(u8, org, " ");
            if (value.len > 0) {
                try addHeader(self.allocator, &header_list, &owned_lines, "OpenAI-Organization", value);
            }
        }
        if (active_opts.project) |project| {
            const value = std.mem.trim(u8, project, " ");
            if (value.len > 0) {
                try addHeader(self.allocator, &header_list, &owned_lines, "OpenAI-Project", value);
            }
        }

        try easy.setUrl(url_z);
        try easy.setMethod(method);
        try easy.setHeaders(header_list);
        if (body) |payload| {
            try easy.setPostFields(payload);
        }

        if (stream) {
            const cb = on_chunk orelse return errors.Error.HttpError;
            var stream_state: StreamState = .{
                .on_chunk = cb,
                .chunk_ctx = chunk_ctx,
                .control = control,
            };
            try easy.setWritedata(@ptrCast(&stream_state));
            try easy.setWritefunction(streamWrite);
            const resp = easy.perform() catch {
                if (life_ctx.aborted == .cancelled or stream_state.err == error.Cancelled)
                    return error.Cancelled;
                if (life_ctx.aborted == .timeout or stream_state.err == error.Timeout)
                    return error.Timeout;
                if (stream_state.failed) return stream_state.err;
                return errors.Error.HttpError;
            };
            if (stream_state.failed) return stream_state.err;
            return .{
                .status = @intCast(resp.status_code),
                .body = &.{},
                .retry_after_ms = headerRetryAfterMs(resp),
                .request_id = try headerValueDup(arena, resp, "x-request-id"),
            };
        }

        var body_writer: Io.Writer.Allocating = .init(self.allocator);
        errdefer body_writer.deinit();
        try easy.setWriter(&body_writer.writer);
        const resp = easy.perform() catch {
            if (life_ctx.aborted == .cancelled) return error.Cancelled;
            if (life_ctx.aborted == .timeout) return error.Timeout;
            if (control.isCancelled()) return error.Cancelled;
            if (control.isExpired(lifecycle.monoNowNs())) return error.Timeout;
            return errors.Error.HttpError;
        };
        body_writer.writer.flush() catch {};
        const bytes = try body_writer.toOwnedSlice();
        return .{
            .status = @intCast(resp.status_code),
            .body = bytes,
            .retry_after_ms = headerRetryAfterMs(resp),
            .request_id = try headerValueDup(arena, resp, "x-request-id"),
        };
    }
};

const CurlLifeCtx = struct {
    control: lifecycle.Control,
    aborted: enum { none, cancelled, timeout } = .none,
};

fn curlXferInfo(
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
    const state: *CurlLifeCtx = @ptrCast(@alignCast(clientp.?));
    if (state.control.isCancelled()) {
        state.aborted = .cancelled;
        return 1;
    }
    if (state.control.isExpired(lifecycle.monoNowNs())) {
        state.aborted = .timeout;
        return 1;
    }
    return 0;
}

const StreamState = struct {
    on_chunk: Transport.StreamChunk,
    chunk_ctx: ?*anyopaque,
    control: lifecycle.Control = .{},
    failed: bool = false,
    err: errors.Error = errors.Error.HttpError,
};

fn streamWrite(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    const real_size = size * nmemb;
    const state: *StreamState = @ptrCast(@alignCast(user_data));
    if (state.control.isCancelled()) {
        state.failed = true;
        state.err = error.Cancelled;
        return 0;
    }
    if (state.control.isExpired(lifecycle.monoNowNs())) {
        state.failed = true;
        state.err = error.Timeout;
        return 0;
    }
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    state.on_chunk(state.chunk_ctx, data) catch |err| {
        state.failed = true;
        state.err = err;
        return 0;
    };
    return real_size;
}

fn headerRetryAfterMs(resp: curl.Easy.Response) ?u64 {
    const header = (resp.getHeader("Retry-After") catch return null) orelse return null;
    const raw = std.mem.trim(u8, header.get(), " \t");
    const seconds = std.fmt.parseInt(u64, raw, 10) catch return null;
    return seconds *% 1000;
}

fn headerValueDup(arena: std.mem.Allocator, resp: curl.Easy.Response, name: [:0]const u8) !?[]const u8 {
    const header = (resp.getHeader(name) catch return null) orelse return null;
    return try arena.dupe(u8, header.get());
}

test "curl transport resolves request options" {
    var transport = try Transport.init(std.testing.allocator, std.testing.io, .{
        .base_url = "https://api.local",
        .api_key = "k-default",
        .timeout_ms = 5000,
        .max_retries = 4,
        .retry_base_delay_ms = 250,
    });
    defer transport.deinit();
    const default_opts = transport.resolveRequestOptions(null);
    try std.testing.expectEqualStrings("https://api.local", default_opts.base_url);
    try std.testing.expectEqual(@as(u64, 5000), default_opts.timeout_ms.?);
}
