//! Process-level tui-minimal-001 fixtures (§11 #28–32, #18).
//! Linked only when root builds with `-Dtui=true`.
//!
//! ## Oracles (non-vacuous)
//!
//! | Gate | Setup | Exact proof |
//! |------|--------|-------------|
//! | #28 non-TTY | pipes (std.process.run) | exit 2, empty stdout |
//! | #29 mode matrix | pipes | exit 2 / help 0 |
//! | #30 geometry | PTY 10×3 + key+base URL | exit 1, geometry diag, no alt-screen, no MissingApiKey; 80×24 control reaches `state:idle` |
//! | #31 idle SIGINT | PTY 80×24 + mock, wait `state:idle` | first SIGINT → exact exit 0 |
//! | #31 busy first | slow mock ready-file + prompt | first SIGINT → `state:closing`/`closing`, pid alive, no 130 yet |
//! | #31 second (std) | while blocked/pending | second SIGINT → exact 130 |
//! | #31 curl first | same busy setup | cooperative cancel path; no fake completed; no unack-130 claim |
//! | #32 restore | PTY, wait idle | ICANON/ECHO off in raw; write Ctrl+D; exit 0; termios restored on slave |
//! | #18 blocked | std busy + first SIGINT | visible closing, no completed/success, still alive, then 130 |
//!
//! macOS (and Linux when openpty available): real openpty. Other OS: SkipZigTest.
//! Backend honesty: std hard 130 vs curl active cancel — no fake second-SIGINT oracle on curl.
//!
//! No production test backdoors. Public env only: ZAG_API_KEY + ZAG_BASE_URL.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const fixture_opts = @import("tui_fixture_options");

const zag_bin: []const u8 = fixture_opts.zag_bin;
const slow_mock_bin: []const u8 = fixture_opts.slow_mock_bin;
const headless_mock_bin: []const u8 = fixture_opts.headless_mock_bin;
const http_backend = fixture_opts.http_backend;

const secret_fixture = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
const port_file_name = "tui_slow_mock.port";
const ready_file_name = "tui_slow_mock.ready";

const geometry_diag = "tui: terminal too small (need ≥ 20×5)";
const alt_enter = "\x1b[?1049h";
const state_idle = "state:idle";
const state_busy = "state:busy";
const state_closing = "state:closing";
const note_closing = "closing";

const tui_argv = [_][]const u8{ "--tui", "--no-project", "--no-skills", "--no-prompt-templates" };

const pty_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

// ── pipe mode matrix (non-PTY) ──────────────────────────────────────────────

const RunOut = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: *RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runZagPipes(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, argv_tail: []const []const u8) !RunOut {
    var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try Io.Dir.cwd().realPathFile(io, zag_bin, &abs_buf);
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.append(gpa, abs_buf[0..abs_len]);
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
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
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
    var out = try runZagPipes(gpa, io, tmp.dir, &.{"--tui"});
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_json_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--tui", "--json", "hi" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
}

test "gate29_mode_matrix_tui_json_stream_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--tui", "--json-stream", "hi" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
}

test "gate29_mode_matrix_tui_doctor_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--tui", "--doctor" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
}

test "gate29_mode_matrix_tui_prompt_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--tui", "hello" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
}

test "gate29_mode_matrix_tui_verbose_exit2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--tui", "--verbose" });
    defer out.deinit(gpa);
    try expectExited(out.term, 2);
}

test "gate29_help_with_tui_exit0_no_init" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--help", "--tui" });
    defer out.deinit(gpa);
    try expectExited(out.term, 0);
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn absPath(io: Io, rel: []const u8) ![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try Io.Dir.cwd().realPathFile(io, rel, &buf);
    return try std.heap.page_allocator.dupe(u8, buf[0..n]);
}

