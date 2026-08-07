//! Process-level acp-v1-001 fixture (permanent, automated).
//!
//! Root `build.zig` injects the built `zag` binary path via
//! `acp_fixture_options.zag_bin`, the mock-server binary via
//! `acp_fixture_options.headless_mock_bin`, and the HTTP backend tag. It runs
//! this file as a test artifact under `zig build test` (std and curl backends
//! rebuild `zag` accordingly).
//!
//! Spawns the real `zag --acp` binary under an isolated cwd + synthetic env
//! (mock provider over loopback, no real credentials, no network egress) and
//! drives the JSON-RPC 2.0 wire over pipes / PTY, mirroring the rpc/TUI PTY
//! gates. The fixture is a FAKE EDITOR speaking ACP v1 (acp.md §5-§6).
//! 26 gate classes (acp-001 §verification):
//!
//!   1  mode matrix (--acp + --rpc/--json/--json-stream/--tui/--doctor/
//!      --verbose/positional prompt → exit 2, empty stdout)
//!   2  --acp --help → exit 0, empty stdout (help on stderr)
//!   3  handshake: initialize → protocolVersion 1 + frozen capabilities
//!   4  protocol errors: pre-initialize request → -32600; unknown method →
//!      -32601; unknown notification ignored, server continues
//!   5  session/new → sess_1; repeated → same id (idempotent)
//!   6  session/new validation: cwd mismatch / mcpServers / prompt → -32602
//!   7  prompt round-trip: agent_message_chunk + exactly one end_turn response
//!   8  content blocks: text + resource flattened; image → -32602
//!   9  busy: second prompt while in flight → -32001; run unaffected
//!  10  cancel: session/cancel while busy → cancelled (cooperative; curl
//!      active-cancel)
//!  11  steer while busy → queued + interjectionId echoed; next turn echoes
//!  12  control caps: steer > 4096 B → -32003; 5th steer → -32002
//!  13  permission allow_once: request_permission (adapter id) → tool runs,
//!      tool_call/tool_call_update frames
//!  14  permission deny: reject_once / reject_always / outcome cancelled →
//!      denied tool body
//!  15  permission remember: allow_always → second identical write re-asks
//!      NOT
//!  16  cancel while permission pending → run ends cancelled
//!  17  session/list → single row with process cwd
//!  18  extensions: authentication/getUser stub; ping → {}
//!  19  JSON-RPC errors: malformed → -32700 (id null); missing jsonrpc →
//!      -32600; string id echoed verbatim
//!  20  framing: line > 4 MiB → -32700 + resync; server continues
//!  21  redaction: fixture secret never appears in any frame (incl. the
//!      permission request fields)
//!  22  PTY: protocol-only stdout (no ANSI), handshake works, EOF → exit 0
//!  23  PTY signals: busy + first SIGINT → graceful 0; second → 130 (std)
//!  24  disconnect: close stdin while busy → exit 0, durable session saved
//!  25  startup failure: no provider config → exit 30, empty stdout
//!  26  ownership: acp files import no zag-agent-core / zag-tui
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
const fixture_opts = @import("acp_fixture_options");
const framing = @import("rpc/framing.zig");

const zag_bin: []const u8 = fixture_opts.zag_bin;
const mock_bin: []const u8 = fixture_opts.headless_mock_bin;
const http_backend = fixture_opts.http_backend;

const secret_fixture = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
const port_file_name = "acp_mock.port";
const ready_file_name = "acp_mock.ready";
const tool_file_name = "acp_fixture_out.txt";

const acp_argv = [_][]const u8{ "--acp", "--no-project", "--no-skills", "--no-prompt-templates" };

const pty_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

// ── process helpers (rpc fixture style) ─────────────────────────────────────

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

const MockHandle = struct { pid: posix.pid_t, port: u16 };

/// Start the headless mock (acp mode: echo + optional tool-call + stall).
fn startMock(
    io: Io,
    cwd: Io.Dir,
    tool_call: bool,
    tool_call_count: usize,
    tool_call_every: usize,
    stall_ms: u64,
    want_ready: bool,
) !MockHandle {
    const abs = try absPath(io, mock_bin);
    defer std.heap.page_allocator.free(abs);
    const stall_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{stall_ms});
    defer std.heap.page_allocator.free(stall_str);
    const count_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{tool_call_count});
    defer std.heap.page_allocator.free(count_str);
    const every_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{tool_call_every});
    defer std.heap.page_allocator.free(every_str);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, abs);
    try argv.append(std.heap.page_allocator, "--port-file");
    try argv.append(std.heap.page_allocator, port_file_name);
    try argv.append(std.heap.page_allocator, "--max-requests");
    try argv.append(std.heap.page_allocator, "0");
    try argv.append(std.heap.page_allocator, "--echo");
    if (tool_call) {
        try argv.append(std.heap.page_allocator, "--tool-call");
        try argv.append(std.heap.page_allocator, "--tool-call-count");
        try argv.append(std.heap.page_allocator, count_str);
        if (tool_call_every > 0) {
            try argv.append(std.heap.page_allocator, "--tool-call-every");
            try argv.append(std.heap.page_allocator, every_str);
        }
        try argv.append(std.heap.page_allocator, "--tool-path");
        try argv.append(std.heap.page_allocator, tool_file_name);
    }
    // Per-connection diagnostics (additive mock option; the file lives in the
    // fixture cwd and is cleaned with the tmp dir).
    try argv.append(std.heap.page_allocator, "--log-file");
    try argv.append(std.heap.page_allocator, "acp_mock.log");
    if (stall_ms > 0) {
        try argv.append(std.heap.page_allocator, "--stall-ms");
        try argv.append(std.heap.page_allocator, stall_str);
    }
    if (want_ready) {
        try argv.append(std.heap.page_allocator, "--ready-file");
        try argv.append(std.heap.page_allocator, ready_file_name);
    }

    // Mock stderr → file in the fixture cwd (diagnostics; the accept loop's
    // failure mode is otherwise invisible).
    var err_file: Io.File = cwd.createFile(io, "acp_mock.err", .{}) catch return error.SpawnFailed;
    err_file.close(io);
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = try cwd.openFile(io, "acp_mock.err", .{ .mode = .write_only }) },
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

