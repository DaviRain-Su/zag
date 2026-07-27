//! prompt-templates-001 Gate fixtures — binding module §11 items 1–17.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const agent_mod = @import("agent.zig");
const templates = @import("prompt_templates.zig");
const core = @import("zag-agent-core");
const tool = core.tool;
const session_store = @import("session_store.zig");
const redact_mod = @import("redact.zig");

const Session = agent_mod.Session;
const Agent = agent_mod.Agent;

fn writeTemplate(io: Io, dir: Io.Dir, name: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}.md", .{name});
    defer std.testing.allocator.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = body });
}

fn absPathOf(io: Io, dir: Io.Dir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(io, ".", &buf);
    return try gpa.dupe(u8, buf[0..n]);
}

fn noopProvider() core.provider.Provider {
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
    return .{
        .ptr = @constCast(&{}),
        .vtable = &.{ .chat = Mock.chat },
    };
}

fn countingProvider(calls: *u32) core.provider.Provider {
    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const core.message.Message,
            _: []const core.tool.Definition,
            _: core.provider.RequestControl,
        ) core.provider.ChatError!core.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    // Heap-stable via static storage is awkward; use leaked test-local box via
    // opaque pointer to the *u32 itself and a shared vtable that bumps via
    // a global isn't ideal. Instead return provider whose ptr is the calls pointer
    // with a free function cast — but vtable needs *anyopaque struct.
    // Use simple pattern: encode *u32 as ptr and cast in chat.
    const V = struct {
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const core.message.Message,
            _: []const core.tool.Definition,
            _: core.provider.RequestControl,
        ) core.provider.ChatError!core.message.AssistantTurn {
            const c: *u32 = @ptrCast(@alignCast(ptr));
            c.* += 1;
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    _ = Mock;
    return .{
        .ptr = calls,
        .vtable = &.{ .chat = V.chat },
    };
}

// ── §11.1 Roots + enable neutrality ─────────────────────────────────────────

test "templates §11.1: user discovery + --no-prompt-templates empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "alpha", "ALPHA_BODY $ARGUMENTS");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 1), s.templates_catalog.entries.len);
        try std.testing.expectEqualStrings("alpha", s.templates_catalog.entries[0].name);
        try std.testing.expect(std.mem.indexOf(u8, s.templates_catalog.entries[0].body, "ALPHA_BODY") != null);
    }

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .templates_enabled = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.templates_catalog.entries.len);
    }
}

// ── §11.2 Project trust off/on ──────────────────────────────────────────────

test "templates §11.2: project trust off/on independent of --no-project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "proj-tpl-unique";
    Io.Dir.cwd().createDirPath(io, ".agents/prompts") catch {};
    defer Io.Dir.cwd().deleteTree(io, ".agents/prompts") catch {};
    {
        var agents = try Io.Dir.cwd().openDir(io, ".agents/prompts", .{ .iterate = true });
        defer agents.close(io);
        try writeTemplate(io, agents, skill_name, "PROJECT_TPL_BODY");
    }

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false, // --no-project
            .project_templates_trust = .untrusted,
        });
        defer s.deinit();
        try std.testing.expect(s.templates_catalog.find(skill_name) == null);
    }

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false, // still --no-project
            .project_templates_trust = .trusted,
        });
        defer s.deinit();
        const e = s.templates_catalog.find(skill_name) orelse return error.TestUnexpectedResult;
        try std.testing.expect(e.origin == .project);
        try std.testing.expect(std.mem.indexOf(u8, e.body, "PROJECT_TPL_BODY") != null);
    }
}

// ── §11.3 Containment / symlink escape ──────────────────────────────────────

