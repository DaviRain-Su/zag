//! Preallocated 128-slot card ring with terminal/host-error reserves.
//!
//! Lock law: redactAlloc / UTF-8 / truncate / O(n) work **outside** the spin
//! lock. Under lock: fixed memcpy, length fields, FIFO bookkeeping, ui_seq only.

const std = @import("std");
const c = @import("constants.zig");
const present = @import("present.zig");
const coding = @import("zag-coding-agent");

pub const CardKind = enum {
    ordinary,
    user,
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

/// Prepared card bytes after redaction/UTF-8/truncation (stack-owned).
pub const PreparedCard = struct {
    title: [c.card_title_max_bytes]u8 = undefined,
    title_len: u16 = 0,
    body: [c.card_body_max_bytes]u8 = undefined,
    body_len: u16 = 0,

    pub fn fromSources(
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        title_src: []const u8,
        body_src: []const u8,
    ) PreparedCard {
        var out: PreparedCard = .{};
        out.title_len = @intCast(present.presentInto(gpa, redactor, &out.title, title_src));
        out.body_len = @intCast(present.presentInto(gpa, redactor, &out.body, body_src));
        return out;
    }

    pub fn fromFixed(title: []const u8, body: []const u8) PreparedCard {
        var out: PreparedCard = .{};
        out.title_len = @intCast(present.copyTruncated(&out.title, title));
        out.body_len = @intCast(present.copyTruncated(&out.body, body));
        return out;
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
    ordinary_start: usize = 0,
    cards_dropped: u32 = 0,
    ui_seq: u64 = 0,
    mu: std.atomic.Mutex = .unlocked,

    pub const ordinary_end: usize = c.ordinary_card_slots;
    pub const terminal_idx: usize = c.ordinary_card_slots;
    pub const host_error_idx: usize = c.ordinary_card_slots + 1;
    pub const drop_note_idx: usize = c.ordinary_card_slots + 2;

    pub fn init() CardRing {
        return .{};
    }

    fn lock(self: *CardRing) void {
        while (!self.mu.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *CardRing) void {
        self.mu.unlock();
    }

    /// Redact outside lock, then publish prepared bytes under lock.
    pub fn publishOrdinary(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        title_src: []const u8,
        body_src: []const u8,
    ) void {
        const prepared = PreparedCard.fromSources(gpa, redactor, title_src, body_src);
        self.publishOrdinaryPrepared(prepared);
    }

    pub fn publishOrdinaryPrepared(self: *CardRing, prepared: PreparedCard) void {
        self.publishKindPrepared(.ordinary, prepared);
    }

    /// User prompt card (tui-polish follow-up): the submitted input shows in
    /// the transcript paired with the assistant reply that follows.
    pub fn publishUser(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        body_src: []const u8,
    ) void {
        const prepared = PreparedCard.fromSources(gpa, redactor, "user", body_src);
        self.publishKindPrepared(.user, prepared);
    }

    fn publishKindPrepared(self: *CardRing, kind: CardKind, prepared: PreparedCard) void {
        self.lock();
        defer self.unlock();

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
        self.writePreparedLocked(idx, kind, prepared);
        self.ordinary_count += 1;
    }

    /// Replace the newest ordinary card whose title starts with `title_prefix`
    /// (used for assistant full-body snapshot). If none, publishes new ordinary.
    pub fn replaceNewestOrdinaryTitlePrefix(
        self: *CardRing,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        title_prefix: []const u8,
        title_src: []const u8,
        body_src: []const u8,
    ) void {
        const prepared = PreparedCard.fromSources(gpa, redactor, title_src, body_src);
        self.lock();
        defer self.unlock();

        var i: usize = self.ordinary_count;
        while (i > 0) {
            i -= 1;
            const idx = (self.ordinary_start + i) % ordinary_end;
            const slot = &self.slots[idx];
            if (slot.occupied and std.mem.startsWith(u8, slot.titleSlice(), title_prefix)) {
                self.ui_seq += 1;
                self.writePreparedLocked(idx, .ordinary, prepared);
                return;
            }
        }
        // No match — unlock not needed; still holding lock, publish new.
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
        self.writePreparedLocked(idx, .ordinary, prepared);
        self.ordinary_count += 1;
    }

    /// Remove the newest ordinary card whose title starts with `title_prefix`
    /// (tui-thinking-streaming-001: a turn that completes without reasoning
    /// drops its progressive thinking card). Newer cards shift down one slot
    /// so the FIFO stays dense. Returns true when a card was removed.
    pub fn removeNewestOrdinaryTitlePrefix(self: *CardRing, title_prefix: []const u8) bool {
        self.lock();
        defer self.unlock();
        var i: usize = self.ordinary_count;
        while (i > 0) {
            i -= 1;
            const idx = (self.ordinary_start + i) % ordinary_end;
            if (self.slots[idx].occupied and std.mem.startsWith(u8, self.slots[idx].titleSlice(), title_prefix)) {
                var j: usize = i;
                while (j + 1 < self.ordinary_count) : (j += 1) {
                    const cur = (self.ordinary_start + j) % ordinary_end;
                    const nxt = (self.ordinary_start + j + 1) % ordinary_end;
                    self.slots[cur] = self.slots[nxt];
                }
                const last = (self.ordinary_start + self.ordinary_count - 1) % ordinary_end;
                self.slots[last].occupied = false;
                self.ordinary_count -= 1;
                self.ui_seq += 1;
                return true;
            }
        }
        return false;
    }

    /// Allocation-free terminal reserve (numeric/enum fixed fields only).
    pub fn publishTerminalFixed(self: *CardRing, title: []const u8, body: []const u8) void {
        // Fixed codes — copyTruncated is O(n) but n ≤ fixed small; no heap/redact.
        // Still prepare outside lock for consistency.
        const prepared = PreparedCard.fromFixed(title, body);
        self.lock();
        defer self.unlock();
        self.ui_seq += 1;
        self.writePreparedLocked(terminal_idx, .terminal, prepared);
    }

    pub fn demoteTerminalToOrdinary(self: *CardRing) void {
        // Copy terminal bytes to stack under lock briefly, then re-publish as ordinary.
        var title_copy: [c.card_title_max_bytes]u8 = undefined;
        var body_copy: [c.card_body_max_bytes]u8 = undefined;
        var title_len: u16 = 0;
        var body_len: u16 = 0;
        var had = false;

        self.lock();
        const term = &self.slots[terminal_idx];
        if (term.occupied) {
            had = true;
            title_len = term.title_len;
            body_len = term.body_len;
            @memcpy(title_copy[0..title_len], term.title[0..title_len]);
            @memcpy(body_copy[0..body_len], term.body[0..body_len]);
            term.occupied = false;
        }
        self.unlock();

        if (!had) return;
        var prepared: PreparedCard = .{};
        prepared.title_len = title_len;
        prepared.body_len = body_len;
        @memcpy(prepared.title[0..title_len], title_copy[0..title_len]);
        @memcpy(prepared.body[0..body_len], body_copy[0..body_len]);
        self.publishOrdinaryPrepared(prepared);
    }

    pub fn publishHostErrorFixed(self: *CardRing, title: []const u8, body: []const u8) void {
        const prepared = PreparedCard.fromFixed(title, body);
        self.lock();
        defer self.unlock();
        self.ui_seq += 1;
        self.writePreparedLocked(host_error_idx, .host_error, prepared);
    }

    pub fn snapshotSeq(self: *CardRing) u64 {
        self.lock();
        defer self.unlock();
        return self.ui_seq;
    }

    pub fn snapshot(self: *CardRing, out: []CardSlot) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
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
        // Fixed numeric only — format into stack then fixed copy under lock is OK
        // (tiny fixed buffer, no redactAlloc). Prefer prepare path for consistency:
        var body_buf: [32]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "cards_dropped={d}", .{self.cards_dropped}) catch "cards_dropped=?";
        const prepared = PreparedCard.fromFixed("drop", body);
        self.writePreparedLocked(drop_note_idx, .drop_note, prepared);
    }

    fn writePreparedLocked(self: *CardRing, idx: usize, kind: CardKind, prepared: PreparedCard) void {
        var slot = &self.slots[idx];
        slot.kind = kind;
        slot.occupied = true;
        slot.ui_seq = self.ui_seq;
        slot.title_len = prepared.title_len;
        slot.body_len = prepared.body_len;
        if (prepared.title_len > 0) {
            @memcpy(slot.title[0..prepared.title_len], prepared.title[0..prepared.title_len]);
        }
        if (prepared.body_len > 0) {
            @memcpy(slot.body[0..prepared.body_len], prepared.body[0..prepared.body_len]);
        }
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

test "publishOrdinary redacts outside lock (secret not stored raw)" {
    const gpa = std.testing.allocator;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    var ring = CardRing.init();
    ring.publishOrdinary(gpa, &r, "title", "hold " ++ secret);
    try std.testing.expect(std.mem.indexOf(u8, ring.slots[0].bodySlice(), secret) == null);
}
