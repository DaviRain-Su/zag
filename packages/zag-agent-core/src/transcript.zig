//! Conversation transcript — the only place that owns message string storage
//! for a run/session.
//!
//! Business code should call append* helpers; it should not touch arenas or
//! duplicate tool_call slices by hand.

const std = @import("std");
const message = @import("message.zig");

pub const Error = error{OutOfMemory};

/// Single-use internal value for mid-batch steering (harness-steering-001).
///
/// `prepareUser` copies text into the transcript arena and reserves message-list
/// capacity for every remaining Tool row plus the user row. Abandoning a
/// prepared value exposes no message; arena bytes live until Session deinit.
/// A later attempt prepares an independent value rather than reusing this one.
/// `appendPreparedUser` is infallible after a successful prepare (no allocation).
pub const PreparedUser = struct {
    text: []const u8,
};

pub const Transcript = struct {
    /// All message string/tool_call bytes live here for the transcript lifetime.
    arena: std.mem.Allocator,
    messages: std.ArrayList(message.Message) = .empty,

    pub fn init(arena: std.mem.Allocator) Transcript {
        return .{ .arena = arena };
    }

    pub fn items(self: *const Transcript) []const message.Message {
        return self.messages.items;
    }

    pub fn appendSystem(self: *Transcript, text: []const u8) Error!void {
        const owned = self.arena.dupe(u8, text) catch return error.OutOfMemory;
        self.messages.append(self.arena, message.Message.system(owned)) catch
            return error.OutOfMemory;
    }

    pub fn appendUser(self: *Transcript, text: []const u8) Error!void {
        const owned = self.arena.dupe(u8, text) catch return error.OutOfMemory;
        self.messages.append(self.arena, message.Message.user(owned)) catch
            return error.OutOfMemory;
    }

    /// Pre-copy user text and reserve `reserve_rows` additional message slots.
    /// Does not expose a user row. On OOM, no row is visible and the caller must
    /// not write steered side effects.
    pub fn prepareUser(self: *Transcript, text: []const u8, reserve_rows: usize) Error!PreparedUser {
        const owned = self.arena.dupe(u8, text) catch return error.OutOfMemory;
        self.messages.ensureUnusedCapacity(self.arena, reserve_rows) catch
            return error.OutOfMemory;
        return .{ .text = owned };
    }

    /// Append a previously prepared user row without allocation. Single-use:
    /// the caller must not call this twice with the same prepared value after a
    /// successful append (Debug builds may assert via capacity bookkeeping).
    pub fn appendPreparedUser(self: *Transcript, prepared: PreparedUser) void {
        self.messages.appendAssumeCapacity(message.Message.user(prepared.text));
    }

    /// Persist an assistant turn (text, optional tool_calls, optional
    /// reasoning) into the ledger.
    pub fn appendAssistantTurn(self: *Transcript, turn: message.AssistantTurn) Error!void {
        const content = self.arena.dupe(u8, turn.content) catch return error.OutOfMemory;
        const reasoning = if (turn.reasoning) |r|
            self.arena.dupe(u8, r) catch return error.OutOfMemory
        else
            null;

        if (turn.tool_calls.len == 0) {
            var m = message.Message.assistantText(content);
            m.reasoning = reasoning;
            self.messages.append(self.arena, m) catch return error.OutOfMemory;
            return;
        }

        const calls = self.arena.alloc(message.ToolCall, turn.tool_calls.len) catch
            return error.OutOfMemory;
        for (turn.tool_calls, 0..) |c, i| {
            calls[i] = .{
                .id = self.arena.dupe(u8, c.id) catch return error.OutOfMemory,
                .name = self.arena.dupe(u8, c.name) catch return error.OutOfMemory,
                .arguments = self.arena.dupe(u8, c.arguments) catch return error.OutOfMemory,
            };
        }
        var m = message.Message.assistantToolCalls(content, calls);
        m.reasoning = reasoning;
        self.messages.append(self.arena, m) catch return error.OutOfMemory;
    }

    /// Append a runtime-injected assistant row (synthetic reason carrier:
    /// interjection, auto-continue, task-completed, system-reminder).
    /// `prompt_index` is the current prompt-turn index (may be null).
    pub fn appendSyntheticReason(
        self: *Transcript,
        content: []const u8,
        prompt_index: ?u32,
    ) Error!void {
        const owned = self.arena.dupe(u8, content) catch return error.OutOfMemory;
        self.messages.append(self.arena, .{
            .role = .assistant,
            .content = owned,
            .synthetic = true,
            .prompt_index = prompt_index,
        }) catch return error.OutOfMemory;
    }

    pub fn appendToolResult(
        self: *Transcript,
        tool_call_id: []const u8,
        content: []const u8,
    ) Error!void {
        // tool_call_id already lives in an earlier assistant message (same arena).
        const body = self.arena.dupe(u8, content) catch return error.OutOfMemory;
        self.messages.append(self.arena, message.Message.toolResult(tool_call_id, body)) catch
            return error.OutOfMemory;
    }
};

