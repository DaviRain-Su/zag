//! Row-level virtualized transcript scrollback (tui-scrollback-001).
//!
//! Port of hyper-grok-build's scrollback state (compute_paint_window,
//! lazy measurement, follow mode) — Zig-native, HEIGHT-ONLY cache:
//! per-card geometry keyed by (slot_index, ui_seq, occupied), cumulative
//! virtual_y over a compressed visible-card list, and a settle loop that
//! measures the visible window exactly (via an injected measure callback).
//!
//! This module is pure: the measure callback is supplied by the caller
//! (render.zig runs the markdown renderer in measure mode); tests inject a
//! fake. No vaxis import here.

const std = @import("std");
const cards = @import("cards.zig");
const c = @import("constants.zig");

/// i17 y_off bound (vaxis Window.y_off). Draw clamps to this; invariant:
/// skip < h <= 65535 < |i17 min| = 65536, so the negative child offset
/// never overflows the cast.
pub const max_draw_offset: usize = 65535;

/// Estimate margin: entries below the viewport measured exactly, so the
/// next scroll-up lands exact (hyper: MEASURE_MARGIN_ENTRIES = 8).
pub const measure_margin_entries: usize = 8;

/// Per-card geometry cache. Indexed by SLOT index (keyed with ui_seq by
/// the caller via `ensureMeasured` — see `sync`).
pub const CardGeo = struct {
    /// Height in rows: exact when `measured`, else an estimate.
    h: u16 = 0,
    measured: bool = false,
};

pub const EstimateFn = *const fn (slot: *const cards.CardSlot, content_width: u16, assistant: bool) u16;
pub const MeasureFn = *const fn (gpa: std.mem.Allocator, slot: *const cards.CardSlot, content_width: u16) u16;

pub const PrepareResult = struct {
    /// Paint window over the visible-card list.
    start: usize,
    end: usize,
    /// Content row of `start` in viewport coordinates (may be negative —
    /// the first card can be clipped at the top).
    content_y0: i64,
};