fn makeEnvPairs(gpa: std.mem.Allocator, port: u16) ![]const []const u8 {
    const url = try std.fmt.allocPrint(gpa, "ZAG_BASE_URL=http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(url);
    const pairs = try gpa.alloc([]const u8, 2);
    pairs[0] = "ZAG_API_KEY=" ++ secret_fixture;
    pairs[1] = url;
    return pairs;
}

fn reap(io: Io, pid: posix.pid_t) void {
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = io;
}

fn waitPeek(pid: posix.pid_t) ?u32 {
    var status: c_int = 0;
    const r = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (r == pid) return @bitCast(status);
    return null;
}

fn waitBounded(io: Io, pid: posix.pid_t, bound_ms: u64) ?u32 {
    return waitBoundedDrain(io, pid, bound_ms, null, null, null);
}

/// Wait for pid exit while optionally draining PTY master so the child cannot
/// block forever on a full terminal write buffer (SIGINT/exit path needs paint).
fn waitBoundedDrain(
    io: Io,
    pid: posix.pid_t,
    bound_ms: u64,
    master: ?posix.fd_t,
    acc: ?*std.ArrayList(u8),
    gpa: ?std.mem.Allocator,
) ?u32 {
    var start_tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&start_tv, null);
    const started_us = @as(i128, start_tv.sec) * 1_000_000 + start_tv.usec;
    const step_ms: i32 = 20;
    while (true) {
        if (waitPeek(pid)) |st| return st;
        var now_tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&now_tv, null);
        const now_us = @as(i128, now_tv.sec) * 1_000_000 + now_tv.usec;
        if (now_us -| started_us >= @as(i128, bound_ms) * 1000) return null;
        if (master) |m| {
            var pfds = [_]posix.pollfd{.{ .fd = m, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfds, step_ms) catch {};
            var chunk: [4096]u8 = undefined;
            while (true) {
                const rc = std.c.read(m, &chunk, chunk.len);
                if (rc <= 0) break;
                if (acc) |a| {
                    if (gpa) |alloc| {
                        a.appendSlice(alloc, chunk[0..@intCast(rc)]) catch {};
                    }
                }
            }
        } else {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(step_ms)), .real) catch {};
        }
    }
}

fn pidAlive(pid: posix.pid_t) bool {
    // kill(pid, 0) existence probe (signal 0 = no delivery).
    const rc = std.c.kill(pid, @enumFromInt(0));
    return rc == 0;
}

fn exitCode(status: u32) ?u8 {
    if (std.c.W.IFEXITED(status)) return @intCast(std.c.W.EXITSTATUS(status));
    return null;
}

// ── slow mock ───────────────────────────────────────────────────────────────

fn startSlowMock(io: Io, cwd: Io.Dir, stall_ms: u64, want_ready: bool) !struct { pid: posix.pid_t, port: u16 } {
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

/// session-swap-001: the headless mock completes FULL chat responses (the
/// slow mock's full-response path is not exercised by any test) — used by
/// the gate33 /resume → continue fixture.
fn startHeadlessMock(io: Io, cwd: Io.Dir) !struct { pid: posix.pid_t, port: u16 } {
    const abs = try absPath(io, headless_mock_bin);
    defer std.heap.page_allocator.free(abs);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, abs);
    try argv.append(std.heap.page_allocator, "--port-file");
    try argv.append(std.heap.page_allocator, port_file_name);
    // Serve until killed: the TUI startup /models probe (curl backend)
    // consumes a request before the fixture's chat request.
    try argv.append(std.heap.page_allocator, "--max-requests");
    try argv.append(std.heap.page_allocator, "0");

    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    const pid = child.id orelse return error.NoPid;
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

/// Wait for the mock's ready-file while CONTINUING TO DRAIN the PTY master.
///
/// The ready-file is the deterministic "request consumed, about to stall"
/// handshake; but between the preceding waitMarker returning and this poll
/// loop, the child may paint more (winsize repaint, busy chrome). An undrained
/// master fills the PTY output buffer (~1KB) and blocks the child's write in
/// paint() — which would stall the Enter→HTTP→ready chain past the bound. Same
/// drain discipline as `waitBoundedDrain` (SIGINT/exit path).
fn waitRequestReady(io: Io, cwd: Io.Dir, bound_ms: u64, pty: *PtySession) !void {
    var elapsed: u64 = 0;
    const step_ms: i32 = 5;
    while (elapsed < bound_ms) {
        var pfds = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&pfds, step_ms) catch {};
        var chunk: [4096]u8 = undefined;
        while (true) {
            const rc = std.c.read(pty.master, &chunk, chunk.len);
            if (rc <= 0) break;
            pty.acc.appendSlice(pty.gpa, chunk[0..@intCast(rc)]) catch {};
        }
        const content = cwd.readFileAlloc(io, ready_file_name, std.heap.page_allocator, .limited(16)) catch |err| switch (err) {
            error.FileNotFound => {
                elapsed += @intCast(step_ms);
                continue;
            },
            else => return err,
        };
        defer std.heap.page_allocator.free(content);
        if (std.mem.indexOf(u8, content, "ready") != null) return;
        elapsed += @intCast(step_ms);
    }
    return error.RequestReadyTimeout;
}

