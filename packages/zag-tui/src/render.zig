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
    /// Live subagent count for status chips (0 = omit).
    running_tasks: u32 = 0,
    /// Monotonic ms for busy spinner animation.
    tick_ms: u64 = 0,
    /// Basename of the working directory (grok-style ambient chip), e.g.
    /// "zag". Empty = omit the chip.
    cwd_tail: []const u8 = "",
    /// Git branch from `.git/HEAD` (short sha when detached); empty = omit.
    git_branch: []const u8 = "",
    /// Total tokens of the last completed run (0 = omit the `[tok:…]` chip).
    last_tokens: u32 = 0,
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

/// Per-paint options for card fold/truncate (grok DisplayMode subset).
/// Set via `setCardPaintOpts` before `prepare`/`drawFrame` so measure + render
/// stay byte-identical without widening the measure fn pointer.
pub const CardPaintOpts = struct {
    /// Thinking cards: false = header only (default, grok collapsed/truncated).
    thinking_expanded: bool = false,
    /// Max body lines for tool cards (0 = unlimited). Grok truncated ≈ 6.
    tool_body_max_lines: u16 = 6,
    /// Collapse consecutive completed tool cards sharing a verb into
    /// header-only rows, keeping only the newest card's body (grok verb
    /// folding). Running `tool start` cards never join a group.
    tool_groups_collapsed: bool = true,
};

var card_paint_opts: CardPaintOpts = .{};

/// Snapshot backing the current paint (set via `setCardPaintSnap` before
/// measure + draw). Measure and render resolve tool-verb groups by index
/// into this slice; valid only during one prepare + draw pass.
var card_paint_snap: []const cards.CardSlot = &.{};

pub fn setCardPaintOpts(opts: CardPaintOpts) void {
    card_paint_opts = opts;
}

pub fn getCardPaintOpts() CardPaintOpts {
    return card_paint_opts;
}

/// Store the snapshot backing the current paint. Call alongside
/// `setCardPaintOpts` (before `prepare`/`drawFrame`) so measureCardHeight
/// and renderCardInto can resolve tool-verb groups by snap index.
pub fn setCardPaintSnap(snap: []const cards.CardSlot) void {
    card_paint_snap = snap;
}

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
            // Grok-inspired stack:
            //   cards → tasks → modal → turn_status → editor → shortcuts
            const border_style = palette.style(.card_border);
            const cards_win = childRegion(root, layout.cards);
            const editor_win = borderedChild(root, layout.editor, .{
                .where = .all,
                .glyphs = .single_rounded,
                .style = border_style,
            });

            drawCards(gpa, cards_win, layout.cards_window, layout.mode, snap, palette, store, sb);
            drawEditorStatusBorder(root, layout.editor, facts, palette, store);
            drawEditor(editor_win, layout.mode, ed, palette);
            drawTurnStatus(childRegion(root, layout.turn_status), facts, palette, store);
            drawShortcutsBar(childRegion(root, layout.shortcuts), facts, modal.pending, tasks_opts.focused, palette, store);

            if (layout.modal) |m| drawModal(root, m, modal, palette, store);
            if (layout.tasks_overlay) |tr| drawTasksOverlay(root, tr, subagents, palette, store, tasks_opts);
            if (ov.kind != .none and !modal.pending) drawHostOverlay(root, layout, ov, palette, store);
        },
    }
    // The paint snap is only valid during one measure+draw pass (its backing
    // buffer may be a test-local array); drop it so later direct measure
    // calls can never scan a dangling slice.
    card_paint_snap = &.{};
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
                    break :blk store.format("⠋ {s}", .{toolPrettyName(name)});
                } else if (std.mem.startsWith(u8, title, "tool ")) {
                    const name = if (title.len > "tool ".len) title["tool ".len..] else title;
                    const pretty = toolPrettyName(name);
                    if (card_paint_opts.tool_groups_collapsed) {
                        const g = toolGroupInfo(snap, window.start + i);
                        if (g.size > 1) {
                            if (store.format("✓ {s} ×{d}", .{ g.pretty, g.size })) |s2| break :blk s2;
                        }
                    }
                    break :blk store.format("✓ {s}", .{pretty});
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

    // Verb-group collapse (grok tool folding): older siblings of a consecutive
    // same-verb completed-tool run render header-only (their measured height
    // is 1, so the body window is absent anyway); the newest keeps its body
    // and gets a ×N count suffix on the title.
    var tool_group: ToolGroupInfo = .{};
    if (is_tool_done and card_paint_opts.tool_groups_collapsed) {
        if (snapIndexOf(card)) |idx| {
            const g = toolGroupInfo(card_paint_snap, idx);
            if (g.size > 1) tool_group = g;
        }
    }
    const grouped_header_only = tool_group.size > 1 and !tool_group.is_newest_in_group;

    // omp-inspired status line: icon + title
    if (card.kind == .user) {
        if (store.format("❯ {s}", .{title})) |s| {
            printLineStyled(win, 0, s, style);
        }
    } else if (is_tool_start) {
        // grok: "⠋ Read path/to/file" — verb + path/command preview from args.
        const name = if (title.len > "tool start ".len) title["tool start ".len..] else title;
        const pretty = toolPrettyName(name);
        const preview = toolBodyPreview(card.bodySlice());
        if (preview.len > 0) {
            if (store.format("⠋ {s}  {s}", .{ pretty, preview })) |s|
                printLineStyled(win, 0, present.utf8Prefix(s, win.width), style);
        } else if (store.format("⠋ {s}", .{pretty})) |s| {
            printLineStyled(win, 0, s, style);
        }
    } else if (is_tool_done) {
        // grok: "✓ Edit ×3 path  +n/-m" / "✓ Read path" — the ×N count
        // suffix appears only on the NEWEST card of a collapsed group.
        const name = if (title.len > "tool ".len) title["tool ".len..] else title;
        const pretty = toolPrettyName(name);
        const count_title: []const u8 = if (tool_group.size > 1 and tool_group.is_newest_in_group)
            (store.format("{s} ×{d}", .{ tool_group.pretty, tool_group.size }) orelse pretty)
        else
            pretty;
        const failed = toolBodyLooksFailed(card.bodySlice());
        const icon: []const u8 = if (failed) "✗" else "✓";
        const done_style = if (failed) palette.style(.tool_error_fg) else palette.style(.tool_success_fg);
        const preview = toolBodyPreview(card.bodySlice());
        const detail = toolResultDetail(card.bodySlice());
        const line = blk: {
            if (preview.len > 0 and detail.len > 0)
                break :blk store.format("{s} {s}  {s}  {s}", .{ icon, count_title, preview, detail });
            if (preview.len > 0)
                break :blk store.format("{s} {s}  {s}", .{ icon, count_title, preview });
            if (detail.len > 0)
                break :blk store.format("{s} {s}  {s}", .{ icon, count_title, detail });
            break :blk store.format("{s} {s}", .{ icon, count_title });
        };
        if (line) |s| printLineStyled(win, 0, present.utf8Prefix(s, win.width), done_style);
    } else if (is_host_error) {
        if (store.format("✗ {s}", .{title})) |s| {
            printLineStyled(win, 0, s, palette.style(.error_fg));
        }
    } else if (is_thinking) {
        // grok ThinkingBlock: collapsed header by default; Ctrl+E expands body.
        var muted = palette.style(.muted_fg);
        muted.italic = true;
        const progressive = std.mem.startsWith(u8, title_raw, "thinking progressive");
        const expanded = card_paint_opts.thinking_expanded;
        if (progressive) {
            if (expanded) {
                printLineStyled(win, 0, "Thinking…", muted);
            } else if (store.format("Thinking…  (ctrl+e to expand)", .{})) |s| {
                printLineStyled(win, 0, present.utf8Prefix(s, win.width), muted);
            }
        } else {
            if (expanded) {
                printLineStyled(win, 0, "Thought", muted);
            } else if (store.format("Thought  (ctrl+e to expand)", .{})) |s| {
                printLineStyled(win, 0, present.utf8Prefix(s, win.width), muted);
            }
        }
    } else {
        if (store.format("· {s}", .{title})) |s| {
            printLineStyled(win, 0, s, style);
        }
    }

    // Body: thinking collapsed → header only; tools truncated to N lines;
    // grouped non-newest tools → header only (height 1 from measure).
    const show_body = has_body and card.body_len > 0 and win.height > 1 and
        !(is_thinking and !card_paint_opts.thinking_expanded) and
        !grouped_header_only;
    if (show_body) {
        const body_win = win.child(.{
            .x_off = 2,
            .y_off = 1,
            .width = if (win.width > 2) win.width - 2 else 1,
            .height = win.height - 1,
        });
        const body_base: vaxis.Style = if (is_tool_start or is_tool_done)
            palette.style(.muted_fg)
        else if (is_thinking) blk: {
            var m = palette.style(.muted_fg);
            m.italic = true;
            break :blk m;
        } else style;

        if (is_tool_start or is_tool_done) {
            // Grok-style truncated tool body (no full markdown dump).
            drawToolBodyTruncated(body_win, card.bodySlice(), body_base, palette, store, card_paint_opts.tool_body_max_lines);
        } else {
            const md_style = md_render.MdStyle.forCard(palette, body_base);
            if (md_parse.parseMarkdown(gpa, card.bodySlice())) |doc|
                _ = md_render.renderMarkdownIntoStyled(gpa, body_win, doc, md_style)
            else
                _ = md_render.renderRawIntoStyled(gpa, body_win, card.bodySlice(), md_style);
        }
    }
}


