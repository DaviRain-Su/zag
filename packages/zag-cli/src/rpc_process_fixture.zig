//! Process-level rpc-v1-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `rpc_fixture_options.zag_bin`, the mock-server binary via
//! `rpc_fixture_options.headless_mock_bin`, and the HTTP backend tag. It runs
//! this file as a test artifact under `zig build test` (std and curl backends
//! rebuild `zag` accordingly).
//!
//! Spawns the real `zag --rpc` binary under an isolated cwd + synthetic env
//! (mock provider over loopback, no real credentials, no network egress) and
//! drives the NDJSON wire over pipes / PTY, mirroring the TUI PTY gates.
//! ~19 gate classes (rpc-v1-001 §verification):
//!
//!   1  mode matrix (--rpc + --json/--json-stream/--tui/--doctor/--verbose/
//!      positional prompt → exit 2, empty stdout)
//!   2  --rpc --help → exit 0, empty stdout (help on stderr)
//!   3  handshake: first frame = `ready` with exact fields
//!   4  prompt round-trip: deltas + one terminal response (completed)
//!   5  busy: second prompt while in flight → session_busy
//!   6  steer while busy → control_applied + steered text echoed next turn
//!   7  follow_up while busy → control_applied (follow_up) + echoed
//!   8  cancel busy → cancelled, ok=true (cooperative; curl active-cancel)
//!   9  control caps: >4096 B → message_too_long; 5th steer → queue_full
//!  10  permission ask: permission_request → allow runs tool / deny blocks
//!  11  cancel while gate pending → gate denies, run ends cancelled
//!  12  resume: -s run; resume same path; separate --rpc -c resumes durable
//!  13  exit request → ok then EOF, exit 0, session file saved with turns
//!  14  client disconnect (stdin close while busy) → exit 0, session saved
//!  15  protocol errors: bad JSON / unknown method / bad version / over-cap
//!      frame with resync — server continues
//!  16  redaction: fixture secret never appears in any frame
//!  17  PTY: protocol-only stdout (no ANSI), handshake, exit 0
//!  18  PTY signals: busy + first SIGINT → graceful 0; second → 130 (std)
//!  19  ownership: rpc files import no zag-agent-core / zag-tui
//!
//! Determinism: no blind sleeps decide injection points. The mock writes a
//! `ready` marker after consuming the full HTTP request and before the
//! response-head stall; the fixture waits on that marker before sending
//! cancel / steer / SIGINT. All waits are bounded; on failure children are
//! killed + reaped for clean diagnosis. Output must not leak secrets or
//! absolute paths.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const fixture_opts = @import("rpc_fixture_options");
const framing = @import("rpc/framing.zig");

const zag_bin: []const u8 = fixture_opts.zag_bin;
const mock_bin: []const u8 = fixture_opts.headless_mock_bin;
const http_backend = fixture_opts.http_backend;

const secret_fixture = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
const port_file_name = "rpc_mock.port";
const ready_file_name = "rpc_mock.ready";

const protocol_version = "rpc-v1";
const rpc_argv = [_][]const u8{ "--rpc", "--no-project", "--no-skills", "--no-prompt-templates" };

const pty_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

// ── process helpers (sigint/tui fixture style) ──────────────────────────────

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

fn waitBounded(io: Io, pid: posix.pid_t, bound_ms: u64) ?u32 {
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

fn reap(io: Io, pid: posix.pid_t) void {
    _ = std.c.kill(pid, posix.SIG.KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = io;
}

fn exitCode(status: u32) ?u8 {
    if (std.c.W.IFEXITED(status)) return std.c.W.EXITSTATUS(status);
    return null;
}

fn expectExited(status: u32, code: u8) !void {
    const got = exitCode(status) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(code, got);
}

fn assertNoSecretOrPath(out: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, out, secret_fixture) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-test-") == null);
}

/// Wait for the mock's ready-file marker (request consumed, about to stall).
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

/// Start the headless mock (rpc mode: echo + optional tool-call + stall).
fn startMock(
    io: Io,
    cwd: Io.Dir,
    tool_call: bool,
    stall_ms: u64,
    want_ready: bool,
) !MockHandle {
    const abs = try absPath(io, mock_bin);
    defer std.heap.page_allocator.free(abs);
    const stall_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{stall_ms});
    defer std.heap.page_allocator.free(stall_str);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, abs);
    try argv.append(std.heap.page_allocator, "--port-file");
    try argv.append(std.heap.page_allocator, port_file_name);
    try argv.append(std.heap.page_allocator, "--max-requests");
    try argv.append(std.heap.page_allocator, "0");
    try argv.append(std.heap.page_allocator, "--echo");
    if (tool_call) try argv.append(std.heap.page_allocator, "--tool-call");
    if (stall_ms > 0) {
        try argv.append(std.heap.page_allocator, "--stall-ms");
        try argv.append(std.heap.page_allocator, stall_str);
    }
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

// ── RPC client over pipes ───────────────────────────────────────────────────

const Frame = std.json.Value;
const OwnedFrame = std.json.Parsed(Frame);

const RpcClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    pid: posix.pid_t,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    reader: framing.FrameReader,
    /// Frames read but not yet consumed by the current wait.
    pending: std.ArrayList(OwnedFrame) = .empty,

    fn spawn(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, env_pairs: []const []const u8, argv_tail: []const []const u8) !RpcClient {
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

        const child = std.process.spawn(io, .{
            .argv = argv_list.items,
            .cwd = .{ .dir = cwd },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.SpawnFailed;
        const pid = child.id orelse return error.NoPid;
        return .{
            .gpa = gpa,
            .io = io,
            .pid = pid,
            .stdin_fd = child.stdin.?.handle,
            .stdout_fd = child.stdout.?.handle,
            .reader = framing.FrameReader.init(gpa, child.stdout.?.handle),
        };
    }

    fn deinit(self: *RpcClient) void {
        if (self.pid > 0) reap(self.io, self.pid);
        for (self.pending.items) |*f| f.deinit();
        self.pending.deinit(self.gpa);
        self.reader.deinit();
        self.* = undefined;
    }

    /// Write one frame line to the child's stdin.
    fn send(self: *RpcClient, line: []const u8) !void {
        var off: usize = 0;
        while (off < line.len) {
            const n = try rawWrite(self.stdin_fd, line[off..]);
            off += n;
        }
        _ = try rawWrite(self.stdin_fd, "\n");
    }

    fn sendJson(self: *RpcClient, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.write(value);
        try self.send(out.written());
    }

    fn closeStdin(self: *RpcClient) void {
        rawClose(self.stdin_fd);
        self.stdin_fd = -1;
    }

    /// Pull available stdout bytes into the reader (bounded poll).
    fn pump(self: *RpcClient, bound_ms: u64) !bool {
        var elapsed: u64 = 0;
        const step: i32 = 10;
        while (elapsed < bound_ms) {
            var pfds = [_]posix.pollfd{.{ .fd = self.stdout_fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfds, step) catch {};
            if (pfds[0].revents != 0) {
                return self.reader.fill() catch return error.IoFailed;
            }
            elapsed += @intCast(step);
        }
        return false;
    }

    /// Read frames until `pred` matches, accumulating all frames read.
    /// Returns gpa-owned Parsed frames (caller frees with `freeFrames`).
    fn recvUntil(self: *RpcClient, bound_ms: u64, comptime pred: fn (Frame) bool) ![]OwnedFrame {
        var acc: std.ArrayList(OwnedFrame) = .empty;
        errdefer {
            for (acc.items) |*f| f.deinit();
            acc.deinit(self.gpa);
        }
        // Serve pending frames first.
        var idx: usize = 0;
        while (idx < self.pending.items.len) {
            const owned = self.pending.items[idx];
            try acc.append(self.gpa, owned);
            idx += 1;
            if (pred(owned.value)) {
                const rest = self.pending.items[idx..];
                std.mem.copyForwards(OwnedFrame, self.pending.items[0..rest.len], rest);
                self.pending.items.len = rest.len;
                return try acc.toOwnedSlice(self.gpa);
            }
        }
        self.pending.clearRetainingCapacity();

        var elapsed: u64 = 0;
        const step_ms: u64 = 10;
        while (elapsed < bound_ms) {
            _ = try self.pump(step_ms);
            while (self.reader.takeFrame() catch return error.IoFailed) |nxt| {
                switch (nxt) {
                    .line => |line| {
                        const parsed = std.json.parseFromSlice(Frame, self.gpa, line, .{}) catch {
                            self.gpa.free(line);
                            continue; // non-JSON line: not a protocol frame
                        };
                        self.gpa.free(line);
                        try acc.append(self.gpa, parsed);
                        if (pred(parsed.value)) return try acc.toOwnedSlice(self.gpa);
                    },
                    .eof => return try acc.toOwnedSlice(self.gpa),
                    .too_long => continue,
                }
            }
            elapsed += step_ms;
        }
        return try acc.toOwnedSlice(self.gpa);
    }

    fn waitExit(self: *RpcClient, bound_ms: u64) ?u32 {
        const st = waitBounded(self.io, self.pid, bound_ms);
        if (st != null) self.pid = 0;
        return st;
    }
};

fn freeFrames(gpa: std.mem.Allocator, frames: []OwnedFrame) void {
    for (frames) |*f| f.deinit();
    gpa.free(frames);
}

/// Portable raw fd write (Linux syscall / libc elsewhere).
fn rawWrite(fd: posix.fd_t, bytes: []const u8) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        return rc;
    }
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return error.WriteFailed;
    return @intCast(rc);
}

