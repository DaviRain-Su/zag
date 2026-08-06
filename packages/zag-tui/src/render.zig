//! vaxis cell renderer (tui-vaxis-001). Thin shell over `layout.compute`:
//! per-region draw functions write only within their region windows
//! (`root.child(.{ .x_off, .y_off, .width, .height })`); card bodies/titles
//! truncate per the tui-layout-001 rules (utf8Prefix min-caps); multi-line
//! editor content clips to the fixed content row; `state:{s}` stays present
//! in the header cells (PTY grep contract). `vx.render()` diff replaces the
//! old full-frame ANSI; the offscreen fixtures assert the cell content that
//! the pre-vaxis golden frames encode.

const std = @import("std");
const vaxis = @import("vaxis");
const c = @import("constants.zig");
const cards = @import("cards.zig");
const editor = @import("editor.zig");
const layout_mod = @import("layout.zig");
const permission = @import("permission.zig");
const present = @import("present.zig");
const terminal = @import("terminal.zig");
const theme_mod = @import("theme.zig");
const overlay_mod = @import("overlay.zig");

pub const UiState = enum {
    idle,
    busy,
    closing,
    @"error",
    closed,
};

pub const StatusFacts = struct {
    id_display: []const u8,
    open_display: []const u8,
    session_configured: bool,
    perm: []const u8,
    shell: []const u8,
    state: UiState,
    status_note: []const u8 = "",
    steering_pending: u32 = 0,
    followup_pending: u32 = 0,
    model: []const u8 = "—",
    theme_id: []const u8 = theme_mod.builtin_id,
};

pub const OverlayPaint = struct {
    kind: overlay_mod.Kind = .none,
    cursor: usize = 0,
    lines: []const []const u8 = &.{},
};

pub fn stateName(s: UiState) []const u8 {
    return switch (s) {
        .idle => "idle",
        .busy => "busy",
        .closing => "closing",
        .@"error" => "error",
        .closed => "closed",
    };
}

/// Last UiState drawn by renderFrame (single-app renderer). On transitions a
/// full refresh is queued so the PTY marker contract ("state:{s}" appears
/// contiguous in the byte stream) holds even though the cell diff normally
/// emits only the changed "busy"/"closing" run.
var last_drawn_state: ?UiState = null;

/// Render full frame. Permission modal fields come from a lock-safe snapshot.
/// `size` is the authoritative geometry: the screen is resized first if it
/// drifted (belt-and-braces on top of winsize events).
pub fn renderFrame(
    term: *terminal.Terminal,
    size: terminal.Size,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
    palette: *const theme_mod.Palette,
    ov: OverlayPaint,
    scroll_from_bottom: usize,
) error{WriteFailed}!void {
    term.ensureSize(size);
    if (last_drawn_state == null or last_drawn_state.? != facts.state) {
        term.vx.queueRefresh();
        last_drawn_state = facts.state;
    }
    const layout = layout_mod.compute(size, snap.len, modal.pending, facts.status_note.len > 0, scroll_from_bottom);
    // The vaxis screen borrows cell graphemes from the formatted lines; the
    // store must outlive `render()` below (and lives across paints).
    term.scratch.len = 0;
    const root = term.vx.window();
    drawFrame(root, layout, facts, snap, ed, modal, palette, ov, &term.scratch);
    term.render() catch return error.WriteFailed;
}

/// Draw a frame into `root` (the vaxis window). Tests draw into an offscreen
/// window over a `vaxis.Screen` and assert the resulting cells (keeping the
/// store alive for the cell reads).
fn drawFrame(
    root: vaxis.Window,
    layout: layout_mod.Layout,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
    palette: *const theme_mod.Palette,
    ov: OverlayPaint,
    store: *terminal.LineStore,
) void {
    root.clear();
    switch (layout.mode) {
        .constrained => {
            drawHeader(childRegion(root, layout.header), layout.mode, facts, palette, store);
            drawStatus(childRegion(root, layout.status), layout.mode, facts, ed, palette, store);
            drawCards(childRegion(root, layout.cards), layout.cards_window, layout.mode, snap, palette, store);
            drawEditor(childRegion(root, layout.editor), layout.mode, ed, palette);
        },
        .full => {
            drawHeader(childRegion(root, layout.header), layout.mode, facts, palette, store);
            drawCards(childRegion(root, layout.cards), layout.cards_window, layout.mode, snap, palette, store);
            drawEditor(childRegion(root, layout.editor), layout.mode, ed, palette);
            drawStatus(childRegion(root, layout.status), layout.mode, facts, ed, palette, store);
            if (layout.modal) |m| drawModal(root, m, modal, palette, store);
            if (ov.kind != .none and !modal.pending) drawHostOverlay(root, layout, ov, palette, store);
        },
    }
}