// ── PTY ─────────────────────────────────────────────────────────────────────

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*posix.termios,
    winp: ?*posix.winsize,
) c_int;

const PtySession = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    keep_slave: bool,
    pid: ?posix.pid_t = null,
    /// Exit status observed by waitMarker's waitPeek (curl backend: the
    /// child can exit before the closing marker is read; waitExit reuses it).
    last_status: ?u32 = null,
    acc: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn open(gpa: std.mem.Allocator, cols: u16, rows: u16, keep_slave: bool) !PtySession {
        var master: c_int = -1;
        var slave: c_int = -1;
        var wsz: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master, &slave, null, null, &wsz) != 0) return error.OpenPtyFailed;
        // master nonblocking for poll/read
        const fl = std.c.fcntl(master, std.c.F.GETFL);
        if (fl >= 0) _ = std.c.fcntl(master, std.c.F.SETFL, fl | 0x0004); // O_NONBLOCK mac
        return .{
            .master = master,
            .slave = slave,
            .keep_slave = keep_slave,
            .gpa = gpa,
        };
    }

    fn spawnZag(self: *PtySession, io: Io, cwd_abs: []const u8, env_pairs: []const []const u8) !void {
        const abs = try absPath(io, zag_bin);
        defer std.heap.page_allocator.free(abs);

        var args_z: std.ArrayList([:0]u8) = .empty;
        defer {
            for (args_z.items) |a| self.gpa.free(a);
            args_z.deinit(self.gpa);
        }
        try args_z.append(self.gpa, try self.gpa.dupeZ(u8, abs));
        for (tui_argv) |a| try args_z.append(self.gpa, try self.gpa.dupeZ(u8, a));

        var env_z: std.ArrayList([:0]u8) = .empty;
        defer {
            for (env_z.items) |e| self.gpa.free(e);
            env_z.deinit(self.gpa);
        }
        for (env_pairs) |p| try env_z.append(self.gpa, try self.gpa.dupeZ(u8, p));

        const cwd_z = try self.gpa.dupeZ(u8, cwd_abs);
        defer self.gpa.free(cwd_z);

        var argv_ptrs = try self.gpa.alloc(?[*:0]const u8, args_z.items.len + 1);
        defer self.gpa.free(argv_ptrs);
        for (args_z.items, 0..) |a, i| argv_ptrs[i] = a.ptr;
        argv_ptrs[args_z.items.len] = null;

        var envp_ptrs = try self.gpa.alloc(?[*:0]const u8, env_z.items.len + 1);
        defer self.gpa.free(envp_ptrs);
        for (env_z.items, 0..) |e, i| envp_ptrs[i] = e.ptr;
        envp_ptrs[env_z.items.len] = null;

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Do not setsid/TIOCSCTTY: keep slave as a plain shared PTY so the
            // parent can tcgetattr after cooperative restore (macOS destroys
            // the controlling-tty slave on session exit → NOTTY). SIGINT under
            // test is process-directed via kill(), not tty-generated Ctrl+C.
            _ = std.c.close(self.master);
            _ = std.c.dup2(self.slave, 0);
            _ = std.c.dup2(self.slave, 1);
            _ = std.c.dup2(self.slave, 2);
            if (self.slave > 2) _ = std.c.close(self.slave);
            _ = std.c.chdir(cwd_z.ptr);
            _ = std.c.execve(args_z.items[0].ptr, @ptrCast(argv_ptrs.ptr), @ptrCast(envp_ptrs.ptr));
            std.c._exit(127);
        }
        self.pid = @intCast(pid);
        if (!self.keep_slave) {
            _ = std.c.close(self.slave);
            self.slave = -1;
        }
    }

    fn deinit(self: *PtySession, io: Io) void {
        if (self.pid) |p| {
            reap(io, p);
            self.pid = null;
        }
        if (self.master >= 0) _ = std.c.close(self.master);
        if (self.slave >= 0) _ = std.c.close(self.slave);
        self.acc.deinit(self.gpa);
        self.* = undefined;
    }

    /// Poll master, accumulate output, return true if marker found (bounded).
    fn waitMarker(self: *PtySession, io: Io, marker: []const u8, bound_ms: u64) !bool {
        var elapsed: u64 = 0;
        const step: i32 = 20;
        while (elapsed < bound_ms) {
            if (self.pid) |p| {
                if (waitPeek(p)) |st| {
                    self.last_status = st;
                    self.pid = null;
                    _ = io;
                    return std.mem.indexOf(u8, self.acc.items, marker) != null;
                }
            }
            var pfds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfds, step) catch {};
            elapsed += @intCast(step);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const rc = std.c.read(self.master, &chunk, chunk.len);
                if (rc < 0) break;
                if (rc == 0) break;
                try self.acc.appendSlice(self.gpa, chunk[0..@intCast(rc)]);
            }
            if (std.mem.indexOf(u8, self.acc.items, marker) != null) return true;
        }
        return std.mem.indexOf(u8, self.acc.items, marker) != null;
    }

    fn writeAll(self: *PtySession, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.master, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
    }

    fn waitExit(self: *PtySession, io: Io, bound_ms: u64) ?u32 {
        const pid = self.pid orelse return self.last_status;
        const st = waitBoundedDrain(io, pid, bound_ms, self.master, &self.acc, self.gpa);
        if (st != null) {
            self.last_status = st;
            self.pid = null;
        }
        return st;
    }
};

