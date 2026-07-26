//! session-fork-001 Gate fixtures — binding module §8 items 1–29.
//!
//! Create-body fault uses session_store.testing strategy A
//! (`setFailNextCreateBody`): test-only, production-impossible, fires inside
//! the final `createNewWithRedactor` after lease acquisition.
//!
//! Residual honesty: failed create may leave intermediate dirs and a reusable
//! stale `{path}.lock` sidecar; it must not leave a held lock FD or committed
//! child `.jsonl`. `Writer.deinit` does not unlink the lock sidecar (D-006).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const agent_mod = @import("agent.zig");
const session_store = @import("session_store.zig");
const redact_mod = @import("redact.zig");
const context_mod = @import("context.zig");
const lifecycle_mod = @import("lifecycle.zig");
const core = @import("zag-agent-core");

const Session = agent_mod.Session;
const Agent = agent_mod.Agent;
const message = core.message;
const loop = core.loop;
const provider_mod = core.provider;
const tool = core.tool;

const secret_key = redact_mod.testing.fake_api_key;

// ── helpers ──────────────────────────────────────────────────────────────────

const EchoChat = struct {
    text: []const u8 = "fork-reply",
    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        _: []const message.Message,
        _: []const tool.Definition,
        _: provider_mod.RequestControl,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .content = try arena.dupe(u8, self.text),
            .tool_calls = &.{},
            .finish_reason = "stop",
        };
    }
};

fn echoProvider(state: *EchoChat) provider_mod.Provider {
    return .{
        .ptr = state,
        .vtable = &.{ .chat = EchoChat.chat },
    };
}

fn readFileOrEmpty(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return gpa.dupe(u8, ""),
        else => return err,
    };
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn expectParentUnchanged(
    parent: *Session,
    parent_path: ?[]const u8,
    parent_bytes_before: ?[]const u8,
    gen: u32,
    summary: ?[]const u8,
    base: []const u8,
    project: []const u8,
    msg_count: usize,
    steer_n: usize,
    follow_n: usize,
) !void {
    try std.testing.expectEqual(gen, parent.compaction_gen);
    if (summary) |s| {
        try std.testing.expect(parent.compaction_summary != null);
        try std.testing.expectEqualStrings(s, parent.compaction_summary.?);
    } else {
        try std.testing.expect(parent.compaction_summary == null);
    }
    try std.testing.expectEqualStrings(base, parent.base_system);
    try std.testing.expectEqualStrings(project, parent.project_body);
    try std.testing.expectEqual(msg_count, parent.transcript.items().len);
    try std.testing.expectEqual(steer_n, parent.steeringPending());
    try std.testing.expectEqual(follow_n, parent.followUpPending());
    if (parent_path) |pp| {
        try std.testing.expect(parent.path != null);
        try std.testing.expectEqualStrings(pp, parent.path.?);
        try std.testing.expect(parent.writer != null);
        if (parent_bytes_before) |before| {
            const after = try readFileOrEmpty(parent.gpa, parent.io, pp);
            defer parent.gpa.free(after);
            try std.testing.expectEqualStrings(before, after);
        }
    } else {
        try std.testing.expect(parent.path == null);
        try std.testing.expect(parent.writer == null);
    }
}