// ── ACP client over pipes (fake editor) ─────────────────────────────────────

const Frame = std.json.Value;
const OwnedFrame = std.json.Parsed(Frame);

const AcpClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    pid: posix.pid_t,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    stderr_fd: posix.fd_t,
    reader: framing.FrameReader,
    /// Frames read but not yet consumed by the current wait.
    pending: std.ArrayList(OwnedFrame) = .empty,

    fn spawn(gpa: std.mem.Allocator, io: Io, cwd: Io.Dir, env_pairs: []const []const u8, argv_tail: []const []const u8) !AcpClient {
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
            .stderr_fd = child.stderr.?.handle,
            .reader = framing.FrameReader.init(gpa, child.stdout.?.handle),
        };
    }

    fn deinit(self: *AcpClient) void {
        if (self.pid > 0) reap(self.io, self.pid);
        for (self.pending.items) |*f| f.deinit();
        self.pending.deinit(self.gpa);
        self.reader.deinit();
        self.* = undefined;
    }

    /// Write one frame line to the child's stdin.
    fn send(self: *AcpClient, line: []const u8) !void {
        var off: usize = 0;
        while (off < line.len) {
            const n = try rawWrite(self.stdin_fd, line[off..]);
            off += n;
        }
        _ = try rawWrite(self.stdin_fd, "\n");
    }

    fn sendJson(self: *AcpClient, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.write(value);
        try self.send(out.written());
    }

    fn closeStdin(self: *AcpClient) void {
        rawClose(self.stdin_fd);
        self.stdin_fd = -1;
    }

    /// Pull available stdout bytes into the reader (bounded poll).
    fn pump(self: *AcpClient, bound_ms: u64) !bool {
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
    fn recvUntil(self: *AcpClient, bound_ms: u64, comptime pred: fn (Frame) bool) ![]OwnedFrame {
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

    fn waitExit(self: *AcpClient, bound_ms: u64) ?u32 {
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

// ── frame accessors (JSON-RPC 2.0) ─────────────────────────────────────────

/// A response: jsonrpc 2.0, an id, no method, and result/error.
fn isJsonRpcResponse(f: Frame) bool {
    if (f != .object) return false;
    if (f.object.get("method") != null) return false;
    const jr = f.object.get("jsonrpc") orelse return false;
    if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) return false;
    return f.object.get("id") != null;
}

fn isResponseId(f: Frame, id: i64) bool {
    if (!isJsonRpcResponse(f)) return false;
    const rid = f.object.get("id") orelse return false;
    return rid == .integer and rid.integer == id;
}

fn isResponseIdStr(f: Frame, id: []const u8) bool {
    if (!isJsonRpcResponse(f)) return false;
    const rid = f.object.get("id") orelse return false;
    return rid == .string and std.mem.eql(u8, rid.string, id);
}

/// A notification: jsonrpc 2.0, a method, no id.
fn isNotificationMethod(f: Frame, method: []const u8) bool {
    if (f != .object) return false;
    const m = f.object.get("method") orelse return false;
    if (m != .string or !std.mem.eql(u8, m.string, method)) return false;
    const id = f.object.get("id") orelse return true;
    return id == .null;
}

/// An agent→client request: jsonrpc 2.0, a method, an id.
fn isRequestMethod(f: Frame, method: []const u8) bool {
    if (f != .object) return false;
    const m = f.object.get("method") orelse return false;
    if (m != .string or !std.mem.eql(u8, m.string, method)) return false;
    const id = f.object.get("id") orelse return false;
    return id == .integer or id == .string;
}

fn isErrorResponse(f: Frame, code: i64) bool {
    if (!isJsonRpcResponse(f)) return false;
    const ec = f.object.get("error") orelse return false;
    if (ec != .object) return false;
    const c = ec.object.get("code") orelse return false;
    return c == .integer and c.integer == code;
}

fn objPath(f: Frame, comptime path: []const u8) ?Frame {
    var cur = f;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |key| {
        if (cur == .array) {
            const idx = std.fmt.parseInt(usize, key, 10) catch return null;
            if (idx >= cur.array.items.len) return null;
            cur = cur.array.items[idx];
            continue;
        }
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

fn tmpCwdAbs(io: Io, tmp: *std.testing.TmpDir) ![]u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    return try std.heap.page_allocator.dupe(u8, path_buf[0..n]);
}

/// Spin up a client + mock with the standard acp flags. `cwd_abs` is the
/// canonical fixture working directory (used for session/new + session/list).
const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tmp: std.testing.TmpDir,
    mock: MockHandle,
    env: []const []const u8,
    client: AcpClient,
    cwd_abs: []u8,

    fn start(
        gpa: std.mem.Allocator,
        io: Io,
        tool_call: bool,
        tool_call_count: usize,
        tool_call_every: usize,
        stall_ms: u64,
        want_ready: bool,
    ) !Session {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const mock = try startMock(io, tmp.dir, tool_call, tool_call_count, tool_call_every, stall_ms, want_ready);
        errdefer reap(io, mock.pid);
        const env = try makeEnvPairs(gpa, mock.port);
        errdefer gpa.free(env[1]);
        errdefer gpa.free(env);
        var client = try AcpClient.spawn(gpa, io, tmp.dir, env, &acp_argv);
        errdefer client.deinit();
        const cwd_abs = try tmpCwdAbs(io, &tmp);
        errdefer std.heap.page_allocator.free(cwd_abs);
        return .{
            .gpa = gpa,
            .io = io,
            .tmp = tmp,
            .mock = mock,
            .env = env,
            .client = client,
            .cwd_abs = cwd_abs,
        };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.gpa.free(self.env[1]);
        self.gpa.free(self.env);
        std.heap.page_allocator.free(self.cwd_abs);
        reap(self.io, self.mock.pid);
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// initialize (id 1) → session/new with the process cwd (id 2).
    /// Returns the initialize response frames (freed by the caller).
    fn handshake(self: *Session) ![]OwnedFrame {
        try self.client.sendJson(.{
            .jsonrpc = "2.0",
            .id = @as(i64, 1),
            .method = "initialize",
            .params = .{ .protocolVersion = @as(i64, 1) },
        });
        const init_resp = try self.client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 1);
            }
        }.pred);
        try self.client.sendJson(.{
            .jsonrpc = "2.0",
            .id = @as(i64, 2),
            .method = "session/new",
            .params = .{ .cwd = self.cwd_abs },
        });
        const new_resp = try self.client.recvUntil(10_000, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 2);
            }
        }.pred);
        freeFrames(self.gpa, new_resp);
        return init_resp;
    }

    /// Send one session/prompt with the given id and text (no waiting).
    fn sendPrompt(self: *Session, id: i64, text: []const u8) !void {
        try self.client.sendJson(.{
            .jsonrpc = "2.0",
            .id = id,
            .method = "session/prompt",
            .params = .{
                .sessionId = "sess_1",
                .prompt = &.{.{ .type = "text", .text = text }},
            },
        });
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

test "gate01_acp_mode_matrix_pipes_exit2_stdout_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const combos = [_][]const []const u8{
        &.{ "--acp", "--rpc" },
        &.{ "--acp", "--json", "hi" },
        &.{ "--acp", "--json-stream", "hi" },
        &.{ "--acp", "--tui" },
        &.{ "--acp", "--doctor" },
        &.{ "--acp", "--verbose" },
        &.{ "--acp", "positional prompt" },
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

test "gate02_acp_help_exit0_stdout_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{ "--acp", "--help" });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), std.math.cast(u8, out.status).?);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "--acp") != null);
}