fn tmpCwdAbs(io: Io, tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    return try std.heap.page_allocator.dupe(u8, path_buf[0..n]);
}

// ── Gate #30 geometry ───────────────────────────────────────────────────────

test "gate30_pty_geometry_below_min_exit1_with_provider_env" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Mock with zero stall — only needed so env+resolve would work if geometry allowed.
    const mock = try startSlowMock(io, tmp.dir, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 10, 3, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    // Wait for process exit while draining master (geometry before raw).
    const st = pty.waitExit(io, 8000) orelse {
        pty.deinit(io);
        return error.Timeout;
    };
    const code = exitCode(st) orelse return error.NotExited;
    try std.testing.expectEqual(@as(u8, 1), code);

    const out = pty.acc.items;
    try std.testing.expect(std.mem.indexOf(u8, out, geometry_diag) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, alt_enter) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MissingApiKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "missing API key") == null);

    pty.deinit(io);
}

test "gate30_control_80x24_reaches_idle_proves_env" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mock = try startSlowMock(io, tmp.dir, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    const found = try pty.waitMarker(io, state_idle, 12_000);
    try std.testing.expect(found);
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, alt_enter) != null);
    // Clean cooperative exit for hygiene.
    if (pty.pid != null) {
        pty.writeAll(&.{0x04}); // Ctrl+D empty → exit 0
        _ = pty.waitExit(io, 5000);
    }
    pty.deinit(io);
}

// ── Gate #31 idle / busy / second ───────────────────────────────────────────

test "gate31_pty_idle_first_sigint_exit0_after_state_idle" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mock = try startSlowMock(io, tmp.dir, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    try std.testing.expect(try pty.waitMarker(io, state_idle, 12_000));
    const pid = pty.pid orelse return error.NoPid;
    try std.posix.kill(pid, std.posix.SIG.INT);

    // Drain master while waiting — otherwise child blocks on paint and never exits.
    const st = pty.waitExit(io, 5000) orelse {
        pty.deinit(io);
        return error.Timeout;
    };
    try std.testing.expectEqual(@as(u8, 0), exitCode(st).?);
    pty.deinit(io);
}