fn assertNestedNonAlias(parent_m: message.Message, child_m: message.Message) !void {
    try std.testing.expect(parent_m.content.ptr != child_m.content.ptr or parent_m.content.len == 0);
    if (parent_m.tool_calls) |pc| {
        const cc = child_m.tool_calls.?;
        try std.testing.expect(pc.ptr != cc.ptr);
        for (pc, cc) |a, b| {
            try std.testing.expect(a.id.ptr != b.id.ptr or a.id.len == 0);
            try std.testing.expect(a.name.ptr != b.name.ptr or a.name.len == 0);
            try std.testing.expect(a.arguments.ptr != b.arguments.ptr or a.arguments.len == 0);
            try std.testing.expectEqualStrings(a.id, b.id);
            try std.testing.expectEqualStrings(a.name, b.name);
            try std.testing.expectEqualStrings(a.arguments, b.arguments);
        }
    }
    if (parent_m.tool_call_id) |pid| {
        const cid = child_m.tool_call_id.?;
        try std.testing.expect(pid.ptr != cid.ptr or pid.len == 0);
        try std.testing.expectEqualStrings(pid, cid);
    }
    if (parent_m.content_parts) |pp| {
        const cp = child_m.content_parts.?;
        try std.testing.expect(pp.ptr != cp.ptr);
        try std.testing.expectEqual(pp.len, cp.len);
        for (pp, cp) |a, b| {
            switch (a) {
                .text => |at| {
                    const bt = b.text;
                    try std.testing.expectEqualStrings(at, bt);
                    try std.testing.expect(at.ptr != bt.ptr or at.len == 0);
                },
                .image_url => |ai| {
                    const bi = b.image_url;
                    try std.testing.expectEqualStrings(ai.url, bi.url);
                    try std.testing.expect(ai.url.ptr != bi.url.ptr or ai.url.len == 0);
                    if (ai.detail) |ad| {
                        const bd = bi.detail.?;
                        try std.testing.expectEqualStrings(ad, bd);
                        try std.testing.expect(ad.ptr != bd.ptr or ad.len == 0);
                    } else {
                        try std.testing.expect(bi.detail == null);
                    }
                },
            }
        }
    }
}

const LifecycleCapture = struct {
    gpa: std.mem.Allocator,
    session_configured: ?bool = null,
    fn observer(self: *LifecycleCapture) lifecycle_mod.LifecycleObserver {
        return .{ .ptr = self, .on_event = onEvent };
    }
    fn onEvent(ptr: ?*anyopaque, event: lifecycle_mod.LifecycleEvent) void {
        const self: *LifecycleCapture = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .run_start => |rs| self.session_configured = rs.session_configured,
            else => {},
        }
    }
};

// ── §8 items 1–4, 5–9: success path ownership ────────────────────────────────

