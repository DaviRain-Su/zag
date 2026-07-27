//! Process-level tui-minimal-001 fixtures (§11 #28, #29, partial #1/#33).
//! Only linked when root builds with `-Dtui=true`.
//!
//! Spawns real `zag` binary under isolated cwd. Asserts mode mutex / non-TTY
//! exits without silent REPL. Does not claim full PTY interactive coverage
//! (Zig std has no portable PTY harness); interactive paths are covered by
//! package unit/integration tests in zag-tui.

const std = @import("std");
const Io = std.Io;
const fixture_opts = @import("tui_fixture_options");

const zag_bin: []const u8 = fixture_opts.zag_bin;

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
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try Io.Dir.cwd().realPathFile(io, zag_bin, &abs_buf);
    const zag_abs = abs_buf[0..abs_len];

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, zag_abs);
    for (argv_tail) |a| try argv_list.append(gpa, a);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const result = try std.process.run(gpa, io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(15), .clock = .awake } },
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

test "gate28_nontty_tui_exit2_stdout_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{"--tui"});
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
    try std.testing.expect(out.stderr.len > 0);
}

test "gate29_mode_matrix_tui_json_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--tui", "--json", "hi" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_json_stream_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--tui", "--json-stream", "hi" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_doctor_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--tui", "--doctor" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_prompt_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--tui", "hello", "world" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_verbose_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--tui", "--verbose" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_help_with_tui_exit0_no_init" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZag(gpa, io, tmp.dir, &.{ "--help", "--tui" });
    defer out.deinit(gpa);
    try expectExited(out.term, 0);
    try std.testing.expect(out.stdout.len > 0 or out.stderr.len > 0);
}
