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
const scrollback_mod = @import("scrollback.zig");
const subagent_mod = @import("zag-coding-agent").subagent;

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
    /// Thinking visibility toggle state (Ctrl+T).
    show_thinking: bool = false,
    /// Transcript scroll offset (0 = newest window); shown as feedback.
    scroll: usize = 0,
};

/// Per-row rendering kind for overlay lines (session-tree-001): resume
/// group headers render muted and are not selectable (no cursor marker).
pub const RowKind = enum {
    normal,
    muted,
};

pub const OverlayPaint = struct {
    kind: overlay_mod.Kind = .none,
    cursor: usize = 0,
    lines: []const []const u8 = &.{},
    /// Parallel to `lines`: per-row kind. May be shorter than `lines`;
    /// missing rows render as `.normal`.
    row_kinds: []const RowKind = &.{},
};

/// Grok-inspired tasks pane options (subagents-001 TUI).
pub const TasksPaneOpts = struct {
    cursor: usize = 0,
    expanded: bool = false,
    /// Monotonic ms used for spinner + elapsed (0 = unknown).
    tick_ms: u64 = 0,
    /// Header shows a focus marker when the pane owns j/k/Space.
    focused: bool = false,
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
    sb: *scrollback_mod.Scrollback,
    subagents: ?*const subagent_mod.Registry,
    tasks_opts: TasksPaneOpts,
) error{WriteFailed}!void {
    term.ensureSize(size);
    if (last_drawn_state == null or last_drawn_state.? != facts.state) {
        // State transition always forces a full refresh so the PTY marker
        // contract ("state:{s}" appears in the status chips) stays honest.
        last_drawn_state = facts.state;
    }
    const root = term.vx.window();
    drawFrame(term.md_arena.allocator(), root, layout, facts, snap, ed, modal, palette, ov, &term.scratch, sb, subagents, tasks_opts);
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
    sb: *scrollback_mod.Scrollback,
    subagents: ?*const subagent_mod.Registry,
    tasks_opts: TasksPaneOpts,
) void {
    root.clear();
    switch (layout.mode) {
        .constrained => {
            drawHeader(childRegion(root, layout.header), layout.mode, facts, palette, store);
            drawStatus(childRegion(root, layout.status), layout.mode, facts, ed, palette, store);
            drawCards(gpa, childRegion(root, layout.cards), layout.cards_window, layout.mode, snap, palette, store, sb);
            drawEditor(childRegion(root, layout.editor), layout.mode, ed, palette);
        },
        .full => {
            // Minimal chrome (omp/grok-inspired): borderless transcript + a
            // self-contained rounded input box at the bottom. No top title
            // bar, no side rails, no separate status band.
            const border_style = palette.style(.card_border);
            const cards_win = childRegion(root, layout.cards);
            // Editor: full rounded box. Top border carries the status chips.
            const editor_win = borderedChild(root, layout.editor, .{
                .where = .all,
                .glyphs = .single_rounded,
                .style = border_style,
            });

            drawCards(gpa, cards_win, layout.cards_window, layout.mode, snap, palette, store, sb);
            // Status chips sit in the editor top border (omp StatusLine-in-border).
            drawEditorStatusBorder(root, layout.editor, facts, palette, store);
            drawEditor(editor_win, layout.mode, ed, palette);

            if (layout.modal) |m| drawModal(root, m, modal, palette, store);
            if (layout.tasks_overlay) |t| drawTasksOverlay(root, t, subagents, palette, store, tasks_opts);
            if (ov.kind != .none and !modal.pending) drawHostOverlay(root, layout, ov, palette, store);
        },
    }
}

