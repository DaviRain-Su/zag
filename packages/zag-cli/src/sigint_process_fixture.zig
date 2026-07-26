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
//!     requests cooperative cancel; the fixture then uses a bounded retry
//!     escape loop — periodic re-SIGINT until the process actually exits 130
//!     (no "assume the first signal landed after 10ms" correctness premise).
//!   * Active curl-backend request: first SIGINT actively aborts the in-flight
//!     transfer; the run returns a headless `cancelled` terminal (exit 11);
//!     stdout is read to EOF and parsed to prove EXACTLY one terminal and that
//!     it is `cancelled`.
//!
//! Determinism (cli-sigint-001 review item 5 / P2 follow-up): no blind sleep
//! decides the injection point. The slow mock writes a `ready` marker after
//! consuming the full HTTP request and before the response-head stall; the
//! fixture waits on that marker, THEN sends the first SIGINT. All waits are
//! bounded; on failure the fixture reaps/kills children for clean diagnosis.
//! Output must not leak secrets or absolute paths.

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
/// Returns the raw status word, or `null` if the bound elapsed. When waitpid
/// returns `pid` the child HAS been reaped (waitpid is not just a peek); the
/// caller must not wait/reap that pid again. Safe to call repeatedly until it
/// returns non-null — only one waitpid will succeed.
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

/// Reap a child unconditionally: SIGKILL then blocking waitpid so no zombies
/// leak between tests. Best-effort; ignores errors. Idempotent — calling after
/// a successful waitBounded reap is safe (waitpid returns -1/ECHILD).
fn reap(io: Io, pid: std.posix.pid_t) void {
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = io;
}

/// Read `fd` to EOF with bounded polling. Accumulates everything until EOF or
/// `bound_ms` elapses (no marker-based early truncation — P2 hygiene). The
/// caller owns the returned bytes.
const ReadEofResult = struct {
    bytes: []u8,
    eof: bool,
    timed_out: bool,
};

fn readToEof(gpa: std.mem.Allocator, io: Io, fd: std.posix.fd_t, bound_ms: u64) !ReadEofResult {
    _ = io;
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);
    var elapsed: u64 = 0;
    const step_ms: i32 = 10;
    while (elapsed < bound_ms) {
        var pfds: [1]std.posix.pollfd = .{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        // Unexpected poll error -> typed ReadFailed (no silent infinite continue).
        const n = std.posix.poll(&pfds, step_ms) catch return error.ReadFailed;
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
            return .{ .bytes = try acc.toOwnedSlice(gpa), .eof = true, .timed_out = false };
        }
        try acc.appendSlice(gpa, chunk[0..@intCast(rc)]);
    }
    return .{ .bytes = try acc.toOwnedSlice(gpa), .eof = false, .timed_out = true };
}

