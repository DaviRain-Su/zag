//! Permission gate — HITL by tool risk from validated descriptors (D-007).
//!
//! ```
//! tool_call ──► descriptor.risk
//!                  │
//!                  session_kind=plan? ──► non-plan write/shell → deny
//!                  │
//!                  └── risk
//!                       read  → allow
//!                       write → remember hit? allow
//!                               else ask / yolo
//!                       shell → ask / yolo
//! ```
//!
//! Risk is never inferred from tool names. Missing metadata fails at
//! registration (see `tool.buildTool`), not by defaulting to read.
//! Denied tools still return a **tool result string** so the model can adapt.

const std = @import("std");
const Io = std.Io;
const zt = @import("zag-types");
const message = @import("message.zig");

/// Max distinct write paths remembered per agent session (Tiger-style bound).
pub const max_remembered_paths: usize = 64;

pub const Mode = enum {
    /// Write / shell require human confirmation (unless remembered).
    ask,
    /// Auto-allow everything that plan mode still permits (dangerous; explicit opt-in).
    yolo,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .ask => "ask",
            .yolo => "yolo",
        };
    }

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "ask")) return .ask;
        if (std.mem.eql(u8, s, "yolo")) return .yolo;
        return null;
    }
};

/// Product session overlay (H3 stub; full UX is C6).
/// `plan` forbids general write/shell; allows read + writing reserved plan files.
pub const SessionKind = enum {
    agent,
    plan,

    pub fn name(self: SessionKind) []const u8 {
        return switch (self) {
            .agent => "agent",
            .plan => "plan",
        };
    }

    pub fn parse(s: []const u8) ?SessionKind {
        if (std.mem.eql(u8, s, "agent")) return .agent;
        if (std.mem.eql(u8, s, "plan")) return .plan;
        return null;
    }
};

/// Risk class (L0). Prefer descriptor.capabilities.risk over any name map.
pub const Risk = zt.ToolRisk;

/// Paths that remain writable under `SessionKind.plan`.
pub fn isPlanWritePath(path: []const u8) bool {
    var p = path;
    while (p.len >= 2 and (std.mem.eql(u8, p[0..2], "./") or std.mem.eql(u8, p[0..2], ".\\"))) {
        p = p[2..];
    }
    return std.mem.eql(u8, p, "plan.md") or std.mem.eql(u8, p, ".zag/plan.md");
}

pub const Decision = enum { allow, deny };

pub const Outcome = struct {
    decision: Decision,
    /// True when ask-mode write was skipped because the path was remembered.
    remembered: bool = false,
    /// True when deny came from plan-mode overlay (not user prompt).
    plan_blocked: bool = false,
};

/// Callback: return true to allow the tool call. Receives the full descriptor.
pub const AskFn = *const fn (
    ptr: ?*anyopaque,
    descriptor: zt.ToolDescriptor,
    arguments_json: []const u8,
) Decision;