test "templates §11.3: symlink escape soft-skip both roots" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "secret.md", .data = "SECRET_OUTSIDE_BYTES" });
    var out_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const out_n = try outside.dir.realPathFile(io, "secret.md", &out_buf);
    const outside_path = out_buf[0..out_n];

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tmp.dir.symLink(io, outside_path, "escape.md", .{}) catch |err| switch (err) {
        error.AccessDenied, error.ReadOnlyFileSystem => return error.SkipZigTest,
        else => |e| return e,
    };
    try writeTemplate(io, tmp.dir, "good", "GOOD_BODY");

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(s.templates_catalog.find("escape") == null);
    try std.testing.expect(s.templates_catalog.find("good") != null);
    for (s.templates_catalog.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.body, "SECRET_OUTSIDE_BYTES") == null);
    }
    var saw_escape = false;
    for (s.templates_catalog.diags) |d| {
        if (d == .candidate_escape) saw_escape = true;
    }
    try std.testing.expect(saw_escape);
}

// ── §11.4 Non-recursive + byte-sort ─────────────────────────────────────────

test "templates §11.4: non-recursive direct files + byte-sort" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "zeta", "Z");
    try writeTemplate(io, tmp.dir, "alpha", "A");
    try writeTemplate(io, tmp.dir, "mid", "M");
    // Nested dir must be ignored (non-recursive).
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/hidden.md", .data = "HIDDEN" });
    try tmp.dir.writeFile(io, .{ .sub_path = "noise.txt", .data = "noise" });

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 3), s.templates_catalog.entries.len);
    try std.testing.expectEqualStrings("alpha", s.templates_catalog.entries[0].name);
    try std.testing.expectEqualStrings("mid", s.templates_catalog.entries[1].name);
    try std.testing.expectEqualStrings("zeta", s.templates_catalog.entries[2].name);
    try std.testing.expect(s.templates_catalog.find("hidden") == null);
}

// ── §11.5 Name validation + reserved skill ──────────────────────────────────

test "templates §11.5: invalid names + reserved skill soft-skip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "good-name", "GOOD");
    try writeTemplate(io, tmp.dir, "Bad_Name", "BAD");
    try writeTemplate(io, tmp.dir, "skill", "RESERVED");
    try writeTemplate(io, tmp.dir, "empty-body", "   \n  ");
    // oversize name stem
    var long_stem: [70]u8 = undefined;
    @memset(&long_stem, 'a');
    const long_name = long_stem[0..65];
    try writeTemplate(io, tmp.dir, long_name, "LONG");

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(s.templates_catalog.find("good-name") != null);
    try std.testing.expect(s.templates_catalog.find("skill") == null);
    try std.testing.expect(s.templates_catalog.find(long_name) == null);
    try std.testing.expectEqual(@as(usize, 1), s.templates_catalog.entries.len);

    var saw_reserved = false;
    var saw_invalid = false;
    var saw_empty = false;
    for (s.templates_catalog.diags) |d| {
        if (d == .name_reserved) saw_reserved = true;
        if (d == .name_invalid) saw_invalid = true;
        if (d == .body_empty) saw_empty = true;
    }
    try std.testing.expect(saw_reserved);
    try std.testing.expect(saw_invalid);
    try std.testing.expect(saw_empty);
}

// ── §11.6 Project overrides user ────────────────────────────────────────────

test "templates §11.6: project overrides user same name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = "shared-tpl";
    try writeTemplate(io, tmp.dir, name, "USER_BODY");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    Io.Dir.cwd().createDirPath(io, ".agents/prompts") catch {};
    defer Io.Dir.cwd().deleteTree(io, ".agents/prompts/" ++ name ++ ".md") catch {};
    {
        var agents = try Io.Dir.cwd().openDir(io, ".agents/prompts", .{ .iterate = true });
        defer agents.close(io);
        try writeTemplate(io, agents, name, "PROJECT_BODY");
    }

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_templates_root = user_root,
        .project_templates_trust = .trusted,
    });
    defer s.deinit();

    const e = s.templates_catalog.find(name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(e.origin == .project);
    try std.testing.expectEqualStrings("PROJECT_BODY", e.body);
    var saw_override = false;
    for (s.templates_catalog.diags) |d| {
        if (d == .project_override) saw_override = true;
    }
    try std.testing.expect(saw_override);
}

// ── §11.7 / §11.8 Substitution ──────────────────────────────────────────────