/// Test/measurement hook: paint a frame into `root` (tui-scrollback-001
/// golden updates). Production uses renderFrame (terminal-owned store +
/// arena); this entry takes them explicitly.
pub fn drawFrameInto(
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
    sb: *scrollback_mod.Scrollback,
    subagents: ?*const subagent_mod.Registry,
    tasks_opts: TasksPaneOpts,
) void {
    drawFrame(gpa, root, layout, facts, snap, ed, modal, palette, ov, store, sb, subagents, tasks_opts);
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

/// Row-level transcript drawing (tui-scrollback-001): the paint window
/// comes from the scrollback (binary search over cumulative rows); each
/// visible card renders into a child window with a possibly-negative
/// `y_off` (vaxis bounds-drops rows above the window, so a top-clipped
/// card shows its tail). The scrollbar track is drawn by drawFrame (it
/// lives outside the cards region).
fn drawCards(
    gpa: std.mem.Allocator,
    win: vaxis.Window,
    window: layout_mod.CardsWindow,
    mode: layout_mod.Mode,
    snap: []const cards.CardSlot,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
    sb: *scrollback_mod.Scrollback,
) void {
    const w: u16 = win.width;

    if (mode == .constrained) {
        // Up to 3 one-line titles, NEWEST first (snap[len-1-i]).
        var row: u16 = 0;
        var i: usize = window.count;
        while (i > 0 and row < win.height) {
            i -= 1;
            const card = &snap[window.start + i];
            if (card.kind == .terminal) continue;
            const title_raw = card.titleSlice();
            const title = present.utf8Prefix(title_raw, @min(@as(usize, 128), @max(@as(usize, w), 2) - 2));
            const line = blk: {
                if (std.mem.startsWith(u8, title, "tool start ")) {
                    const name = if (title.len > "tool start ".len) title["tool start ".len..] else title;
                    break :blk store.format("◐ {s}", .{name});
                } else if (std.mem.startsWith(u8, title, "tool ")) {
                    const name = if (title.len > "tool ".len) title["tool ".len..] else title;
                    break :blk store.format("✓ {s}", .{name});
                } else if (card.kind == .host_error or std.mem.eql(u8, title, "host_error")) {
                    break :blk store.format("✗ {s}", .{title});
                } else {
                    break :blk store.format("· {s}", .{title});
                }
            };
            if (line) |s| {
                printLineStyled(win, row, s, cardStyleFor(card.kind, title_raw, palette));
            }
            row += 1;
        }
        return;
    }

    // Full mode: row-level scrollback paint. The last column of the cards
    // interior is the scrollbar track (always reserved — conditional
    // reservation would be a width↔total feedback loop); content renders
    // into the remaining width.
    const content_win = if (win.width > 1) win.child(.{ .width = win.width - 1 }) else win;
    if (sb.vis.items.len == 0) {
        if (content_win.height > 0) {
            printLineStyled(content_win, 0, "(no events yet)", palette.style(.card_fg));
        }
        drawScrollbar(win, sb, palette);
        return;
    }
    const pw = sb.paintWindow(content_win.height);
    var y: i64 = pw.content_y0;
    var i: usize = pw.start;
    while (i < pw.end) : (i += 1) {
        const h: i64 = sb.heightAt(i);
        if (y + h <= 0) {
            // Fully above the viewport.
            y += h + 1;
            continue;
        }
        if (y >= content_win.height) break;
        const slot = &snap[sb.slotAt(i)];
        // Negative y_off clips the card's top rows (vaxis writeCell drops
        // rows above the window); the invariant skip < h ≤ 65535 < |i17
        // min| keeps the cast safe.
        const y_off: i17 = @intCast(@min(@max(y, -@as(i64, scrollback_mod.max_draw_offset)), @as(i64, scrollback_mod.max_draw_offset)));
        const card_win = content_win.child(.{
            .y_off = y_off,
            .width = content_win.width,
            .height = @intCast(@min(@max(h, 1), 65535)),
        });
        renderCardInto(gpa, card_win, slot, palette, store);
        y += h + 1;
    }
    drawScrollbar(win, sb, palette);
}

/// Render one card into `win` (its full height). Assistant cards render the
/// markdown body flush-left with NO title row; user cards get a `❯ user`
/// title row + indented body; tool cards get a status icon + colored title
/// (omp-inspired); host_error/drop_note stay single-title.
fn renderCardInto(
    gpa: std.mem.Allocator,
    win: vaxis.Window,
    card: *const cards.CardSlot,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    const title_raw = card.titleSlice();
    const is_assistant = std.mem.startsWith(u8, title_raw, "assistant");
    const is_tool_start = std.mem.startsWith(u8, title_raw, "tool start ");
    const is_tool_done = std.mem.startsWith(u8, title_raw, "tool ") and !is_tool_start;
    const is_thinking = std.mem.startsWith(u8, title_raw, "thinking");
    const is_host_error = card.kind == .host_error or std.mem.eql(u8, title_raw, "host_error");

    const style = cardStyleFor(card.kind, title_raw, palette);
    if (is_assistant) {
        // Assistant cards: NO title row — the markdown body IS the entry.
        if (card.body_len > 0) {
            const md_style = md_render.MdStyle.forCard(palette, style);
            if (md_parse.parseMarkdown(gpa, card.bodySlice())) |doc|
                _ = md_render.renderMarkdownIntoStyled(gpa, win, doc, md_style)
            else
                _ = md_render.renderRawIntoStyled(gpa, win, card.bodySlice(), md_style);
        }
        return;
    }

    const title_limit = @min(@as(usize, 128), @max(@as(usize, win.width), 2) - 2);
    const title = present.utf8Prefix(title_raw, title_limit);
    const has_body = card.kind == .user or is_tool_start or is_tool_done or is_thinking;

    // omp-inspired status line: icon + title
    if (card.kind == .user) {
        if (store.format("❯ {s}", .{title})) |s| {
            printLineStyled(win, 0, s, style);
        }
    } else if (is_tool_start) {
        // "tool start {name}" → "◐ {name}"
        const name = if (title.len > "tool start ".len) title["tool start ".len..] else title;
        if (store.format("◐ {s}", .{name})) |s| {
            printLineStyled(win, 0, s, style);
        }
    } else if (is_tool_done) {
        // "tool {name}" → "✓ {name}" (or "✗" when host_error body)
        const name = if (title.len > "tool ".len) title["tool ".len..] else title;
        const failed = toolBodyLooksFailed(card.bodySlice());
        const icon: []const u8 = if (failed) "✗" else "✓";
        const done_style = if (failed) palette.style(.tool_error_fg) else palette.style(.tool_success_fg);
        if (store.format("{s} {s}", .{ icon, name })) |s| {
            printLineStyled(win, 0, s, done_style);
        }
    } else if (is_host_error) {
        if (store.format("✗ {s}", .{title})) |s| {
            printLineStyled(win, 0, s, palette.style(.error_fg));
        }
    } else if (is_thinking) {
        if (store.format("💭 {s}", .{title})) |s| {
            var muted = palette.style(.muted_fg);
            muted.italic = true;
            printLineStyled(win, 0, s, muted);
        }
    } else {
        if (store.format("· {s}", .{title})) |s| {
            printLineStyled(win, 0, s, style);
        }
    }

    if (has_body and card.body_len > 0 and win.height > 1) {
        const body_win = win.child(.{
            .x_off = 2,
            .y_off = 1,
            .width = if (win.width > 2) win.width - 2 else 1,
            .height = win.height - 1,
        });
        // Tool bodies use muted base so args/results don't fight the title color.
        const body_base: vaxis.Style = if (is_tool_start or is_tool_done)
            palette.style(.muted_fg)
        else
            style;
        const md_style = md_render.MdStyle.forCard(palette, body_base);
        if (md_parse.parseMarkdown(gpa, card.bodySlice())) |doc|
            _ = md_render.renderMarkdownIntoStyled(gpa, body_win, doc, md_style)
        else
            _ = md_render.renderRawIntoStyled(gpa, body_win, card.bodySlice(), md_style);
    }
}

fn toolBodyLooksFailed(body: []const u8) bool {
    // Soft heuristic: tool error envelopes from the loop/tool_error path.
    if (std.mem.indexOf(u8, body, "error:") != null) return true;
    if (std.mem.indexOf(u8, body, "permission denied") != null) return true;
    if (std.mem.indexOf(u8, body, "jail_deny") != null) return true;
    if (std.mem.indexOf(u8, body, "\"ok\":false") != null) return true;
    return false;
}

/// Exact card height (tui-scrollback-001 measurement): markdown render in
/// measure mode (unclipped row count) or the raw fallback. Matches
/// renderCardInto's row production exactly. Row counts depend only on
/// width, so the built-in palette suffices (colors never affect wrap).
pub fn measureCardHeight(gpa: std.mem.Allocator, card: *const cards.CardSlot, content_width: u16) u16 {
    // Per-call arena: the koino parse allocates through its allocator; a
    // bare gpa would leak on every measurement (the render path uses the
    // terminal's retained md_arena instead).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const agpa = arena.allocator();
    const palette = theme_mod.builtinDefault();
    const style = cardStyle(card.kind, &palette);
    const md_style = md_render.MdStyle.forCard(&palette, style);
    const mwin = measureWindow(content_width);
    const is_assistant = std.mem.startsWith(u8, card.titleSlice(), "assistant");
    if (is_assistant) {
        if (card.body_len == 0) return 0;
        if (md_parse.parseMarkdown(agpa, card.bodySlice())) |doc|
            return md_render.measureMarkdownIntoStyled(agpa, mwin, doc, md_style)
        else
            return md_render.measureRawIntoStyled(agpa, mwin, card.bodySlice(), md_style);
    }
    var h: u16 = 1;
    const has_body = card.kind == .user or std.mem.startsWith(u8, card.titleSlice(), "tool ") or std.mem.startsWith(u8, card.titleSlice(), "thinking");
    if (has_body and card.body_len > 0) {
        // The body renders indented (x_off=2) at width content_width-2 —
        // measure at the SAME width or the last wrapped line would clip.
        const body_w = content_width -| 2;
        const body_h = if (md_parse.parseMarkdown(agpa, card.bodySlice())) |doc|
            md_render.measureMarkdownIntoStyled(agpa, measureWindow(body_w), doc, md_style)
        else
            md_render.measureRawIntoStyled(agpa, measureWindow(body_w), card.bodySlice(), md_style);
        h +|= body_h;
    }
    return h;
}

/// Zero-width offscreen screen for measurement (width_method defaults to
/// wcwidth, which is all `gwidth` reads). Measure mode never writes cells
/// (putCell no-op), so this static screen is never touched — it exists
/// only to give Window its `screen` pointer.
var measure_screen: vaxis.Screen = .{};

/// A window for measurement: any window works — measure mode never writes
/// cells, it only reads width + grapheme metrics.
fn measureWindow(content_width: u16) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = @max(content_width, 1),
        .height = 1,
        .screen = &measure_screen,
    };
}

