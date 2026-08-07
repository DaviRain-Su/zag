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
    /// Reserved (full mode: unused, h=0). Constrained: title line.
    header: Region,
    /// Transcript / card list. Full mode: borderless, fills above the input.
    cards: Region,
    /// Bottom input box. Full mode: self-contained rounded box (top border
    /// carries the status chips, then content rows, then bottom border).
    editor: Region,
    /// Full mode: unused (h=0) — status lives in the editor top border.
    /// Constrained: the compact status line.
    status: Region,
    /// Permission modal overlay region — never present in constrained mode.
    modal: ?Region,
    /// Subagent tasks overlay region — sits ABOVE the modal (if any) and the
    /// editor band; never present in constrained mode.
    tasks_overlay: ?Region,
    cards_window: CardsWindow,
};

/// `scroll_from_bottom`: 0 shows the newest window; larger values scroll older
/// cards into view (clamped). Constrained mode ignores scroll (always newest 3).
/// `editor_lines`: the editor's current line count — the full-mode editor
/// region grows to show up to `max_editor_rows` content rows (Alt+Enter
/// multiline input); the transcript shrinks accordingly.
pub const max_editor_rows: usize = 4;

pub fn compute(
    size: terminal.Size,
    card_count: usize,
    modal_pending: bool,
    note_present: bool,
    scroll_from_bottom: usize,
    editor_lines: usize,
    tasks_visible: bool,
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
            .tasks_overlay = null,
            .cards_window = .{ .start = start, .count = @intCast(count) },
        };
    }

    // Full mode (omp/grok-inspired minimal chrome):
    //   transcript fills y=0 .. editor_y (no top title bar, no side rails)
    //   editor is a self-contained box: top border (status) + content + bottom
    //   status region is unused (h=0) — chips live in the editor top border
    //   modal / tasks sit above the editor
    const header_h: u16 = 0;

    // Editor: 2 border rows + up to max_editor_rows content rows.
    const ed_content: u16 = @intCast(@min(editor_lines, max_editor_rows));
    const editor_h: u16 = @min(2 + ed_content, rows);
    const editor_y: u16 = if (rows >= editor_h) rows - editor_h else 0;

    // Status band collapsed into the editor top border.
    const status_y: u16 = editor_y;
    const status_h: u16 = 0;

    const gap: u16 = editor_y; // everything above the editor is available
    const modal_h: u16 = if (modal_pending) @min(4, gap) else 0;
    const modal_region: ?Region = if (modal_h == 0) null else .{
        .x = 0,
        .y = editor_y - modal_h,
        .w = w,
        .h = modal_h,
    };

    // Grok-style tasks pane: up to 12 rows above the editor (header +
    // entries + optional expanded detail). Shrinks if the gap is smaller.
    const tasks_h: u16 = if (tasks_visible) @min(12, gap -| modal_h) else 0;
    const tasks_region: ?Region = if (tasks_h == 0) null else .{
        .x = 0,
        .y = editor_y -| modal_h -| tasks_h,
        .w = w,
        .h = tasks_h,
    };

    // Transcript fills from the top down to the stack above the editor.
    const cards_y: u16 = header_h;
    const cards_gap: u16 = if (editor_y > cards_y + modal_h + tasks_h)
        editor_y - cards_y - modal_h - tasks_h
    else
        0;
    const max_cards: u16 = if (rows > 8) cards_gap else @min(3, cards_gap);
    const cards_h: u16 = max_cards;

    const max_cards_u: usize = cards_h;
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
        .tasks_overlay = tasks_region,
        .cards_window = .{ .start = start, .count = count },
    };
}

// ── geometry fixtures (tui-layout-001) ──────────────────────────────────────

test "layout full mode geometry" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, false, 0, 1, false);
    try std.testing.expect(l.mode == .full);
    // No top chrome: header collapsed.
    try std.testing.expectEqual(@as(u16, 0), l.header.y);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    // Transcript fills y=0 .. editor_y. Editor box = top border + 1 content + bottom.
    try std.testing.expectEqual(@as(u16, 0), l.cards.y);
    try std.testing.expectEqual(@as(u16, 21), l.cards.h); // 24 - 3
    try std.testing.expectEqual(@as(u16, 80), l.cards.w);
    try std.testing.expectEqual(@as(usize, 5), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 21), l.editor.y);
    try std.testing.expectEqual(@as(u16, 3), l.editor.h);
    // Status band folded into the editor top border.
    try std.testing.expectEqual(@as(u16, 0), l.status.h);
    try std.testing.expect(l.modal == null);
}

test "layout full note is ignored (no header band)" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, true, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    try std.testing.expectEqual(@as(u16, 0), l.cards.y);
    try std.testing.expectEqual(@as(u16, 21), l.cards.h);
    try std.testing.expectEqual(@as(u16, 21), l.editor.y);
    try std.testing.expectEqual(@as(u16, 0), l.status.h);
}

test "layout full modal presence and position" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, true, false, 0, 1, false);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 17), m.y); // editor_y(21) - 4
    try std.testing.expectEqual(@as(u16, 4), m.h);
    try std.testing.expectEqual(@as(u16, 80), m.w);
    try std.testing.expectEqual(@as(u16, 17), l.cards.h); // 21 - 4
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    try std.testing.expectEqual(@as(u16, 21), l.editor.y);
}

