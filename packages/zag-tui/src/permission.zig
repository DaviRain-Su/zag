//! Single-slot permission rendezvous: worker AskFn publishes; UI decides.
//!
//! Redaction of tool name completes **outside** the permission spin lock.
//! UI reads modal facts only via `snapshot()` under the lock.

const std = @import("std");
const builtin = @import("builtin");
const zt = @import("zag-types");
const coding = @import("zag-coding-agent");
const c = @import("constants.zig");
const present = @import("present.zig");

pub const ModalSnapshot = struct {
    pending: bool = false,
    risk_label: [16]u8 = undefined,
    risk_len: u8 = 0,
    args_len: usize = 0,
    tool_name: [c.permission_tool_name_max_bytes]u8 = undefined,
    tool_name_len: u8 = 0,

    pub fn riskSlice(self: *const ModalSnapshot) []const u8 {
        return self.risk_label[0..self.risk_len];
    }
    pub fn toolNameSlice(self: *const ModalSnapshot) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }
};

pub const PermissionSlot = struct {
    mu: std.atomic.Mutex = .unlocked,
    pending: bool = false,
    decided: bool = false,
    decision: coding.permissions.Decision = .deny,
    closing: bool = false,
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

    /// Worker-side AskFn. Never reads stdin / never renders / never holds card lock.
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

        // ── Outside lock: redact + truncate tool name; risk/args_len fixed ──
        const risk = descriptor.capabilities.risk.label();
        var risk_buf: [16]u8 = undefined;
        const rlen = @min(risk.len, risk_buf.len);
        @memcpy(risk_buf[0..rlen], risk[0..rlen]);

        var tool_buf: [c.permission_tool_name_max_bytes]u8 = undefined;
        const tlen = present.presentInto(gpa, redactor, &tool_buf, descriptor.definition.name);
        const args_len = arguments_json.len;

        // ── Under lock: publish fixed preprocessed fields only ──
        self.lock();
        if (self.closing) {
            self.unlock();
            return .deny;
        }
        if (self.pending) {
            self.unlock();
            return .deny;
        }

        @memcpy(self.risk_label[0..rlen], risk_buf[0..rlen]);
        self.risk_len = @intCast(rlen);
        self.args_len = args_len;
        if (tlen > 0) @memcpy(self.tool_name[0..tlen], tool_buf[0..tlen]);
        self.tool_name_len = @intCast(tlen);

        self.pending = true;
        self.decided = false;
        self.decision = .deny;
        self.unlock();

        wake_fn(wake_ctx);

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

    /// Atomic snapshot for UI render (only safe way to read modal fields).
    pub fn snapshot(self: *PermissionSlot) ModalSnapshot {
        self.lock();
        defer self.unlock();
        var out: ModalSnapshot = .{
            .pending = self.pending and !self.decided,
            .risk_len = self.risk_len,
            .args_len = self.args_len,
            .tool_name_len = self.tool_name_len,
        };
        if (self.risk_len > 0) {
            @memcpy(out.risk_label[0..self.risk_len], self.risk_label[0..self.risk_len]);
        }
        if (self.tool_name_len > 0) {
            @memcpy(out.tool_name[0..self.tool_name_len], self.tool_name[0..self.tool_name_len]);
        }
        return out;
    }

    pub fn isPending(self: *PermissionSlot) bool {
        return self.snapshot().pending;
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

test "permission snapshot is only reader path" {
    var slot = PermissionSlot{};
    slot.pending = true;
    slot.decided = false;
    slot.risk_len = 4;
    @memcpy(slot.risk_label[0..4], "read");
    slot.args_len = 7;
    const snap = slot.snapshot();
    try std.testing.expect(snap.pending);
    try std.testing.expectEqualStrings("read", snap.riskSlice());
    try std.testing.expectEqual(@as(usize, 7), snap.args_len);
}