test "templates §11.7–8: substitution $ARGUMENTS $$ no rescan + append rule" {
    const gpa = std.testing.allocator;
    const catalog = templates.Catalog{
        .entries = &[_]templates.TemplateEntry{
            .{ .name = "with-arg", .body = "X $ARGUMENTS Y $$ Z $", .origin = .user },
            .{ .name = "static", .body = "static only", .origin = .user },
        },
    };

    {
        const exp = try templates.expandTemplate(gpa, catalog, "with-arg", "ARGS$ARGUMENTS$$");
        defer gpa.free(exp.user_text);
        try std.testing.expectEqualStrings("X ARGS$ARGUMENTS$$ Y $ Z $", exp.user_text);
    }
    {
        const exp = try templates.expandTemplate(gpa, catalog, "static", "tail");
        defer gpa.free(exp.user_text);
        try std.testing.expectEqualStrings("static only\n\ntail", exp.user_text);
    }
    {
        const exp = try templates.expandTemplate(gpa, catalog, "static", "");
        defer gpa.free(exp.user_text);
        try std.testing.expectEqualStrings("static only", exp.user_text);
    }
    {
        // Empty args with placeholder present → empty substitution, no append.
        const exp = try templates.expandTemplate(gpa, catalog, "with-arg", "");
        defer gpa.free(exp.user_text);
        try std.testing.expectEqualStrings("X  Y $ Z $", exp.user_text);
    }
}

// ── §11.9 Budgets ───────────────────────────────────────────────────────────

test "templates §11.9: file size, entry cap, aggregate, args/expansion budgets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Oversize file soft-skip + valid peer
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const big = try gpa.alloc(u8, templates.max_file_bytes + 100);
        defer gpa.free(big);
        @memset(big, 'B');
        try writeTemplate(io, tmp.dir, "too-big", big);
        try writeTemplate(io, tmp.dir, "ok-one", "OK");
        const user_root = try absPathOf(io, tmp.dir, gpa);
        defer gpa.free(user_root);
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        try std.testing.expect(s.templates_catalog.find("too-big") == null);
        try std.testing.expect(s.templates_catalog.find("ok-one") != null);
        var saw_file_too_large = false;
        for (s.templates_catalog.diags) |d| {
            if (d == .file_too_large) saw_file_too_large = true;
        }
        try std.testing.expect(saw_file_too_large);
    }

    // >64 direct children → entry_limit; first 64 byte-sorted considered
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var i: usize = 0;
        while (i < 70) : (i += 1) {
            var name_buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "e{d:0>2}", .{i});
            try writeTemplate(io, tmp.dir, name, "E");
        }
        const user_root = try absPathOf(io, tmp.dir, gpa);
        defer gpa.free(user_root);
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        try std.testing.expect(s.templates_catalog.find("e00") != null);
        try std.testing.expect(s.templates_catalog.find("e63") != null);
        try std.testing.expect(s.templates_catalog.find("e64") == null);
        try std.testing.expect(s.templates_catalog.entries.len <= templates.max_entries_per_root);
        var saw_entry_limit = false;
        for (s.templates_catalog.diags) |d| {
            if (d == .entry_limit) saw_entry_limit = true;
        }
        try std.testing.expect(saw_entry_limit);
    }

    // Aggregate source budget
    {
        var tmp2 = std.testing.tmpDir(.{ .iterate = true });
        defer tmp2.cleanup();
        const chunk: usize = 22 * 1024;
        var body_buf: [22 * 1024]u8 = undefined;
        @memset(&body_buf, 'S');
        var j: usize = 0;
        while (j < 12) : (j += 1) {
            var name_buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "s{d:0>2}", .{j});
            try writeTemplate(io, tmp2.dir, name, body_buf[0..chunk]);
        }
        const root2 = try absPathOf(io, tmp2.dir, gpa);
        defer gpa.free(root2);
        var s2 = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .user_templates_root = root2,
        });
        defer s2.deinit();
        var sum: usize = 0;
        for (s2.templates_catalog.entries) |e| sum += e.body.len;
        try std.testing.expect(sum <= templates.max_source_aggregate);
        var saw_budget = false;
        for (s2.templates_catalog.diags) |d| {
            if (d == .source_budget) saw_budget = true;
        }
        try std.testing.expect(saw_budget);
        try std.testing.expect(s2.templates_catalog.find("s00") != null);
    }

    // Args too large
    {
        const catalog = templates.Catalog{
            .entries = &[_]templates.TemplateEntry{.{ .name = "t", .body = "x", .origin = .user }},
        };
        const huge_args = try gpa.alloc(u8, templates.max_arguments_bytes + 1);
        defer gpa.free(huge_args);
        @memset(huge_args, 'a');
        try std.testing.expectError(error.ArgumentsTooLarge, templates.expandTemplate(gpa, catalog, "t", huge_args));
    }

    // Expansion too large: body + args via append > 32 KiB (args still ≤ 8 KiB)
    {
        var body_buf: [25 * 1024]u8 = undefined;
        @memset(&body_buf, 'b');
        const catalog = templates.Catalog{
            .entries = &[_]templates.TemplateEntry{.{ .name = "t", .body = &body_buf, .origin = .user }},
        };
        var args_buf: [8 * 1024]u8 = undefined;
        @memset(&args_buf, 'a');
        // 25k body + \n\n + 8k args > 32k
        try std.testing.expectError(error.ExpansionTooLarge, templates.expandTemplate(gpa, catalog, "t", &args_buf));
    }
}

