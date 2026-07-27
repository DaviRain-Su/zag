//! Single-slot permission rendezvous: worker AskFn publishes; UI decides.

const std = @import("std");
const builtin = @import("builtin");
const zt = @import("zag-types");
const coding = @import("zag-coding-agent");
const c = @import("constants.zig");
const present = @import("present.zig");

pub const PermissionSlot = struct {
    /// Short critical sections; spin (no Io.Mutex cancel points in callbacks).
    mu: std.atomic.Mutex = .unlocked,
    pending: bool = false,
    decided: bool = false,
    decision: coding.permissions.Decision = .deny,
    closing: bool = false,
    /// Bounded modal facts (no raw args body).
    risk_label: [16]u8 = undefined,
    risk_len: u8 = 0,
    args_len: usize = 0,
    tool_name: [c.permission_tool_name_max_bytes]u8 = undefined,
    tool_name_len: u8 = 0,

    fn lock(self: *PermissionSlot) void {
        while (!self.mu.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *PermissionSlot) void {
        self.mu.unlock();
    }

    pub fn riskSlice(self: *const PermissionSlot) []const u8 {
        return self.risk_label[0..self.risk_len];
    }
    pub fn toolNameSlice(self: *const PermissionSlot) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }

    /// Worker-side AskFn body. Never reads stdin / never renders.
    /// Waits by brief unlock + sleep (not under card lock).
    pub fn ask(
        self: *PermissionSlot,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        ask_ctx_ok: bool,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
        wake_fn: *const fn (*anyopaque) void,
        wake_ctx: *anyopaque,
    ) coding.permissions.Decision {
        if (!ask_ctx_ok or redactor == null) return .deny;

        self.lock();
        if (self.closing) {
            self.unlock();
            return .deny;
        }
        if (self.pending) {
            self.unlock();
            return .deny;
        }

        const risk = descriptor.capabilities.risk.label();
        const rlen = @min(risk.len, self.risk_label.len);
        @memcpy(self.risk_label[0..rlen], risk[0..rlen]);
        self.risk_len = @intCast(rlen);
        self.args_len = arguments_json.len;
        self.tool_name_len = @intCast(present.presentInto(
            gpa,
            redactor,
            &self.tool_name,
            descriptor.definition.name,
        ));

        self.pending = true;
        self.decided = false;
        self.decision = .deny;
        self.unlock();

        wake_fn(wake_ctx);

        // Wait for decision or closing without holding card_ring_mutex.
        while (true) {
            self.lock();
            if (self.decided or self.closing) {
                const out = if (self.closing) coding.permissions.Decision.deny else self.decision;
                self.pending = false;
                self.decided = false;
                self.unlock();
                return out;
            }
            self.unlock();
            // Brief yield without Io cancel points (worker wait).
            // std.Thread.sleep removed in 0.16; libc nanosleep is inherent on
            // macOS and link_libc Linux; raw Linux uses clock_nanosleep syscall.
            if (builtin.os.tag == .linux and !builtin.link_libc) {
                var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                _ = std.os.linux.clock_nanosleep(.MONOTONIC, 0, &ts, null);
            } else {
                var ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            }
        }
    }

    pub fn decide(self: *PermissionSlot, d: coding.permissions.Decision) void {
        self.lock();
        defer self.unlock();
        if (!self.pending or self.decided) return;
        self.decision = d;
        self.decided = true;
    }

    pub fn denyAndClose(self: *PermissionSlot) void {
        self.lock();
        defer self.unlock();
        self.closing = true;
        if (self.pending and !self.decided) {
            self.decision = .deny;
            self.decided = true;
        }
    }

    pub fn isPending(self: *PermissionSlot) bool {
        self.lock();
        defer self.unlock();
        return self.pending and !self.decided;
    }

    pub fn resetClosing(self: *PermissionSlot) void {
        self.lock();
        defer self.unlock();
        self.closing = false;
    }
};

test "permission slot second request denies" {
    var slot = PermissionSlot{};
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();

    const desc = coding.permissions.testDescriptor("write_file", .write);
    const Wake = struct {
        fn f(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;

    slot.pending = true;
    const d = slot.ask(gpa, &r, true, desc, "{}", Wake.f, &dummy);
    try std.testing.expectEqual(coding.permissions.Decision.deny, d);
}

test "permission null ctx / missing redactor deny" {
    var slot = PermissionSlot{};
    const gpa = std.testing.allocator;
    const desc = coding.permissions.testDescriptor("write_file", .write);
    const Wake = struct {
        fn f(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;
    try std.testing.expectEqual(
        coding.permissions.Decision.deny,
        slot.ask(gpa, null, true, desc, "{}", Wake.f, &dummy),
    );
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    try std.testing.expectEqual(
        coding.permissions.Decision.deny,
        slot.ask(gpa, &r, false, desc, "{}", Wake.f, &dummy),
    );
}
