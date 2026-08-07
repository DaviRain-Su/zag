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
    /// Grok-style control queue strip (pending steering/follow-up messages) —
    /// sits above the turn-status/editor stack and BELOW the modal/tasks
    /// overlays. h=0 (null) when no control messages are pending.
    queue_overlay: ?Region,
    /// Grok-style turn-status row above the editor (busy spinner / waiting).
    /// h=0 when idle.
    turn_status: Region,
    /// Grok-style shortcuts bar under the editor. Full mode always 1 row
    /// when the terminal is tall enough; constrained: h=0.
    shortcuts: Region,
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
    /// When true, reserve one row above the editor for the turn-status strip
    /// (busy / closing / error). Idle leaves it collapsed.
    turn_status_visible: bool,
    /// When true, reserve up to 4 rows above turn-status/editor for the
    /// grok-style control queue strip (pending steering/follow-up). The
    /// renderer draws only the actual entries inside the reserved band.
    queue_visible: bool,
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
            .queue_overlay = null,
            .turn_status = .{ .x = 0, .y = 0, .w = w, .h = 0 },
            .shortcuts = .{ .x = 0, .y = 0, .w = w, .h = 0 },
            .cards_window = .{ .start = start, .count = @intCast(count) },
        };
    }

    // Full mode (omp/grok-inspired minimal chrome):
    //   transcript fills y=0 .. stack
    //   optional turn-status (busy) above editor
    //   editor self-contained box (top border = status chips)
    //   shortcuts bar under editor (always 1 row when tall enough)
    //   modal / tasks sit above turn-status / editor
    const header_h: u16 = 0;

    // Bottom chrome: shortcuts bar (grok ShortcutsBar) — 1 row when we have
    // room beyond the minimum editor (3). Tiny terminals drop it.
    const shortcuts_h: u16 = if (rows >= 6) 1 else 0;
    const shortcuts_y: u16 = if (shortcuts_h > 0) rows - shortcuts_h else 0;

    // Editor: 2 border rows + up to max_editor_rows content rows.
    const ed_content: u16 = @intCast(@min(editor_lines, max_editor_rows));
    const editor_h: u16 = @min(2 + ed_content, rows -| shortcuts_h);
    const editor_y: u16 = if (rows >= editor_h + shortcuts_h) rows - editor_h - shortcuts_h else 0;

    // Turn-status strip (grok turn_status): 1 row above the editor when busy.
    const turn_h: u16 = if (turn_status_visible and editor_y > 0) 1 else 0;
    const turn_y: u16 = editor_y -| turn_h;

    // Grok-style control queue strip: up to 4 rows directly above
    // turn-status/editor (clamped by the available gap — tiny terminals
    // collapse it to nothing rather than overflow).
    const queue_h: u16 = if (queue_visible) @min(4, editor_y -| turn_h) else 0;
    const queue_y: u16 = (editor_y -| turn_h) -| queue_h;
    const queue_region: ?Region = if (queue_h == 0) null else .{
        .x = 0,
        .y = queue_y,
        .w = w,
        .h = queue_h,
    };

    // Status band collapsed into the editor top border.
    const status_y: u16 = editor_y;
    const status_h: u16 = 0;

    // Everything above the queue/turn-status/editor stack is available for
    // modal/tasks/cards.
    const stack_top: u16 = queue_y;
    const gap: u16 = stack_top;
    const modal_h: u16 = if (modal_pending) @min(4, gap) else 0;
    const modal_region: ?Region = if (modal_h == 0) null else .{
        .x = 0,
        .y = stack_top - modal_h,
        .w = w,
        .h = modal_h,
    };

    // Grok-style tasks pane: up to 12 rows above modal/turn/editor.
    const tasks_h: u16 = if (tasks_visible) @min(12, gap -| modal_h) else 0;
    const tasks_region: ?Region = if (tasks_h == 0) null else .{
        .x = 0,
        .y = stack_top -| modal_h -| tasks_h,
        .w = w,
        .h = tasks_h,
    };

    // Transcript fills from the top down to the stack above turn/editor.
    const cards_y: u16 = header_h;
    const cards_gap: u16 = if (stack_top > cards_y + modal_h + tasks_h)
        stack_top - cards_y - modal_h - tasks_h
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
        .queue_overlay = queue_region,
        .turn_status = .{ .x = 0, .y = turn_y, .w = w, .h = turn_h },
        .shortcuts = .{ .x = 0, .y = shortcuts_y, .w = w, .h = shortcuts_h },
        .cards_window = .{ .start = start, .count = count },
    };
}
// ── geometry fixtures (tui-layout-001) ──────────────────────────────────────

test "layout full mode with tasks pane" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, true, false, false);
    try std.testing.expect(l.mode == .full);
    const t = l.tasks_overlay orelse return error.TestUnexpectedResult;
    // shortcuts=1 → editor_y=20, editor_h=3; tasks 12 above editor
    try std.testing.expectEqual(@as(u16, 12), t.h);
    try std.testing.expectEqual(@as(u16, 8), t.y); // editor_y 20 - 12
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 3), l.editor.h);
    try std.testing.expectEqual(@as(u16, 1), l.shortcuts.h);
    try std.testing.expectEqual(@as(u16, 8), l.cards.h); // 20 - 12
}

