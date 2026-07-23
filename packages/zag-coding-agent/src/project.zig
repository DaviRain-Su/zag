//! Project instructions — inject AGENTS.md (or README) into the system prompt.
//!
//! Business rule: project conventions live in **system**, not as a fake user
//! message, so they apply for the whole session (including resume).

const std = @import("std");
const Io = std.Io;

pub const max_instructions_bytes: usize = 24 * 1024;

/// Candidate files, first existing wins.
pub const candidates = [_][]const u8{
    "AGENTS.md",
    "agents.md",
    "CLAUDE.md",
    "README.md",
};

pub const Loaded = struct {
    /// Relative path that was loaded.
    source: []const u8,
    /// File body (caller frees with allocator).
    body: []u8,
};

/// Load project instructions from cwd. Returns null if none found.
pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
) error{OutOfMemory}!?Loaded {
    for (candidates) |name| {
        const body = cwd.readFileAlloc(io, name, gpa, .limited(max_instructions_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        return .{
            .source = name,
            .body = body,
        };
    }
    return null;
}

/// Merge base system prompt + optional project block into one string (arena/gpa owned).
pub fn composeSystemPrompt(
    gpa: std.mem.Allocator,
    base_system: []const u8,
    project: ?Loaded,
) error{OutOfMemory}![]u8 {
    if (project) |p| {
        return std.fmt.allocPrint(gpa,
            \\{s}
            \\
            \\# Project instructions (from {s})
            \\
            \\The following project-specific rules take precedence when they do not conflict with safety or tool protocols:
            \\
            \\{s}
        , .{ base_system, p.source, p.body });
    }
    return gpa.dupe(u8, base_system);
}

test "composeSystemPrompt without project" {
    const gpa = std.testing.allocator;
    const s = try composeSystemPrompt(gpa, "base", null);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("base", s);
}

test "composeSystemPrompt with project" {
    const gpa = std.testing.allocator;
    const body = try gpa.dupe(u8, "use tabs");
    defer gpa.free(body);
    const s = try composeSystemPrompt(gpa, "base", .{ .source = "AGENTS.md", .body = body });
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "use tabs") != null);
}