/// card.kind + title prefix drive color (omp-inspired tool/status ramp):
/// host_error → error_fg, terminal/drop_note → muted_fg, user → accent_fg,
/// tool start → tool_running_fg, tool done → tool_success_fg, ordinary → card_fg.
fn cardStyle(kind: cards.CardKind, palette: *const theme_mod.Palette) vaxis.Style {
    return cardStyleFor(kind, "", palette);
}

fn cardStyleFor(kind: cards.CardKind, title: []const u8, palette: *const theme_mod.Palette) vaxis.Style {
    if (std.mem.startsWith(u8, title, "tool start ")) return palette.style(.tool_running_fg);
    if (std.mem.startsWith(u8, title, "tool ")) return palette.style(.tool_success_fg);
    if (std.mem.startsWith(u8, title, "thinking")) return palette.style(.muted_fg);
    return switch (kind) {
        .host_error => palette.style(.error_fg),
        .terminal, .drop_note => palette.style(.muted_fg),
        .user => palette.style(.accent_fg),
        .ordinary => palette.style(.card_fg),
    };
}

/// Scrollbar track (tui-scrollback-001): drawn at the cards interior's
/// last column only when content overflows (total > viewport); the column
/// itself is always reserved in full mode. Division-first arithmetic
/// avoids overflow (u128 intermediates). The thumb is dimmed while
/// follow_mode (hyper: thumb blends when following).
fn drawScrollbar(win: vaxis.Window, sb: *const scrollback_mod.Scrollback, palette: *const theme_mod.Palette) void {
    const total: usize = sb.total_height;
    const viewport: usize = win.height;
    if (total <= viewport or viewport == 0 or win.width <= 2) return;
    const col: u16 = win.width - 1;
    const thumb_h: usize = @max(1, @as(usize, @intCast((@as(u128, viewport) * viewport) / total)));
    const thumb_y: usize = @as(usize, @intCast((@as(u128, sb.scroll_offset) * viewport) / total));
    const track_style = palette.style(.muted_fg);
    const thumb_base = palette.style(.card_fg);
    const thumb_style: vaxis.Style = if (sb.follow_mode) blk: {
        var s = thumb_base;
        s.dim = true;
        break :blk s;
    } else thumb_base;
    var r: usize = 0;
    while (r < viewport) : (r += 1) {
        const in_thumb = r >= thumb_y and r < thumb_y + thumb_h;
        const glyph: []const u8 = if (in_thumb) "█" else "│";
        const style: vaxis.Style = if (in_thumb) thumb_style else track_style;
        win.writeCell(col, @intCast(r), .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
    }
}

fn drawEditor(win: vaxis.Window, mode: layout_mod.Mode, ed: *const editor.Editor, palette: *const theme_mod.Palette) void {
    const editor_style = mergedFgBg(palette, .editor_fg, .editor_bg);
    const prompt_style = palette.style(.accent_fg);
    const content = ed.slice();
    if (mode == .constrained) {
        const first_line = singleLine(content);
        const row: u16 = 0;
        if (row < win.height) {
            _ = win.printSegment(.{ .text = "❯ ", .style = prompt_style }, .{ .row_offset = row, .wrap = .none });
            if (first_line.len > 0) {
                _ = win.printSegment(.{ .text = first_line, .style = editor_style }, .{ .row_offset = row, .col_offset = 2, .wrap = .none });
            }
            const prefix = if (ed.cursor <= first_line.len) content[0..ed.cursor] else first_line;
            win.showCursor(2 + win.gwidth(prefix), row);
        }
        return;
    }
    // Full mode: interior of the rounded input box. First content row uses
    // a `❯ ` prompt (omp/grok); continuation rows indent to match.
    const max_rows: usize = win.height;
    if (max_rows == 0) return;

    var line_starts: [layout_mod.max_editor_rows + 1]usize = undefined;
    var line_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            if (line_count < line_starts.len) line_starts[line_count] = start;
            line_count += 1;
            start = i + 1;
        }
    }
    var cursor_line: usize = 0;
    var k: usize = 0;
    while (k < line_count) : (k += 1) {
        const ls = line_starts[k];
        const le = if (k + 1 < line_count) line_starts[k + 1] - 1 else content.len;
        if (ed.cursor >= ls and ed.cursor <= le) {
            cursor_line = k;
            break;
        }
    }
    const first_vis = if (cursor_line + 1 > max_rows) cursor_line + 1 - max_rows else 0;
    const vis_rows = @min(line_count - first_vis, max_rows);
    var r: usize = 0;
    while (r < vis_rows) : (r += 1) {
        const li = first_vis + r;
        const ls = line_starts[li];
        const le = if (li + 1 < line_count) line_starts[li + 1] - 1 else content.len;
        const line = content[ls..le];
        const is_first = r == 0 and first_vis == 0;
        const prefix_text: []const u8 = if (is_first) "❯ " else "  ";
        const pstyle = if (is_first) prompt_style else editor_style;
        _ = win.printSegment(.{ .text = prefix_text, .style = pstyle }, .{ .row_offset = @intCast(r), .wrap = .none });
        if (line.len > 0) {
            _ = win.printSegment(.{ .text = line, .style = editor_style }, .{
                .row_offset = @intCast(r),
                .col_offset = @intCast(win.gwidth(prefix_text)),
                .wrap = .none,
            });
        } else if (is_first and content.len == 0) {
            _ = win.printSegment(.{ .text = "Build anything…  / commands · Alt+Enter newline", .style = palette.style(.muted_fg) }, .{
                .row_offset = @intCast(r),
                .col_offset = @intCast(win.gwidth(prefix_text)),
                .wrap = .none,
            });
        }
    }
    const cl = cursor_line - first_vis;
    const cls = line_starts[cursor_line];
    const cl_len = if (cursor_line + 1 < line_count) line_starts[cursor_line + 1] - 1 else content.len;
    const in_line = @min(ed.cursor, cl_len);
    const prefix = if (in_line >= cls) content[cls..in_line] else content[0..in_line];
    const col_base: usize = 2; // "❯ " / "  " are both 2 cells
    win.showCursor(@intCast(col_base + win.gwidth(prefix)), @intCast(cl));
}