test "layout full mode geometry" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, false, 0, 1, false, false, false);
    try std.testing.expect(l.mode == .full);
    try std.testing.expectEqual(@as(u16, 0), l.header.y);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    // shortcuts=1 + editor=3 → editor_y=20, cards=20
    try std.testing.expectEqual(@as(u16, 0), l.cards.y);
    try std.testing.expectEqual(@as(u16, 20), l.cards.h);
    try std.testing.expectEqual(@as(u16, 80), l.cards.w);
    try std.testing.expectEqual(@as(usize, 5), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 3), l.editor.h);
    try std.testing.expectEqual(@as(u16, 1), l.shortcuts.h);
    try std.testing.expectEqual(@as(u16, 23), l.shortcuts.y);
    try std.testing.expectEqual(@as(u16, 0), l.status.h);
    try std.testing.expectEqual(@as(u16, 0), l.turn_status.h);
    try std.testing.expect(l.modal == null);
    try std.testing.expect(l.tasks_overlay == null);
}

test "layout full note is ignored (no header band)" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, false, true, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    try std.testing.expectEqual(@as(u16, 0), l.cards.y);
    try std.testing.expectEqual(@as(u16, 20), l.cards.h);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 0), l.status.h);
}

test "layout full modal presence and position" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 5, true, false, 0, 1, false, false, false);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), m.y); // editor_y(20) - 4
    try std.testing.expectEqual(@as(u16, 4), m.h);
    try std.testing.expectEqual(@as(u16, 80), m.w);
    try std.testing.expectEqual(@as(u16, 16), l.cards.h); // 20 - 4
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
}

test "layout full note + modal clamps cards" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, true, true, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), m.y);
    try std.testing.expectEqual(@as(u16, 16), l.cards.h);
    try std.testing.expectEqual(@as(usize, 16), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 4), l.cards_window.start); // 20-16
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
}

test "layout rows 10 geometry" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 8, false, false, 0, 1, false, false, false);
    try std.testing.expect(l.mode == .full);
    try std.testing.expectEqual(@as(u16, 3), l.editor.h);
    try std.testing.expectEqual(@as(u16, 6), l.editor.y);
    try std.testing.expectEqual(@as(u16, 6), l.cards.h);
    try std.testing.expectEqual(@as(usize, 6), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 2), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 1), l.shortcuts.h);
}

test "layout rows 13 cards fill above editor" {
    const l = compute(.{ .cols = 80, .rows = 13 }, 2, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(usize, 2), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 9), l.cards.h); // 13 - 3 - 1
}

test "layout rows 10 + note + modal clamps without overflow" {
    const l = compute(.{ .cols = 80, .rows = 10 }, 5, true, true, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 0), l.header.h);
    const m = l.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 2), m.y); // editor_y(6) - 4
    try std.testing.expectEqual(@as(u16, 4), m.h);
    try std.testing.expectEqual(@as(u16, 2), l.cards.h);
    try std.testing.expectEqual(@as(u16, 6), l.editor.y);
    try std.testing.expect(l.header.y + l.header.h <= 10);
    try std.testing.expect(l.cards.y + l.cards.h <= 10);
    try std.testing.expect(l.editor.y + l.editor.h + l.shortcuts.h <= 10);
    try std.testing.expect(m.y + m.h <= 10);
}

test "layout rows 0 and 1 never overflow" {
    const l0 = compute(.{ .cols = 80, .rows = 0 }, 3, true, true, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 0), l0.header.h);
    try std.testing.expectEqual(@as(u16, 0), l0.cards.h);
    try std.testing.expectEqual(@as(u16, 0), l0.editor.h);
    try std.testing.expectEqual(@as(u16, 0), l0.status.h);
    try std.testing.expect(l0.modal == null);
    try std.testing.expect(l0.header.y + l0.header.h <= 0);
    try std.testing.expect(l0.cards.y + l0.cards.h <= 0);
    try std.testing.expect(l0.editor.y + l0.editor.h <= 0);

    const l1 = compute(.{ .cols = 80, .rows = 1 }, 3, true, false, 0, 1, false, false, false);
    try std.testing.expect(l1.header.y + l1.header.h <= 1);
    try std.testing.expect(l1.cards.y + l1.cards.h <= 1);
    try std.testing.expect(l1.editor.y + l1.editor.h <= 1);
    try std.testing.expect(l1.status.y + l1.status.h <= 1);
}

test "layout tiny width clamps w to 1" {
    const l = compute(.{ .cols = 0, .rows = 24 }, 1, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 1), l.header.w);
    try std.testing.expectEqual(@as(u16, 1), l.cards.w);
    try std.testing.expectEqual(@as(u16, 1), l.editor.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.w);
    const l1 = compute(.{ .cols = 1, .rows = 24 }, 1, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 1), l1.header.w);
}

test "layout card_count 0 yields empty cards window" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
    try std.testing.expectEqual(@as(u16, 20), l.cards.h);
}

