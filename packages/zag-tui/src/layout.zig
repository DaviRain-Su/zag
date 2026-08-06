//! Pure layout computation for the host TUI frame (tui-layout-001).
//!
//! No IO, no allocator, no app state: `compute` turns a terminal size and a
//! few counts into screen rectangles. The renderer is a thin shell over these
//! regions; geometry mirrors render.zig's pre-slice paragraphs so frames stay
//! byte-identical for the same inputs.
//!
//! Clamp law: `w` shrinks to ≥ 1; `h` shrinks to the available rows;
//! `h == 0` means the region is absent (draw skips); `y + h <= size.rows`
//! always holds — no region can overflow a degenerate terminal.

const std = @import("std");
const terminal = @import("terminal.zig");

pub const Region = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const Mode = enum { full, constrained };

pub const CardsWindow = struct { start: usize, count: usize };

pub const Layout = struct {
    mode: Mode,
    /// Top band. Full: top border + id line + perm/shell/state line (+1 note
    /// row). Constrained: the `[zag tui · constrained]` title line.
    header: Region,
    /// Scrollable card list band (`├─ cards ─` is its first row in full
    /// mode; constrained mode draws bare `· title` lines, sized to content).
    cards: Region,
    /// Fixed band at the bottom: separator row + ONE clipped content row
    /// (full mode); single `> …` line (constrained).
    editor: Region,
    /// Footer hint line + the frame's bottom border row (full mode); the
    /// status line alone (constrained).
    status: Region,
    /// Permission modal overlay region — never present in constrained mode.
    modal: ?Region,
    cards_window: CardsWindow,
};

/// `scroll_from_bottom`: 0 shows the newest window; larger values scroll older
/// cards into view (clamped). Constrained mode ignores scroll (always newest 3).
pub fn compute(
    size: terminal.Size,
    card_count: usize,
    modal_pending: bool,
    note_present: bool,
    scroll_from_bottom: usize,
) Layout {
    const w: u16 = @max(size.cols, 1);
    const rows = size.rows;
    _ = note_present; // header is a single border row; notes surface in the meta line

    if (size.isConstrained()) {
        // 3-line form: status line, up to 3 card titles (newest first),
        // editor line. Modal is never drawn (modal = null).
        const count: u16 = @intCast(@min(card_count, 3));
        const header_y: u16 = 0;
        const header_h: u16 = @min(1, rows);
        const status_y: u16 = @min(1, rows);
        const status_h: u16 = @min(1, rows - status_y);
        const cards_y: u16 = @min(2, rows);
        const cards_h: u16 = @min(count, rows - cards_y);
        const editor_y: u16 = @min(2 + count, rows);
        const editor_h: u16 = @min(1, rows - editor_y);
        const start = if (card_count > count) card_count - count else 0;
        return .{
            .mode = .constrained,
            .header = .{ .x = 0, .y = header_y, .w = w, .h = header_h },
            .cards = .{ .x = 0, .y = cards_y, .w = w, .h = cards_h },
            .editor = .{ .x = 0, .y = editor_y, .w = w, .h = editor_h },
            .status = .{ .x = 0, .y = status_y, .w = w, .h = status_h },
            .modal = null,
            .cards_window = .{ .start = start, .count = @intCast(count) },
        };
    }

    // Full mode, bottom-up: fixed 4-row bottom band (editor separator +
    // content row, then the meta line + the frame's bottom border row),
    // the modal computed above it, transcript/cards filling the middle
    // after the header (tui-polish-001 closed-frame geometry; header is a
    // single border row with the title overlaid — the id/perm/shell info
    // lines are gone for the minimal look).
    const header_h: u16 = @min(1, rows);

    const editor_y: u16 = if (rows >= 4) rows - 4 else 0;
    const editor_h: u16 = @min(2, rows -| editor_y);
    const status_y: u16 = if (rows >= 2) rows - 2 else 0;
    const status_h: u16 = @min(2, rows -| status_y);

    const gap: u16 = if (editor_y > header_h) editor_y - header_h else 0;
    const modal_h: u16 = if (modal_pending) @min(4, gap) else 0;
    const modal_region: ?Region = if (modal_h == 0) null else .{
        .x = 0,
        .y = editor_y - modal_h,
        .w = w,
        .h = modal_h,
    };

    const max_cards: u16 = if (rows > 12) rows - 10 else 3;
    const cards_y: u16 = header_h;
    const cards_gap: u16 = if (editor_y > cards_y + modal_h) editor_y - cards_y - modal_h else 0;
    const cards_h: u16 = @min(max_cards, cards_gap);

    const max_cards_u: usize = if (rows > 12) rows - 10 else 3;
    const count = @min(card_count, max_cards_u);
    const max_scroll = if (card_count > count) card_count - count else 0;
    const scroll = @min(scroll_from_bottom, max_scroll);
    const start = if (card_count > count) card_count - count - scroll else 0;

    return .{
        .mode = .full,
        .header = .{ .x = 0, .y = 0, .w = w, .h = header_h },
        .cards = .{ .x = 0, .y = cards_y, .w = w, .h = cards_h },
        .editor = .{ .x = 0, .y = editor_y, .w = w, .h = editor_h },
        .status = .{ .x = 0, .y = status_y, .w = w, .h = status_h },
        .modal = modal_region,
        .cards_window = .{ .start = start, .count = count },
    };
}

