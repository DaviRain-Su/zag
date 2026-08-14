//! Frame codec for the zag-live image protocol.
//!
//! Wire format: 4-byte little-endian u32 length + UTF-8 payload; the payload
//! is exactly one s-expression, single line. String literals use ONE escaping
//! discipline both directions — canonical Gambit `write` escapes:
//!
//!   \" \\ \n \r \t \a \b \v \f      named escapes
//!   \xhh;                           any other byte < 0x20 or 0x7F, lowercase
//!                                   minimal hex, semicolon-terminated
//!                                   (Gambit canonical; decode is
//!                                   case-insensitive on hex digits)
//!   bytes >= 0x80                   raw (payloads must be valid UTF-8)
//!
//! Decoding is strict: an unknown escape or malformed \x..; is a hard error,
//! never silently mangled. Arbitrary control bytes (incl. NUL), quotes,
//! backslashes, literal `\x..;` text, and UTF-8 round-trip byte-identically
//! (spike-002 fuzz evidence: 1500/1500 adversarial strings).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Max frame payload, both directions. Must match max-frame-bytes in
/// assets/runtime.ss.
pub const max_frame_bytes: u32 = 4 * 1024 * 1024;

pub const Error = error{
    FrameTooLarge,
    ProtocolError,
    UnknownEscape,
    BadHexEscape,
    UnterminatedString,
    ExpectedString,
    Eof,
};

/// Write one frame. Payloads larger than the cap are rejected locally.
pub fn writeFrame(io: Io, file: Io.File, payload: []const u8) !void {
    if (payload.len > max_frame_bytes) return error.FrameTooLarge;
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .little);
    try file.writeStreamingAll(io, &hdr);
    try file.writeStreamingAll(io, payload);
}

/// Write one frame WITHOUT the cap check. Test seam: exercises the image's
/// own inbound rejection (acceptance class 5).
pub fn writeFrameUnchecked(io: Io, file: Io.File, payload: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .little);
    try file.writeStreamingAll(io, &hdr);
    try file.writeStreamingAll(io, payload);
}

fn readExact(io: Io, file: Io.File, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = file.readStreaming(io, &.{buf[off..]}) catch |e| switch (e) {
            error.EndOfStream => return error.Eof,
            else => return e,
        };
        if (n == 0) return error.Eof;
        off += n;
    }
}

/// Read one frame. Returns null on clean EOF at a frame boundary;
/// error.FrameTooLarge when the length prefix exceeds the cap (caller decides
/// image disposition); error.Eof on a torn frame.
pub fn readFrame(gpa: Allocator, io: Io, file: Io.File) !?[]u8 {
    var hdr: [4]u8 = undefined;
    readExact(io, file, &hdr) catch |e| switch (e) {
        error.Eof => return null,
        else => return e,
    };
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > max_frame_bytes) return error.FrameTooLarge;
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    try readExact(io, file, buf);
    return buf;
}

/// Read one frame with a wall-clock deadline (poll on the pipe fd). Returns
/// null on clean EOF; error.DeadlineExceeded when the deadline expires
/// before any frame byte arrives.
pub fn readFrameDeadline(
    gpa: Allocator,
    io: Io,
    file: Io.File,
    deadline_ms: u32,
) !?[]u8 {
    var fds = [_]std.posix.pollfd{
        .{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const n = std.posix.poll(&fds, @intCast(deadline_ms)) catch return error.PollFailed;
    if (n == 0) return error.DeadlineExceeded;
    return try readFrame(gpa, io, file);
}

// ---------- canonical Gambit string escaping ----------

pub const EscapeError = Allocator.Error;

/// Escape an arbitrary byte string into Gambit `write` canonical literal form
/// (without the surrounding quotes).
pub fn escape(gpa: Allocator, s: []const u8) EscapeError![]u8 {
    const hexdig = "0123456789abcdef";
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '"' => try list.appendSlice(gpa, "\\\""),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            0x07 => try list.appendSlice(gpa, "\\a"),
            0x08 => try list.appendSlice(gpa, "\\b"),
            0x0b => try list.appendSlice(gpa, "\\v"),
            0x0c => try list.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try list.appendSlice(gpa, "\\x");
                    if (c >= 0x10) try list.append(gpa, hexdig[c >> 4]);
                    try list.append(gpa, hexdig[c & 0xf]);
                    try list.append(gpa, ';');
                } else {
                    try list.append(gpa, c);
                }
            },
        }
    }
    return list.toOwnedSlice(gpa);
}

pub const ParsedString = struct { value: []u8, end: usize };

