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
        .tool_policy = core.loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = core.loop.Jail.allowAllForTrustedHost(),
        .shell_policy = core.loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = core.loop.ContextView.identity(),
        .event_sink = core.loop.LoopEventSink.discard(),
        .control_input = core.loop.ControlInput.none(),
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
    // chmod-based write-denial is only effective on Unix-like, non-root systems.
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) {
        return error.SkipZigTest;
    }
    // Root can still write to a 0o555 directory, so the failure path is not testable.
    if (std.c.geteuid() == 0) {
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

// ── D-011 session-store canonical ownership compile assertion ───────────────
//
// Proves an external SDK consumer resolves the product-owned `session_store`
// surface (moved from `zag-agent-core` to `zag-coding-agent` by
// core-session-ownership-001) through the public `zag-coding-agent` module
// root — not only indirectly via `coding.Session`. This is a compile-time
// canonical-ownership check, not a behavior test.

test "coding.session_store canonical symbol resolves from external consumer" {
    // The schema version constant is a stable product contract (D-006 v1).
    try std.testing.expectEqual(@as(u32, 1), coding.session_store.current_schema_version);
    // The Error set is publicly reachable; referencing it proves the canonical
    // module root compiles the product-owned session surface for consumers.
    const E = coding.session_store.Error;
    _ = E; // ownership/compile assertion only; no behavior exercised.
}

// ── session-fork-001: mandatory public fork API + durable smoke ───────────────
//
// External consumer imports coding-agent by module name only; exercises
// `Session.fork` and durable create + resume. No Core fork imports.

test "session-fork: public Session.fork + durable create/resume smoke" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-sdk-session-fork";
    const parent_path = ".zag-test-sdk-session-fork/parent.jsonl";
    const child_path = ".zag-test-sdk-session-fork/child.jsonl";
    std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    // Compile assertion: ForkError is public on coding-agent.
    const FE = coding.ForkError;
    _ = FE;

    const MockProvider = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "fork-smoke"),
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

    var parent = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer parent.deinit();

    try parent.transcript.appendUser("before-fork");
    try parent.save();
    const parent_bytes = try std.Io.Dir.cwd().readFileAlloc(io, parent_path, gpa, .limited(64 * 1024));
    defer gpa.free(parent_bytes);

    {
        var child = try parent.fork(child_path);
        defer child.deinit();

        // Parent durable bytes unchanged after fork
        const parent_after = try std.Io.Dir.cwd().readFileAlloc(io, parent_path, gpa, .limited(64 * 1024));
        defer gpa.free(parent_after);
        try std.testing.expectEqualStrings(parent_bytes, parent_after);

        try std.testing.expect(child.path != null);
        try std.testing.expectEqualStrings(child_path, child.path.?);

        // Durable smoke: child reply + save path (auto on reply) then resume
        const result = try agent.reply(&child, "from-child");
        try std.testing.expectEqualStrings("fork-smoke", result.final_text);
        try std.testing.expectEqual(coding.loop.StopReason.completed, result.stop_reason);
    }

    // Resume child durable state after child writer released
    var resumed = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .path = child_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();

    var saw_before = false;
    var saw_from_child = false;
    for (resumed.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, "before-fork")) saw_before = true;
        if (m.role == .user and std.mem.eql(u8, m.content, "from-child")) saw_from_child = true;
    }
    try std.testing.expect(saw_before);
    try std.testing.expect(saw_from_child);

    // Parent still valid after child deinit
    try std.testing.expectEqualStrings(parent_path, parent.path.?);
}

// ── D-011 seam composition fixtures ──────────────────────────────────────────