test "session-fork §8.1-9: success parent integrity, content_parts, dual path, layers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-success";
    const parent_path = ".zag-test-session-fork-success/parent.jsonl";
    const child_path = ".zag-test-session-fork-success/child.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys-fork-base",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .secrets = &.{secret_key},
    });

    // Non-empty project + compaction layers
    const arena = parent.arena_impl.allocator();
    parent.project_body = try arena.dupe(u8, "project-body-live");
    parent.project_source = "AGENTS.md";
    try parent.noteCompaction(.{ .summary = "session-summary-v1", .dropped = 0 });

    // Tool-bundle + aliased tool_call_id
    const calls = try arena.alloc(message.ToolCall, 1);
    calls[0] = .{
        .id = try arena.dupe(u8, "call-1"),
        .name = try arena.dupe(u8, "list_dir"),
        .arguments = try arena.dupe(u8, "{\"path\":\".\"}"),
    };
    try parent.transcript.appendAssistantTurn(.{
        .content = "tools",
        .tool_calls = calls,
        .finish_reason = "tool_calls",
    });
    // appendToolResult aliases tool_call_id to assistant call id in parent arena
    try parent.transcript.appendToolResult(calls[0].id, "tool-ok");

    // Positive content_parts (text + image_url with detail)
    const parts = try arena.alloc(message.ContentPart, 2);
    parts[0] = .{ .text = try arena.dupe(u8, "see image") };
    parts[1] = .{ .image_url = .{
        .url = try arena.dupe(u8, "https://example.com/a.png"),
        .detail = try arena.dupe(u8, "high"),
    } };
    try parent.transcript.messages.append(arena, message.Message{
        .role = .user,
        .content = try arena.dupe(u8, "multimodal"),
        .content_parts = parts,
    });

    // Secret in live transcript (redaction on durable child)
    try parent.transcript.appendUser(try std.fmt.allocPrint(arena, "key={s}", .{secret_key}));

    try parent.enqueueSteering("steer-pending");
    try parent.enqueueFollowUp("follow-pending");
    try parent.save();

    const parent_bytes = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes);
    const gen = parent.compaction_gen;
    const summary = try gpa.dupe(u8, parent.compaction_summary.?);
    defer gpa.free(summary);
    const base = try gpa.dupe(u8, parent.base_system);
    defer gpa.free(base);
    const project = try gpa.dupe(u8, parent.project_body);
    defer gpa.free(project);
    const msg_count = parent.transcript.items().len;
    const parent_arena_ptr = parent.arena_impl;
    const parent_path_ptr = parent.path.?.ptr;
    const parent_writer_path_ptr = parent.writer.?.path.ptr;
    const parent_secret_ptr = parent.owned_redactor.?.secrets.items[0].ptr;
    const steer_n = parent.steeringPending();
    const follow_n = parent.followUpPending();

    var child = try parent.fork(child_path);
    defer child.deinit();

    // §8.1 parent file byte-equal after success
    // §8.3 parent field equality on success
    try expectParentUnchanged(
        &parent,
        parent_path,
        parent_bytes,
        gen,
        summary,
        base,
        project,
        msg_count,
        steer_n,
        follow_n,
    );
    try std.testing.expect(parent.arena_impl == parent_arena_ptr);
    try std.testing.expect(parent.path.?.ptr == parent_path_ptr);
    try std.testing.expect(parent.writer.?.path.ptr == parent_writer_path_ptr);

    // §8.5 heap-stable arena
    try std.testing.expect(child.arena_impl != parent.arena_impl);
    const child_moved = child; // by-value move keeps arena_impl pointer stable
    try std.testing.expect(child_moved.arena_impl == child.arena_impl);
    child = child_moved;

    // §8.6 positive content_parts live fixture
    var saw_parts = false;
    for (parent.transcript.items(), child.transcript.items()) |pm, cm| {
        try std.testing.expectEqual(pm.role, cm.role);
        try std.testing.expectEqualStrings(pm.content, cm.content);
        try assertNestedNonAlias(pm, cm);
        if (pm.content_parts != null) {
            saw_parts = true;
            try std.testing.expect(cm.content_parts != null);
            try std.testing.expectEqual(@as(usize, 2), cm.content_parts.?.len);
            try std.testing.expectEqualStrings("see image", cm.content_parts.?[0].text);
            try std.testing.expectEqualStrings("https://example.com/a.png", cm.content_parts.?[1].image_url.url);
            try std.testing.expectEqualStrings("high", cm.content_parts.?[1].image_url.detail.?);
        }
    }
    try std.testing.expect(saw_parts);

    // §8.7 nested non-alias for layers
    try std.testing.expect(parent.base_system.ptr != child.base_system.ptr);
    try std.testing.expect(parent.project_body.ptr != child.project_body.ptr);
    try std.testing.expect(parent.compaction_summary.?.ptr != child.compaction_summary.?.ptr);
    try std.testing.expectEqualStrings(parent.base_system, child.base_system);
    try std.testing.expectEqualStrings(parent.project_body, child.project_body);
    try std.testing.expectEqual(parent.compaction_gen, child.compaction_gen);
    try std.testing.expectEqualStrings(parent.compaction_summary.?, child.compaction_summary.?);

    // §8.8 dual path ownership pointers
    try std.testing.expect(child.path != null);
    try std.testing.expect(child.writer != null);
    try std.testing.expect(child.path.?.ptr != child.writer.?.path.ptr);
    try std.testing.expectEqualStrings(child_path, child.path.?);
    try std.testing.expectEqualStrings(child_path, child.writer.?.path);

    // Child redactor independent secrets
    try std.testing.expect(child.owned_redactor != null);
    try std.testing.expect(child.owned_redactor.?.secrets.items[0].ptr != parent_secret_ptr);

    // §8.9 live layers equal
    const pl = parent.layers();
    const cl = child.layers();
    try std.testing.expectEqualStrings(pl.system, cl.system);
    try std.testing.expectEqualStrings(pl.project, cl.project);
    try std.testing.expectEqualStrings(pl.session, cl.session);

    // §8.14 queue isolation
    try std.testing.expectEqual(@as(usize, 0), child.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), child.followUpPending());
    try std.testing.expectEqual(@as(usize, 1), parent.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), parent.followUpPending());

    // §8.15 redaction: child durable has marker, not raw secret
    const child_bytes = try readFileOrEmpty(gpa, io, child_path);
    defer gpa.free(child_bytes);
    try std.testing.expect(std.mem.indexOf(u8, child_bytes, secret_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, child_bytes, redact_mod.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, parent_bytes, secret_key) == null);

    // Parent still has pending queues and valid lease — deinit parent first then child
    // is covered in a dedicated dual-order test; here parent-first.
    parent.deinit();
    // child still valid after parent deinit (independent ownership)
    try std.testing.expectEqualStrings(child_path, child.path.?);
}

