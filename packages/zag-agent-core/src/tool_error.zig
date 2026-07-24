//! Machine-readable tool soft-fail strings (H1).
//!
//! Shape (stable for golden / evals):
//!   error: code=<CODE> message=<human>
//!
//! Tool-specific codes (e.g. anchor_not_found) may also use `code=`;
//! this module covers harness-level codes from loop-turn.md.

const std = @import("std");

pub const Code = enum {
    unknown_tool,
    invalid_arguments,
    permission_denied,
    jail_deny,
    shell_deny,
    tool_failed,
    cancelled,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .unknown_tool => "unknown_tool",
            .invalid_arguments => "invalid_arguments",
            .permission_denied => "permission_denied",
            .jail_deny => "jail_deny",
            .shell_deny => "shell_deny",
            .tool_failed => "tool_failed",
            .cancelled => "cancelled",
        };
    }

    pub fn parse(s: []const u8) ?Code {
        inline for (@typeInfo(Code).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Code, f.name);
        }
        return null;
    }
};

/// Format a soft-fail tool result. Caller owns the slice.
pub fn format(
    gpa: std.mem.Allocator,
    code: Code,
    message_human: []const u8,
) std.mem.Allocator.Error![]u8 {
    std.debug.assert(message_human.len > 0);
    return std.fmt.allocPrint(
        gpa,
        "error: code={s} message={s}",
        .{ code.name(), message_human },
    );
}

/// True when `body` contains `code=<name>` for this harness code.
pub fn hasCode(body: []const u8, code: Code) bool {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "code={s}", .{code.name()}) catch return false;
    return std.mem.indexOf(u8, body, needle) != null;
}

/// Extract `code=` token when present (first occurrence).
pub fn extractCode(body: []const u8) ?[]const u8 {
    const key = "code=";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    const from = start + key.len;
    var end = from;
    while (end < body.len) : (end += 1) {
        const c = body[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
    }
    if (end == from) return null;
    return body[from..end];
}

test "format and hasCode" {
    // Goal: stable prefix is parseable by golden/evals.
    const gpa = std.testing.allocator;
    const s = try format(gpa, .permission_denied, "user rejected write_file");
    defer gpa.free(s);
    try std.testing.expect(hasCode(s, .permission_denied));
    try std.testing.expect(!hasCode(s, .jail_deny));
    try std.testing.expectEqualStrings("permission_denied", extractCode(s).?);
    try std.testing.expect(Code.parse("jail_deny").? == .jail_deny);
    try std.testing.expect(Code.parse("nope") == null);
}
