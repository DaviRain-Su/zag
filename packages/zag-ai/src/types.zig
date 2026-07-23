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

/// Token usage reported by the provider (when present).
pub const Usage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    /// Optional reasoning tokens (o-series / some providers).
    reasoning_tokens: u32 = 0,

    pub fn fromCounts(prompt: i64, completion: i64, total: i64) Usage {
        return .{
            .prompt_tokens = clampU32(prompt),
            .completion_tokens = clampU32(completion),
            .total_tokens = clampU32(total),
        };
    }

    fn clampU32(v: i64) u32 {
        if (v <= 0) return 0;
        if (v >= std.math.maxInt(u32)) return std.math.maxInt(u32);
        return @intCast(v);
    }
};

pub const AssistantTurn = struct {
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    finish_reason: []const u8 = "",
    /// Null when the provider omitted usage (common for some streams).
    usage: ?Usage = null,

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

/// How the model should pick tools for this request.
pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    /// Force a single function by name.
    function: []const u8,
};

/// Per-request knobs for chat completions (optional; defaults keep current behavior).
pub const ChatOptions = struct {
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    tool_choice: ?ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    user: ?[]const u8 = null,
    seed: ?u64 = null,
    /// Free-form provider fields merged into the JSON body (via openai-zig `extra_body`).
    extra_body: ?std.json.Value = null,
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

/// Classify provider failures for retry / UX (agent loop may map all to ProviderFailed).
pub fn isRetryableError(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Timeout, error.ServerError, error.HttpFailed => true,
        else => false,
    };
}

test "role json names" {
    try std.testing.expectEqualStrings("user", Role.user.jsonName());
}

test "usage clamp" {
    const u = Usage.fromCounts(10, 5, 15);
    try std.testing.expectEqual(@as(u32, 10), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 5), u.completion_tokens);
    try std.testing.expectEqual(@as(u32, 15), u.total_tokens);
}

test "isRetryableError" {
    try std.testing.expect(isRetryableError(error.RateLimited));
    try std.testing.expect(!isRetryableError(error.AuthenticationFailed));
}