fn rawClose(fd: posix.fd_t) void {
    if (fd < 0) return;
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

// ── frame accessors ─────────────────────────────────────────────────────────

fn isResponse(f: Frame) bool {
    if (f != .object) return false;
    const ty = f.object.get("type") orelse return false;
    return ty == .string and std.mem.eql(u8, ty.string, "response");
}

fn isResponseId(f: Frame, id: i64) bool {
    if (!isResponse(f)) return false;
    const rid = f.object.get("id") orelse return false;
    return rid == .integer and rid.integer == id;
}

fn isNotificationMethod(f: Frame, method: []const u8) bool {
    if (f != .object) return false;
    const ty = f.object.get("type") orelse return false;
    if (ty != .string or !std.mem.eql(u8, ty.string, "notification")) return false;
    const m = f.object.get("method") orelse return false;
    return m == .string and std.mem.eql(u8, m.string, method);
}

fn objPath(f: Frame, comptime path: []const u8) ?Frame {
    var cur = f;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

fn strField(f: Frame, comptime path: []const u8) ?[]const u8 {
    const v = objPath(f, path) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn intField(f: Frame, comptime path: []const u8) ?i64 {
    const v = objPath(f, path) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

fn boolField(f: Frame, comptime path: []const u8) ?bool {
    const v = objPath(f, path) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}

fn containsField(f: Frame, comptime path: []const u8) bool {
    return objPath(f, path) != null;
}

fn idIsNull(f: Frame) bool {
    const v = f.object.get("id") orelse return false;
    return v == .null;
}

/// Spin up a client + mock with the standard rpc flags.
const MockHandle = struct { pid: posix.pid_t, port: u16 };

const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tmp: std.testing.TmpDir,
    mock: MockHandle,
    env: []const []const u8,
    client: RpcClient,

    fn start(gpa: std.mem.Allocator, io: Io, tool_call: bool, stall_ms: u64, want_ready: bool) !Session {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const mock = try startMock(io, tmp.dir, tool_call, stall_ms, want_ready);
        errdefer reap(io, mock.pid);
        const env = try makeEnvPairs(gpa, mock.port);
        errdefer gpa.free(env[1]);
        errdefer gpa.free(env);
        const client = try RpcClient.spawn(gpa, io, tmp.dir, env, &rpc_argv);
        return .{
            .gpa = gpa,
            .io = io,
            .tmp = tmp,
            .mock = mock,
            .env = env,
            .client = client,
        };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.gpa.free(self.env[1]);
        self.gpa.free(self.env);
        reap(self.io, self.mock.pid);
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// Wait for the `ready` handshake; returns the ready frame (freed by
    /// the caller's freeFrames on the SAME slice).
    fn handshake(self: *Session) ![]OwnedFrame {
        return self.client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isNotificationMethod(f, "ready");
            }
        }.pred);
    }
};

// ══════════════════════════════════════════════════════════════════════════
// Gates
// ══════════════════════════════════════════════════════════════════════════

const RunOut = struct {
    status: u32,
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
    return .{
        .status = switch (result.term) {
            .exited => |c| @as(u32, c),
            else => std.math.maxInt(u32),
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

test "gate01_rpc_mode_matrix_pipes_exit2_stdout_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const combos = [_][]const []const u8{
        &.{ "--rpc", "--json", "hi" },
        &.{ "--rpc", "--json-stream", "hi" },
        &.{ "--rpc", "--tui" },
        &.{ "--rpc", "--doctor" },
        &.{ "--rpc", "--verbose" },
        &.{ "--rpc", "positional prompt" },
    };
    for (combos) |tail| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var out = try runZagPipes(gpa, io, tmp.dir, tail);
        defer out.deinit(gpa);
        if (out.status == std.math.maxInt(u32)) return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 2), std.math.cast(u8, out.status).?);
        try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
    }
}

test "gate02_rpc_help_exit0_stdout_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--rpc", "--help" });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), std.math.cast(u8, out.status).?);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "--rpc") != null);
}

test "gate03_handshake_ready_first_frame_exact_fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    defer freeFrames(gpa, ready);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    const f = ready[0].value;
    try std.testing.expectEqualStrings(protocol_version, strField(f, "protocol_version").?);
    try std.testing.expectEqualStrings("notification", strField(f, "type").?);
    try std.testing.expectEqualStrings("ready", strField(f, "method").?);
    try std.testing.expectEqualStrings(protocol_version, strField(f, "params.protocol_version").?);
    try std.testing.expect(strField(f, "params.zag_version").?.len > 0);
    try std.testing.expectEqualStrings("ask", strField(f, "params.permission").?);
    try std.testing.expectEqualStrings("protect", strField(f, "params.shell_policy").?);
    try std.testing.expectEqual(false, boolField(f, "params.session.configured").?);
    try std.testing.expectEqual(@as(i64, 0), intField(f, "params.session.turns").?);
    try std.testing.expectEqual(false, boolField(f, "params.session.resumed").?);
}

test "gate04_prompt_round_trip_deltas_and_terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "hello rpc", .stream = true },
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var saw_delta = false;
    var terminal: ?Frame = null;
    for (frames) |f| {
        if (isNotificationMethod(f.value, "assistant_delta")) saw_delta = true;
        if (isResponseId(f.value, 1)) terminal = f.value;
    }
    try std.testing.expect(saw_delta); // default subscription + stream
    const t = terminal orelse return error.NoTerminal;
    try std.testing.expectEqual(true, boolField(t, "result.ok").?);
    try std.testing.expectEqualStrings("completed", strField(t, "result.stop_reason").?);
    try std.testing.expectEqual(@as(i64, 1), intField(t, "result.turns").?);
    const final_text = strField(t, "result.final_text") orelse "";
    try std.testing.expect(std.mem.indexOf(u8, final_text, "hello rpc") != null);
    try std.testing.expect(containsField(t, "result.usage.total_tokens"));
}

test "gate05_busy_second_prompt_session_busy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 3_000, true);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "first run", .stream = true },
    });
    try waitRequestReady(io, s.tmp.dir, 10_000); // in flight, stalled
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "prompt",
        .params = .{ .text = "second run", .stream = true },
    });
    const frames = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 2);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var busy: ?Frame = null;
    for (frames) |f| {
        if (isResponseId(f.value, 2)) busy = f.value;
    }
    const b = busy orelse return error.NoResponse;
    try std.testing.expectEqualStrings("session_busy", strField(b, "error.code").?);
    // In-flight run unaffected: cancel it and let it finish.
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 3),
        .method = "cancel",
    });
    const end = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, end);
    var first: ?Frame = null;
    for (end) |f| {
        if (isResponseId(f.value, 1)) first = f.value;
    }
    try std.testing.expectEqualStrings("cancelled", strField(first.?, "result.stop_reason").?);
}