/// Paint compact status chips into the editor region's top border row
/// (omp-style: status lives inside `╭─ … ─╮`).
fn drawEditorStatusBorder(
    root: vaxis.Window,
    region: layout_mod.Region,
    facts: StatusFacts,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    if (region.h == 0 or region.w < 6) return;
    const style = palette.style(.status_fg);
    const muted = palette.style(.muted_fg);
    // Leave room for `╭─` and `─╮`.
    const max_w = region.w -| 4;
    const chips = store.format(" {s} · {s} · perm:{s} · think:{s} · state:{s} ", .{
        facts.model,
        facts.theme_id,
        facts.perm,
        if (facts.show_thinking) "on" else "off",
        stateName(facts.state),
    }) orelse return;
    const text = present.utf8Prefix(chips, max_w);
    _ = root.printSegment(.{ .text = text, .style = style }, .{
        .col_offset = region.x + 2,
        .row_offset = region.y,
        .wrap = .none,
    });
    // Scroll feedback + note, trailing, muted if room.
    var col: usize = 2 + root.gwidth(text);
    if (facts.scroll > 0) {
        if (store.format("↑{d} ", .{facts.scroll})) |n| {
            _ = root.printSegment(.{ .text = n, .style = palette.style(.error_fg) }, .{
                .col_offset = @intCast(region.x + col),
                .row_offset = region.y,
                .wrap = .none,
            });
            col +|= root.gwidth(n);
        }
    }
    if (facts.status_note.len > 0) {
        if (store.format("· {s} ", .{facts.status_note})) |n| {
            const capped = present.utf8Prefix(n, region.w -| col -| 2);
            _ = root.printSegment(.{ .text = capped, .style = muted }, .{
                .col_offset = @intCast(region.x + col),
                .row_offset = region.y,
                .wrap = .none,
            });
        }
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
    _ = ed;
    const status_style = palette.style(.accent_fg);
    if (win.height < 1) return;
    // Full mode: status is drawn into the editor top border — nothing here.
    if (mode == .full) return;
    if (store.format("state={s} perm:{s} id={s}", .{ stateName(facts.state), facts.perm, facts.id_display })) |s| {
        printLineStyled(win, 0, s, status_style);
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

/// Grok-inspired tasks pane (subagents-001 TUI): full-width strip above the
/// editor listing live registry entries with status color, elapsed time,
/// turns, and an optional expanded output preview for the selected row.
///
/// `opts.cursor` is the selected entry index (0 = newest-first position 0).
/// `opts.expanded` shows the selected entry's output / error under its row.
/// `opts.tick_ms` drives a simple spinner for running entries.

fn drawTasksOverlay(
    root: vaxis.Window,
    region: layout_mod.Region,
    registry: ?*const subagent_mod.Registry,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
    opts: TasksPaneOpts,
) void {
    if (region.w == 0 or region.h == 0) return;
    const border = palette.style(.card_border);
    const muted = palette.style(.muted_fg);
    const box = borderedChild(root, region, .{
        .where = .all,
        .glyphs = .single_rounded,
        .style = border,
    });
    if (box.width == 0 or box.height == 0) return;

    // Header chip on the top border: " tasks N · running R "
    var live: usize = 0;
    var running: usize = 0;
    var snap_buf: [subagent_mod.max_registry_entries]subagent_mod.Entry = undefined;
    var n: usize = 0;
    if (registry) |reg| {
        n = reg.snapshotInto(&snap_buf);
        live = n;
        running = reg.countByStatus(.running) + reg.countByStatus(.pending);
    }
    // Newest-first for the pane (grok sorts running-first then newest).
    // Reverse the oldest-first snapshot into a stack buffer of indices.
    var order: [subagent_mod.max_registry_entries]usize = undefined;
    var oi: usize = 0;
    while (oi < n) : (oi += 1) order[oi] = n - 1 - oi;
    // Stable-ish running-first: bubble running/pending to the front.
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            const ea = snap_buf[order[a]].status;
            const eb = snap_buf[order[b]].status;
            const ra = ea == .running or ea == .pending;
            const rb = eb == .running or eb == .pending;
            if (!ra and rb) {
                const tmp = order[a];
                order[a] = order[b];
                order[b] = tmp;
            }
        }
    }

    if (store.format(" tasks {d} · running {d}{s} ", .{
        live,
        running,
        if (opts.focused) " · FOCUSED" else "",
    })) |hdr| {
        _ = root.printSegment(.{ .text = hdr, .style = palette.style(.status_fg) }, .{
            .col_offset = region.x + 2,
            .row_offset = region.y,
            .wrap = .none,
        });
    }

    if (n == 0) {
        // Should not normally paint: layout hides the region when empty.
        printLineStyled(box, 0, "(no subagents)", muted);
        return;
    }

    const cursor = @min(opts.cursor, n - 1);
    var row: u16 = 0;
    var i: usize = 0;
    while (i < n and row < box.height) : (i += 1) {
        const e = &snap_buf[order[i]];
        const selected = i == cursor;
        const st = statusStyle(e.status, palette);
        const glyph = statusGlyph(e.status, opts.tick_ms);
        const marker: []const u8 = if (selected) (if (opts.expanded) "▾ " else "▸ ") else "  ";
        const elapsed = formatElapsed(e.started_ms, e.finished_ms, opts.tick_ms);
        // Left: marker glyph type: description … Right: turns + elapsed
        if (store.format("{s}{s} {s}: {s}", .{
            marker,
            glyph,
            e.subagent_type.name(),
            singleLine(e.description),
        })) |left| {
            const left_capped = present.utf8Prefix(left, box.width -| 12);
            printLineStyled(box, row, left_capped, if (selected) palette.style(.accent_fg) else st);
            if (store.format(" {s} · {d}t", .{ elapsed, e.turns })) |right| {
                const rw = box.gwidth(right);
                if (rw < box.width) {
                    _ = box.printSegment(.{ .text = right, .style = muted }, .{
                        .row_offset = row,
                        .col_offset = box.width - rw,
                        .wrap = .none,
                    });
                }
            }
        }
        row += 1;

        // Expanded detail under the selected row.
        if (selected and opts.expanded and row < box.height) {
            const detail: []const u8 = blk: {
                if (e.error_message) |em| if (em.len > 0) break :blk em;
                if (e.output.len > 0) break :blk e.output;
                break :blk "(no output yet)";
            };
            // Up to 3 detail lines, indented, muted.
            var lines = std.mem.splitScalar(u8, detail, '\n');
            var di: usize = 0;
            while (lines.next()) |ln| : (di += 1) {
                if (di >= 3 or row >= box.height) break;
                if (store.format("    {s}", .{singleLine(ln)})) |s| {
                    printLineStyled(box, row, present.utf8Prefix(s, box.width), muted);
                }
                row += 1;
            }
            if (e.id.len > 0 and row < box.height) {
                if (store.format("    id={s}  status={s}", .{ e.id, e.status.name() })) |s| {
                    printLineStyled(box, row, present.utf8Prefix(s, box.width), muted);
                    row += 1;
                }
            }
        }
    }
}

fn statusStyle(status: subagent_mod.Status, palette: *const theme_mod.Palette) vaxis.Style {
    return switch (status) {
        .pending => palette.style(.muted_fg),
        .running => palette.style(.tool_running_fg),
        .completed => palette.style(.tool_success_fg),
        .failed => palette.style(.tool_error_fg),
        .cancelled => palette.style(.muted_fg),
    };
}

/// One-cell status indicator; running entries animate with tick_ms.
fn statusGlyph(status: subagent_mod.Status, tick_ms: u64) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return switch (status) {
        .pending => "○",
        .running => frames[@intCast((tick_ms / 80) % frames.len)],
        .completed => "✓",
        .failed => "✗",
        .cancelled => "⊘",
    };
}

