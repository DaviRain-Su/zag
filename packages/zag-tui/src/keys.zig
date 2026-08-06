//! vaxis.Key → AppKey translation (tui-vaxis-001).
//!
//! Hand-rolled byte decoding is gone: vaxis's parser produces `vaxis.Key`
//! events (codepoint + modifiers + UTF-8 text). This module maps those into
//! the app's key vocabulary. Printable codepoints are UTF-8-encoded into the
//! caller-provided `out` buffer (4 bytes max) so multi-byte input like "你"
//! inserts as one codepoint instead of byte-by-byte.

const std = @import("std");
const vaxis = @import("vaxis");

pub const AppKey = union(enum) {
    /// UTF-8 encoding of a printable codepoint; slice borrows `out` from
    /// `mapKey` and is valid until the next `mapKey` call.
    char: []const u8,
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
    ctrl_a,
    ctrl_e,
    ctrl_w,
    ctrl_u,
    ctrl_k,
    /// Toggle the permission mode (hyper: Ctrl+O toggles always-approve).
    ctrl_o,
    alt_s,
    alt_f,
    page_up,
    page_down,
    home,
    end,
    unknown,
};

/// Map a vaxis key event to an AppKey. `out` receives the UTF-8 encoding for
/// `.char` results (4 bytes max — one codepoint).
pub fn mapKey(key: vaxis.Key, out: *[4]u8) AppKey {
    const cp = key.codepoint;
    const mods = key.mods;

    // Alt+Enter and Alt+<char> arrive as ESC-prefixed sequences.
    if (mods.alt and cp == vaxis.Key.enter) return .alt_enter;
    if (mods.alt and (cp == 's' or cp == 'S')) return .alt_s;
    if (mods.alt and (cp == 'f' or cp == 'F')) return .alt_f;

    // Ctrl+letter (vaxis maps C0 controls to lowercase letters with ctrl).
    if (mods.ctrl) {
        switch (cp) {
            'j' => return .ctrl_j,
            'c' => return .ctrl_c, // defensive — ISIG normally routes Ctrl+C to SIGINT
            'd' => return .ctrl_d,
            'a' => return .ctrl_a,
            'e' => return .ctrl_e,
            'w' => return .ctrl_w,
            'u' => return .ctrl_u,
            'k' => return .ctrl_k,
            'o' => return .ctrl_o,
            else => {},
        }
    }

    switch (cp) {
        vaxis.Key.enter => return .enter,
        vaxis.Key.escape => return .escape,
        vaxis.Key.backspace => return .backspace,
        0x08 => return .backspace, // vaxis maps 0x08 to 0x7F; keep legacy BS
        vaxis.Key.up => return .up,
        vaxis.Key.down => return .down,
        vaxis.Key.left => return .left,
        vaxis.Key.right => return .right,
        vaxis.Key.delete => return .delete,
        vaxis.Key.page_up, vaxis.Key.kp_page_up => return .page_up,
        vaxis.Key.page_down, vaxis.Key.kp_page_down => return .page_down,
        vaxis.Key.home, vaxis.Key.kp_home => return .home,
        vaxis.Key.end, vaxis.Key.kp_end => return .end,
        else => {},
    }

    // Printable: encode the codepoint (multi-byte UTF-8 in one insert).
    // vaxis encodes special keys (arrows etc.) in the private-use area
    // starting at Key.insert; those are handled above and must not map here.
    if (cp >= 0x20 and cp < vaxis.Key.insert and cp <= 0x10FFFF) {
        const n = std.unicode.utf8Encode(cp, out) catch return .unknown;
        return .{ .char = out[0..n] };
    }
    return .unknown;
}

// ── fixtures (tui-vaxis-001) ────────────────────────────────────────────────

fn k(cp: u21) vaxis.Key {
    return .{ .codepoint = cp };
}