fn childRegion(root: vaxis.Window, region: layout_mod.Region) vaxis.Window {
    return root.child(.{
        .x_off = region.x,
        .y_off = region.y,
        .width = region.w,
        .height = region.h,
    });
}

fn printLine(win: vaxis.Window, row: u16, text: []const u8) void {
    _ = win.printSegment(.{ .text = text }, .{ .row_offset = row, .wrap = .none });
}

/// Header/status lines keep the pre-vaxis byte-based min-cap
/// (`utf8Prefix(text, w)`) so frames stay byte-identical to the old layout.
fn printLineStyled(win: vaxis.Window, row: u16, text: []const u8, style: vaxis.Style) void {
    const capped = present.utf8Prefix(text, win.width);
    _ = win.printSegment(.{ .text = capped, .style = style }, .{ .row_offset = row, .wrap = .none });
}

fn drawHeader(win: vaxis.Window, mode: layout_mod.Mode, facts: StatusFacts, palette: *const theme_mod.Palette, store: *terminal.LineStore) void {
    const header_style = palette.style(.status_fg);
    var row: u16 = 0;
    if (mode == .constrained) {
        if (row < win.height) {
            printLine(win, row, "[zag tui · constrained]");
        }
        return;
    }
    if (row < win.height) {
        printLineStyled(win, row, "┌─ zag  tui ─", header_style);
        row += 1;
    }
    if (row < win.height) {
        if (store.format("│ id: {s}  open:{s} cfg:{s}", .{
            facts.id_display,
            facts.open_display,
            if (facts.session_configured) "y" else "n",
        })) |s| {
            printLineStyled(win, row, s, header_style);
        }
        row += 1;
    }
    if (row < win.height) {
        var tail_buf: [64]u8 = undefined;
        var tail: []const u8 = "";
        if (facts.steering_pending > 0 or facts.followup_pending > 0) {
            tail = std.fmt.bufPrint(&tail_buf, "  S:{d} F:{d}", .{
                facts.steering_pending,
                facts.followup_pending,
            }) catch "";
        }
        if (store.format("│ perm:{s}  shell:{s}  state:{s}{s}", .{
            facts.perm,
            facts.shell,
            stateName(facts.state),
            tail,
        })) |s| {
            printLineStyled(win, row, s, header_style);
        }
        row += 1;
    }
    if (facts.status_note.len > 0 and row < win.height) {
        if (store.format("│ note: {s}", .{facts.status_note})) |s| {
            printLineStyled(win, row, s, header_style);
        }
    }
}

fn drawCards(
    win: vaxis.Window,
    window: layout_mod.CardsWindow,
    mode: layout_mod.Mode,
    snap: []const cards.CardSlot,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    const card_style = palette.style(.card_fg);
    _ = card_style;
    var row: u16 = 0;
    const w: u16 = win.width;
    const title_limit = @min(@as(usize, 128), @max(@as(usize, w), 2) - 2);
    const body_limit = @min(@as(usize, 120), @max(@as(usize, w), 3) - 3);

    if (mode == .full) {
        if (row < win.height) {
            printLineStyled(win, row, "├─ transcript ─", palette.style(.muted_fg));
            row += 1;
        }
        if (window.count == 0) {
            if (row < win.height) {
                printLine(win, row, "│ (no events yet)");
            }
            return;
        }
        var i: usize = 0;
        while (i < window.count and row < win.height) : (i += 1) {
            const card = &snap[window.start + i];
            if (row < win.height) {
                const title = present.utf8Prefix(card.titleSlice(), title_limit);
                if (store.format("│ · {s}", .{title})) |s| {
                    printLine(win, row, s);
                }
                row += 1;
            }
            if (card.body_len > 0 and row < win.height) {
                const preview = present.utf8Prefix(card.bodySlice(), body_limit);
                if (store.format("│   {s}", .{preview})) |s| {
                    printLine(win, row, s);
                }
                row += 1;
            }
        }
        return;
    }

    // Constrained: up to 3 one-line titles, NEWEST first (snap[len-1-i]).
    var i: usize = window.count;
    while (i > 0 and row < win.height) {
        i -= 1;
        const card = &snap[window.start + i];
        const title = present.utf8Prefix(card.titleSlice(), title_limit);
        if (store.format("· {s}", .{title})) |s| {
            printLine(win, row, s);
        }
        row += 1;
    }
}