test "gate06_steer_while_busy_control_applied_next_turn_echoes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1_500, true);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "initial", .stream = true },
    });
    try waitRequestReady(io, s.tmp.dir, 10_000);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "steer",
        .params = .{ .text = "steered instruction" },
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var saw_control = false;
    var final_text: []const u8 = "";
    for (frames) |f| {
        if (isNotificationMethod(f.value, "control_applied")) {
            if (std.mem.eql(u8, strField(f.value, "params.kind") orelse "", "steering")) saw_control = true;
        }
        if (isResponseId(f.value, 1)) final_text = strField(f.value, "result.final_text") orelse "";
    }
    try std.testing.expect(saw_control);
    try std.testing.expect(std.mem.indexOf(u8, final_text, "steered instruction") != null);
    var steer_ok = false;
    for (frames) |f| {
        if (isResponseId(f.value, 2)) steer_ok = true;
    }
    try std.testing.expect(steer_ok);
}

test "gate07_follow_up_while_busy_applied_at_would_complete" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1_500, true);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "initial", .stream = true },
    });
    try waitRequestReady(io, s.tmp.dir, 10_000);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "follow_up",
        .params = .{ .text = "follow-up question" },
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var saw_control = false;
    var final_text: []const u8 = "";
    for (frames) |f| {
        if (isNotificationMethod(f.value, "control_applied")) {
            if (std.mem.eql(u8, strField(f.value, "params.kind") orelse "", "follow_up")) saw_control = true;
        }
        if (isResponseId(f.value, 1)) final_text = strField(f.value, "result.final_text") orelse "";
    }
    try std.testing.expect(saw_control);
    try std.testing.expect(std.mem.indexOf(u8, final_text, "follow-up question") != null);
}

test "gate08_cancel_busy_prompt_cancelled_ok_true" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 2_000, true);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "long run", .stream = true },
    });
    try waitRequestReady(io, s.tmp.dir, 10_000);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "cancel",
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var cancelled: ?Frame = null;
    for (frames) |f| {
        if (isResponseId(f.value, 1)) cancelled = f.value;
    }
    const c = cancelled orelse return error.NoTerminal;
    // Cooperative honesty: std waits for the provider boundary (stall ends),
    // curl actively aborts. Both report the truthful terminal.
    try std.testing.expectEqualStrings("cancelled", strField(c, "result.stop_reason").?);
    try std.testing.expectEqual(true, boolField(c, "result.ok").?);
}

test "gate09_control_caps_message_too_long_and_queue_full" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);

    const too_long = "x" ** 4097;
    const big_line = try std.fmt.allocPrint(gpa, "{{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"steer\",\"params\":{{\"text\":\"{s}\"}}}}", .{too_long});
    defer gpa.free(big_line);
    try s.client.send(big_line);
    const f1 = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqualStrings("message_too_long", strField(f1[0].value, "error.code").?);

    // Fill the steering queue (cap 4), then the 5th steer → queue_full.
    // Responses are written in request order, so each fill's response is the
    // next `response` frame in the stream.
    var fills: i64 = 0;
    while (fills < 4) : (fills += 1) {
        try s.client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = 10 + fills,
            .method = "steer",
            .params = .{ .text = "queued steer" },
        });
        const fq = try s.client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isResponse(f);
            }
        }.pred);
        freeFrames(gpa, fq);
    }
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 14),
        .method = "steer",
        .params = .{ .text = "fifth steer" },
    });
    const f5 = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 14);
        }
    }.pred);
    defer freeFrames(gpa, f5);
    try std.testing.expectEqualStrings("queue_full", strField(f5[0].value, "error.code").?);
}