test "session-fork §8.8: child-first then parent deinit order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-deinit-order";
    const parent_path = ".zag-test-session-fork-deinit-order/p.jsonl";
    const child_path = ".zag-test-session-fork-deinit-order/c.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    var child = try parent.fork(child_path);
    // child-first
    child.deinit();
    try std.testing.expectEqualStrings(parent_path, parent.path.?);
    parent.deinit();
}

// ── §8.10–13 product chains ──────────────────────────────────────────────────

test "session-fork §8.10-13: post-compaction child reply, parent reply after fork, ephemeral, tools" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-chains";
    const parent_path = ".zag-test-session-fork-chains/parent.jsonl";
    const child_path = ".zag-test-session-fork-chains/child.jsonl";
    const eph_child = ".zag-test-session-fork-chains/eph-child.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var mock: EchoChat = .{ .text = "ok" };
    var agent = try Agent.init(gpa, io, echoProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    // Durable parent with compaction
    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer parent.deinit();
    try parent.noteCompaction(.{ .summary = "compacted-context", .dropped = 2 });
    try std.testing.expect(parent.compaction_gen >= 1);

    const calls = try parent.arena_impl.allocator().alloc(message.ToolCall, 1);
    calls[0] = .{
        .id = try parent.arena_impl.allocator().dupe(u8, "t-pair"),
        .name = try parent.arena_impl.allocator().dupe(u8, "list_dir"),
        .arguments = try parent.arena_impl.allocator().dupe(u8, "{}"),
    };
    try parent.transcript.appendAssistantTurn(.{
        .content = "use tool",
        .tool_calls = calls,
        .finish_reason = "tool_calls",
    });
    try parent.transcript.appendToolResult(calls[0].id, "listed");
    try parent.save();
    const parent_bytes_pre = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes_pre);

    var child = try parent.fork(child_path);
    defer child.deinit();
    try std.testing.expectEqual(parent.compaction_gen, child.compaction_gen);
    try std.testing.expectEqualStrings("compacted-context", child.compaction_summary.?);

    // §8.10 child reply builds context with session layer
    const child_result = try agent.reply(&child, "continue");
    try std.testing.expectEqual(loop.StopReason.completed, child_result.stop_reason);
    try std.testing.expectEqualStrings("compacted-context", child.layers().session);

    // §8.11 parent continues after fork: snapshot child durable bytes **after**
    // child reply/save and **before** parent reply; parent save must not touch
    // the child file (exact byte-equal after parent reply).
    const child_bytes_pre_parent_reply = try readFileOrEmpty(gpa, io, child_path);
    defer gpa.free(child_bytes_pre_parent_reply);
    try std.testing.expect(child_bytes_pre_parent_reply.len > 0);

    const parent_bytes_mid = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes_mid);
    try std.testing.expectEqualStrings(parent_bytes_pre, parent_bytes_mid);
    const parent_result = try agent.reply(&parent, "parent-continues");
    try std.testing.expectEqual(loop.StopReason.completed, parent_result.stop_reason);

    const child_bytes_after_parent = try readFileOrEmpty(gpa, io, child_path);
    defer gpa.free(child_bytes_after_parent);
    try std.testing.expectEqualStrings(child_bytes_pre_parent_reply, child_bytes_after_parent);

    const parent_bytes_post = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes_post);
    try std.testing.expect(parent_bytes_post.len >= parent_bytes_pre.len);
    try std.testing.expect(std.mem.indexOf(u8, parent_bytes_post, "parent-continues") != null);

    // §8.13 tool-bundle pairing preserved in child live transcript
    var saw_tool_pair = false;
    for (child.transcript.items()) |m| {
        if (m.role == .tool and m.tool_call_id != null) {
            if (std.mem.eql(u8, m.tool_call_id.?, "t-pair")) saw_tool_pair = true;
        }
    }
    try std.testing.expect(saw_tool_pair);

    // §8.12 ephemeral parent → durable child
    var eph = try Session.start(gpa, io, .{
        .base_system = "eph-sys",
        .load_project_instructions = false,
    });
    defer eph.deinit();
    try std.testing.expect(eph.path == null);
    var echild = try eph.fork(eph_child);
    defer echild.deinit();
    try std.testing.expect(eph.path == null);
    try std.testing.expect(echild.path != null);
    try std.testing.expect(fileExists(io, eph_child));
    try std.testing.expect(!fileExists(io, "eph-invented-parent.jsonl"));

    var life: LifecycleCapture = .{ .gpa = gpa };
    var agent2 = try Agent.init(gpa, io, echoProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .lifecycle = life.observer(),
    });
    defer agent2.deinit();
    const er = try agent2.reply(&echild, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, er.stop_reason);
    try std.testing.expect(life.session_configured == true);
}

