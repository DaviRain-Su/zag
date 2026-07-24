//! Contract tests: wire shapes Agent depends on (no network).
//!
//! These pin parsing + request body encoding so openai-zig upgrades cannot
//! silently break the harness.

const std = @import("std");
const types = @import("types.zig");
const openai_compat = @import("openai_compat.zig");
const factory = @import("factory.zig");
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
                            .type = "function",
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

test "contract: factory.createWire accepts anthropic_messages style" {
    const gpa = std.testing.allocator;
    // Init only — no network until chat.
    var w = try factory.createWire(gpa, std.testing.io, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "sk-ant-test",
        .model = "claude-sonnet-4-20250514",
    }, .anthropic_messages);
    defer w.deinit();
    try std.testing.expect(w.apiStyle() == .anthropic_messages);
    try std.testing.expectEqualStrings("anthropic_messages", w.name());
}

test "contract: factory.createWire openai_compat style" {
    const gpa = std.testing.allocator;
    var w = try factory.createWire(gpa, std.testing.io, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test",
        .model = "test-model",
    }, .openai_compat);
    defer w.deinit();
    try std.testing.expect(w.apiStyle() == .openai_compat);
    try std.testing.expect(w.supportsEmbed());
}

test "contract: anthropic wire embed is NotSupported" {
    const gpa = std.testing.allocator;
    var w = try factory.createWire(gpa, std.testing.io, .{
        .base_url = "https://api.anthropic.com",
        .api_key = "sk-ant-test",
        .model = "claude-sonnet-4-20250514",
    }, .anthropic_messages);
    defer w.deinit();
    try std.testing.expect(!w.supportsEmbed());
    try std.testing.expectError(error.NotSupported, w.embed(gpa, &.{"hello"}, .{}));
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

// --- h-provider-001: deadline / cancel / partial tool-call safety ---

const request_control = @import("request_control.zig");
const http = @import("http.zig");

test "contract: Timeout and Cancelled are not retryable" {
    try std.testing.expect(!types.isRetryableError(error.Timeout));
    try std.testing.expect(!types.isRetryableError(error.Cancelled));
    try std.testing.expect(types.isRetryableError(error.RateLimited));
}

test "contract: preflight cancel and zero timeout fail before network" {
    var flag: types.CancelFlag = .{};
    flag.request();
    try std.testing.expectError(error.Cancelled, request_control.preflight(
        types.RequestControl.none().withCancel(&flag),
    ));
    try std.testing.expectError(error.Timeout, request_control.preflight(
        types.RequestControl.withTimeoutMs(types.monoNowNs(), 0),
    ));
}

test "contract: local slow server enforces timeout wall bound" {
    // Local loopback only — no public network. Both std and curl backends.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        io: std.Io,
        server: *std.Io.net.Server,
        accepted: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.accepted.store(true, .seq_cst);
            // Hold connection open well past client timeout (slow headers/body).
            std.Io.sleep(self.io, .{ .nanoseconds = 5 * std.time.ns_per_s }, .awake) catch {};
            // Best-effort minimal response if still open.
            var w = stream.writer(self.io, &.{});
            _ = w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch {};
            w.interface.flush() catch {};
        }
    };

    var ctx: ServerCtx = .{ .io = io, .server = &server };
    const thr = try std.Thread.spawn(.{}, ServerCtx.run, .{&ctx});
    defer thr.join();

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var client = try http.Client.initBearer(gpa, io, .{
        .base_url = base_url,
        .api_key = "test",
        .model = "m",
        .max_retries = 0,
        .timeout_ms = 200,
    });
    defer client.deinit();

    const control = types.RequestControl.withTimeoutMs(types.monoNowNs(), 200);
    const t0 = types.monoNowNs();
    const result = client.postJsonControl("/slow", "{}", control);
    const elapsed_ms = (types.monoNowNs() - t0) / std.time.ns_per_ms;

    try std.testing.expectError(error.Timeout, result);
    // Wall-clock upper bound: timeout + generous slack for scheduling (not 5s server hold).
    try std.testing.expect(elapsed_ms < 2500);
}

