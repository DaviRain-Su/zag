//! Protocol-history validation — Tool-call/result bundle legality (D-011).
//!
//! Core owns the fail-closed check that every Tool-call/result bundle in the
//! provider-visible body is well-formed **before** any `Provider.chat`. This
//! is independent of the product `ContextView` implementation: the loop
//! validates the projection it receives, not just the algorithm that built it.
//!
//! Body history (after leading transcript `system` rows) is validated:
//! - every assistant `tool_calls` bundle has nonempty **unique** call IDs;
//! - immediately followed by **exactly one** contiguous `tool` result per call
//!   in **deterministic call-list order** (same order as `tool_calls`);
//! - no unknown / duplicate / missing / empty IDs;
//! - no orphan `tool` rows;
//! - no partial/incomplete bundles at end of body.
//!
//! Malformed history → `error.InvalidContext` before any provider call.

const std = @import("std");
const message = @import("message.zig");

/// Protocol-history legality error. The loop maps this to `RunError.InvalidContext`
/// (terminal `invalid_context`), distinct from provider errors.
pub const Error = error{
    /// Malformed tool-call/result history or other fail-closed context policy.
    InvalidContext,
};

/// Fail-closed body policy (non-system history):
/// - every assistant `tool_calls` bundle has nonempty **unique** call IDs;
/// - immediately followed by **exactly one** contiguous `tool` result per call
///   in **deterministic call-list order** (same order as `tool_calls`);
/// - no unknown / duplicate / missing / empty IDs;
/// - no orphan `tool` rows;
/// - no partial/incomplete bundles at end of body.
pub fn validateBodyHistory(body: []const message.Message) error{InvalidContext}!void {
    var i: usize = 0;
    while (i < body.len) {
        switch (body[i].role) {
            .system, .user => i += 1,
            .assistant => {
                if (body[i].tool_calls) |calls| {
                    if (calls.len == 0) {
                        i += 1;
                        continue;
                    }
                    try validateCallIds(calls);
                    if (i + 1 + calls.len > body.len) return error.InvalidContext;
                    for (calls, 0..) |c, j| {
                        const t = body[i + 1 + j];
                        if (t.role != .tool) return error.InvalidContext;
                        const tid = t.tool_call_id orelse return error.InvalidContext;
                        if (tid.len == 0) return error.InvalidContext;
                        if (!std.mem.eql(u8, tid, c.id)) return error.InvalidContext;
                    }
                    i += 1 + calls.len;
                } else {
                    i += 1;
                }
            },
            .tool => return error.InvalidContext,
        }
    }
}

fn validateCallIds(calls: []const message.ToolCall) error{InvalidContext}!void {
    for (calls, 0..) |c, ci| {
        if (c.id.len == 0) return error.InvalidContext;
        for (calls[0..ci]) |prev| {
            if (std.mem.eql(u8, prev.id, c.id)) return error.InvalidContext;
        }
    }
}

/// If `start` lands inside tool results, walk back to the carrier assistant.
/// Body must already pass `validateBodyHistory` (or this returns InvalidContext).
pub fn alignToLegalStart(body: []const message.Message, start: usize) error{InvalidContext}!usize {
    if (start >= body.len) return start;
    if (body[start].role != .tool) return start;
    var s = start;
    while (s > 0 and body[s].role == .tool) s -= 1;
    if (body[s].role != .assistant or body[s].tool_calls == null or body[s].tool_calls.?.len == 0) {
        return error.InvalidContext;
    }
    return s;
}

/// Exclusive end index of the atomic unit starting at `start` (legal start).
/// Assistant with N calls → assistant + N results; otherwise one message.
pub fn unitEnd(body: []const message.Message, start: usize) usize {
    if (start >= body.len) return start;
    if (body[start].role == .assistant) {
        if (body[start].tool_calls) |calls| {
            if (calls.len > 0) return start + 1 + calls.len;
        }
    }
    return start + 1;
}

/// Validate the protocol-visible body of a projected ContextView `View`.
///
/// The view may carry leading `system` layer messages (product prompt layers);
/// those are skipped. The remaining non-system body is validated fail-closed.
/// This is the independent Core gate that runs **after** the product
/// `ContextView` returns and **before** `Provider.chat`, regardless of how the
/// product built the view.
pub fn validateViewBody(view_messages: []const message.Message) error{InvalidContext}!void {
    // Skip leading system layers (product prompt layers may be present).
    var body_start: usize = 0;
    while (body_start < view_messages.len and view_messages[body_start].role == .system) : (body_start += 1) {}
    try validateBodyHistory(view_messages[body_start..]);
}

