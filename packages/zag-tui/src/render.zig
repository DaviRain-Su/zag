//! vaxis cell renderer (tui-vaxis-001). Thin shell over `layout.compute`:
//! per-region draw functions write only within their region windows
//! (`root.child(.{ .x_off, .y_off, .width, .height })`); card bodies/titles
//! truncate per the tui-layout-001 rules (utf8Prefix min-caps); multi-line
//! editor content clips to the fixed content row; `state:{s}` stays present
//! in the status meta line (PTY grep contract). `vx.render()` diff replaces the
//! old full-frame ANSI; the offscreen fixtures assert the cell content that
//! the pre-vaxis golden frames encode.

const std = @import("std");
const vaxis = @import("vaxis");
const c = @import("constants.zig");
const cards = @import("cards.zig");
const editor = @import("editor.zig");
const layout_mod = @import("layout.zig");
const md_parse = @import("md_parse.zig");
const md_render = @import("md_render.zig");
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
    /// Transcript scroll offset (0 = newest window); shown as feedback.
    scroll: usize = 0,
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
/// drifted (belt-and-braces on top of winsize events). `layout` is computed
/// by the caller (paint() keeps the cards region height for page scrolling).
pub fn renderFrame(
    term: *terminal.Terminal,
    size: terminal.Size,
    layout: layout_mod.Layout,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
    palette: *const theme_mod.Palette,
    ov: OverlayPaint,
) error{WriteFailed}!void {
    term.ensureSize(size);
    if (last_drawn_state == null or last_drawn_state.? != facts.state) {
        term.vx.queueRefresh();
        last_drawn_state = facts.state;
    }
    // The vaxis screen borrows cell graphemes from the formatted lines; the
    // store must outlive `render()` below (and lives across paints). The
    // markdown parse arena is retained across frames (see Terminal.md_arena)
    // so screen/diff cell slices stay valid; reset it for this frame's parses.
    term.scratch.len = 0;
    _ = term.md_arena.reset(.retain_capacity);
    const root = term.vx.window();
    drawFrame(term.md_arena.allocator(), root, layout, facts, snap, ed, modal, palette, ov, &term.scratch);
    term.render() catch return error.WriteFailed;
}