test "low-level core: explicit five-seam permissive composition" {
    // Proves an external SDK consumer can compose the five explicit seams at
    // the low level (allowAllForTrustedHost is explicit, never a default).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: core.tool.Context, instance: ?*anyopaque, _: []const u8) core.tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ok") catch return error.OutOfMemory;
        }
    };
    var state: State = .{};
    const t = try core.tool.buildTool(gpa, .{
        .definition = .{
            .name = "counter",
            .description = "x",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &state,
        .handler = Stub.h,
    });

    const Mock = struct {
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
                tc[0] = .{ .id = "c1", .name = "counter", .arguments = "{}" };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = core.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("count");

    const result = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &[_]core.tool.Tool{t} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = core.loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = core.loop.Jail.allowAllForTrustedHost(),
        .shell_policy = core.ShellPolicy.allowAllForTrustedHost(),
        .context_view = core.loop.ContextView.identity(),
        .event_sink = core.loop.LoopEventSink.discard(),
        .control_input = core.loop.ControlInput.none(),
    }, &transcript);

    try std.testing.expectEqualStrings("done", result.final_text);
    try std.testing.expectEqual(@as(u32, 1), state.n);
}

test "low-level core: explicit deny policy prevents handler execution" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const State = struct { ran: bool = false };
    const Stub = struct {
        fn h(_: core.tool.Context, instance: ?*anyopaque, _: []const u8) core.tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const t = try core.tool.buildTool(gpa, .{
        .definition = .{
            .name = "write_file",
            .description = "x",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &state,
        .handler = Stub.h,
    });

    const Mock = struct {
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
                    .name = "write_file",
                    .arguments = try arena.dupe(u8, "{\"path\":\"x\",\"content\":\"y\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "denied ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = core.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("write");

    _ = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &[_]core.tool.Tool{t} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = core.loop.ToolPolicy.denyAll(),
        .jail = core.loop.Jail.allowAllForTrustedHost(),
        .shell_policy = core.loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = core.loop.ContextView.identity(),
        .event_sink = core.loop.LoopEventSink.discard(),
        .control_input = core.loop.ControlInput.none(),
    }, &transcript);

    try std.testing.expect(!state.ran);
    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and core.tool_error.hasCode(m.content, .permission_denied)) saw = true;
    }
    try std.testing.expect(saw);
}

test "low-level core: unknown tool soft-fails before policy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Mock = struct {
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
                tc[0] = .{ .id = "c1", .name = "nope_nope", .arguments = "{}" };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    const provider = core.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("unknown");

    _ = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = core.loop.ToolPolicy.denyAll(),
        .jail = core.loop.Jail.allowAllForTrustedHost(),
        .shell_policy = core.loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = core.loop.ContextView.identity(),
        .event_sink = core.loop.LoopEventSink.discard(),
        .control_input = core.loop.ControlInput.none(),
    }, &transcript);

    var saw = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and core.tool_error.hasCode(m.content, .unknown_tool)) saw = true;
    }
    try std.testing.expect(saw);
}

test "low-level core: discard sink and identity view are explicit, not defaults" {
    // The discard sink and identity view are named explicit helpers. A
    // consumer selects them; they are never silently normalized to missing.
    const discard_sink = core.loop.LoopEventSink.discard();
    const identity_view = core.loop.ContextView.identity();
    try discard_sink.emit(.{ .turn_start = 1 });
    _ = identity_view;
}

// ── D-011 canonical product-owned observation ownership compile assertions ──
//
// Proves an external SDK consumer resolves the product-owned Trace/Redactor/
// Observer surface (moved from `zag-agent-core` to `zag-coding-agent` by
// core-observation-ownership-001) through the public `zag-coding-agent` module
// root — not indirectly via Core. These are compile-time canonical-ownership
// checks, not behavior tests.

test "coding.trace canonical schema version resolves from external consumer" {
    try std.testing.expectEqual(@as(u32, 1), coding.trace.current_schema_version);
}

test "coding.redact.Redactor canonical type resolves from external consumer" {
    // The Redactor type is publicly reachable through the canonical product root.
    const R = coding.redact.Redactor;
    _ = R; // compile assertion only.
}