fn drawEditor(win: vaxis.Window, mode: layout_mod.Mode, ed: *const editor.Editor, palette: *const theme_mod.Palette) void {
    const editor_style = palette.style(.editor_fg);
    var row: u16 = 0;
    const content = ed.slice();
    const first_line = singleLine(content);
    if (mode == .constrained) {
        if (row < win.height) {
            _ = win.printSegment(.{ .text = "> ", .style = editor_style }, .{ .row_offset = row, .wrap = .none });
            if (first_line.len > 0) {
                _ = win.printSegment(.{ .text = first_line }, .{ .row_offset = row, .col_offset = 2, .wrap = .none });
            }
            // Cursor cell (byte → cell via UTF-8 width).
            const prefix = if (ed.cursor <= first_line.len) content[0..ed.cursor] else first_line;
            win.showCursor(2 + win.gwidth(prefix), row);
        }
        return;
    }
    if (row < win.height) {
        printLine(win, row, "├─ editor ─");
        row += 1;
    }
    // Fixed content row: the first editor line, clipped like card bodies.
    if (row < win.height) {
        _ = win.printSegment(.{ .text = "│ > ", .style = editor_style }, .{ .row_offset = row, .wrap = .none });
        if (first_line.len > 0) {
            _ = win.printSegment(.{ .text = first_line }, .{ .row_offset = row, .col_offset = 4, .wrap = .none });
        }
        const prefix = if (ed.cursor <= first_line.len) content[0..ed.cursor] else first_line;
        win.showCursor(4 + win.gwidth(prefix), row);
    }
}

fn drawStatus(
    win: vaxis.Window,
    mode: layout_mod.Mode,
    facts: StatusFacts,
    ed: *const editor.Editor,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    const status_style = palette.style(.accent_fg);
    if (win.height < 1) return;
    if (mode == .constrained) {
        if (store.format("state={s} id={s}", .{ stateName(facts.state), facts.id_display })) |s| {
            printLineStyled(win, 0, s, status_style);
        }
        return;
    }
    if (store.format("│ model:{s} theme:{s} [{d}/{d}] [/ palette · PgUp/Dn]", .{
        facts.model,
        facts.theme_id,
        ed.len,
        c.editor_max_bytes,
    })) |s| {
        printLineStyled(win, 0, s, status_style);
    }
}

/// Modal overlay: rounded vaxis border + style (the visual upgrade), title
/// printed over the top border, two content rows inside. Geometry is
/// layout.zig's.
fn drawModal(root: vaxis.Window, region: layout_mod.Region, modal: permission.ModalSnapshot, palette: *const theme_mod.Palette, store: *terminal.LineStore) void {
    const modal_style = palette.style(.modal_fg);
    const inner = root.child(.{
        .x_off = region.x,
        .y_off = region.y,
        .width = region.w,
        .height = region.h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = modal_style,
        },
    });
    if (inner.width == 0 or inner.height == 0) return;

    // Title over the top border (same position the pre-vaxis frame used).
    _ = root.printSegment(.{ .text = "permission (modal)", .style = modal_style }, .{
        .col_offset = region.x + 2,
        .row_offset = region.y,
        .wrap = .none,
    });

    var row: u16 = 0;
    if (row < inner.height) {
        if (store.format("risk:{s}  args_len:{d}  tool:{s}", .{
            modal.riskSlice(),
            modal.args_len,
            if (modal.tool_name_len == 0) "—" else modal.toolNameSlice(),
        })) |s| {
            printLine(inner, row, s);
        }
        row += 1;
    }
    if (row < inner.height) {
        printLine(inner, row, "[a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny");
    }
}

