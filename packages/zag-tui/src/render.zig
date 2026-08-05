//! ANSI layout renderer (allocation-light; uses stack buffers).
//!
//! Thin shell over `layout.compute`: per-region draw functions write only
//! within their region bounds; card bodies/titles truncate to the region
//! width on UTF-8 boundaries; multi-line editor content clips to the fixed
//! content row. Full-mode and constrained-mode frames are byte-identical to
//! the pre-slice paragraphs for the same inputs (golden fixtures below).

const std = @import("std");
const c = @import("constants.zig");
const cards = @import("cards.zig");
const editor = @import("editor.zig");
const layout_mod = @import("layout.zig");
const permission = @import("permission.zig");
const present = @import("present.zig");
const terminal = @import("terminal.zig");

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

/// Render full frame. Permission modal fields come from a lock-safe snapshot.
pub fn renderFrame(
    term: *terminal.Terminal,
    size: terminal.Size,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
) error{WriteFailed}!void {
    var buf: [16 * 1024]u8 = undefined;
    var list = std.ArrayList(u8).initBuffer(&buf);

    // Clear + home (once per frame; full repaint semantics retained in v1).
    list.appendSliceBounded("\x1b[H\x1b[2J") catch return error.WriteFailed;

    const layout = layout_mod.compute(size, snap.len, modal.pending, facts.status_note.len > 0);
    switch (layout.mode) {
        .constrained => {
            try drawHeader(&list, layout.header, layout.mode, facts);
            try drawStatus(&list, layout.status, layout.mode, facts, ed);
            try drawCards(&list, layout.cards, layout.cards_window, layout.mode, snap);
            try drawEditor(&list, layout.editor, layout.mode, ed);
        },
        .full => {
            try drawHeader(&list, layout.header, layout.mode, facts);
            try drawCards(&list, layout.cards, layout.cards_window, layout.mode, snap);
            try drawEditor(&list, layout.editor, layout.mode, ed);
            try drawStatus(&list, layout.status, layout.mode, facts, ed);
            if (layout.modal) |m| try drawModal(&list, m, modal);
        },
    }

    try term.writeAll(list.items);
}

fn drawHeader(
    list: *std.ArrayList(u8),
    region: layout_mod.Region,
    mode: layout_mod.Mode,
    facts: StatusFacts,
) error{WriteFailed}!void {
    var written: u16 = 0;
    if (mode == .constrained) {
        if (written < region.h) {
            try appendLine(list, region.w, "[zag tui · constrained]");
        }
        return;
    }
    if (written < region.h) {
        try appendLine(list, region.w, "┌─ zag  tui ─");
        written += 1;
    }
    if (written < region.h) {
        var tmp: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "│ id: {s}  open:{s} cfg:{s}", .{
            facts.id_display,
            facts.open_display,
            if (facts.session_configured) "y" else "n",
        }) catch return error.WriteFailed;
        try appendLine(list, region.w, s);
        written += 1;
    }
    if (written < region.h) {
        var tmp: [2048]u8 = undefined;
        const head = std.fmt.bufPrint(&tmp, "│ perm:{s}  shell:{s}  state:{s}", .{
            facts.perm,
            facts.shell,
            stateName(facts.state),
        }) catch return error.WriteFailed;
        var s = head;
        if (facts.steering_pending > 0 or facts.followup_pending > 0) {
            const tail = std.fmt.bufPrint(tmp[head.len..], "  S:{d} F:{d}", .{
                facts.steering_pending,
                facts.followup_pending,
            }) catch return error.WriteFailed;
            s = tmp[0 .. head.len + tail.len];
        }
        try appendLine(list, region.w, s);
        written += 1;
    }
    if (facts.status_note.len > 0 and written < region.h) {
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "│ note: {s}", .{facts.status_note}) catch return error.WriteFailed;
        try appendLine(list, region.w, s);
    }
}

fn drawCards(
    list: *std.ArrayList(u8),
    region: layout_mod.Region,
    window: layout_mod.CardsWindow,
    mode: layout_mod.Mode,
    snap: []const cards.CardSlot,
) error{WriteFailed}!void {
    var written: u16 = 0;
    const title_limit = @min(@as(usize, 128), @max(@as(usize, region.w), 2) - 2);
    const body_limit = @min(@as(usize, 120), @max(@as(usize, region.w), 3) - 3);

    if (mode == .full) {
        if (written < region.h) {
            try appendLine(list, region.w, "├─ cards ─");
            written += 1;
        }
        if (window.count == 0) {
            if (written < region.h) {
                try appendLine(list, region.w, "│ (no events yet)");
            }
            return;
        }
        var i: usize = 0;
        while (i < window.count and written < region.h) : (i += 1) {
            const card = &snap[window.start + i];
            if (written < region.h) {
                const title = present.utf8Prefix(card.titleSlice(), title_limit);
                try appendFmtRawLine(list, "│ · {s}", .{title});
                written += 1;
            }
            if (card.body_len > 0 and written < region.h) {
                const preview = present.utf8Prefix(card.bodySlice(), body_limit);
                try appendFmtRawLine(list, "│   {s}", .{preview});
                written += 1;
            }
        }
        return;
    }

    // Constrained: up to 3 one-line titles, NEWEST first (snap[len-1-i]).
    var i: usize = window.count;
    while (i > 0 and written < region.h) {
        i -= 1;
        const card = &snap[window.start + i];
        const title = present.utf8Prefix(card.titleSlice(), title_limit);
        try appendFmtRawLine(list, "· {s}", .{title});
        written += 1;
    }
}