test "gate31_pty_busy_first_sigint_closing_alive_std_second_130" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Long stall for std blocked path; ready-file handshake before first SIGINT.
    const mock = try startSlowMock(io, tmp.dir, 30_000, true);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    try std.testing.expect(try pty.waitMarker(io, state_idle, 12_000));

    // Submit root prompt (Enter).
    pty.writeAll("hello-busy\r");

    // Deterministic: mock consumed request and is about to stall.
    try waitRequestReady(io, tmp.dir, 8000, &pty);

    // Optional: busy chrome if paint landed.
    _ = try pty.waitMarker(io, state_busy, 1500);

    const pid = pty.pid orelse return error.NoPid;
    try std.posix.kill(pid, std.posix.SIG.INT);

    // Must show closing / note and stay alive briefly (std blocked).
    var saw_closing = try pty.waitMarker(io, state_closing, 3000);
    if (!saw_closing) saw_closing = try pty.waitMarker(io, note_closing, 800);
    try std.testing.expect(saw_closing);
    // Curl actively cancels: the process may already be gone by the time the
    // closing marker lands — pid-alive is only guaranteed for the std
    // backend (still blocked in receiveHead). The curl branch below asserts
    // the cooperative exit instead.
    if (http_backend == .std) {
        try std.testing.expect(pidAlive(pid));
        // No hard exit yet.
        try std.testing.expect(pty.pid != null);
    }

    switch (http_backend) {
        .std => {
            // Second SIGINT while Guard still pending → hard 130.
            // Drain PTY while retrying so paint/cancel path cannot block.
            var elapsed: u64 = 0;
            var got130 = false;
            while (elapsed < 6000) {
                if (pty.waitExit(io, 50)) |st| {
                    try std.testing.expectEqual(@as(u8, 130), exitCode(st).?);
                    got130 = true;
                    break;
                }
                try std.posix.kill(pid, std.posix.SIG.INT);
                elapsed += 50;
            }
            try std.testing.expect(got130);
            try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "stop=completed") == null);
        },
        .curl => {
            // Curl backend limitation: libcurl does not invoke the XFERINFO
            // progress callback while waiting for the response head (no
            // transfer activity), so a provider that stalls before the head
            // cannot be cancelled promptly — the request only observes the
            // cancel flag once data starts flowing (or the mock replies).
            // The gate therefore bounds at the TUI shutdown join bound (30s)
            // plus margin, and asserts the cooperative exit actually happens
            // (no unacknowledged second-SIGINT 130 claim).
            const st = pty.waitExit(io, 35_000);
            try std.testing.expect(st != null);
            const code = exitCode(st.?).?;
            try std.testing.expect(code == 0 or code == 1);
            try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "stop=completed") == null);
        },
    }
    pty.deinit(io);
}

// ── Gate #32 cooperative restore ────────────────────────────────────────────

test "gate32_pty_ctrl_d_exit0_termios_restored" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mock = try startSlowMock(io, tmp.dir, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, true); // keep slave for termios
    errdefer pty.deinit(io);

    const orig = try posix.tcgetattr(pty.slave);

    try pty.spawnZag(io, cwd_abs, env);
    try std.testing.expect(try pty.waitMarker(io, state_idle, 12_000));

    // Raw mode on input: ICANON and ECHO off.
    const raw_tios = try posix.tcgetattr(pty.slave);
    try std.testing.expect(!raw_tios.lflag.ICANON);
    try std.testing.expect(!raw_tios.lflag.ECHO);

    // Real Ctrl+D (empty buffer idle EOF → exit 0). Do NOT close master.
    pty.writeAll(&.{0x04});

    const st = pty.waitExit(io, 5000) orelse {
        pty.deinit(io);
        return error.Timeout;
    };
    try std.testing.expectEqual(@as(u8, 0), exitCode(st).?);

    // Termios restored on slave after cooperative exit.
    const after = try posix.tcgetattr(pty.slave);
    try std.testing.expectEqual(orig.lflag.ICANON, after.lflag.ICANON);
    try std.testing.expectEqual(orig.lflag.ECHO, after.lflag.ECHO);
    try std.testing.expectEqual(orig.lflag.ISIG, after.lflag.ISIG);
    try std.testing.expectEqual(orig.lflag.IEXTEN, after.lflag.IEXTEN);
    try std.testing.expectEqual(orig.iflag.ICRNL, after.iflag.ICRNL);
    try std.testing.expectEqual(orig.iflag.IXON, after.iflag.IXON);

    // Alt-screen leave if we entered (best-effort check).
    _ = try pty.waitMarker(io, "\x1b[?1049l", 200);

    pty.deinit(io);
}

// ── session-swap-001: real binary /resume → select → continue ──────────────

