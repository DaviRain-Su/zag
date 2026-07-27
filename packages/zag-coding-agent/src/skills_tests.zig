//! skills-001 Gate fixtures — binding module §11 items 1–14.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const agent_mod = @import("agent.zig");
const skills = @import("skills.zig");
const core = @import("zag-agent-core");
const tool = core.tool;
const session_store = @import("session_store.zig");

const Session = agent_mod.Session;
const Agent = agent_mod.Agent;

fn writeSkill(
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    description: []const u8,
    body: []const u8,
    disable: bool,
) !void {
    const skill_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{name});
    defer std.testing.allocator.free(skill_dir);
    try dir.createDirPath(io, skill_dir);
    const content = if (disable)
        try std.fmt.allocPrint(std.testing.allocator,
            \\---
            \\name: {s}
            \\description: {s}
            \\disable-model-invocation: true
            \\---
            \\
            \\{s}
            \\
        , .{ name, description, body })
    else
        try std.fmt.allocPrint(std.testing.allocator,
            \\---
            \\name: {s}
            \\description: {s}
            \\---
            \\
            \\{s}
            \\
        , .{ name, description, body });
    defer std.testing.allocator.free(content);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{name});
    defer std.testing.allocator.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = content });
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

// ── §11.1 User discovery + disable neutrality ───────────────────────────────

test "skills §11.1: user discovery + --no-skills empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "alpha", "Alpha skill", "ALPHA_BODY", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .user_skills_root = user_root,
        });
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 1), s.skills_catalog.entries.len);
        try std.testing.expectEqualStrings("alpha", s.skills_catalog.entries[0].name);
        try std.testing.expect(s.skills_catalog.summary.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, s.skills_catalog.summary, "alpha") != null);
        try std.testing.expect(s.skills_catalog.hasInvocable());
    }

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .skills_enabled = false,
            .user_skills_root = user_root,
        });
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.skills_catalog.entries.len);
        try std.testing.expectEqualStrings("", s.skills_catalog.summary);
        try std.testing.expect(!s.skills_catalog.hasInvocable());
        try std.testing.expectEqualStrings("", s.layers().ephemeral);
    }
}

// ── §11.2 Project trust off/on ──────────────────────────────────────────────

test "skills §11.2: project trust off/on independent of --no-project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Project root is always cwd/.agents/skills — use unique name + cleanup.
    const skill_name = "zagtest-proj-beta";
    Io.Dir.cwd().createDirPath(io, ".agents/skills/" ++ skill_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, ".agents/skills/" ++ skill_name) catch {};

    const body =
        \\---
        \\name: zagtest-proj-beta
        \\description: project beta
        \\---
        \\
        \\PROJECT_BODY
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = ".agents/skills/" ++ skill_name ++ "/SKILL.md",
        .data = body,
    });

    // Untrusted: ignored
    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .project_skills_trust = .untrusted,
        });
        defer s.deinit();
        try std.testing.expect(s.skills_catalog.find(skill_name) == null);
    }

    // Trusted + --no-project (load_project_instructions false): still discovers
    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .project_skills_trust = .trusted,
        });
        defer s.deinit();
        const e = s.skills_catalog.find(skill_name) orelse return error.TestUnexpectedResult;
        try std.testing.expect(e.origin == .project);
        try std.testing.expect(std.mem.indexOf(u8, e.body, "PROJECT_BODY") != null);
    }
}

// ── §11.3 Project override ──────────────────────────────────────────────────