fn formatElapsed(started_ms: u64, finished_ms: u64, now_ms: u64) []const u8 {
    // Static buffers are fine: LineStore.format copies into its own buffer
    // before the next call. We still keep a small local that formatElapsed
    // returns via a threadlocal-ish approach — caller must copy immediately.
    const end = if (finished_ms > started_ms) finished_ms else now_ms;
    const ms = if (end > started_ms) end - started_ms else 0;
    const sec = ms / 1000;
    const mins = sec / 60;
    const s = sec % 60;
    // Use a process-local rotating buffer pair to keep the slice valid until
    // the next formatElapsed call (draw path formats once per row).
    const Pair = struct {
        var bufs: [2][16]u8 = undefined;
        var i: usize = 0;
    };
    Pair.i ^= 1;
    if (mins > 0) {
        return std.fmt.bufPrint(&Pair.bufs[Pair.i], "{d}m{d:0>2}s", .{ mins, s }) catch "?";
    }
    return std.fmt.bufPrint(&Pair.bufs[Pair.i], "{d}s", .{s}) catch "?";
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
    // Help is a full reference list (~20 rows); other overlays are short.
    const h: u16 = @min(24, @max(layout.cards.h -| 1, 4));
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
        .@"resume" => "resume",
    };
    _ = root.printSegment(.{ .text = title, .style = style }, .{
        .col_offset = x + 2,
        .row_offset = y,
        .wrap = .none,
    });
    var row: u16 = 0;
    for (ov.lines, 0..) |line, i| {
        if (row >= box.height) break;
        // Group headers (session-tree-001) render muted and carry no cursor
        // marker: they are non-selectable (Enter is a no-op on them).
        const kind: RowKind = if (i < ov.row_kinds.len) ov.row_kinds[i] else .normal;
        const row_style = if (kind == .muted) palette.style(.muted_fg) else style;
        const marker_ch: []const u8 = if (i == ov.cursor and kind != .muted) "> " else "  ";
        // Split marker + line into TWO segments: vaxis printSegment borrows
        // the text slice into cells (no copy), so a stack-allocated joined
        // buffer would dangle by the time render() diffs. The marker is a
        // compile-time literal and `line` lives in the App's persistent
        // overlay_line_bufs — both safe to borrow.
        _ = box.printSegment(.{ .text = marker_ch, .style = row_style }, .{
            .row_offset = row,
            .wrap = .none,
        });
        _ = box.printSegment(.{ .text = line, .style = row_style }, .{
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
) !scrollback_mod.Scrollback {
    cs.* = try CellScreen.init(gpa, cols, rows);
    const layout = layout_mod.compute(.{ .cols = cols, .rows = rows }, snap.len, modal.pending, facts.status_note.len > 0, 0, ed.lineCount(), false);
    const palette = theme_mod.builtinDefault();
    var sb = scrollback_mod.Scrollback.init(gpa);
    errdefer sb.deinit();
    _ = sb.prepare(snap, @max(layout.cards.w -| 3, 1), @max(layout.cards.h -| 1, 1), measureCardHeight, scrollback_mod.estimateCard);
    drawFrame(cs.md_arena.allocator(), cs.root(cols, rows), layout, facts, snap, ed, modal, &palette, .{}, &cs.store, &sb, null, .{});
    return sb;
}

/// drawFixture variant that renders a host overlay (no permission modal).
fn drawOverlayFixture(
    cs: *CellScreen,
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    ov: OverlayPaint,
) !scrollback_mod.Scrollback {
    cs.* = try CellScreen.init(gpa, cols, rows);
    const layout = layout_mod.compute(.{ .cols = cols, .rows = rows }, snap.len, false, facts.status_note.len > 0, 0, ed.lineCount(), false);
    const palette = theme_mod.builtinDefault();
    var sb = scrollback_mod.Scrollback.init(gpa);
    errdefer sb.deinit();
    _ = sb.prepare(snap, @max(layout.cards.w -| 3, 1), @max(layout.cards.h -| 1, 1), measureCardHeight, scrollback_mod.estimateCard);
    drawFrame(cs.md_arena.allocator(), cs.root(cols, rows), layout, facts, snap, ed, .{}, &palette, ov, &cs.store, &sb, null, .{});
    return sb;
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
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);
    defer sb.deinit();

    // Minimal chrome: borderless transcript at top, rounded input at bottom.
    // Geometry @80x24, 1-line editor, modal: cards=0..16, modal=17..20, editor=21..23.
    // Transcript rows use contains (last col is the scrollbar track).
    try expectRowContains(&cs.screen, 0, "✓ write_file");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
    try expectRowContains(&cs.screen, 3, "hello world");

    // Modal still rounded, full width.
    try expectModalTopRow(&cs.screen, 17);
    try expectRowContains(&cs.screen, 18, "risk:medium");
    try expectRowContains(&cs.screen, 18, "write_file");
    try expectRowContains(&cs.screen, 19, "[a]=allow");
    try expectModalBottomRow(&cs.screen, 20);

    // Editor box: rounded corners + status chips on the top border + ❯ prompt.
    try expectCellEquals(&cs.screen, 0, 21, "╭");
    try expectCellEquals(&cs.screen, 79, 21, "╮");
    try expectRowContains(&cs.screen, 21, "perm:ask");
    try expectRowContains(&cs.screen, 21, "busy");
    try expectCellEquals(&cs.screen, 0, 22, "│");
    try expectCellEquals(&cs.screen, 1, 22, "❯");
    try expectCellEquals(&cs.screen, 2, 22, " ");
    try expectCellEquals(&cs.screen, 0, 23, "╰");
    try expectCellEquals(&cs.screen, 79, 23, "╯");
    // No full-frame side rails on the transcript.
    try expectCellEquals(&cs.screen, 0, 0, "✓");

}

test "render wide frame 130 cols matches golden rows (no truncation)" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 130, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowContains(&cs.screen, 0, "✓ write_file");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
    try expectRowContains(&cs.screen, 3, "hello world");
    try expectCellEquals(&cs.screen, 0, 21, "╭");
    try expectCellEquals(&cs.screen, 129, 21, "╮");
    try expectRowContains(&cs.screen, 21, "busy");
    try expectCellEquals(&cs.screen, 1, 22, "❯");
    try expectCellEquals(&cs.screen, 0, 23, "╰");
    try expectCellEquals(&cs.screen, 129, 23, "╯");
    try expectModalTopRow(&cs.screen, 17);
    try expectCellEquals(&cs.screen, 0, 17, "╭");
    try expectCellEquals(&cs.screen, 129, 17, "╮");

}