test "gate03_handshake_initialize_frozen_capabilities" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    defer freeFrames(gpa, init_resp);
    try std.testing.expectEqual(@as(usize, 1), init_resp.len);
    const f = init_resp[0].value;
    try std.testing.expectEqual(@as(i64, 1), intField(f, "id").?);
    try std.testing.expectEqual(@as(i64, 1), intField(f, "result.protocolVersion").?);
    try std.testing.expect(containsField(f, "result.agentCapabilities.sessionCapabilities.list"));
    try std.testing.expect(!containsField(f, "result.agentCapabilities.loadSession"));
    try std.testing.expect(!containsField(f, "result.agentCapabilities.mcpCapabilities"));
    try std.testing.expectEqualStrings("zag", strField(f, "result.agentInfo.name").?);
    try std.testing.expectEqualStrings("Zag", strField(f, "result.agentInfo.title").?);
    try std.testing.expect(strField(f, "result.agentInfo.version").?.len > 0);
    const auth = objPath(f, "result.authMethods") orelse return error.NoAuthMethods;
    try std.testing.expect(auth == .array);
    try std.testing.expectEqual(@as(usize, 0), auth.array.items.len);
}

test "gate04_protocol_errors_preinit_unknown_ignored_notification" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();

    // Request before initialize → -32600 with the echoed id.
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 7), .method = "ping" });
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32600);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqual(@as(i64, 7), intField(f1[0].value, "id").?);
    try std.testing.expectEqualStrings("not initialized", strField(f1[0].value, "error.message").?);

    // Initialize, then unknown method → -32601 (id echoed).
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 1), .method = "initialize", .params = .{ .protocolVersion = @as(i64, 1) } });
    const init_resp = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, init_resp);
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 8), .method = "frobnicate" });
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32601);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expectEqual(@as(i64, 8), intField(f2[0].value, "id").?);

    // Unknown notification → ignored; the server continues (ping round trip).
    try s.client.sendJson(.{ .jsonrpc = "2.0", .method = "bogus_notif", .params = .{} });
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 9), .method = "ping" });
    const f3 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 9);
        }
    }.pred);
    defer freeFrames(gpa, f3);
    try std.testing.expectEqual(@as(usize, 1), f3.len); // only the ping response
    try std.testing.expect(containsField(f3[0].value, "result"));
}

