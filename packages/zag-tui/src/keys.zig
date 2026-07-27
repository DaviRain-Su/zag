//! Bounded key decoder for raw-mode stdin bytes.

const std = @import("std");

pub const Key = union(enum) {
    char: u8,
    enter,
    alt_enter,
    escape,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    ctrl_c,
    ctrl_d,
    ctrl_j,
    alt_s,
    alt_f,
    unknown,
};

/// Decode one key from a byte stream buffer. Returns key + bytes consumed.
/// Incomplete escape sequences return null (wait for more input).
pub fn decode(buf: []const u8) ?struct { key: Key, n: usize } {
    if (buf.len == 0) return null;
    const b0 = buf[0];

    // C0 controls
    if (b0 == 0x03) return .{ .key = .ctrl_c, .n = 1 };
    if (b0 == 0x04) return .{ .key = .ctrl_d, .n = 1 };
    if (b0 == 0x0a or b0 == 0x0d) return .{ .key = .enter, .n = 1 };
    if (b0 == 0x0a) return .{ .key = .ctrl_j, .n = 1 }; // unreachable after above; keep Ctrl+J as enter-class
    if (b0 == 0x7f or b0 == 0x08) return .{ .key = .backspace, .n = 1 };
    if (b0 == 0x1b) {
        if (buf.len == 1) {
            // Could be bare Esc or incomplete sequence — treat single Esc after
            // no further bytes as Escape only when caller flushes; here wait if
            // we cannot know. For poll-driven UI, lone ESC is Escape.
            return .{ .key = .escape, .n = 1 };
        }
        // Alt+key: ESC + printable
        if (buf[1] != '[') {
            const ch = buf[1];
            if (ch == '\r' or ch == '\n') return .{ .key = .alt_enter, .n = 2 };
            if (ch == 's' or ch == 'S') return .{ .key = .alt_s, .n = 2 };
            if (ch == 'f' or ch == 'F') return .{ .key = .alt_f, .n = 2 };
            // Alt+Enter sometimes as ESC then enter already handled.
            return .{ .key = .{ .char = ch }, .n = 2 };
        }
        // CSI sequences
        if (buf.len < 3) return null; // incomplete
        if (buf[1] == '[') {
            switch (buf[2]) {
                'A' => return .{ .key = .up, .n = 3 },
                'B' => return .{ .key = .down, .n = 3 },
                'C' => return .{ .key = .right, .n = 3 },
                'D' => return .{ .key = .left, .n = 3 },
                '3' => {
                    if (buf.len < 4) return null;
                    if (buf[3] == '~') return .{ .key = .delete, .n = 4 };
                    return .{ .key = .unknown, .n = 4 };
                },
                else => return .{ .key = .unknown, .n = 3 },
            }
        }
        return .{ .key = .escape, .n = 1 };
    }

    // Printable / UTF-8 lead — emit single byte; multi-byte UTF-8 inserted as bytes.
    if (b0 >= 0x20) return .{ .key = .{ .char = b0 }, .n = 1 };
    if (b0 == 0x09) return .{ .key = .{ .char = '\t' }, .n = 1 };
    return .{ .key = .unknown, .n = 1 };
}

test "decode arrows and enter" {
    const up = decode("\x1b[A").?;
    try std.testing.expect(up.key == .up);
    const ent = decode("\r").?;
    try std.testing.expect(ent.key == .enter);
    const alt_s = decode("\x1bs").?;
    try std.testing.expect(alt_s.key == .alt_s);
}
