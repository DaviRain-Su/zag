//! Process-level cli-sigint-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `sigint_fixture_options.zag_bin` and the slow mock-server binary path via
//! `sigint_fixture_options.slow_mock_bin`. It runs this file as a test artifact
//! under `zig build test` (std and curl backends rebuild `zag` accordingly).
//!
//! Spawns the real direct `zag` process under an isolated cwd + synthetic
//! environment (no real credentials) and exercises the SIGINT lifecycle:
//!   * Idle REPL: first SIGINT wakes the blocking read and the direct process
//!     exits with code 0 within a bound; no runtime error/stack on stderr.
//!   * Active std-backend request blocked in response-head: first SIGINT
//!     requests cooperative cancel; a second SIGINT while the cancel is still
//!     pending hard-exits with conventional status 130.
//!   * Active curl-backend request: first SIGINT actively aborts the in-flight
//!     transfer; the run returns a headless `cancelled` terminal (exit 11);
//!     stdout is parsed to prove EXACTLY one terminal and that it is
//!     `cancelled`.
//!
//! Determinism (cli-sigint-001 review item 5): no blind sleep decides the
//! injection point. The slow mock writes a `ready` marker after consuming the
//! full HTTP request and before the response-head stall; the fixture waits on
//! that marker, THEN sends the first SIGINT. All waits are bounded; on failure
//! the fixture reaps/kills children for clean diagnosis. Output must not leak
//! secrets or absolute paths.

const std = @import("std");
const Io = std.Io;
const fixture_opts = @import("sigint_fixture_options");

const zag_bin: []const u8 = fixture_opts.zag_bin;
const slow_mock_bin: []const u8 = fixture_opts.slow_mock_bin;

// Backend capability truth (cli-sigint-001 / D-005):
//   * std  : no active in-flight cancel; request can remain blocked in
//            response-head; the second SIGINT is the hard-exit 130 escape.
//   * curl : active in-flight cancel via xferinfo abort; first SIGINT cancels
//            and the run returns a headless `cancelled` terminal (exit 11).
const http_backend = fixture_opts.http_backend;

const secret_fixture = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
const port_file_name = "sigint_slow_mock.port";
const ready_file_name = "sigint_slow_mock.ready";

/// Wait for `pid` to exit using `waitpid(WNOHANG)` with bounded polling.
/// Returns the raw status word, or `null` if the bound elapsed.
fn waitBounded(io: Io, pid: std.posix.pid_t, bound_ms: u64) ?u32 {
    var elapsed: u64 = 0;
    const step_ms: u64 = 10;
    while (elapsed < bound_ms) {
        var status: c_int = 0;
        const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (r == pid) return @bitCast(status);
        if (r < 0) return null;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(step_ms), .real) catch {};
        elapsed += step_ms;
    }
    return null;
}

/// Reap a child unconditionally: SIGKILL then waitpid (blocking) so no zombies
/// leak between tests. Best-effort; ignores errors.
fn reap(io: Io, pid: std.posix.pid_t) void {
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = io;
}

/// Read from `fd` into `buf`, polling for readability with a per-iteration
/// timeout. Accumulates until `marker` is found, EOF, or `bound_ms` elapses.
const ReadResult = struct {
    bytes: []u8,
    found: bool,
    eof: bool,
    timed_out: bool,
};

fn readUntilMarker(
    gpa: std.mem.Allocator,
    io: Io,
    fd: std.posix.fd_t,
    marker: []const u8,
    bound_ms: u64,
) !ReadResult {
    _ = io;
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);
    var elapsed: u64 = 0;
    const step_ms: i32 = 10;
    while (elapsed < bound_ms) {
        var pfds: [1]std.posix.pollfd = .{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfds, step_ms) catch return .{
            .bytes = try acc.toOwnedSlice(gpa),
            .found = false,
            .eof = false,
            .timed_out = false,
        };
        elapsed += @intCast(step_ms);
        if (n == 0) continue;
        if (pfds[0].revents == 0) continue;
        var chunk: [4096]u8 = undefined;
        const rc = std.c.read(fd, &chunk, chunk.len);
        if (rc < 0) {
            switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => continue,
                else => return error.ReadFailed,
            }
        }
        if (rc == 0) {
            return .{ .bytes = try acc.toOwnedSlice(gpa), .found = std.mem.indexOf(u8, acc.items, marker) != null, .eof = true, .timed_out = false };
        }
        try acc.appendSlice(gpa, chunk[0..@intCast(rc)]);
        if (std.mem.indexOf(u8, acc.items, marker) != null) {
            return .{ .bytes = try acc.toOwnedSlice(gpa), .found = true, .eof = false, .timed_out = false };
        }
    }
    return .{ .bytes = try acc.toOwnedSlice(gpa), .found = false, .eof = false, .timed_out = true };
}

