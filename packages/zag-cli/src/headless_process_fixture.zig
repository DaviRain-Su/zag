//! Process-level headless-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `headless_fixture_options.zag_bin` and the mock-server binary path via
//! `headless_fixture_options.mock_server_bin`. It runs this file as a test
//! artifact under `zig build test` (std and curl backends rebuild `zag`
//! accordingly).
//!
//! Spawns real product processes under isolated cwd + controlled environment
//! against a built-in OpenAI-compatible mock HTTP server (loopback, no external
//! network) and asserts:
//! - stdout lines are valid JSON;
//! - `--json` emits exactly one envelope (result or error);
//! - `--json-stream` ends with exactly one terminal run_end/error event;
//! - exit codes match the headless contract matrix;
//! - stderr contains no secret or absolute path.
//!
//! The mock server is a separate Zig binary (see `headless_mock_server.zig`)
//! so it runs in its own process/I/O runtime. The fixture drives it via
//! `--port-file`, avoiding Zig 0.16 `Io.Threaded` deadlocks between network
//! accept and `std.process.run` in the same test process.

const std = @import("std");
const Io = std.Io;
const fixture_opts = @import("headless_fixture_options");

const zag_bin: []const u8 = fixture_opts.zag_bin;
const mock_server_bin: []const u8 = fixture_opts.mock_server_bin;

const secret_fixture = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";

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
    env_pairs: []const []const u8,
) !RunOut {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    for (env_pairs) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try env.put(pair[0..eq], pair[eq + 1 ..]);
    }

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
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runMockServer(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    port_file: []const u8,
    force_stream: bool,
) !std.process.RunResult {
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try Io.Dir.cwd().realPathFile(io, mock_server_bin, &abs_buf);
    const server_abs = abs_buf[0..abs_len];

    const argv = if (force_stream)
        &[_][]const u8{ server_abs, "--port-file", port_file, "--stream" }
    else
        &[_][]const u8{ server_abs, "--port-file", port_file };

    return try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .awake } },
    });
}

fn expectExited(term: std.process.Child.Term, code: u8) !void {
    switch (term) {
        .exited => |c| try std.testing.expectEqual(code, c),
        else => return error.TestUnexpectedResult,
    }
}

fn assertNoSecretOrPath(out: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, out, secret_fixture) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") == null);
}

