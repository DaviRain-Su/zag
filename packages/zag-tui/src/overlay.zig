//! Overlay state machine (tui-slash-host / model-settings).
//! Pure UI state — no Core / Session types.

const std = @import("std");

pub const Kind = enum {
    none,
    help,
    slash_palette,
    settings,
    model,
    theme,
};

pub const Overlay = struct {
    kind: Kind = .none,
    /// Highlighted row within the active list (0-based).
    cursor: usize = 0,
    /// Slash filter text after leading `/` (owned by App editor slice when live).
    filter_len: usize = 0,

    pub fn open(self: *Overlay, kind: Kind) void {
        self.kind = kind;
        self.cursor = 0;
        self.filter_len = 0;
    }

    pub fn close(self: *Overlay) void {
        self.kind = .none;
        self.cursor = 0;
        self.filter_len = 0;
    }

    pub fn isOpen(self: *const Overlay) bool {
        return self.kind != .none;
    }

    pub fn moveUp(self: *Overlay, count: usize) void {
        if (count == 0) return;
        if (self.cursor > 0) self.cursor -= 1 else self.cursor = count - 1;
    }

    pub fn moveDown(self: *Overlay, count: usize) void {
        if (count == 0) return;
        self.cursor = (self.cursor + 1) % count;
    }

    pub fn clampCursor(self: *Overlay, count: usize) void {
        if (count == 0) {
            self.cursor = 0;
            return;
        }
        if (self.cursor >= count) self.cursor = count - 1;
    }
};

/// Built-in slash commands (v1). Skill/template handled separately via coding-agent.
pub const Builtin = enum {
    help,
    settings,
    model,
    theme,

    pub fn fromName(name: []const u8) ?Builtin {
        if (std.mem.eql(u8, name, "help")) return .help;
        if (std.mem.eql(u8, name, "settings")) return .settings;
        if (std.mem.eql(u8, name, "model")) return .model;
        if (std.mem.eql(u8, name, "theme")) return .theme;
        return null;
    }

    pub fn label(self: Builtin) []const u8 {
        return switch (self) {
            .help => "/help",
            .settings => "/settings",
            .model => "/model",
            .theme => "/theme",
        };
    }

    pub fn overlayKind(self: Builtin) Kind {
        return switch (self) {
            .help => .help,
            .settings => .settings,
            .model => .model,
            .theme => .theme,
        };
    }
};

pub const builtin_names = [_][]const u8{ "help", "settings", "model", "theme" };

/// Match builtins whose name starts with `prefix` (no leading slash).
pub fn matchBuiltins(prefix: []const u8, out: *[builtin_names.len][]const u8) usize {
    var n: usize = 0;
    for (builtin_names) |name| {
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            out[n] = name;
            n += 1;
        }
    }
    return n;
}

test "overlay open close cursor wrap" {
    var o: Overlay = .{};
    try std.testing.expect(!o.isOpen());
    o.open(.help);
    try std.testing.expect(o.isOpen());
    o.moveDown(3);
    try std.testing.expectEqual(@as(usize, 1), o.cursor);
    o.moveUp(3);
    try std.testing.expectEqual(@as(usize, 0), o.cursor);
    o.close();
    try std.testing.expect(!o.isOpen());
}

test "builtin fromName" {
    try std.testing.expect(Builtin.fromName("help").? == .help);
    try std.testing.expect(Builtin.fromName("nope") == null);
}

test "matchBuiltins prefix" {
    var buf: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), matchBuiltins("mod", &buf));
    try std.testing.expectEqualStrings("model", buf[0]);
    try std.testing.expectEqual(@as(usize, 4), matchBuiltins("", &buf));
}