/// Row-level scrollback state. Owned by App (survives frames: geometry
/// cache + scroll position are cross-frame).
pub const Scrollback = struct {
    gpa: std.mem.Allocator,
    /// Visible-card index list: positions into the snapshot array.
    /// Compressed: skips unoccupied and `.terminal` slots.
    vis: std.ArrayListUnmanaged(u16) = .empty,
    /// Parallel geometry (vis-indexed) — heights + exactness.
    geo: std.ArrayListUnmanaged(CardGeo) = .empty,
    /// Cumulative rows over vis: vy[i+1] = vy[i] + h[i] + 1 (gap = 1
    /// between visible cards, trailing included).
    vy: std.ArrayListUnmanaged(usize) = .empty,
    total_height: usize = 0,
    /// Rows from the transcript top; 0 = oldest. usize on purpose (u16
    /// strands the bottom of >65535-row sessions).
    scroll_offset: usize = 0,
    /// Auto-scroll to the newest row. Any manual upward scroll clears it;
    /// overscroll at the bottom re-engages it.
    follow_mode: bool = true,
    last_width: u16 = 0,
    /// Cards present last sync (for change detection): parallel to slots.
    seen: [c.card_slots]u64 = [_]u64{0} ** c.card_slots,
    /// Slots occupied at last sync.
    seen_occ: [c.card_slots]bool = [_]bool{false} ** c.card_slots,
    /// Whether any geometry changed since the last prepare (settle needs
    /// a re-measure pass).
    geometry_dirty: bool = true,

    pub fn init(gpa: std.mem.Allocator) Scrollback {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scrollback) void {
        self.vis.deinit(self.gpa);
        self.geo.deinit(self.gpa);
        self.vy.deinit(self.gpa);
    }

    /// Row count of the whole visible transcript.
    pub fn total(self: *const Scrollback) usize {
        return self.total_height;
    }

    pub fn maxOffset(self: *const Scrollback, viewport_h: usize) usize {
        return self.total_height -| viewport_h;
    }

    // ── sync: visible list + change detection ──────────────────────────────

    /// Rebuild the visible-card list from the snapshot (O(slots)); mark
    /// geometry dirty when the visible composition or any card identity
    /// (ui_seq) changed. Called once per frame before prepare.
    pub fn sync(self: *Scrollback, snap: []const cards.CardSlot) void {
        var new_vis: std.ArrayListUnmanaged(u16) = .empty;
        // Compare against `seen`; only rebuild when something changed.
        var changed = false;
        var i: usize = 0;
        while (i < snap.len) : (i += 1) {
            const slot = &snap[i];
            const occ = slot.occupied and slot.kind != .terminal;
            if (occ != self.seen_occ[i] or (occ and slot.ui_seq != self.seen[i])) {
                changed = true;
            }
            self.seen_occ[i] = occ;
            if (occ) self.seen[i] = slot.ui_seq;
        }
        if (!changed and self.vis.items.len > 0) return;

        new_vis.ensureTotalCapacity(self.gpa, snap.len) catch return;
        for (snap, 0..) |*slot, si| {
            if (slot.occupied and slot.kind != .terminal) {
                new_vis.appendAssumeCapacity(@intCast(si));
            }
        }
        self.vis.deinit(self.gpa);
        self.vis = new_vis;
        // Geometry parallel array is rebuilt below (prepare); mark dirty.
        self.geometry_dirty = true;
    }

    // ── estimate + prepare ─────────────────────────────────────────────────

    /// Rebuild virtual_y + total from the visible list and current geo
    /// (estimate or exact heights). O(vis).
    fn rebuildVy(self: *Scrollback) void {
        self.vy.clearRetainingCapacity();
        self.vy.ensureTotalCapacity(self.gpa, self.geo.items.len) catch return;
        var y: usize = 0;
        for (self.geo.items) |g| {
            self.vy.appendAssumeCapacity(y);
            y += g.h + 1; // gap = 1 after every visible card
        }
        self.total_height = y;
    }

    /// Width changed or visible list changed → reset all measured flags
    /// (heights stay as estimates) and rebuild vy from estimates.
    fn invalidateAll(self: *Scrollback) void {
        for (self.geo.items) |*g| g.measured = false;
        self.rebuildVy();
    }

    /// Per-frame entry. Order (review #7): sync → settle → re-pin →
    /// paint window. `measure` runs the exact measurement (markdown
    /// render in measure mode); `estimate` is the cheap fallback when a
    /// slot's geometry is unmeasured at a new width.
    pub fn prepare(
        self: *Scrollback,
        snap: []const cards.CardSlot,
        width: u16,
        viewport_h: usize,
        measure: MeasureFn,
        est: EstimateFn,
    ) PrepareResult {
        self.sync(snap);

        // Geometry parallel to vis: rebuild when the visible list changed.
        if (self.geometry_dirty) {
            self.geo.clearRetainingCapacity();
            self.geo.ensureTotalCapacity(self.gpa, self.vis.items.len) catch return .{ .start = 0, .end = 0, .content_y0 = 0 };
            for (self.vis.items) |si| {
                const slot = &snap[si];
                const assistant = std.mem.startsWith(u8, slot.titleSlice(), "assistant");
                self.geo.appendAssumeCapacity(.{ .h = est(slot, width, assistant), .measured = false });
            }
            self.geometry_dirty = false;
        }
        if (width != self.last_width) {
            self.last_width = width;
            self.invalidateAll();
        }

        // Settle: measure the visible window ± margin exactly, repeat until
        // stable (measured grows monotonically — terminates).
        var guard: usize = self.vis.items.len + 2;
        while (guard > 0) : (guard -= 1) {
            const any = self.settleOnce(snap, width, viewport_h, measure);
            if (!any) break;
        }
        if (guard == 0) {
            // Defensive: force everything measured to guarantee progress.
            for (self.geo.items) |*g| g.measured = true;
        }

        // Re-pin: follow → bottom; else clamp to the valid range.
        if (self.follow_mode) {
            self.scroll_offset = self.maxOffset(viewport_h);
        } else {
            self.scroll_offset = @min(self.scroll_offset, self.maxOffset(viewport_h));
        }

        return self.paintWindow(viewport_h);
    }

    /// One settle pass: measure unmeasured entries in [0, last entry
    /// starting before the viewport bottom + margin). The window starts at
    /// 0 (NOT at the viewport top) so a top-straddling card is never
    /// skipped when its estimate lands exactly on a boundary — the
    /// estimate-overestimate assumption would otherwise leak it. Cost is
    /// bounded by the card ring ceiling (125 slots). Returns whether
    /// anything was newly measured (i.e. vy changed and another pass is
    /// needed).
    fn settleOnce(
        self: *Scrollback,
        snap: []const cards.CardSlot,
        width: u16,
        viewport_h: usize,
        measure: MeasureFn,
    ) bool {
        if (self.vis.items.len == 0) return false;
        var any = false;

        // Last entry starting before the viewport bottom (+ margin).
        const vp_end = self.scroll_offset + viewport_h;
        var end: usize = 0;
        {
            var lo: usize = 0;
            var hi: usize = self.vy.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (self.vy.items[mid] < vp_end) lo = mid + 1 else hi = mid;
            }
            end = @min(lo + measure_margin_entries, self.vis.items.len);
        }

        var i: usize = 0;
        while (i < end) : (i += 1) {
            const g = &self.geo.items[i];
            if (g.measured) continue;
            const slot = &snap[self.vis.items[i]];
            g.h = measure(self.gpa, slot, width);
            g.measured = true;
            any = true;
        }
        if (any) self.rebuildVy();
        return any;
    }

    /// Paint window over the visible list (hyper compute_paint_window port;
    /// no group-header extension). Returns the entry range to draw and the
    /// viewport row where `start` begins (negative = clipped above).
    pub fn paintWindow(self: *const Scrollback, viewport_h: usize) PrepareResult {
        if (self.vis.items.len == 0 or viewport_h == 0)
            return .{ .start = 0, .end = 0, .content_y0 = 0 };

        const vp_start = self.scroll_offset;
        const vp_end = vp_start + viewport_h;

        // First entry whose START is >= vp_start.
        var first_rel: usize = 0;
        {
            var lo: usize = 0;
            var hi: usize = self.vy.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (self.vy.items[mid] < vp_start) lo = mid + 1 else hi = mid;
            }
            first_rel = lo;
        }
        if (first_rel > 0) {
            const prev = first_rel - 1;
            // Strict: an entry ending exactly AT vp_start does not straddle.
            if (self.vy.items[prev] + self.geo.items[prev].h > vp_start) first_rel -= 1;
        }
        const paint_start = first_rel;

        // First entry whose START is >= vp_end.
        var paint_end: usize = 0;
        {
            var lo: usize = 0;
            var hi: usize = self.vy.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (self.vy.items[mid] < vp_end) lo = mid + 1 else hi = mid;
            }
            paint_end = lo;
        }
        if (paint_end < paint_start) paint_end = paint_start;

        const content_y0: i64 = if (paint_start < paint_end)
            @as(i64, @intCast(self.vy.items[paint_start])) - @as(i64, @intCast(vp_start))
        else
            0;
        return .{ .start = paint_start, .end = paint_end, .content_y0 = content_y0 };
    }

    // ── scroll / follow (hyper nav.rs port) ─────────────────────────────────

    pub fn scrollUp(self: *Scrollback, rows: usize) void {
        self.scroll_offset = self.scroll_offset -| rows;
        self.follow_mode = false;
    }

    pub fn scrollDown(self: *Scrollback, rows: usize, viewport_h: usize) void {
        const before = self.scroll_offset;
        const max = self.maxOffset(viewport_h);
        self.scroll_offset = @min(self.scroll_offset +| rows, max);
        // Overscroll at the bottom re-engages follow (hyper
        // follow_by_overscroll): only when the scroll was fully clamped.
        if (rows > 0 and self.scroll_offset == before and self.scroll_offset >= max) {
            self.follow_mode = true;
        }
    }

    pub fn gotoBottom(self: *Scrollback, viewport_h: usize) void {
        self.scroll_offset = self.maxOffset(viewport_h);
        self.follow_mode = true;
    }

    pub fn pageRows(viewport_h: usize) usize {
        if (viewport_h == 0) return 0;
        return @max(viewport_h - 1, 1);
    }

    /// Visible-card slot index for `vis_idx` (paint window indices).
    pub fn slotAt(self: *const Scrollback, vis_idx: usize) u16 {
        return self.vis.items[vis_idx];
    }

    pub fn heightAt(self: *const Scrollback, vis_idx: usize) u16 {
        return self.geo.items[vis_idx].h;
    }
};

