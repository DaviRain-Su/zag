//! External SDK consumer fixture — proves monorepo packages compose without
//! private source paths. All imports use declared package module names only.

const std = @import("std");
const zt = @import("zag-types");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");

// ── import contract sanity test ─────────────────────────────────────────────

test "consumer fixture only imports public package modules" {
    // Embed this source file and verify every @import argument is a declared
    // public module name, never a relative sibling-package source path.
    const source = @embedFile(@src().file);
    const allowed = &[_][]const u8{ "std", "builtin", "zag-types", "zag-agent-core", "zag-coding-agent" };

    var i: usize = 0;
    while (i < source.len) {
        // Skip double-quoted string literals (including the literal "@import(" used below).
        if (source[i] == '\"') {
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                    continue;
                }
                if (source[i] == '\"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        // Skip single-line comments.
        if (std.mem.startsWith(u8, source[i..], "//")) {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            i += "@import(".len;
            while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
            if (i >= source.len or source[i] != '\"') return error.TestUnexpectedResult;
            i += 1;
            const start = i;
            while (i < source.len and source[i] != '\"') i += 1;
            if (i >= source.len) return error.TestUnexpectedResult;
            const arg = source[start..i];
            var ok = false;
            for (allowed) |a| {
                if (std.mem.eql(u8, arg, a)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                std.log.err("illegal import argument: {s}", .{arg});
                return error.TestUnexpectedResult;
            }
            i += 1; // skip closing quote
            while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
            if (i >= source.len or source[i] != ')') return error.TestUnexpectedResult;
            i += 1;
            continue;
        }
        i += 1;
    }
}

// ── low-level core composition ──────────────────────────────────────────────

test "low-level zag-types + zag-agent-core composition" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Counter = struct {
        n: u32 = 0,
        fn h(ctx: core.tool.Context, instance: ?*anyopaque, _: []const u8) core.tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.n += 1;
            return std.fmt.allocPrint(ctx.allocator, "{d}", .{self.n}) catch return error.OutOfMemory;
        }
    };
    var counter: Counter = .{};

    const custom_tool = try core.tool.buildTool(gpa, .{
        .definition = .{
            .name = "counter",
            .description = "stateful counter",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &counter,
        .handler = Counter.h,
    });

    const MockProvider = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const core.message.Message,
            _: []const core.tool.Definition,
            _: core.provider.RequestControl,
        ) core.provider.ChatError!core.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(core.message.ToolCall, 1);
                tc[0] = .{
                    .id = "c1",
                    .name = "counter",
                    .arguments = "{}",
                };
                return .{
                    .content = "calling",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = "done",
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: MockProvider = .{};
    const provider = core.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("count");

    const toolset = try core.tool.Toolset.initValidated(gpa, &[_]core.tool.Tool{custom_tool});

    const result = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = toolset,
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), counter.n);
    try std.testing.expectEqual(core.loop.StopReason.completed, result.stop_reason);
}

// ── high-level coding.Agent composition helpers ─────────────────────────────

const ObservedEvent = union(enum) {
    assistant_text,
    usage,
    tool_call: []const u8,
    tool_result: []const u8,
    permission: struct { allowed: bool, remembered: bool },

    fn deinit(self: ObservedEvent, gpa: std.mem.Allocator) void {
        switch (self) {
            .tool_call => |n| gpa.free(n),
            .tool_result => |n| gpa.free(n),
            else => {},
        }
    }
};