fn makeEnvPairs(gpa: std.mem.Allocator, port: u16) ![]const []const u8 {
    const url = try std.fmt.allocPrint(gpa, "ZAG_BASE_URL=http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(url);
    const pairs = try gpa.alloc([]const u8, 2);
    errdefer gpa.free(pairs);
    pairs[0] = "ZAG_API_KEY=" ++ secret_fixture;
    pairs[1] = url;
    return pairs;
}

const port_file_name = "headless_mock_server.port";

/// Run `zag` with the built-in mock server. The server is a separate process
/// so its network accept does not share the fixture's `Io.Threaded` runtime.
fn runZagWithMockServer(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    argv_tail: []const []const u8,
    force_stream: bool,
) !RunOut {
    // Main thread runs the server process (blocking). A spawned thread waits
    // for the port file and then runs `zag`. Keeping the main thread inside
    // `std.process.run` lets the spawned thread's own `std.process.run` make
    // progress on the shared `Io.Threaded` runtime.
    const ZagCtx = struct {
        gpa: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        argv_tail: []const []const u8,
        out: *?RunOut,
        err: *?anyerror,
    };
    var zag_out: ?RunOut = null;
    var zag_err: ?anyerror = null;
    var zag_ctx = ZagCtx{
        .gpa = gpa,
        .io = io,
        .cwd = cwd,
        .argv_tail = argv_tail,
        .out = &zag_out,
        .err = &zag_err,
    };
    const zag_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *ZagCtx) void {
            var port: u16 = 0;
            var spins: u32 = 0;
            while (port == 0) {
                const content = ctx.cwd.readFileAlloc(ctx.io, port_file_name, ctx.gpa, .limited(32)) catch |err| switch (err) {
                    error.FileNotFound => {
                        spins += 1;
                        if (spins > 10_000) {
                            ctx.err.* = error.PortFileTimeout;
                            return;
                        }
                        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                        continue;
                    },
                    else => |e| {
                        ctx.err.* = e;
                        return;
                    },
                };
                defer ctx.gpa.free(content);
                port = std.fmt.parseInt(u16, std.mem.trim(u8, content, " \n"), 10) catch continue;
            }

            const env_pairs = makeEnvPairs(ctx.gpa, port) catch |e| {
                ctx.err.* = e;
                return;
            };
            defer {
                ctx.gpa.free(env_pairs[1]);
                ctx.gpa.free(env_pairs);
            }
            ctx.out.* = runZag(ctx.gpa, ctx.io, ctx.cwd, ctx.argv_tail, env_pairs) catch |e| {
                ctx.err.* = e;
                return;
            };
        }
    }.run, .{&zag_ctx});

    const server_result = runMockServer(gpa, io, cwd, port_file_name, force_stream) catch |e| {
        zag_thread.join();
        if (zag_out) |*out| out.deinit(gpa);
        return e;
    };
    defer {
        gpa.free(server_result.stdout);
        gpa.free(server_result.stderr);
    }

    zag_thread.join();
    if (zag_err) |e| {
        if (zag_out) |*out| out.deinit(gpa);
        return e;
    }
    return zag_out orelse error.NoZagOutput;
}

test "process headless --json one-shot completed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try runZagWithMockServer(gpa, io, tmp.dir, &.{
        "--json",
        "hello",
    }, false);
    defer out.deinit(gpa);

    try expectExited(out.term, 0);
    const text = std.mem.trim(u8, out.stdout, " \n");
    try std.testing.expect(std.mem.startsWith(u8, text, "{"));
    try std.testing.expect(std.mem.endsWith(u8, text, "}"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"protocol_version\":\"headless-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"stop_reason\":\"completed\"") != null);
    try assertNoSecretOrPath(out.stdout);
    try assertNoSecretOrPath(out.stderr);
}

test "process headless --json-stream one-shot terminal run_end" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try runZagWithMockServer(gpa, io, tmp.dir, &.{
        "--json-stream",
        "hello",
    }, false);
    defer out.deinit(gpa);

    try expectExited(out.term, 0);
    const text = std.mem.trim(u8, out.stdout, " \n");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var terminal_count: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "{"));
        if (std.mem.indexOf(u8, line, "\"type\":\"run_end\"") != null) terminal_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), terminal_count);
    try assertNoSecretOrPath(out.stdout);
    try assertNoSecretOrPath(out.stderr);
}

test "process headless --json missing key returns provider_configuration exit 30" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try runZag(gpa, io, tmp.dir, &.{
        "--json",
        "hello",
    }, &.{});
    defer out.deinit(gpa);

    try expectExited(out.term, 30);
    const text = std.mem.trim(u8, out.stdout, " \n");
    try std.testing.expect(std.mem.startsWith(u8, text, "{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"code\":\"provider_configuration\"") != null);
    try assertNoSecretOrPath(out.stdout);
    try assertNoSecretOrPath(out.stderr);
}

test "process headless --json invalid absolute session path exits 2 without leak" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try runZag(gpa, io, tmp.dir, &.{
        "--json",
        "-s",
        "/tmp/headless-fixture-escape.jsonl",
        "hello",
    }, &.{});
    defer out.deinit(gpa);

    try expectExited(out.term, 2);
    // stdout must not contain a protocol envelope or path leak.
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "\"type\":\"result\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "\"type\":\"error\"") == null);
    try assertNoSecretOrPath(out.stdout);
    try assertNoSecretOrPath(out.stderr);
}
