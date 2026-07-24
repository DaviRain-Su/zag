//! Neutral HTTP client for wire adapters (no openai_zig dependency).
//!
//! Backend selected at build time (`-Dhttp_backend=std|curl`):
//! - `std` (default) — Zig `std.http.Client` (`http_std.zig`)
//! - `curl` — zig-curl / libcurl (`http_curl.zig`); see D-005
//!
//! Auth is explicit: Bearer vs custom headers (Anthropic `x-api-key`).
//!
//! **Logging (h-redact-001):** this transport does not log Authorization headers,
//! API keys, response bodies, or credential-bearing URLs. Diagnostics stay
//! status/length class only. Product redaction lives in zag-agent-core.

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

/// Diagnostic label for bake-off / HTTP tooling base URL (h-redact-001).
/// Always returns the fixed token `BASE_URL=configured` — never interpolates
/// caller/env URL bytes (`base_url` may contain userinfo or query secrets).
/// `base_url` is accepted only so call sites can pass the real value without
/// a separate print path that might echo it.
pub fn formatConfiguredBaseUrlStatus(base_url: []const u8) []const u8 {
    _ = base_url;
    return "BASE_URL=configured";
}

test "http backend is named" {
    const name = backendName();
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "curl"));
}

test "formatConfiguredBaseUrlStatus never echoes secret-bearing URL" {
    const secret_url = "https://user:secret@example.invalid/?token=sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const out = formatConfiguredBaseUrlStatus(secret_url);
    try std.testing.expectEqualStrings("BASE_URL=configured", out);
    try std.testing.expect(std.mem.indexOf(u8, out, secret_url) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "user") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "token=") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "example.invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://") == null);
}