// ── §8.14–16 queues / redaction / resume honesty ─────────────────────────────

test "session-fork §8.16: child resume rows+compaction only; content_parts dropped by load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-resume";
    const parent_path = ".zag-test-session-fork-resume/p.jsonl";
    const child_path = ".zag-test-session-fork-resume/c.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "fork-time-base",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .secrets = &.{secret_key},
    });
    defer parent.deinit();
    parent.project_body = try parent.arena_impl.allocator().dupe(u8, "fork-time-project");
    try parent.noteCompaction(.{ .summary = "resume-summary", .dropped = 0 });

    const parts = try parent.arena_impl.allocator().alloc(message.ContentPart, 2);
    parts[0] = .{ .text = try parent.arena_impl.allocator().dupe(u8, "t") };
    parts[1] = .{ .image_url = .{
        .url = try parent.arena_impl.allocator().dupe(u8, "https://x/y.png"),
        .detail = try parent.arena_impl.allocator().dupe(u8, "low"),
    } };
    try parent.transcript.messages.append(parent.arena_impl.allocator(), .{
        .role = .user,
        .content = try parent.arena_impl.allocator().dupe(u8, "with-parts"),
        .content_parts = parts,
    });
    try parent.transcript.appendUser("plain-user");
    try parent.save();

    {
        var child = try parent.fork(child_path);
        // Live child has content_parts
        var live_parts = false;
        for (child.transcript.items()) |m| {
            if (m.content_parts != null) live_parts = true;
        }
        try std.testing.expect(live_parts);
        // §8.29: JSONL roundtrip is not deep-copy evidence — load drops parts.
        // Deinit child and resume from durable file.
        child.deinit();
    }

    var resumed = try Session.start(gpa, io, .{
        .base_system = "host-opts-base", // host opts, not fork-time base
        .path = child_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();

    try std.testing.expectEqual(@as(u32, 1), resumed.compaction_gen);
    try std.testing.expectEqualStrings("resume-summary", resumed.compaction_summary.?);
    try std.testing.expectEqual(@as(usize, 0), resumed.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), resumed.followUpPending());
    // base_system follows host opts, not fork-time live field
    try std.testing.expectEqualStrings("host-opts-base", resumed.base_system);
    // content_parts absent after session-v1 load
    for (resumed.transcript.items()) |m| {
        try std.testing.expect(m.content_parts == null);
    }
    var saw_plain = false;
    for (resumed.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, "plain-user")) saw_plain = true;
    }
    try std.testing.expect(saw_plain);
}

