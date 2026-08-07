//! Session-owned bounded control queues (harness-steering-001).
//!
//! Two fixed preallocated FIFO queues (steering + follow-up), each with capacity
//! 4 and 4096-byte slots. Enqueue copies input without allocation. Peek/commit
//! for Core's borrowed `ControlInput` run under one mutex for atomic boundary
//! selection (steering priority at would-complete).
//!
//! Thread claim is narrow: enqueue and pending-count may run on one foreign
//! thread while a single reply consumes. clear/deinit are idle-only.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zag-agent-core");
const control_input = core.control_input;

pub const capacity: usize = 4;
pub const message_max_bytes: usize = 4096;

pub const ControlError = error{
    QueueFull,
    MessageTooLong,
    EmptyMessage,
    InvalidUtf8,
};

pub const Kind = control_input.Kind;
pub const Boundary = control_input.Boundary;
pub const Item = control_input.Item;

/// One fixed ring of `capacity` slots × `message_max_bytes` bytes.
const FixedQueue = struct {
    /// Owned contiguous backing: capacity * message_max_bytes.
    backing: []u8,
    lens: [capacity]usize = .{0} ** capacity,
    head: usize = 0,
    count: usize = 0,

    fn init(gpa: std.mem.Allocator) error{OutOfMemory}!FixedQueue {
        const backing = try gpa.alloc(u8, capacity * message_max_bytes);
        @memset(backing, 0);
        return .{ .backing = backing };
    }

    fn deinit(self: *FixedQueue, gpa: std.mem.Allocator) void {
        gpa.free(self.backing);
        self.* = undefined;
    }

    fn clear(self: *FixedQueue) void {
        self.head = 0;
        self.count = 0;
        @memset(&self.lens, 0);
    }

    fn pending(self: *const FixedQueue) usize {
        return self.count;
    }

    fn slotSlice(self: *FixedQueue, index: usize) []u8 {
        const off = index * message_max_bytes;
        return self.backing[off..][0..message_max_bytes];
    }

    fn headText(self: *const FixedQueue) ?[]const u8 {
        if (self.count == 0) return null;
        const len = self.lens[self.head];
        const off = self.head * message_max_bytes;
        return self.backing[off..][0..len];
    }

    /// Copy `text` into the next free slot. No allocation.
    fn enqueue(self: *FixedQueue, text: []const u8) ControlError!void {
        if (text.len == 0) return error.EmptyMessage;
        if (text.len > message_max_bytes) return error.MessageTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (self.count >= capacity) return error.QueueFull;

        const idx = (self.head + self.count) % capacity;
        const slot = self.slotSlice(idx);
        @memcpy(slot[0..text.len], text);
        self.lens[idx] = text.len;
        self.count += 1;
    }

    fn popHead(self: *FixedQueue) void {
        std.debug.assert(self.count > 0);
        self.lens[self.head] = 0;
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
    }
};