test "transcript append user and assistant text" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    var t = Transcript.init(arena_impl.allocator());

    try t.appendSystem("sys");
    try t.appendUser("hi");
    try t.appendAssistantTurn(.{ .content = "hello", .tool_calls = &.{} });

    try std.testing.expectEqual(@as(usize, 3), t.items().len);
    try std.testing.expectEqualStrings("hi", t.items()[1].content);
    try std.testing.expectEqualStrings("hello", t.items()[2].content);
}

test "transcript prepareUser then appendPreparedUser is allocation-free append" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    var t = Transcript.init(arena_impl.allocator());

    try t.appendUser("first");
    const prepared = try t.prepareUser("steered-in", 3);
    // Capacity reserved; prepared row not yet visible.
    try std.testing.expectEqual(@as(usize, 1), t.items().len);

    // Fill remaining reserved tool slots then the user row.
    try t.appendToolResult("c1", "ok1");
    try t.appendToolResult("c2", "ok2");
    t.appendPreparedUser(prepared);

    try std.testing.expectEqual(@as(usize, 4), t.items().len);
    try std.testing.expectEqualStrings("steered-in", t.items()[3].content);
}

test "transcript abandoned PreparedUser exposes no user row" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    var t = Transcript.init(arena_impl.allocator());

    _ = try t.prepareUser("hidden", 1);
    try std.testing.expectEqual(@as(usize, 0), t.items().len);

    // Independent later prepare works.
    const again = try t.prepareUser("visible", 1);
    t.appendPreparedUser(again);
    try std.testing.expectEqual(@as(usize, 1), t.items().len);
    try std.testing.expectEqualStrings("visible", t.items()[0].content);
}

test "transcript appendAssistantTurn forwards reasoning" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    var t = Transcript.init(arena_impl.allocator());

    try t.appendAssistantTurn(.{
        .content = "visible",
        .tool_calls = &.{},
        .reasoning = "hidden thinking",
    });
    const m = t.items()[0];
    try std.testing.expectEqualStrings("visible", m.content);
    try std.testing.expectEqualStrings("hidden thinking", m.reasoning.?);

    // Reasoning survives the tool-call path too.
    const calls = [_]message.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    try t.appendAssistantTurn(.{
        .content = "",
        .tool_calls = &calls,
        .reasoning = "planning the call",
    });
    const m2 = t.items()[1];
    try std.testing.expectEqualStrings("planning the call", m2.reasoning.?);
    try std.testing.expectEqualStrings("c1", m2.tool_calls.?[0].id);

    // Absent reasoning stays null.
    try t.appendAssistantTurn(.{ .content = "plain", .tool_calls = &.{} });
    try std.testing.expect(t.items()[2].reasoning == null);
}

test "transcript appendSyntheticReason stamps synthetic + prompt_index" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    var t = Transcript.init(arena_impl.allocator());

    try t.appendSyntheticReason("task completed", 3);
    const m = t.items()[0];
    try std.testing.expect(m.role == .assistant);
    try std.testing.expectEqualStrings("task completed", m.content);
    try std.testing.expect(m.synthetic);
    try std.testing.expectEqual(@as(?u32, 3), m.prompt_index);

    // Null prompt_index is allowed (unknown / preamble rows).
    try t.appendSyntheticReason("interjection", null);
    const m2 = t.items()[1];
    try std.testing.expect(m2.synthetic);
    try std.testing.expect(m2.prompt_index == null);
    try std.testing.expect(m2.reasoning == null);
}