// ── §8.17–23 path / lock / create faults ─────────────────────────────────────

test "session-fork §8.17-23: InvalidPath, AlreadyExists, Busy, same-path, OOM, create-body, null redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-faults";
    const parent_path = ".zag-test-session-fork-faults/parent.jsonl";
    const exists_path = ".zag-test-session-fork-faults/exists.jsonl";
    const busy_path = ".zag-test-session-fork-faults/busy.jsonl";
    const create_fail_path = ".zag-test-session-fork-faults/nested/create-fail.jsonl";
    const oom_path = ".zag-test-session-fork-faults/oom.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .secrets = &.{secret_key},
    });
    defer parent.deinit();
    try parent.transcript.appendUser("u");
    try parent.enqueueSteering("s");
    try parent.save();

    const parent_bytes = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes);
    const gen = parent.compaction_gen;
    const base = try gpa.dupe(u8, parent.base_system);
    defer gpa.free(base);
    const project = try gpa.dupe(u8, parent.project_body);
    defer gpa.free(project);
    const msg_count = parent.transcript.items().len;
    const steer_n = parent.steeringPending();
    const follow_n = parent.followUpPending();
    const parent_path_ptr = parent.path.?.ptr;

    // §8.17 InvalidPath
    try std.testing.expectError(error.InvalidPath, parent.fork("/abs/nope.jsonl"));
    try std.testing.expectError(error.InvalidPath, parent.fork("../escape.jsonl"));
    try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);

    // §8.18 SessionAlreadyExists leaves pre-existing bytes unchanged
    const prior_exists =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"keep-me"}
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = exists_path, .data = prior_exists });
    try std.testing.expectError(error.SessionAlreadyExists, parent.fork(exists_path));
    const exists_after = try readFileOrEmpty(gpa, io, exists_path);
    defer gpa.free(exists_after);
    try std.testing.expectEqualStrings(prior_exists, exists_after);
    try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);

    // §8.20 same-as-parent durable path: AlreadyExists (honest, not Busy); parent never replaced
    try std.testing.expectError(error.SessionAlreadyExists, parent.fork(parent_path));
    try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);
    try std.testing.expect(parent.path.?.ptr == parent_path_ptr);

    // §8.19 SessionBusy — hold lock on target without committed session file
    // (create hits acquireLock → WouldBlock before any committed jsonl).
    {
        const script = try std.fmt.allocPrint(gpa,
            \\import fcntl, signal, sys, time, os
            \\signal.alarm(8)
            \\lock = "{s}.lock"
            \\os.makedirs(os.path.dirname(lock) or ".", exist_ok=True)
            \\f = open(lock, "a+")
            \\fcntl.flock(f, fcntl.LOCK_EX)
            \\sys.stdout.write("ready\n")
            \\sys.stdout.flush()
            \\time.sleep(30)
        , .{busy_path});
        defer gpa.free(script);

        var holder = try std.process.spawn(io, .{
            .argv = &.{ "python3", "-c", script },
            .stdout = .pipe,
        });
        defer {
            if (holder.stdout) |f| {
                f.close(io);
                holder.stdout = null;
            }
            holder.kill(io);
        }
        var stdout_buf: [64]u8 = undefined;
        var stdout_reader = holder.stdout.?.reader(io, &stdout_buf);
        const line = stdout_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.TestUnexpectedResult,
            else => return err,
        };
        try std.testing.expectEqualStrings("ready", line);

        try std.testing.expectError(error.SessionBusy, parent.fork(busy_path));
        try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);
        try std.testing.expect(!fileExists(io, busy_path));
    }

    // §8.21 prep OOM — no child jsonl, no held lock, parent unchanged
    {
        // Sweep fail indices after Session is live; fork uses parent.gpa
        var saw_oom = false;
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = idx });
            const saved = parent.gpa;
            parent.gpa = failing.allocator();
            const result = parent.fork(oom_path);
            parent.gpa = saved;
            if (result) |c| {
                var child = c;
                child.deinit();
                // Success without induced failure — stop (prep completed)
                if (!failing.has_induced_failure) break;
                Io.Dir.cwd().deleteFile(io, oom_path) catch {};
                Io.Dir.cwd().deleteFile(io, ".zag-test-session-fork-faults/oom.jsonl.lock") catch {};
            } else |err| {
                try std.testing.expect(err == error.OutOfMemory);
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expect(!fileExists(io, oom_path));
                try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);
                saw_oom = true;
                // Ensure no held lock: a real create can proceed
                var probe = try parent.fork(oom_path);
                probe.deinit();
                Io.Dir.cwd().deleteFile(io, oom_path) catch {};
                Io.Dir.cwd().deleteFile(io, ".zag-test-session-fork-faults/oom.jsonl.lock") catch {};
                break;
            }
        }
        try std.testing.expect(saw_oom);
        try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);
    }

    // §8.22 create-body fault (strategy A): setFailNextCreateBody enters final create
    {
        session_store.testing.setFailNextCreateBody(true);
        defer session_store.testing.setFailNextCreateBody(false);

        const err = parent.fork(create_fail_path);
        try std.testing.expectError(error.IoFailed, err);
        // no committed child jsonl
        try std.testing.expect(!fileExists(io, create_fail_path));
        try expectParentUnchanged(&parent, parent_path, parent_bytes, gen, null, base, project, msg_count, steer_n, follow_n);
        // Intermediate dirs MAY remain (honest residual)
        // Stale lock sidecar (if any) is reusable for later successful create (D-006)
        var retry = try parent.fork(create_fail_path);
        defer retry.deinit();
        try std.testing.expect(fileExists(io, create_fail_path));
        try std.testing.expect(retry.path != null);
    }

    // §8.23 null product redactor (ephemeral test-constructed): typed fail-closed
    {
        const null_child = ".zag-test-session-fork-faults/null-r.jsonl";
        var null_parent = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer null_parent.deinit();
        if (null_parent.owned_redactor) |*r| {
            r.deinit();
            null_parent.owned_redactor = null;
        }
        try std.testing.expectError(error.OutOfMemory, null_parent.fork(null_child));
        try std.testing.expect(!fileExists(io, null_child));
        try std.testing.expectEqualStrings("sys", null_parent.base_system);
    }
}