fn drawEditor(
    list: *std.ArrayList(u8),
    region: layout_mod.Region,
    mode: layout_mod.Mode,
    ed: *const editor.Editor,
) error{WriteFailed}!void {
    var written: u16 = 0;
    if (mode == .constrained) {
        if (written < region.h) {
            try appendFmtLine(list, region.w, "> {s}", .{singleLine(ed.slice())});
        }
        return;
    }
    if (written < region.h) {
        try appendLine(list, region.w, "├─ editor ─");
        written += 1;
    }
    // Fixed content row: the first editor line, clipped like card bodies.
    if (written < region.h) {
        const content = ed.slice();
        if (content.len == 0) {
            try appendLine(list, region.w, "│ > ");
        } else {
            var tmp: [2048]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "│ > {s}", .{singleLine(content)}) catch return error.WriteFailed;
            try appendLine(list, region.w, s);
        }
    }
}

fn drawStatus(
    list: *std.ArrayList(u8),
    region: layout_mod.Region,
    mode: layout_mod.Mode,
    facts: StatusFacts,
    ed: *const editor.Editor,
) error{WriteFailed}!void {
    if (region.h < 1) return;
    if (mode == .constrained) {
        try appendFmtLine(list, region.w, "state={s} id={s}", .{ stateName(facts.state), facts.id_display });
        return;
    }
    try appendFmtLine(list, region.w, "│ [{d}/{d}]  [submit:Enter · nl:Alt+Enter]", .{
        ed.len,
        c.editor_max_bytes,
    });
}

fn drawModal(
    list: *std.ArrayList(u8),
    region: layout_mod.Region,
    modal: permission.ModalSnapshot,
) error{WriteFailed}!void {
    var written: u16 = 0;
    if (written < region.h) {
        try appendLine(list, region.w, "┌─ permission (modal) ─");
        written += 1;
    }
    if (written < region.h) {
        try appendFmtLine(list, region.w, "│ risk:{s}  args_len:{d}  tool:{s}", .{
            modal.riskSlice(),
            modal.args_len,
            if (modal.tool_name_len == 0) "—" else modal.toolNameSlice(),
        });
        written += 1;
    }
    if (written < region.h) {
        try appendLine(list, region.w, "│ [a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny");
        written += 1;
    }
    if (written < region.h) {
        try appendLine(list, region.w, "└─");
        written += 1;
    }
}

/// Append `s` truncated to `w` bytes on a UTF-8 boundary, plus CRLF.
fn appendLine(list: *std.ArrayList(u8), w: u16, s: []const u8) error{WriteFailed}!void {
    const cut = present.utf8Prefix(s, w);
    list.appendSliceBounded(cut) catch return error.WriteFailed;
    list.appendSliceBounded("\r\n") catch return error.WriteFailed;
}

fn appendFmtLine(
    list: *std.ArrayList(u8),
    w: u16,
    comptime fmt: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    var tmp: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return error.WriteFailed;
    try appendLine(list, w, s);
}

/// Append a formatted line WITHOUT line-level width truncation — used for
/// card title/body rows, where the part rules
/// (`utf8Prefix(title, min(128, w-2))`, `utf8Prefix(body, min(120, w-3))`)
/// are the authoritative truncation and the prefix budget already mirrors
/// today's caps (128/120).
fn appendFmtRawLine(
    list: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    var tmp: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return error.WriteFailed;
    list.appendSliceBounded(s) catch return error.WriteFailed;
    list.appendSliceBounded("\r\n") catch return error.WriteFailed;
}

fn singleLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

// ── fixtures (tui-layout-001) ───────────────────────────────────────────────