/// Draw a frame into `root` (the vaxis window). Tests draw into an offscreen
/// window over a `vaxis.Screen` and assert the resulting cells (keeping the
/// store alive for the cell reads). `gpa` backs the per-paint markdown parse
/// arena (tui-markdown-001).
fn drawFrame(
    gpa: std.mem.Allocator,
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
            drawCards(gpa, childRegion(root, layout.cards), layout.cards_window, layout.mode, snap, palette, store);
            drawEditor(childRegion(root, layout.editor), layout.mode, ed, palette);
        },
        .full => {
            // Closed frame (tui-polish-001): every region is a vaxis bordered
            // child. The header's top border opens the frame, the cards/editor
            // top borders draw `├ … ┤` separators on the shared side rails,
            // and the status region's bottom border closes it. Labels are
            // overlaid on the border rows (drawModal pattern).
            const border_style = palette.style(.card_border);
            const header_win = borderedChild(root, layout.header, .{
                .where = .{ .other = .{ .top = true, .left = true, .right = true } },
                .glyphs = .single_square,
                .style = border_style,
            });
            const cards_win = borderedChild(root, layout.cards, .{
                .where = .{ .other = .{ .top = true, .left = true, .right = true } },
                .glyphs = .{ .custom = .{ "├", "─", "┤", "│", "┘", "└" } },
                .style = border_style,
            });
            const editor_win = borderedChild(root, layout.editor, .{
                .where = .{ .other = .{ .top = true, .left = true, .right = true } },
                .glyphs = .{ .custom = .{ "├", "─", "┤", "│", "┘", "└" } },
                .style = border_style,
            });
            const status_win = borderedChild(root, layout.status, .{
                .where = .{ .other = .{ .left = true, .right = true, .bottom = true } },
                .glyphs = .single_square,
                .style = border_style,
            });

            drawHeader(header_win, layout.mode, facts, palette, store);
            drawCards(gpa, cards_win, layout.cards_window, layout.mode, snap, palette, store);
            drawEditor(editor_win, layout.mode, ed, palette);
            drawStatus(status_win, layout.mode, facts, ed, palette, store);

            overlayLineTitle(root, layout.header, " zag  tui ", palette.style(.status_fg));
            overlayLineTitle(root, layout.cards, " transcript ", border_style);
            overlayLineTitle(root, layout.editor, " editor ", border_style);

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

/// Bordered child over a layout region (interior insets by the drawn sides).
fn borderedChild(root: vaxis.Window, region: layout_mod.Region, border: vaxis.Window.BorderOptions) vaxis.Window {
    return root.child(.{
        .x_off = region.x,
        .y_off = region.y,
        .width = region.w,
        .height = region.h,
        .border = border,
    });
}

/// Overlay a label on a region's top border row (drawModal title pattern).
fn overlayLineTitle(root: vaxis.Window, region: layout_mod.Region, text: []const u8, style: vaxis.Style) void {
    _ = root.printSegment(.{ .text = text, .style = style }, .{
        .col_offset = region.x + 2,
        .row_offset = region.y,
        .wrap = .none,
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
    const header_style = mergedFgBg(palette, .status_fg, .status_bg);
    var row: u16 = 0;
    if (mode == .constrained) {
        if (row < win.height) {
            printLine(win, row, "[zag tui · constrained]");
        }
        return;
    }
    // Full mode: the frame's top border + title are drawn by drawFrame; the
    // interior starts at the id line.
    if (row < win.height) {
        if (store.format(" id: {s}  open:{s} cfg:{s}", .{
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
        if (store.format(" perm:{s}  shell:{s}  state:{s}{s}", .{
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
        if (store.format(" note: {s}", .{facts.status_note})) |s| {
            printLineStyled(win, row, s, header_style);
        }
    }
}

/// Merge an `*_fg` and an `*_bg` role into one style (bg roles parse to
/// `.bg`; builtins leave the bg default).
fn mergedFgBg(palette: *const theme_mod.Palette, fg_role: theme_mod.Role, bg_role: theme_mod.Role) vaxis.Style {
    const fg = palette.style(fg_role);
    const bg = palette.style(bg_role);
    return .{ .fg = fg.fg, .bg = bg.bg };
}

fn drawCards(
    gpa: std.mem.Allocator,
    win: vaxis.Window,
    window: layout_mod.CardsWindow,
    mode: layout_mod.Mode,
    snap: []const cards.CardSlot,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    var row: u16 = 0;
    const w: u16 = win.width;
    const title_limit = @min(@as(usize, 128), @max(@as(usize, w), 2) - 2);

    if (mode == .full) {
        // The `├ … ┤` separator row is the region's border (drawFrame); the
        // interior starts at the first card.
        if (window.count == 0) {
            if (row < win.height) {
                printLineStyled(win, row, "(no events yet)", palette.style(.card_fg));
            }
            return;
        }
        var i: usize = 0;
        while (i < window.count and row < win.height) : (i += 1) {
            const card = &snap[window.start + i];
            const style = cardStyle(card.kind, palette);
            if (row < win.height) {
                const title = present.utf8Prefix(card.titleSlice(), title_limit);
                if (store.format("· {s}", .{title})) |s| {
                    printLineStyled(win, row, s, style);
                }
                row += 1;
            }
            // Body rendering only for assistant + user cards (tool/terminal/
            // host-error rows stay single-title — transcript compaction).
            // The body is the already-redacted card buffer; markdown is
            // rendered multi-line, clipped to the cards region (tui-markdown-
            // 001). Fallback on parse failure/OOM: raw text, never blank.
            const is_assistant = std.mem.startsWith(u8, card.titleSlice(), "assistant");
            if ((is_assistant or card.kind == .user) and card.body_len > 0 and row < win.height) {
                const body_win = win.child(.{
                    .x_off = 2,
                    .y_off = row,
                    .width = if (win.width > 2) win.width - 2 else 1,
                    .height = win.height - row,
                });
                const md_style = md_render.MdStyle.forCard(palette, style);
                const md_rows: u16 = if (md_parse.parseMarkdown(gpa, card.bodySlice())) |doc|
                    md_render.renderMarkdownIntoStyled(gpa, body_win, doc, md_style)
                else
                    md_render.renderRawIntoStyled(gpa, body_win, card.bodySlice(), md_style);
                row += md_rows;
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
            printLineStyled(win, row, s, cardStyle(card.kind, palette));
        }
        row += 1;
    }
}

/// card.kind drives color: host_error → error_fg, terminal/drop_note →
/// muted_fg, user → accent_fg (distinct from assistant output), ordinary →
/// card_fg.
fn cardStyle(kind: cards.CardKind, palette: *const theme_mod.Palette) vaxis.Style {
    return switch (kind) {
        .host_error => palette.style(.error_fg),
        .terminal, .drop_note => palette.style(.muted_fg),
        .user => palette.style(.accent_fg),
        .ordinary => palette.style(.card_fg),
    };
}

fn drawEditor(win: vaxis.Window, mode: layout_mod.Mode, ed: *const editor.Editor, palette: *const theme_mod.Palette) void {
    const editor_style = mergedFgBg(palette, .editor_fg, .editor_bg);
    const row: u16 = 0;
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
    // Full mode: the `├ … ┤` separator row is the region's border; the
    // single fixed content row is the first editor line, clipped like card
    // bodies. The interior ` > ` maps to the same absolute cursor column the
    // pre-vaxis `│ > ` frame used (the `│` moved into the border).
    if (row < win.height) {
        _ = win.printSegment(.{ .text = " > ", .style = editor_style }, .{ .row_offset = row, .wrap = .none });
        if (first_line.len > 0) {
            _ = win.printSegment(.{ .text = first_line }, .{ .row_offset = row, .col_offset = 3, .wrap = .none });
        } else {
            // Placeholder hint (muted) until the user types.
            _ = win.printSegment(.{ .text = "输入消息，/ 查看命令", .style = palette.style(.muted_fg) }, .{ .row_offset = row, .col_offset = 3, .wrap = .none });
        }
        const prefix = if (ed.cursor <= first_line.len) content[0..ed.cursor] else first_line;
        win.showCursor(3 + win.gwidth(prefix), row);
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
    _ = ed; // meta line no longer shows the byte counter (minimal look)
    const status_style = palette.style(.accent_fg);
    if (win.height < 1) return;
    if (mode == .constrained) {
        if (store.format("state={s} id={s}", .{ stateName(facts.state), facts.id_display })) |s| {
            printLineStyled(win, 0, s, status_style);
        }
        return;
    }
    // Meta line: model · theme · state (+ scroll feedback + hints). Built
    // with store (persistent bytes survive render()).
    if (store.format(" model:{s} theme:{s} state:{s}", .{
        facts.model,
        facts.theme_id,
        stateName(facts.state),
    })) |s| {
        printLineStyled(win, 0, s, status_style);
        var col: usize = win.gwidth(s);
        if (facts.scroll > 0) {
            if (store.format(" ↑{d}", .{facts.scroll})) |n| {
                _ = win.printSegment(.{ .text = n, .style = palette.style(.error_fg) }, .{
                    .row_offset = 0,
                    .col_offset = @intCast(col),
                    .wrap = .none,
                });
                col += win.gwidth(n);
            }
        }
        if (store.format(" [PgUp/Dn 滚动 · / 命令]", .{})) |n| {
            _ = win.printSegment(.{ .text = n, .style = palette.style(.muted_fg) }, .{
                .row_offset = 0,
                .col_offset = @intCast(col + 1),
                .wrap = .none,
            });
        }
        if (facts.status_note.len > 0) {
            if (store.format(" · {s}", .{facts.status_note})) |n| {
                _ = win.printSegment(.{ .text = n, .style = status_style }, .{
                    .row_offset = 0,
                    .col_offset = @intCast(col + 1),
                    .wrap = .none,
                });
            }
        }
    }
}

/// Modal overlay: rounded vaxis border in `modal_border` + content in
/// `modal_fg` (the visual upgrade), title printed over the top border, two
/// content rows inside. Geometry is layout.zig's.
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
            .style = palette.style(.modal_border),
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
            printLineStyled(inner, row, s, modal_style);
        }
        row += 1;
    }
    if (row < inner.height) {
        printLineStyled(inner, row, "[a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny", modal_style);
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
    const y: u16 = layout.cards.y + 1; // skip the cards region's `├ … ┤` separator row
    const x: u16 = if (root.width > w) (root.width - w) / 2 else 0;
    const box = root.child(.{
        .x_off = x,
        .y_off = y,
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = palette.style(.modal_border),
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
        // Split marker + line into TWO segments: vaxis printSegment borrows
        // the text slice into cells (no copy), so a stack-allocated joined
        // buffer would dangle by the time render() diffs. The marker is a
        // compile-time literal and `line` lives in the App's persistent
        // overlay_line_bufs — both safe to borrow.
        _ = box.printSegment(.{ .text = marker_ch, .style = style }, .{
            .row_offset = row,
            .wrap = .none,
        });
        _ = box.printSegment(.{ .text = line, .style = style }, .{
            .row_offset = row,
            .col_offset = @intCast(marker_ch.len),
            .wrap = .none,
        });
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
    /// Markdown parse arena (tui-markdown-001): cell graphemes borrow koino
    /// Text slices, so the arena must outlive the assertions.
    md_arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !CellScreen {
        return .{
            .screen = try vaxis.Screen.init(gpa, .{
                .rows = rows,
                .cols = cols,
                .x_pixel = 0,
                .y_pixel = 0,
            }),
            .md_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *CellScreen, gpa: std.mem.Allocator) void {
        self.md_arena.deinit();
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
    drawFrame(cs.md_arena.allocator(), cs.root(cols, rows), layout, facts, snap, ed, modal, &palette, .{}, &cs.store);
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

/// Assert the cell style fg at (col,row) is an index color equal to `expected`.
fn expectCellFgIndex(screen: *const vaxis.Screen, col: u16, row: u16, expected: u8) !void {
    const cell = screen.readCell(col, row) orelse return error.TestUnexpectedResult;
    switch (cell.style.fg) {
        .index => |i| try std.testing.expectEqual(expected, i),
        else => return error.TestUnexpectedResult,
    }
}

/// UTF-8 codepoint count of `s` (== cell count for single-width glyphs).
fn utf8CellCount(s: []const u8) ?usize {
    return std.unicode.utf8CountCodepoints(s) catch null;
}

/// Assert a bordered content row: `│` + interior padded to width-2 cells +
/// `│`. Padding is CELL-based so multi-byte interior glyphs (· —) pad right.
fn expectBorderedRow(screen: *const vaxis.Screen, row: u16, interior: []const u8) !void {
    const interior_cells = utf8CellCount(interior) orelse return error.TestUnexpectedResult;
    if (interior_cells > @as(usize, screen.width) - 2) return error.TestUnexpectedResult;
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const vertical: []const u8 = "│";
    @memcpy(buf[n..][0..vertical.len], vertical);
    n += vertical.len;
    @memcpy(buf[n..][0..interior.len], interior);
    n += interior.len;
    const pad = @as(usize, screen.width) - 2 - interior_cells;
    @memset(buf[n .. n + pad], ' ');
    n += pad;
    @memcpy(buf[n..][0..vertical.len], vertical);
    n += vertical.len;
    try expectRowEquals(screen, row, buf[0..n]);
}

/// Assert a separator row: `├─` + label + `─`… + `┤` (label cell count).
fn expectSeparatorRow(screen: *const vaxis.Screen, row: u16, label: []const u8) !void {
    const label_cells = utf8CellCount(label) orelse return error.TestUnexpectedResult;
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const prefix: []const u8 = "├─";
    const h: []const u8 = "─";
    const suffix: []const u8 = "┤";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    @memcpy(buf[n..][0..label.len], label);
    n += label.len;
    var cells: usize = 2 + label_cells;
    while (cells < @as(usize, screen.width) - 1) : (cells += 1) {
        @memcpy(buf[n..][0..h.len], h);
        n += h.len;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    try expectRowEquals(screen, row, buf[0..n]);
}

/// Assert the frame's top border row: `┌─` + title + `─`… + `┐`.
fn expectTopBorderRow(screen: *const vaxis.Screen, row: u16, title: []const u8) !void {
    const title_cells = utf8CellCount(title) orelse return error.TestUnexpectedResult;
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const prefix: []const u8 = "┌─";
    const h: []const u8 = "─";
    const suffix: []const u8 = "┐";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    @memcpy(buf[n..][0..title.len], title);
    n += title.len;
    var cells: usize = 2 + title_cells;
    while (cells < @as(usize, screen.width) - 1) : (cells += 1) {
        @memcpy(buf[n..][0..h.len], h);
        n += h.len;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    try expectRowEquals(screen, row, buf[0..n]);
}

/// Assert the frame's bottom border row: `└` + `─`… + `┘`.
fn expectBottomBorderRow(screen: *const vaxis.Screen, row: u16) !void {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const prefix: []const u8 = "└";
    const h: []const u8 = "─";
    const suffix: []const u8 = "┘";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    var cells: usize = 1;
    while (cells < @as(usize, screen.width) - 1) : (cells += 1) {
        @memcpy(buf[n..][0..h.len], h);
        n += h.len;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    try expectRowEquals(screen, row, buf[0..n]);
}

/// Assert the modal's top border row (rounded, title overlaid): `╭─` +
/// "permission (modal)" + `─`… + `╮`.
fn expectModalTopRow(screen: *const vaxis.Screen, row: u16) !void {
    const title: []const u8 = "permission (modal)";
    const title_cells = utf8CellCount(title) orelse return error.TestUnexpectedResult;
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const prefix: []const u8 = "╭─";
    const h: []const u8 = "─";
    const suffix: []const u8 = "╮";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    @memcpy(buf[n..][0..title.len], title);
    n += title.len;
    var cells: usize = 2 + title_cells;
    while (cells < @as(usize, screen.width) - 1) : (cells += 1) {
        @memcpy(buf[n..][0..h.len], h);
        n += h.len;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    try expectRowEquals(screen, row, buf[0..n]);
}

/// Assert the modal's bottom border row: `╰` + `─`… + `╯`.
fn expectModalBottomRow(screen: *const vaxis.Screen, row: u16) !void {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    const prefix: []const u8 = "╰";
    const h: []const u8 = "─";
    const suffix: []const u8 = "╯";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    var cells: usize = 1;
    while (cells < @as(usize, screen.width) - 1) : (cells += 1) {
        @memcpy(buf[n..][0..h.len], h);
        n += h.len;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    try expectRowEquals(screen, row, buf[0..n]);
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
    // Post-compaction transcript shape: a tool row (ordinary kind, body kept
    // but NOT previewed) + an assistant card (body previewed).
    var c0 = cards.CardSlot{ .occupied = true, .title_len = 15, .body_len = 13 };
    @memcpy(c0.title[0..15], "tool write_file");
    @memcpy(c0.body[0..13], "id=t1 args={}");
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

// Full-mode frame (tui-polish-001): the four regions draw as vaxis bordered
// children — top border with the "zag tui" title, `├ … ┤` separators on the
// transcript/editor rows, shared side rails, bottom border closing the frame.
// The permission modal keeps its rounded border + interior rows.
test "render full-mode cells match the closed-frame golden (80x24)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);

    // Minimal frame: row 0 is the top border (title overlaid) — the header
    // is a single border row, so the transcript separator follows directly
    // at row 1 (the id/perm/shell info lines are gone).
    try expectTopBorderRow(&cs.screen, 0, " zag  tui ");
    try expectSeparatorRow(&cs.screen, 1, " transcript ");
    // Card rows (tool row single title, assistant title + body preview),
    // then the cards region's side rails to row 14.
    try expectBorderedRow(&cs.screen, 2, "· tool write_file");
    try expectBorderedRow(&cs.screen, 3, "· assistant turn=1");
    try expectBorderedRow(&cs.screen, 4, "  hello world");
    var row: u16 = 5;
    while (row < 15) : (row += 1) try expectBorderedRow(&cs.screen, row, "");
    // Row 15 is the gap between the cards region and the modal (blank).
    try expectRowEquals(&cs.screen, 15, "");
    // Modal: rounded border at rows 16-19 (full width), title + two rows.
    try expectModalTopRow(&cs.screen, 16);
    try expectBorderedRow(&cs.screen, 17, "risk:medium  args_len:23  tool:write_file");
    try expectBorderedRow(&cs.screen, 18, "[a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny");
    try expectModalBottomRow(&cs.screen, 19);
    // Editor separator + placeholder content, status meta line, bottom
    // border closes the frame. The placeholder is ` > ` at interior cols
    // 0-2 then the muted CJK hint; each CJK glyph is 2 cells wide in vaxis
    // (the odd cells are skipped), so assert cell-by-cell instead of the
    // full row.
    try expectSeparatorRow(&cs.screen, 20, " editor ");
    try expectCellEquals(&cs.screen, 1, 21, " ");
    try expectCellEquals(&cs.screen, 2, 21, ">");
    try expectCellEquals(&cs.screen, 3, 21, " ");
    try expectCellEquals(&cs.screen, 4, 21, "输");
    try expectCellEquals(&cs.screen, 14, 21, "/");
    try expectCellEquals(&cs.screen, 22, 21, "令");
    try expectRowContains(&cs.screen, 22, "state:busy");
    try expectRowContains(&cs.screen, 22, "PgUp/Dn");
    try expectBottomBorderRow(&cs.screen, 23);

    // Cell-level frame closure: every corner/edge glyph of the outer frame.
    try expectCellEquals(&cs.screen, 0, 0, "┌");
    try expectCellEquals(&cs.screen, 79, 0, "┐");
    try expectCellEquals(&cs.screen, 0, 23, "└");
    try expectCellEquals(&cs.screen, 79, 23, "┘");
    try expectCellEquals(&cs.screen, 0, 1, "├");
    try expectCellEquals(&cs.screen, 79, 1, "┤");
    try expectCellEquals(&cs.screen, 0, 20, "├");
    try expectCellEquals(&cs.screen, 79, 20, "┤");
    try expectCellEquals(&cs.screen, 0, 2, "│");
    try expectCellEquals(&cs.screen, 79, 2, "│");
    // Modal corner cells (rounded family).
    try expectCellEquals(&cs.screen, 0, 16, "╭");
    try expectCellEquals(&cs.screen, 79, 16, "╮");
    try expectCellEquals(&cs.screen, 0, 19, "╰");
    try expectCellEquals(&cs.screen, 79, 19, "╯");
}

test "render wide frame 130 cols matches golden rows (no truncation)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 130, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);

    try expectTopBorderRow(&cs.screen, 0, " zag  tui ");
    try expectSeparatorRow(&cs.screen, 1, " transcript ");
    try expectBorderedRow(&cs.screen, 2, "· tool write_file");
    try expectBorderedRow(&cs.screen, 3, "· assistant turn=1");
    try expectBorderedRow(&cs.screen, 4, "  hello world");
    try expectSeparatorRow(&cs.screen, 20, " editor ");
    // The editor prompt + CJK placeholder (wide glyphs occupy 2 cells each;
    // assert cells individually since expectBorderedRow miscounts width).
    try expectCellEquals(&cs.screen, 1, 21, " ");
    try expectCellEquals(&cs.screen, 2, 21, ">");
    try expectCellEquals(&cs.screen, 3, 21, " ");
    try expectCellEquals(&cs.screen, 4, 21, "输");
    try expectCellEquals(&cs.screen, 5, 21, " ");
    try expectCellEquals(&cs.screen, 6, 21, "入");
    try expectRowContains(&cs.screen, 22, "state:busy");
    try expectRowContains(&cs.screen, 22, "PgUp/Dn");
    try expectBottomBorderRow(&cs.screen, 23);
    try expectModalTopRow(&cs.screen, 16);
    // Wide modal border spans the full width.
    try expectCellEquals(&cs.screen, 0, 16, "╭");
    try expectCellEquals(&cs.screen, 129, 16, "╮");
    try expectCellEquals(&cs.screen, 0, 23, "└");
    try expectCellEquals(&cs.screen, 129, 23, "┘");
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
    try expectRowEquals(&cs.screen, 3, "· tool write_file");
    try expectRowEquals(&cs.screen, 4, "> ");
    var row: u16 = 5;
    while (row < 8) : (row += 1) try expectRowEquals(&cs.screen, row, "");
}

test "render state:{s} text present in the status meta line (PTY marker contract)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;

    facts.state = .idle;
    var cs_idle: CellScreen = undefined;
    try drawFixture(&cs_idle, gpa, 80, 24, facts, &f.snap, &f.ed, .{});
    defer cs_idle.deinit(gpa);
    // The header is a single border row now; the state text lives in the
    // bottom meta line (status row 22 = rows-2).
    try expectRowContains(&cs_idle.screen, 22, "state:idle");
    try expectRowContains(&cs_idle.screen, 22, "PgUp/Dn");

    facts.state = .closing;
    var cs_closing: CellScreen = undefined;
    try drawFixture(&cs_closing, gpa, 80, 24, facts, &f.snap, &f.ed, .{});
    defer cs_closing.deinit(gpa);
    try expectRowContains(&cs_closing.screen, 22, "state:closing");
}

test "render body preview truncated to interior width on UTF-8 boundary" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // 80 cols → interior width 78 → body content width 76 (2-space indent).
    // The markdown renderer wraps by GRAPHEME: the 2-byte é at byte offset 74
    // survives as a whole cell (74 a's + é + x fill the row; yz wrap to the
    // next row). The old byte-based preview (which dropped the é) is replaced
    // by the md render path.
    var long = cards.CardSlot{ .occupied = true, .title_len = 16, .body_len = 79 };
    @memcpy(long.title[0..16], "assistant turn=2");
    @memcpy(long.body[0..74], "a" ** 74);
    @memcpy(long.body[74..76], "\xc3\xa9");
    @memcpy(long.body[76..79], "xyz");
    const snap = [_]cards.CardSlot{ long };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);

    // First body row: 2-space indent + 74 a's + é + x (76 content cells).
    // Cards start at row 2 (single-row header), so the title is row 2 and
    // the body begins at row 3.
    try expectBorderedRow(&cs.screen, 3, ("  " ++ ("a" ** 74) ++ "\xc3\xa9" ++ "x"));
    // The wrapped tail lands on the next row (no content lost).
    try expectBorderedRow(&cs.screen, 4, "  yz");
}

test "render title truncated to interior width (min-cap holds)" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // 80 cols → interior width 78 → title cap = min(128, 78-2) = 76; the row
    // clips at the interior width: "· " (3) + 75 t's, then the right rail.
    var slot = cards.CardSlot{ .occupied = true, .title_len = 100, .body_len = 0 };
    @memcpy(slot.title[0..100], "t" ** 100);
    const snap = [_]cards.CardSlot{ slot };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectBorderedRow(&cs.screen, 2, ("· " ++ ("t" ** 75)));
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

    try expectBorderedRow(&cs.screen, 21, " > line1");
    // The status meta line no longer carries the byte counter / key hints.
    try expectRowContains(&cs.screen, 22, "state:busy");
    try expectRowContains(&cs.screen, 22, "PgUp/Dn");
}

test "render status strings min-capped to interior width" {
    const gpa = std.testing.allocator;
    var f = fixedFixture();
    f.facts_full.theme_id = "x" ** 100;
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);

    // The header is a border row (nothing to cap there); the meta line is
    // the min-capped string now. Interior is 78 cells: " model:— theme:"
    // (15 cells / 17 bytes) + 61 x's fills the byte cap exactly.
    try expectBorderedRow(&cs.screen, 22, (" model:— theme:" ++ ("x" ** 61)));
}

test "render no-events frame" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &.{}, &f.ed, .{});
    defer cs.deinit(gpa);

    try expectBorderedRow(&cs.screen, 2, "(no events yet)");
}

test "render card kind drives fg style" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // One card of each kind; the fg index at the title's first char follows
    // the kind ramp: ordinary → card_fg (7), terminal/drop_note → muted_fg
    // (8), host_error → error_fg (1).
    var ordinary = cards.CardSlot{ .occupied = true, .title_len = 5, .body_len = 0 };
    @memcpy(ordinary.title[0..5], "alpha");
    var term_card = cards.CardSlot{ .occupied = true, .kind = .terminal, .title_len = 12, .body_len = 0 };
    @memcpy(term_card.title[0..12], "run_terminal");
    var host_error = cards.CardSlot{ .occupied = true, .kind = .host_error, .title_len = 10, .body_len = 0 };
    @memcpy(host_error.title[0..10], "host_error");
    var drop_note = cards.CardSlot{ .occupied = true, .kind = .drop_note, .title_len = 4, .body_len = 0 };
    @memcpy(drop_note.title[0..4], "drop");
    const snap = [_]cards.CardSlot{ ordinary, term_card, host_error, drop_note };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);

    // Title text starts at interior col 2 ("· " prefix) → absolute col 3.
    // Cards begin at row 2 (single-row header → cards_y = 1).
    try expectCellFgIndex(&cs.screen, 3, 2, 7); // ordinary → card_fg
    try expectCellFgIndex(&cs.screen, 3, 3, 8); // terminal → muted_fg
    try expectCellFgIndex(&cs.screen, 3, 4, 1); // host_error → error_fg
    try expectCellFgIndex(&cs.screen, 3, 5, 8); // drop_note → muted_fg
    // Tool/terminal/host-error cards render as single title rows.
    try expectBorderedRow(&cs.screen, 2, "· alpha");
    try expectBorderedRow(&cs.screen, 3, "· run_terminal");
    try expectBorderedRow(&cs.screen, 4, "· host_error");
    try expectBorderedRow(&cs.screen, 5, "· drop");
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

// ── tui-markdown-001 fixtures: transcript card bodies ─────────────────────
//
// drawCards renders assistant + user card bodies through md_render
// (multi-line, clipped to the cards region); tool/terminal/host-error rows
// stay single-title. Geometry at 80x24 (no modal): cards region interior
// rows 2..14 (single-row header → cards_y = 1); the assistant title row is
// 3 and its body starts at row 4, column 2 (border + 1 interior offset).

fn mdCard(title: []const u8, kind: cards.CardKind, body: []const u8) cards.CardSlot {
    var slot = cards.CardSlot{ .occupied = true, .kind = kind };
    slot.title_len = @intCast(@min(title.len, slot.title.len));
    @memcpy(slot.title[0..slot.title_len], title[0..slot.title_len]);
    slot.body_len = @intCast(@min(body.len, slot.body.len));
    @memcpy(slot.body[0..slot.body_len], body[0..slot.body_len]);
    return slot;
}

test "md transcript: assistant card renders multi-line markdown body" {
    const gpa = std.testing.allocator;
    const body = "# Title\n\npara **bold** text.\n\n- one\n- two\n";
    const snap = [_]cards.CardSlot{
        mdCard("tool write_file", .ordinary, "id=t1 args={}"),
        mdCard("assistant turn=1", .ordinary, body),
    };
    var ed = editor.Editor.init(&fixture_editor_storage);
    const facts = StatusFacts{
        .id_display = "sess-x",
        .open_display = "n_a",
        .session_configured = false,
        .perm = "yolo",
        .shell = "protect",
        .state = .idle,
    };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);

    // Tool row stays single-title; assistant title + formatted body follow.
    // Cards begin at row 2 (single-row header → cards_y = 1).
    try expectBorderedRow(&cs.screen, 2, "· tool write_file");
    try expectBorderedRow(&cs.screen, 3, "· assistant turn=1");
    // Body row 4 = the H1 heading: accent fg + bold, markers stripped.
    // Body content starts at absolute col 3 (border + interior + 2 indent).
    try expectCellEquals(&cs.screen, 3, 4, "T");
    try expectCellFgIndex(&cs.screen, 3, 4, 3);
    const h = cs.screen.readCell(3, 4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.style.bold);
    var buf: [512]u8 = undefined;
    const r4 = rowText(&cs.screen, 4, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r4, "# Title") == null);
    try std.testing.expect(std.mem.indexOf(u8, r4, "Title") != null);
    // Bold inline inside the paragraph row (absolute col 8 = "bold" start).
    try expectRowContains(&cs.screen, 5, "bold");
    const bold_cell = cs.screen.readCell(8, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(bold_cell.style.bold);
    // List rows with bullets.
    try expectRowContains(&cs.screen, 6, "• one");
    try expectRowContains(&cs.screen, 7, "• two");
}

test "md transcript: tall assistant body clips at the cards region height" {
    const gpa = std.testing.allocator;
    // 30 paragraphs — far more rows than the 11-row body window.
    var body_buf: [4096]u8 = undefined;
    var n: usize = 0;
    var i: usize = 1;
    while (i <= 30 and n < body_buf.len) : (i += 1) {
        const line = std.fmt.bufPrint(body_buf[n..], "line {d} content\n\n", .{i}) catch break;
        n += line.len;
    }
    const body = body_buf[0..n];
    const snap = [_]cards.CardSlot{mdCard("assistant turn=1", .ordinary, body)};
    var ed = editor.Editor.init(&fixture_editor_storage);
    const facts = StatusFacts{
        .id_display = "sess-x",
        .open_display = "n_a",
        .session_configured = false,
        .perm = "yolo",
        .shell = "protect",
        .state = .idle,
    };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);

    // Single-card layout: the cards region is 14 rows (y=1..14, interior
    // rows 2..14), so the body window is 12 rows (region 14 − title row −
    // border) and the render clips at "line 12" (screen row 14 = 3 + 11);
    // nothing past the region.
    try expectRowContains(&cs.screen, 14, "line 12");
    var buf: [512]u8 = undefined;
    const last = rowText(&cs.screen, 15, &buf);
    try std.testing.expect(std.mem.indexOf(u8, last, "line 13") == null);
    const r16 = rowText(&cs.screen, 16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r16, "line 13") == null);
}

test "md transcript: user card body renders with accent base" {
    const gpa = std.testing.allocator;
    const snap = [_]cards.CardSlot{mdCard("user", .user, "# my question\n")};
    var ed = editor.Editor.init(&fixture_editor_storage);
    const facts = StatusFacts{
        .id_display = "sess-x",
        .open_display = "n_a",
        .session_configured = false,
        .perm = "yolo",
        .shell = "protect",
        .state = .idle,
    };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);

    // User title row 2; body row 3 = the H1: accent fg (user base accent) +
    // bold heading, markers stripped.
    try expectBorderedRow(&cs.screen, 2, "· user");
    try expectCellEquals(&cs.screen, 3, 3, "m");
    try expectCellFgIndex(&cs.screen, 3, 3, 3);
    const h = cs.screen.readCell(3, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.style.bold);
    var buf: [512]u8 = undefined;
    const r3 = rowText(&cs.screen, 3, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r3, "# my question") == null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "my question") != null);
}

test "md transcript: tool rows unchanged (single title, body never rendered)" {
    const gpa = std.testing.allocator;
    const snap = [_]cards.CardSlot{
        mdCard("tool write_file", .ordinary, "id=t1 args={}"),
        mdCard("tool run_shell", .ordinary, "ok=true"),
    };
    var ed = editor.Editor.init(&fixture_editor_storage);
    const facts = StatusFacts{
        .id_display = "sess-x",
        .open_display = "n_a",
        .session_configured = false,
        .perm = "yolo",
        .shell = "protect",
        .state = .idle,
    };
    var cs: CellScreen = undefined;
    try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);

    try expectBorderedRow(&cs.screen, 2, "· tool write_file");
    try expectBorderedRow(&cs.screen, 3, "· tool run_shell");
    // The bodies never appear as rows (tool rows are single-title). Scan the
    // whole cards interior (rows 4..14) plus the gap rows below it.
    var row: u16 = 4;
    while (row < 17) : (row += 1) {
        var buf: [512]u8 = undefined;
        const text = rowText(&cs.screen, row, &buf);
        try std.testing.expect(std.mem.indexOf(u8, text, "id=t1") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "ok=true") == null);
    }
}
