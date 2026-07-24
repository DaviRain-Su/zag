//! HTTP transport facade for openai-zig.
//!
//! Backend selected at build time (`-Dhttp_backend=std|curl`):
//! - `std` (default) — `std.http.Client` (`http_std.zig`)
//! - `curl` — zig-curl / libcurl (`http_curl.zig`); see Zag D-005

const std = @import("std");
const build_options = @import("openai_build_options");

const impl = switch (build_options.http_backend) {
    .std => @import("http_std.zig"),
    .curl => @import("http_curl.zig"),
};

pub const Transport = impl.Transport;
pub const lifecycle = @import("lifecycle.zig");

pub fn backendName() []const u8 {
    return @tagName(build_options.http_backend);
}

// Keep shared helper / DeepSeek routing tests compiling under either backend.
test {
    _ = @import("http_std.zig");
}

test "transport backend is named" {
    const name = backendName();
    try std.testing.expect(std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "curl"));
}