test "session-fork §8.23 durable parent + null redactor: typed fail-closed, parent file equal" {
    // Review follow-up: durable parent with stripped redactor must not panic,
    // must not create child jsonl, and must leave parent durable bytes equal.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-null-durable";
    const parent_path = ".zag-test-session-fork-null-durable/parent.jsonl";
    const child_path = ".zag-test-session-fork-null-durable/child.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .secrets = &.{secret_key},
    });
    defer parent.deinit();
    try parent.transcript.appendUser("durable-before-null");
    try parent.save();

    const parent_bytes = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_bytes);
    try std.testing.expect(parent_bytes.len > 0);

    // Strip redactor after durable create (corrupt / programming state).
    if (parent.owned_redactor) |*r| {
        r.deinit();
        parent.owned_redactor = null;
    }

    try std.testing.expectError(error.OutOfMemory, parent.fork(child_path));
    try std.testing.expect(!fileExists(io, child_path));

    const parent_after = try readFileOrEmpty(gpa, io, parent_path);
    defer gpa.free(parent_after);
    try std.testing.expectEqualStrings(parent_bytes, parent_after);
    try std.testing.expect(parent.writer != null);
    try std.testing.expectEqualStrings(parent_path, parent.path.?);
}

// ── §8.24–29 lifecycle / Core / backends note / maturity / non-mechanism ─────