test "gate05_session_new_idempotent_sess_1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 5),
        .method = "session/new",
        .params = .{ .cwd = s.cwd_abs },
    });
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 5);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqualStrings("sess_1", strField(f1[0].value, "result.sessionId").?);

    // Repeated call → same id (idempotent, acp.md §7).
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 6),
        .method = "session/new",
        .params = .{ .cwd = s.cwd_abs },
    });
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 6);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expectEqualStrings("sess_1", strField(f2[0].value, "result.sessionId").?);
}

test "gate06_session_new_validation_cwd_mcp_prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // cwd ≠ process cwd → -32602 (canonicalized comparison).
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 5),
        .method = "session/new",
        .params = .{ .cwd = "/" },
    });
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32602);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqual(@as(i64, 5), intField(f1[0].value, "id").?);

    // Non-empty mcpServers → -32602.
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 6),
        .method = "session/new",
        .params = .{ .cwd = s.cwd_abs, .mcpServers = &.{.{ .url = "http://x" }} },
    });
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32602);
        }
    }.pred);
    defer freeFrames(gpa, f2);

    // prompt present → -32602 (initial prompt unsupported).
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 7),
        .method = "session/new",
        .params = .{ .cwd = s.cwd_abs, .prompt = &.{.{ .type = "text", .text = "hi" }} },
    });
    const f3 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32602);
        }
    }.pred);
    defer freeFrames(gpa, f3);

    // Server still serves the startup session afterwards.
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 8),
        .method = "session/new",
        .params = .{ .cwd = s.cwd_abs },
    });
    const f4 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 8);
        }
    }.pred);
    defer freeFrames(gpa, f4);
    try std.testing.expectEqualStrings("sess_1", strField(f4[0].value, "result.sessionId").?);
}

test "gate07_prompt_round_trip_chunks_and_single_response" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "hello acp");
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var saw_chunk = false;
    var response_count: usize = 0;
    var terminal: ?Frame = null;
    for (frames) |f| {
        if (isNotificationMethod(f.value, "session/update")) {
            if (std.mem.eql(u8, strField(f.value, "params.update.sessionUpdate") orelse "", "agent_message_chunk")) saw_chunk = true;
        }
        if (isResponseId(f.value, 3)) {
            response_count += 1;
            terminal = f.value;
        }
    }
    try std.testing.expect(saw_chunk);
    try std.testing.expectEqual(@as(usize, 1), response_count); // exactly one response
    const t = terminal orelse return error.NoTerminal;
    try std.testing.expectEqualStrings("end_turn", strField(t, "result.stopReason").?);
    try std.testing.expect(containsField(t, "result"));
    try std.testing.expect(!containsField(t, "error"));
    // The echoed prompt text reached the model (echo mock).
    var chunk_contains = false;
    for (frames) |f| {
        if (isNotificationMethod(f.value, "session/update")) {
            const text = strField(f.value, "params.update.content.text") orelse "";
            if (std.mem.indexOf(u8, text, "hello acp") != null) chunk_contains = true;
        }
    }
    try std.testing.expect(chunk_contains);
}

test "gate08_content_blocks_text_resource_flatten_image_reject" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // text blocks concatenated.
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 3),
        .method = "session/prompt",
        .params = .{
            .sessionId = "sess_1",
            .prompt = &.{
                .{ .type = "text", .text = "alpha" },
                .{ .type = "text", .text = "beta" },
            },
        },
    });
    const f1 = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    var saw_alpha_beta = false;
    for (f1) |f| {
        if (isNotificationMethod(f.value, "session/update")) {
            const text = strField(f.value, "params.update.content.text") orelse "";
            if (std.mem.indexOf(u8, text, "alphabeta") != null) saw_alpha_beta = true;
        }
    }
    try std.testing.expect(saw_alpha_beta);

    // resource-with-inline-text flattened (text field + contents array).
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 4),
        .method = "session/prompt",
        .params = .{
            .sessionId = "sess_1",
            .prompt = &.{
                .{ .type = "resource", .resource = .{ .uri = "u1", .text = "gamma" } },
                .{ .type = "resource", .resource = .{ .uri = "u2", .contents = &.{.{ .type = "text", .text = "delta" }} } },
            },
        },
    });
    const f2 = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 4);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    var saw_gamma_delta = false;
    for (f2) |f| {
        if (isNotificationMethod(f.value, "session/update")) {
            const text = strField(f.value, "params.update.content.text") orelse "";
            if (std.mem.indexOf(u8, text, "gammadelta") != null) saw_gamma_delta = true;
        }
    }
    try std.testing.expect(saw_gamma_delta);

    // image block → -32602 (unsupported content block).
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 5),
        .method = "session/prompt",
        .params = .{
            .sessionId = "sess_1",
            .prompt = &.{.{ .type = "image", .image = .{} }},
        },
    });
    const f3 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32602);
        }
    }.pred);
    defer freeFrames(gpa, f3);
    try std.testing.expectEqual(@as(i64, 5), intField(f3[0].value, "id").?);
}

