//! Permission gate — HITL for dangerous tools (Phase 1).
//!
//! ```
//! tool_call ──► risk? ──► read: auto-allow
//!                  │
//!                  └── write/execute ──► mode
//!                         ask:  prompt human
//!                         yolo: allow
//! ```
//!
//! Denied tools still return a **tool result string** so the model can adapt;
//! the loop does not crash.

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");

pub const Mode = enum {
    /// Write / shell require human confirmation.
    ask,
    /// Auto-allow everything (dangerous; explicit opt-in).
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

pub const Risk = enum {
    /// list_dir, read_file — no confirmation in ask mode.
    read,
    /// write_file
    write,
    /// run_shell
    execute,

    pub fn needsConfirmation(self: Risk) bool {
        return self != .read;
    }
};

/// Classify a tool by name (Phase 1 built-ins).
pub fn riskOf(tool_name: []const u8) Risk {
    if (std.mem.eql(u8, tool_name, "write_file")) return .write;
    if (std.mem.eql(u8, tool_name, "run_shell")) return .execute;
    return .read;
}

pub const Decision = enum { allow, deny };

/// Callback: return true to allow the tool call.
pub const AskFn = *const fn (
    ptr: ?*anyopaque,
    tool_name: []const u8,
    arguments_json: []const u8,
) Decision;

pub const Gate = struct {
    mode: Mode,
    /// Used only when mode == .ask and risk needs confirmation.
    ask_fn: ?AskFn = null,
    ask_ctx: ?*anyopaque = null,

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

    pub fn decide(
        self: Gate,
        tool_name: []const u8,
        arguments_json: []const u8,
    ) Decision {
        if (self.mode == .yolo) return .allow;
        if (!riskOf(tool_name).needsConfirmation()) return .allow;
        const f = self.ask_fn orelse return .deny;
        return f(self.ask_ctx, tool_name, arguments_json);
    }
};

fn alwaysDeny(_: ?*anyopaque, _: []const u8, _: []const u8) Decision {
    return .deny;
}

fn alwaysAllow(_: ?*anyopaque, _: []const u8, _: []const u8) Decision {
    return .allow;
}

/// Interactive stdin y/N prompt for CLI ask mode.
pub const StdinPrompter = struct {
    io: Io,

    pub fn gate(self: *StdinPrompter) Gate {
        return Gate.ask(promptImpl, self);
    }

    fn promptImpl(ptr: ?*anyopaque, tool_name: []const u8, arguments_json: []const u8) Decision {
        const self: *StdinPrompter = @ptrCast(@alignCast(ptr.?));
        const io = self.io;

        const risk = riskOf(tool_name);
        const risk_label: []const u8 = switch (risk) {
            .read => "read",
            .write => "write",
            .execute => "shell",
        };

        // Preview args (truncated) on stderr via std.log.
        const preview_len = @min(arguments_json.len, 400);
        std.log.warn(
            \\permission: allow {s} tool `{s}`?
            \\  args: {s}{s}
            \\  [y]es / [N]o >
        , .{
            risk_label,
            tool_name,
            arguments_json[0..preview_len],
            if (arguments_json.len > preview_len) "…" else "",
        });

        // Also print a short prompt to stdout so the user sees it in REPL.
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
    return std.fmt.allocPrint(
        allocator,
        "error: permission denied for tool '{s}'. The user rejected this operation. Do not retry the same call; explain what you wanted to do and wait for guidance.",
        .{tool_name},
    );
}

test "riskOf classification" {
    try std.testing.expect(riskOf("list_dir") == .read);
    try std.testing.expect(riskOf("read_file") == .read);
    try std.testing.expect(riskOf("write_file") == .write);
    try std.testing.expect(riskOf("run_shell") == .execute);
}

test "yolo allows write" {
    const g = Gate.yolo();
    try std.testing.expect(g.decide("write_file", "{}") == .allow);
    try std.testing.expect(g.decide("run_shell", "{}") == .allow);
}

test "ask mode auto-allows read" {
    const g = Gate.denyAllDangerous();
    try std.testing.expect(g.decide("list_dir", "{}") == .allow);
    try std.testing.expect(g.decide("write_file", "{}") == .deny);
}

test "mode parse" {
    try std.testing.expect(Mode.parse("ask").? == .ask);
    try std.testing.expect(Mode.parse("yolo").? == .yolo);
    try std.testing.expect(Mode.parse("nope") == null);
}

// silence unused
comptime {
    _ = alwaysAllow;
    _ = message;
}