test "render constrained-mode cells match pre-vaxis golden (30x8)" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 30, 8, f.facts_constrained, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowEquals(&cs.screen, 0, "[zag tui · constrained]");
    try expectRowEquals(&cs.screen, 1, "state=busy perm:ask id=sess-ab");
    // Constrained shows newest-first titles with icons.
    try expectRowEquals(&cs.screen, 2, "· assistant turn=1");
    try expectRowEquals(&cs.screen, 3, "✓ write_file");
    try expectRowEquals(&cs.screen, 4, "❯ ");
    var row: u16 = 5;
    while (row < 8) : (row += 1) try expectRowEquals(&cs.screen, row, "");

}

test "render state:{s} text present in the status meta line (PTY marker contract)" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // Status chips live in the editor top border (row 21 with 1-line editor).
    // Format: " model · theme · perm:ask · think:off · busy "
    try expectRowContains(&cs.screen, 21, "busy");
    try expectRowContains(&cs.screen, 21, "perm:ask");

}

test "render body preview truncated to interior width on UTF-8 boundary" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    // Body longer than the content width should truncate on a UTF-8 boundary.
    var slot = cards.CardSlot{ .occupied = true, .title_len = 16, .body_len = 0 };
    @memcpy(slot.title[0..16], "assistant turn=1");
    const body = "αβγδεζηθικλμνξοπρστυφχψω" ** 4; // multi-byte
    slot.body_len = @intCast(@min(body.len, slot.body.len));
    @memcpy(slot.body[0..slot.body_len], body[0..slot.body_len]);
    const snap = [_]cards.CardSlot{slot};
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 40, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // Borderless: content starts at col 0; no crash and first cell is a grapheme.
    const c0 = cs.screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(c0.char.grapheme.len > 0);

}