// ── §11.10 Start OOM before create ──────────────────────────────────────────

test "templates §11.10: discovery OOM before create leaves no file/lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "oom-tpl", "body");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-templates-oom";
    const path = ".zag-test-templates-oom/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Disable skills so discovery allocs are template-dominated.
    var saw_oom = false;
    var idx: usize = 0;
    while (idx < 120) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = idx });
        const fa = failing.allocator();
        const result = Session.start(fa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
        });
        if (result) |session| {
            var s = session;
            s.deinit();
            Io.Dir.cwd().deleteFile(io, path) catch {};
            Io.Dir.cwd().deleteFile(io, path ++ ".lock") catch {};
            break;
        } else |err| {
            if (err == error.OutOfMemory) {
                saw_oom = true;
                Io.Dir.cwd().access(io, path, .{}) catch {
                    continue;
                };
                return error.TestUnexpectedResult;
            }
            Io.Dir.cwd().deleteFile(io, path) catch {};
            Io.Dir.cwd().deleteFile(io, path ++ ".lock") catch {};
        }
    }
    try std.testing.expect(saw_oom);
}

// ── §11.11 Resume rediscovery / schema freeze ───────────────────────────────

test "templates §11.11: resume re-discovers; no template fields in JSONL; schema v1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "resume-a", "BODY_A");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-templates-resume";
    const path = ".zag-test-templates-resume/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        try std.testing.expect(s.templates_catalog.find("resume-a") != null);
        try s.transcript.appendUser("hi");
        try s.save();
    }

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "BODY_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "templates_catalog") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);

    tmp.dir.deleteFile(io, "resume-a.md") catch {};
    try writeTemplate(io, tmp.dir, "resume-b", "BODY_B");

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_templates_root = user_root,
    });
    defer resumed.deinit();
    try std.testing.expect(resumed.templates_catalog.find("resume-a") == null);
    try std.testing.expect(resumed.templates_catalog.find("resume-b") != null);
    try std.testing.expectEqual(@as(u32, session_store.current_schema_version), 1);
}

// ── §11.12 Fork deep-copy / parent immutability ─────────────────────────────

test "templates §11.12: fork deep-copies catalog; parent immutable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "fork-me", "FORK_BODY_UNIQUE");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-templates-fork";
    const parent_path = ".zag-test-templates-fork/p.jsonl";
    const child_path = ".zag-test-templates-fork/c.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_templates_root = user_root,
    });
    defer parent.deinit();

    const parent_body_ptr = parent.templates_catalog.entries[0].body.ptr;
    const parent_body = try gpa.dupe(u8, parent.templates_catalog.entries[0].body);
    defer gpa.free(parent_body);

    {
        var child = try parent.fork(child_path);
        defer child.deinit();
        try std.testing.expectEqual(@as(usize, 1), child.templates_catalog.entries.len);
        try std.testing.expectEqualStrings(parent_body, child.templates_catalog.entries[0].body);
        try std.testing.expect(child.templates_catalog.entries[0].body.ptr != parent_body_ptr);
    }

    try std.testing.expectEqualStrings(parent_body, parent.templates_catalog.entries[0].body);
}

