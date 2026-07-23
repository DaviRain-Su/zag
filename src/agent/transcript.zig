//! Conversation transcript — the only place that owns message string storage
//! for a run/session.
//!
//! Business code should call append* helpers; it should not touch arenas or
//! duplicate tool_call slices by hand.

const std = @import("std");
const message = @import("message.zig");

pub const Error = error{OutOfMemory};

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

    /// Persist an assistant turn (text and optional tool_calls) into the ledger.
    pub fn appendAssistantTurn(self: *Transcript, turn: message.AssistantTurn) Error!void {
        const content = self.arena.dupe(u8, turn.content) catch return error.OutOfMemory;

        if (turn.tool_calls.len == 0) {
            self.messages.append(self.arena, message.Message.assistantText(content)) catch
                return error.OutOfMemory;
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
        self.messages.append(self.arena, message.Message.assistantToolCalls(content, calls)) catch
            return error.OutOfMemory;
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