test "coding.observer.Observer/Event canonical types resolve from external consumer" {
    const O = coding.observer.Observer;
    const E = coding.observer.Event;
    _ = O;
    _ = E; // compile assertion only.
}

// ── D-011 borrowed source-event evidence: host honors the borrow contract ──
//
// An external host implements a file-local `LoopEventSink` that receives Core
// `LoopEvent` facts. The loop payload slices (e.g. `.assistant_message`) are
// **borrowed** — valid only during `emit`. This fixture proves a host that
// copies a borrowed slice into owned bytes (using its own allocator) retains
// the original content after the callback returns and the source mutable
// buffer is modified. It uses the public `zag-agent-core` `LoopEventSink` and
// `LoopEvent` imports only; no fake is leaked to the public API.

const BorrowEvidenceSink = struct {
    gpa: std.mem.Allocator,
    owned_assistant: ?[]u8 = null,

    fn deinit(self: *BorrowEvidenceSink) void {
        if (self.owned_assistant) |o| self.gpa.free(o);
        self.owned_assistant = null;
    }

    fn vtable(self: *BorrowEvidenceSink) core.loop.LoopEventSink {
        return .{
            .ptr = self,
            .vtable = &borrow_evidence_vtable,
        };
    }
};

const borrow_evidence_vtable: core.loop_event.LoopEventSinkVTable = .{
    .emit = borrowEvidenceEmit,
};

fn borrowEvidenceEmit(ptr: ?*anyopaque, event: core.loop_event.LoopEvent) core.loop_event.SinkError!void {
    const self: *BorrowEvidenceSink = @ptrCast(@alignCast(ptr.?));
    switch (event) {
        .assistant_message => |am| {
            // The slice is borrowed for the duration of this call only. Dupe
            // into owned bytes using the host allocator so the copy survives.
            const owned = self.gpa.dupe(u8, am.text) catch return error.OutOfMemory;
            // Free any prior copy (one event per run for this fixture).
            if (self.owned_assistant) |o| self.gpa.free(o);
            self.owned_assistant = owned;
        },
        else => {},
    }
}

test "borrowed LoopEvent assistant_message is owned-safe after source mutation" {
    const gpa = std.testing.allocator;

    // A real low-level loop turn uses a scratch arena; here the host owns a
    // mutable buffer that stands in for the arena/loop-internal slice.
    const original = "hello borrowed world";
    const mut = try gpa.dupe(u8, original);
    defer gpa.free(mut);

    var sink_state: BorrowEvidenceSink = .{ .gpa = gpa };
    defer sink_state.deinit();

    const sink = sink_state.vtable();
    // Emit a borrowed slice (the loop would pass a borrowed text slice).
    try sink.emit(.{ .assistant_message = .{ .text = mut, .has_tools = false } });

    // After the callback returns, the host mutates the original mutable buffer.
    // This simulates the turn arena being reused / the borrowed slice going away.
    for (mut) |*c| c.* = 'X';

    // The owned copy must still hold the original content (host honored the
    // borrow contract by duping before returning).
    try std.testing.expect(sink_state.owned_assistant != null);
    try std.testing.expectEqualStrings(original, sink_state.owned_assistant.?);

    // The mutated buffer no longer equals the original.
    try std.testing.expect(!std.mem.eql(u8, mut, original));
}

// ── harness-events-001: public LifecycleObserver from external consumer ────
//
// Installs the public `coding.LifecycleObserver`, copies borrowed assistant/
// tool id/name/args/body inside the callback, then proves the owned copies
// remain valid after `Agent.reply` returns and the reply arena is gone.
// Low-level Core sink fixtures above stay independent (no lifecycle pollution).

