//! Model-plane log scrubbing (h-redact-001).
//!
//! Keeps the model plane free of an agent-core dependency (no package cycle).
//! Full pattern+exact policy lives in `zag-agent-core` `redact.zig` and is applied
//! on the product path (verbose/trace/session). This module covers HTTP/config
//! diagnostics only:
//!
//! - Never log `Authorization` headers or raw API keys (transports do not log them).
//! - Scrub exact configured secrets from body/error/URL previews before stderr.
//! - Mask URL userinfo (`scheme://user:pass@host`).
//! - Fail closed on OOM: never return a raw borrow of secret-bearing text.
//!
//! Low-level raw HTTP that intentionally skips scrubbing must not call these
//! helpers. Pattern shapes are applied at the agent-core boundary; callers that
//! need patterns here should pre-scrub with a core Redactor or pass exact secrets.

const std = @import("std");

pub const marker: []const u8 = "[REDACTED]";
pub const min_secret_len: usize = 8;
pub const Error = error{OutOfMemory};

/// Scrub exact secrets (longest-first) from `text`. Empty/short secrets ignored.
pub fn scrubExact(
    gpa: std.mem.Allocator,
    text: []const u8,
    secrets: []const []const u8,
) Error![]u8 {
    // Collect usable secrets sorted by length desc (stack-bounded small N).
    var usable: [16][]const u8 = undefined;
    var n: usize = 0;
    for (secrets) |s| {
        if (s.len < min_secret_len) continue;
        if (n >= usable.len) break;
        usable[n] = s;
        n += 1;
    }
    // Insertion sort longest first.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and usable[j - 1].len < usable[j].len) : (j -= 1) {
            const tmp = usable[j - 1];
            usable[j - 1] = usable[j];
            usable[j] = tmp;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos < text.len) {
        var matched: ?usize = null;
        for (usable[0..n]) |sec| {
            if (sec.len <= text.len - pos and std.mem.eql(u8, text[pos .. pos + sec.len], sec)) {
                matched = sec.len;
                break;
            }
        }
        if (matched) |mlen| {
            out.appendSlice(gpa, marker) catch return error.OutOfMemory;
            pos += mlen;
        } else {
            out.append(gpa, text[pos]) catch return error.OutOfMemory;
            pos += 1;
        }
    }
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Scrub a URL: strip userinfo, then exact secrets.
pub fn scrubUrlForLog(
    gpa: std.mem.Allocator,
    url: []const u8,
    secrets: []const []const u8,
) Error![]u8 {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);

    var base: []const u8 = url;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const after = url[scheme_end + 3 ..];
        if (std.mem.indexOfScalar(u8, after, '@')) |at| {
            const authority = after[0..at];
            if (std.mem.indexOfScalar(u8, authority, '/') == null) {
                tmp.appendSlice(gpa, url[0 .. scheme_end + 3]) catch return error.OutOfMemory;
                tmp.appendSlice(gpa, marker ++ "@") catch return error.OutOfMemory;
                tmp.appendSlice(gpa, after[at + 1 ..]) catch return error.OutOfMemory;
                base = tmp.items;
            }
        }
    }
    return scrubExact(gpa, base, secrets);
}

test "scrubExact removes configured secret" {
    const gpa = std.testing.allocator;
    const fake = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const out = try scrubExact(gpa, "x=" ++ fake ++ "y", &.{fake});
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, fake) == null);
    try std.testing.expectEqualStrings("x=" ++ marker ++ "y", out);
}

test "scrubExact ignores short secrets" {
    const gpa = std.testing.allocator;
    const out = try scrubExact(gpa, "abc short", &.{ "abc", "short" });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abc short", out);
}

test "scrubUrlForLog userinfo" {
    const gpa = std.testing.allocator;
    const out = try scrubUrlForLog(gpa, "https://user:supersecret@api.example/v1", &.{});
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "supersecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "api.example") != null);
}