/// Grok-style tool verb: bash→Bash, read_file→Read, edit_file→Edit, …
fn toolPrettyName(name: []const u8) []const u8 {
    // Common coding-agent tools (keep short for the title row).
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "run_shell")) return "Bash";
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "read_file")) return "Read";
    if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "edit_file") or std.mem.eql(u8, name, "apply_patch") or std.mem.eql(u8, name, "search_replace") or std.mem.eql(u8, name, "apply_hunk") or std.mem.eql(u8, name, "apply_transaction")) return "Edit";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "write_file")) return "Write";
    if (std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "search")) return "Search";
    if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "list_dir")) return "Glob";
    if (std.mem.eql(u8, name, "task") or std.mem.eql(u8, name, "Task")) return "Task";
    if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "TodoWrite")) return "Todo";
    if (name.len == 0) return name;
    return name;
}

/// Verb-group membership of one card in a snapshot (grok tool folding):
/// consecutive completed tool cards (`tool ` but not `tool start `) sharing
/// the same `toolPrettyName` form a group; the newest (highest index) keeps
/// its body, older siblings collapse to header-only rows.
const ToolGroupInfo = struct {
    /// Group size (1 = lone tool card; 0 = not a completed tool card).
    size: usize = 0,
    /// True when this card is the newest of its group (keeps its body).
    is_newest_in_group: bool = false,
    /// `toolPrettyName` of the shared verb ("" when not a tool card).
    pretty: []const u8 = "",
};

fn isToolDoneTitle(title: []const u8) bool {
    return std.mem.startsWith(u8, title, "tool ") and !std.mem.startsWith(u8, title, "tool start ");
}

fn toolNameOf(title: []const u8) []const u8 {
    return if (title.len > "tool ".len) title["tool ".len..] else title;
}

/// Group info for snap[index]: maximal consecutive run of completed tool
/// cards with the same pretty verb containing `index`. O(group size), called
/// per card per paint (bounded by the 125-slot ring).
fn toolGroupInfo(snap: []const cards.CardSlot, index: usize) ToolGroupInfo {
    if (index >= snap.len) return .{};
    if (!isToolDoneTitle(snap[index].titleSlice())) return .{};
    const pretty = toolPrettyName(toolNameOf(snap[index].titleSlice()));
    var start = index;
    while (start > 0 and
        isToolDoneTitle(snap[start - 1].titleSlice()) and
        std.mem.eql(u8, toolPrettyName(toolNameOf(snap[start - 1].titleSlice())), pretty)) : (start -= 1) {}
    var end = index;
    while (end + 1 < snap.len and
        isToolDoneTitle(snap[end + 1].titleSlice()) and
        std.mem.eql(u8, toolPrettyName(toolNameOf(snap[end + 1].titleSlice())), pretty)) : (end += 1) {}
    return .{
        .size = end - start + 1,
        .is_newest_in_group = (end == index),
        .pretty = pretty,
    };
}

/// Resolve a card's index in the current paint snapshot: ui_seq match (the
/// ring assigns a monotonic id per publish), falling back to slot-address
/// identity for hand-built test slots with ui_seq == 0.
fn snapIndexOf(card: *const cards.CardSlot) ?usize {
    for (card_paint_snap, 0..) |*s, i| {
        if (s.ui_seq != 0 and s.ui_seq == card.ui_seq) return i;
        if (@intFromPtr(s) == @intFromPtr(card)) return i;
    }
    return null;
}

/// Cheap per-paint signature of the tool-verb-group structure (which cards
/// collapse). The app compares consecutive paints: when it changes, cached
/// scrollback heights for unchanged ui_seqs are stale (a sibling's collapse
/// status changed), so the measure cache must be invalidated before prepare.
pub fn toolGroupSignature(snap: []const cards.CardSlot) u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    for (snap, 0..) |*s, i| {
        _ = s;
        const g = toolGroupInfo(snap, i);
        if (g.size == 0) continue;
        h = (h ^ (@as(u64, g.size) << 32 | @as(u64, @intFromBool(g.is_newest_in_group)))) *% 0x100000001b3;
    }
    return h;
}

/// First interesting token from a tool body for the title-row preview
/// (path, command head). Handles tool_start `args={json}` and tool_end envelopes.
fn toolBodyPreview(body: []const u8) []const u8 {
    if (body.len == 0) return "";
    // tool_start body: "id=… args={…}"
    if (std.mem.indexOf(u8, body, "args=")) |at| {
        const json = std.mem.trimStart(u8, body[at + 5 ..], " \t");
        if (jsonExtract(json, "path")) |p| return singleLine(p);
        if (jsonExtract(json, "file")) |p| return singleLine(p);
        if (jsonExtract(json, "command")) |p| return singleLine(p);
        if (jsonExtract(json, "pattern")) |p| return singleLine(p);
        if (jsonExtract(json, "query")) |p| return singleLine(p);
        if (jsonExtract(json, "target")) |p| return singleLine(p);
    }
    // Direct JSON body
    if (jsonExtract(body, "path")) |p| return singleLine(p);
    if (jsonExtract(body, "file")) |p| return singleLine(p);
    if (jsonExtract(body, "command")) |p| return singleLine(p);

    // tool_end envelopes from edit_tools / fs_tools
    // "ok: wrote N bytes to PATH"
    if (std.mem.indexOf(u8, body, " bytes to ")) |at| {
        const rest = body[at + " bytes to ".len ..];
        var end_i: usize = 0;
        while (end_i < rest.len and rest[end_i] != '\n' and rest[end_i] != ' ') : (end_i += 1) {}
        if (end_i > 0) return singleLine(rest[0..end_i]);
    }
    // "ok: search_replace path=PATH …"
    if (std.mem.indexOf(u8, body, "path=")) |at| {
        const rest = body[at + 5 ..];
        var end_i: usize = 0;
        while (end_i < rest.len and rest[end_i] != '\n' and rest[end_i] != ' ') : (end_i += 1) {}
        if (end_i > 0) return singleLine(rest[0..end_i]);
    }

    var line = body;
    if (std.mem.indexOfScalar(u8, body, '\n')) |nl| line = body[0..nl];
    line = std.mem.trim(u8, line, " \t\r");
    // Skip envelope-only first lines (ok: code=…)
    if (std.mem.startsWith(u8, line, "ok:") or std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "id=")) {
        return "";
    }
    // Diff bodies: skip the header lines (---/+++/@@) — the diff itself
    // paints in the body.
    if (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ") or std.mem.startsWith(u8, line, "@@")) {
        return "";
    }
    if (std.mem.startsWith(u8, line, "```")) {
        if (std.mem.indexOfScalar(u8, body, '\n')) |nl| {
            const rest = std.mem.trim(u8, body[nl + 1 ..], " \t\r\n");
            if (std.mem.indexOfScalar(u8, rest, '\n')) |n2| return singleLine(rest[0..n2]);
            return singleLine(rest);
        }
    }
    return singleLine(line);
}