const SdkLifecycleOwned = struct {
    kind: enum { run_start, assistant_message, tool_start, tool_end, control_applied, run_terminal },
    turn: u32 = 0,
    call_index: u32 = 0,
    text: ?[]u8 = null,
    has_tools: bool = false,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: ?[]u8 = null,
    body: ?[]u8 = null,
    session_configured: bool = false,
    next_turn: u32 = 0,
    turns: u32 = 0,
    ok: bool = false,
    stop_reason: coding.loop.StopReason = .completed,

    fn deinit(self: *SdkLifecycleOwned, gpa: std.mem.Allocator) void {
        if (self.text) |s| gpa.free(s);
        if (self.id) |s| gpa.free(s);
        if (self.name) |s| gpa.free(s);
        if (self.arguments) |s| gpa.free(s);
        if (self.body) |s| gpa.free(s);
    }
};

const SdkLifecycleRecorder = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(SdkLifecycleOwned) = .empty,
    terminal_count: u32 = 0,
    after_terminal: bool = false,
    open: bool = false,

    fn init(gpa: std.mem.Allocator) SdkLifecycleRecorder {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *SdkLifecycleRecorder) void {
        for (self.events.items) |*e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    fn observer(self: *SdkLifecycleRecorder) coding.LifecycleObserver {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    fn onEvent(ptr: ?*anyopaque, event: coding.LifecycleEvent) void {
        const self: *SdkLifecycleRecorder = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .run_start => {
                if (self.open) self.after_terminal = true;
                self.open = true;
            },
            .run_terminal => {
                if (!self.open) self.after_terminal = true;
                self.open = false;
            },
            else => {
                if (!self.open) self.after_terminal = true;
            },
        }
        var owned: SdkLifecycleOwned = switch (event) {
            .run_start => |rs| .{
                .kind = .run_start,
                .session_configured = rs.session_configured,
            },
            .assistant_message => |am| blk: {
                const text = self.gpa.dupe(u8, am.text) catch return;
                break :blk .{
                    .kind = .assistant_message,
                    .turn = am.turn,
                    .text = text,
                    .has_tools = am.has_tools,
                };
            },
            .tool_start => |ts| blk: {
                const id = self.gpa.dupe(u8, ts.id) catch return;
                const name = self.gpa.dupe(u8, ts.name) catch {
                    self.gpa.free(id);
                    return;
                };
                const arguments = self.gpa.dupe(u8, ts.arguments) catch {
                    self.gpa.free(id);
                    self.gpa.free(name);
                    return;
                };
                break :blk .{
                    .kind = .tool_start,
                    .turn = ts.turn,
                    .call_index = ts.call_index,
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
            },
            .tool_end => |te| blk: {
                const id = self.gpa.dupe(u8, te.id) catch return;
                const name = self.gpa.dupe(u8, te.name) catch {
                    self.gpa.free(id);
                    return;
                };
                const body = self.gpa.dupe(u8, te.body) catch {
                    self.gpa.free(id);
                    self.gpa.free(name);
                    return;
                };
                break :blk .{
                    .kind = .tool_end,
                    .turn = te.turn,
                    .call_index = te.call_index,
                    .id = id,
                    .name = name,
                    .body = body,
                };
            },
            .control_applied => |c| blk: {
                const text = self.gpa.dupe(u8, c.text) catch return;
                break :blk .{
                    .kind = .control_applied,
                    .next_turn = c.next_turn,
                    .text = text,
                };
            },
            .run_terminal => |rt| .{
                .kind = .run_terminal,
                .turns = rt.turns,
                .ok = rt.ok,
                .stop_reason = rt.stop_reason,
            },
        };
        if (event == .run_terminal) self.terminal_count += 1;
        self.events.append(self.gpa, owned) catch owned.deinit(self.gpa);
    }
};

test "public LifecycleObserver copies assistant/tool bytes; owned after reply returns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Echo = struct {
        fn h(ctx: core.tool.Context, _: ?*anyopaque, args: []const u8) core.tool.HandlerError![]u8 {
            // Echo a distinctive body so the owned tool_end copy is identifiable.
            return std.fmt.allocPrint(ctx.allocator, "echo:{s}", .{args}) catch return error.OutOfMemory;
        }
    };
    const custom_tool = try coding.tool.buildTool(gpa, .{
        .definition = .{
            .name = "echo_tool",
            .description = "echo args",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .read,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .instance = null,
        .handler = Echo.h,
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
                    .id = try arena.dupe(u8, "sdk-tool-1"),
                    .name = try arena.dupe(u8, "echo_tool"),
                    .arguments = try arena.dupe(u8, "{\"v\":\"owned-safe\"}"),
                };
                return .{
                    .content = try arena.dupe(u8, "sdk-assistant-with-tools"),
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = try arena.dupe(u8, "sdk-final-assistant"),
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

    var rec = SdkLifecycleRecorder.init(gpa);
    defer rec.deinit();

    var agent = try coding.Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .toolset = &[_]coding.tool.Tool{custom_tool},
        .lifecycle = rec.observer(),
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "run echo");
    try std.testing.expectEqualStrings("sdk-final-assistant", result.final_text);
    try std.testing.expectEqual(coding.loop.StopReason.completed, result.stop_reason);

    // Exact public sequence and correlation (program order).
    try std.testing.expectEqual(@as(usize, 6), rec.events.items.len);
    try std.testing.expectEqual(.run_start, rec.events.items[0].kind);
    try std.testing.expect(!rec.events.items[0].session_configured);

    try std.testing.expectEqual(.assistant_message, rec.events.items[1].kind);
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[1].turn);
    try std.testing.expect(rec.events.items[1].has_tools);
    try std.testing.expectEqualStrings("sdk-assistant-with-tools", rec.events.items[1].text.?);

    try std.testing.expectEqual(.tool_start, rec.events.items[2].kind);
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[2].call_index);
    try std.testing.expectEqualStrings("sdk-tool-1", rec.events.items[2].id.?);
    try std.testing.expectEqualStrings("echo_tool", rec.events.items[2].name.?);
    try std.testing.expectEqualStrings("{\"v\":\"owned-safe\"}", rec.events.items[2].arguments.?);

    try std.testing.expectEqual(.tool_end, rec.events.items[3].kind);
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[3].call_index);
    try std.testing.expectEqualStrings("sdk-tool-1", rec.events.items[3].id.?);
    try std.testing.expectEqualStrings("echo_tool", rec.events.items[3].name.?);
    try std.testing.expectEqualStrings("echo:{\"v\":\"owned-safe\"}", rec.events.items[3].body.?);

    try std.testing.expectEqual(.assistant_message, rec.events.items[4].kind);
    try std.testing.expect(!rec.events.items[4].has_tools);
    try std.testing.expectEqualStrings("sdk-final-assistant", rec.events.items[4].text.?);

    try std.testing.expectEqual(.run_terminal, rec.events.items[5].kind);
    try std.testing.expect(rec.events.items[5].ok);
    try std.testing.expectEqual(coding.loop.StopReason.completed, rec.events.items[5].stop_reason);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);

    // After reply returns, session arena may be reused by further work; the
    // owned copies retained by the external consumer must still match.
    try session.transcript.appendUser("post-reply-mutation");
    try std.testing.expectEqualStrings("sdk-assistant-with-tools", rec.events.items[1].text.?);
    try std.testing.expectEqualStrings("sdk-tool-1", rec.events.items[2].id.?);
    try std.testing.expectEqualStrings("echo_tool", rec.events.items[2].name.?);
    try std.testing.expectEqualStrings("{\"v\":\"owned-safe\"}", rec.events.items[2].arguments.?);
    try std.testing.expectEqualStrings("echo:{\"v\":\"owned-safe\"}", rec.events.items[3].body.?);
    try std.testing.expectEqualStrings("sdk-final-assistant", rec.events.items[4].text.?);
}