fn drawHostOverlay(
    root: vaxis.Window,
    layout: layout_mod.Layout,
    ov: OverlayPaint,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    _ = store;
    const style = palette.style(.modal_fg);
    const h: u16 = @min(12, @max(layout.cards.h, 4));
    const w: u16 = @min(root.width, 60);
    const y: u16 = layout.cards.y;
    const x: u16 = if (root.width > w) (root.width - w) / 2 else 0;
    const box = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = style,
        },
    });
    if (box.width == 0 or box.height == 0) return;
    const title: []const u8 = switch (ov.kind) {
        .none => return,
        .help => "help",
        .slash_palette => "slash",
        .settings => "settings",
        .model => "model",
        .theme => "theme",
    };
    _ = root.printSegment(.{ .text = title, .style = style }, .{
        .col_offset = x + 2,
        .row_offset = y,
        .wrap = .none,
    });
    var row: u16 = 0;
    for (ov.lines, 0..) |line, i| {
        if (row >= box.height) break;
        const marker_ch: []const u8 = if (i == ov.cursor) "> " else "  ";
        var buf: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buf, "{s}{s}", .{ marker_ch, line }) catch line;
        printLineStyled(box, row, rendered, style);
        row += 1;
    }
}

fn singleLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

// ── fixtures (tui-vaxis-001): offscreen cell snapshots ──────────────────────

/// Offscreen canvas: a vaxis.Screen + a root Window built per draw so the
/// Window's `screen` pointer never dangles across value moves. Owns the line
/// store so cell grapheme slices stay valid for the assertions.
const CellScreen = struct {
    screen: vaxis.Screen,
    store: terminal.LineStore = .{},

    fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !CellScreen {
        return .{ .screen = try vaxis.Screen.init(gpa, .{
            .rows = rows,
            .cols = cols,
            .x_pixel = 0,
            .y_pixel = 0,
        }) };
    }

    fn deinit(self: *CellScreen, gpa: std.mem.Allocator) void {
        self.screen.deinit(gpa);
    }

    fn root(self: *CellScreen, cols: u16, rows: u16) vaxis.Window {
        return .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = cols,
            .height = rows,
            .screen = &self.screen,
        };
    }
};

fn drawFixture(
    cs: *CellScreen,
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
) !void {
    cs.* = try CellScreen.init(gpa, cols, rows);
    const layout = layout_mod.compute(.{ .cols = cols, .rows = rows }, snap.len, modal.pending, facts.status_note.len > 0, 0);
    const palette = theme_mod.builtinDefault();
    drawFrame(cs.root(cols, rows), layout, facts, snap, ed, modal, &palette, .{}, &cs.store);
}