const RecordingObserver = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(ObservedEvent) = .empty,

    fn init(gpa: std.mem.Allocator) RecordingObserver {
        return .{
            .gpa = gpa,
            .events = .empty,
        };
    }

    fn deinit(self: *RecordingObserver) void {
        for (self.events.items) |e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    fn observer(self: *RecordingObserver) coding.observer.Observer {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    fn onEvent(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *RecordingObserver = @ptrCast(@alignCast(ptr.?));
        const observed: ObservedEvent = switch (event) {
            .assistant_text => .assistant_text,
            .usage => .usage,
            .tool_call => |c| .{ .tool_call = self.gpa.dupe(u8, c.name) catch return },
            .tool_result => |r| .{ .tool_result = self.gpa.dupe(u8, r.name) catch return },
            .permission => |p| .{ .permission = .{ .allowed = p.allowed, .remembered = p.remembered } },
        };
        self.events.append(self.gpa, observed) catch {
            observed.deinit(self.gpa);
        };
    }
};

test "high-level coding.Agent injects custom tool, provider, observer, and ask policy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const WriteStub = struct {
        ran: bool = false,
        fn h(ctx: core.tool.Context, instance: ?*anyopaque, _: []const u8) core.tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return ctx.allocator.dupe(u8, "ok") catch return error.OutOfMemory;
        }
    };
    var stub: WriteStub = .{};
    const custom_tool = try coding.tool.buildTool(gpa, .{
        .definition = .{
            .name = "noop_write",
            .description = "stateful write stub",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &stub,
        .handler = WriteStub.h,
    });

    const MockProvider = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(coding.message.ToolCall, 1);
                tc[0] = .{
                    .id = "c1",
                    .name = "noop_write",
                    .arguments = try arena.dupe(u8, "{\"path\":\"x.txt\"}"),
                };
                return .{
                    .content = "calling",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = "done",
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: MockProvider = .{};
    const provider = coding.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var recording = RecordingObserver.init(gpa);
    defer recording.deinit();

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .ask,
        .permission_gate = coding.permissions.Gate.ask(alwaysAllowAsk, null),
        .toolset = &[_]coding.tool.Tool{custom_tool},
        .observer = recording.observer(),
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "write something");

    try std.testing.expect(stub.ran);
    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(coding.loop.StopReason.completed, result.stop_reason);

    // Observer event sequence: tool_call → permission(allow) → tool_result.
    try std.testing.expect(recording.events.items.len >= 3);
    var saw_tool_call = false;
    var saw_permission = false;
    var saw_tool_result = false;
    for (recording.events.items) |ev| {
        switch (ev) {
            .tool_call => |n| {
                if (std.mem.eql(u8, n, "noop_write")) saw_tool_call = true;
            },
            .permission => |p| {
                if (p.allowed) saw_permission = true;
            },
            .tool_result => |n| {
                if (std.mem.eql(u8, n, "noop_write")) saw_tool_result = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_tool_call);
    try std.testing.expect(saw_permission);
    try std.testing.expect(saw_tool_result);
}

fn alwaysAllowAsk(_: ?*anyopaque, _: coding.tool.ToolDescriptor, _: []const u8) coding.permissions.Decision {
    return .allow;
}

test "high-level ask policy deny path does not execute tool" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const WriteStub = struct {
        ran: bool = false,
        fn h(_: core.tool.Context, instance: ?*anyopaque, _: []const u8) core.tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return error.ToolFailed;
        }
    };
    var stub: WriteStub = .{};
    const custom_tool = try coding.tool.buildTool(gpa, .{
        .definition = .{
            .name = "deny_write",
            .description = "should not run",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &stub,
        .handler = WriteStub.h,
    });

    const MockProvider = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(coding.message.ToolCall, 1);
                tc[0] = .{
                    .id = "d1",
                    .name = "deny_write",
                    .arguments = try arena.dupe(u8, "{\"path\":\"x.txt\"}"),
                };
                return .{
                    .content = "calling",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = "denied ok",
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: MockProvider = .{};
    const provider = coding.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var recording = RecordingObserver.init(gpa);
    defer recording.deinit();

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .ask,
        .permission_gate = coding.permissions.Gate.ask(alwaysDenyAsk, null),
        .toolset = &[_]coding.tool.Tool{custom_tool},
        .observer = recording.observer(),
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "write something");

    try std.testing.expect(!stub.ran);
    try std.testing.expectEqualStrings("denied ok", result.final_text);

    // Observer must record a permission deny event for deny_write.
    var saw_deny = false;
    for (recording.events.items) |ev| {
        switch (ev) {
            .permission => |p| {
                if (!p.allowed) saw_deny = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_deny);
}

fn alwaysDenyAsk(_: ?*anyopaque, _: coding.tool.ToolDescriptor, _: []const u8) coding.permissions.Decision {
    return .deny;
}

// ── cancellation (between tools, not mid-flight) ───────────────────────────

test "high-level cancel after assistant tool_calls fills pending with cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const MockProvider = struct {
        agent: *coding.Agent,
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            // Request cancellation after the model has emitted tool_calls.
            self.agent.requestCancel();
            const tc = try arena.alloc(coding.message.ToolCall, 2);
            tc[0] = .{
                .id = "t1",
                .name = "unknown_tool",
                .arguments = "{}",
            };
            tc[1] = .{
                .id = "t2",
                .name = "unknown_tool",
                .arguments = "{}",
            };
            return .{
                .content = "calling",
                .tool_calls = tc,
                .finish_reason = "tool_calls",
            };
        }
    };

    // Provider needs a stable pointer to the agent; fill it after Agent.init.
    var provider_state: MockProvider = .{ .agent = undefined };
    const provider = coding.provider.Provider{
        .ptr = &provider_state,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .toolset = &[_]coding.tool.Tool{},
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    provider_state.agent = &agent;

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "call two");

    try std.testing.expectEqual(coding.loop.StopReason.cancelled, result.stop_reason);

    var cancelled_tools: u32 = 0;
    for (session.transcript.items()) |m| {
        if (m.role == .tool and core.tool_error.hasCode(m.content, .cancelled)) {
            cancelled_tools += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), cancelled_tools);
}