test "skills §11.3: project overrides user same name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = "zagtest-ovr";
    try writeSkill(io, tmp.dir, name, "user desc", "USER_BODY", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    Io.Dir.cwd().createDirPath(io, ".agents/skills/" ++ name) catch {};
    defer Io.Dir.cwd().deleteTree(io, ".agents/skills/" ++ name) catch {};
    {
        var agents = try Io.Dir.cwd().openDir(io, ".agents/skills", .{ .iterate = true });
        defer agents.close(io);
        try writeSkill(io, agents, name, "proj desc", "PROJ_BODY", false);
    }

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
        .project_skills_trust = .trusted,
    });
    defer s.deinit();

    const e = s.skills_catalog.find(name) orelse return error.TestUnexpectedResult;
    try std.testing.expect(e.origin == .project);
    try std.testing.expect(std.mem.indexOf(u8, e.body, "PROJ_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.description, "proj") != null);
    var saw_override = false;
    for (s.skills_catalog.diags) |d| {
        if (d == .project_override) saw_override = true;
    }
    try std.testing.expect(saw_override);
}

// ── §11.4 Symlink escape ────────────────────────────────────────────────────

test "skills §11.4: symlink escape soft-skip both roots" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "user_root");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/SKILL.md", .data = 
        \\---
        \\name: escape
        \\description: should not load
        \\---
        \\
        \\SECRET_OUTSIDE
        \\
    });
    var user = try parent.dir.openDir(io, "user_root", .{ .iterate = true });
    defer user.close(io);
    user.symLink(io, "../outside", "escape", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.ReadOnlyFileSystem => return error.SkipZigTest,
        else => |e| return e,
    };

    const user_root = try absPathOf(io, user, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();
    try std.testing.expect(s.skills_catalog.find("escape") == null);
    // No outside bytes in catalog/summary
    try std.testing.expect(std.mem.indexOf(u8, s.skills_catalog.summary, "SECRET") == null);
    for (s.skills_catalog.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.body, "SECRET_OUTSIDE") == null);
    }
}

// ── §11.5 Validation bounds ─────────────────────────────────────────────────

test "skills §11.5: invalid candidates soft-skip; valid accepted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeSkill(io, tmp.dir, "good-skill", "ok desc", "GOOD", false);

    // name mismatch
    try tmp.dir.createDirPath(io, "bad-name");
    try tmp.dir.writeFile(io, .{ .sub_path = "bad-name/SKILL.md", .data =
        \\---
        \\name: other
        \\description: x
        \\---
        \\body
        \\
    });

    // empty body
    try tmp.dir.createDirPath(io, "empty-body");
    try tmp.dir.writeFile(io, .{ .sub_path = "empty-body/SKILL.md", .data =
        \\---
        \\name: empty-body
        \\description: x
        \\---
        \\
        \\
    });

    // bad charset
    try tmp.dir.createDirPath(io, "Bad_Name");
    try tmp.dir.writeFile(io, .{ .sub_path = "Bad_Name/SKILL.md", .data =
        \\---
        \\name: Bad_Name
        \\description: x
        \\---
        \\body
        \\
    });

    // overlong description
    var long_desc: [1100]u8 = undefined;
    @memset(&long_desc, 'd');
    const long_fm = try std.fmt.allocPrint(gpa,
        \\---
        \\name: long-desc
        \\description: {s}
        \\---
        \\
        \\body
        \\
    , .{long_desc[0..]});
    defer gpa.free(long_fm);
    try tmp.dir.createDirPath(io, "long-desc");
    try tmp.dir.writeFile(io, .{ .sub_path = "long-desc/SKILL.md", .data = long_fm });

    // invalid utf-8
    try tmp.dir.createDirPath(io, "bad-utf8");
    try tmp.dir.writeFile(io, .{ .sub_path = "bad-utf8/SKILL.md", .data = &[_]u8{ '-', '-', '-', '\n', 'n', 'a', 'm', 'e', ':', ' ', 'b', 'a', 'd', '-', 'u', 't', 'f', '8', '\n', 0xff, 0xfe } });

    // oversize file
    try tmp.dir.createDirPath(io, "big-file");
    const big = try gpa.alloc(u8, skills.max_file_bytes + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    // still needs frontmatter prefix so parser path hits size first
    const big_full = try std.fmt.allocPrint(gpa, "---\nname: big-file\ndescription: x\n---\n{s}", .{big});
    defer gpa.free(big_full);
    try tmp.dir.writeFile(io, .{ .sub_path = "big-file/SKILL.md", .data = big_full });

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(s.skills_catalog.find("good-skill") != null);
    try std.testing.expect(s.skills_catalog.find("bad-name") == null);
    try std.testing.expect(s.skills_catalog.find("empty-body") == null);
    try std.testing.expect(s.skills_catalog.find("Bad_Name") == null);
    try std.testing.expect(s.skills_catalog.find("long-desc") == null);
    try std.testing.expect(s.skills_catalog.find("bad-utf8") == null);
    try std.testing.expect(s.skills_catalog.find("big-file") == null);
}

// ── §11.6 Manual-only ───────────────────────────────────────────────────────

