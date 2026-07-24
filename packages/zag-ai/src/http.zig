//! Neutral HTTP client for wire adapters (no openai_zig dependency).
//!
//! Backend selected at build time (`-Dhttp_backend=std|curl`):
//! - `std` (default) — Zig `std.http.Client` (`http_std.zig`)
//! - `curl` — zig-curl / libcurl (`http_curl.zig`); see D-005
//!
//! Auth is explicit: Bearer vs custom headers (Anthropic `x-api-key`).

const std = @import("std");
const build_options = @import("build_options");

const impl = switch (build_options.http_backend) {
    .std => @import("http_std.zig"),
    .curl => @import("http_curl.zig"),
};

pub const Error = impl.Error;
pub const Config = impl.Config;
pub const Response = impl.Response;
pub const StreamChunk = impl.StreamChunk;
pub const Client = impl.Client;

pub fn backendName() []const u8 {
    return @tagName(build_options.http_backend);
}

test "http backend is named" {
    const name = backendName();
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "curl"));
}