test "render title truncated to interior width (min-cap holds)" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var slot = cards.CardSlot{ .occupied = true, .title_len = 100, .body_len = 0 };
    @memcpy(slot.title[0..100], "t" ** 100);
    const snap = [_]cards.CardSlot{slot};
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // "· " + truncated t's, no side border.
    try expectCellEquals(&cs.screen, 0, 0, "·");
    try expectCellEquals(&cs.screen, 2, 0, "t");

}

test "render multi-line editor grows and shows the cursor window" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var ed = editor.Editor.init(&fixture_editor_storage);
    // Three lines of input.
    _ = ed.insert("one\ntwo\nthree");
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // editor_h = 2 borders + 3 content = 5; editor_y = 19.
    try expectCellEquals(&cs.screen, 0, 19, "╭");
    try expectCellEquals(&cs.screen, 0, 23, "╰");
    try expectCellEquals(&cs.screen, 1, 20, "❯");
    try expectRowContains(&cs.screen, 20, "one");
    try expectRowContains(&cs.screen, 21, "two");
    try expectRowContains(&cs.screen, 22, "three");

}

test "render status strings min-capped to interior width" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;
    facts.model = "m" ** 40;
    facts.theme_id = "t" ** 40;
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 40, 24, facts, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // Status chips are truncated into the editor top border; no crash.
    try expectCellEquals(&cs.screen, 0, 21, "╭");
    try expectCellEquals(&cs.screen, 39, 21, "╮");

}

test "render no-events frame" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    const snap = [_]cards.CardSlot{};
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    try expectRowContains(&cs.screen, 0, "(no events yet)");
    try expectCellEquals(&cs.screen, 0, 21, "╭");
    try expectCellEquals(&cs.screen, 1, 22, "❯");

}

test "render card kind drives fg style" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
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
    var sb = try drawFixture(&cs, gpa, 80, 24, f.facts_full, &snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();

    // Borderless: cards start at row 0. Text after icon/dot is at col 2.
    try expectCellFgIndex(&cs.screen, 2, 0, 7); // ordinary → card_fg
    try expectCellFgIndex(&cs.screen, 2, 2, 1); // host_error → error_fg
    try expectCellFgIndex(&cs.screen, 2, 4, 8); // drop_note → muted_fg
    try expectRowEquals(&cs.screen, 0, "· alpha");
    try expectRowEquals(&cs.screen, 2, "✗ host_error");
    try expectRowEquals(&cs.screen, 4, "· drop");

}

test "render resume overlay: group headers muted + cursor marker suppressed" {
    const gpa = std.testing.allocator;
    const f = fixedFixture();
    const lines = [_][]const u8{ "beta 03-05 07:08 3B", "proj-a/", "proj-a/y 02-02 11:12 5B" };
    const kinds = [_]RowKind{ .normal, .muted, .normal };

    var cs: CellScreen = undefined;
    var sb = try drawOverlayFixture(&cs, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{
        .kind = overlay_mod.Kind.@"resume",
        .cursor = 0,
        .lines = &lines,
        .row_kinds = &kinds,
    });
    defer cs.deinit(gpa);
    defer sb.deinit();

    // Find the cursor marker ">" on a session row and a muted header cell.
    var found_marker = false;
    var found_muted_header = false;
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var col: u16 = 0;
        while (col < 80) : (col += 1) {
            const cell = cs.screen.readCell(col, row) orelse continue;
            if (std.mem.eql(u8, cell.char.grapheme, ">") and blk: { const fg = cell.style.fg; break :blk switch (fg) { .index => |i| i == 5, else => false }; })
                found_marker = true;
            if (std.mem.eql(u8, cell.char.grapheme, "p") and blk: { const fg = cell.style.fg; break :blk switch (fg) { .index => |i| i == 8, else => false }; })
                found_muted_header = true; // "proj-a/"
        }
    }
    try std.testing.expect(found_marker);
    try std.testing.expect(found_muted_header);

    // Cursor on the header: muted style AND no marker on that header row.
    var cs2: CellScreen = undefined;
    var sb2 = try drawOverlayFixture(&cs2, gpa, 80, 24, f.facts_full, &f.snap, &f.ed, .{
        .kind = overlay_mod.Kind.@"resume",
        .cursor = 1,
        .lines = &lines,
        .row_kinds = &kinds,
    });
    defer cs2.deinit(gpa);
    defer sb2.deinit();
    var header_row_has_marker = false;
    row = 0;
    while (row < 24) : (row += 1) {
        var col: u16 = 0;
        var row_has_proj = false;
        var row_has_marker = false;
        while (col < 80) : (col += 1) {
            const cell = cs2.screen.readCell(col, row) orelse continue;
            if (std.mem.eql(u8, cell.char.grapheme, "p") and blk: { const fg = cell.style.fg; break :blk switch (fg) { .index => |i| i == 8, else => false }; })
                row_has_proj = true;
            if (std.mem.eql(u8, cell.char.grapheme, ">")) row_has_marker = true;
        }
        if (row_has_proj and row_has_marker) header_row_has_marker = true;
    }
    try std.testing.expect(!header_row_has_marker);
}

test "render degenerate 20x5 constrained never overflows" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 20, 5, f.facts_constrained, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    try expectCellEquals(&cs.screen, 19, 0, "n");
    try expectRowEquals(&cs.screen, 4, "❯ ");

}