// ── geometry fixtures (tui-layout-001) ──────────────────────────────────────

test "layout full mode geometry" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, false, 0);
    try std.testing.expect(l.mode == .full);
    // header: single border row with the title overlaid (minimal frame);
    // the id/perm/shell info lines are gone.
    try std.testing.expectEqual(@as(u16, 0), l.header.y);
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    try std.testing.expectEqual(@as(u16, 80), l.header.w);
    // cards region rows = rows - 10 (>12); window = last min(card_count, 14).
    try std.testing.expectEqual(@as(u16, 1), l.cards.y);
    try std.testing.expectEqual(@as(u16, 14), l.cards.h);
    try std.testing.expectEqual(@as(usize, 5), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    // Fixed bottom band: 2-row editor (separator + content) + 2-row status
    // (meta line + frame bottom border).
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 2), l.editor.h);
    try std.testing.expectEqual(@as(u16, 22), l.status.y);
    try std.testing.expectEqual(@as(u16, 2), l.status.h);
    try std.testing.expect(l.modal == null);
}

test "layout full note is ignored (single-row header)" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, true, 0);
    // Notes surface in the meta line; the header stays a single border row.
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    try std.testing.expectEqual(@as(u16, 1), l.cards.y);
    try std.testing.expectEqual(@as(u16, 14), l.cards.h);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 22), l.status.y);
}

test "layout full modal presence and position" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, true, false, 0);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), m.y); // bottom-up from editor band
    try std.testing.expectEqual(@as(u16, 4), m.h);
    try std.testing.expectEqual(@as(u16, 80), m.w);
    // The modal consumes the gap above the editor band, but the single-row
    // header leaves the cards their full 14-row budget.
    try std.testing.expectEqual(@as(u16, 14), l.cards.h);
    // Everything else unchanged.
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 22), l.status.y);
}

test "layout full note + modal clamps cards" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, true, true, 0);
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), m.y);
    // 1 (header) + 14 (cards) + 4 (modal) + 4 (bottom band) = 23 ≤ 24.
    try std.testing.expectEqual(@as(u16, 14), l.cards.h);
    // Window math is independent of the clamped region height.
    try std.testing.expectEqual(@as(usize, 14), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 6), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 22), l.status.y);
}

test "layout rows <= 12 caps cards at 3" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 8, false, false, 0);
    try std.testing.expect(l.mode == .full); // rows=10 not constrained
    try std.testing.expectEqual(@as(usize, 3), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 5), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 3), l.cards.h);
    try std.testing.expectEqual(@as(u16, 6), l.editor.y);
    try std.testing.expectEqual(@as(u16, 8), l.status.y);
}

test "layout rows 13 cards cap 3" {
    const l = compute(.{ .cols = 80, .rows = 13 }, 2, false, false, 0);
    try std.testing.expectEqual(@as(usize, 2), l.cards_window.count); // card_count < window
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 3), l.cards.h); // 13 - 10 = 3
}

test "layout rows 10 + note + modal clamps without overflow" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 5, true, true, 0);
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 2), m.y); // bottom-up from the editor band
    try std.testing.expectEqual(@as(u16, 4), m.h); // gap is 5 → modal caps at 4
    try std.testing.expectEqual(@as(u16, 1), l.cards.h); // one leftover row below the modal
    try std.testing.expectEqual(@as(u16, 6), l.editor.y);
    try std.testing.expectEqual(@as(u16, 8), l.status.y);
    // y + h <= rows for every region.
    try std.testing.expect(l.header.y + l.header.h <= 10);
    try std.testing.expect(l.cards.y + l.cards.h <= 10);
    try std.testing.expect(l.editor.y + l.editor.h <= 10);
    try std.testing.expect(l.status.y + l.status.h <= 10);
    try std.testing.expect(m.y + m.h <= 10);
}