test "skills §11.6: manual-only summary deny + activation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "manual", "manual only", "MANUAL_BODY", true);
    try writeSkill(io, tmp.dir, "open", "open skill", "OPEN_BODY", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(std.mem.indexOf(u8, s.skills_catalog.summary, "manual") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.skills_catalog.summary, "open") != null);

    // read_skill denies manual-only
    const rs = skills.readSkillTool(&s.skills_catalog);
    const deny = try rs.handler(.{
        .allocator = gpa,
        .io = io,
        .cwd = Io.Dir.cwd(),
    }, rs.instance, "{\"name\":\"manual\"}");
    defer gpa.free(deny);
    try std.testing.expect(std.mem.indexOf(u8, deny, "skill_manual_only") != null);

    // manual activation allowed
    const act = try skills.expandSkillActivation(gpa, s.skills_catalog, "manual", "rest");
    defer gpa.free(act.user_text);
    try std.testing.expect(std.mem.indexOf(u8, act.user_text, "MANUAL_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, act.user_text, "rest") != null);
}

// ── §11.7 Aggregate bounds ──────────────────────────────────────────────────

test "skills §11.7: summary aggregate exclude later entries (header/footer accounted)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create many skills with large descriptions to exceed 4096 summary
    // including fixed header/footer overhead (skills.md §3.3 / §4.3).
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "s{d:0>2}", .{i});
        var desc: [200]u8 = undefined;
        @memset(&desc, 'd');
        try writeSkill(io, tmp.dir, name, &desc, "body", false);
    }
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(s.skills_catalog.summary.len <= skills.max_summary_bytes);
    try std.testing.expect(s.skills_catalog.summary.len > 0);
    // Whole-candidate exclusion: no mid-string hard clamp; header intact.
    try std.testing.expect(std.mem.startsWith(u8, s.skills_catalog.summary, skills.summary_header));
    try std.testing.expect(std.mem.endsWith(u8, s.skills_catalog.summary, skills.summary_footer));
    try std.testing.expect(s.skills_catalog.entries.len < 40);
    var saw_summary_budget = false;
    for (s.skills_catalog.diags) |d| {
        if (d == .summary_budget) saw_summary_budget = true;
    }
    try std.testing.expect(saw_summary_budget);
    // Remaining still work
    try std.testing.expect(s.skills_catalog.entries.len > 0);
    try std.testing.expect(s.skills_catalog.find("s00") != null);
}

test "skills §11.7: body aggregate exclude later entries" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 12 × ~24 KiB bodies ≈ 288 KiB > 256 KiB max_body_aggregate; each file
    // stays under max_file_bytes so exclusion is aggregate-driven, not per-file.
    const body_chunk: usize = 22 * 1024;
    var body_buf: [22 * 1024]u8 = undefined;
    @memset(&body_buf, 'B');
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "b{d:0>2}", .{i});
        try writeSkill(io, tmp.dir, name, "body-budget desc", body_buf[0..body_chunk], false);
    }
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    var body_sum: usize = 0;
    for (s.skills_catalog.entries) |e| body_sum += e.body.len;
    try std.testing.expect(body_sum <= skills.max_body_aggregate);
    try std.testing.expect(s.skills_catalog.entries.len < 12);
    var saw_body_budget = false;
    for (s.skills_catalog.diags) |d| {
        if (d == .body_budget) saw_body_budget = true;
    }
    try std.testing.expect(saw_body_budget);
    // Earlier (byte-sorted) entries remain usable.
    try std.testing.expect(s.skills_catalog.find("b00") != null);
    const rs = skills.readSkillTool(&s.skills_catalog);
    const ok = try rs.handler(.{ .allocator = gpa, .io = io, .cwd = Io.Dir.cwd() }, rs.instance, "{\"name\":\"b00\"}");
    defer gpa.free(ok);
    try std.testing.expect(ok.len > 0);
}

// ── Project-override net budget (skills.md §3.1 project-wins-by-name) ───────

