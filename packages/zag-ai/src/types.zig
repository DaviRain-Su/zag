//! Shared chat types for all wire adapters (canonical transcript + request shapes).

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

/// Multimodal content part (adapters map to vendor wire shapes).
pub const ContentPart = union(enum) {
    text: []const u8,
    /// Image by URL or data: URL. `detail` is optional (auto|low|high).
    image_url: struct {
        url: []const u8,
        detail: ?[]const u8 = null,
    },
};

pub const Message = struct {
    role: Role,
    /// Plain-text content (legacy / default path).
    content: []const u8 = "",
    /// When set, serialized as a content array (multimodal). Prefer over `content`.
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn user(content: []const u8) Message {
        return .{ .role = .user, .content = content };
    }
    pub fn userMultimodal(parts: []const ContentPart) Message {
        return .{ .role = .user, .content_parts = parts };
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

    /// Approximate character weight for context budgeting.
    pub fn estimateChars(self: Message) usize {
        var n: usize = self.content.len;
        if (self.tool_call_id) |id| n += id.len;
        if (self.tool_calls) |calls| {
            for (calls) |c| n += c.id.len + c.name.len + c.arguments.len;
        }
        if (self.content_parts) |parts| {
            for (parts) |p| {
                switch (p) {
                    .text => |t| n += t.len,
                    // Images cost far more tokens than URL length; rough char proxy.
                    .image_url => |img| n += img.url.len + 2_000,
                }
            }
        }
        return n;
    }
};

/// Options for `WireAdapter.embed` (vendors ignore unsupported fields).
pub const EmbedOptions = struct {
    /// Defaults to client config model when null.
    model: ?[]const u8 = null,
    dimensions: ?u32 = null,
    encoding_format: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

/// Result of an embedding request (arena-allocated vectors).
pub const EmbeddingResult = struct {
    model: []const u8 = "",
    /// One vector per input (order preserved).
    vectors: []const []const f64 = &.{},
    usage: ?Usage = null,
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
    /// Free-form vendor fields (OpenAI adapter maps to `extra_body`; others may ignore).
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

/// Live stream callback (shared by wire adapters and stream module).
pub const StreamHandler = *const fn (ctx: ?*anyopaque, event: StreamEvent) anyerror!void;

/// Classify provider failures for retry / UX (agent loop may map all to ProviderFailed).
pub fn isRetryableError(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Timeout, error.ServerError, error.HttpFailed => true,
        // NotSupported and auth/schema errors are permanent for the request.
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

test "isRetryableError does not treat NotSupported as retryable" {
    // wire.Error.NotSupported — agent should not retry capability gaps
    try std.testing.expect(!isRetryableError(error.NotSupported));
}