// ── unit tests ──────────────────────────────────────────────────────────────

test "validateBodyHistory accepts clean alternating user/assistant" {
    const body = [_]message.Message{
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
    };
    try validateBodyHistory(&body);
}

test "validateBodyHistory accepts well-formed tool bundle" {
    const calls = [_]message.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]message.Message{
        .user("ask"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out1"),
        .toolResult("c2", "out2"),
        .user("done"),
    };
    try validateBodyHistory(&body);
}

test "validateBodyHistory rejects orphan tool" {
    const orphan = [_]message.Message{
        .user("u"),
        .toolResult("z", "nope"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&orphan));
}

test "validateBodyHistory rejects wrong tool_call_id" {
    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const wrong_id = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "ok"),
        .toolResult("WRONG", "bad"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&wrong_id));
}

test "validateBodyHistory rejects out-of-order results" {
    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const ooo = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a2", "second-first"),
        .toolResult("a1", "first-second"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&ooo));
}

test "validateBodyHistory rejects incomplete bundle" {
    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const incomplete = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "only-one"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&incomplete));
}

test "validateBodyHistory rejects duplicate call IDs" {
    const dup = [_]message.ToolCall{
        .{ .id = "x", .name = "list_dir", .arguments = "{}" },
        .{ .id = "x", .name = "read_file", .arguments = "{}" },
    };
    const dups = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &dup),
        .toolResult("x", "1"),
        .toolResult("x", "2"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&dups));
}

test "validateBodyHistory rejects empty call id" {
    const empty_id = [_]message.ToolCall{
        .{ .id = "", .name = "list_dir", .arguments = "{}" },
    };
    const empty = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &empty_id),
        .toolResult("", "x"),
    };
    try std.testing.expectError(error.InvalidContext, validateBodyHistory(&empty));
}

test "alignToLegalStart walks back to carrier assistant" {
    const calls_a = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]message.Message{
        .user("old-1"),
        .user("ask-tools"),
        .assistantToolCalls("using tools", &calls_a),
        .toolResult("a1", "dir-out"),
        .toolResult("a2", "file-out"),
        .user("final"),
        .assistantText("done"),
    };
    // Index of toolResult a2 within body: user, user, asst_tools, a1, a2 → 4
    const land_on_a2: usize = 4;
    try std.testing.expect(body[land_on_a2].role == .tool);
    try std.testing.expectEqualStrings("a2", body[land_on_a2].tool_call_id.?);
    const aligned = try alignToLegalStart(&body, land_on_a2);
    try std.testing.expect(body[aligned].role == .assistant);
    try std.testing.expect(body[aligned].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), body[aligned].tool_calls.?.len);
}

test "alignToLegalStart returns start when not on tool" {
    const body = [_]message.Message{
        .user("u"),
        .assistantText("a"),
    };
    const s = try alignToLegalStart(&body, 0);
    try std.testing.expectEqual(@as(usize, 0), s);
}

test "unitEnd skips assistant + all results" {
    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]message.Message{
        .user("ask"),
        .assistantToolCalls("using tools", &calls),
        .toolResult("a1", "dir-out"),
        .toolResult("a2", "file-out"),
        .user("final"),
    };
    const end = unitEnd(&body, 1);
    try std.testing.expectEqual(@as(usize, 4), end);
}

test "unitEnd single message for non-bundle" {
    const body = [_]message.Message{
        .user("u"),
        .assistantText("a"),
    };
    const end = unitEnd(&body, 0);
    try std.testing.expectEqual(@as(usize, 1), end);
}

test "validateViewBody skips leading system layers" {
    const calls = [_]message.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
    };
    const view = [_]message.Message{
        .system("base-sys"),
        .system("project"),
        .user("ask"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out"),
        .user("done"),
    };
    try validateViewBody(&view);
}

test "validateViewBody rejects malformed body after system layers" {
    const view = [_]message.Message{
        .system("base-sys"),
        .user("ask"),
        .toolResult("orphan", "nope"),
    };
    try std.testing.expectError(error.InvalidContext, validateViewBody(&view));
}

test "validateViewBody accepts empty view" {
    const view: [0]message.Message = .{};
    try validateViewBody(&view);
}

test "validateViewBody accepts system-only view" {
    const view = [_]message.Message{
        .system("base-sys"),
        .system("project"),
    };
    try validateViewBody(&view);
}