/// Extract `"key":"value"` from a JSON-ish blob (best-effort, no full parse).
fn jsonExtract(blob: []const u8, key: []const u8) ?[]const u8 {
    var keybuf: [64]u8 = undefined;
    if (key.len + 4 > keybuf.len) return null;
    const pat = std.fmt.bufPrint(&keybuf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, blob, pat)) |at| {
        const rest = blob[at + pat.len ..];
        if (std.mem.indexOfScalar(u8, rest, '"')) |end| return rest[0..end];
    }
    return null;
}

/// Compact result suffix for the title row: "+3/-1", "exit 0", "16B", …
fn toolResultDetail(body: []const u8) []const u8 {
    if (body.len == 0) return "";
    // search_replace: removed=A inserted=B
    var removed: ?usize = null;
    var inserted: ?usize = null;
    if (std.mem.indexOf(u8, body, "removed=")) |at| {
        removed = parseLeadingUsize(body[at + 8 ..]);
    }
    if (std.mem.indexOf(u8, body, "inserted=")) |at| {
        inserted = parseLeadingUsize(body[at + 9 ..]);
    }
    if (removed != null or inserted != null) {
        const Pair = struct {
            var bufs: [2][24]u8 = undefined;
            var i: usize = 0;
        };
        Pair.i ^= 1;
        const r = removed orelse 0;
        const ins = inserted orelse 0;
        return std.fmt.bufPrint(&Pair.bufs[Pair.i], "+{d}/-{d}", .{ ins, r }) catch "";
    }
    // wrote N bytes
    if (std.mem.indexOf(u8, body, "wrote ")) |at| {
        if (parseLeadingUsize(body[at + 6 ..])) |n| {
            const Pair = struct {
                var bufs: [2][24]u8 = undefined;
                var i: usize = 0;
            };
            Pair.i ^= 1;
            if (n >= 1024)
                return std.fmt.bufPrint(&Pair.bufs[Pair.i], "{d}KB", .{n / 1024}) catch "";
            return std.fmt.bufPrint(&Pair.bufs[Pair.i], "{d}B", .{n}) catch "";
        }
    }
    // shell exit_code=N
    if (std.mem.indexOf(u8, body, "exit_code=")) |at| {
        if (parseLeadingUsize(body[at + 10 ..])) |code| {
            const Pair = struct {
                var bufs: [2][24]u8 = undefined;
                var i: usize = 0;
            };
            Pair.i ^= 1;
            return std.fmt.bufPrint(&Pair.bufs[Pair.i], "exit {d}", .{code}) catch "";
        }
    }
    return "";
}

fn parseLeadingUsize(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    return std.fmt.parseInt(usize, s[0..i], 10) catch null;
}

/// Per-line paint kind for tool bodies (grok tool-body polish): diff
/// `+`/`-` markers and bash stderr get status colors; diff context and bash
/// stdout stay on the base muted tool style.
const ToolLineKind = enum {
    plain,
    success,
    err,
    muted,
};

const ToolBodyMode = enum {
    /// Generic envelope / summary dump (ok:/error:/id= …), no sections.
    dump,
    /// Bash output with `--- stdout ---` / `--- stderr ---` sections.
    bash,
    /// Unified-diff-shaped body: color `+`/`-` lines, mute context.
    diff,
    /// File text: line-number gutter + plain content.
    file,
};

const ToolBodyLine = struct {
    text: []const u8,
    kind: ToolLineKind,
    /// 0-based source line number (gutter uses it; counts skipped lines too).
    line_no: usize,
};

/// Drives a tool body exactly as the truncated painter renders it. Both
/// measureToolBodyLines and drawToolBodyTruncated iterate this, so the
/// measured row count always equals the painted rows (leading-blank drop,
/// envelope skip, bash section selection, diff coloring all included; the
/// gutter only changes cell width, never the row count).
const ToolBodyScan = struct {
    body: []const u8,
    mode: ToolBodyMode,
    /// Skip the envelope first line (the title row already shows the path)
    /// when more content follows it.
    skip_envelope: bool,
    /// First paint-region byte offset (bash: right after the first section
    /// marker line; everything before it is the envelope + markers).
    start: usize = 0,
    in_stderr: bool = false,
    pos: usize = 0,
    line_no: usize = 0,
    /// Any non-blank line yielded yet (leading blanks drop).
    started: bool = false,

    fn init(body: []const u8) ToolBodyScan {
        const stdout_at = std.mem.indexOf(u8, body, "--- stdout ---");
        const stderr_at = std.mem.indexOf(u8, body, "--- stderr ---");
        if (stdout_at != null or stderr_at != null) {
            const first = if (stdout_at) |a| (if (stderr_at) |b| @min(a, b) else a) else stderr_at.?;
            var start = first + "--- stdout ---".len;
            while (start < body.len and body[start] != '\n') : (start += 1) {}
            if (start < body.len and body[start] == '\n') start += 1;
            return .{
                .body = body,
                .mode = .bash,
                .skip_envelope = false,
                .start = start,
                .in_stderr = (stderr_at != null) and (stdout_at == null or stderr_at.? < stdout_at.?),
            };
        }
        if (hasDiffMarkers(body)) {
            return .{
                .body = body,
                .mode = .diff,
                .skip_envelope = isEnvelopeLine(singleLine(body)) and
                    toolBodyPreview(body).len > 0 and hasMoreThanFirstLine(body),
            };
        }
        if (isEnvelopeLine(singleLine(body))) {
            return .{
                .body = body,
                .mode = .dump,
                .skip_envelope = toolBodyPreview(body).len > 0 and hasMoreThanFirstLine(body),
            };
        }
        return .{ .body = body, .mode = .file, .skip_envelope = false };
    }

    /// Next painted line, or null when exhausted — mirrors the painter.
    fn next(self: *ToolBodyScan) ?ToolBodyLine {
        while (self.pos < self.body.len) {
            var end = self.pos;
            while (end < self.body.len and self.body[end] != '\n') : (end += 1) {}
            const raw = self.body[self.pos..end];
            const line_no = self.line_no;
            self.line_no += 1;
            self.pos = if (end < self.body.len) end + 1 else end;

            if (self.mode == .bash) {
                // Skip everything up to and including the first section
                // marker; later marker lines flip stdout/stderr.
                if (self.pos <= self.start) {
                    if (std.mem.startsWith(u8, raw, "--- stderr ---")) self.in_stderr = true;
                    continue;
                }
                if (std.mem.startsWith(u8, raw, "--- stdout ---")) {
                    self.in_stderr = false;
                    continue;
                }
                if (std.mem.startsWith(u8, raw, "--- stderr ---")) {
                    self.in_stderr = true;
                    continue;
                }
                if (raw.len == 0 and !self.started) continue;
                self.started = true;
                return .{ .text = raw, .kind = if (self.in_stderr) .err else .plain, .line_no = line_no };
            }

            // Envelope skip: the title row already shows the path.
            if (self.skip_envelope and line_no == 0) continue;

            if (self.mode == .diff) {
                if (raw.len == 0 and !self.started) continue;
                self.started = true;
                const kind: ToolLineKind = if (std.mem.startsWith(u8, raw, "+") and !std.mem.startsWith(u8, raw, "+++"))
                    .success
                else if (std.mem.startsWith(u8, raw, "-") and !std.mem.startsWith(u8, raw, "---"))
                    .err
                else
                    .muted;
                return .{ .text = raw, .kind = kind, .line_no = line_no };
            }

            if (raw.len == 0 and !self.started) continue;
            self.started = true;
            return .{ .text = raw, .kind = .plain, .line_no = line_no };
        }
        return null;
    }
};