/// Estimate-only height: char-ceil over source lines using byte length
/// with a conservative width/2 (UTF-8 CJK ≈ 3 bytes / 2 cells) — no
/// markdown render. Assistant cards render their body flush-left
/// (no title row); user cards add a title row; tool/host_error/drop
/// are single-title rows. The estimate never underestimates the real
/// wrapped row count (every rendered row holds at least width/2 bytes),
/// so lazy-measurement windows never skip a top-straddling card.
pub fn estimateCard(slot: *const cards.CardSlot, content_width: u16, assistant: bool) u16 {
    if (assistant) {
        const half: usize = @max(@max(content_width, 1) / 2, 1);
        const rows = estBody(slot.bodySlice(), half);
        return @intCast(@min(@max(rows, 1), 65535));
    }
    const half: usize = @max(@max(content_width, 1) / 2, 1);
    var rows: u64 = 0;
    switch (slot.kind) {
        .ordinary, .host_error, .drop_note, .terminal => {
            // Single title row (no body rendering).
            rows = 1;
        },
        .user => {
            rows = 1; // `❯ user` title row
            rows += estBody(slot.bodySlice(), half);
        },
    }
    return @intCast(@min(rows, 65535));
}

fn estBody(body: []const u8, half: usize) u64 {
    if (body.len == 0) return 0;
    var rows: u64 = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        rows += @max(1, (line.len + half - 1) / half);
    }
    return rows;
}

