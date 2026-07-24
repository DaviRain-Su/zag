//! Agent harness loop — business only.
//!
//! ```
//! transcript ──► context.view ──► provider.chat
//!      ▲                               │
//!      │                          tool_calls?
//!      │                          no → done
//!      │                          yes ↓
//!      │              permission → jail → shell policy
//!      │                     deny → soft tool error
//!      │                     allow → execute
//!      └──────── tool results ────────┘
//! ```

const std = @import("std");
const zt = @import("zag-types");
const message = @import("message.zig");
const tool = @import("tool.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const observer_mod = @import("observer.zig");
const permissions = @import("permissions.zig");
const context_mod = @import("context.zig");
const workspace = @import("workspace.zig");
const shell_policy = @import("shell_policy.zig");
const trace_mod = @import("trace.zig");

pub const default_max_turns: u32 = 20;

pub const Options = struct {
    max_turns: u32 = default_max_turns,
    observer: observer_mod.Observer = .none(),
    permission_gate: permissions.Gate = .yolo(),
    context: context_mod.Options = .{},
    shell_policy: shell_policy.Mode = .protect,
    /// Optional structured audit log (not freed by loop).
    trace: ?*trace_mod.Trace = null,
    /// Extra chat attempts on retryable provider errors (0 = no loop-level retry).
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
};

pub const RunError = error{
    MaxTurnsExceeded,
    ProviderFailed,
    OutOfMemory,
};

pub const Result = struct {
    final_text: []const u8,
    turns: u32,
    /// Sum of provider-reported usage across chat turns (zeros if none reported).
    usage: message.Usage = .{},
};

pub const Deps = struct {
    gpa: std.mem.Allocator,
    provider: provider_mod.Provider,
    toolset: tool.Toolset,
    tool_ctx: tool.Context,
    options: Options = .{},
};

pub fn run(deps: Deps, transcript: *transcript_mod.Transcript) RunError!Result {
    var turns: u32 = 0;
    var last_text: []const u8 = "";
    var usage_total: message.Usage = .{};

    while (turns < deps.options.max_turns) {
        turns += 1;
        if (deps.options.trace) |tr| {
            tr.emitTurn(turns) catch {};
        }

        var turn_arena_impl: std.heap.ArenaAllocator = .init(deps.gpa);
        defer turn_arena_impl.deinit();
        const scratch = turn_arena_impl.allocator();

        const view = context_mod.viewForModel(
            scratch,
            transcript.items(),
            deps.options.context,
        ) catch return error.OutOfMemory;

        const turn = try chatWithRetry(deps, scratch, view.messages);

        try transcript.appendAssistantTurn(turn);
        last_text = transcript.items()[transcript.items().len - 1].content;
        deps.options.observer.emit(.{ .assistant_text = last_text });
        if (deps.options.trace) |tr| {
            tr.emitAssistant(last_text) catch {};
            tr.emitUsage(turn) catch {};
        }
        if (turn.usage) |u| {
            usage_total.add(u);
            deps.options.observer.emit(.{ .usage = u });
        }

        if (!turn.wantsTools()) {
            return .{ .final_text = last_text, .turns = turns, .usage = usage_total };
        }

        const last_msg = transcript.items()[transcript.items().len - 1];
        const calls = last_msg.tool_calls orelse {
            return .{ .final_text = last_text, .turns = turns, .usage = usage_total };
        };

        const registry = deps.toolset.registry();
        for (calls) |call| {
            deps.options.observer.emit(.{ .tool_call = call });
            if (deps.options.trace) |tr| {
                tr.emitToolCall(call) catch {};
            }

            // 1) Human permission gate
            const decision = deps.options.permission_gate.decide(call.name, call.arguments);
            const allowed = decision == .allow;
            deps.options.observer.emit(.{
                .permission = .{ .tool_name = call.name, .allowed = allowed },
            });
            if (deps.options.trace) |tr| {
                tr.emitPermission(call.name, allowed) catch {};
            }

            if (!allowed) {
                const denied = permissions.deniedMessage(deps.tool_ctx.allocator, call.name) catch
                    return error.OutOfMemory;
                defer deps.tool_ctx.allocator.free(denied);
                try finishTool(deps, transcript, call, denied);
                continue;
            }

            // 2) Path jail
            if (workspace.toolUsesPath(call.name)) {
                if (try pathJailCheck(deps, call)) |deny_body| {
                    defer deps.tool_ctx.allocator.free(deny_body);
                    try finishTool(deps, transcript, call, deny_body);
                    continue;
                }
            }

            // 3) Shell policy
            if (std.mem.eql(u8, call.name, "run_shell")) {
                if (try shellPolicyCheck(deps, call.arguments)) |deny_body| {
                    defer deps.tool_ctx.allocator.free(deny_body);
                    try finishTool(deps, transcript, call, deny_body);
                    continue;
                }
            }

            const raw = registry.execute(deps.tool_ctx, call.name, call.arguments) catch
                return error.OutOfMemory;
            defer deps.tool_ctx.allocator.free(raw);
            try finishTool(deps, transcript, call, raw);
        }
    }

    return error.MaxTurnsExceeded;
}

fn chatWithRetry(
    deps: Deps,
    scratch: std.mem.Allocator,
    messages: []const message.Message,
) RunError!message.AssistantTurn {
    const max_attempts: u32 = @as(u32, deps.options.chat_retries) + 1;
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const result = deps.provider.chat(
            scratch,
            messages,
            deps.toolset.tools,
        );
        if (result) |turn| {
            return turn;
        } else |err| {
            const retryable = zt.isRetryableError(err);
            const more = attempt + 1 < max_attempts;
            if (!retryable or !more) return error.ProviderFailed;

            if (deps.options.trace) |tr| {
                tr.emitProviderRetry(attempt + 1, @errorName(err)) catch {};
            }
            if (deps.options.observer.on_event != null) {
                std.log.warn(
                    "provider retry {d}/{d} after {s}",
                    .{ attempt + 1, deps.options.chat_retries, @errorName(err) },
                );
            }
            const delay_ms = deps.options.retry_base_delay_ms * (@as(u64, 1) << @intCast(@min(attempt, 4)));
            const duration: std.Io.Duration = .{ .nanoseconds = @intCast(delay_ms * std.time.ns_per_ms) };
            std.Io.sleep(deps.tool_ctx.io, duration, .real) catch {};
        }
    }
    return error.ProviderFailed;
}