test "gate10_permission_ask_allow_runs_tool_deny_blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // ── allow path: tool runs, permission notification, file written ──────
    {
        var s = try Session.start(gpa, io, true, 0, false);
        defer s.deinit();
        const ready = try s.handshake();
        freeFrames(gpa, ready);
        try s.client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 1),
            .method = "prompt",
            .params = .{ .text = "write it", .stream = true },
        });
        var decision_sent = false;
        var frames: []OwnedFrame = &.{};
        var all: std.ArrayList(OwnedFrame) = .empty;
        defer {
            for (all.items) |*f| f.deinit();
            all.deinit(gpa);
        }
        var deadline: u64 = 0;
        while (deadline < 15_000) : (deadline += 100) {
            frames = try s.client.recvUntil(500, struct {
                fn pred(f: Frame) bool {
                    return isResponseId(f, 1);
                }
            }.pred);
            for (frames) |f| try all.append(gpa, f);
            gpa.free(frames);
            if (!decision_sent) {
                for (all.items) |f| {
                    if (isNotificationMethod(f.value, "permission_request")) {
                        const rid = intField(f.value, "params.request_id").?;
                        try s.client.sendJson(.{
                            .protocol_version = protocol_version,
                            .@"type" = "request",
                            .id = @as(i64, 100),
                            .method = "permission_decision",
                            .params = .{ .request_id = rid, .allowed = true, .remember = true },
                        });
                        decision_sent = true;
                    }
                }
            }
            var terminal: ?Frame = null;
            for (all.items) |f| {
                if (isResponseId(f.value, 1)) terminal = f.value;
            }
            if (terminal) |t| {
                try std.testing.expectEqualStrings("completed", strField(t, "result.stop_reason").?);
                var saw_perm_request = false;
                var saw_perm_notif = false;
                var saw_tool_start = false;
                var saw_tool_end = false;
                for (all.items) |g| {
                    if (isNotificationMethod(g.value, "permission_request")) saw_perm_request = true;
                    if (isNotificationMethod(g.value, "permission")) {
                        if (boolField(g.value, "params.allowed").?) saw_perm_notif = true;
                    }
                    if (isNotificationMethod(g.value, "tool_start")) saw_tool_start = true;
                    if (isNotificationMethod(g.value, "tool_end")) saw_tool_end = true;
                }
                try std.testing.expect(saw_perm_request);
                try std.testing.expect(saw_perm_notif);
                try std.testing.expect(saw_tool_start);
                try std.testing.expect(saw_tool_end);
                // Tool actually ran: file exists in the fixture cwd.
                const content = s.tmp.dir.readFileAlloc(io, "rpc_fixture_out.txt", gpa, .limited(1024)) catch null;
                if (content) |c| {
                    defer gpa.free(c);
                    try std.testing.expect(std.mem.indexOf(u8, c, "write it") != null);
                } else {
                    return error.ToolDidNotRun;
                }
                deadline = 99_999; // done
                break;
            }
        }
        if (deadline < 99_999) return error.NoTerminal;
    }
    // ── deny path: permission notification denied, tool body denied ───────
    {
        var s = try Session.start(gpa, io, true, 0, false);
        defer s.deinit();
        const ready = try s.handshake();
        freeFrames(gpa, ready);
        try s.client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 1),
            .method = "prompt",
            .params = .{ .text = "write denied", .stream = true },
        });
        var decision_sent = false;
        var frames: []OwnedFrame = &.{};
        var all2: std.ArrayList(OwnedFrame) = .empty;
        defer {
            for (all2.items) |*f| f.deinit();
            all2.deinit(gpa);
        }
        var deadline: u64 = 0;
        while (deadline < 15_000) : (deadline += 100) {
            frames = try s.client.recvUntil(500, struct {
                fn pred(f: Frame) bool {
                    return isResponseId(f, 1);
                }
            }.pred);
            for (frames) |f| try all2.append(gpa, f);
            gpa.free(frames);
            if (!decision_sent) {
                for (all2.items) |f| {
                    if (isNotificationMethod(f.value, "permission_request")) {
                        const rid = intField(f.value, "params.request_id").?;
                        try s.client.sendJson(.{
                            .protocol_version = protocol_version,
                            .@"type" = "request",
                            .id = @as(i64, 100),
                            .method = "permission_decision",
                            .params = .{ .request_id = rid, .allowed = false, .remember = false },
                        });
                        decision_sent = true;
                    }
                }
            }
            var terminal2: ?Frame = null;
            for (all2.items) |f| {
                if (isResponseId(f.value, 1)) terminal2 = f.value;
            }
            if (terminal2) |t| {
                try std.testing.expectEqualStrings("completed", strField(t, "result.stop_reason").?);
                var saw_denied_notif = false;
                var saw_denied_body = false;
                for (all2.items) |g| {
                    if (isNotificationMethod(g.value, "permission")) {
                        if (!boolField(g.value, "params.allowed").?) saw_denied_notif = true;
                    }
                    if (isNotificationMethod(g.value, "tool_end")) {
                        const body = strField(g.value, "params.body") orelse "";
                        if (std.mem.indexOf(u8, body, "permission denied") != null) saw_denied_body = true;
                    }
                }
                try std.testing.expect(saw_denied_notif);
                try std.testing.expect(saw_denied_body);
                deadline = 99_999;
                break;
            }
        }
        if (deadline < 99_999) return error.NoTerminal;
    }
}

test "gate11_cancel_pending_gate_resolves_deny_run_cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, true, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "gate me", .stream = true },
    });
    // Wait for the gate to be pending, then cancel (never allow on cancel).
    var saw_request = false;
    var frames: []OwnedFrame = &.{};
    defer freeFrames(gpa, frames);
    var deadline: u64 = 0;
    while (deadline < 10_000) : (deadline += 100) {
        freeFrames(gpa, frames);
        frames = try s.client.recvUntil(300, struct {
            fn pred(_: Frame) bool {
                return false;
            }
        }.pred);
        for (frames) |f| {
            if (isNotificationMethod(f.value, "permission_request")) saw_request = true;
        }
        if (saw_request) break;
    }
    try std.testing.expect(saw_request);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "cancel",
    });
    const end = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, end);
    var cancelled: ?Frame = null;
    var saw_denied = false;
    for (end) |f| {
        if (isResponseId(f.value, 1)) cancelled = f.value;
        if (isNotificationMethod(f.value, "permission") and !boolField(f.value, "params.allowed").?) saw_denied = true;
    }
    const c = cancelled orelse return error.NoTerminal;
    try std.testing.expectEqualStrings("cancelled", strField(c, "result.stop_reason").?);
    try std.testing.expectEqual(true, boolField(c, "result.ok").?);
    try std.testing.expect(saw_denied);
}