// ── §11.13 Routing precedence + unknown slash ───────────────────────────────

test "templates §11.13: /skill: first; known /name expands; unknown stays raw; reply no parse" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "review", "Review: $ARGUMENTS");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    // /skill: form is not a template parse (colon invalid kebab)
    try std.testing.expect(templates.parseTemplateCommand("/skill:foo") == null);

    const cmd = templates.parseTemplateCommand("/review please fix").?;
    try std.testing.expectEqualStrings("review", cmd.name);
    try std.testing.expectEqualStrings("please fix", cmd.rest);

    const exp = try templates.expandTemplate(gpa, s.templates_catalog, cmd.name, cmd.rest);
    defer gpa.free(exp.user_text);
    try std.testing.expectEqualStrings("Review: please fix", exp.user_text);

    // Unknown slash is not an expansion error — host leaves raw
    try std.testing.expect(templates.parseTemplateCommand("/unknown-cmd") != null);
    try std.testing.expect(s.templates_catalog.find("unknown-cmd") == null);

    // Agent.reply does not implicit-parse
    var agent = try Agent.init(gpa, io, noopProvider(), .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();
    const raw = "/review should stay raw";
    _ = try agent.reply(&s, raw);
    var saw_raw = false;
    for (s.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, raw)) saw_raw = true;
    }
    try std.testing.expect(saw_raw);
}

// ── §11.14 Local failure no provider ────────────────────────────────────────

test "templates §11.14: expansion size errors local; zero provider calls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "t", "body");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    var calls: u32 = 0;
    var agent = try Agent.init(gpa, io, countingProvider(&calls), .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();

    const huge_args = try gpa.alloc(u8, templates.max_arguments_bytes + 1);
    defer gpa.free(huge_args);
    @memset(huge_args, 'x');
    try std.testing.expectError(
        error.ArgumentsTooLarge,
        templates.expandTemplate(gpa, s.templates_catalog, "t", huge_args),
    );
    try std.testing.expectError(
        error.UnknownTemplate,
        templates.expandTemplate(gpa, s.templates_catalog, "missing", ""),
    );
    // No reply attempted on local expansion failure path → provider untouched.
    try std.testing.expectEqual(@as(u32, 0), calls);

    // Successful expand + reply still works (provider may be called).
    const exp = try templates.expandTemplate(gpa, s.templates_catalog, "t", "");
    defer gpa.free(exp.user_text);
    _ = try agent.reply(&s, exp.user_text);
    try std.testing.expect(calls >= 1);
}

// ── §11.15 CLI routing surface (public API composition) ─────────────────────

test "templates §11.15: public API routing expands ordinary user text; schemas frozen" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "ship", "Ship checklist\n$ARGUMENTS");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-templates-15";
    const path = ".zag-test-templates-15/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .skills_enabled = false,
        .user_templates_root = user_root,
    });
    defer s.deinit();

    // Host-style explicit expand then ordinary reply (one-shot/REPL/headless contract).
    const cmd = templates.parseTemplateCommand("/ship go").?;
    const exp = try templates.expandTemplate(gpa, s.templates_catalog, cmd.name, cmd.rest);
    defer gpa.free(exp.user_text);

    var agent = try Agent.init(gpa, io, noopProvider(), .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();
    _ = try agent.reply(&s, exp.user_text);

    var saw_expanded = false;
    for (s.transcript.items()) |m| {
        if (m.role == .user and std.mem.indexOf(u8, m.content, "Ship checklist") != null) {
            saw_expanded = true;
            try std.testing.expect(std.mem.indexOf(u8, m.content, "go") != null);
        }
    }
    try std.testing.expect(saw_expanded);

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);
    // Catalog not serialized; expanded body may appear as ordinary user content only.
    try std.testing.expect(std.mem.indexOf(u8, raw, "templates_catalog") == null);
    try std.testing.expectEqual(@as(u32, 1), session_store.current_schema_version);
}

