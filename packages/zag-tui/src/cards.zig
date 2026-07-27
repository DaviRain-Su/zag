//! Preallocated 128-slot card ring with terminal/host-error reserves.

const std = @import("std");
const c = @import("constants.zig");
const present = @import("present.zig");
const coding = @import("zag-coding-agent");

pub const CardKind = enum {
    ordinary,
    terminal,
    host_error,
    drop_note,
};

pub const CardSlot = struct {
    kind: CardKind = .ordinary,
    occupied: bool = false,
    title_len: u16 = 0,
    body_len: u16 = 0,
    title: [c.card_title_max_bytes]u8 = undefined,
    body: [c.card_body_max_bytes]u8 = undefined,
    ui_seq: u64 = 0,

    pub fn titleSlice(self: *const CardSlot) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn bodySlice(self: *const CardSlot) []const u8 {
        return self.body[0..self.body_len];
    }
};

/// Ring layout:
/// [0..125) ordinary FIFO
/// [125] terminal reserve
/// [126] host-error reserve
/// [127] drop-note (virtual; not part of ordinary drop recursion)
pub const CardRing = struct {
    slots: [c.card_slots]CardSlot = [_]CardSlot{.{}} ** c.card_slots,
    ordinary_count: usize = 0,
    /// Index of oldest ordinary when ring is wrapping; FIFO over 0..124.
    ordinary_start: usize = 0,
    cards_dropped: u32 = 0,
    ui_seq: u64 = 0,
    /// Short critical sections only — spin (same pattern as control_queue).
    mu: std.atomic.Mutex = .unlocked,

    pub const ordinary_end: usize = c.ordinary_card_slots;
    pub const terminal_idx: usize = c.ordinary_card_slots;
    pub const host_error_idx: usize = c.ordinary_card_slots + 1;
    pub const drop_note_idx: usize = c.ordinary_card_slots + 2;

    pub fn init() CardRing {
        return .{};
    }

    fn lock(self: *CardRing) void {
        while (!self.mu.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *CardRing) void {
        self.mu.unlock();
    }

    /// Publish ordinary card under lock. Drops oldest ordinary when full.
    pub fn publishOrdinary(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        title_src: []const u8,
        body_src: []const u8,
    ) void {
        self.lock();
        defer self.unlock();

        if (self.ordinary_count == ordinary_end) {
            // Drop oldest ordinary.
            const drop_i = self.ordinary_start;
            self.slots[drop_i].occupied = false;
            self.ordinary_start = (self.ordinary_start + 1) % ordinary_end;
            self.ordinary_count -= 1;
            if (self.cards_dropped < std.math.maxInt(u32)) self.cards_dropped += 1;
            self.refreshDropNoteLocked();
        }

        const idx = (self.ordinary_start + self.ordinary_count) % ordinary_end;
        self.ui_seq += 1;
        self.fillSlotLocked(gpa, redactor, idx, .ordinary, title_src, body_src);
        self.ordinary_count += 1;
    }

    /// Allocation-free terminal reserve (numeric/enum fixed fields only — caller formats).
    pub fn publishTerminalFixed(self: *CardRing, title: []const u8, body: []const u8) void {
        self.lock();
        defer self.unlock();
        self.ui_seq += 1;
        self.fillFixedLocked(terminal_idx, .terminal, title, body);
    }

    pub fn demoteTerminalToOrdinary(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
    ) void {
        self.lock();
        defer self.unlock();
        const term = &self.slots[terminal_idx];
        if (!term.occupied) return;
        // Copy fixed bytes into ordinary without re-redacting (already fixed).
        const title = term.titleSlice();
        const body = term.bodySlice();
        term.occupied = false;
        // Manually push as ordinary without redaction (already numeric/fixed).
        if (self.ordinary_count == ordinary_end) {
            const drop_i = self.ordinary_start;
            self.slots[drop_i].occupied = false;
            self.ordinary_start = (self.ordinary_start + 1) % ordinary_end;
            self.ordinary_count -= 1;
            if (self.cards_dropped < std.math.maxInt(u32)) self.cards_dropped += 1;
            self.refreshDropNoteLocked();
        }
        const idx = (self.ordinary_start + self.ordinary_count) % ordinary_end;
        self.ui_seq += 1;
        self.fillFixedLocked(idx, .ordinary, title, body);
        self.ordinary_count += 1;
        _ = gpa;
        _ = redactor;
    }

    pub fn publishHostErrorFixed(self: *CardRing, title: []const u8, body: []const u8) void {
        self.lock();
        defer self.unlock();
        self.ui_seq += 1;
        self.fillFixedLocked(host_error_idx, .host_error, title, body);
    }

    pub fn snapshotSeq(self: *CardRing) u64 {
        self.lock();
        defer self.unlock();
        return self.ui_seq;
    }

    /// Copy visible cards newest-last into out (bounded). Returns count.
    pub fn snapshot(self: *CardRing, out: []CardSlot) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        // Ordinary FIFO oldest→newest
        var i: usize = 0;
        while (i < self.ordinary_count and n < out.len) : (i += 1) {
            const idx = (self.ordinary_start + i) % ordinary_end;
            if (self.slots[idx].occupied) {
                out[n] = self.slots[idx];
                n += 1;
            }
        }
        if (self.slots[drop_note_idx].occupied and n < out.len) {
            out[n] = self.slots[drop_note_idx];
            n += 1;
        }
        if (self.slots[terminal_idx].occupied and n < out.len) {
            out[n] = self.slots[terminal_idx];
            n += 1;
        }
        if (self.slots[host_error_idx].occupied and n < out.len) {
            out[n] = self.slots[host_error_idx];
            n += 1;
        }
        return n;
    }

    fn refreshDropNoteLocked(self: *CardRing) void {
        var body_buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "cards_dropped={d}", .{self.cards_dropped}) catch "cards_dropped=?";
        self.fillFixedLocked(drop_note_idx, .drop_note, "drop", body);
    }

    fn fillSlotLocked(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        idx: usize,
        kind: CardKind,
        title_src: []const u8,
        body_src: []const u8,
    ) void {
        var slot = &self.slots[idx];
        slot.kind = kind;
        slot.occupied = true;
        slot.ui_seq = self.ui_seq;
        slot.title_len = @intCast(present.presentInto(gpa, redactor, &slot.title, title_src));
        slot.body_len = @intCast(present.presentInto(gpa, redactor, &slot.body, body_src));
    }

    fn fillFixedLocked(
        self: *CardRing,
        idx: usize,
        kind: CardKind,
        title: []const u8,
        body: []const u8,
    ) void {
        var slot = &self.slots[idx];
        slot.kind = kind;
        slot.occupied = true;
        slot.ui_seq = self.ui_seq;
        // Fixed codes only — no redaction heap; still cap with exact marker rules.
        slot.title_len = @intCast(present.copyTruncated(&slot.title, title));
        slot.body_len = @intCast(present.copyTruncated(&slot.body, body));
    }
};