/// Session-scoped remembered write paths (Agent owns lifetime).
pub const Remember = struct {
    gpa: std.mem.Allocator,
    enabled: bool = true,
    paths: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, enabled: bool) Remember {
        return .{ .gpa = gpa, .enabled = enabled };
    }

    pub fn deinit(self: *Remember) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn contains(self: *const Remember, path: []const u8) bool {
        for (self.paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// Record an approved write path. No-op when disabled, duplicate, or at cap.
    pub fn rememberPath(self: *Remember, path: []const u8) void {
        if (!self.enabled) return;
        if (path.len == 0) return;
        if (self.contains(path)) return;
        if (self.paths.items.len >= max_remembered_paths) return;
        const dup = self.gpa.dupe(u8, path) catch return;
        self.paths.append(self.gpa, dup) catch {
            self.gpa.free(dup);
        };
    }
};

pub const Gate = struct {
    mode: Mode,
    session_kind: SessionKind = .agent,
    /// Used only when mode == .ask and risk needs confirmation.
    ask_fn: ?AskFn = null,
    ask_ctx: ?*anyopaque = null,
    /// Optional session remember store (pointer kept stable across Gate copies).
    remember: ?*Remember = null,

    pub fn yolo() Gate {
        return .{ .mode = .yolo };
    }

    pub fn ask(ask_fn: AskFn, ask_ctx: ?*anyopaque) Gate {
        return .{
            .mode = .ask,
            .ask_fn = ask_fn,
            .ask_ctx = ask_ctx,
        };
    }

    /// Always deny dangerous tools (unit tests).
    pub fn denyAllDangerous() Gate {
        return ask(alwaysDeny, null);
    }

    /// Convenience: Decision only (tests / callers that ignore remember metadata).
    pub fn decide(
        self: Gate,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
    ) Decision {
        return self.check(descriptor, arguments_json, null).decision;
    }

    /// Full check with optional `path` (from tool args) for remember + plan rules.
    /// Risk comes only from `descriptor.capabilities.risk`.
    pub fn check(
        self: Gate,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
        path: ?[]const u8,
    ) Outcome {
        const risk = descriptor.capabilities.risk;

        if (self.session_kind == .plan) {
            if (risk == .execute) {
                return .{ .decision = .deny, .plan_blocked = true };
            }
            if (risk == .write) {
                const p = path orelse {
                    return .{ .decision = .deny, .plan_blocked = true };
                };
                if (!isPlanWritePath(p)) {
                    return .{ .decision = .deny, .plan_blocked = true };
                }
            }
            // plan-file write and reads fall through to ask/yolo/remember
        }

        if (self.mode == .yolo) return .{ .decision = .allow };
        if (!risk.needsConfirmation()) return .{ .decision = .allow };

        if (risk == .write) {
            if (path) |p| {
                if (self.remember) |store| {
                    if (store.enabled and store.contains(p)) {
                        return .{ .decision = .allow, .remembered = true };
                    }
                }
            }
        }

        const f = self.ask_fn orelse return .{ .decision = .deny };
        const d = f(self.ask_ctx, descriptor, arguments_json);
        if (d == .allow and risk == .write) {
            if (path) |p| {
                if (self.remember) |store| {
                    store.rememberPath(p);
                }
            }
        }
        return .{ .decision = d };
    }
};

fn alwaysDeny(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8) Decision {
    return .deny;
}

fn alwaysAllow(_: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8) Decision {
    return .allow;
}

/// Interactive stdin y/N prompt for CLI ask mode.
pub const StdinPrompter = struct {
    io: Io,

    pub fn gate(self: *StdinPrompter) Gate {
        return Gate.ask(promptImpl, self);
    }

    fn promptImpl(ptr: ?*anyopaque, descriptor: zt.ToolDescriptor, arguments_json: []const u8) Decision {
        const self: *StdinPrompter = @ptrCast(@alignCast(ptr.?));
        const io = self.io;
        const risk = descriptor.capabilities.risk;
        const tool_name = descriptor.definition.name;
        // h-redact-001: never print raw arguments_json (may contain secrets).
        // Generic metadata only: risk + tool name + arg byte length.
        std.log.warn(
            "permission: allow {s} tool `{s}`? (args_len={d}) [y]es / [N]o >",
            .{ risk.label(), tool_name, arguments_json.len },
        );

        Io.File.stderr().writeStreamingAll(io, "  → type y + Enter to allow, anything else to deny: ") catch {};

        var buf: [64]u8 = undefined;
        var reader = Io.File.stdin().reader(io, &buf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch return .deny;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 1 and (trimmed[0] == 'y' or trimmed[0] == 'Y')) return .allow;
        if (std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "YES")) return .allow;
        return .deny;
    }
};

pub fn deniedMessage(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
) std.mem.Allocator.Error![]u8 {
    return deniedMessageWithReason(allocator, tool_name, .user);
}

pub fn deniedMessageWithReason(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    reason: enum { user, plan_mode },
) std.mem.Allocator.Error![]u8 {
    const tool_error = @import("tool_error.zig");
    const detail: []const u8 = switch (reason) {
        .user => "The user rejected this operation. Do not retry the same call; explain what you wanted to do and wait for guidance.",
        .plan_mode => "Session is in plan mode: only read tools and writing plan.md / .zag/plan.md are allowed. Switch to agent mode for general edits or shell.",
    };
    const msg = try std.fmt.allocPrint(
        allocator,
        "permission denied for tool '{s}'. {s}",
        .{ tool_name, detail },
    );
    defer allocator.free(msg);
    return tool_error.format(allocator, .permission_denied, msg);
}