// ── fixtures ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fake measure: deterministic exact height from the body byte length
/// (title + ceil(body_len / 10)), independent of width — tests the settle
/// loop without markdown.
fn fakeMeasure(gpa: std.mem.Allocator, slot: *const cards.CardSlot, content_width: u16) u16 {
    _ = gpa;
    _ = content_width;
    const assistant = std.mem.startsWith(u8, slot.titleSlice(), "assistant");
    if (assistant) {
        return @intCast(@max(1, (slot.body_len + 9) / 10));
    }
    var h: u16 = 1;
    if (slot.kind == .user) h += @intCast(@max(0, (slot.body_len + 9) / 10));
    return h;
}

fn fakeEstimate(slot: *const cards.CardSlot, content_width: u16, assistant: bool) u16 {
    _ = content_width;
    if (assistant) return @intCast(@max(1, (slot.body_len + 19) / 20)); // underestimate
    var h: u16 = 1;
    if (slot.kind == .user) h += @intCast(@max(0, (slot.body_len + 19) / 20));
    return h;
}

/// Build a snapshot of N ordinary cards with deterministic body lengths.
fn fakeSnap(n: usize, body_len: u16, kind: cards.CardKind, ui_seq_base: u64) [c.card_slots]cards.CardSlot {
    var snap: [c.card_slots]cards.CardSlot = [_]cards.CardSlot{.{}} ** c.card_slots;
    var i: usize = 0;
    while (i < n and i < c.ordinary_card_slots) : (i += 1) {
        snap[i] = .{
            .kind = kind,
            .occupied = true,
            .title_len = 9,
            .body_len = body_len,
            .ui_seq = ui_seq_base + @as(u64, @intCast(i + 1)),
        };
        @memcpy(snap[i].title[0..9], "assistant");
        @memset(snap[i].body[0..body_len], 'x');
    }
    return snap;
}

test "scrollback: virtual_y cumulative with gaps" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(3, 10, .ordinary, 100); // assistant: exact = ceil(10/10) = 1 row each
    sb.sync(&snap);
    // Estimate pass then settle: all three measured (they fit in any window).
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 3), sb.vis.items.len);
    // vy[0]=0, h=1, gap=1 → vy[1]=2, vy[2]=4; total = 4+1+1 = 6.
    try testing.expectEqual(@as(usize, 0), sb.vy.items[0]);
    try testing.expectEqual(@as(usize, 2), sb.vy.items[1]);
    try testing.expectEqual(@as(usize, 4), sb.vy.items[2]);
    try testing.expectEqual(@as(usize, 6), sb.total_height);
}