test "card ring FIFO drop saturating nonrecursive" {
    var ring = CardRing.init();
    const gpa = std.testing.allocator;
    var i: usize = 0;
    while (i < c.ordinary_card_slots + 3) : (i += 1) {
        var title_buf: [32]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "t{d}", .{i});
        ring.publishOrdinary(gpa, null, title, "body");
    }
    try std.testing.expectEqual(@as(usize, c.ordinary_card_slots), ring.ordinary_count);
    try std.testing.expectEqual(@as(u32, 3), ring.cards_dropped);
    // Drop note exists and is not consuming ordinary FIFO recursively.
    try std.testing.expect(ring.slots[CardRing.drop_note_idx].occupied);
    const note = ring.slots[CardRing.drop_note_idx].bodySlice();
    try std.testing.expectEqualStrings("cards_dropped=3", note);
}

test "terminal reserve retained under ordinary flood" {
    var ring = CardRing.init();
    const gpa = std.testing.allocator;
    ring.publishTerminalFixed("run_terminal", "ok=true stop=completed turns=1");
    var i: usize = 0;
    while (i < c.ordinary_card_slots + 10) : (i += 1) {
        ring.publishOrdinary(gpa, null, "x", "y");
    }
    try std.testing.expect(ring.slots[CardRing.terminal_idx].occupied);
    try std.testing.expectEqualStrings("run_terminal", ring.slots[CardRing.terminal_idx].titleSlice());
}