test "coding.LifecycleObserver/LifecycleEvent public types resolve from external consumer" {
    const O = coding.LifecycleObserver;
    const E = coding.LifecycleEvent;
    const L = coding.lifecycle;
    _ = O;
    _ = E;
    _ = L;
}

// ── harness-steering-001 external consumer surface ──────────────────────────

test "harness-steering: ControlInput.none and steered code resolve from package roots" {
    const none = core.loop.ControlInput.none();
    try std.testing.expect(none.peek(.pre_turn) == null);
    try std.testing.expect(none.peek(.would_complete) == null);
    try std.testing.expect(core.tool_error.hasCode(core.tool_error.steered_body, .steered));
    _ = coding.ControlError;
    _ = coding.ControlKind;
    _ = coding.control_queue.capacity;
}

test "harness-steering: Session enqueue copies caller bytes; low-level none composition" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const buf = try gpa.dupe(u8, "external-steer");
    try session.enqueueSteering(buf);
    gpa.free(buf);
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());

    // Low-level loop composition with explicit none (no Session adapter).
    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const core.message.Message,
            _: []const core.tool.Definition,
            _: core.provider.RequestControl,
        ) core.provider.ChatError!core.message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock_state: u8 = 0;
    const provider = core.provider.Provider{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");
    const result = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = core.loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = core.loop.Jail.allowAllForTrustedHost(),
        .shell_policy = core.loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = core.loop.ContextView.identity(),
        .event_sink = core.loop.LoopEventSink.discard(),
        .control_input = core.loop.ControlInput.none(),
    }, &transcript);
    try std.testing.expectEqual(core.loop.StopReason.completed, result.stop_reason);
    // Session queue untouched by low-level none composition.
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());
}