fn absPath(io: Io, rel: []const u8) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, rel, &buf);
    return try std.heap.page_allocator.dupe(u8, buf[0..n]);
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

/// Start the slow mock server (separate process), wait for the port file, and
/// return (pid, port). Caller must reap the mock child.
fn startSlowMock(io: Io, cwd: Io.Dir, stall_ms: u64, want_ready: bool) !struct {
    pid: std.posix.pid_t,
    port: u16,
} {
    const stall_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{stall_ms});
    defer std.heap.page_allocator.free(stall_str);
    const abs = try absPath(io, slow_mock_bin);
    defer std.heap.page_allocator.free(abs);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, abs);
    try argv.append(std.heap.page_allocator, "--port-file");
    try argv.append(std.heap.page_allocator, port_file_name);
    try argv.append(std.heap.page_allocator, "--stall-ms");
    try argv.append(std.heap.page_allocator, stall_str);
    if (want_ready) {
        try argv.append(std.heap.page_allocator, "--ready-file");
        try argv.append(std.heap.page_allocator, ready_file_name);
    }

    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    const pid = child.id orelse return error.NoPid;

    var port: u16 = 0;
    var spins: u32 = 0;
    while (port == 0 and spins < 8000) : (spins += 1) {
        const content = cwd.readFileAlloc(io, port_file_name, std.heap.page_allocator, .limited(32)) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .real) catch {};
                continue;
            },
            else => return err,
        };
        defer std.heap.page_allocator.free(content);
        port = std.fmt.parseInt(u16, std.mem.trim(u8, content, " \n"), 10) catch continue;
    }
    if (port == 0) return error.PortFileTimeout;
    return .{ .pid = pid, .port = port };
}

/// Block until the slow mock's request-ready marker file appears (bounded).
/// This is the deterministic handshake that the std-backend request is now
/// in-flight and blocked in receiveHead — NOT a blind sleep (review item 5).
fn waitRequestReady(io: Io, cwd: Io.Dir, bound_ms: u64) !void {
    var elapsed: u64 = 0;
    const step_ms: u64 = 5;
    while (elapsed < bound_ms) {
        const content = cwd.readFileAlloc(io, ready_file_name, std.heap.page_allocator, .limited(16)) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(step_ms), .real) catch {};
                elapsed += step_ms;
                continue;
            },
            else => return err,
        };
        defer std.heap.page_allocator.free(content);
        if (std.mem.indexOf(u8, content, "ready") != null) return;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(step_ms), .real) catch {};
        elapsed += step_ms;
    }
    return error.RequestReadyTimeout;
}

/// Spawn the direct `zag` binary with pipe stdio under `cwd` + `env_pairs`.
fn spawnZag(io: Io, cwd: Io.Dir, argv_tail: []const []const u8, env_pairs: []const []const u8) !std.process.Child {
    const abs = try absPath(io, zag_bin);
    defer std.heap.page_allocator.free(abs);

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(std.heap.page_allocator);
    try argv_list.append(std.heap.page_allocator, abs);
    for (argv_tail) |a| try argv_list.append(std.heap.page_allocator, a);

    var env = std.process.Environ.Map.init(std.heap.page_allocator);
    defer env.deinit();
    for (env_pairs) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try env.put(pair[0..eq], pair[eq + 1 ..]);
    }

    return std.process.spawn(io, .{
        .argv = argv_list.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;
}

fn assertNoSecretOrPath(out: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, out, secret_fixture) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") == null);
}

fn childStdoutFd(child: *std.process.Child) std.posix.fd_t {
    return child.stdout.?.handle;
}
fn childStderrFd(child: *std.process.Child) std.posix.fd_t {
    return child.stderr.?.handle;
}