test "layout rows 0 and 1 never overflow" {
    const l0 = compute(.{ .cols = 80, .rows = 0 }, 3, true, true, 0);
    try std.testing.expectEqual(@as(u16, 0), l0.header.h);
    try std.testing.expectEqual(@as(u16, 0), l0.cards.h);
    try std.testing.expectEqual(@as(u16, 0), l0.editor.h);
    try std.testing.expectEqual(@as(u16, 0), l0.status.h);
    try std.testing.expect(l0.modal == null); // no gap → absent
    try std.testing.expect(l0.header.y + l0.header.h <= 0);
    try std.testing.expect(l0.cards.y + l0.cards.h <= 0);
    try std.testing.expect(l0.editor.y + l0.editor.h <= 0);
    try std.testing.expect(l0.status.y + l0.status.h <= 0);

    const l1 = compute(.{ .cols = 80, .rows = 1 }, 3, true, false, 0);
    try std.testing.expect(l1.header.y + l1.header.h <= 1);
    try std.testing.expect(l1.cards.y + l1.cards.h <= 1);
    try std.testing.expect(l1.editor.y + l1.editor.h <= 1);
    try std.testing.expect(l1.status.y + l1.status.h <= 1);
}

test "layout tiny width clamps w to 1" {
    const l = compute(.{ .cols = 0, .rows = 24 }, 1, false, false, 0);
    try std.testing.expectEqual(@as(u16, 1), l.header.w);
    try std.testing.expectEqual(@as(u16, 1), l.cards.w);
    try std.testing.expectEqual(@as(u16, 1), l.editor.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.w);
    const l1 = compute(.{ .cols = 1, .rows = 24 }, 1, false, false, 0);
    try std.testing.expectEqual(@as(u16, 1), l1.header.w);
}

test "layout card_count 0 yields empty cards window" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    // Region budget is card-count independent.
    try std.testing.expectEqual(@as(u16, 14), l.cards.h);
}

test "layout window is the last count cards when overflowing" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, false, false, 0);
    try std.testing.expectEqual(@as(usize, 14), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 6), l.cards_window.start);
}

test "layout constrained geometry" {
    const l = compute(.{ .cols = 30, .rows = 8 }, 5, true, true, 0);
    try std.testing.expect(l.mode == .constrained);
    try std.testing.expect(l.modal == null); // modal never drawn
    try std.testing.expectEqual(@as(u16, 0), l.header.y);
    try std.testing.expectEqual(@as(u16, 1), l.header.h);
    try std.testing.expectEqual(@as(u16, 1), l.status.y);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    try std.testing.expectEqual(@as(u16, 2), l.cards.y);
    try std.testing.expectEqual(@as(u16, 3), l.cards.h); // sized to content (cap 3)
    try std.testing.expectEqual(@as(u16, 5), l.editor.y);
    try std.testing.expectEqual(@as(u16, 1), l.editor.h);
    try std.testing.expectEqual(@as(usize, 3), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 2), l.cards_window.start); // newest 3 of 5
}

test "layout constrained no cards" {
    const l = compute(.{ .cols = 30, .rows = 8 }, 0, false, false, 0);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(u16, 0), l.cards.h); // region absent
    try std.testing.expectEqual(@as(u16, 2), l.editor.y);
    try std.testing.expectEqual(@as(u16, 1), l.editor.h);
}

test "layout constrained rows 1 clamps without overflow" {
    const l = compute(.{ .cols = 30, .rows = 1 }, 2, false, false, 0);
    try std.testing.expect(l.header.y + l.header.h <= 1);
    try std.testing.expect(l.status.y + l.status.h <= 1);
    try std.testing.expect(l.cards.y + l.cards.h <= 1);
    try std.testing.expect(l.editor.y + l.editor.h <= 1);
}

test "layout scroll from bottom shifts window start" {
    const base = compute(.{ .cols = 80, .rows = 24 }, 20, false, false, 0);
    const scrolled = compute(.{ .cols = 80, .rows = 24 }, 20, false, false, 5);
    try std.testing.expect(scrolled.cards_window.start + 5 == base.cards_window.start);
}