fn finishTool(
    deps: Deps,
    transcript: *transcript_mod.Transcript,
    call: message.ToolCall,
    body: []const u8,
) RunError!void {
    deps.options.observer.emit(.{
        .tool_result = .{ .name = call.name, .body = body },
    });
    if (deps.options.trace) |tr| {
        tr.emitToolResult(call.name, body) catch {};
    }
    try transcript.appendToolResult(call.id, body);
}

/// Returns owned deny message, or null if path is OK.
fn pathJailCheck(deps: Deps, call: message.ToolCall) RunError!?[]u8 {
    const path = workspace.pathArgument(deps.tool_ctx.allocator, call.arguments) catch
        return error.OutOfMemory;
    if (path == null) return null;
    defer deps.tool_ctx.allocator.free(path.?);

    workspace.checkToolPath(path.?) catch {
        if (deps.options.trace) |tr| {
            tr.emitJailDeny(call.name, path.?) catch {};
        }
        if (deps.options.observer.on_event != null) {
            std.log.warn("jail deny {s} path={s}", .{ call.name, path.? });
        }
        return try workspace.deniedMessage(deps.tool_ctx.allocator, path.?);
    };
    return null;
}

fn shellPolicyCheck(deps: Deps, arguments_json: []const u8) RunError!?[]u8 {
    const command = tool.requireStringField(deps.tool_ctx.allocator, arguments_json, "command") catch {
        return null; // let the tool report invalid args
    };
    defer deps.tool_ctx.allocator.free(command);

    if (shell_policy.check(deps.options.shell_policy, command) == .allow) return null;

    if (deps.options.trace) |tr| {
        tr.emitShellDeny(command) catch {};
    }
    if (deps.options.observer.on_event != null) {
        std.log.warn("shell policy deny: {s}", .{command});
    }
    return try shell_policy.deniedMessage(deps.tool_ctx.allocator, command);
}

test "loop stops when model returns text only" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), result.turns);
}

test "permission deny yields tool error without executing" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"x\",\"content\":\"y\"}"),
                };
                return .{
                    .content = "",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            _ = messages;
            return .{
                .content = try arena.dupe(u8, "understood, not writing"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write something");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{
            .permission_gate = .denyAllDangerous(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("understood, not writing", result.final_text);
    var found_deny = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and std.mem.indexOf(u8, m.content, "permission denied") != null) {
            found_deny = true;
        }
    }
    try std.testing.expect(found_deny);
}

test "jail deny absolute path without writing" {
    const gpa = std.testing.allocator;

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"/etc/passwd\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "blocked"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("read passwd");

    const result = try run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expectEqualStrings("blocked", result.final_text);
    var found = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and std.mem.indexOf(u8, m.content, "workspace jail") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}