test "skills: project override net-fits when current+new would exceed summary" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Pack user summary to capacity with "shared" + fillers (200-byte descs).
    // Checking current+new *before* subtracting the superseded user entry
    // soft-skips project "shared" (summary_budget) while the user skill
    // remains — violating project-wins-by-name. Net-of-supersede must win.
    var desc: [200]u8 = undefined;
    @memset(&desc, 'd');
    const entry_cost = 8 + "shared".len + 1 + 15 + desc.len + 1; // name len 6 for shared
    const filler_cost = 8 + 3 + 1 + 15 + desc.len + 1; // "u00" len 3
    // shared sorts before u*; fill with shared + N fillers until near cap.
    try writeSkill(io, tmp.dir, "shared", desc[0..], "USER_SHARED_BODY", false);
    var n_fillers: usize = 0;
    var running: usize = skills.summary_fixed_overhead + entry_cost;
    while (running + filler_cost <= skills.max_summary_bytes) : (n_fillers += 1) {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "u{d:0>2}", .{n_fillers});
        try writeSkill(io, tmp.dir, name, desc[0..], "filler-body", false);
        running += filler_cost;
    }
    // Prove double-count of shared would exceed once catalog is full.
    try std.testing.expect(running + entry_cost > skills.max_summary_bytes);
    try std.testing.expect(n_fillers >= 1);

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const proj_name = "shared";
    Io.Dir.cwd().createDirPath(io, ".agents/skills/" ++ proj_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, ".agents/skills/" ++ proj_name) catch {};
    {
        var agents = try Io.Dir.cwd().openDir(io, ".agents/skills", .{ .iterate = true });
        defer agents.close(io);
        try writeSkill(io, agents, proj_name, desc[0..], "PROJ_SHARED_BODY", false);
    }

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
        .project_skills_trust = .trusted,
    });
    defer s.deinit();

    const e = s.skills_catalog.find("shared") orelse return error.TestUnexpectedResult;
    try std.testing.expect(e.origin == .project);
    try std.testing.expect(std.mem.indexOf(u8, e.body, "PROJ_SHARED_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.body, "USER_SHARED_BODY") == null);
    var saw_override = false;
    var saw_summary_budget = false;
    for (s.skills_catalog.diags) |d| {
        if (d == .project_override) saw_override = true;
        if (d == .summary_budget) saw_summary_budget = true;
    }
    try std.testing.expect(saw_override);
    try std.testing.expect(!saw_summary_budget);
    try std.testing.expect(s.skills_catalog.summary.len <= skills.max_summary_bytes);
    try std.testing.expect(std.mem.indexOf(u8, s.skills_catalog.summary, "shared") != null);
}

// ── Entry cap: sort-then-cap dirs; files must not starve (skills.md §3.1) ────

test "skills: entry cap is sort-then-cap of directories; non-dirs do not starve" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 70 non-directory files first (readdir-order bait) + 2 valid skill dirs
    // with names that sort after many file names. Old bug stopped after 64
    // children of any kind before sort, so files could starve skill dirs.
    var f: usize = 0;
    while (f < 70) : (f += 1) {
        var fname: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&fname, "aaa-file-{d:0>3}.txt", .{f});
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "noise" });
    }
    try writeSkill(io, tmp.dir, "zzz-late-a", "late a", "LATE_A", false);
    try writeSkill(io, tmp.dir, "zzz-late-b", "late b", "LATE_B", false);

    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    try std.testing.expect(s.skills_catalog.find("zzz-late-a") != null);
    try std.testing.expect(s.skills_catalog.find("zzz-late-b") != null);
    try std.testing.expectEqual(@as(usize, 2), s.skills_catalog.entries.len);
}

test "skills: >64 skill directories: byte-sort then first 64; entry_limit diag" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 70 skill dirs; after byte-sort only first 64 names are considered.
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d:0>2}", .{i});
        try writeSkill(io, tmp.dir, name, "d", "BODY", false);
    }
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    // d00..d63 are the first 64 in byte-sort ("d00".."d63"; "d64".."d69" dropped).
    // Note: "d00".."d09","d10".."d63" = 64; "d64"+"d65"+"d66"+"d67"+"d68"+"d69" excluded.
    try std.testing.expect(s.skills_catalog.find("d00") != null);
    try std.testing.expect(s.skills_catalog.find("d63") != null);
    try std.testing.expect(s.skills_catalog.find("d64") == null);
    try std.testing.expect(s.skills_catalog.find("d69") == null);
    // Cap may also hit summary_budget before 64 bodies; at most 64 considered.
    try std.testing.expect(s.skills_catalog.entries.len <= skills.max_entries_per_root);
    var saw_entry_limit = false;
    for (s.skills_catalog.diags) |d| {
        if (d == .entry_limit) saw_entry_limit = true;
    }
    try std.testing.expect(saw_entry_limit);
}

// ── §11.8 Start OOM before create ───────────────────────────────────────────