// ── §11.16 SDK/product composition ──────────────────────────────────────────

test "templates §11.16: public enable/trust/user-root + parse/expand; no implicit reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "sdk-tpl", "SDK_TPL $ARGUMENTS");
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .templates_enabled = true,
        .project_templates_trust = .untrusted,
        .user_templates_root = user_root,
    });
    defer s.deinit();
    try std.testing.expect(s.templates_catalog.find("sdk-tpl") != null);

    const cmd = templates.parseTemplateCommand("/sdk-tpl more").?;
    const exp = try templates.expandTemplate(gpa, s.templates_catalog, cmd.name, cmd.rest);
    defer gpa.free(exp.user_text);
    try std.testing.expectEqualStrings("SDK_TPL more", exp.user_text);

    var agent = try Agent.init(gpa, io, noopProvider(), .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();
    const raw = "/sdk-tpl more";
    _ = try agent.reply(&s, raw);
    var saw = false;
    for (s.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, raw)) saw = true;
    }
    try std.testing.expect(saw);
}

// ── §11.17 Security composition ─────────────────────────────────────────────

test "templates §11.17: after expansion write/shell still hit ask + jail + protect + redact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const secret = "tpl-secret-token-XYZ-999";
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeTemplate(io, tmp.dir, "induce", "Please write and shell; secret=" ++ secret);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const write_params =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
    ;
    const shell_params =
        \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"],"additionalProperties":false}
    ;

    const HandlerStub = struct {
        ran: bool = false,
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };

    const OneShotToolMock = struct {
        tool_name: []const u8,
        arguments: []const u8,
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
                    .name = self.tool_name,
                    .arguments = try arena.dupe(u8, self.arguments),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    // A) ask-deny
    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        const exp = try templates.expandTemplate(gpa, s.templates_catalog, "induce", "");
        defer gpa.free(exp.user_text);

        var stub: HandlerStub = .{};
        const write_tool = try tool.buildTool(gpa, .{
            .definition = .{ .name = "write_file", .description = "w", .parameters_json = write_params },
            .capabilities = .{ .risk = .write, .workspace = .{ .path_field = "path" }, .cancellation = .none, .shell = .none },
            .instance = &stub,
            .handler = HandlerStub.h,
        });
        var mock: OneShotToolMock = .{
            .tool_name = "write_file",
            .arguments = "{\"path\":\"secret.txt\",\"content\":\"x\"}",
        };
        const provider = core.provider.Provider{ .ptr = &mock, .vtable = &.{ .chat = OneShotToolMock.chat } };
        var agent = try Agent.init(gpa, io, provider, .{
            .permission_mode = .ask,
            .permission_gate = @import("permissions.zig").Gate.ask(struct {
                fn deny(_: ?*anyopaque, _: tool.ToolDescriptor, _: []const u8) @import("permissions.zig").Decision {
                    return .deny;
                }
            }.deny, null),
            .toolset = &[_]tool.Tool{write_tool},
            .shell_policy = .protect,
            .verbose = false,
            .max_turns = 4,
        });
        defer agent.deinit();
        _ = try agent.reply(&s, exp.user_text);
        try std.testing.expect(!stub.ran);
        var saw_perm = false;
        for (s.transcript.items()) |m| {
            if (m.role == .tool and core.tool_error.hasCode(m.content, .permission_denied)) saw_perm = true;
        }
        try std.testing.expect(saw_perm);
    }

    // B) jail deny
    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        const exp = try templates.expandTemplate(gpa, s.templates_catalog, "induce", "");
        defer gpa.free(exp.user_text);

        var stub: HandlerStub = .{};
        const write_tool = try tool.buildTool(gpa, .{
            .definition = .{ .name = "write_file", .description = "w", .parameters_json = write_params },
            .capabilities = .{ .risk = .write, .workspace = .{ .path_field = "path" }, .cancellation = .none, .shell = .none },
            .instance = &stub,
            .handler = HandlerStub.h,
        });
        var mock: OneShotToolMock = .{
            .tool_name = "write_file",
            .arguments = "{\"path\":\"/etc/passwd\",\"content\":\"x\"}",
        };
        const provider = core.provider.Provider{ .ptr = &mock, .vtable = &.{ .chat = OneShotToolMock.chat } };
        var agent = try Agent.init(gpa, io, provider, .{
            .permission_mode = .yolo,
            .toolset = &[_]tool.Tool{write_tool},
            .shell_policy = .protect,
            .verbose = false,
            .max_turns = 4,
        });
        defer agent.deinit();
        _ = try agent.reply(&s, exp.user_text);
        try std.testing.expect(!stub.ran);
        var saw_jail = false;
        for (s.transcript.items()) |m| {
            if (m.role == .tool and core.tool_error.hasCode(m.content, .jail_deny)) saw_jail = true;
        }
        try std.testing.expect(saw_jail);
    }

    // C) shell protect
    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
        });
        defer s.deinit();
        const exp = try templates.expandTemplate(gpa, s.templates_catalog, "induce", "");
        defer gpa.free(exp.user_text);

        var stub: HandlerStub = .{};
        const shell_tool = try tool.buildTool(gpa, .{
            .definition = .{ .name = "run_shell", .description = "s", .parameters_json = shell_params },
            .capabilities = .{ .risk = .execute, .workspace = .none, .cancellation = .none, .shell = .command_argument },
            .instance = &stub,
            .handler = HandlerStub.h,
        });
        var mock: OneShotToolMock = .{
            .tool_name = "run_shell",
            .arguments = "{\"command\":\"rm -rf /\"}",
        };
        const provider = core.provider.Provider{ .ptr = &mock, .vtable = &.{ .chat = OneShotToolMock.chat } };
        var agent = try Agent.init(gpa, io, provider, .{
            .permission_mode = .yolo,
            .toolset = &[_]tool.Tool{shell_tool},
            .shell_policy = .protect,
            .verbose = false,
            .max_turns = 4,
        });
        defer agent.deinit();
        _ = try agent.reply(&s, exp.user_text);
        try std.testing.expect(!stub.ran);
        var saw_shell = false;
        for (s.transcript.items()) |m| {
            if (m.role == .tool and core.tool_error.hasCode(m.content, .shell_deny)) {
                saw_shell = true;
                try std.testing.expect(std.mem.indexOf(u8, m.content, "rm -rf") == null);
            }
        }
        try std.testing.expect(saw_shell);
    }

    // D) redaction of expanded ordinary user message
    {
        const dir_name = ".zag-test-templates-11-17-redact";
        const sess_path = ".zag-test-templates-11-17-redact/s.jsonl";
        Io.Dir.cwd().deleteTree(io, dir_name) catch {};
        try Io.Dir.cwd().createDirPath(io, dir_name);
        defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

        const secret_slots = [_][]const u8{secret};
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_templates_root = user_root,
            .secrets = &secret_slots,
            .pattern_redaction = true,
        });
        defer s.deinit();

        const exp = try templates.expandTemplate(gpa, s.templates_catalog, "induce", "");
        defer gpa.free(exp.user_text);
        try std.testing.expect(std.mem.indexOf(u8, exp.user_text, secret) != null);

        var agent = try Agent.init(gpa, io, noopProvider(), .{
            .permission_mode = .yolo,
            .toolset = &[_]tool.Tool{},
            .verbose = false,
            .max_turns = 2,
            .secrets = &secret_slots,
            .pattern_redaction = true,
        });
        defer agent.deinit();
        _ = try agent.reply(&s, exp.user_text);

        const sess_bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
        defer gpa.free(sess_bytes);
        try std.testing.expect(std.mem.indexOf(u8, sess_bytes, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, sess_bytes, redact_mod.marker) != null);
    }
}