/// Parse a `"..."` Scheme string literal starting at s[start]; returns the
/// unescaped value and the index just past the closing quote. Strict:
/// unknown escapes and malformed \x..; are errors.
pub fn parseString(gpa: Allocator, s: []const u8, start: usize) !ParsedString {
    if (start >= s.len or s[start] != '"') return error.ExpectedString;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var i = start + 1;
    while (true) {
        if (i >= s.len) return error.UnterminatedString;
        const c = s[i];
        if (c == '"') return .{ .value = try list.toOwnedSlice(gpa), .end = i + 1 };
        if (c != '\\') {
            try list.append(gpa, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) return error.UnterminatedString;
        switch (s[i]) {
            'n' => try list.append(gpa, '\n'),
            't' => try list.append(gpa, '\t'),
            'r' => try list.append(gpa, '\r'),
            'a' => try list.append(gpa, 0x07),
            'b' => try list.append(gpa, 0x08),
            'v' => try list.append(gpa, 0x0b),
            'f' => try list.append(gpa, 0x0c),
            '\\' => try list.append(gpa, '\\'),
            '"' => try list.append(gpa, '"'),
            'x' => {
                i += 1;
                var cp: u21 = 0;
                var digits: usize = 0;
                while (i < s.len and s[i] != ';') : (i += 1) {
                    const d = std.fmt.charToDigit(s[i], 16) catch
                        return error.BadHexEscape;
                    cp = std.math.mul(u21, cp, 16) catch return error.BadHexEscape;
                    cp = std.math.add(u21, cp, d) catch return error.BadHexEscape;
                    digits += 1;
                }
                if (i >= s.len or digits == 0) return error.BadHexEscape;
                var ubuf: [4]u8 = undefined;
                const ulen = std.unicode.utf8Encode(cp, &ubuf) catch
                    return error.BadHexEscape;
                try list.appendSlice(gpa, ubuf[0..ulen]);
            },
            else => return error.UnknownEscape,
        }
        i += 1;
    }
}

/// Skip horizontal whitespace.
pub fn skipSpaces(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// Read a bare symbol/token (no spaces, parens).
pub fn readToken(s: []const u8, start: usize) struct { tok: []const u8, end: usize } {
    var i = start;
    while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != ')' and s[i] != '(') i += 1;
    return .{ .tok = s[start..i], .end = i };
}

/// Extract the datum from `(ok <datum>)` / `(err <datum>)`: a string literal
/// (unescaped) or the raw text up to (but excluding) the frame's own final
/// `)`. The trim strips exactly ONE closing paren — the datum itself may be
/// a list whose parens must survive.
pub fn parseDatum(gpa: Allocator, fr: []const u8, start: usize) ![]u8 {
    const i = skipSpaces(fr, start);
    if (i < fr.len and fr[i] == '"') {
        const ps = try parseString(gpa, fr, i);
        return ps.value;
    }
    var end = fr.len;
    while (end > i and fr[end - 1] == ' ') end -= 1;
    if (end > i and fr[end - 1] == ')') end -= 1;
    while (end > i and fr[end - 1] == ' ') end -= 1;
    return try gpa.dupe(u8, fr[i..end]);
}

pub const Reply = union(enum) { ok: []u8, err: []u8 };

/// Classify a reply frame. Returns null when the frame is not a reply.
pub fn parseReply(gpa: Allocator, fr: []const u8) !?Reply {
    if (std.mem.startsWith(u8, fr, "(ok ") or std.mem.eql(u8, fr, "(ok)")) {
        if (fr.len <= 3) return Reply{ .ok = try gpa.dupe(u8, "") };
        return Reply{ .ok = try parseDatum(gpa, fr, 3) };
    }
    if (std.mem.startsWith(u8, fr, "(err ")) {
        return Reply{ .err = try parseDatum(gpa, fr, 4) };
    }
    return null;
}

pub fn isReplyFrame(fr: []const u8) bool {
    return std.mem.startsWith(u8, fr, "(ok ") or
        std.mem.startsWith(u8, fr, "(err ") or
        std.mem.eql(u8, fr, "(ok)");
}

test "escape/parse round-trip on nasty strings" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "\"quoted\"",
        "back\\slash",
        "literal \\x41; text",
        "nul\x00byte",
        "ctrl\x01\x1f\x7f",
        "\x07\x08\x0b\x0c named",
        "λ日本語🚀",
        "line1\nline2\r\n\ttab",
    };
    for (cases) |s| {
        const esc = try escape(gpa, s);
        defer gpa.free(esc);
        const wrapped = try std.fmt.allocPrint(gpa, "\"{s}\"", .{esc});
        defer gpa.free(wrapped);
        const ps = try parseString(gpa, wrapped, 0);
        defer gpa.free(ps.value);
        try std.testing.expectEqualStrings(s, ps.value);
        try std.testing.expectEqual(wrapped.len, ps.end);
    }
}

test "strict decode: unknown escapes and malformed hex are loud" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownEscape, parseString(gpa, "\"a\\q b\"", 0));
    try std.testing.expectError(error.UnknownEscape, parseString(gpa, "\"\\e\"", 0));
    try std.testing.expectError(error.BadHexEscape, parseString(gpa, "\"\\xZZ;\"", 0));
    try std.testing.expectError(error.BadHexEscape, parseString(gpa, "\"\\x;\"", 0));
    try std.testing.expectError(error.UnterminatedString, parseString(gpa, "\"abc", 0));
    // hex escapes decode to UTF-8 bytes
    const ps = try parseString(gpa, "\"\\x41;\\x0;\\x3BB;\"", 0);
    defer gpa.free(ps.value);
    try std.testing.expectEqualStrings("A\x00\xce\xbb", ps.value);
}

test "parseDatum keeps a list datum's own parens" {
    const gpa = std.testing.allocator;
    const d = try parseDatum(gpa, "(ok ((source \"x\") (status committed)))", 3);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("((source \"x\") (status committed))", d);
}