/// Test helper: minimal descriptor with the given risk (no path / shell claim).
pub fn testDescriptor(tool_name: []const u8, risk: Risk) zt.ToolDescriptor {
    return .{
        .definition = .{
            .name = tool_name,
            .description = "",
            .parameters_json = "{}",
        },
        .capabilities = .{
            .risk = risk,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
    };
}

test "descriptor risk drives gate" {
    const g = Gate.denyAllDangerous();
    try std.testing.expect(g.decide(testDescriptor("list_dir", .read), "{}") == .allow);
    try std.testing.expect(g.decide(testDescriptor("write_file", .write), "{}") == .deny);
    try std.testing.expect(g.decide(testDescriptor("custom_mut", .write), "{}") == .deny);
    try std.testing.expect(g.decide(testDescriptor("custom_exec", .execute), "{}") == .deny);
    // Name alone is never classified: unknown-looking name with read risk allows.
    try std.testing.expect(g.decide(testDescriptor("run_shell", .read), "{}") == .allow);
}

test "yolo allows write and execute by descriptor risk" {
    const g = Gate.yolo();
    try std.testing.expect(g.decide(testDescriptor("write_file", .write), "{}") == .allow);
    try std.testing.expect(g.decide(testDescriptor("run_shell", .execute), "{}") == .allow);
    try std.testing.expect(g.decide(testDescriptor("custom_w", .write), "{}") == .allow);
}

test "mode parse" {
    try std.testing.expect(Mode.parse("ask").? == .ask);
    try std.testing.expect(Mode.parse("yolo").? == .yolo);
    try std.testing.expect(Mode.parse("nope") == null);
}

test "remember skips second ask for same path" {
    const gpa = std.testing.allocator;
    var store = Remember.init(gpa, true);
    defer store.deinit();

    var allow_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn ask(ptr: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8) Decision {
            const c: *u32 = @ptrCast(@alignCast(ptr.?));
            c.* += 1;
            return .allow;
        }
    };

    var gate = Gate.ask(Ctx.ask, &allow_count);
    gate.remember = &store;

    const write_desc = testDescriptor("write_file", .write);
    const first = gate.check(write_desc, "{\"path\":\"a.txt\"}", "a.txt");
    try std.testing.expect(first.decision == .allow);
    try std.testing.expect(!first.remembered);
    try std.testing.expectEqual(@as(u32, 1), allow_count);

    const second = gate.check(write_desc, "{\"path\":\"a.txt\"}", "a.txt");
    try std.testing.expect(second.decision == .allow);
    try std.testing.expect(second.remembered);
    try std.testing.expectEqual(@as(u32, 1), allow_count);

    const other = gate.check(write_desc, "{\"path\":\"b.txt\"}", "b.txt");
    try std.testing.expect(other.decision == .allow);
    try std.testing.expect(!other.remembered);
    try std.testing.expectEqual(@as(u32, 2), allow_count);
}

test "remember can be disabled" {
    const gpa = std.testing.allocator;
    var store = Remember.init(gpa, false);
    defer store.deinit();

    var allow_count: u32 = 0;
    const Ctx = struct {
        fn ask(ptr: ?*anyopaque, _: zt.ToolDescriptor, _: []const u8) Decision {
            const c: *u32 = @ptrCast(@alignCast(ptr.?));
            c.* += 1;
            return .allow;
        }
    };
    var gate = Gate.ask(Ctx.ask, &allow_count);
    gate.remember = &store;

    const write_desc = testDescriptor("write_file", .write);
    _ = gate.check(write_desc, "{}", "a.txt");
    _ = gate.check(write_desc, "{}", "a.txt");
    try std.testing.expectEqual(@as(u32, 2), allow_count);
}

test "plan mode blocks shell and non-plan writes by risk" {
    var gate = Gate.yolo();
    gate.session_kind = .plan;

    try std.testing.expect(gate.check(testDescriptor("list_dir", .read), "{}", null).decision == .allow);
    try std.testing.expect(gate.check(testDescriptor("run_shell", .execute), "{\"command\":\"ls\"}", null).decision == .deny);
    try std.testing.expect(gate.check(testDescriptor("run_shell", .execute), "{}", null).plan_blocked);

    // Custom execute name still blocked under plan.
    try std.testing.expect(gate.check(testDescriptor("my_shell", .execute), "{}", null).decision == .deny);

    const bad = gate.check(testDescriptor("write_file", .write), "{}", "src/main.zig");
    try std.testing.expect(bad.decision == .deny);
    try std.testing.expect(bad.plan_blocked);

    const ok = gate.check(testDescriptor("write_file", .write), "{}", "plan.md");
    try std.testing.expect(ok.decision == .allow);
    try std.testing.expect(gate.check(testDescriptor("write_file", .write), "{}", ".zag/plan.md").decision == .allow);
    try std.testing.expect(gate.check(testDescriptor("write_file", .write), "{}", "./plan.md").decision == .allow);
}

test "isPlanWritePath" {
    try std.testing.expect(isPlanWritePath("plan.md"));
    try std.testing.expect(isPlanWritePath("./plan.md"));
    try std.testing.expect(isPlanWritePath(".zag/plan.md"));
    try std.testing.expect(!isPlanWritePath("docs/plan.md"));
    try std.testing.expect(!isPlanWritePath("plan.txt"));
}

// silence unused
comptime {
    _ = alwaysAllow;
    _ = message;
}