/// Body has at least one diff-marker line: `+`/`-` prefix that is not a
/// `+++`/`---` file header (git-diff style).
fn hasDiffMarkers(body: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        if (std.mem.startsWith(u8, raw, "+") and !std.mem.startsWith(u8, raw, "+++")) return true;
        if (std.mem.startsWith(u8, raw, "-") and !std.mem.startsWith(u8, raw, "---")) return true;
    }
    return false;
}

/// Pure tool-result envelope first line (`ok:`/`error:`/`id=` forms). Bodies
/// like this are summaries, not file text — no gutter, envelope-skip rules.
fn isEnvelopeLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "ok:") or std.mem.startsWith(u8, line, "ok=") or
        std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "error=") or
        std.mem.startsWith(u8, line, "id=");
}

/// True when the first line is followed by any non-blank content.
fn hasMoreThanFirstLine(body: []const u8) bool {
    const nl = std.mem.indexOfScalar(u8, body, '\n') orelse return false;
    var i = nl + 1;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\n') return true;
    }
    return false;
}

/// Gutter width: digits of the source line count, clamped to 3–4 cols.
fn gutterWidth(body: []const u8) u16 {
    const total = countBodyLines(body);
    var digits: u16 = 1;
    var n: usize = total;
    while (n >= 10) : (n /= 10) digits += 1;
    return @min(@max(digits, 3), 4);
}

/// Paint a truncated tool body (first N lines + "… +K lines" footer) with
/// grok-style polish: read/file-text bodies get a muted line-number gutter,
/// diff bodies color `+`/`-` markers, bash bodies show the stdout/stderr
/// sections with stderr in tool_error_fg.
fn drawToolBodyTruncated(
    win: vaxis.Window,
    body: []const u8,
    style: vaxis.Style,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
    max_lines: u16,
) void {
    if (win.height == 0 or win.width == 0 or body.len == 0) return;
    const scan_ctx = ToolBodyScan.init(body);
    // Count first so the "… +N lines" footer is exact; the body is ≤ 4096
    // bytes, so the second pass is cheap and keeps measure == paint.
    var visible: usize = 0;
    {
        var s = scan_ctx;
        while (s.next() != null) : (visible += 1) {}
    }
    if (visible == 0) return;
    const limit: usize = if (max_lines == 0) std.math.maxInt(usize) else max_lines;
    const shown = @min(visible, limit);
    const footer = visible > shown;
    const success_style = palette.style(.tool_success_fg);
    const error_style = palette.style(.tool_error_fg);
    const gutter_w: u16 = if (scan_ctx.mode == .file) gutterWidth(body) else 0;
    var s = scan_ctx;
    var row: u16 = 0;
    var painted: usize = 0;
    while (s.next()) |ln| {
        if (painted >= shown or row >= win.height) break;
        const line_style: vaxis.Style = switch (ln.kind) {
            .success => success_style,
            .err => error_style,
            else => style,
        };
        if (gutter_w > 0 and win.width > gutter_w + 1) {
            paintGutterLine(win, row, gutter_w, ln.line_no, ln.text, line_style, style, store);
        } else {
            printLineStyled(win, row, present.utf8Prefix(ln.text, win.width), line_style);
        }
        row += 1;
        painted += 1;
    }
    if (footer and row < win.height) {
        if (store.format("… +{d} lines", .{visible - shown})) |f| {
            var dim = style;
            dim.dim = true;
            printLineStyled(win, row, f, dim);
        }
    }
}