/// Cell text of one row (graphemes joined left to right).
fn rowText(screen: *const vaxis.Screen, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var col: u16 = 0;
    while (col < screen.width) : (col += 1) {
        const cell = screen.readCell(col, row) orelse break;
        const g = cell.char.grapheme;
        if (n + g.len > buf.len) break;
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

/// Assert the full row equals `expected` padded with spaces to the width,
/// compared CELL-by-cell (graphemes, not raw bytes — box-drawing glyphs are
/// multi-byte UTF-8). Fixture expectations are single-codepoint glyphs.
fn expectRowEquals(screen: *const vaxis.Screen, row: u16, expected: []const u8) !void {
    var col: u16 = 0;
    var off: usize = 0;
    while (col < screen.width) : (col += 1) {
        const cell = screen.readCell(col, row) orelse return error.TestUnexpectedResult;
        if (off < expected.len) {
            var end = off + 1;
            while (end < expected.len and (expected[end] & 0xC0) == 0x80) end += 1;
            try std.testing.expectEqualStrings(expected[off..end], cell.char.grapheme);
            off = end;
        } else {
            try std.testing.expectEqualStrings(" ", cell.char.grapheme);
        }
    }
    // The expected content must fit within the row width.
    try std.testing.expect(off == expected.len);
}

fn expectCellEquals(screen: *const vaxis.Screen, col: u16, row: u16, expected: []const u8) !void {
    const cell = screen.readCell(col, row) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, cell.char.grapheme);
}

fn expectRowContains(screen: *const vaxis.Screen, row: u16, needle: []const u8) !void {
    var buf: [512]u8 = undefined;
    const actual = rowText(screen, row, &buf);
    try std.testing.expect(std.mem.indexOf(u8, actual, needle) != null);
}

/// Editor storage outlives the fixture (file-scope global).
var fixture_editor_storage: [c.editor_max_bytes]u8 = undefined;

const RenderFixture = struct {
    facts_full: StatusFacts,
    facts_constrained: StatusFacts,
    snap: [2]cards.CardSlot,
    ed: editor.Editor,
    modal: permission.ModalSnapshot,
};

fn fixedFixture() RenderFixture {
    var c0 = cards.CardSlot{ .occupied = true, .title_len = 9, .body_len = 20 };
    @memcpy(c0.title[0..9], "run_start");
    @memcpy(c0.body[0..20], "session_configured=y");
    var c1 = cards.CardSlot{ .occupied = true, .title_len = 16, .body_len = 11 };
    @memcpy(c1.title[0..16], "assistant turn=1");
    @memcpy(c1.body[0..11], "hello world");

    var modal = permission.ModalSnapshot{ .pending = true, .risk_len = 6, .args_len = 23, .tool_name_len = 10 };
    @memcpy(modal.risk_label[0..6], "medium");
    @memcpy(modal.tool_name[0..10], "write_file");

    return .{
        .facts_full = .{
            .id_display = "sess-abc",
            .open_display = "create_new",
            .session_configured = true,
            .perm = "ask",
            .shell = "protect",
            .state = .busy,
            .status_note = "",
            .steering_pending = 2,
            .followup_pending = 1,
        },
        .facts_constrained = .{
            .id_display = "sess-abc",
            .open_display = "n/a",
            .session_configured = false,
            .perm = "ask",
            .shell = "protect",
            .state = .busy,
            .status_note = "",
            .steering_pending = 0,
            .followup_pending = 0,
        },
        .snap = .{ c0, c1 },
        .ed = editor.Editor.init(&fixture_editor_storage),
        .modal = modal,
    };
}

// Full-mode parity (tui-vaxis-001): the pre-vaxis GOLDEN_FULL frame at
// 80×24 translated into cells. Rows outside the modal match byte-for-byte;
// the modal is the sanctioned visual upgrade (rounded border + style) with
// the same interior content.
test "render full-mode cells match pre-vaxis golden (80x24)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 0, "┌─ zag  tui ─");
    try expectRowEquals(&cs.screen, 1, "│ id: sess-abc  open:create_new cfg:y");
    try expectRowEquals(&cs.screen, 2, "│ perm:ask  shell:protect  state:busy  S:2 F:1");
    try expectRowEquals(&cs.screen, 3, "├─ transcript ─");
    try expectRowEquals(&cs.screen, 4, "│ · run_start");
    try expectRowEquals(&cs.screen, 5, "│   session_configured=y");
    try expectRowEquals(&cs.screen, 6, "│ · assistant turn=1");
    try expectRowEquals(&cs.screen, 7, "│   hello world");
    try expectRowEquals(&cs.screen, 21, "├─ editor ─");
    try expectRowEquals(&cs.screen, 22, "│ > ");
    try expectRowEquals(&cs.screen, 23, "│ model:— theme:zag-default [0/65536] [/ palette · PgUp/Dn]");
    // Rows the golden frame clears stay blank cells.
    var row: u16 = 8;
    while (row < 17) : (row += 1) try expectRowEquals(&cs.screen, row, "");

    // Modal: rounded border cells present; interior content at the pre-vaxis
    // positions (content starts one cell inside the border, like the old
    // `│`-prefixed lines).
    try expectCellEquals(&cs.screen, 0, 17, "╭");
    try expectCellEquals(&cs.screen, 79, 17, "╮");
    try expectCellEquals(&cs.screen, 0, 20, "╰");
    try expectCellEquals(&cs.screen, 79, 20, "╯");
    try expectCellEquals(&cs.screen, 0, 18, "│");
    try expectCellEquals(&cs.screen, 79, 18, "│");
    try expectCellEquals(&cs.screen, 0, 19, "│");
    try expectCellEquals(&cs.screen, 79, 19, "│");
    try expectRowContains(&cs.screen, 17, "permission (modal)");
    try expectRowContains(&cs.screen, 18, "risk:medium  args_len:23  tool:write_file");
    try expectRowContains(&cs.screen, 19, "[a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny");
}

test "render wide frame 130 cols matches golden rows (no truncation)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 130, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 0, "┌─ zag  tui ─");
    try expectRowEquals(&cs.screen, 1, "│ id: sess-abc  open:create_new cfg:y");
    try expectRowEquals(&cs.screen, 2, "│ perm:ask  shell:protect  state:busy  S:2 F:1");
    try expectRowEquals(&cs.screen, 3, "├─ transcript ─");
    try expectRowEquals(&cs.screen, 4, "│ · run_start");
    try expectRowEquals(&cs.screen, 5, "│   session_configured=y");
    try expectRowEquals(&cs.screen, 6, "│ · assistant turn=1");
    try expectRowEquals(&cs.screen, 7, "│   hello world");
    try expectRowEquals(&cs.screen, 21, "├─ editor ─");
    try expectRowEquals(&cs.screen, 22, "│ > ");
    try expectRowEquals(&cs.screen, 23, "│ model:— theme:zag-default [0/65536] [/ palette · PgUp/Dn]");
    try expectRowContains(&cs.screen, 17, "permission (modal)");
    // Wide modal border spans the full width.
    try expectCellEquals(&cs.screen, 0, 17, "╭");
    try expectCellEquals(&cs.screen, 129, 17, "╮");
}