test "gate09_busy_second_prompt_minus32001_run_unaffected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 3_000, true);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "first run");
    try waitRequestReady(io, s.tmp.dir, 10_000); // in flight, stalled
    try s.sendPrompt(4, "second run");
    const frames = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32001);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    try std.testing.expectEqual(@as(i64, 4), intField(frames[0].value, "id").?);

    // In-flight run unaffected: cancel it and let it finish.
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .method = "session/cancel",
        .params = .{ .sessionId = "sess_1" },
    });
    const end = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, end);
    var first: ?Frame = null;
    for (end) |f| {
        if (isResponseId(f.value, 3)) first = f.value;
    }
    try std.testing.expectEqualStrings("cancelled", strField(first.?, "result.stopReason").?);
}

test "gate10_cancel_busy_prompt_cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 2_000, true);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "long run");
    try waitRequestReady(io, s.tmp.dir, 10_000);
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .method = "session/cancel",
        .params = .{ .sessionId = "sess_1" },
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    var cancelled: ?Frame = null;
    for (frames) |f| {
        if (isResponseId(f.value, 3)) cancelled = f.value;
    }
    const c = cancelled orelse return error.NoTerminal;
    // Cooperative honesty: std waits for the provider boundary (stall ends),
    // curl actively aborts. Both report the truthful terminal.
    try std.testing.expectEqualStrings("cancelled", strField(c, "result.stopReason").?);
}

test "gate11_steer_while_busy_queued_echoed_next_turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 1_500, true);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "initial");
    try waitRequestReady(io, s.tmp.dir, 10_000);
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 4),
        .method = "session/steer",
        .params = .{ .sessionId = "sess_1", .text = "steered instruction", .interjectionId = "ij-1" },
    });
    const frames = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    // Steer response: queued + interjectionId echoed.
    var steer_ok = false;
    var steer_text_seen = false;
    for (frames) |f| {
        if (isResponseId(f.value, 4)) {
            if (std.mem.eql(u8, strField(f.value, "result.status") orelse "", "queued") and
                std.mem.eql(u8, strField(f.value, "result.interjectionId") orelse "", "ij-1")) steer_ok = true;
        }
        if (isNotificationMethod(f.value, "session/update")) {
            const text = strField(f.value, "params.update.content.text") orelse "";
            if (std.mem.indexOf(u8, text, "steered instruction") != null) steer_text_seen = true;
        }
    }
    try std.testing.expect(steer_ok);
    try std.testing.expect(steer_text_seen);
    var terminal: ?Frame = null;
    for (frames) |f| {
        if (isResponseId(f.value, 3)) terminal = f.value;
    }
    try std.testing.expectEqualStrings("end_turn", strField((terminal orelse return error.NoTerminal), "result.stopReason").?);
}

test "gate12_control_caps_steer_too_long_and_queue_full" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // steer > 4096 B → -32003 (wire-enforced before the queue).
    const too_long = "x" ** 4097;
    const big_line = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/steer\",\"params\":{{\"sessionId\":\"sess_1\",\"text\":\"{s}\"}}}}", .{too_long});
    defer gpa.free(big_line);
    try s.client.send(big_line);
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32003);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expectEqual(@as(i64, 1), intField(f1[0].value, "id").?);

    // Fill the steering queue (cap 4), then the 5th steer → -32002.
    var fills: i64 = 0;
    while (fills < 4) : (fills += 1) {
        try s.client.sendJson(.{
            .jsonrpc = "2.0",
            .id = 10 + fills,
            .method = "session/steer",
            .params = .{ .sessionId = "sess_1", .text = "queued steer" },
        });
        const fq = try s.client.recvUntil(5_000, struct {
            fn pred(f: Frame) bool {
                return isJsonRpcResponse(f);
            }
        }.pred);
        freeFrames(gpa, fq);
    }
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 14),
        .method = "session/steer",
        .params = .{ .sessionId = "sess_1", .text = "fifth steer" },
    });
    const f5 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32002);
        }
    }.pred);
    defer freeFrames(gpa, f5);
    try std.testing.expectEqual(@as(i64, 14), intField(f5[0].value, "id").?);
}