/// Dual queues + shared spin mutex. 32 KiB text backing total (2 × 4 × 4096).
/// Zig 0.16: `std.Io.Mutex` needs Io/cancel; critical sections are short copies
/// so a spin on `std.atomic.Mutex` is the right no-alloc, no-Io choice.
pub const DualQueues = struct {
    mu: std.atomic.Mutex = .unlocked,
    steering: FixedQueue,
    follow_up: FixedQueue,

    fn lock(self: *DualQueues) void {
        while (!self.mu.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *DualQueues) void {
        self.mu.unlock();
    }

    /// Preallocate both backings. Call before create/resume I/O or writer lease.
    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!DualQueues {
        var steering = try FixedQueue.init(gpa);
        errdefer steering.deinit(gpa);
        const follow_up = try FixedQueue.init(gpa);
        return .{
            .steering = steering,
            .follow_up = follow_up,
        };
    }

    pub fn deinit(self: *DualQueues, gpa: std.mem.Allocator) void {
        // Idle-only by contract; no lock (host externally synchronizes).
        self.steering.deinit(gpa);
        self.follow_up.deinit(gpa);
        self.* = undefined;
    }

    /// Idle-only: discard pending process-memory items.
    pub fn clear(self: *DualQueues) void {
        self.lock();
        defer self.unlock();
        self.steering.clear();
        self.follow_up.clear();
    }

    pub fn enqueueSteering(self: *DualQueues, text: []const u8) ControlError!void {
        self.lock();
        defer self.unlock();
        return self.steering.enqueue(text);
    }

    pub fn enqueueFollowUp(self: *DualQueues, text: []const u8) ControlError!void {
        self.lock();
        defer self.unlock();
        return self.follow_up.enqueue(text);
    }

    pub fn steeringPending(self: *DualQueues) usize {
        self.lock();
        defer self.unlock();
        return self.steering.pending();
    }

    pub fn followUpPending(self: *DualQueues) usize {
        self.lock();
        defer self.unlock();
        return self.follow_up.pending();
    }

    /// Copy pending control messages for the TUI (harness-steering-001 queue
    /// pane). Order: steering FIFO first, then follow_up FIFO. Each entry's
    /// kind is written to `out_kinds[i]` and up to `text_bufs[i].len` bytes of
    /// its text (UTF-8, already validated at enqueue) to `text_bufs[i]`; the
    /// actual byte count goes to `out_lens[i]`. Returns the number of entries
    /// copied = min of the three slice lengths (callers cap at 8 = 4+4).
    /// Thread-safe: locks `mu` for the whole copy, so the TUI can paint
    /// without holding the lock across the render pass. No allocation.
    pub fn copyPending(
        self: *DualQueues,
        out_kinds: []Kind,
        text_bufs: [][128]u8, // UI preview cap 128 is fine
        out_lens: []usize,
    ) usize {
        self.lock();
        defer self.unlock();
        const n = @min(@min(out_kinds.len, text_bufs.len), out_lens.len);
        var count: usize = 0;
        while (count < n and count < self.steering.count) : (count += 1) {
            const idx = (self.steering.head + count) % capacity;
            const len = self.steering.lens[idx];
            const src = self.steering.backing[idx * message_max_bytes ..][0..len];
            out_kinds[count] = .steering;
            const cap = @min(text_bufs[count].len, src.len);
            @memcpy(text_bufs[count][0..cap], src[0..cap]);
            out_lens[count] = cap;
        }
        var fcount: usize = 0;
        while (count < n and fcount < self.follow_up.count) : (fcount += 1) {
            const idx = (self.follow_up.head + fcount) % capacity;
            const len = self.follow_up.lens[idx];
            const src = self.follow_up.backing[idx * message_max_bytes ..][0..len];
            out_kinds[count] = .follow_up;
            const cap = @min(text_bufs[count].len, src.len);
            @memcpy(text_bufs[count][0..cap], src[0..cap]);
            out_lens[count] = cap;
            count += 1;
        }
        return count;
    }

    /// Atomic boundary selection under one lock (Core ControlInput.peek).
    pub fn peek(self: *DualQueues, boundary: Boundary) ?Item {
        self.lock();
        defer self.unlock();
        switch (boundary) {
            .pre_turn, .between_tools => {
                if (self.steering.headText()) |t| {
                    return .{ .kind = .steering, .text = t };
                }
                return null;
            },
            .would_complete => {
                if (self.steering.headText()) |t| {
                    return .{ .kind = .steering, .text = t };
                }
                if (self.follow_up.headText()) |t| {
                    return .{ .kind = .follow_up, .text = t };
                }
                return null;
            },
        }
    }

    /// Remove current head of `kind`. Debug-assert matching head exists.
    pub fn commit(self: *DualQueues, kind: Kind) void {
        self.lock();
        defer self.unlock();
        switch (kind) {
            .steering => {
                if (builtin.mode == .Debug) {
                    std.debug.assert(self.steering.count > 0);
                }
                self.steering.popHead();
            },
            .follow_up => {
                if (builtin.mode == .Debug) {
                    std.debug.assert(self.follow_up.count > 0);
                }
                self.follow_up.popHead();
            },
        }
    }

    pub fn asControlInput(self: *DualQueues) control_input.ControlInput {
        return .{
            .ptr = self,
            .vtable = &control_vtable,
        };
    }
};

const control_vtable: control_input.ControlInputVTable = .{
    .peek = dualPeek,
    .commit = dualCommit,
};

fn dualPeek(ptr: ?*anyopaque, boundary: Boundary) ?Item {
    const self: *DualQueues = @ptrCast(@alignCast(ptr.?));
    return self.peek(boundary);
}

fn dualCommit(ptr: ?*anyopaque, kind: Kind) void {
    const self: *DualQueues = @ptrCast(@alignCast(ptr.?));
    self.commit(kind);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "control_queue capacity FIFO and typed errors" {
    const gpa = std.testing.allocator;
    var q = try DualQueues.init(gpa);
    defer q.deinit(gpa);

    try std.testing.expectError(error.EmptyMessage, q.enqueueSteering(""));
    try std.testing.expectError(error.EmptyMessage, q.enqueueFollowUp(""));
    // Non-empty whitespace accepted unchanged.
    try q.enqueueSteering("  ");
    try std.testing.expectEqual(@as(usize, 1), q.steeringPending());
    try std.testing.expectEqualStrings("  ", q.peek(.pre_turn).?.text);

    const too_long = [_]u8{'x'} ** (message_max_bytes + 1);
    try std.testing.expectError(error.MessageTooLong, q.enqueueSteering(&too_long));

    // Invalid UTF-8
    try std.testing.expectError(error.InvalidUtf8, q.enqueueSteering(&[_]u8{ 0xff, 0xfe }));

    // Independent capacities
    try q.enqueueFollowUp("f1");
    try q.enqueueFollowUp("f2");
    try std.testing.expectEqual(@as(usize, 1), q.steeringPending());
    try std.testing.expectEqual(@as(usize, 2), q.followUpPending());

    // Fill remaining steering slots (1 already used).
    try q.enqueueSteering("s2");
    try q.enqueueSteering("s3");
    try q.enqueueSteering("s4");
    try std.testing.expectError(error.QueueFull, q.enqueueSteering("s5"));
    try std.testing.expectEqual(@as(usize, 4), q.steeringPending());

    // FIFO commit
    q.commit(.steering);
    try std.testing.expectEqualStrings("s2", q.peek(.pre_turn).?.text);
    try std.testing.expectEqual(@as(usize, 3), q.steeringPending());

    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), q.followUpPending());
}

