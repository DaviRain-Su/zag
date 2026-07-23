//! Neutral HTTP helper for wire adapters.
//!
//! Wraps monorepo `openai_zig.transport` (generic HTTP + retries + stream) without
//! pulling OpenAI Chat Completions APIs into Anthropic (or other) adapters.

const std = @import("std");
const Io = std.Io;
const openai = @import("openai_zig");
const wire = @import("wire.zig");
const config_mod = @import("config.zig");

const transport_mod = openai.transport;

pub const Error = wire.Error;
pub const Config = config_mod.Config;
pub const StreamChunk = transport_mod.Transport.StreamChunk;
pub const Response = transport_mod.Transport.Response;

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: transport_mod.Transport,
    /// Stable buffer for header auth values (e.g. x-api-key).
    owned_key: ?[]u8 = null,

    /// OpenAI-style Bearer auth from `config.api_key`.
    pub fn initBearer(allocator: std.mem.Allocator, io: Io, config: Config) Error!Client {
        const transport = transport_mod.Transport.init(allocator, io, .{
            .base_url = config.base_url,
            .api_key = config.api_key,
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
        }) catch return error.HttpFailed;
        return .{ .allocator = allocator, .transport = transport };
    }

    /// Header auth (Anthropic): `header_name: api_key` plus optional static extras.
    /// `extra` values must outlive the client (string literals OK).
    pub fn initHeaderAuth(
        allocator: std.mem.Allocator,
        io: Io,
        config: Config,
        header_name: []const u8,
        extra: []const std.http.Header,
    ) Error!Client {
        const key_copy = allocator.dupe(u8, config.api_key) catch return error.OutOfMemory;
        errdefer allocator.free(key_copy);

        var list: std.ArrayList(std.http.Header) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, .{ .name = header_name, .value = key_copy });
        try list.appendSlice(allocator, extra);

        const transport = transport_mod.Transport.init(allocator, io, .{
            .base_url = config.base_url,
            .api_key = null,
            .extra_headers = list.items,
            .timeout_ms = config.timeout_ms,
            .max_retries = config.max_retries,
            .retry_base_delay_ms = config.retry_base_delay_ms,
        }) catch return error.HttpFailed;

        return .{
            .allocator = allocator,
            .transport = transport,
            .owned_key = key_copy,
        };
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        if (self.owned_key) |k| self.allocator.free(k);
        self.* = undefined;
    }

    pub fn postJson(self: *Client, path: []const u8, body: []const u8) Error!Response {
        return self.transport.requestWithOptions(
            .POST,
            path,
            &.{
                .{ .name = "Accept", .value = "application/json" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            body,
            null,
        ) catch |err| mapErr(err);
    }

    pub fn freeBody(self: *Client, body: []u8) void {
        self.transport.allocator.free(body);
    }

    pub fn postJsonStream(
        self: *Client,
        path: []const u8,
        body: []const u8,
        on_chunk: StreamChunk,
        chunk_ctx: ?*anyopaque,
    ) Error!void {
        self.transport.requestStreamWithOptions(
            .POST,
            path,
            &.{
                .{ .name = "Accept", .value = "text/event-stream" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
            body,
            on_chunk,
            chunk_ctx,
            null,
        ) catch |err| return mapErr(err);
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
};

pub fn mapErr(err: anyerror) Error {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "AuthenticationError")) return error.AuthenticationFailed;
    if (std.mem.eql(u8, name, "PermissionDeniedError")) return error.PermissionDenied;
    if (std.mem.eql(u8, name, "RateLimitError")) return error.RateLimited;
    if (std.mem.eql(u8, name, "Timeout") or std.mem.eql(u8, name, "TimeoutError")) return error.Timeout;
    if (std.mem.eql(u8, name, "InternalServerError")) return error.ServerError;
    if (std.mem.eql(u8, name, "BadRequestError") or
        std.mem.eql(u8, name, "UnprocessableEntityError") or
        std.mem.eql(u8, name, "NotFoundError") or
        std.mem.eql(u8, name, "ConflictError"))
        return error.BadRequest;
    if (std.mem.eql(u8, name, "DeserializeError") or std.mem.eql(u8, name, "SerializeError"))
        return error.InvalidResponse;
    if (std.mem.eql(u8, name, "WriteFailed")) return error.WriteFailed;
    return error.HttpFailed;
}