test "skills §11.8: discovery OOM before create leaves no file/lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "oom-skill", "desc", "body", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-skills-oom";
    const path = ".zag-test-skills-oom/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Sweep fail indices: some will hit during skills discovery allocations.
    var saw_oom = false;
    var idx: usize = 0;
    while (idx < 80) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = idx });
        const fa = failing.allocator();
        const result = Session.start(fa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .user_skills_root = user_root,
        });
        if (result) |session| {
            var s = session;
            s.deinit();
            // First full success: file may exist from this success path; clean for next.
            Io.Dir.cwd().deleteFile(io, path) catch {};
            Io.Dir.cwd().deleteFile(io, path ++ ".lock") catch {};
            break;
        } else |err| {
            if (err == error.OutOfMemory) {
                saw_oom = true;
                // No session file / lock from failed start
                Io.Dir.cwd().access(io, path, .{}) catch {
                    // missing is expected
                    continue;
                };
                // If file exists, fail — OOM must not create
                return error.TestUnexpectedResult;
            }
            // Other errors (e.g. SessionAlreadyExists from leftover) clean up
            Io.Dir.cwd().deleteFile(io, path) catch {};
            Io.Dir.cwd().deleteFile(io, path ++ ".lock") catch {};
        }
    }
    try std.testing.expect(saw_oom);
}

// ── §11.9 Fork deep ownership ───────────────────────────────────────────────

test "skills §11.9: fork deep-copies catalog; parent immutable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "fork-me", "desc", "FORK_BODY_UNIQUE", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-skills-fork";
    const parent_path = ".zag-test-skills-fork/p.jsonl";
    const child_path = ".zag-test-skills-fork/c.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    var parent = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = parent_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer parent.deinit();

    const parent_body_ptr = parent.skills_catalog.entries[0].body.ptr;
    const parent_body = try gpa.dupe(u8, parent.skills_catalog.entries[0].body);
    defer gpa.free(parent_body);
    const parent_summary = try gpa.dupe(u8, parent.skills_catalog.summary);
    defer gpa.free(parent_summary);

    {
        var child = try parent.fork(child_path);
        defer child.deinit();
        try std.testing.expectEqual(@as(usize, 1), child.skills_catalog.entries.len);
        try std.testing.expectEqualStrings(parent_body, child.skills_catalog.entries[0].body);
        // Distinct allocation (deep copy)
        try std.testing.expect(child.skills_catalog.entries[0].body.ptr != parent_body_ptr);
        try std.testing.expectEqualStrings(parent_summary, child.skills_catalog.summary);
    }

    // Parent unchanged after child deinit
    try std.testing.expectEqualStrings(parent_body, parent.skills_catalog.entries[0].body);
    try std.testing.expectEqualStrings(parent_summary, parent.skills_catalog.summary);
}

// ── §11.10 Resume rediscovery / schema v1 freeze ────────────────────────────

test "skills §11.10: resume re-discovers; no skill fields in JSONL; schema v1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "resume-a", "desc a", "BODY_A", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    const dir = ".zag-test-skills-resume";
    const path = ".zag-test-skills-resume/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .user_skills_root = user_root,
        });
        defer s.deinit();
        try std.testing.expect(s.skills_catalog.find("resume-a") != null);
        try s.transcript.appendUser("hi");
        try s.save();
    }

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "skill") == null or std.mem.indexOf(u8, raw, "\"skills\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "BODY_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);

    // Change live root: replace skill
    tmp.dir.deleteTree(io, "resume-a") catch {};
    try writeSkill(io, tmp.dir, "resume-b", "desc b", "BODY_B", false);

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer resumed.deinit();
    try std.testing.expect(resumed.skills_catalog.find("resume-a") == null);
    try std.testing.expect(resumed.skills_catalog.find("resume-b") != null);
    try std.testing.expectEqual(@as(u32, session_store.current_schema_version), 1);
}

// ── §11.11 read_skill success / unknown ─────────────────────────────────────

test "skills §11.11: read_skill body / unknown / no path / caps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "readable", "r", "READ_BODY_XYZ", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    const rs = skills.readSkillTool(&s.skills_catalog);
    try std.testing.expect(rs.descriptor.capabilities.risk == .read);
    try std.testing.expect(rs.descriptor.capabilities.workspace == .none);
    try std.testing.expect(rs.descriptor.capabilities.shell == .none);

    const ok = try rs.handler(.{ .allocator = gpa, .io = io, .cwd = Io.Dir.cwd() }, rs.instance, "{\"name\":\"readable\"}");
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "READ_BODY_XYZ") != null);

    const miss = try rs.handler(.{ .allocator = gpa, .io = io, .cwd = Io.Dir.cwd() }, rs.instance, "{\"name\":\"nope\"}");
    defer gpa.free(miss);
    try std.testing.expect(std.mem.indexOf(u8, miss, "skill_not_found") != null);
}