test "gate12_resume_same_path_and_across_restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session_path = ".zag/sessions/default.jsonl";
    var argv_s: [rpc_argv.len + 2][]const u8 = undefined;
    for (rpc_argv, 0..) |a, i| argv_s[i] = a;
    argv_s[rpc_argv.len] = "-s";
    argv_s[rpc_argv.len + 1] = session_path;
    var argv_c: [rpc_argv.len + 1][]const u8 = undefined;
    for (rpc_argv, 0..) |a, i| argv_c[i] = a;
    argv_c[rpc_argv.len] = "-c";

    // ── Part A: -s creates; resume same path; prompt; exit ─────────────────
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const mock = try startMock(io, tmp.dir, false, 0, false);
        defer reap(io, mock.pid);
        const env = try makeEnvPairs(gpa, mock.port);
        defer {
            gpa.free(env[1]);
            gpa.free(env);
        }
        var client = try RpcClient.spawn(gpa, io, tmp.dir, env, &argv_s);
        defer client.deinit();

        const ready = try client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isNotificationMethod(f, "ready");
            }
        }.pred);
        defer freeFrames(gpa, ready);
        try std.testing.expectEqual(false, boolField(ready[0].value, "params.session.resumed").?);

        try client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 1),
            .method = "prompt",
            .params = .{ .text = "durable turn", .stream = true },
        });
        const p1 = try client.recvUntil(15_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 1);
            }
        }.pred);
        freeFrames(gpa, p1);

        // resume onto the same path (open_or_create; old lease released first)
        try client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 2),
            .method = "resume",
            .params = .{ .path = session_path },
        });
        const r2 = try client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 2);
            }
        }.pred);
        defer freeFrames(gpa, r2);
        var resumed_resp: ?Frame = null;
        var session_notif = false;
        for (r2) |f| {
            if (isResponseId(f.value, 2)) resumed_resp = f.value;
            if (isNotificationMethod(f.value, "session")) session_notif = true;
        }
        const rr = resumed_resp orelse return error.NoResponse;
        try std.testing.expectEqual(true, boolField(rr, "result.ok").?);
        try std.testing.expectEqual(true, boolField(rr, "result.resumed").?);
        try std.testing.expect(session_notif);

        // prompt after resume works on the rebound session
        try client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 3),
            .method = "prompt",
            .params = .{ .text = "after resume", .stream = true },
        });
        const p3 = try client.recvUntil(15_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 3);
            }
        }.pred);
        defer freeFrames(gpa, p3);
        var after_resume: ?Frame = null;
        for (p3) |f| {
            if (isResponseId(f.value, 3)) after_resume = f.value;
        }
        const ar = after_resume orelse return error.NoTerminal;
        try std.testing.expectEqualStrings("completed", strField(ar, "result.stop_reason").?);

        try client.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 4),
            .method = "exit",
        });
        const e = try client.recvUntil(5_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 4);
            }
        }.pred);
        freeFrames(gpa, e);
        const st = client.waitExit(10_000) orelse return error.Timeout;
        try expectExited(st, 0);
    }

    // ── Part B: separate process --rpc -c resumes the same durable file ───
    {
        var tmp2 = std.testing.tmpDir(.{});
        defer tmp2.cleanup();
        const mock2 = try startMock(io, tmp2.dir, false, 0, false);
        defer reap(io, mock2.pid);
        const env2 = try makeEnvPairs(gpa, mock2.port);
        defer {
            gpa.free(env2[1]);
            gpa.free(env2);
        }
        // Create the durable file in THIS cwd with -s, then resume it with -c.
        var client_a = try RpcClient.spawn(gpa, io, tmp2.dir, env2, &argv_s);
        const ready_a = try client_a.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isNotificationMethod(f, "ready");
            }
        }.pred);
        defer freeFrames(gpa, ready_a);
        try client_a.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 1),
            .method = "prompt",
            .params = .{ .text = "before restart", .stream = true },
        });
        const p1 = try client_a.recvUntil(15_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 1);
            }
        }.pred);
        freeFrames(gpa, p1);
        try client_a.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 2),
            .method = "exit",
        });
        const e = try client_a.recvUntil(5_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 2);
            }
        }.pred);
        freeFrames(gpa, e);
        const st_a = client_a.waitExit(10_000) orelse return error.Timeout;
        try expectExited(st_a, 0);
        client_a.deinit();

        // -c resumes the durable file in THIS cwd.
        var client_b = try RpcClient.spawn(gpa, io, tmp2.dir, env2, &argv_c);
        defer client_b.deinit();
        const ready_b = try client_b.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isNotificationMethod(f, "ready");
            }
        }.pred);
        defer freeFrames(gpa, ready_b);
        try std.testing.expectEqual(true, boolField(ready_b[0].value, "params.session.configured").?);
        try std.testing.expectEqual(true, boolField(ready_b[0].value, "params.session.resumed").?);
        try std.testing.expect(intField(ready_b[0].value, "params.session.turns").? >= 1);

        try client_b.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 1),
            .method = "prompt",
            .params = .{ .text = "after restart", .stream = true },
        });
        const p2 = try client_b.recvUntil(15_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 1);
            }
        }.pred);
        defer freeFrames(gpa, p2);
        var after_restart: ?Frame = null;
        for (p2) |f| {
            if (isResponseId(f.value, 1)) after_restart = f.value;
        }
        const ar2 = after_restart orelse return error.NoTerminal;
        try std.testing.expectEqualStrings("completed", strField(ar2, "result.stop_reason").?);
        try std.testing.expect(intField(ar2, "result.turns").? >= 1);

        try client_b.sendJson(.{
            .protocol_version = protocol_version,
            .@"type" = "request",
            .id = @as(i64, 2),
            .method = "exit",
        });
        const e2 = try client_b.recvUntil(5_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 2);
            }
        }.pred);
        defer freeFrames(gpa, e2);
        const st_b = client_b.waitExit(10_000) orelse return error.Timeout;
        try expectExited(st_b, 0);
    }
}