/// Read from `fd` until `marker` is found, EOF, or `bound_ms` elapses. Used
/// only for the `you>` prompt readiness poll (a real marker, not a sentinel).
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
        // Unexpected poll error -> typed ReadFailed (no silent masking).
        const n = std.posix.poll(&pfds, step_ms) catch return error.ReadFailed;
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
/// return (pid, port). On any failure after spawn (port-file timeout/parse
/// error), the child is killed+reaped via errdefer so it cannot leak (P2).
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

    // P2 hygiene: if anything below fails, kill+reap the mock child so it
    // cannot leak as a zombie/orphan between tests.
    errdefer reap(io, pid);

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
    var zag_reaped = false;
    defer if (!zag_reaped) {
        if (child.id != null) {
            reap(io, child.id.?);
            child.id = null;
        }
    };

    const ready_marker = "you> ";
    const rr = try readUntilMarker(gpa, io, childStdoutFd(&child), ready_marker, 8000);
    defer gpa.free(rr.bytes);
    if (rr.timed_out or !rr.found) {
        const stderr_eof = readToEof(gpa, io, childStderrFd(&child), 50) catch null;
        defer if (stderr_eof) |s| gpa.free(s.bytes);
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
    child.id = null;
    zag_reaped = true; // waitBounded reaped it; do not double-reap.

    // stderr read to EOF (no marker truncation — P2 hygiene). Must reach EOF
    // (not time out) so truncated output cannot pass the assertions below.
    const err_eof = try readToEof(gpa, io, childStderrFd(&child), 200);
    defer gpa.free(err_eof.bytes);
    try std.testing.expect(err_eof.eof);
    try std.testing.expect(!err_eof.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, err_eof.bytes, "error:") == null);
    try std.testing.expect(std.mem.indexOf(u8, err_eof.bytes, "stack trace") == null);
    try std.testing.expect(std.mem.indexOf(u8, err_eof.bytes, "ReadFailed") == null);
    try assertNoSecretOrPath(err_eof.bytes);
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
    var zag_reaped = false;
    defer if (!zag_reaped) {
        if (child.id != null) {
            reap(io, child.id.?);
            child.id = null;
        }
    };

    // Deterministic handshake: wait for the mock's request-ready marker so we
    // know the std-backend request is in-flight and blocked BEFORE signalling.
    try waitRequestReady(io, tmp.dir, 4000);

    const pid = child.id orelse return error.NoPid;
    // First SIGINT: cooperative cancel request (handler sets flag + state).
    try std.posix.kill(pid, std.posix.SIG.INT);

    switch (http_backend) {
        .std => {
            // std has no active in-flight cancel; the request stays blocked, so
            // the interrupt stays pending. Bounded retry escape (P2): poll
            // waitpid(WNOHANG); if the process has not exited, periodically
            // re-send SIGINT until a second unacknowledged delivery actually
            // lands and the handler hard-exits 130. The sleep is ONLY the poll
            // cadence — never a "10ms then assume the first landed" premise.
            const total_bound_ms: u64 = 6000;
            const cadence_ms: u64 = 50;
            var elapsed: u64 = 0;
            var escaped = false;
            while (elapsed < total_bound_ms) {
                if (waitBounded(io, pid, cadence_ms)) |status| {
                    try std.testing.expect(std.c.W.IFEXITED(status));
                    try std.testing.expectEqual(@as(u8, 130), std.c.W.EXITSTATUS(status));
                    escaped = true;
                    break;
                }
                // Not yet exited: re-send SIGINT. A handler that already
                // transitioned IDLE->PENDING on the first delivery will, on
                // this next delivery, see pending and hard-exit 130. If the
                // first delivery had not yet landed, this becomes the first.
                try std.posix.kill(pid, std.posix.SIG.INT);
                elapsed += cadence_ms;
            }
            try std.testing.expect(escaped);
            child.id = null;
            zag_reaped = true;
        },
        .curl => {
            // curl actively aborts the in-flight request on the first SIGINT;
            // the run returns a headless cancelled terminal (exit 11) within a
            // bound. Read stdout to EOF (no marker truncation) and verify
            // exactly one headless terminal envelope, cancelled (review item 5).
            const status_opt = waitBounded(io, pid, 4000);
            try std.testing.expect(status_opt != null);
            const status = status_opt.?;
            try std.testing.expect(std.c.W.IFEXITED(status));
            try std.testing.expectEqual(@as(u8, 11), std.c.W.EXITSTATUS(status));
            child.id = null;
            zag_reaped = true;

            const out_eof = try readToEof(gpa, io, childStdoutFd(&child), 300);
            defer gpa.free(out_eof.bytes);
            // Must reach EOF so a truncated terminal stream cannot pass.
            try std.testing.expect(out_eof.eof);
            try std.testing.expect(!out_eof.timed_out);
            // `--json` emits exactly one `"type":"result"` terminal envelope.
            const term_tag = "\"type\":\"result\"";
            const first = std.mem.indexOf(u8, out_eof.bytes, term_tag);
            try std.testing.expect(first != null);
            const second = std.mem.indexOfPos(u8, out_eof.bytes, first.? + term_tag.len, term_tag);
            try std.testing.expect(second == null);
            // No competing terminal type (error/run_end) may also appear.
            try std.testing.expect(std.mem.indexOf(u8, out_eof.bytes, "\"type\":\"error\"") == null);
            // The terminal is a cancelled result.
            try std.testing.expect(std.mem.indexOf(u8, out_eof.bytes, "\"stop_reason\":\"cancelled\"") != null);
            try assertNoSecretOrPath(out_eof.bytes);
        },
    }
}
