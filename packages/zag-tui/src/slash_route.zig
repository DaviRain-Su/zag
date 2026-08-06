//! TUI submit routing for slash (skill / template / builtins).
//! Reuses coding-agent parsers; does not invent a second skill catalog.

const std = @import("std");
const coding = @import("zag-coding-agent");
const overlay = @import("overlay.zig");

pub const RouteError = error{
    UnknownSkill,
    UnknownTemplate,
    ArgumentsTooLarge,
    ExpansionTooLarge,
    OutOfMemory,
};

pub const Routed = union(enum) {
    /// Expanded or raw text to send as reply.
    prompt: struct { text: []const u8, owned: bool },
    /// Open a host overlay instead of replying.
    open_overlay: overlay.Kind,
    /// Local error note (no reply).
    note: []const u8,
};

/// Parse `/name` builtins (exact, optional trailing whitespace only).
pub fn parseBuiltinSlash(input: []const u8) ?overlay.Builtin {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '/') return null;
    const rest = trimmed[1..];
    // No args for v1 builtins — reject if space present after name.
    const name = if (std.mem.indexOfScalar(u8, rest, ' ')) |i| rest[0..i] else rest;
    if (name.len != rest.len and rest[name.len] == ' ') {
        // trailing args → not a bare builtin (leave for template/skill)
        if (overlay.Builtin.fromName(name)) |_| {
            // Allow `/help` only exact; with args treat as unknown builtin → fall through
            return null;
        }
        return null;
    }
    return overlay.Builtin.fromName(name);
}

/// Skill → template → builtin overlay → raw prompt.
pub fn routeSubmit(
    gpa: std.mem.Allocator,
    session: *const coding.Session,
    prompt: []const u8,
) RouteError!Routed {
    if (coding.parseSkillCommand(prompt)) |cmd| {
        const act = coding.expandSkillActivation(gpa, session, cmd.name, cmd.rest) catch |err| {
            return switch (err) {
                error.UnknownSkill => error.UnknownSkill,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        return .{ .prompt = .{ .text = act.user_text, .owned = true } };
    }
    if (coding.parseTemplateCommand(prompt)) |cmd| {
        if (session.templates_enabled and session.templates_catalog.find(cmd.name) != null) {
            const exp = coding.expandTemplate(gpa, session, cmd.name, cmd.rest) catch |err| {
                return switch (err) {
                    error.UnknownTemplate => error.UnknownTemplate,
                    error.ArgumentsTooLarge => error.ArgumentsTooLarge,
                    error.ExpansionTooLarge => error.ExpansionTooLarge,
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
            return .{ .prompt = .{ .text = exp.user_text, .owned = true } };
        }
    }
    if (parseBuiltinSlash(prompt)) |b| {
        return .{ .open_overlay = b.overlayKind() };
    }
    return .{ .prompt = .{ .text = prompt, .owned = false } };
}

/// Slash filter after leading `/` for palette (editor may be `/hel`).
pub fn slashFilter(editor_text: []const u8) ?[]const u8 {
    if (editor_text.len == 0 or editor_text[0] != '/') return null;
    // Stop at first whitespace or newline.
    const body = editor_text[1..];
    if (std.mem.indexOfAny(u8, body, " \t\r\n")) |i| return body[0..i];
    return body;
}

test "parseBuiltinSlash" {
    try std.testing.expect(parseBuiltinSlash("/help").? == .help);
    try std.testing.expect(parseBuiltinSlash("  /model  ").? == .model);
    try std.testing.expect(parseBuiltinSlash("/skill:x") == null);
    try std.testing.expect(parseBuiltinSlash("help") == null);
}

test "slashFilter" {
    try std.testing.expectEqualStrings("hel", slashFilter("/hel").?);
    try std.testing.expect(slashFilter("x") == null);
}
