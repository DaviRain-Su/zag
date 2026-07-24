//! Process-level h-doctor-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `doctor_fixture_options.zag_bin` and runs this file as a test artifact under
//! `zig build test` (std and curl backends rebuild `zag` accordingly).
//!
//! Spawns real product processes under isolated cwd + empty environment (no
//! provider/API-key/config) and asserts:
//! - exit 0 + complete fixed-field stdout for default and yolo/off/no-project;
//! - legal session/trace paths do not create files (session/trace not entered);
//! - invalid session paths fail before doctor with generic error (no path leak).
//!
//! Any accidental `ai.resolve` without a key fails the process (non-zero), so
//! green exit 0 proves resolve/wire/network were not entered.

const std = @import("std");
const Io = std.Io;
const fixture_opts = @import("doctor_fixture_options");

const zag_bin: []const u8 = fixture_opts.zag_bin;

fn emptyEnv(gpa: std.mem.Allocator) std.process.Environ.Map {
    return .init(gpa);
}

const RunOut = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

fn runZag(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    argv_tail: []const []const u8,
) !RunOut {
    var env = emptyEnv(gpa);
    defer env.deinit();

    // Child cwd is an isolated tmp dir; argv[0] with a relative path would be
    // resolved under that dir. Force absolute path from the parent process cwd.
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try Io.Dir.cwd().realPathFile(io, zag_bin, &abs_buf);
    const zag_abs = abs_buf[0..abs_len];

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, zag_abs);
    for (argv_tail) |a| try argv_list.append(gpa, a);

    const result = try std.process.run(gpa, io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn expectExited(term: std.process.Child.Term, code: u8) !void {
    switch (term) {
        .exited => |c| try std.testing.expectEqual(code, c),
        else => return error.TestUnexpectedResult,
    }
}

fn assertFullDoctorReport(out: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, out, "zag doctor\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "project_instructions=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "test_entry=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "permission=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_policy=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lexical_file_jail=enforced") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real_file_containment=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret_redaction=enabled_on_agent_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider_key_redaction=deferred_until_provider_resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "os_sandbox=not_implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_containment=not_path_contained") != null);
    // Path-free: no absolute path markers.
    try std.testing.expect(std.mem.indexOf(u8, out, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") == null);
}

fn fileExists(io: Io, cwd: Io.Dir, path: []const u8) bool {
    cwd.access(io, path, .{}) catch return false;
    return true;
}

test "process doctor: defaults ask/protect no-key full report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = secret ++ "\n" });

    var out = try runZag(gpa, io, tmp.dir, &.{"--doctor"});
    defer out.deinit(gpa);

    try expectExited(out.term, 0);
    try assertFullDoctorReport(out.stdout);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "permission=ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "shell_policy=protect") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "project_instructions=enabled_present") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "test_entry=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "real_file_containment=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, secret) == null);
}

test "process doctor: yolo/off/no-project selections reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "ignored-body\n" });

    var out = try runZag(gpa, io, tmp.dir, &.{
        "--yolo",
        "--shell-policy",
        "off",
        "--no-project",
        "--doctor",
    });
    defer out.deinit(gpa);

    try expectExited(out.term, 0);
    try assertFullDoctorReport(out.stdout);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "permission=yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "shell_policy=off") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "project_instructions=disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "ignored-body") == null);
}

test "process doctor: valid session/trace paths do not open files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "x\n" });

    const session = ".zag/sessions/doctor-fixture.jsonl";
    const trace = ".zag/traces/doctor-fixture.jsonl";

    var out = try runZag(gpa, io, tmp.dir, &.{
        "--session",
        session,
        "--trace=.zag/traces/doctor-fixture.jsonl",
        "--doctor",
    });
    defer out.deinit(gpa);

    try expectExited(out.term, 0);
    try assertFullDoctorReport(out.stdout);
    // Session/trace construction must not run — files must not appear.
    try std.testing.expect(!fileExists(io, tmp.dir, session));
    try std.testing.expect(!fileExists(io, tmp.dir, trace));
    try std.testing.expect(!fileExists(io, tmp.dir, ".zag/sessions"));
    try std.testing.expect(!fileExists(io, tmp.dir, ".zag/traces"));
}

test "process doctor: absolute session path fails validation before doctor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const bad = "/tmp/" ++ secret ++ "/session.jsonl";

    var out = try runZag(gpa, io, tmp.dir, &.{
        "--session",
        bad,
        "--doctor",
    });
    defer out.deinit(gpa);

    try expectExited(out.term, 2);
    // Must not produce a complete doctor report on validation failure.
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "os_sandbox=not_implemented") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "session path must be") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, bad) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, secret) == null);
}

test "process doctor: ../ session path fails validation without path echo" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const bad = "../" ++ secret ++ "/escape.jsonl";

    var out = try runZag(gpa, io, tmp.dir, &.{
        "-s",
        bad,
        "--doctor",
    });
    defer out.deinit(gpa);

    try expectExited(out.term, 2);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "os_sandbox=not_implemented") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "session path must be") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, bad) == null);
}