test "control_queue would_complete steering priority under lock" {
    const gpa = std.testing.allocator;
    var q = try DualQueues.init(gpa);
    defer q.deinit(gpa);

    try q.enqueueFollowUp("follow");
    try q.enqueueSteering("steer");
    const item = q.peek(.would_complete).?;
    try std.testing.expectEqual(Kind.steering, item.kind);
    try std.testing.expectEqualStrings("steer", item.text);
    q.commit(.steering);
    const next = q.peek(.would_complete).?;
    try std.testing.expectEqual(Kind.follow_up, next.kind);
}

test "control_queue copyPending steering then follow_up FIFO" {
    const gpa = std.testing.allocator;
    var q = try DualQueues.init(gpa);
    defer q.deinit(gpa);

    // Interleaved enqueue: steering FIFO must come out first, then follow_up.
    try q.enqueueSteering("s1");
    try q.enqueueFollowUp("f1");
    try q.enqueueSteering("s2");
    try q.enqueueFollowUp("f2");

    var kinds: [8]Kind = undefined;
    var bufs: [8][128]u8 = undefined;
    var lens: [8]usize = undefined;
    const n = q.copyPending(&kinds, &bufs, &lens);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(Kind.steering, kinds[0]);
    try std.testing.expectEqualStrings("s1", bufs[0][0..lens[0]]);
    try std.testing.expectEqual(Kind.steering, kinds[1]);
    try std.testing.expectEqualStrings("s2", bufs[1][0..lens[1]]);
    try std.testing.expectEqual(Kind.follow_up, kinds[2]);
    try std.testing.expectEqualStrings("f1", bufs[2][0..lens[2]]);
    try std.testing.expectEqual(Kind.follow_up, kinds[3]);
    try std.testing.expectEqualStrings("f2", bufs[3][0..lens[3]]);

    // Caller cap: fewer buffers than pending → copy stops at the cap.
    var kinds2: [2]Kind = undefined;
    var bufs2: [2][128]u8 = undefined;
    var lens2: [2]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.copyPending(&kinds2, &bufs2, &lens2));
    try std.testing.expectEqual(Kind.steering, kinds2[0]);
    try std.testing.expectEqual(Kind.steering, kinds2[1]);

    // Empty queues copy nothing.
    q.clear();
    var kinds3: [4]Kind = undefined;
    var bufs3: [4][128]u8 = undefined;
    var lens3: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), q.copyPending(&kinds3, &bufs3, &lens3));

    // Long text truncates to the preview buffer cap without corrupting.
    try q.enqueueSteering("s-long");
    try q.enqueueFollowUp("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"); // > 128
    var kinds4: [2]Kind = undefined;
    var bufs4: [2][128]u8 = undefined;
    var lens4: [2]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.copyPending(&kinds4, &bufs4, &lens4));
    try std.testing.expectEqual(@as(usize, 6), lens4[0]); // "s-long" fits whole
    try std.testing.expectEqualStrings("s-long", bufs4[0][0..lens4[0]]);
    try std.testing.expectEqual(@as(usize, 128), lens4[1]); // follow-up truncated
    // Pending counts unchanged by copy.
    try std.testing.expectEqual(@as(usize, 1), q.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), q.followUpPending());
}

test "control_queue enqueue copies caller bytes" {
    const gpa = std.testing.allocator;
    var q = try DualQueues.init(gpa);
    defer q.deinit(gpa);

    const buf = try gpa.dupe(u8, "mutable");
    try q.enqueueSteering(buf);
    gpa.free(buf); // caller released
    try std.testing.expectEqualStrings("mutable", q.peek(.pre_turn).?.text);
}

test "control_queue asControlInput none-compatible peek empty" {
    const gpa = std.testing.allocator;
    var q = try DualQueues.init(gpa);
    defer q.deinit(gpa);
    const ci = q.asControlInput();
    try std.testing.expect(ci.peek(.pre_turn) == null);
    try std.testing.expect(ci.peek(.would_complete) == null);
}
