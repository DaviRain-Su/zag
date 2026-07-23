//! Shared chat types for OpenAI-compatible APIs (wire + transcript shapes).

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

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const Message = struct {
    role: Role,
    content: []const u8 = "",
    tool_calls: ?[]const ToolCall = null,
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
        return .{ .role = .assistant, .content = content, .tool_calls = calls };
    }
    pub fn toolResult(tool_call_id: []const u8, content: []const u8) Message {
        return .{ .role = .tool, .content = content, .tool_call_id = tool_call_id };
    }
};

pub const AssistantTurn = struct {
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    finish_reason: []const u8 = "",

    pub fn wantsTools(self: AssistantTurn) bool {
        return self.tool_calls.len > 0;
    }
};

/// Tool schema exposed to the model (no local handler — handlers live in zag agent).
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    /// Partial tool call assembly (id/name may appear once; arguments stream as deltas).
    tool_call_delta: struct {
        index: usize,
        id: []const u8 = "",
        name: []const u8 = "",
        arguments_delta: []const u8 = "",
    },
    finish_reason: []const u8,
    done,
};

test "role json names" {
    try std.testing.expectEqualStrings("user", Role.user.jsonName());
}
