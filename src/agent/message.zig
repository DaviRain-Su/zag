//! Agent message protocol (OpenAI-compatible shapes).
//!
//! These types are the transcript: everything the loop sends to the model and
//! everything that comes back. Ownership: strings are borrowed; the caller
//! (usually an arena) owns the underlying bytes for the lifetime of the run.

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonName(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

/// One model-requested function call.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON object string, e.g. `{"path":"."}`.
    arguments: []const u8,
};

/// A single entry in the conversation transcript.
pub const Message = struct {
    role: Role,
    /// Text content. Empty string is allowed (e.g. assistant-only tool_calls).
    content: []const u8 = "",
    /// Present on assistant messages that request tools.
    tool_calls: ?[]const ToolCall = null,
    /// Present on tool result messages; must match a prior tool_call.id.
    tool_call_id: ?[]const u8 = null,

    pub fn user(content: []const u8) Message {
        return .{ .role = .user, .content = content };
    }

    pub fn system(content: []const u8) Message {
        return .{ .role = .system, .content = content };
    }

    pub fn assistantText(content: []const u8) Message {
        return .{ .role = .assistant, .content = content };
    }

    pub fn assistantToolCalls(content: []const u8, calls: []const ToolCall) Message {
        return .{
            .role = .assistant,
            .content = content,
            .tool_calls = calls,
        };
    }

    pub fn toolResult(tool_call_id: []const u8, content: []const u8) Message {
        return .{
            .role = .tool,
            .content = content,
            .tool_call_id = tool_call_id,
        };
    }
};

/// One completion turn from the provider.
pub const AssistantTurn = struct {
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    /// Raw finish_reason from the API when available.
    finish_reason: []const u8 = "",

    pub fn wantsTools(self: AssistantTurn) bool {
        return self.tool_calls.len > 0;
    }
};

test "role json names" {
    try std.testing.expectEqualStrings("user", Role.user.jsonName());
    try std.testing.expectEqualStrings("tool", Role.tool.jsonName());
}