// ── skills-001: public options + activation surface smoke ───────────────────
//
// External consumer uses coding-agent module names only. Proves enable/trust/
// user-root options, parse/expand activation, and that Agent.reply does not
// implicit-parse `/skill:`. No schema/event change claims.

test "skills-001: public options + activation + no implicit reply parse" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Compile assertions: public skill surface is reachable.
    const Trust = coding.ProjectSkillsTrust;
    _ = Trust;
    const SE = coding.SkillActivationError;
    _ = SE;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sdk-skill");
    const skill_md =
        \\---
        \\name: sdk-skill
        \\description: sdk smoke skill
        \\---
        \\
        \\SDK_BODY
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "sdk-skill/SKILL.md", .data = skill_md });

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_n = try tmp.dir.realPathFile(io, ".", &root_buf);
    const user_root = root_buf[0..root_n];

    var session = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
        .skills_enabled = true,
        .project_skills_trust = .untrusted,
        .user_skills_root = user_root,
    });
    defer session.deinit();

    try std.testing.expect(session.skills_catalog.find("sdk-skill") != null);

    const cmd = coding.parseSkillCommand("/skill:sdk-skill more") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("sdk-skill", cmd.name);
    try std.testing.expectEqualStrings("more", cmd.rest);

    const act = try coding.expandSkillActivation(gpa, &session, cmd.name, cmd.rest);
    defer gpa.free(act.user_text);
    try std.testing.expect(std.mem.indexOf(u8, act.user_text, "SDK_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, act.user_text, "more") != null);

    // Unknown skill is local error (no provider).
    try std.testing.expectError(
        error.UnknownSkill,
        coding.expandSkillActivation(gpa, &session, "missing-skill", ""),
    );

    // Agent.reply never implicit-parses /skill:
    const MockProvider = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const coding.message.Message,
            _: []const coding.tool.Definition,
            _: coding.provider.RequestControl,
        ) coding.provider.ChatError!coding.message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "reply-ok"),
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
        .toolset = &[_]coding.tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();

    const raw = "/skill:sdk-skill stays raw in reply";
    _ = try agent.reply(&session, raw);
    var saw_raw = false;
    for (session.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, raw)) saw_raw = true;
    }
    try std.testing.expect(saw_raw);

    // Disable skills → empty catalog
    var disabled = try coding.Session.start(gpa, io, .{
        .base_system = "system",
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_skills_root = user_root,
    });
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 0), disabled.skills_catalog.entries.len);
}