test "layout window is the last count cards when overflowing" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 20, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(usize, 20), l.cards_window.count); // min(20,20)
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.start);
}

test "layout editor grows with input lines" {
    const l1 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(u16, 3), l1.editor.h); // 2 borders + 1
    try std.testing.expectEqual(@as(u16, 36), l1.editor.y);
    try std.testing.expectEqual(@as(u16, 36), l1.cards.h);
    const l3 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 3, false, false, false);
    try std.testing.expectEqual(@as(u16, 5), l3.editor.h); // 2 + 3
    try std.testing.expectEqual(@as(u16, 34), l3.editor.y);
    try std.testing.expectEqual(@as(u16, 34), l3.cards.h);
    const l9 = compute(.{ .cols = 80, .rows = 40 }, 0, false, false, 0, 9, false, false, false);
    try std.testing.expectEqual(@as(u16, 2 + max_editor_rows), l9.editor.h);
}

test "layout constrained geometry" {
    const l = compute(.{ .cols = 30, .rows = 8 }, 5, true, true, 0, 1, false, false, false);
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
    const l = compute(.{ .cols = 30, .rows = 8 }, 0, false, false, 0, 1, false, false, false);
    try std.testing.expectEqual(@as(usize, 0), l.cards_window.count);
    try std.testing.expectEqual(@as(u16, 0), l.cards.h); // region absent
    try std.testing.expectEqual(@as(u16, 2), l.editor.y);
    try std.testing.expectEqual(@as(u16, 1), l.editor.h);
}

test "layout constrained rows 1 clamps without overflow" {
    const l = compute(.{ .cols = 30, .rows = 1 }, 2, false, false, 0, 1, false, false, false);
    try std.testing.expect(l.header.y + l.header.h <= 1);
    try std.testing.expect(l.status.y + l.status.h <= 1);
    try std.testing.expect(l.cards.y + l.cards.h <= 1);
    try std.testing.expect(l.editor.y + l.editor.h <= 1);
}

test "layout scroll from bottom shifts window start" {
    const base = compute(.{ .cols = 80, .rows = 24 }, 25, false, false, 0, 1, false, false, false);
    const scrolled = compute(.{ .cols = 80, .rows = 24 }, 25, false, false, 5, 1, false, false, false);
    // cards_h = 20; count = min(25,20)=20; max_scroll=5; scroll clamps to 5.
    try std.testing.expectEqual(@as(usize, 5), base.cards_window.start); // 25-20
    try std.testing.expectEqual(@as(usize, 0), scrolled.cards_window.start); // 25-20-5
    try std.testing.expect(base.cards_window.start > scrolled.cards_window.start);
}

test "layout turn_status reserves a row when busy" {
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false, true, false);
    try std.testing.expectEqual(@as(u16, 1), l.turn_status.h);
    try std.testing.expectEqual(@as(u16, 19), l.turn_status.y); // editor_y 20 - 1
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 19), l.cards.h);
}

test "layout queue_visible reserves rows above turn_status without overflow" {
    // Queue alone: 4 rows directly above the editor (no turn strip busy).
    const l = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false, false, true);
    const q = l.queue_overlay orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 4), q.h);
    try std.testing.expectEqual(@as(u16, 16), q.y); // editor_y 20 - 4
    try std.testing.expectEqual(@as(u16, 20), l.editor.y);
    try std.testing.expectEqual(@as(u16, 16), l.cards.h);
    try std.testing.expect(q.y + q.h <= 24);

    // With the busy turn strip, the queue sits ABOVE it (stack below modal).
    const lt = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false, true, true);
    const qt = lt.queue_overlay orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 1), lt.turn_status.h);
    try std.testing.expectEqual(@as(u16, 19), lt.turn_status.y);
    try std.testing.expectEqual(@as(u16, 15), qt.y); // 19 - 4
    try std.testing.expectEqual(@as(u16, 15), lt.cards.h);
    try std.testing.expect(qt.y + qt.h <= 24);

    // Modal sits above the queue (unchanged 4-row modal, pushed up).
    const lm = compute(.{ .cols = 80, .rows = 24 }, 5, true, false, 0, 1, false, false, true);
    const m = lm.modal orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 12), m.y); // 16 - 4
    try std.testing.expectEqual(@as(u16, 4), m.h);
    const qm = lm.queue_overlay orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 16), qm.y);
    try std.testing.expect(m.y + m.h <= qm.y);

    // Tiny terminal: queue collapses rather than overflow.
    const ltiny = compute(.{ .cols = 80, .rows = 3 }, 3, true, false, 0, 1, false, false, true);
    if (ltiny.queue_overlay) |qq| {
        try std.testing.expect(qq.y + qq.h <= 3);
    }
    try std.testing.expect(ltiny.editor.y + ltiny.editor.h + ltiny.shortcuts.h <= 3);

    // Hidden (default): null region, prior geometry untouched.
    const lf = compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, false, false, false);
    try std.testing.expect(lf.queue_overlay == null);
    try std.testing.expectEqual(@as(u16, 20), lf.editor.y);
    try std.testing.expectEqual(@as(u16, 20), lf.cards.h);
}