test "layout full note + modal clamps cards" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, true, true, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 17), m.y);
    try std.testing.expectEqual(@as(u16, 17), l.cards.h);
    try std.testing.expectEqual(@as(usize, 17), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 3), l.cards_window.start); // 20-17
    try std.testing.expectEqual(@as(u16, 21), l.editor.y);
}

test "layout rows 10 geometry" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 8, false, false, 0, 1, false);
    try std.testing.expect(l.mode == .full);
    try std.testing.expectEqual(@as(u16, 3), l.editor.h);
    try std.testing.expectEqual(@as(u16, 7), l.editor.y);
    try std.testing.expectEqual(@as(u16, 7), l.cards.h);
    try std.testing.expectEqual(@as(usize, 7), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 1), l.cards_window.start);
}

test "layout rows 13 cards fill above editor" {
    const l = compute(.{ .cols = 80, .rows = 13 }, 2, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(usize, 2), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 10), l.cards.h); // 13 - 3
}

test "layout rows 10 + note + modal clamps without overflow" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 5, true, true, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 3), m.y); // editor_y(7) - 4
    try std.testing.expectEqual(@as(u16, 4), m.h);
    try std.testing.expectEqual(@as(u16, 3), l.cards.h);
    try std.testing.expectEqual(@as(u16, 7), l.editor.y);
    try std.testing.expect(l.header.y + l.header.h <= 10);
    try std.testing.expect(l.cards.y + l.cards.h <= 10);
    try std.testing.expect(l.editor.y + l.editor.h <= 10);
    try std.testing.expect(m.y + m.h <= 10);
}

test "layout rows 0 and 1 never overflow" {
    const l0 = compute(.{ .cols = 80, .rows = 0 }, 3, true, true, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 0), l0.header.h);
    try std.testing.expectEqual(@as(u16, 0), l0.cards.h);
    try std.testing.expectEqual(@as(u16, 0), l0.editor.h);
    try std.testing.expectEqual(@as(u16, 0), l0.status.h);
    try std.testing.expect(l0.modal == null);
    try std.testing.expect(l0.header.y + l0.header.h <= 0);
    try std.testing.expect(l0.cards.y + l0.cards.h <= 0);
    try std.testing.expect(l0.editor.y + l0.editor.h <= 0);

    const l1 = compute(.{ .cols = 80, .rows = 1 }, 3, true, false, 0, 1, false);
    try std.testing.expect(l1.header.y + l1.header.h <= 1);
    try std.testing.expect(l1.cards.y + l1.cards.h <= 1);
    try std.testing.expect(l1.editor.y + l1.editor.h <= 1);
    try std.testing.expect(l1.status.y + l1.status.h <= 1);
}

test "layout tiny width clamps w to 1" {
    const l = compute(.{ .cols = 0, .rows = 24 }, 1, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 1), l.header.w);
    try std.testing.expectEqual(@as(u16, 1), l.cards.w);
    try std.testing.expectEqual(@as(u16, 1), l.editor.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.w);
    const l1 = compute(.{ .cols = 1, .rows = 24 }, 1, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 1), l1.header.w);
}

test "layout card_count 0 yields empty cards window" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 21), l.cards.h);
}

test "layout window is the last count cards when overflowing" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(usize, 20), l.cards_window.count); // min(20,21)
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
}

test "layout editor grows with input lines" {
    const l1 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(u16, 3), l1.editor.h); // 2 borders + 1
    try std.testing.expectEqual(@as(u16, 37), l1.editor.y);
    try std.testing.expectEqual(@as(u16, 37), l1.cards.h);
    const l3 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 3, false);
    try std.testing.expectEqual(@as(u16, 5), l3.editor.h); // 2 + 3
    try std.testing.expectEqual(@as(u16, 35), l3.editor.y);
    try std.testing.expectEqual(@as(u16, 35), l3.cards.h);
    const l9 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 9, false);
    try std.testing.expectEqual(@as(u16, 2 + max_editor_rows), l9.editor.h);
}

test "layout constrained geometry" {
    const l = compute(.{ .cols = 30, .rows = 8 }, 5, true, true, 0, 1, false);
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
    const l = compute(.{ .cols = 30, .rows = 8 }, 0, false, false, 0, 1, false);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(u16, 0), l.cards.h); // region absent
    try std.testing.expectEqual(@as(u16, 2), l.editor.y);
    try std.testing.expectEqual(@as(u16, 1), l.editor.h);
}

test "layout constrained rows 1 clamps without overflow" {
    const l = compute(.{ .cols = 30, .rows = 1 }, 2, false, false, 0, 1, false);
    try std.testing.expect(l.header.y + l.header.h <= 1);
    try std.testing.expect(l.status.y + l.status.h <= 1);
    try std.testing.expect(l.cards.y + l.cards.h <= 1);
    try std.testing.expect(l.editor.y + l.editor.h <= 1);
}

test "layout scroll from bottom shifts window start" {
    const base = compute(.{ .cols = 80, .rows = 24 }, 25, false, false, 0, 1, false);
    const scrolled = compute(.{ .cols = 80, .rows = 24 }, 25, false, false, 5, 1, false);
    // cards_h = 21; count = min(25,21)=21; max_scroll=4; scroll clamps to 4.
    try std.testing.expectEqual(@as(usize, 4), base.cards_window.start); // 25-21
    try std.testing.expectEqual(@as(usize, 0), scrolled.cards_window.start); // 25-21-4
    try std.testing.expect(base.cards_window.start > scrolled.cards_window.start);
}