test "gate13_exit_request_response_then_eof_exit0_session_saved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session_path = ".zag/sessions/rpc_exit_test.jsonl";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }
    var argv: [rpc_argv.len + 2][]const u8 = undefined;
    for (rpc_argv, 0..) |a, i| argv[i] = a;
    argv[rpc_argv.len] = "-s";
    argv[rpc_argv.len + 1] = session_path;
    var client = try RpcClient.spawn(gpa, io, tmp.dir, env, &argv);
    defer client.deinit();

    const ready = try client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isNotificationMethod(f, "ready");
        }
    }.pred);
    defer freeFrames(gpa, ready);
    try std.testing.expectEqual(true, boolField(ready[0].value, "params.session.configured").?);

    try client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "persist me", .stream = true },
    });
    const p1 = try client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, p1);

    try client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 2),
        .method = "exit",
    });
    const e = try client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 2);
        }
    }.pred);
    defer freeFrames(gpa, e);
    try std.testing.expectEqual(true, boolField(e[0].value, "result.ok").?);

    const st = client.waitExit(10_000) orelse return error.Timeout;
    try expectExited(st, 0);

    // Session file saved with turns: contains the user text + JSONL rows.
    const content = try tmp.dir.readFileAlloc(io, session_path, gpa, .limited(1024 * 1024));
    defer gpa.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "persist me") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"role\"") != null);
}

test "gate14_client_disconnect_busy_exit0_session_saved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session_path = ".zag/sessions/rpc_disconnect.jsonl";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 2_000, true);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }
    var argv: [rpc_argv.len + 2][]const u8 = undefined;
    for (rpc_argv, 0..) |a, i| argv[i] = a;
    argv[rpc_argv.len] = "-s";
    argv[rpc_argv.len + 1] = session_path;
    var client = try RpcClient.spawn(gpa, io, tmp.dir, env, &argv);
    defer client.deinit();

    const ready = try client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isNotificationMethod(f, "ready");
        }
    }.pred);
    defer freeFrames(gpa, ready);

    try client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "disconnect me", .stream = true },
    });
    try waitRequestReady(io, tmp.dir, 10_000);

    // Close stdin while busy → EOF → graceful shutdown (gate deny → cancel →
    // bounded join → save → exit 0).
    client.closeStdin();
    const st = client.waitExit(30_000) orelse return error.Timeout;
    try expectExited(st, 0);

    const content = tmp.dir.readFileAlloc(io, session_path, gpa, .limited(1024 * 1024)) catch null;
    if (content) |c| {
        defer gpa.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "disconnect me") != null);
    }
}

test "gate15_protocol_errors_continue_and_resync" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);

    // bad JSON → id:null invalid_arguments; server continues
    try s.client.send("{not json");
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponse(f) and containsField(f, "error");
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqualStrings("invalid_arguments", strField(f1[0].value, "error.code").?);
    try std.testing.expect(idIsNull(f1[0].value));

    // unknown method → echoed id + unknown_method
    try s.client.send("{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":7,\"method\":\"bogus\"}");
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 7);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expectEqualStrings("unknown_method", strField(f2[0].value, "error.code").?);

    // wrong protocol_version → unsupported_protocol
    try s.client.send("{\"protocol_version\":\"rpc-v9\",\"type\":\"request\",\"id\":8,\"method\":\"exit\"}");
    const f3 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponse(f) and containsField(f, "error");
        }
    }.pred);
    defer freeFrames(gpa, f3);
    try std.testing.expectEqualStrings("unsupported_protocol", strField(f3[0].value, "error.code").?);

    // oversized frame (4 MiB + 1) → invalid_arguments id:null + resync
    const big = "x" ** (framing.frame_cap + 1);
    var off: usize = 0;
    while (off < big.len) {
        const n = @min(65536, big.len - off);
        const wrote = try rawWrite(s.client.stdin_fd, big[off .. off + n]);
        off += wrote;
    }
    try s.client.send("\n");
    const f4 = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponse(f) and containsField(f, "error");
        }
    }.pred);
    defer freeFrames(gpa, f4);
    try std.testing.expectEqualStrings("invalid_arguments", strField(f4[0].value, "error.code").?);
    try std.testing.expect(idIsNull(f4[0].value));

    // server still works after the resync
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 9),
        .method = "prompt",
        .params = .{ .text = "still alive", .stream = true },
    });
    const f5 = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 9);
        }
    }.pred);
    defer freeFrames(gpa, f5);
    var still_alive: ?Frame = null;
    for (f5) |f| {
        if (isResponseId(f.value, 9)) still_alive = f.value;
    }
    const sa = still_alive orelse return error.NoTerminal;
    try std.testing.expectEqualStrings("completed", strField(sa, "result.stop_reason").?);
}