/// Pipe-backed recording terminal: `bytes()` drains the non-blocking wake
/// pipe that stands in for stdout.
const RecordingTerm = struct {
    term: terminal.Terminal,
    fds: [2]std.posix.fd_t,
    buf: [8192]u8 = undefined,

    fn init() !RecordingTerm {
        const fds = try terminal.makeWakePipe();
        return .{ .term = .{ .in_fd = fds[0], .out_fd = fds[1], .orig_in = undefined }, .fds = fds };
    }

    fn bytes(self: *RecordingTerm) []const u8 {
        var total: usize = 0;
        while (true) {
            const n = std.posix.read(self.fds[0], self.buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        return self.buf[0..total];
    }

    fn deinit(self: *RecordingTerm) void {
        terminal.closeFd(self.fds[0]);
        terminal.closeFd(self.fds[1]);
    }
};

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

/// Full-mode golden: captured from the pre-slice render.zig at 80×24 with the
/// fixed fixture (2 cards, empty editor, pending modal, S/F counters). The
/// new region-based renderer must reproduce these bytes exactly.
const GOLDEN_FULL =
    "\x1b[H\x1b[2J" ++
    "┌─ zag  tui ─\r\n" ++
    "│ id: sess-abc  open:create_new cfg:y\r\n" ++
    "│ perm:ask  shell:protect  state:busy  S:2 F:1\r\n" ++
    "├─ cards ─\r\n" ++
    "│ · run_start\r\n" ++
    "│   session_configured=y\r\n" ++
    "│ · assistant turn=1\r\n" ++
    "│   hello world\r\n" ++
    "├─ editor ─\r\n" ++
    "│ > \r\n" ++
    "│ [0/65536]  [submit:Enter · nl:Alt+Enter]\r\n" ++
    "┌─ permission (modal) ─\r\n" ++
    "│ risk:medium  args_len:23  tool:write_file\r\n" ++
    "│ [a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny\r\n" ++
    "└─\r\n";

test "render full-mode frame byte-identical to pre-slice (golden)" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    const f = fixedFixture();
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &f.snap, &f.ed, f.modal);
    try std.testing.expectEqualStrings(GOLDEN_FULL, rec.bytes());
    // At cols ≥ 123 the truncation caps (128/120) never bite, so a wide
    // terminal renders the same bytes for the same input.
    try renderFrame(&rec.term, .{ .cols = 130, .rows = 24 }, f.facts_full, &f.snap, &f.ed, f.modal);
    try std.testing.expectEqualStrings(GOLDEN_FULL, rec.bytes());
}

/// Constrained-mode golden: captured from the pre-slice render.zig at 30×8.
/// Modal is never drawn in constrained mode.
const GOLDEN_CONSTRAINED =
    "\x1b[H\x1b[2J" ++
    "[zag tui · constrained]\r\n" ++
    "state=busy id=sess-abc\r\n" ++
    "· assistant turn=1\r\n" ++
    "· run_start\r\n" ++
    "> \r\n";

test "render constrained-mode frame byte-identical to pre-slice (golden)" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    const f = fixedFixture();
    try renderFrame(&rec.term, .{ .cols = 30, .rows = 8 }, f.facts_constrained, &f.snap, &f.ed, f.modal);
    try std.testing.expectEqualStrings(GOLDEN_CONSTRAINED, rec.bytes());
}

test "render body preview truncated to region width on UTF-8 boundary" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    const f = fixedFixture();
    // 80 cols → body limit = min(120, 77) = 77. A 2-byte é straddles the cut;
    // the whole codepoint must be dropped (76 a's, no é).
    var long = cards.CardSlot{ .occupied = true, .title_len = 3, .body_len = 81 };
    @memcpy(long.title[0..3], "big");
    @memcpy(long.body[0..76], "a" ** 76);
    @memcpy(long.body[76..78], "\xc3\xa9");
    @memcpy(long.body[78..81], "xyz");
    const snap = [_]cards.CardSlot{ long };
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &snap, &f.ed, .{});
    const frame = rec.bytes();
    try std.testing.expect(std.mem.indexOf(u8, frame, "\xc3\xa9") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, ("a" ** 76) ++ "\r\n") != null);
}

test "render title truncated to region width" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    const f = fixedFixture();
    // 80 cols → title limit = min(128, 78) = 78.
    var slot = cards.CardSlot{ .occupied = true, .title_len = 100, .body_len = 0 };
    @memcpy(slot.title[0..100], "t" ** 100);
    const snap = [_]cards.CardSlot{ slot };
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &snap, &f.ed, .{});
    const frame = rec.bytes();
    try std.testing.expect(std.mem.indexOf(u8, frame, "│ · " ++ ("t" ** 78) ++ "\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "t" ** 79) == null);
}

test "render multi-line editor clipped to the fixed content row" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    var f = fixedFixture();
    _ = f.ed.insert("line1\nline2");
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &f.snap, &f.ed, .{});
    const frame = rec.bytes();
    try std.testing.expect(std.mem.indexOf(u8, frame, "│ > line1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "│ . line2") == null);
}

test "render header strings min-capped to region width" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    var f = fixedFixture();
    f.facts_full.id_display = "x" ** 100;
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &f.snap, &f.ed, .{});
    const frame = rec.bytes();
    // "│ id: " (8 bytes with 3-byte │) + 72 x's = 80; longer runs must not
    // appear and the capped line must end with CRLF.
    try std.testing.expect(std.mem.indexOf(u8, frame, "x" ** 73) == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, ("x" ** 72) ++ "\r\n") != null);
}

test "render no-events frame" {
    var rec = try RecordingTerm.init();
    defer rec.deinit();
    const f = fixedFixture();
    try renderFrame(&rec.term, .{ .cols = 80, .rows = 24 }, f.facts_full, &.{}, &f.ed, .{});
    const frame = rec.bytes();
    try std.testing.expect(std.mem.indexOf(u8, frame, "│ (no events yet)\r\n") != null);
}
