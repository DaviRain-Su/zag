//! Contract tests: wire shapes Agent depends on (no network).
//!
//! These pin parsing + request body encoding so openai-zig upgrades cannot
//! silently break the harness.

const std = @import("std");
const types = @import("types.zig");
const openai_compat = @import("openai_compat.zig");
const gen = @import("openai_zig").generated;

test "contract: assistant text stop turn" {
    const gpa = std.testing.allocator;
    const turn = try openai_compat.turnFromResponse(gpa, .{
        .id = "chatcmpl_test",
        .object = "chat.completion",
        .choices = &.{
            .{
                .index = 0,
                .finish_reason = "stop",
                .message = .{
                    .role = "assistant",
                    .content = "done",
                },
            },
        },
        .usage = .{
            .prompt_tokens = 3,
            .completion_tokens = 1,
            .total_tokens = 4,
        },
    });
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
    }
    try std.testing.expectEqualStrings("done", turn.content);
    try std.testing.expectEqualStrings("stop", turn.finish_reason);
    try std.testing.expect(!turn.wantsTools());
    try std.testing.expectEqual(@as(u32, 4), turn.usage.?.total_tokens);
}

test "contract: tool_calls round-trip fields" {
    const gpa = std.testing.allocator;
    const turn = try openai_compat.turnFromResponse(gpa, .{
        .choices = &.{
            .{
                .finish_reason = "tool_calls",
                .message = .{
                    .tool_calls = &.{
                        .{
                            .id = "call_abc",
                            .@"type" = "function",
                            .function = .{
                                .name = "read_file",
                                .arguments = "{\"path\":\"src/main.zig\"}",
                            },
                        },
                    },
                },
            },
        },
    });
    defer {
        gpa.free(turn.content);
        gpa.free(turn.finish_reason);
        for (turn.tool_calls) |tc| {
            gpa.free(tc.id);
            gpa.free(tc.name);
            gpa.free(tc.arguments);
        }
        gpa.free(turn.tool_calls);
    }
    try std.testing.expect(turn.wantsTools());
    try std.testing.expectEqual(@as(usize, 1), turn.tool_calls.len);
    try std.testing.expectEqualStrings("call_abc", turn.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", turn.tool_calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, turn.tool_calls[0].arguments, "main.zig") != null);
}

test "contract: request body encodes agent messages and tools" {
    const gpa = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const msgs = [_]types.Message{
        types.Message.system("you are zag"),
        types.Message.user("list files"),
        types.Message.assistantToolCalls("", &calls),
        types.Message.toolResult("c1", "main.zig\n"),
    };
    const tools = [_]types.ToolDefinition{.{
        .name = "list_dir",
        .description = "List directory",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
        ,
    }};
    const body = try openai_compat.buildRequestBody(gpa, "deepseek-v4-flash", &msgs, &tools, .{
        .temperature = 0.0,
        .tool_choice = .auto,
        .max_tokens = 1024,
    }, false);
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"list_dir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0") != null);
}

test "contract: force function tool_choice JSON shape" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{types.Message.user("x")};
    const body = try openai_compat.buildRequestBody(gpa, "m", &msgs, &.{}, .{
        .tool_choice = .{ .function = "run_shell" },
    }, false);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"run_shell\"") != null);
}

test "contract: empty choices is invalid" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, openai_compat.turnFromResponse(gpa, .{
        .choices = &.{},
    }));
}

test "contract: mapSdkError surface used by agent" {
    try std.testing.expectEqual(error.AuthenticationFailed, openai_compat.mapSdkError(error.AuthenticationError));
    try std.testing.expectEqual(error.RateLimited, openai_compat.mapSdkError(error.RateLimitError));
    try std.testing.expect(types.isRetryableError(openai_compat.mapSdkError(error.RateLimitError)));
    try std.testing.expect(!types.isRetryableError(openai_compat.mapSdkError(error.AuthenticationError)));
}

test "contract: WireAdapter vtable exposes openai_compat style" {
    // Pure surface check — no network. Client init needs valid-looking config only.
    const gpa = std.testing.allocator;
    var client = openai_compat.Client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test",
        .model = "test-model",
    });
    defer client.deinit();
    const w = client.asWire();
    try std.testing.expect(w.apiStyle() == .openai_compat);
    try std.testing.expectEqualStrings("openai_compat", w.name());
}

test "contract: createWire accepts anthropic_messages style" {
    const gpa = std.testing.allocator;
    // Init only — no network until chat.
    var w = try openai_compat.createWire(gpa, std.testing.io, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "sk-ant-test",
        .model = "claude-sonnet-4-20250514",
    }, .anthropic_messages);
    defer w.deinit();
    try std.testing.expect(w.apiStyle() == .anthropic_messages);
    try std.testing.expectEqualStrings("anthropic_messages", w.name());
}

test "contract: toChatMessages preserves tool result" {
    const gpa = std.testing.allocator;
    const msgs = [_]types.Message{
        types.Message.toolResult("tid", "ok"),
    };
    const out = try openai_compat.toChatMessages(gpa, &msgs);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("tool", out[0].role);
    try std.testing.expectEqualStrings("tid", out[0].tool_call_id.?);
    try std.testing.expectEqualStrings("ok", out[0].content.?);
}

// Keep gen import used (ensures CreateChatCompletionResponse still has usage).
test "contract: generated usage shape" {
    const u: gen.CompletionUsage = .{
        .prompt_tokens = 1,
        .completion_tokens = 2,
        .total_tokens = 3,
    };
    try std.testing.expectEqual(@as(i64, 3), u.total_tokens);
}