// ── session persistence ─────────────────────────────────────────────────────

fn runChmod(path: []const u8, mode: u16) !void {
    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    if (std.c.chmod(zpath, mode) != 0) return error.ChmodFailed;
}

test "session create → reply → save → resume preserves transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-sdk-session";
    const path = ".zag-test-sdk-session/session.jsonl";
    std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const MockProvider = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "hello-back"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: MockProvider = .{};
    const provider = coding.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();

    // Create + reply + auto-save.
    {
        var session = try coding.Session.start(gpa, io, .{
            .base_system = "system",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "hello");
        try std.testing.expectEqualStrings("hello-back", result.final_text);
    }

    // Resume and verify transcript continuity.
    {
        var resumed = try coding.Session.start(gpa, io, .{
            .base_system = "system",
            .path = path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        defer resumed.deinit();

        var saw_user = false;
        var saw_assistant = false;
        for (resumed.transcript.items()) |m| {
            if (m.role == .user and std.mem.eql(u8, m.content, "hello")) saw_user = true;
            if (m.role == .assistant and std.mem.eql(u8, m.content, "hello-back")) saw_assistant = true;
        }
        try std.testing.expect(saw_user);
        try std.testing.expect(saw_assistant);

        const result2 = try agent.reply(&resumed, "again");
        try std.testing.expectEqualStrings("hello-back", result2.final_text);
    }
}

test "session save error returns session_error and preserves prior bytes" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) {
        return error.SkipZigTest;
    }

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-sdk-save-error";
    const path = ".zag-test-sdk-save-error/session.jsonl";
    std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const MockProvider = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "reply"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: MockProvider = .{};
    const provider = coding.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = MockProvider.chat },
    };

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    // Snapshot durable bytes after successful create.
    const prior = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(prior);
    try std.testing.expect(prior.len > 0);

    // Make parent directory read-only so the atomic save temp write fails.
    try runChmod(dir_name, 0o555);
    defer runChmod(dir_name, 0o755) catch {};

    const err = agent.reply(&session, "hello");
    try std.testing.expectError(error.IoFailed, err);

    // Restore write permission for cleanup and byte comparison.
    try runChmod(dir_name, 0o755);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(prior, after);
}