test "scrollback: paintWindow empty + zero-viewport" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap: [c.card_slots]cards.CardSlot = [_]cards.CardSlot{.{}} ** c.card_slots;
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 0), pw.start);
    try testing.expectEqual(@as(usize, 0), pw.end);
    const pw0 = sb.paintWindow(0);
    try testing.expectEqual(@as(usize, 0), pw0.end);
}

test "scrollback: paintWindow scroll 0 shows the head" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(2, 10, .ordinary, 100); // 1 row each + gap = 4 total
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    sb.scroll_offset = 0;
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 0), pw.start);
    try testing.expectEqual(@as(usize, 2), pw.end);
    try testing.expectEqual(@as(i64, 0), pw.content_y0);
}

test "scrollback: paintWindow mid-history straddle back-off" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    // 3 cards of 3 rows each (body 30): vy = [0, 4, 8], total = 12.
    var snap = fakeSnap(3, 30, .ordinary, 100);
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 12), sb.total_height);
    // Offset 5 → vp_start=5 lands inside card 1 (vy=4, h=3 → rows 4,5,6).
    sb.scroll_offset = 5;
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 1), pw.start); // back off to the straddler
    try testing.expectEqual(@as(usize, 3), pw.end);
    try testing.expectEqual(@as(i64, -1), pw.content_y0); // card 1's row 1 shows at viewport row 0
}

test "scrollback: paintWindow exact boundary does NOT back off" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(3, 30, .ordinary, 100); // vy = [0, 4, 8]
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    // Offset 4 = exactly card 1's start → no back-off.
    sb.scroll_offset = 4;
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 1), pw.start);
    try testing.expectEqual(@as(i64, 0), pw.content_y0);
}

test "scrollback: paintWindow gap landing yields blank top row" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(3, 30, .ordinary, 100); // vy = [0, 4, 8]; gap row at 3
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    sb.scroll_offset = 3; // lands in card 0's gap
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 1), pw.start); // card 0 ends at 3 → not > 3
    try testing.expectEqual(@as(i64, 1), pw.content_y0); // blank row 0
    try testing.expectEqual(@as(usize, 3), pw.end);
}

test "scrollback: paintWindow bottom window" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(3, 30, .ordinary, 100); // total = 12
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    sb.scroll_offset = 8; // last card start
    const pw = sb.paintWindow(20);
    try testing.expectEqual(@as(usize, 2), pw.start);
    try testing.expectEqual(@as(usize, 3), pw.end);
    try testing.expectEqual(@as(i64, 0), pw.content_y0);
}

test "scrollback: lazy measurement measures only the window ± margin" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    // 125 cards × 3 rows = 500 total; viewport 10 → the bottom window
    // measures; far-from-bottom cards stay estimates until scrolled into
    // range. (Window starts at 0, ends at vp_bottom + margin.)
    var snap = fakeSnap(125, 30, .ordinary, 100);
    _ = sb.prepare(&snap, 80, 10, fakeMeasure, fakeEstimate);
    var measured: usize = 0;
    for (sb.geo.items) |g| {
        if (g.measured) measured += 1;
    }
    try testing.expect(measured < 125); // far-top cards unmeasured
    // Scroll to the top: the top window gets measured; the far-bottom
    // cards (past vp_end + margin) remain estimates.
    sb.scrollUp(1000);
    _ = sb.prepare(&snap, 80, 10, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 0), sb.scroll_offset);
    measured = 0;
    for (sb.geo.items) |g| {
        if (g.measured) measured += 1;
    }
    try testing.expect(measured < 125); // bottom far cards still unmeasured
    try testing.expect(measured > 0);
    // Scrolling through the middle settles the newly revealed cards.
    sb.scrollDown(1000, 10); // two-step overscroll → follow
    sb.scrollDown(1000, 10);
    _ = sb.prepare(&snap, 80, 10, fakeMeasure, fakeEstimate);
    for (sb.geo.items) |g| try testing.expect(g.measured); // follow → bottom window covers all
}

test "scrollback: estimate vs exact converge through settle" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(2, 30, .ordinary, 100); // exact 3 rows; estimate 2 rows
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    // After settle, geometry is exact: vy[1] = 3 + 1 = 4.
    try testing.expectEqual(@as(usize, 4), sb.vy.items[1]);
    try testing.expectEqual(@as(usize, 8), sb.total_height);
    // All measured.
    for (sb.geo.items) |g| try testing.expect(g.measured);
}