test "session-fork §8.24: child reply lifecycle session_configured + Trace configured only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-trace";
    const parent_path = ".zag-test-session-fork-trace/p.jsonl";
    const child_path = ".zag-test-session-fork-trace/c.jsonl";
    const trace_path = ".zag-test-session-fork-trace/trace.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var mock: EchoChat = .{};
    var life: LifecycleCapture = .{ .gpa = gpa };
    var agent = try Agent.init(gpa, io, echoProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = trace_path,
        .lifecycle = life.observer(),
    });
    defer agent.deinit();

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer parent.deinit();
    var child = try parent.fork(child_path);
    defer child.deinit();

    const result = try agent.reply(&child, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expect(life.session_configured == true);

    const tr_bytes = try readFileOrEmpty(gpa, io, trace_path);
    defer gpa.free(tr_bytes);
    try std.testing.expect(std.mem.indexOf(u8, tr_bytes, "\"session\":\"configured\"") != null);
    // Never raw child path in trace
    try std.testing.expect(std.mem.indexOf(u8, tr_bytes, child_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, tr_bytes, "c.jsonl") == null);
}

test "session-fork §8.25: Core root/source has no fork export" {
    // Core public module surface has no fork API/state (D-011).
    // Path-free: @hasDecl on the imported package only (no monorepo path scan).
    try std.testing.expect(@hasDecl(core, "message"));
    try std.testing.expect(@hasDecl(core, "transcript"));
    try std.testing.expect(@hasDecl(core, "loop"));
    try std.testing.expect(!@hasDecl(core, "fork"));
    try std.testing.expect(!@hasDecl(core, "Session"));
    try std.testing.expect(!@hasDecl(core, "SessionFork"));
    try std.testing.expect(!@hasDecl(core, "ForkError"));
    try std.testing.expect(!@hasDecl(core, "session_store"));
    try std.testing.expect(!@hasDecl(core, "createNewWithRedactor"));
}

test "session-fork §8.29: live content_parts prove fork is not JSONL roundtrip deep-copy" {
    // Companion to §8.6/§8.16: if fork used save→load, content_parts would be null.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zag-test-session-fork-not-jsonl";
    const parent_path = ".zag-test-session-fork-not-jsonl/p.jsonl";
    const child_path = ".zag-test-session-fork-not-jsonl/c.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer parent.deinit();
    const parts = try parent.arena_impl.allocator().alloc(message.ContentPart, 2);
    parts[0] = .{ .text = try parent.arena_impl.allocator().dupe(u8, "alpha") };
    parts[1] = .{ .image_url = .{
        .url = try parent.arena_impl.allocator().dupe(u8, "data:image/png;base64,xx"),
        .detail = try parent.arena_impl.allocator().dupe(u8, "auto"),
    } };
    try parent.transcript.messages.append(parent.arena_impl.allocator(), .{
        .role = .user,
        .content = "",
        .content_parts = parts,
    });

    var child = try parent.fork(child_path);
    defer child.deinit();
    var found = false;
    for (child.transcript.items()) |m| {
        if (m.content_parts) |cp| {
            found = true;
            try std.testing.expectEqual(@as(usize, 2), cp.len);
            try std.testing.expectEqualStrings("alpha", cp[0].text);
            try std.testing.expectEqualStrings("auto", cp[1].image_url.detail.?);
        }
    }
    try std.testing.expect(found);
    // Note: maturity rows remain L2 — not asserted here (docs Gate / closeout).
}

test "session-fork noteCompaction shape compile guard" {
    const e: context_mod.CompactionEvent = .{
        .summary = "x",
        .dropped = 0,
    };
    _ = e;
}