// ── §11.12 Toolset append / duplicate fail-closed ───────────────────────────

test "skills §11.12: compose append + duplicate InvalidToolset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "tool-a", "d", "B", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    // Default base append
    const base = [_]tool.Tool{};
    const composed = try skills.composeToolsetWithReadSkill(gpa, &base, &s.skills_catalog);
    defer if (composed) |c| gpa.free(c);
    try std.testing.expect(composed != null);
    try std.testing.expectEqual(@as(usize, 1), composed.?.len);
    try std.testing.expectEqualStrings("read_skill", composed.?[0].descriptor.definition.name);

    // Duplicate fail-closed
    const dup_base = [_]tool.Tool{skills.readSkillTool(&s.skills_catalog)};
    try std.testing.expectError(
        error.InvalidToolset,
        skills.composeToolsetWithReadSkill(gpa, &dup_base, &s.skills_catalog),
    );

    // Agent.reply with custom toolset already containing read_skill → InvalidToolset
    var agent = try Agent.init(gpa, io, noopProvider(), .{
        .permission_mode = .yolo,
        .toolset = &dup_base,
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();
    try std.testing.expectError(error.InvalidToolset, agent.reply(&s, "hi"));
}

// ── §11.13 Skill-induced tools still gated ──────────────────────────────────

test "skills §11.13: after body load, write/shell still ask+jail+protect" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "induce", "d", "use write_file and run_shell", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    // Expand skill then run agent with ask-deny and shell protect defaults.
    const act = try skills.expandSkillActivation(gpa, s.skills_catalog, "induce", "");
    defer gpa.free(act.user_text);

    const WriteStub = struct {
        ran: bool = false,
        fn h(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return error.ToolFailed;
        }
    };
    var stub: WriteStub = .{};
    const write_tool = try tool.buildTool(gpa, .{
        .definition = .{
            .name = "write_file",
            .description = "w",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}",
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

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const core.message.Message,
            _: []const tool.Definition,
            _: core.provider.RequestControl,
        ) core.provider.ChatError!core.message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(core.message.ToolCall, 1);
                tc[0] = .{
                    .id = "w1",
                    .name = "write_file",
                    .arguments = try arena.dupe(u8, "{\"path\":\"/etc/passwd\",\"content\":\"x\"}"),
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
    var mock: Mock = .{};
    const provider = core.provider.Provider{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    };

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

    const result = try agent.reply(&s, act.user_text);
    try std.testing.expect(!stub.ran);
    try std.testing.expectEqualStrings("done", result.final_text);
}

// ── §11.14 Activation parse + reply never implicit ──────────────────────────

test "skills §11.14: parse/expand + Agent.reply does not implicit-parse /skill:" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeSkill(io, tmp.dir, "cli-skill", "d", "CLI_BODY", false);
    const user_root = try absPathOf(io, tmp.dir, gpa);
    defer gpa.free(user_root);

    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .user_skills_root = user_root,
    });
    defer s.deinit();

    // parse exact form
    const cmd = skills.parseSkillCommand("/skill:cli-skill rest here").?;
    try std.testing.expectEqualStrings("cli-skill", cmd.name);
    try std.testing.expectEqualStrings("rest here", cmd.rest);
    try std.testing.expect(skills.parseSkillCommand("/foo") == null);
    try std.testing.expect(skills.parseSkillCommand("/skill") == null);

    // unknown local error
    try std.testing.expectError(error.UnknownSkill, skills.expandSkillActivation(gpa, s.skills_catalog, "missing", ""));

    // Agent.reply must NOT expand /skill: — raw text goes to transcript
    var agent = try Agent.init(gpa, io, noopProvider(), .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();

    const raw_cmd = "/skill:cli-skill should stay raw";
    _ = try agent.reply(&s, raw_cmd);
    var saw_raw = false;
    for (s.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, raw_cmd)) saw_raw = true;
    }
    try std.testing.expect(saw_raw);
}

// ── CLI routing unit (parse surface) ────────────────────────────────────────

test "skills CLI-facing: parseSkillCommand exported contract" {
    try std.testing.expect(skills.parseSkillCommand("/skill:x") != null);
    try std.testing.expect(skills.parseSkillCommand("not a skill") == null);
}