test "gate16_redaction_secret_never_in_frames" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, true, 0, false);
    defer s.deinit();
    const ready = try s.handshake();
    freeFrames(gpa, ready);
    try s.client.sendJson(.{
        .protocol_version = protocol_version,
        .@"type" = "request",
        .id = @as(i64, 1),
        .method = "prompt",
        .params = .{ .text = "embed the secret " ++ secret_fixture ++ " in the file", .stream = true },
    });
    var decision_sent = false;
    var frames: []OwnedFrame = &.{};
    defer freeFrames(gpa, frames);
    var deadline: u64 = 0;
    var saw_request = false;
    while (deadline < 15_000) : (deadline += 100) {
        freeFrames(gpa, frames);
        frames = try s.client.recvUntil(500, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 1);
            }
        }.pred);
        if (!decision_sent) {
            for (frames) |f| {
                if (isNotificationMethod(f.value, "permission_request")) {
                    const rid = intField(f.value, "params.request_id").?;
                    try s.client.sendJson(.{
                        .protocol_version = protocol_version,
                        .@"type" = "request",
                        .id = @as(i64, 100),
                        .method = "permission_decision",
                        .params = .{ .request_id = rid, .allowed = true, .remember = false },
                    });
                    decision_sent = true;
                }
            }
        }
        for (frames) |f| {
            if (isNotificationMethod(f.value, "permission_request")) saw_request = true;
            if (isResponseId(f.value, 1)) deadline = 99_999;
        }
        if (deadline >= 99_999) break;
    }
    try std.testing.expect(saw_request);
    // The secret was in the prompt, in the mock-echoed tool args, and in the
    // echoed final text — it must never appear on the wire.
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    for (frames) |f| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.write(f.value);
        try blob.appendSlice(gpa, out.written());
    }
    try std.testing.expect(std.mem.indexOf(u8, blob.items, secret_fixture) == null);
    try assertNoSecretOrPath(blob.items);
}

test "gate19_ownership_no_core_or_tui_imports_in_rpc_files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_][]const u8{
        "packages/zag-cli/src/rpc/framing.zig",
        "packages/zag-cli/src/rpc/protocol.zig",
        "packages/zag-cli/src/rpc/server.zig",
        "packages/zag-cli/src/rpc_entry.zig",
    };
    for (files) |path| {
        const content = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-agent-core\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-tui\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "zag_tui") == null);
    }
}

// ── PTY gates (rpc-v1-001 #17/#18; tui fixture style) ───────────────────────

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
    pid: posix.pid_t,
    acc: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn open(gpa: std.mem.Allocator) !PtySession {
        var master: c_int = -1;
        var slave: c_int = -1;
        var wsz: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master, &slave, null, null, &wsz) != 0) return error.OpenPtyFailed;
        const fl = std.c.fcntl(master, std.c.F.GETFL);
        if (fl >= 0) _ = std.c.fcntl(master, std.c.F.SETFL, fl | 0x0004); // O_NONBLOCK mac
        return .{ .master = master, .slave = slave, .pid = 0, .gpa = gpa };
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
        for (rpc_argv) |a| try args_z.append(self.gpa, try self.gpa.dupeZ(u8, a));

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
        _ = std.c.close(self.slave);
        self.slave = -1;
    }

    fn deinit(self: *PtySession, io: Io) void {
        if (self.pid > 0) reap(io, self.pid);
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
            if (self.pid > 0) {
                if (waitBounded(io, self.pid, 0) != null) return std.mem.indexOf(u8, self.acc.items, marker) != null;
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
        const pid = self.pid;
        if (pid <= 0) return null;
        const st = waitBounded(io, pid, bound_ms);
        if (st != null) self.pid = 0;
        return st;
    }
};

fn tmpCwdAbs(io: Io, tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    return try std.heap.page_allocator.dupe(u8, path_buf[0..n]);
}

test "gate17_pty_stdout_protocol_only_handshake_exit0" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 0, false);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }
    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);

    const found = try pty.waitMarker(io, "\"method\":\"ready\"", 12_000);
    try std.testing.expect(found);
    // No ANSI escapes / alt-screen on the wire (protocol-only stdout).
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "state:idle") == null);

    // Send a prompt over the PTY: response arrives as protocol.
    pty.writeAll("{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"prompt\",\"params\":{\"text\":\"pty hello\",\"stream\":true}}\n");
    const resp = try pty.waitMarker(io, "\"id\":1", 15_000);
    try std.testing.expect(resp);

    // Clean cooperative exit.
    pty.writeAll("{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":2,\"method\":\"exit\"}\n");
    const st = pty.waitExit(io, 10_000) orelse {
        pty.deinit(io);
        return error.Timeout;
    };
    try expectExited(st, 0);
    pty.deinit(io);
}

test "gate18_pty_busy_first_sigint_graceful_0_second_130_std" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 3_000, true);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }
    const cwd_abs = try tmpCwdAbs(io, &tmp);
    defer std.heap.page_allocator.free(cwd_abs);

    var pty = try PtySession.open(gpa);
    errdefer pty.deinit(io);
    try pty.spawnZag(io, cwd_abs, env);
    try std.testing.expect(try pty.waitMarker(io, "\"method\":\"ready\"", 12_000));

    pty.writeAll("{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"prompt\",\"params\":{\"text\":\"sigint busy\",\"stream\":true}}\n");
    try waitRequestReady(io, tmp.dir, 10_000);

    const pid = pty.pid;
    try std.posix.kill(pid, std.posix.SIG.INT);

    if (http_backend == .std) {
        // Second SIGINT while the join is in progress → hard exit 130
        // (the Guard's pending state is never acknowledged during shutdown).
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .real) catch {};
        try std.posix.kill(pid, std.posix.SIG.INT);
        const st = pty.waitExit(io, 10_000) orelse {
            pty.deinit(io);
            return error.Timeout;
        };
        try expectExited(st, 130);
    } else {
        // curl: the first SIGINT actively aborts the transfer; graceful exit 0.
        const st = pty.waitExit(io, 15_000) orelse {
            pty.deinit(io);
            return error.Timeout;
        };
        try expectExited(st, 0);
    }
    pty.deinit(io);
}