test "scrollback: follow stays at bottom on new content" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(2, 30, .ordinary, 100); // total = 8
    _ = sb.prepare(&snap, 80, 6, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 2), sb.scroll_offset); // follow → max(8-6)
    // New card arrives.
    var snap2 = fakeSnap(3, 30, .ordinary, 100); // total = 12
    _ = sb.prepare(&snap2, 80, 6, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 6), sb.scroll_offset); // auto-follow to new bottom
}

test "scrollback: manual scroll up leaves follow; overscroll re-engages" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(5, 30, .ordinary, 100); // total = 20
    _ = sb.prepare(&snap, 80, 10, fakeMeasure, fakeEstimate);
    try testing.expect(sb.follow_mode);
    sb.scrollUp(5);
    try testing.expect(!sb.follow_mode);
    try testing.expectEqual(@as(usize, 5), sb.scroll_offset);
    // New content while scrolled up: offset unchanged (no jump).
    var snap2 = fakeSnap(6, 30, .ordinary, 100);
    _ = sb.prepare(&snap2, 80, 10, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 5), sb.scroll_offset);
    // Overscroll at bottom re-engages: the first scroll lands at max
    // (offset moved, no re-engage); the next fully-clamped scroll does.
    sb.scrollDown(1000, 10);
    try testing.expect(!sb.follow_mode);
    sb.scrollDown(1000, 10);
    try testing.expect(sb.follow_mode);
    try testing.expectEqual(@as(usize, 14), sb.scroll_offset); // max(24-10)
}

test "scrollback: terminal cards invisible (no rows)" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap: [c.card_slots]cards.CardSlot = [_]cards.CardSlot{.{}} ** c.card_slots;
    snap[0] = .{ .kind = .ordinary, .occupied = true, .title_len = 9, .body_len = 30, .ui_seq = 1 };
    @memcpy(snap[0].title[0..9], "assistant");
    @memset(snap[0].body[0..30], 'x');
    snap[1] = .{ .kind = .terminal, .occupied = true, .title_len = 12, .body_len = 0, .ui_seq = 2 };
    @memcpy(snap[1].title[0..12], "run_terminal");
    snap[2] = .{ .kind = .ordinary, .occupied = true, .title_len = 9, .body_len = 30, .ui_seq = 3 };
    @memcpy(snap[2].title[0..9], "assistant");
    @memset(snap[2].body[0..30], 'x');
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 2), sb.vis.items.len);
    try testing.expectEqual(@as(usize, 0), sb.vis.items[0]);
    try testing.expectEqual(@as(usize, 2), sb.vis.items[1]);
    // Gaps only between visible cards: total = 3 + 1 + 3 + 1 = 8.
    try testing.expectEqual(@as(usize, 8), sb.total_height);
}

test "scrollback: ring wrap — earliest changed = 0 rebuilds O(n)" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(3, 30, .ordinary, 100);
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    // Card 0 replaced (new ui_seq) — geometry_dirty via sync.
    snap[0].ui_seq = 999;
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    try testing.expectEqual(@as(usize, 3), sb.vis.items.len);
    // Height unchanged (same body_len) but cache now reflects the new seq.
    try testing.expectEqual(@as(usize, 12), sb.total_height);
}

test "scrollback: width change invalidates all measurements" {
    const gpa = testing.allocator;
    var sb = Scrollback.init(gpa);
    defer sb.deinit();
    var snap = fakeSnap(2, 30, .ordinary, 100);
    _ = sb.prepare(&snap, 80, 20, fakeMeasure, fakeEstimate);
    for (sb.geo.items) |g| try testing.expect(g.measured);
    // Width change → all unmeasured → settle re-measures visible.
    _ = sb.prepare(&snap, 40, 20, fakeMeasure, fakeEstimate);
    for (sb.geo.items) |g| try testing.expect(g.measured);
    try testing.expectEqual(@as(usize, 8), sb.total_height); // fake measure is width-independent
}

test "scrollback: pageRows clamps to 1" {
    try testing.expectEqual(@as(usize, 1), Scrollback.pageRows(1));
    try testing.expectEqual(@as(usize, 0), Scrollback.pageRows(0));
    try testing.expectEqual(@as(usize, 19), Scrollback.pageRows(20));
}