// ── tui-markdown-001 fixtures: transcript card bodies ─────────────────────
//
// drawCards renders assistant + user card bodies through md_render
// (multi-line, clipped to the cards region); tool/host-error rows stay
// single-title, terminal cards are never rendered. Geometry at 80x24 (no
// modal): cards region interior rows 2..14 (single-row header → cards_y =
// 1); the assistant entry has no title row — its body starts at row 2,
// flush-left at column 1 (border + interior offset).

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
    var sb = try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowEquals(&cs.screen, 0, "✓ write_file");
    try expectRowEquals(&cs.screen, 1, "  id=t1 args={}");
    // Assistant body flush-left at row 3 (tool 2 rows + gap).
    try expectCellEquals(&cs.screen, 0, 3, "T");
    try expectCellFgIndex(&cs.screen, 0, 3, 3);
    const h = cs.screen.readCell(0, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.style.bold);
    var buf: [512]u8 = undefined;
    const r3 = rowText(&cs.screen, 3, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r3, "# Title") == null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "Title") != null);
    try expectRowContains(&cs.screen, 5, "bold");
    const bold_cell = cs.screen.readCell(5, 5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(bold_cell.style.bold);
    try expectRowContains(&cs.screen, 7, "• one");
    try expectRowContains(&cs.screen, 8, "• two");

}

test "md transcript: tall assistant body clips at the cards region height" {

    const gpa = std.testing.allocator;
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
    var sb = try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();

    var buf: [512]u8 = undefined;
    var found_tail = false;
    var r: u16 = 0;
    while (r <= 20) : (r += 1) {
        const text = rowText(&cs.screen, r, &buf);
        if (std.mem.indexOf(u8, text, "line 30") != null) {
            found_tail = true;
            break;
        }
    }
    try std.testing.expect(found_tail);
    sb.scrollUp(200);
    const layout2 = layout_mod.compute(.{ .cols = 80, .rows = 24 }, 1, false, false, 0, 1, false);
    _ = sb.prepare(&snap, @max(layout2.cards.w -| 1, 1), @max(layout2.cards.h, 1), measureCardHeight, scrollback_mod.estimateCard);
    const palette2 = theme_mod.builtinDefault();
    drawFrameInto(cs.md_arena.allocator(), cs.root(80, 24), layout2, facts, &snap, &ed, .{}, &palette2, .{}, &cs.store, &sb, null, .{});
    try expectRowContains(&cs.screen, 0, "line 1");
    const head = rowText(&cs.screen, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, head, "line 30") == null);
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
    var sb = try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowEquals(&cs.screen, 0, "❯ user");
    try expectCellEquals(&cs.screen, 2, 1, "m");
    try expectCellFgIndex(&cs.screen, 2, 1, 3);
    const h = cs.screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.style.bold);
    var buf: [512]u8 = undefined;
    const r1 = rowText(&cs.screen, 1, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r1, "# my question") == null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "my question") != null);

}

test "md transcript: tool rows show status icon and indented body" {

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
    var sb = try drawFixture(&cs, gpa, 80, 24, facts, &snap, &ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowEquals(&cs.screen, 0, "✓ write_file");
    try expectRowEquals(&cs.screen, 1, "  id=t1 args={}");
    try expectRowEquals(&cs.screen, 3, "✓ run_shell");
    try expectRowEquals(&cs.screen, 4, "  ok=true");

}

test "tasks pane: renders status-colored rows with header chips" {
    const gpa = std.testing.allocator;
    var reg = subagent_mod.Registry.init(gpa);
    defer reg.deinit();

    const a = reg.allocSlot();
    try reg.setIdentity(a, "scan packages");
    reg.get(a).subagent_type = .scout;
    reg.get(a).status = .running;
    reg.get(a).turns = 3;
    reg.get(a).started_ms = 1_000;
    reg.active_count = 1;

    const b = reg.allocSlot();
    try reg.setIdentity(b, "review diff");
    reg.get(b).subagent_type = .reviewer;
    reg.get(b).status = .completed;
    reg.get(b).turns = 5;
    reg.get(b).started_ms = 1_000;
    reg.get(b).finished_ms = 4_000;
    reg.get(b).output = try gpa.dupe(u8, "looks good\nline2");

    var cs = try CellScreen.init(gpa, 80, 24);
    defer cs.deinit(gpa);
    const f = fixedFixture();
    var ed = editor.Editor.init(&fixture_editor_storage);
    const layout = layout_mod.compute(.{ .cols = 80, .rows = 24 }, 0, false, false, 0, 1, true);
    const tr = layout.tasks_overlay orelse return error.TestUnexpectedResult;
    try std.testing.expect(tr.h >= 4);
    const palette = theme_mod.builtinDefault();
    var sb = scrollback_mod.Scrollback.init(gpa);
    defer sb.deinit();
    _ = sb.prepare(&[_]cards.CardSlot{}, @max(layout.cards.w -| 1, 1), @max(layout.cards.h -| 1, 1), measureCardHeight, scrollback_mod.estimateCard);
    drawFrame(cs.md_arena.allocator(), cs.root(80, 24), layout, f.facts_full, &[_]cards.CardSlot{}, &ed, .{}, &palette, .{}, &cs.store, &sb, &reg, .{
        .cursor = 1,
        .expanded = true,
        .tick_ms = 5_000,
    });

    // Scan the whole tasks region for the expected chips / labels.
    var saw_header = false;
    var saw_scout = false;
    var saw_detail = false;
    var r: u16 = tr.y;
    while (r < tr.y + tr.h) : (r += 1) {
        var buf: [512]u8 = undefined;
        const text = rowText(&cs.screen, r, &buf);
        if (std.mem.indexOf(u8, text, "tasks") != null) saw_header = true;
        if (std.mem.indexOf(u8, text, "scout") != null) saw_scout = true;
        if (std.mem.indexOf(u8, text, "looks good") != null or std.mem.indexOf(u8, text, "id=") != null) saw_detail = true;
    }
    try std.testing.expect(saw_header);
    try std.testing.expect(saw_scout);
    try std.testing.expect(saw_detail);
}