test "gate33_pty_resume_swap_continue_appends_to_selected_session" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A saved session the TUI can swap to. The initial session is EPHEMERAL
    // (no -c/-s), so the resume overlay lists exactly ONE row ("beta") —
    // deterministic selection (cursor 0 + Enter), no FS-order dependence.
    try tmp.dir.createDirPath(io, ".zag/sessions");
    const beta_fixture =
        \\{"schema_version":1,"v":1,"type":"zag_session","compaction_gen":0}
        \\{"role":"user","content":"beta-original-q"}
        \\{"role":"assistant","content":"beta-original-a"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = ".zag/sessions/beta.jsonl", .data = beta_fixture });

    // Full-chat mock (headless mock server): the slow mock's full-response
    // path is not exercised by any existing test, so the headless mock —
    // proven by headless_process_fixture — serves the post-swap reply.
    const mock = try startHeadlessMock(io, tmp.dir);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    // Idle, then open /resume; the only listed session row is "beta".
    try std.testing.expect(try pty.waitMarker(io, state_idle, 12_000));
    pty.writeAll("/resume\r");
    try std.testing.expect(try pty.waitMarker(io, "beta", 5000));
    pty.writeAll("\r"); // Enter: select beta → swap + replay

    // The swap replayed the selected session's transcript (its cards paint
    // in the transcript area; the swap note itself is width-truncated on
    // 80 cols, so the replayed body is the deterministic marker).
    try std.testing.expect(try pty.waitMarker(io, "beta-original-a", 5000));

    // Real continue: the next message appends to the SELECTED session.
    pty.writeAll("swapped-continue\r");
    // Reply completion marker: the assistant turn card paints the mock's
    // response body in the transcript (the run_terminal reserve card is a
    // .terminal-kind card that drawCards skips — never rendered).
    try std.testing.expect(try pty.waitMarker(io, "Hello from mock", 12_000));

    // The selected session file now holds BOTH halves (original + new turn).
    // Poll with a bound: the save commits just after the stream completes
    // (the run_terminal reserve card is never rendered — drawCards skips
    // .terminal cards — so the file is the deterministic completion proof).
    var saved = false;
    var spins: u32 = 0;
    while (spins < 500 and !saved) : (spins += 1) {
        const raw = tmp.dir.readFileAlloc(io, ".zag/sessions/beta.jsonl", gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
                continue;
            },
            else => return err,
        };
        if (std.mem.indexOf(u8, raw, "beta-original-q") != null and
            std.mem.indexOf(u8, raw, "beta-original-a") != null and
            std.mem.indexOf(u8, raw, "swapped-continue") != null and
            std.mem.indexOf(u8, raw, "Hello from mock") != null)
        {
            saved = true;
        }
        gpa.free(raw);
        if (!saved) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(saved);

    // Clean cooperative exit.
    if (pty.pid != null) {
        pty.writeAll(&.{0x04}); // Ctrl+D empty → exit 0
        _ = pty.waitExit(io, 5000);
    }
    pty.deinit(io);
}

// ── Gate #18 blocked provider visible closing ───────────────────────────────

test "gate18_pty_blocked_provider_closing_no_fake_success_std_130" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mock = try startSlowMock(io, tmp.dir, 30_000, true);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }

    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa, 80, 24, false);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    try std.testing.expect(try pty.waitMarker(io, state_idle, 12_000));
    pty.writeAll("block-me\r");
    try waitRequestReady(io, tmp.dir, 8000, &pty);

    const pid = pty.pid orelse return error.NoPid;
    try std.posix.kill(pid, std.posix.SIG.INT);

    var saw_closing = try pty.waitMarker(io, state_closing, 3000);
    if (!saw_closing) saw_closing = try pty.waitMarker(io, note_closing, 800);
    try std.testing.expect(saw_closing);
    try std.testing.expect(pidAlive(pid));
    // No invented completed success.
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "stop=completed") == null);
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "ok=true stop=completed") == null);

    switch (http_backend) {
        .std => {
            var elapsed: u64 = 0;
            var got130 = false;
            while (elapsed < 6000) {
                if (pty.waitExit(io, 50)) |st| {
                    try std.testing.expectEqual(@as(u8, 130), exitCode(st).?);
                    got130 = true;
                    break;
                }
                try std.posix.kill(pid, std.posix.SIG.INT);
                elapsed += 50;
            }
            try std.testing.expect(got130);
        },
        .curl => {
            const st = pty.waitExit(io, 8000);
            try std.testing.expect(st != null);
            try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "stop=completed") == null);
        },
    }
    pty.deinit(io);
}