/// Paint one file-text line with a right-aligned muted line-number gutter.
/// vaxis borrows cell graphemes (no copy), so the number is formatted into
/// the LineStore — a stack buffer would dangle by render time. The gutter
/// consumes cells only; the row count is unchanged (measure lockstep).
fn paintGutterLine(
    win: vaxis.Window,
    row: u16,
    gutter_w: u16,
    line_no: usize,
    text: []const u8,
    content_style: vaxis.Style,
    muted: vaxis.Style,
    store: *terminal.LineStore,
) void {
    const num = store.format("{d}", .{line_no + 1}) orelse return;
    const num_w: u16 = @intCast(num.len);
    const pad = if (gutter_w > num_w) gutter_w - num_w else 0;
    const gut_w = gutter_w + 1; // gutter + separator space
    if (gut_w >= win.width) {
        printLineStyled(win, row, present.utf8Prefix(text, win.width), content_style);
        return;
    }
    const pad_strs = [_][]const u8{ "", " ", "  ", "   " };
    var col: u16 = 0;
    if (pad > 0) {
        _ = win.printSegment(.{ .text = pad_strs[@intCast(pad)], .style = muted }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
        col += pad;
    }
    _ = win.printSegment(.{ .text = num, .style = muted }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
    col += num_w;
    _ = win.printSegment(.{ .text = " ", .style = muted }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
    col += 1;
    if (col >= win.width) return;
    const content = present.utf8Prefix(text, win.width - col);
    if (content.len > 0) {
        _ = win.printSegment(.{ .text = content, .style = content_style }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
    }
}

fn countBodyLines(body: []const u8) usize {
    if (body.len == 0) return 0;
    var n: usize = 1;
    for (body) |b| {
        if (b == '\n') n += 1;
    }
    // Don't count a trailing bare newline as an extra visible line.
    if (body[body.len - 1] == '\n' and n > 0) n -= 1;
    return @max(n, 1);
}

/// Row count the truncated tool painter actually paints (post envelope /
/// section selection + leading-blank drop) plus the "… +N lines" footer.
/// Iterates the SAME ToolBodyScan as drawToolBodyTruncated, so measure and
/// render stay in lockstep (the gutter changes width, never the count).
fn measureToolBodyLines(body: []const u8, max_lines: u16) u16 {
    var s = ToolBodyScan.init(body);
    var visible: usize = 0;
    while (s.next() != null) : (visible += 1) {}
    if (visible == 0) return 0;
    const limit: usize = if (max_lines == 0) std.math.maxInt(usize) else max_lines;
    const shown = @min(visible, limit);
    const extra: usize = if (visible > shown) 1 else 0; // "… +N lines"
    return @intCast(@min(shown + extra, std.math.maxInt(u16)));
}

/// Grok turn-status strip: spinner + "Working…" / "Waiting on you" / error.
fn drawTurnStatus(
    win: vaxis.Window,
    facts: StatusFacts,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    if (win.height == 0 or win.width == 0) return;
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const spin = frames[@intCast((facts.tick_ms / 80) % frames.len)];
    var style = palette.style(.muted_fg);
    const text: []const u8 = switch (facts.state) {
        .busy => blk: {
            style = palette.style(.tool_running_fg);
            if (facts.running_tasks > 0) {
                break :blk store.format("{s} Working · {d} task{s}", .{
                    spin,
                    facts.running_tasks,
                    if (facts.running_tasks == 1) "" else "s",
                }) orelse "Working…";
            }
            break :blk store.format("{s} Working…", .{spin}) orelse "Working…";
        },
        .closing => "closing…",
        .@"error" => blk: {
            style = palette.style(.error_fg);
            break :blk "error — see transcript";
        },
        else => return, // idle/closed: region should be h=0
    };
    // Left accent bar + label (grok diamond/pulse simplified).
    _ = win.printSegment(.{ .text = "◆ ", .style = style }, .{ .row_offset = 0, .wrap = .none });
    _ = win.printSegment(.{ .text = present.utf8Prefix(text, win.width -| 2), .style = style }, .{
        .row_offset = 0,
        .col_offset = 2,
        .wrap = .none,
    });
}

/// Grok ShortcutsBar under the prompt: context-sensitive key hints.
fn drawShortcutsBar(
    win: vaxis.Window,
    facts: StatusFacts,
    modal_pending: bool,
    tasks_focused: bool,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
) void {
    if (win.height == 0 or win.width == 0) return;
    const muted = palette.style(.muted_fg);
    const key_st = palette.style(.accent_fg);
    const hints: []const u8 = if (modal_pending)
        "a allow  ·  d deny  ·  esc cancel  ·  ctrl+o auto"
    else if (tasks_focused)
        "j/k nav  ·  space expand  ·  esc back  ·  ctrl+k close"
    else if (facts.state == .busy)
        "esc note  ·  alt+s steer  ·  alt+f follow-up  ·  ctrl+e think  ·  F1 help"
    else if (facts.show_thinking)
        "enter send  ·  ctrl+e think  ·  ctrl+t hide  ·  ctrl+k tasks  ·  F1 help"
    else
        "enter send  ·  / commands  ·  ctrl+k tasks  ·  ctrl+o perm  ·  F1 help";

    // Paint key tokens in accent when simple "word word" pairs — keep whole
    // line muted for v1 simplicity (readable, low noise).
    _ = key_st;
    const line = store.format(" {s}", .{hints}) orelse hints;
    printLineStyled(win, 0, present.utf8Prefix(line, win.width), muted);
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
    const title = card.titleSlice();
    const is_tool = std.mem.startsWith(u8, title, "tool ");
    const is_thinking = std.mem.startsWith(u8, title, "thinking");
    const has_body = card.kind == .user or is_tool or is_thinking;
    if (has_body and card.body_len > 0) {
        // Thinking collapsed (default): header only — matches renderCardInto.
        if (is_thinking and !card_paint_opts.thinking_expanded) return 1;
        if (is_tool) {
            // Verb-group collapse (grok): older siblings of a same-verb
            // completed-tool run are header-only; the newest keeps its body.
            // `tool start` cards never join (toolGroupInfo returns size 0).
            if (card_paint_opts.tool_groups_collapsed and isToolDoneTitle(title)) {
                if (snapIndexOf(card)) |idx| {
                    const g = toolGroupInfo(card_paint_snap, idx);
                    if (g.size > 1 and !g.is_newest_in_group) return 1;
                }
            }
            // Truncated tool body (line-based, not md-wrap) + optional footer.
            h +|= measureToolBodyLines(card.bodySlice(), card_paint_opts.tool_body_max_lines);
            return h;
        }
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

/// Assemble the editor top-border status chips (grok-style ambient chips):
/// `model · theme · cwd · git · perm · think · tasks? · [tok] · state`.
/// Optional chips are dropped in priority order (git → cwd → tasks → tokens)
/// when the line exceeds `max_w` bytes so the mandatory contiguous
/// `perm:` / `think:` / `state:` markers stay visible; the final fallback
/// caps the core line with utf8Prefix. Returns a slice into `scratch`.
fn buildStatusChips(scratch: []u8, facts: StatusFacts, max_w: usize) []const u8 {
    var tok_buf: [24]u8 = undefined;
    var tasks_buf: [24]u8 = undefined;
    var perm_buf: [48]u8 = undefined;
    var think_buf: [48]u8 = undefined;
    var state_buf: [48]u8 = undefined;

    const perm_seg = std.fmt.bufPrint(&perm_buf, "perm:{s}", .{facts.perm}) catch "perm:?";
    const think_seg = std.fmt.bufPrint(&think_buf, "think:{s}", .{if (facts.show_thinking) "on" else "off"}) catch "think:?";
    const state_seg = std.fmt.bufPrint(&state_buf, "state:{s}", .{stateName(facts.state)}) catch "state:?";
    const tasks_seg = if (facts.running_tasks > 0)
        std.fmt.bufPrint(&tasks_buf, "tasks:{d}", .{facts.running_tasks}) catch ""
    else "";
    // Tokens: `[tok:{d}k]` at >= 1000 (integer division), else `[tok:{d}]`.
    const tok_seg = if (facts.last_tokens > 0)
        (if (facts.last_tokens >= 1000)
            std.fmt.bufPrint(&tok_buf, "[tok:{d}k]", .{facts.last_tokens / 1000})
        else
            std.fmt.bufPrint(&tok_buf, "[tok:{d}]", .{facts.last_tokens})) catch ""
    else "";

    var level: usize = 0;
    while (true) : (level += 1) {
        const segs = [_][]const u8{
            facts.model,
            facts.theme_id,
            if (level >= 2) "" else facts.cwd_tail,
            if (level >= 1) "" else facts.git_branch,
            perm_seg,
            think_seg,
            if (level >= 3) "" else tasks_seg,
            if (level >= 4) "" else tok_seg,
            state_seg,
        };
        // Join non-empty segments with " · ", wrapped in spaces. `n` advances
        // only on successful bufPrint writes, so a scratch overflow leaves a
        // valid prefix (used by the final utf8Prefix cap below).
        var n: usize = 0;
        scratch[n] = ' ';
        n += 1;
        var first = true;
        var overflowed = false;
        for (segs) |seg| {
            if (overflowed) break;
            if (seg.len == 0) continue;
            const out = if (first)
                std.fmt.bufPrint(scratch[n..], "{s}", .{seg})
            else
                std.fmt.bufPrint(scratch[n..], " · {s}", .{seg});
            if (out) |s| {
                n += s.len;
                first = false;
            } else |_| {
                overflowed = true;
            }
        }
        if (!overflowed and n < scratch.len) {
            scratch[n] = ' ';
            n += 1;
        } else {
            overflowed = true;
        }
        const line = scratch[0..n];
        if (level == 4) return present.utf8Prefix(line, max_w); // final cap
        if (overflowed) continue; // scratch exhausted — drop more chips
        if (line.len <= max_w) return line;
    }
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
    // grok status chips. Keep contiguous `perm:` / `state:` / `think:` markers.
    var scratch: [512]u8 = undefined;
    const chips = buildStatusChips(&scratch, facts, max_w);
    const text = store.format("{s}", .{chips}) orelse return;
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

/// Grok-inspired tasks pane: full-width strip above the editor.
///
/// Each row (mirrors grok `render_agent_overlay`):
///   [sel] [icon] Type  description………………  [Nt] [elapsed]
/// Icon is status-colored; selection is a left marker + reverse/accent bar.
/// Expanded selection shows up to 4 lines of output/error under the row.
fn drawTasksOverlay(
    root: vaxis.Window,
    region: layout_mod.Region,
    registry: ?*const subagent_mod.Registry,
    palette: *const theme_mod.Palette,
    store: *terminal.LineStore,
    opts: TasksPaneOpts,
) void {
    if (region.w == 0 or region.h == 0) return;
    const border_role: theme_mod.Role = if (opts.focused) .accent_fg else .card_border;
    const border = palette.style(border_role);
    const muted = palette.style(.muted_fg);
    const box = borderedChild(root, region, .{
        .where = .all,
        .glyphs = .single_rounded,
        .style = border,
    });
    if (box.width == 0 or box.height == 0) return;

    var snap_buf: [subagent_mod.max_registry_entries]subagent_mod.Entry = undefined;
    var n: usize = 0;
    var running: usize = 0;
    if (registry) |reg| {
        n = reg.snapshotInto(&snap_buf);
        running = reg.countByStatus(.running) + reg.countByStatus(.pending);
    }

    // Order: running/pending first, then newest-first within each group.
    var order: [subagent_mod.max_registry_entries]usize = undefined;
    {
        var oi: usize = 0;
        while (oi < n) : (oi += 1) order[oi] = n - 1 - oi; // newest first
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
    }

    // Title in top border (grok: compact "Tasks" chrome).
    const hdr: ?[]const u8 = if (opts.focused)
        (if (running > 0)
            store.format(" Tasks {d} · {d} running · j/k Space ", .{ n, running })
        else
            store.format(" Tasks {d} · j/k Space ", .{n}))
    else if (running > 0)
        store.format(" Tasks {d} · {d} running ", .{ n, running })
    else
        store.format(" Tasks {d} ", .{n});
    if (hdr) |h| {
        _ = root.printSegment(.{ .text = h, .style = palette.style(.status_fg) }, .{
            .col_offset = region.x + 2,
            .row_offset = region.y,
            .wrap = .none,
        });
    }

    if (n == 0) {
        printLineStyled(box, 0, "(no subagents)", muted);
        return;
    }

    const cursor = @min(opts.cursor, n - 1);
    var row: u16 = 0;
    var i: usize = 0;
    while (i < n and row < box.height) : (i += 1) {
        const e = &snap_buf[order[i]];
        const selected = i == cursor;
        const icon_style = statusStyle(e.status, palette);
        const glyph = statusGlyph(e.status, opts.tick_ms);
        const type_label = typeTitle(e.subagent_type);
        const elapsed = formatElapsed(e.started_ms, e.finished_ms, opts.tick_ms);

        // Right cluster first so we know how much width to reserve.
        // grok: "Nt · elapsed" / just elapsed when turns==0.
        const right: []const u8 = blk: {
            if (e.turns > 0) {
                break :blk store.format("{d}t · {s}", .{ e.turns, elapsed }) orelse elapsed;
            }
            break :blk elapsed;
        };
        const right_w: u16 = box.gwidth(right);
        const pad: u16 = 1;
        const right_col: u16 = if (box.width > right_w + pad) box.width - right_w else 0;

        // Left: "▸ ⠋ Scout  description…"
        const sel_mark: []const u8 = if (selected)
            (if (opts.expanded) "▾ " else "▸ ")
        else
            "  ";
        const desc = singleLine(e.description);
        // Build left without description, measure, then fit description by
        // display width (not bytes) so CJK/emoji don't collide with metrics.
        const left_head = store.format("{s}{s} {s}  ", .{ sel_mark, glyph, type_label }) orelse sel_mark;
        const head_w: u16 = box.gwidth(left_head);
        const desc_budget: u16 = if (right_col > head_w + 1) right_col - head_w - 1 else 0;
        const desc_fit = fitDisplay(box, desc, desc_budget);

        // Paint selection bar background on the whole row when focused+selected.
        if (selected and opts.focused) {
            var col_i: u16 = 0;
            while (col_i < box.width) : (col_i += 1) {
                box.writeCell(col_i, row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = palette.style(.status_bg).bg, .fg = palette.style(.accent_fg).fg },
                });
            }
        }

        // Icon + type in status color; description muted (or accent when selected).
        var col: u16 = 0;
        _ = box.printSegment(.{ .text = sel_mark, .style = if (selected) palette.style(.accent_fg) else muted }, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        col +|= box.gwidth(sel_mark);

        _ = box.printSegment(.{ .text = glyph, .style = icon_style }, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        col +|= box.gwidth(glyph);
        // space after icon
        col +|= 1;

        _ = box.printSegment(.{ .text = type_label, .style = if (selected) palette.style(.accent_fg) else icon_style }, .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        });
        col +|= box.gwidth(type_label);
        col +|= 2; // gap before description

        if (desc_fit.len > 0 and col < right_col) {
            const desc_style: vaxis.Style = if (selected) palette.style(.fg) else muted;
            _ = box.printSegment(.{ .text = desc_fit, .style = desc_style }, .{
                .row_offset = row,
                .col_offset = col,
                .wrap = .none,
            });
        }

        // Right-aligned metrics (elapsed / turns).
        if (right_w > 0 and right_col < box.width) {
            _ = box.printSegment(.{ .text = right, .style = muted }, .{
                .row_offset = row,
                .col_offset = right_col,
                .wrap = .none,
            });
        }
        row += 1;

        // Expanded detail (grok view-output): status line + output preview.
        if (selected and opts.expanded and row < box.height) {
            if (store.format("    {s} · {s}", .{ e.status.name(), e.id })) |meta| {
                printAt(box, row, 0, present.utf8Prefix(meta, box.width), muted);
                row += 1;
            }
            const detail: []const u8 = blk: {
                if (e.error_message) |em| if (em.len > 0) break :blk em;
                if (e.output.len > 0) break :blk e.output;
                if (e.status == .running or e.status == .pending) break :blk "working…";
                break :blk "(no output)";
            };
            var lines = std.mem.splitScalar(u8, detail, '\n');
            var di: usize = 0;
            while (lines.next()) |ln| : (di += 1) {
                if (di >= 4 or row >= box.height) break;
                const body = singleLine(ln);
                if (body.len == 0) continue;
                if (store.format("    {s}", .{body})) |s| {
                    printAt(box, row, 0, present.utf8Prefix(s, box.width), muted);
                    row += 1;
                }
            }
        }
    }
}


/// Truncate `text` so its vaxis display width is ≤ `max_w`.
fn fitDisplay(win: vaxis.Window, text: []const u8, max_w: u16) []const u8 {
    if (max_w == 0 or text.len == 0) return "";
    if (win.gwidth(text) <= max_w) return text;
    // Walk UTF-8 codepoints; keep the longest prefix that still fits.
    var i: usize = 0;
    var best: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + len > text.len) break;
        const cand = text[0 .. i + len];
        if (win.gwidth(cand) > max_w) break;
        best = i + len;
        i += len;
    }
    return text[0..best];
}

fn printAt(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    _ = win.printSegment(.{ .text = text, .style = style }, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn typeTitle(t: subagent_mod.SubagentType) []const u8 {
    return switch (t) {
        .task => "Task",
        .scout => "Scout",
        .reviewer => "Reviewer",
    };
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

fn statusGlyph(status: subagent_mod.Status, tick_ms: u64) []const u8 {
    // braille spinner (grok-style motion)
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
    const end = if (finished_ms > started_ms) finished_ms else now_ms;
    const ms = if (end > started_ms) end - started_ms else 0;
    const sec = ms / 1000;
    const mins = sec / 60;
    const s = sec % 60;
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
    const turn_vis = facts.state == .busy or facts.state == .closing or facts.state == .@"error";
    const layout = layout_mod.compute(.{ .cols = cols, .rows = rows }, snap.len, modal.pending, facts.status_note.len > 0, 0, ed.lineCount(), false, turn_vis);
    const palette = theme_mod.builtinDefault();
    var sb = scrollback_mod.Scrollback.init(gpa);
    errdefer sb.deinit();
    setCardPaintSnap(snap);
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
    const turn_vis = facts.state == .busy or facts.state == .closing or facts.state == .@"error";
    const layout = layout_mod.compute(.{ .cols = cols, .rows = rows }, snap.len, false, facts.status_note.len > 0, 0, ed.lineCount(), false, turn_vis);
    const palette = theme_mod.builtinDefault();
    var sb = scrollback_mod.Scrollback.init(gpa);
    errdefer sb.deinit();
    setCardPaintSnap(snap);
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

    // Geometry @80x24 busy+modal+1-line editor:
    //   shortcuts=23, editor=20..22, turn=19, modal=15..18, cards=0..14
    try expectRowContains(&cs.screen, 0, "✓ Write");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
    try expectRowContains(&cs.screen, 3, "hello world");

    try expectModalTopRow(&cs.screen, 15);
    try expectRowContains(&cs.screen, 16, "risk:medium");
    try expectRowContains(&cs.screen, 16, "write_file");
    try expectRowContains(&cs.screen, 17, "[a]=allow");
    try expectModalBottomRow(&cs.screen, 18);

    // Turn-status strip (busy).
    try expectRowContains(&cs.screen, 19, "Working");

    // Editor box + shortcuts bar under it.
    try expectCellEquals(&cs.screen, 0, 20, "╭");
    try expectCellEquals(&cs.screen, 79, 20, "╮");
    try expectRowContains(&cs.screen, 20, "perm:ask");
    try expectRowContains(&cs.screen, 20, "state:busy");
    try expectCellEquals(&cs.screen, 0, 21, "│");
    try expectCellEquals(&cs.screen, 1, 21, "❯");
    try expectCellEquals(&cs.screen, 0, 22, "╰");
    try expectCellEquals(&cs.screen, 79, 22, "╯");
    // Modal pending → permission shortcut hints on the bottom bar.
    try expectRowContains(&cs.screen, 23, "allow");
    try expectRowContains(&cs.screen, 23, "deny");
    try expectCellEquals(&cs.screen, 0, 0, "✓");
}

test "render wide frame 130 cols matches golden rows (no truncation)" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 130, 24, f.facts_full, &f.snap, &f.ed, f.modal);
    defer cs.deinit(gpa);
    defer sb.deinit();

    try expectRowContains(&cs.screen, 0, "✓ Write");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
    try expectRowContains(&cs.screen, 3, "hello world");
    try expectCellEquals(&cs.screen, 0, 20, "╭");
    try expectCellEquals(&cs.screen, 129, 20, "╮");
    try expectRowContains(&cs.screen, 20, "state:busy");
    try expectCellEquals(&cs.screen, 1, 21, "❯");
    try expectCellEquals(&cs.screen, 0, 22, "╰");
    try expectCellEquals(&cs.screen, 129, 22, "╯");
    try expectModalTopRow(&cs.screen, 15);
    try expectCellEquals(&cs.screen, 0, 15, "╭");
    try expectCellEquals(&cs.screen, 129, 15, "╮");

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
    try expectRowEquals(&cs.screen, 3, "✓ Write");
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
    // Status chips on editor top border. busy+shortcuts → editor_y=20.
    // Format keeps contiguous "state:busy" / "perm:ask" PTY markers.
    try expectRowContains(&cs.screen, 20, "state:busy");
    try expectRowContains(&cs.screen, 20, "perm:ask");

}

test "status meta: ambient chips (cwd/git/tokens) render on the editor border" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;
    facts.cwd_tail = "zag";
    facts.git_branch = "main";
    facts.last_tokens = 12345;
    // 100 cols: the full chip line (model/theme/cwd/git/perm/think/tok/state
    // ≈ 88 bytes) fits inside max_w = 96, so nothing is dropped.
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 100, 24, facts, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    // busy+shortcuts → editor_y=20. Chips join with " · "; tokens >= 1000
    // render as "{d}k". Mandatory PTY markers stay contiguous.
    try expectRowContains(&cs.screen, 20, "· zag · main · perm:ask");
    try expectRowContains(&cs.screen, 20, "think:off");
    try expectRowContains(&cs.screen, 20, "[tok:12k]");
    try expectRowContains(&cs.screen, 20, "state:busy");

}

test "status meta: token chip shows the raw count below 1000" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;
    facts.cwd_tail = "zag";
    facts.last_tokens = 999;
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 80, 24, facts, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    try expectRowContains(&cs.screen, 20, "[tok:999]");
    try expectRowContains(&cs.screen, 20, "state:busy");

}

test "status meta: narrow border drops ambient chips before perm/think/state" {

    const gpa = std.testing.allocator;
    const f = fixedFixture();
    var facts = f.facts_full;
    facts.cwd_tail = "zag";
    facts.git_branch = "main";
    facts.last_tokens = 12345;
    // 70 cols: the full chip line (≈88B) does not fit max_w = 66, so the
    // optional chips drop in priority order (git → cwd → tasks → tokens);
    // the mandatory core (≈59B) survives intact with the PTY markers.
    var cs: CellScreen = undefined;
    var sb = try drawFixture(&cs, gpa, 70, 24, facts, &f.snap, &f.ed, .{});
    defer cs.deinit(gpa);
    defer sb.deinit();
    try expectRowContains(&cs.screen, 20, "perm:ask");
    try expectRowContains(&cs.screen, 20, "think:off");
    try expectRowContains(&cs.screen, 20, "state:busy");
    // The ambient chips were dropped, not truncated mid-marker.
    var buf: [512]u8 = undefined;
    const row = rowText(&cs.screen, 20, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row, "main") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "[tok:12k]") == null);

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
    // busy: shortcuts=1 + turn=1 + editor_h=5 → editor_y=18, ╰ at 22, shortcuts 23.
    try expectCellEquals(&cs.screen, 0, 18, "╭");
    try expectCellEquals(&cs.screen, 0, 22, "╰");
    try expectCellEquals(&cs.screen, 1, 19, "❯");
    try expectRowContains(&cs.screen, 19, "one");
    try expectRowContains(&cs.screen, 20, "two");
    try expectRowContains(&cs.screen, 21, "three");

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
    // Status chips truncated into editor top border (busy → editor_y=20).
    try expectCellEquals(&cs.screen, 0, 20, "╭");
    try expectCellEquals(&cs.screen, 39, 20, "╮");

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
    try expectCellEquals(&cs.screen, 0, 20, "╭");
    try expectCellEquals(&cs.screen, 1, 21, "❯");

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

    try expectRowContains(&cs.screen, 0, "✓ Write");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
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
    const layout2 = layout_mod.compute(.{ .cols = 80, .rows = 24 }, 1, false, false, 0, 1, false, false);
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

    try expectRowContains(&cs.screen, 0, "✓ Write");
    try expectRowContains(&cs.screen, 1, "id=t1 args={}");
    try expectRowContains(&cs.screen, 3, "✓ Bash");
    try expectRowContains(&cs.screen, 4, "ok=true");

}

// ── grok tool-body polish + verb groups ──────────────────────────────────

test "tool groups: toolGroupInfo counts consecutive same-verb completed tools" {

    const a = mdCard("tool read_file", .ordinary, "a");
    const b = mdCard("tool read", .ordinary, "b"); // read alias → same "Read"
    const cb = mdCard("tool bash", .ordinary, "c");
    const d = mdCard("tool run_shell", .ordinary, "d"); // shell alias → same "Bash"
    const e = mdCard("tool write_file", .ordinary, "e");
    const snap = [_]cards.CardSlot{ a, b, cb, d, e };

    const g0 = toolGroupInfo(&snap, 0);
    try std.testing.expectEqual(@as(usize, 2), g0.size);
    try std.testing.expect(!g0.is_newest_in_group);
    try std.testing.expectEqualStrings("Read", g0.pretty);
    const g1 = toolGroupInfo(&snap, 1);
    try std.testing.expectEqual(@as(usize, 2), g1.size);
    try std.testing.expect(g1.is_newest_in_group);
    try std.testing.expectEqualStrings("Read", g1.pretty);

    const g2 = toolGroupInfo(&snap, 2);
    try std.testing.expectEqual(@as(usize, 2), g2.size);
    try std.testing.expect(!g2.is_newest_in_group);
    const g3 = toolGroupInfo(&snap, 3);
    try std.testing.expectEqual(@as(usize, 2), g3.size);
    try std.testing.expect(g3.is_newest_in_group);

    // Lone Write card: size 1, trivially newest.
    const g4 = toolGroupInfo(&snap, 4);
    try std.testing.expectEqual(@as(usize, 1), g4.size);
    try std.testing.expect(g4.is_newest_in_group);

    // Non-tool and tool-start cards never join a group, and they break a run.
    const t0 = mdCard("assistant turn=1", .ordinary, "hi");
    const t1 = mdCard("tool start read_file", .ordinary, "id=t1 args={}");
    const snap2 = [_]cards.CardSlot{ t0, t1, a, b };
    try std.testing.expectEqual(@as(usize, 0), toolGroupInfo(&snap2, 0).size);
    try std.testing.expectEqual(@as(usize, 0), toolGroupInfo(&snap2, 1).size);
    // a at index 2: left run broken by the tool-start card, but b still
    // joins from the right → group {2,3}, a not newest.
    const ga = toolGroupInfo(&snap2, 2);
    try std.testing.expectEqual(@as(usize, 2), ga.size);
    try std.testing.expect(!ga.is_newest_in_group);
    const gb = toolGroupInfo(&snap2, 3);
    try std.testing.expectEqual(@as(usize, 2), gb.size);
    try std.testing.expect(gb.is_newest_in_group);
}

test "tool groups: measureCardHeight collapses non-newest grouped tools to 1 row" {

    const gpa = std.testing.allocator;
    const a = mdCard("tool read_file", .ordinary, "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta");
    const b = mdCard("tool read", .ordinary, "one\ntwo");
    const snap = [_]cards.CardSlot{ a, b };
    setCardPaintSnap(&snap);
    defer setCardPaintSnap(&.{});
    setCardPaintOpts(.{ .tool_groups_collapsed = true });
    defer setCardPaintOpts(.{});

    // Older sibling collapses to the title row only.
    try std.testing.expectEqual(@as(u16, 1), measureCardHeight(gpa, &snap[0], 80));
    // Newest keeps title + truncated body (2 lines).
    try std.testing.expectEqual(@as(u16, 3), measureCardHeight(gpa, &snap[1], 80));

    // A tool-start card never joins: the completed tool keeps its body.
    const s = mdCard("tool start read_file", .ordinary, "id=t1 args={}");
    const snap2 = [_]cards.CardSlot{ s, a };
    setCardPaintSnap(&snap2);
    try std.testing.expectEqual(@as(u16, 8), measureCardHeight(gpa, &snap2[1], 80)); // 7-line body + title

    // Collapse disabled → every tool card measures with its body.
    setCardPaintOpts(.{ .tool_groups_collapsed = false });
    try std.testing.expectEqual(@as(u16, 8), measureCardHeight(gpa, &snap[0], 80));
    try std.testing.expectEqual(@as(u16, 3), measureCardHeight(gpa, &snap[1], 80));
}

test "tool groups: non-newest grouped tool renders header-only, newest gets ×N" {

    const gpa = std.testing.allocator;
    const snap = [_]cards.CardSlot{
        mdCard("tool read_file", .ordinary, "alpha\nbeta\ngamma"),
        mdCard("tool read", .ordinary, "one\ntwo"),
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

    // Older sibling: header-only (row 0), no body rows, no count suffix.
    try expectRowContains(&cs.screen, 0, "✓ Read");
    try expectRowContains(&cs.screen, 0, "alpha");
    var buf: [512]u8 = undefined;
    const r0 = rowText(&cs.screen, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r0, "×") == null);
    // Newest (row 2): count suffix + truncated body.
    try expectRowContains(&cs.screen, 2, "✓ Read ×2");
    try expectRowContains(&cs.screen, 3, "one");
    try expectRowContains(&cs.screen, 4, "two");
}

test "tool body: measureToolBodyLines matches painted rows for all modes" {

    // Bash sections: only the stdout/stderr content lines paint (2 rows).
    const bash = "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=3 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n--- stdout ---\nout\n--- stderr ---\nerr\n";
    try std.testing.expectEqual(@as(u16, 2), measureToolBodyLines(bash, 6));
    // Empty sections → no body rows (title only).
    try std.testing.expectEqual(@as(u16, 0), measureToolBodyLines("ok: code=shell_success\n--- stdout ---\n--- stderr ---\n", 6));

    // Diff: 6 lines fit the 6-line cap (no footer)…
    const diff = "--- a/src/x.zig\n+++ b/src/x.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n ctx\n";
    try std.testing.expectEqual(@as(u16, 6), measureToolBodyLines(diff, 6));
    // …a 7th line adds the "… +N lines" footer row.
    const diff7 = "--- a/src/x.zig\n+++ b/src/x.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n ctx\nmore\n";
    try std.testing.expectEqual(@as(u16, 7), measureToolBodyLines(diff7, 6));

    // Leading blanks drop; the gutter never changes the row count.
    try std.testing.expectEqual(@as(u16, 1), measureToolBodyLines("\n\nfoo", 6));
    try std.testing.expectEqual(@as(u16, 3), measureToolBodyLines("alpha\nbeta\ngamma\n", 6));

    // Envelope-only bodies keep their one line (path is not on the title).
    try std.testing.expectEqual(@as(u16, 1), measureToolBodyLines("ok: wrote 16 bytes to target.txt", 6));
    // Envelope with a path on the title AND more content → envelope skipped.
    try std.testing.expectEqual(@as(u16, 2), measureToolBodyLines("ok: search_replace path=x removed=1 inserted=1\nline1\nline2", 6));
}

test "tool body: diff markers paint colored without panic" {

    const gpa = std.testing.allocator;
    const body = "--- a/src/x.zig\n+++ b/src/x.zig\n@@ -1,2 +1,2 @@\n-old line\n+new line\n context\n";
    const snap = [_]cards.CardSlot{mdCard("tool apply_patch", .ordinary, body)};
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

    // Title (diff headers don't leak into the preview) + all 6 body rows.
    try expectRowContains(&cs.screen, 0, "✓ Edit");
    try expectRowContains(&cs.screen, 1, "--- a/src/x.zig");
    try expectRowContains(&cs.screen, 2, "+++ b/src/x.zig");
    try expectRowContains(&cs.screen, 4, "-old line");
    try expectRowContains(&cs.screen, 5, "+new line");
    try expectRowContains(&cs.screen, 6, " context");
    // Body starts at x_off=2 (builtin default: success=2 green, error=1,
    // muted=8). `-` line error-colored, `+` line success-colored, context
    // and diff headers muted.
    try expectCellFgIndex(&cs.screen, 2, 4, 1);
    try expectCellFgIndex(&cs.screen, 2, 5, 2);
    try expectCellFgIndex(&cs.screen, 2, 1, 8);
    try expectCellFgIndex(&cs.screen, 2, 6, 8);
}

test "tool body: bash stdout/stderr sections paint with stderr colored" {

    const gpa = std.testing.allocator;
    const body = "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=3 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n--- stdout ---\nout\n--- stderr ---\nerr\n";
    const snap = [_]cards.CardSlot{mdCard("tool bash", .ordinary, body)};
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

    // Envelope + markers skipped; stdout muted, stderr error-colored.
    try expectRowContains(&cs.screen, 0, "✓ Bash  exit 0");
    try expectRowContains(&cs.screen, 1, "out");
    try expectRowContains(&cs.screen, 2, "err");
    var buf: [512]u8 = undefined;
    const r0 = rowText(&cs.screen, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r0, "ok: code=") == null);
    try expectCellFgIndex(&cs.screen, 2, 1, 8); // stdout → muted
    try expectCellFgIndex(&cs.screen, 2, 2, 1); // stderr → tool_error_fg
}

test "tool body: file text paints a muted line-number gutter" {

    const gpa = std.testing.allocator;
    const snap = [_]cards.CardSlot{mdCard("tool read_file", .ordinary, "alpha\nbeta\ngamma")};
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

    // Gutter right-aligned in 3 cols at x_off=2: "  1 alpha" …
    try expectRowContains(&cs.screen, 1, "alpha");
    try expectCellEquals(&cs.screen, 4, 1, "1"); // right-aligned number
    try expectCellFgIndex(&cs.screen, 4, 1, 8); // muted gutter
    try expectCellEquals(&cs.screen, 6, 1, "a"); // content starts after gutter + space
    try expectRowContains(&cs.screen, 2, "beta");
    try expectRowContains(&cs.screen, 3, "gamma");
}