test "gate13_permission_allow_once_tool_runs_frames_emitted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, true, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "write it");
    var decision_sent = false;
    var frames: []OwnedFrame = &.{};
    var all: std.ArrayList(OwnedFrame) = .empty;
    defer {
        for (all.items) |*f| f.deinit();
        all.deinit(gpa);
    }
    var deadline: u64 = 0;
    var perm_rid: i64 = 0;
    while (deadline < 15_000) : (deadline += 100) {
        frames = try s.client.recvUntil(500, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 3);
            }
        }.pred);
        for (frames) |f| try all.append(gpa, f);
        gpa.free(frames);
        if (!decision_sent) {
            for (all.items) |f| {
                if (isRequestMethod(f.value, "session/request_permission")) {
                    // The adapter's own integer id (acp.md §9).
                    perm_rid = intField(f.value, "id") orelse return error.NoPermissionId;
                    try std.testing.expect(perm_rid > 0);
                    // Frozen option set.
                    const opts = objPath(f.value, "params.options") orelse return error.NoOptions;
                    try std.testing.expect(opts == .array);
                    try std.testing.expectEqual(@as(usize, 4), opts.array.items.len);
                    const opt_ids = [_][]const u8{ "allow_once", "allow_always", "reject_once", "reject_always" };
                    for (opt_ids, 0..) |want, i| {
                        const o = opts.array.items[i];
                        try std.testing.expectEqualStrings(want, strField(o, "id").?);
                        try std.testing.expectEqualStrings(want, strField(o, "kind").?);
                    }
                    try s.client.sendJson(.{
                        .jsonrpc = "2.0",
                        .id = perm_rid,
                        .result = .{ .outcome = .{ .optionId = "allow_once" } },
                    });
                    decision_sent = true;
                }
            }
        }
        var terminal: ?Frame = null;
        for (all.items) |f| {
            if (isResponseId(f.value, 3)) terminal = f.value;
        }
        if (terminal) |t| {
            try std.testing.expectEqualStrings("end_turn", strField(t, "result.stopReason").?);
            var saw_perm = false;
            var saw_tool_call = false;
            var saw_tool_update = false;
            for (all.items) |g| {
                if (isRequestMethod(g.value, "session/request_permission")) saw_perm = true;
                if (isNotificationMethod(g.value, "session/update")) {
                    const kind = strField(g.value, "params.update.sessionUpdate") orelse "";
                    if (std.mem.eql(u8, kind, "tool_call")) saw_tool_call = true;
                    if (std.mem.eql(u8, kind, "tool_call_update")) saw_tool_update = true;
                }
            }
            try std.testing.expect(saw_perm);
            try std.testing.expect(saw_tool_call);
            try std.testing.expect(saw_tool_update);
            // Tool actually ran: the file exists in the fixture cwd.
            const content = s.tmp.dir.readFileAlloc(io, tool_file_name, gpa, .limited(1024)) catch null;
            if (content) |c| {
                defer gpa.free(c);
                try std.testing.expect(std.mem.indexOf(u8, c, "write it") != null);
            } else {
                return error.ToolDidNotRun;
            }
            deadline = 99_999;
            break;
        }
    }
    if (deadline < 99_999) return error.NoTerminal;
}

test "gate14_permission_deny_reject_options_denied_body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const outcomes = [_][]const u8{ "reject_once", "reject_always", "cancelled" };
    for (outcomes) |outcome| {
        var s = try Session.start(gpa, io, true, 1, 0, 0, false);
        defer s.deinit();
        const init_resp = try s.handshake();
        freeFrames(gpa, init_resp);

        try s.sendPrompt(3, "write denied");
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
                    return isResponseId(f, 3);
                }
            }.pred);
            for (frames) |f| try all.append(gpa, f);
            gpa.free(frames);
            if (!decision_sent) {
                for (all.items) |f| {
                    if (isRequestMethod(f.value, "session/request_permission")) {
                        const rid = intField(f.value, "id") orelse return error.NoPermissionId;
                        if (std.mem.eql(u8, outcome, "cancelled")) {
                            try s.client.sendJson(.{
                                .jsonrpc = "2.0",
                                .id = rid,
                                .result = .{ .outcome = "cancelled" },
                            });
                        } else {
                            try s.client.sendJson(.{
                                .jsonrpc = "2.0",
                                .id = rid,
                                .result = .{ .outcome = .{ .optionId = outcome } },
                            });
                        }
                        decision_sent = true;
                    }
                }
            }
            var terminal: ?Frame = null;
            for (all.items) |f| {
                if (isResponseId(f.value, 3)) terminal = f.value;
            }
            if (terminal) |t| {
                try std.testing.expectEqualStrings("end_turn", strField(t, "result.stopReason").?);
                var saw_denied_body = false;
                for (all.items) |g| {
                    if (isNotificationMethod(g.value, "session/update")) {
                        const kind = strField(g.value, "params.update.sessionUpdate") orelse "";
                        if (std.mem.eql(u8, kind, "tool_call_update")) {
                            const text = strField(g.value, "params.update.content.0.content.text") orelse "";
                            if (std.mem.indexOf(u8, text, "permission denied") != null) saw_denied_body = true;
                        }
                    }
                }
                try std.testing.expect(saw_denied_body);
                deadline = 99_999;
                break;
            }
        }
        if (deadline < 99_999) return error.NoTerminal;
    }
}

test "gate15_permission_remember_allow_always_no_second_ask" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Alternating tool calls (every 2nd connection): each run's first
    // request gets a tool, the result-echo request gets plain text. A plain
    // count could never cover run 2 — run 1's tool-result round-trips
    // consume every counted connection first.
    var s = try Session.start(gpa, io, true, 0, 2, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // Run 1: allow_always → the write path is remembered.
    try s.sendPrompt(3, "first write");
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
                return isResponseId(f, 3);
            }
        }.pred);
        for (frames) |f| try all.append(gpa, f);
        gpa.free(frames);
        if (!decision_sent) {
            for (all.items) |f| {
                if (isRequestMethod(f.value, "session/request_permission")) {
                    const rid = intField(f.value, "id") orelse return error.NoPermissionId;
                    try s.client.sendJson(.{
                        .jsonrpc = "2.0",
                        .id = rid,
                        .result = .{ .outcome = .{ .optionId = "allow_always" } },
                    });
                    decision_sent = true;
                }
            }
        }
        for (all.items) |f| {
            if (isResponseId(f.value, 3)) deadline = 99_999;
        }
    }
    if (deadline < 99_999) return error.NoTerminal;

    // Run 2: identical write path → remembered → NO re-ask, tool still runs.
    try s.sendPrompt(4, "second write");
    var saw_perm2 = false;
    var frames2: []OwnedFrame = &.{};
    var all2: std.ArrayList(OwnedFrame) = .empty;
    defer {
        for (all2.items) |*f| f.deinit();
        all2.deinit(gpa);
    }
    var deadline2: u64 = 0;
    while (deadline2 < 15_000) : (deadline2 += 100) {
        frames2 = try s.client.recvUntil(500, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 4);
            }
        }.pred);
        for (frames2) |f| try all2.append(gpa, f);
        gpa.free(frames2);
        for (all2.items) |f| {
            if (isRequestMethod(f.value, "session/request_permission")) saw_perm2 = true;
            if (isResponseId(f.value, 4)) deadline2 = 99_999;
        }
    }
    if (deadline2 < 99_999) return error.NoTerminal;
    try std.testing.expect(!saw_perm2);
    const content = s.tmp.dir.readFileAlloc(io, tool_file_name, gpa, .limited(1024)) catch null;
    if (content) |c| {
        defer gpa.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "second write") != null);
    } else {
        return error.ToolDidNotRun;
    }
}

