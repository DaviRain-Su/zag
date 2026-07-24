//! H1 golden transcripts (mock provider) — see docs/quality/evals.md.
//!
//! 1. readonly-list-build — list_dir then read_file, then text answer
//! 2. deny-write — permission_denied; target file must not appear

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const agent_mod = @import("agent.zig");
const fs_tools = @import("runtime/fs_tools.zig");
const edit_tools = @import("runtime/edit_tools.zig");

const message = core.message;
const tool = core.tool;
const provider_mod = core.provider;
const tool_error = core.tool_error;
const session_store = core.session_store;

test "golden readonly-list-build" {
    // Goal: fixed mock drives list_dir → read_file → final text; tool names stable.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "t1"),
                    .name = try arena.dupe(u8, "list_dir"),
                    .arguments = try arena.dupe(u8, "{\"path\":\".\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            if (self.step == 2) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "t2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"build.zig\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "build.zig defines the monorepo"),
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

    var agent = agent_mod.Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();

    const owned = try agent.complete("You are a test agent.", "What is in build.zig?");
    defer owned.deinit(gpa);

    try std.testing.expect(owned.stop_reason == .completed);
    try std.testing.expectEqualStrings("build.zig defines the monorepo", owned.final_text);

    // Assert tool sequence from session would require keeping session; instead
    // re-run via reply and inspect transcript.
    var session = try agent_mod.Session.start(gpa, io, .{
        .base_system = "You are a test agent.",
        .load_project_instructions = false,
    });
    defer session.deinit();

    mock.step = 0;
    _ = try agent.reply(&session, "What is in build.zig?");

    var names: [2]?[]const u8 = .{ null, null };
    var ni: usize = 0;
    for (session.transcript.items()) |m| {
        if (m.role == .assistant) {
            if (m.tool_calls) |calls| {
                for (calls) |c| {
                    if (ni < 2) {
                        names[ni] = c.name;
                        ni += 1;
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), ni);
    try std.testing.expectEqualStrings("list_dir", names[0].?);
    try std.testing.expectEqualStrings("read_file", names[1].?);
}

test "golden deny-write leaves no file" {
    // Goal: ask/deny on write_file → code=permission_denied; path absent on disk.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "w1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"secret.txt\",\"content\":\"nope\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
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

    // Custom agent-like deps: use loop directly with Phase1 tools + deny gate + tmp cwd.
    const ro = fs_tools.phase0Tools();
    const search = fs_tools.searchTools();
    const rw = edit_tools.phase1ExtraTools();
    const tools = [_]tool.Tool{ ro[0], ro[1], search[0], search[1], rw[0], rw[1], rw[2] };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendSystem("test");
    try transcript.appendUser("write secret.txt");

    const result = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = tmp.dir,
        },
        .options = .{
            .permission_gate = .denyAllDangerous(),
        },
    }, &transcript);

    try std.testing.expectEqualStrings("understood, not writing", result.final_text);
    var denied = false;
    for (transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) {
            denied = true;
        }
    }
    try std.testing.expect(denied);

    tmp.dir.access(io, "secret.txt", .{}) catch {
        return; // expected: file missing
    };
    try std.testing.expect(false); // file must not exist
}

test "cancel then session save/load resumes" {
    // Goal: cancelled run leaves consistent transcript that session_store can reload.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Mock = struct {
        cancel_ptr: *core.cancel.Flag,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.cancel_ptr.request();
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "list_dir"),
                .arguments = try arena.dupe(u8, "{\"path\":\".\"}"),
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };

    var cancel_flag: core.cancel.Flag = .{};
    var mock: Mock = .{ .cancel_ptr = &cancel_flag };
    const provider = provider_mod.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = core.transcript.Transcript.init(arena_impl.allocator());
    try transcript.appendSystem("sys");
    try transcript.appendUser("list");

    const result = try core.loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = tmp.dir,
        },
        .options = .{
            .permission_gate = .yolo(),
            .cancel = &cancel_flag,
        },
    }, &transcript);

    try std.testing.expect(result.stop_reason == .cancelled);
    try std.testing.expect(tool_error.hasCode(
        blk: {
            for (transcript.items()) |m| {
                if (m.role == .tool) break :blk m.content;
            }
            break :blk "";
        },
        .cancelled,
    ));

    // Persist via writer lease (single-writer path) so cancel pairs stay resume-safe.
    var writer = try session_store.createNew(gpa, io, tmp.dir, "session.jsonl", transcript.items(), .{});
    writer.deinit();

    var loaded_arena: std.heap.ArenaAllocator = .init(gpa);
    defer loaded_arena.deinit();
    var loaded = core.transcript.Transcript.init(loaded_arena.allocator());
    var resume_writer = try session_store.resumeExisting(gpa, io, tmp.dir, "session.jsonl", &loaded, null);
    defer resume_writer.deinit();
    try std.testing.expect(loaded.items().len >= 3);
    var found_cancelled = false;
    for (loaded.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .cancelled)) {
            found_cancelled = true;
        }
    }
    try std.testing.expect(found_cancelled);
}