test "render constrained-mode cells match pre-vaxis golden (30x8)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 30, 8, f.facts_constrained, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 0, "[zag tui · constrained]");
    try expectRowEquals(&cs.screen, 1, "state=busy id=sess-abc");
    try expectRowEquals(&cs.screen, 2, "· assistant turn=1");
    try expectRowEquals(&cs.screen, 3, "· run_start");
    try expectRowEquals(&cs.screen, 4, "> ");
    var row: u16 = 5;
    while (row < 8) : (row += 1) try expectRowEquals(&cs.screen, row, "");
}

test "render state:{s} text present in header cells (PTY marker contract)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;

    facts.state = .idle;
    var cs_idle: CellScreen = undefined;
    try drawFixture(&cs_idle, gpa, 80, 24, facts, &f.snap, &f.ed, .{});
    defer cs_idle.deinit(gpa);
    try expectRowContains(&cs_idle.screen, 2, "state:idle");

    facts.state = .closing;
    var cs_closing: CellScreen = undefined;
    try drawFixture(&cs_closing, gpa, 80, 24, facts, &f.snap, &f.ed, .{});
    defer cs_closing.deinit(gpa);
    try expectRowContains(&cs_closing.screen, 2, "state:closing");
}

test "render body preview truncated to region width on UTF-8 boundary" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // 80 cols → body limit = min(120, 77) = 77. A 2-byte é straddles the cut;
    // the whole codepoint must be dropped (76 a's, no é).
    var long = cards.CardSlot{ .occupied = true, .title_len = 3, .body_len = 81 };
    @memcpy(long.title[0..3], "big");
    @memcpy(long.body[0..76], "a" ** 76);
    @memcpy(long.body[76..78], "\xc3\xa9");
    @memcpy(long.body[78..81], "xyz");
    const snap = [_]cards.CardSlot{ long };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 5, ("│   " ++ ("a" ** 76)));
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var buf: [512]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, rowText(&cs.screen, row, &buf), "\xc3\xa9") == null);
    }
}

test "render title truncated to region width (min-cap holds)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // 80 cols → title cap = min(128, 78) = 78; the row clips at 80 cells
    // (4 for "│ · " + 76 t's).
    var slot = cards.CardSlot{ .occupied = true, .title_len = 100, .body_len = 0 };
    @memcpy(slot.title[0..100], "t" ** 100);
    const snap = [_]cards.CardSlot{ slot };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 4, ("│ · " ++ ("t" ** 76)));
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var buf: [512]u8 = undefined;
        const text = rowText(&cs.screen, row, &buf);
        try std.testing.expect(std.mem.indexOf(u8, text, "t" ** 77) == null);
    }
}

test "render multi-line editor clipped to the fixed content row" {
    const gpa = std.testing.allocator;
    var f = fixedFixture();
    _ = f.ed.insert("line1\nline2");
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 22, "│ > line1");
    try expectRowEquals(&cs.screen, 23, "│ model:— theme:zag-default [11/65536] [/ palette · PgUp/Dn]");
}

test "render header strings min-capped to region width" {
    const gpa = std.testing.allocator;
    var f = fixedFixture();
    f.facts_full.id_display = "x" ** 100;
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);

    // "│ id: " (8 cells) + 72 x's = 80; longer runs must not appear.
    try expectRowEquals(&cs.screen, 1, ("│ id: " ++ ("x" ** 72)));
}

test "render no-events frame" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &.{}, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectRowEquals(&cs.screen, 4, "│ (no events yet)");
}

test "render degenerate 20x5 constrained never overflows" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 20, 5, f.facts_constrained, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    // Header line clips at 20 cells; no crash, no out-of-bounds write.
    // "[zag tui · constrained]": cells 0-8, "·" 9, " " 10, "constrained]" 11-22
    // → cell 19 is the 9th char of "constrained]" ("n").
    try expectCellEquals(&cs.screen, 19, 0, "n");
    try expectRowEquals(&cs.screen, 4, "> ");
}