test "gate16_cancel_pending_gate_deny_run_cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, true, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "gate me");
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
            if (isRequestMethod(f.value, "session/request_permission")) saw_request = true;
        }
        if (saw_request) break;
    }
    try std.testing.expect(saw_request);
    try s.client.sendJson(.{
        .jsonrpc = "2.0",
        .method = "session/cancel",
        .params = .{ .sessionId = "sess_1" },
    });
    const end = try s.client.recvUntil(15_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 3);
        }
    }.pred);
    defer freeFrames(gpa, end);
    var cancelled: ?Frame = null;
    for (end) |f| {
        if (isResponseId(f.value, 3)) cancelled = f.value;
    }
    const c = cancelled orelse return error.NoTerminal;
    try std.testing.expectEqualStrings("cancelled", strField(c, "result.stopReason").?);
}

test "gate17_session_list_single_row_process_cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 5), .method = "session/list" });
    const frames = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 5);
        }
    }.pred);
    defer freeFrames(gpa, frames);
    try std.testing.expectEqualStrings("sess_1", strField(frames[0].value, "result.sessions.0.sessionId").?);
    // cwd is the redaction exception: the client launched the process.
    try std.testing.expectEqualStrings(s.cwd_abs, strField(frames[0].value, "result.sessions.0.cwd").?);
}

test "gate18_extensions_getuser_null_ping_empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 5), .method = "authentication/getUser" });
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 5);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.write(f1[0].value);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"userId\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"userName\":null") != null);

    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 6), .method = "ping" });
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 6);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expect(containsField(f2[0].value, "result"));
    try std.testing.expect(!containsField(f2[0].value, "error"));
}

test "gate19_jsonrpc_errors_parse_invalid_request_string_id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // Malformed JSON → -32700 id null; server continues.
    try s.client.send("{not json");
    const f1 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32700);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expect(idIsNull(f1[0].value));

    // Missing jsonrpc → -32600 id null.
    try s.client.send("{\"id\":1,\"method\":\"ping\"}");
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32600);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expect(idIsNull(f2[0].value));

    // String id echoed verbatim.
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = "abc", .method = "ping" });
    const f3 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseIdStr(f, "abc");
        }
    }.pred);
    defer freeFrames(gpa, f3);
    try std.testing.expect(containsField(f3[0].value, "result"));

    // Server continues.
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 9), .method = "ping" });
    const f4 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 9);
        }
    }.pred);
    defer freeFrames(gpa, f4);
    try std.testing.expect(containsField(f4[0].value, "result"));
}

test "gate20_framing_overcap_resync_server_continues" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, false, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    // Oversized frame (4 MiB + 1) → -32700 id null + resync at newline.
    // ONE raw newline terminates the drain (send() would add a second one,
    // producing an empty line → a spurious extra parse error).
    const big = "x" ** (framing.frame_cap + 1);
    var off: usize = 0;
    while (off < big.len) {
        const n = @min(65536, big.len - off);
        const wrote = try rawWrite(s.client.stdin_fd, big[off .. off + n]);
        off += wrote;
    }
    _ = try rawWrite(s.client.stdin_fd, "\n");
    const f1 = try s.client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isErrorResponse(f, -32700);
        }
    }.pred);
    defer freeFrames(gpa, f1);
    try std.testing.expect(idIsNull(f1[0].value));

    // Server still works after the resync.
    try s.client.sendJson(.{ .jsonrpc = "2.0", .id = @as(i64, 9), .method = "ping" });
    const f2 = try s.client.recvUntil(5_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 9);
        }
    }.pred);
    defer freeFrames(gpa, f2);
    try std.testing.expect(containsField(f2[0].value, "result"));
}