test "mapKey: enter / escape / backspace / delete" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(k(vaxis.Key.enter), &out) == .enter);
    try std.testing.expect(mapKey(k(vaxis.Key.escape), &out) == .escape);
    try std.testing.expect(mapKey(k(vaxis.Key.backspace), &out) == .backspace);
    try std.testing.expect(mapKey(k(0x08), &out) == .backspace);
    try std.testing.expect(mapKey(k(vaxis.Key.delete), &out) == .delete);
}

test "mapKey: arrows" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(k(vaxis.Key.up), &out) == .up);
    try std.testing.expect(mapKey(k(vaxis.Key.down), &out) == .down);
    try std.testing.expect(mapKey(k(vaxis.Key.left), &out) == .left);
    try std.testing.expect(mapKey(k(vaxis.Key.right), &out) == .right);
}

test "mapKey: alt chords" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } }, &out) == .alt_enter);
    try std.testing.expect(mapKey(.{ .codepoint = 's', .mods = .{ .alt = true } }, &out) == .alt_s);
    try std.testing.expect(mapKey(.{ .codepoint = 'S', .mods = .{ .alt = true } }, &out) == .alt_s);
    try std.testing.expect(mapKey(.{ .codepoint = 'f', .mods = .{ .alt = true } }, &out) == .alt_f);
    try std.testing.expect(mapKey(.{ .codepoint = 'F', .mods = .{ .alt = true } }, &out) == .alt_f);
}

test "mapKey: ctrl chords" {
    var out: [4]u8 = undefined;
    // vaxis parses Ctrl+J as codepoint 'j' with ctrl mod (0x0A → 'j').
    try std.testing.expect(mapKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }, &out) == .ctrl_j);
    try std.testing.expect(mapKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, &out) == .ctrl_c);
    try std.testing.expect(mapKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }, &out) == .ctrl_d);
}

test "mapKey: ctrl editing chords (a/e/w/u/k)" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(.{ .codepoint = 'a', .mods = .{ .ctrl = true } }, &out) == .ctrl_a);
    try std.testing.expect(mapKey(.{ .codepoint = 'e', .mods = .{ .ctrl = true } }, &out) == .ctrl_e);
    try std.testing.expect(mapKey(.{ .codepoint = 'w', .mods = .{ .ctrl = true } }, &out) == .ctrl_w);
    try std.testing.expect(mapKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } }, &out) == .ctrl_u);
    try std.testing.expect(mapKey(.{ .codepoint = 'k', .mods = .{ .ctrl = true } }, &out) == .ctrl_k);
}

test "mapKey: home / end (keypad and edit keys)" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(k(vaxis.Key.home), &out) == .home);
    try std.testing.expect(mapKey(k(vaxis.Key.end), &out) == .end);
    try std.testing.expect(mapKey(k(vaxis.Key.kp_home), &out) == .home);
    try std.testing.expect(mapKey(k(vaxis.Key.kp_end), &out) == .end);
}

test "mapKey: printable ASCII encodes one byte" {
    var out: [4]u8 = undefined;
    const key = mapKey(k('x'), &out);
    try std.testing.expect(key == .char);
    try std.testing.expectEqualStrings("x", key.char);
}

test "mapKey: multi-byte codepoint is one UTF-8 insert (你)" {
    var out: [4]u8 = undefined;
    const key = mapKey(k(0x4F60), &out); // U+4F60 你
    try std.testing.expect(key == .char);
    try std.testing.expectEqualStrings("你", key.char);
    // One codepoint → exactly one 3-byte slice (never byte-by-byte).
    try std.testing.expectEqual(@as(usize, 3), key.char.len);
}

test "mapKey: unknown inputs" {
    var out: [4]u8 = undefined;
    try std.testing.expect(mapKey(k(vaxis.Key.f1), &out) == .unknown);
    try std.testing.expect(mapKey(k(0x00), &out) == .unknown);
    try std.testing.expect(mapKey(.{ .codepoint = vaxis.Key.multicodepoint }, &out) == .unknown);
}