test "sigint idle REPL: first SIGINT wakes and direct process exits 0 within bound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Slow mock with stall_ms=0 resolves the provider quickly so the REPL
    // reaches `you>` and then blocks on stdin. No ready-file needed for idle.
    const mock = try startSlowMock(io, tmp.dir, 0, false);
    defer reap(io, mock.pid);

    const env_pairs = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env_pairs[1]);
        gpa.free(env_pairs);
    }

    var child = try spawnZag(io, tmp.dir, &.{"--no-project"}, env_pairs);
    // Keep stdin pipe open so the REPL blocks reading (no prompt args → REPL).
    defer {
        if (child.id != null) {
            reap(io, child.id.?);
            child.id = null;
        }
    }

    const ready_marker = "you> ";
    const rr = try readUntilMarker(gpa, io, childStdoutFd(&child), ready_marker, 8000);
    defer gpa.free(rr.bytes);
    if (rr.timed_out or !rr.found) {
        const stderr_rr = readUntilMarker(gpa, io, childStderrFd(&child), "x", 50) catch null;
        defer if (stderr_rr) |s| gpa.free(s.bytes);
        try std.testing.expect(rr.found);
    }

    // First SIGINT (deterministic: prompt is observed from output).
    const pid = child.id orelse return error.NoPid;
    try std.posix.kill(pid, std.posix.SIG.INT);

    const status_opt = waitBounded(io, pid, 4000);
    try std.testing.expect(status_opt != null);
    const status = status_opt.?;
    try std.testing.expect(std.c.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), std.c.W.EXITSTATUS(status));
    child.id = null; // reaped

    // stderr must not contain Zig runtime error/stack traces (review item 4/6).
    const err_rr = try readUntilMarker(gpa, io, childStderrFd(&child), "x", 100);
    defer gpa.free(err_rr.bytes);
    try std.testing.expect(std.mem.indexOf(u8, err_rr.bytes, "error:") == null);
    try std.testing.expect(std.mem.indexOf(u8, err_rr.bytes, "stack trace") == null);
    try std.testing.expect(std.mem.indexOf(u8, err_rr.bytes, "ReadFailed") == null);
    try assertNoSecretOrPath(err_rr.bytes);
}

test "sigint active request: backend-honest second-signal escape (std=130) / active cancel (curl)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Slow mock stalls before the response head so a std-backend one-shot
    // request stays blocked in receiveHead. It writes a ready marker after
    // consuming the request, so we wait on that (deterministic) before
    // signalling — no blind correctness sleep (review item 5).
    const mock = try startSlowMock(io, tmp.dir, 20_000, true);
    defer reap(io, mock.pid);

    const env_pairs = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env_pairs[1]);
        gpa.free(env_pairs);
    }

    var child = try spawnZag(io, tmp.dir, &.{ "--json", "hello" }, env_pairs);
    defer {
        if (child.id != null) {
            reap(io, child.id.?);
            child.id = null;
        }
    }

    // Deterministic handshake: wait for the mock's request-ready marker so we
    // know the std-backend request is in-flight and blocked BEFORE signalling.
    try waitRequestReady(io, tmp.dir, 4000);

    const pid = child.id orelse return error.NoPid;
    // First SIGINT: cooperative cancel request (handler sets flag + state).
    try std.posix.kill(pid, std.posix.SIG.INT);

    switch (http_backend) {
        .std => {
            // std has no active in-flight cancel; the request stays blocked, so
            // the interrupt stays pending. Second SIGINT hard-exits 130.
            // No blind sleep: a tiny bounded grace lets the first signal land
            // and the handler transition IDLE->PENDING; the bound is NOT the
            // correctness oracle (the exit status + readiness handshake are).
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
            try std.posix.kill(pid, std.posix.SIG.INT);
            const status_opt = waitBounded(io, pid, 4000);
            try std.testing.expect(status_opt != null);
            const status = status_opt.?;
            try std.testing.expect(std.c.W.IFEXITED(status));
            try std.testing.expectEqual(@as(u8, 130), std.c.W.EXITSTATUS(status));
            child.id = null;
        },
        .curl => {
            // curl actively aborts the in-flight request on the first SIGINT;
            // the run returns a headless cancelled terminal (exit 11) within a
            // bound. Parse stdout to prove EXACTLY one terminal and that it is
            // `cancelled` (review item 5).
            const status_opt = waitBounded(io, pid, 4000);
            try std.testing.expect(status_opt != null);
            const status = status_opt.?;
            try std.testing.expect(std.c.W.IFEXITED(status));
            try std.testing.expectEqual(@as(u8, 11), std.c.W.EXITSTATUS(status));
            child.id = null;

            // Read stdout and verify exactly one headless terminal envelope,
            // and that it is a `cancelled` result (review item 5).
            const out_rr = try readUntilMarker(gpa, io, childStdoutFd(&child), "x", 200);
            defer gpa.free(out_rr.bytes);
            // `--json` emits exactly one `"type":"result"` terminal envelope.
            const term_tag = "\"type\":\"result\"";
            const first = std.mem.indexOf(u8, out_rr.bytes, term_tag);
            try std.testing.expect(first != null);
            const second = std.mem.indexOfPos(u8, out_rr.bytes, first.? + term_tag.len, term_tag);
            try std.testing.expect(second == null);
            // No competing terminal type (error/run_end) may also appear.
            try std.testing.expect(std.mem.indexOf(u8, out_rr.bytes, "\"type\":\"error\"") == null);
            // The terminal is a cancelled result.
            try std.testing.expect(std.mem.indexOf(u8, out_rr.bytes, "\"stop_reason\":\"cancelled\"") != null);
            try assertNoSecretOrPath(out_rr.bytes);
        },
    }
}