test "gate21_redaction_secret_never_in_frames" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, true, 1, 0, 0, false);
    defer s.deinit();
    const init_resp = try s.handshake();
    freeFrames(gpa, init_resp);

    try s.sendPrompt(3, "embed the secret " ++ secret_fixture ++ " in the file");
    var decision_sent = false;
    var frames: []OwnedFrame = &.{};
    defer freeFrames(gpa, frames);
    var deadline: u64 = 0;
    var saw_request = false;
    while (deadline < 15_000) : (deadline += 100) {
        freeFrames(gpa, frames);
        frames = try s.client.recvUntil(500, struct {
            fn pred(f: Frame) bool {
                return isResponseId(f, 3);
            }
        }.pred);
        if (!decision_sent) {
            for (frames) |f| {
                if (isRequestMethod(f.value, "session/request_permission")) {
                    const rid = intField(f.value, "id") orelse return error.NoPermissionId;
                    try s.client.sendJson(.{
                        .jsonrpc = "2.0",
                        .id = rid,
                        .result = .{ .outcome = .{ .optionId = "allow_once" } },
                    });
                    decision_sent = true;
                }
            }
        }
        for (frames) |f| {
            if (isRequestMethod(f.value, "session/request_permission")) saw_request = true;
            if (isResponseId(f.value, 3)) deadline = 99_999;
        }
        if (deadline >= 99_999) break;
    }
    try std.testing.expect(saw_request);
    // The secret was in the prompt, in the mock-echoed tool args (→ the
    // permission `fields`), and in the echoed chunks — it must never appear
    // on the wire.
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

test "gate26_ownership_no_core_or_tui_imports_in_acp_files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_][]const u8{
        "packages/zag-cli/src/acp/protocol.zig",
        "packages/zag-cli/src/acp/server.zig",
        "packages/zag-cli/src/acp_entry.zig",
    };
    for (files) |path| {
        const content = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-agent-core\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"zag-tui\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "zag_tui") == null);
    }
}

// ── PTY gates (acp-001 #22/#23; rpc/tui fixture style) ──────────────────────

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
        for (acp_argv) |a| try args_z.append(self.gpa, try self.gpa.dupeZ(u8, a));

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

    /// Close the master: the child's stdin reaches EOF/EIO (client
    /// disconnect, acp.md §10.3).
    fn closeMaster(self: *PtySession) void {
        if (self.master >= 0) _ = std.c.close(self.master);
        self.master = -1;
    }

    fn waitExit(self: *PtySession, io: Io, bound_ms: u64) ?u32 {
        const pid = self.pid;
        if (pid <= 0) return null;
        const st = waitBounded(io, pid, bound_ms);
        if (st != null) self.pid = 0;
        return st;
    }
};

test "gate22_pty_stdout_protocol_only_handshake_eof_exit0" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 1, 0, 0, false);
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

    // ACP sends nothing at startup (unlike rpc's `ready`): the editor
    // initiates with `initialize`, then waits for the response.
    pty.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n");
    const found = try pty.waitMarker(io, "\"protocolVersion\":1", 12_000);
    try std.testing.expect(found);
    // No ANSI escapes / alt-screen on the wire (protocol-only stdout).
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, pty.acc.items, "state:idle") == null);

    // Send a prompt over the PTY: response arrives as protocol.
    pty.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[{\"type\":\"text\",\"text\":\"pty hello\"}]}}\n");
    const resp = try pty.waitMarker(io, "\"stopReason\":\"end_turn\"", 15_000);
    try std.testing.expect(resp);

    // EOF (client closes stdin) → graceful exit 0.
    pty.closeMaster();
    const st = pty.waitExit(io, 10_000) orelse {
        pty.deinit(io);
        return error.Timeout;
    };
    try expectExited(st, 0);
    pty.deinit(io);
}

test "gate23_pty_busy_first_sigint_graceful_0_second_130_std" {
    if (!pty_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 1, 0, 3_000, true);
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
    pty.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n");
    try std.testing.expect(try pty.waitMarker(io, "\"protocolVersion\":1", 12_000));

    pty.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[{\"type\":\"text\",\"text\":\"sigint busy\"}]}}\n");
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

test "gate24_disconnect_busy_exit0_session_saved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session_path = ".zag/sessions/acp_disconnect.jsonl";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const mock = try startMock(io, tmp.dir, false, 1, 0, 2_000, true);
    defer reap(io, mock.pid);
    const env = try makeEnvPairs(gpa, mock.port);
    defer {
        gpa.free(env[1]);
        gpa.free(env);
    }
    var argv: [acp_argv.len + 2][]const u8 = undefined;
    for (acp_argv, 0..) |a, i| argv[i] = a;
    argv[acp_argv.len] = "-s";
    argv[acp_argv.len + 1] = session_path;
    var client = try AcpClient.spawn(gpa, io, tmp.dir, env, &argv);
    defer client.deinit();

    try client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 1),
        .method = "initialize",
        .params = .{ .protocolVersion = @as(i64, 1) },
    });
    const init_resp = try client.recvUntil(10_000, struct {
        fn pred(f: Frame) bool {
            return isResponseId(f, 1);
        }
    }.pred);
    defer freeFrames(gpa, init_resp);

    try client.sendJson(.{
        .jsonrpc = "2.0",
        .id = @as(i64, 3),
        .method = "session/prompt",
        .params = .{
            .sessionId = "sess_1",
            .prompt = &.{.{ .type = "text", .text = "disconnect me" }},
        },
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
        try std.testing.expect(std.mem.indexOf(u8, c, "\"role\"") != null);
    }
}

test "gate25_startup_failure_exit30_stdout_empty_stderr_diagnostic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try runZagPipes(gpa, io, tmp.dir, &.{"--acp"});
    defer out.deinit(gpa);
    // No provider config → provider_configuration → exit 30 (acp.md §10.4).
    try std.testing.expectEqual(@as(u8, 30), std.math.cast(u8, out.status).?);
    try std.testing.expectEqual(@as(usize, 0), out.stdout.len);
    try std.testing.expect(out.stderr.len > 0);
}
