//! comptime-serde — compile-time serialization and deserialization for Zig.
//!
//! Zag library mirror of jiacai2050/comptime-serde v0.2.0 (**JSON only**).
//! Upstream also ships TOML/YAML/Protobuf + serde-gen CLI; those are omitted here.

const std = @import("std");
pub const json = @import("formats/json.zig");
const common = @import("formats/common.zig");

pub const Format = enum { json };

/// Returns a comptime-generated type with serialize/deserialize methods
/// for `T` in the given `format`.
pub fn Serde(comptime format: Format, comptime T: type) type {
    return switch (format) {
        .json => json.Serde(T),
    };
}

/// Owns a deserialized value and its backing arena allocator; call `deinit()` to free.
pub const Parsed = common.Parsed;

test {
    std.testing.refAllDecls(@This());
}
