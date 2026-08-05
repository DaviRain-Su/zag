//! Redact → UTF-8 validate → exact-cap truncate → copy into preallocated slot.
//! Never raw fallback; never redactOptional(null).

const std = @import("std");
const coding = @import("zag-coding-agent");
const c = @import("constants.zig");

pub const PresentError = error{OutOfMemory};

/// Copy `src` into `dst` (capacity = dst.len) with exact truncation marker rules.
/// Returns number of bytes written into dst.
pub fn copyTruncated(dst: []u8, src: []const u8) usize {
    if (dst.len == 0) return 0;
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    if (dst.len < c.truncation_marker_len) {
        // Frozen caps avoid this; prefer empty + fail marker at caller for zero-cap edge.
        return 0;
    }
    const prefix_cap = dst.len - c.truncation_marker_len;
    const prefix = utf8Prefix(src, prefix_cap);
    @memcpy(dst[0..prefix.len], prefix);
    @memcpy(dst[prefix.len..][0..c.truncation_marker_len], c.truncation_marker);
    return prefix.len + c.truncation_marker_len;
}

/// Longest prefix of `src` within `max_bytes` that ends on a UTF-8 codepoint
/// boundary (drops an incomplete trailing multi-byte sequence).
pub fn utf8Prefix(src: []const u8, max_bytes: usize) []const u8 {
    if (max_bytes == 0) return src[0..0];
    var end = @min(src.len, max_bytes);
    // Fully fits — nothing to cut (a complete trailing multi-byte char must
    // survive; only an *incomplete* tail sequence is dropped below).
    if (end == src.len) return src;
    while (end > 0 and (src[end - 1] & 0xC0) == 0x80) {
        end -= 1;
    }
    // Drop incomplete leading multi-byte start if cut mid-sequence.
    if (end > 0 and (src[end - 1] & 0x80) != 0) {
        const b = src[end - 1];
        if ((b & 0xE0) == 0xC0 or (b & 0xF0) == 0xE0 or (b & 0xF8) == 0xF0) {
            end -= 1;
        }
    }
    return src[0..end];
}

pub fn isValidUtf8(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

/// Full pipeline for arbitrary outward bytes.
/// Writes into `dst`; returns written length. Markers are exact ASCII.
pub fn presentInto(
    gpa: std.mem.Allocator,
    redactor: ?*const coding.redact.Redactor,
    dst: []u8,
    full_input: []const u8,
) usize {
    if (redactor == null) {
        return writeExact(dst, c.redaction_unavailable);
    }
    const red = redactor.?.redactAlloc(gpa, full_input) catch {
        return writeExact(dst, c.redaction_failed);
    };
    defer gpa.free(red);
    if (!isValidUtf8(red)) {
        return writeExact(dst, c.invalid_utf8);
    }
    return copyTruncated(dst, red);
}

fn writeExact(dst: []u8, exact: []const u8) usize {
    if (exact.len > dst.len) {
        // Caps always fit markers; degrade to prefix without inventing raw secrets.
        @memcpy(dst, exact[0..dst.len]);
        return dst.len;
    }
    @memcpy(dst[0..exact.len], exact);
    return exact.len;
}

test "copyTruncated exact marker and cap" {
    var buf: [32]u8 = undefined;
    const long = "abcdefghijklmnopqrstuvwxyz0123456789";
    const n = copyTruncated(&buf, long);
    try std.testing.expect(n <= buf.len);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n], c.truncation_marker));
    try std.testing.expect(n == 32);
}

test "copyTruncated short passthrough" {
    var buf: [64]u8 = undefined;
    const n = copyTruncated(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "presentInto missing redactor marker" {
    var buf: [64]u8 = undefined;
    const n = presentInto(std.testing.allocator, null, &buf, "secret");
    try std.testing.expectEqualStrings(c.redaction_unavailable, buf[0..n]);
}

test "utf8Prefix full fit keeps complete trailing multibyte char" {
    // A fully-fitting prefix must not drop the last complete codepoint.
    try std.testing.expectEqualStrings("aé", utf8Prefix("aé", 3));
    try std.testing.expectEqualStrings("aé", utf8Prefix("aé", 99));
    try std.testing.expectEqualStrings("", utf8Prefix("é", 1)); // cut mid-char → drop
    try std.testing.expectEqualStrings("a", utf8Prefix("aé", 1));
    try std.testing.expectEqualStrings("ab", utf8Prefix("abé", 3)); // é partial at cut
}

test "presentInto redacts secret" {
    const gpa = std.testing.allocator;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    var buf: [256]u8 = undefined;
    const input = "hold " ++ secret;
    const n = presentInto(gpa, &r, &buf, input);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], coding.redact.marker) != null);
}

test "presentInto OOM is redaction_failed" {
    const gpa = std.testing.allocator;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var buf: [64]u8 = undefined;
    const n = presentInto(failing.allocator(), &r, &buf, "leak " ++ secret);
    try std.testing.expectEqualStrings(c.redaction_failed, buf[0..n]);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], secret) == null);
}