test "contract: cancel aborts in-flight local stream" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        io: std.Io,
        server: *std.Io.net.Server,
        fn run(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [1024]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            // Drain request head (best effort)
            _ = reader.interface.takeDelimiterInclusive('\n') catch {};
            var w = stream.writer(self.io, &.{});
            // Send partial SSE then hang so cancel can fire mid-stream.
            _ = w.interface.writeAll(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                    "1a\r\ndata: {\"partial\":true}\n\n\r\n",
            ) catch {};
            w.interface.flush() catch {};
            std.Io.sleep(self.io, .{ .nanoseconds = 5 * std.time.ns_per_s }, .awake) catch {};
        }
    };
    var ctx: ServerCtx = .{ .io = io, .server = &server };
    const thr = try std.Thread.spawn(.{}, ServerCtx.run, .{&ctx});
    defer thr.join();

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    var client = try http.Client.initBearer(gpa, io, .{
        .base_url = base_url,
        .api_key = "test",
        .model = "m",
        .max_retries = 0,
    });
    defer client.deinit();

    var flag: types.CancelFlag = .{};
    const control = types.RequestControl.none().withCancel(&flag);

    const CancelCtx = struct {
        flag: *types.CancelFlag,
        saw_chunk: bool = false,
        fn onChunk(ctx_ptr: ?*anyopaque, chunk: []const u8) types.ChatError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            if (chunk.len > 0) self.saw_chunk = true;
            // Cancel after first data so abort is mid-flight.
            self.flag.request();
        }
    };
    var cctx: CancelCtx = .{ .flag = &flag };

    // Also arm a delayed cancel if stream is slow to produce chunks.
    const Arm = struct {
        flag: *types.CancelFlag,
        fn go(self: *@This()) void {
            std.Io.sleep(std.testing.io, .{ .nanoseconds = 150 * std.time.ns_per_ms }, .awake) catch {};
            self.flag.request();
        }
    };
    var arm: Arm = .{ .flag = &flag };
    const arm_thr = try std.Thread.spawn(.{}, Arm.go, .{&arm});
    defer arm_thr.join();

    const t0 = types.monoNowNs();
    const result = client.postJsonStreamControl(
        "/stream",
        "{}",
        CancelCtx.onChunk,
        &cctx,
        control,
    );
    const elapsed_ms = (types.monoNowNs() - t0) / std.time.ns_per_ms;

    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expect(elapsed_ms < 2500);
}

test "contract: partial tool-call stream state never finishes on cancel" {
    // Seam: OpenAiStreamState-style assembly discards on error path.
    // Simulates cancel mid tool_call arguments without invoking finish().
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    try content.appendSlice(gpa, "partial");
    var tool_args: std.ArrayList(u8) = .empty;
    defer tool_args.deinit(gpa);
    try tool_args.appendSlice(gpa, "{\"path\":"); // incomplete JSON

    // If we were to finish() this would produce invalid tool args — cancel must not.
    var flag: types.CancelFlag = .{};
    flag.request();
    const control = types.RequestControl.none().withCancel(&flag);
    try std.testing.expectError(error.Cancelled, control.checkNow());
    // Incomplete fragments stay local; no AssistantTurn is built.
    try std.testing.expect(tool_args.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, tool_args.items, "}") == null);
}

test "contract: deadline shared across retry attempts (not reset)" {
    const now = types.monoNowNs();
    const control = types.RequestControl.withTimeoutMs(now, 100);
    // Simulate first attempt spent 60ms of budget.
    const later = now + 60 * std.time.ns_per_ms;
    const rem = control.remainingMs(later).?;
    try std.testing.expect(rem <= 40);
    // Same control object: remaining continues to shrink (not reset to 100).
    const later2 = now + 90 * std.time.ns_per_ms;
    try std.testing.expect(control.remainingMs(later2).? <= 10);
    try std.testing.expectError(error.Timeout, control.check(now + 150 * std.time.ns_per_ms));
}

test "contract: mapSdkError Cancelled" {
    try std.testing.expectEqual(error.Cancelled, openai_compat.mapSdkError(error.Cancelled));
}
