//! Minimal LSP session client (lsp-001): one server child per workspace
//! root, JSON-RPC over stdio pipes, a frozen message subset, bounded
//! deadlines/caches, and direct-child spawn/cleanup.
//!
//! All new MIT-clean code (no vendored LSP client). Owned by
//! `zag-coding-agent` (D-012 law — no Core ports, no process/pipe symbols
//! in `zag-agent-core`).
//!
//! Lifecycle (module §5):
//! - lazy start on first tool call for a root: PATH resolve → spawn
//!   (stdio pipes) → `initialize` handshake (≤20 s) → `initialized`
//! - teardown on `Agent.deinit`: `shutdown` (≤1 s) → `exit` → SIGTERM →
//!   bounded grace wait → SIGKILL → wait. Direct child only.
//! - idle timeout (10 min): checked at call start; teardown then restart.
//! - crash: EOF on stdout / pipe closed → state `.dead`; the current call
//!   fails soft, the next call restarts.
//!
//! Env note: v1 spawns with `environ_map = null` (inherit parent env,
//! same as `run_shell`). TODO(lsp-001): env allow-list hardening
//! {PATH, HOME, LANG, LC_ALL, LC_CTYPE, ZLS_*} — deferred because Zig
//! 0.16 exposes no libc-free parent-environ read and the module's
//! fixture list has no allow-list gate (module §12 Q2 stays open).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const jsonrpc = @import("jsonrpc.zig");

pub const max_file_bytes: usize = 4 * 1024 * 1024;
pub const max_open_files: usize = 64;
pub const max_diag_text_bytes: usize = 32 * 1024;
pub const max_diag_entries: usize = 200;
pub const max_stderr_ring_bytes: usize = 8 * 1024;
const poll_interval_ns: i96 = 20 * std.time.ns_per_ms;

/// Server table (v1: zig → zls only; the shape admits later rows).
pub const ServerRow = struct {
    lang: []const u8,
    binary: []const u8,
    argv: []const []const u8,
};

pub const server_table = [_]ServerRow{
    .{ .lang = "zig", .binary = "zls", .argv = &.{"zls"} },
};

pub const PositionEncoding = enum { utf8, utf16 };

/// Session configuration. Production defaults are the frozen budgets;
/// the private `builtin.is_test` seam overrides binary/argv/deadlines/idle.
pub const Config = struct {
    binary: []const u8 = "zls",
    argv: []const []const u8 = &.{"zls"},
    startup_deadline_ms: u32 = 20_000,
    request_deadline_ms: u32 = 15_000,
    diag_wait_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 10 * 60 * 1000,
    /// Grace window after SIGTERM before SIGKILL (module §7: 2 s).
    teardown_grace_ms: u32 = 2_000,
};

pub const SessionError = error{
    OutOfMemory,
    /// Binary not found in PATH / spawn failure → tool body `null`.
    SpawnFailed,
    /// initialize handshake failed (timeout or protocol) → `null`.
    InitializeFailed,
    /// EOF / pipe closed while a request was pending (server crash).
    ServerExited,
    /// Framing or JSON parse violation, or message over the 8 MiB cap.
    ProtocolError,
    /// Request deadline elapsed with no answer.
    RequestTimeout,
    /// Other I/O failure.
    Io,
};

/// Open-file sync cache entry (module §5.3).
const OpenFile = struct {
    uri: []u8,
    content: []u8,
    version: u32,
};

/// publishDiagnostics cache entry (module §5.3): preformatted per-URI text.
pub const DiagEntry = struct {
    uri: []u8,
    text: []u8,
};

/// Bounded stderr ring (tail surfaced on tool_failed).
const StderrRing = struct {
    buf: [max_stderr_ring_bytes]u8 = undefined,
    len: usize = 0,

    fn push(self: *StderrRing, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0 and self.len < self.buf.len) {
            self.buf[self.len] = rest[0];
            self.len += 1;
            rest = rest[1..];
        }
    }

    fn tail(self: *const StderrRing) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const State = enum {
    ready,
    /// Server gone (crash / protocol kill / idle teardown). Next call restarts.
    dead,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,
    root: []u8,
    root_uri: []u8,
    child: std.process.Child,
    pid: std.posix.pid_t,
    state: State = .ready,
    position_encoding: PositionEncoding = .utf16,
    next_id: u64 = 1,
    pending_id: ?u64 = null,
    response_arrived: bool = false,
    last_response: ?jsonrpc.Response = null,
    diag_wait_uri: ?[]const u8 = null,
    /// True once stdout EOF was observed (child exited); teardown can skip
    /// the SIGTERM grace window for an already-dead child.
    child_exited: bool = false,
    open_files: std.ArrayListUnmanaged(OpenFile) = .empty,
    diag_cache: std.ArrayListUnmanaged(DiagEntry) = .empty,
    stderr_ring: StderrRing = .{},
    decoder: jsonrpc.Decoder = .{},
    last_used_ns: i128 = 0,

    pub fn deinit(self: *Session) void {
        self.teardown();
        self.decoder.deinit(self.gpa);
        for (self.open_files.items) |f| {
            self.gpa.free(f.uri);
            self.gpa.free(f.content);
        }
        self.open_files.deinit(self.gpa);
        for (self.diag_cache.items) |d| {
            self.gpa.free(d.uri);
            self.gpa.free(d.text);
        }
        self.diag_cache.deinit(self.gpa);
        if (self.last_response) |*r| jsonrpc.deinitResponse(self.gpa, r.*);
        self.gpa.free(self.root_uri);
        self.gpa.free(self.root);
        self.* = undefined;
    }

    // ── spawn + initialize handshake ────────────────────────────────────

    /// Spawn the server child for `root` (real absolute path) and complete
    /// the initialize handshake within the startup deadline.
    pub fn start(gpa: std.mem.Allocator, io: Io, cfg: Config, root: []const u8) SessionError!*Session {
        const self = gpa.create(Session) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);

        const root_owned = gpa.dupe(u8, root) catch return error.OutOfMemory;
        errdefer gpa.free(root_owned);
        const root_uri = uriForPath(gpa, root) catch return error.OutOfMemory;
        errdefer gpa.free(root_uri);

        // PATH resolution happens inside spawn (argv[0] lookup); missing
        // binary → SpawnFailed → tool body `null` (one attempt per start).
        const child = std.process.spawn(io, .{
            .argv = cfg.argv,
            .cwd = .{ .path = root },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            // TODO(lsp-001): env allow-list hardening {PATH, HOME, LANG,
            // LC_ALL, LC_CTYPE, ZLS_*} — v1 inherits the parent env
            // (same as run_shell), see module §12 Q2.
        }) catch return error.SpawnFailed;

        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .root = root_owned,
            .root_uri = root_uri,
            .child = child,
            .pid = child.id.?,
        };

        // Non-blocking pipes for the bounded poll loop (module §6.4).
        setNonblocking(child.stdout.?) catch {
            self.teardown();
            return error.Io;
        };
        setNonblocking(child.stderr.?) catch {
            self.teardown();
            return error.Io;
        };

        errdefer self.teardown();

        // initialize (id 1) with client capabilities + positionEncodings.
        const params = try initParams(gpa, self.pid, self.root_uri);
        defer gpa.free(params);

        const init_body = jsonrpc.writeRequest(gpa, 1, "initialize", params) catch return error.OutOfMemory;
        defer gpa.free(init_body);
        try self.sendBody(init_body);
        self.pending_id = 1;
        defer self.pending_id = null;

        const deadline = nowNs(self.io) + @as(i128, cfg.startup_deadline_ms) * std.time.ns_per_ms;
        var init_done = false;
        while (!init_done) {
            if (nowNs(self.io) >= deadline) return error.InitializeFailed;
            self.pumpOnce() catch |err| switch (err) {
                error.ServerExited, error.ProtocolError => return error.InitializeFailed,
                else => return err,
            };
            if (self.response_arrived) {
                // Response captured; parse capabilities from it.
                if (self.last_response) |*resp| {
                    self.position_encoding = parsePositionEncoding(resp);
                    jsonrpc.deinitResponse(self.gpa, resp.*);
                    self.last_response = null;
                }
                init_done = true;
                break;
            }
            Io.sleep(io, .{ .nanoseconds = poll_interval_ns }, .awake) catch return error.Io;
        }

        // initialized notification.
        const notif = jsonrpc.writeNotification(gpa, "initialized", "{}") catch return error.OutOfMemory;
        defer gpa.free(notif);
        try self.sendBody(notif);

        self.touch();
        return self;
    }

    // ── request / notify surface ────────────────────────────────────────

    /// Send a request and pump until its response arrives or the deadline
    /// elapses. Notifications (publishDiagnostics etc.) are dispatched
    /// while pumping. On timeout / crash / protocol error the session is
    /// torn down (state dead). Caller owns the returned message and must
    /// `jsonrpc.deinitMessage` it.
    pub fn request(self: *Session, method: []const u8, params_json: []const u8, deadline_ms: u32) SessionError!jsonrpc.Message {
        if (self.state != .ready) return error.ServerExited;
        const id = self.next_id;
        self.next_id +%= 1;

        const body = jsonrpc.writeRequest(self.gpa, id, method, params_json) catch return error.OutOfMemory;
        defer self.gpa.free(body);
        try self.sendBody(body);

        self.pending_id = id;
        self.response_arrived = false;
        defer {
            self.pending_id = null;
            self.response_arrived = false;
        }

        const deadline = nowNs(self.io) + @as(i128, deadline_ms) * std.time.ns_per_ms;
        while (true) {
            if (nowNs(self.io) >= deadline) {
                self.markDeadAndTeardown();
                return error.RequestTimeout;
            }
            self.pumpOnce() catch |err| switch (err) {
                error.ServerExited, error.ProtocolError => {
                    self.markDeadAndTeardown();
                    return err;
                },
                else => return err,
            };
            if (self.response_arrived) {
                const resp = self.last_response.?;
                self.last_response = null;
                return .{ .response = resp };
            }
            Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch return error.Io;
        }
    }

    /// Send a notification (no response expected; no pump).
    pub fn notify(self: *Session, method: []const u8, params_json: []const u8) SessionError!void {
        if (self.state != .ready) return error.ServerExited;
        const body = jsonrpc.writeNotification(self.gpa, method, params_json) catch return error.OutOfMemory;
        defer self.gpa.free(body);
        try self.sendBody(body);
    }

    /// Document sync + diagnostics pull (module §5.3): returns the cached
    /// per-URI diagnostics text, or null when the cache stayed empty
    /// through the wait budget. A wait-budget expiry is a designed `null`
    /// outcome (not a protocol failure) — the session stays alive.
    pub fn pullDiagnostics(self: *Session, uri: []const u8) SessionError!?[]const u8 {
        if (self.state != .ready) return error.ServerExited;
        if (self.diagFor(uri)) |text| return text;

        self.diag_wait_uri = uri;
        defer self.diag_wait_uri = null;
        const deadline = nowNs(self.io) + @as(i128, self.cfg.diag_wait_ms) * std.time.ns_per_ms;
        while (nowNs(self.io) < deadline) {
            self.pumpOnce() catch |err| switch (err) {
                error.ServerExited, error.ProtocolError => {
                    self.markDeadAndTeardown();
                    return err;
                },
                else => return err,
            };
            if (self.diagFor(uri)) |text| return text;
            Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch return error.Io;
        }
        return null;
    }

    /// Idle timeout check at call start; when expired, teardown and mark
    /// dead (the current call restarts the session).
    pub fn checkIdle(self: *Session) void {
        if (self.state != .ready) return;
        const idle_ns = @as(i128, self.cfg.idle_timeout_ms) * std.time.ns_per_ms;
        if (nowNs(self.io) - self.last_used_ns >= idle_ns) {
            self.teardown();
            self.state = .dead;
        }
    }

    pub fn touch(self: *Session) void {
        self.last_used_ns = nowNs(self.io);
    }

    pub fn isDead(self: *const Session) bool {
        return self.state != .ready;
    }

    pub fn stderrTail(self: *const Session) []const u8 {
        return self.stderr_ring.tail();
    }


    // ── document sync (module §5.3) ─────────────────────────────────────

    /// Ensure the document is open and up to date: didOpen (version 1) or
    /// didChange (full text, version+1). Drops a stale diagnostics entry on
    /// change so a fresh publish is awaited. Cache ≤ 64 URIs, evict oldest.
    pub fn syncDocument(self: *Session, uri: []const u8, content: []const u8) SessionError!void {
        const idx = self.openIndex(uri);
        if (idx) |i| {
            const f = &self.open_files.items[i];
            if (std.mem.eql(u8, f.content, content)) return;
            f.version +%= 1;
            const new_content = self.gpa.dupe(u8, content) catch return error.OutOfMemory;
            self.gpa.free(f.content);
            f.content = new_content;
            self.dropDiag(uri);
            const params = try self.changeParams(uri, f.version, content);
            defer self.gpa.free(params);
            return self.notify("textDocument/didChange", params);
        }

        if (self.open_files.items.len >= max_open_files) {
            const evicted = self.open_files.orderedRemove(0);
            self.gpa.free(evicted.uri);
            self.gpa.free(evicted.content);
        }
        const uri_owned = self.gpa.dupe(u8, uri) catch return error.OutOfMemory;
        errdefer self.gpa.free(uri_owned);
        const content_owned = self.gpa.dupe(u8, content) catch return error.OutOfMemory;
        errdefer self.gpa.free(content_owned);
        self.open_files.append(self.gpa, .{
            .uri = uri_owned,
            .content = content_owned,
            .version = 1,
        }) catch return error.OutOfMemory;
        self.dropDiag(uri);
        const params = try self.openParams(uri, content);
        defer self.gpa.free(params);
        try self.notify("textDocument/didOpen", params);
    }

    /// Position params in the negotiated encoding: utf-8 byte offsets, or
    /// utf-16 code units when the server selected/implied utf-16 (module §6.3).
    pub fn positionParams(self: *Session, uri: []const u8, line: u32, col: u32) SessionError![]u8 {
        const uri_json = jsonrpc.jsonString(self.gpa, uri) catch return error.OutOfMemory;
        defer self.gpa.free(uri_json);
        var wire_col = col;
        if (self.position_encoding == .utf16) {
            if (self.openIndex(uri)) |i| {
                wire_col = utf8OffsetToUtf16Units(self.open_files.items[i].content, line, col);
            }
        }
        const body = std.fmt.allocPrint(self.gpa, "{{\"textDocument\":{{\"uri\":{s}}},\"position\":{{\"line\":{d},\"character\":{d}}}}}", .{ uri_json, line, wire_col }) catch return error.OutOfMemory;
        return body;
    }

    // ── pump ────────────────────────────────────────────────────────────

    /// One non-blocking pump: drain stderr/stdout, dispatch messages.
    /// stderr is drained BEFORE stdout so a dying child's final stderr bytes
    /// are captured even when its stdout EOF is observed in the same pass.
    fn pumpOnce(self: *Session) SessionError!void {
        if (self.child.stderr) |f| {
            var buf: [2048]u8 = undefined;
            const n = f.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock, error.EndOfStream => 0,
                else => return error.Io,
            };
            if (n > 0) self.stderr_ring.push(buf[0..n]);
        }
        if (self.child.stdout) |f| {
            var buf: [8192]u8 = undefined;
            const n = f.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => 0,
                error.EndOfStream => {
                    self.child_exited = true;
                    return error.ServerExited;
                },
                else => return error.Io,
            };
            if (n > 0) self.decoder.push(self.gpa, buf[0..n]) catch return error.OutOfMemory;
        }
        while (try self.decoder.next(self.gpa)) |msg| {
            var msg_var = msg;
            defer jsonrpc.deinitMessage(self.gpa, msg_var);
            try self.dispatch(&msg_var);
        }
    }

    fn dispatch(self: *Session, msg: *jsonrpc.Message) SessionError!void {
        switch (msg.*) {
            .response => |*r| {
                if (self.pending_id) |pid| {
                    if (r.id == pid) {
                        // Ownership of the parsed tree moves into last_response
                        // (the caller's copy is nulled so deinitMessage is a no-op).
                        self.response_arrived = true;
                        self.last_response = r.*;
                        r.parsed = null;
                        r.err = null;
                        self.pending_id = null;
                    }
                    // Response for a stale id: drained and ignored.
                }
            },
            .notification => |n| {
                if (std.mem.eql(u8, n.method, "textDocument/publishDiagnostics")) {
                    self.cacheDiagnostics(n.params) catch return error.OutOfMemory;
                }
                // window/showMessage, window/logMessage, telemetry/event,
                // $/progress and other notifications: ignored (drained).
            },
            .request => |req| {
                // Unknown server→client request: reply MethodNotFound, continue.
                const reply = jsonrpc.writeErrorResponse(self.gpa, req.id, -32601, "MethodNotFound") catch return error.OutOfMemory;
                defer self.gpa.free(reply);
                self.sendBody(reply) catch {};
            },
        }
    }

    // ── diagnostics cache ───────────────────────────────────────────────

    fn diagFor(self: *Session, uri: []const u8) ?[]const u8 {
        for (self.diag_cache.items) |d| {
            if (std.mem.eql(u8, d.uri, uri)) return d.text;
        }
        return null;
    }

    fn dropDiag(self: *Session, uri: []const u8) void {
        var i: usize = 0;
        while (i < self.diag_cache.items.len) {
            if (std.mem.eql(u8, self.diag_cache.items[i].uri, uri)) {
                const d = self.diag_cache.orderedRemove(i);
                self.gpa.free(d.uri);
                self.gpa.free(d.text);
            } else {
                i += 1;
            }
        }
    }

    /// Format and store publishDiagnostics params (module §3.4 diagnostics):
    /// `<severity>: <path>:<line+1>:<col+1>: <message>` per entry,
    /// ≤ 200 entries / 32 KiB text per URI, explicit truncation markers.
    fn cacheDiagnostics(self: *Session, params: ?std.json.Value) SessionError!void {
        if (params == null or params.? != .object) return;
        const obj = params.?.object;
        const uri_v = obj.get("uri") orelse return;
        if (uri_v != .string) return;
        const uri = uri_v.string;
        const diags_v = obj.get("diagnostics") orelse return;
        if (diags_v != .array) return;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);

        var n: usize = 0;
        for (diags_v.array.items) |d| {
            if (n >= max_diag_entries) {
                out.appendSlice(self.gpa, "...[truncated]") catch return error.OutOfMemory;
                break;
            }
            if (d != .object) continue;
            const severity = diagnosticSeverityName(d.object.get("severity"));
            const pos = diagnosticPositionText(self.gpa, self, uri, d.object.get("range")) catch return error.OutOfMemory;
            defer self.gpa.free(pos);
            const msg_v = d.object.get("message") orelse continue;
            if (msg_v != .string) continue;
            if (n > 0) out.append(self.gpa, '\n') catch return error.OutOfMemory;
            const row = std.fmt.allocPrint(self.gpa, "{s}: {s}: {s}", .{ severity, pos, msg_v.string }) catch return error.OutOfMemory;
            defer self.gpa.free(row);
            out.appendSlice(self.gpa, row) catch return error.OutOfMemory;
            n += 1;
        }
        if (n == 0) return;

        var text = out.toOwnedSlice(self.gpa) catch return error.OutOfMemory;
        errdefer self.gpa.free(text);
        if (text.len > max_diag_text_bytes) {
            const cut = self.gpa.dupe(u8, text[0..max_diag_text_bytes]) catch return error.OutOfMemory;
            self.gpa.free(text);
            text = std.fmt.allocPrint(self.gpa, "{s}...[truncated]", .{cut}) catch return error.OutOfMemory;
            self.gpa.free(cut);
        }

        self.dropDiag(uri);
        const uri_owned = self.gpa.dupe(u8, uri) catch return error.OutOfMemory;
        errdefer self.gpa.free(uri_owned);
        self.diag_cache.append(self.gpa, .{ .uri = uri_owned, .text = text }) catch return error.OutOfMemory;
    }

    // ── wire helpers ────────────────────────────────────────────────────

    fn sendBody(self: *Session, body: []const u8) SessionError!void {
        const framed = jsonrpc.frame(self.gpa, body) catch return error.OutOfMemory;
        defer self.gpa.free(framed);
        const f = self.child.stdin orelse return error.ServerExited;
        f.writeStreamingAll(self.io, framed) catch return error.Io;
    }

    fn openIndex(self: *Session, uri: []const u8) ?usize {
        for (self.open_files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.uri, uri)) return i;
        }
        return null;
    }

    fn openParams(self: *Session, uri: []const u8, content: []const u8) SessionError![]u8 {
        const uri_json = jsonrpc.jsonString(self.gpa, uri) catch return error.OutOfMemory;
        defer self.gpa.free(uri_json);
        const text_json = jsonrpc.jsonString(self.gpa, content) catch return error.OutOfMemory;
        defer self.gpa.free(text_json);
        return std.fmt.allocPrint(self.gpa, "{{\"textDocument\":{{\"uri\":{s},\"languageId\":\"zig\",\"version\":1,\"text\":{s}}}}}", .{ uri_json, text_json }) catch return error.OutOfMemory;
    }

    fn changeParams(self: *Session, uri: []const u8, version: u32, content: []const u8) SessionError![]u8 {
        const uri_json = jsonrpc.jsonString(self.gpa, uri) catch return error.OutOfMemory;
        defer self.gpa.free(uri_json);
        const text_json = jsonrpc.jsonString(self.gpa, content) catch return error.OutOfMemory;
        defer self.gpa.free(text_json);
        return std.fmt.allocPrint(self.gpa, "{{\"textDocument\":{{\"uri\":{s},\"version\":{d}}},\"contentChanges\":[{{\"text\":{s}}}]}}", .{ uri_json, version, text_json }) catch return error.OutOfMemory;
    }

    // ── teardown ────────────────────────────────────────────────────────

    fn markDeadAndTeardown(self: *Session) void {
        self.state = .dead;
        self.teardown();
    }

    /// Best-effort graceful teardown (module §5.2): shutdown request (≤1 s)
    /// → exit notification → wait for voluntary exit (≤ grace) → SIGTERM →
    /// bounded grace wait → SIGKILL → wait. Direct child only. Idempotent.
    fn teardown(self: *Session) void {
        if (self.child.id != null) {
            // Best-effort shutdown (≤1 s) + exit notification.
            if (self.state == .ready and self.child.stdin != null) {
                const body = jsonrpc.writeRequest(self.gpa, self.next_id, "shutdown", "{}") catch null;
                if (body) |b| {
                    defer self.gpa.free(b);
                    self.sendBody(b) catch {};
                    self.pending_id = self.next_id;
                    self.response_arrived = false;
                    const deadline = nowNs(self.io) + std.time.ns_per_s;
                    while (!self.response_arrived and nowNs(self.io) < deadline) {
                        self.pumpOnce() catch break;
                        if (!self.response_arrived) {
                            Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch break;
                        }
                    }
                    self.pending_id = null;
                    self.response_arrived = false;
                }
                const exit_body = jsonrpc.writeNotification(self.gpa, "exit", "{}") catch null;
                if (exit_body) |e| {
                    defer self.gpa.free(e);
                    self.sendBody(e) catch {};
                }
                // Give the server a chance to exit voluntarily on `exit`
                // before escalating to signals (bounded by the grace window).
                const grace_ns = @as(i128, self.cfg.teardown_grace_ms) * std.time.ns_per_ms;
                const exit_deadline = nowNs(self.io) + grace_ns;
                while (!self.child_exited and nowNs(self.io) < exit_deadline) {
                    self.pumpOnce() catch break;
                    if (!self.child_exited) {
                        Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch break;
                    }
                }
            }

            if (!self.child_exited) {
                std.posix.kill(self.pid, .TERM) catch {};
                // Bounded grace window (module §7: 2 s) before escalation.
                const grace_ns = @as(i128, self.cfg.teardown_grace_ms) * std.time.ns_per_ms;
                const deadline = nowNs(self.io) + grace_ns;
                while (nowNs(self.io) < deadline) {
                    Io.sleep(self.io, .{ .nanoseconds = poll_interval_ns }, .awake) catch break;
                }
                std.posix.kill(self.pid, .KILL) catch {};
            }
            // Blocking reap; SIGKILL (or prior exit) guarantees a prompt
            // return. wait() closes the pipes and nulls the id.
            _ = self.child.wait(self.io) catch .{ .exited = 1 };
            self.child.id = null;
        }
        self.closePipes();
    }

    fn closePipes(self: *Session) void {
        if (self.child.stdin) |f| {
            f.close(self.io);
            self.child.stdin = null;
        }
        if (self.child.stdout) |f| {
            f.close(self.io);
            self.child.stdout = null;
        }
        if (self.child.stderr) |f| {
            f.close(self.io);
            self.child.stderr = null;
        }
        self.child.id = null;
    }
};

// ── module-level helpers ────────────────────────────────────────────────

/// Byte offset (utf-8 model convention) → UTF-16 code units for a line,
/// using the open document content (module §6.3 fallback).
pub fn utf8OffsetToUtf16Units(content: []const u8, line: u32, col: u32) u32 {
    var line_no: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\n') {
            if (line_no == line) break;
            line_no += 1;
            line_start = i + 1;
        }
        i += 1;
    }
    const line_bytes = content[line_start..i];
    const limit = @min(@as(usize, col), line_bytes.len);
    var units: u32 = 0;
    var j: usize = 0;
    while (j < limit) {
        const cp_len = std.unicode.utf8ByteSequenceLength(line_bytes[j]) catch 1;
        units += if (cp_len >= 4) 2 else 1;
        j += cp_len;
    }
    return units;
}

/// Percent-encode a path into a file:// URI (LSP file URIs).
pub fn uriForPath(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (path) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
        if (ok) {
            try out.append(gpa, c);
        } else {
            const esc = try std.fmt.allocPrint(gpa, "%{x:0>2}", .{c});
            defer gpa.free(esc);
            try out.appendSlice(gpa, esc);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Build the initialize params (module §6.3). Caller owns the result.
fn initParams(gpa: std.mem.Allocator, pid: std.posix.pid_t, root_uri: []const u8) std.mem.Allocator.Error![]u8 {
    const root_json = try jsonrpc.jsonString(gpa, root_uri);
    defer gpa.free(root_json);
    return std.fmt.allocPrint(gpa,
        \\{{"processId":{d},"rootUri":{s},"capabilities":{{"textDocument":{{"synchronization":{{"dynamicRegistration":false,"willSave":false,"willSaveWaitUntil":false,"didSave":false}},"hover":{{"contentFormat":["plaintext","markdown"]}},"definition":{{}},"references":{{}}}}}},"positionEncodings":["utf-8"]}}
    , .{ pid, root_json });
}

/// Parse the negotiated position encoding from the initialize result
/// (module §6.3: absent or `utf-16` → utf-16 units).
fn parsePositionEncoding(resp: *const jsonrpc.Response) PositionEncoding {
    const result = resp.result orelse return .utf16;
    if (result != .object) return .utf16;
    const cap_v = result.object.get("capabilities") orelse return .utf16;
    if (cap_v != .object) return .utf16;
    const enc = cap_v.object.get("positionEncoding") orelse return .utf16;
    if (enc == .string and std.mem.eql(u8, enc.string, "utf-8")) return .utf8;
    return .utf16;
}

fn diagnosticSeverityName(v: ?std.json.Value) []const u8 {
    const sev = v orelse return "error";
    if (sev != .integer) return "error";
    return switch (sev.integer) {
        2 => "warning",
        3 => "info",
        4 => "hint",
        else => "error",
    };
}

/// Format a diagnostic range start as `<path>:<line+1>:<col+1>` with the
/// workspace-relative display path (module §3.4). Always owned.
fn diagnosticPositionText(gpa: std.mem.Allocator, self: *Session, uri: []const u8, v: ?std.json.Value) std.mem.Allocator.Error![]u8 {
    const display_owned = relDisplay(gpa, self.root_uri, uri);
    defer if (display_owned) |d| gpa.free(d);
    const display = display_owned orelse uri;
    var line: i64 = 0;
    var col: i64 = 0;
    if (v) |range| {
        if (range == .object) {
            if (range.object.get("start")) |start| {
                if (start == .object) {
                    if (start.object.get("line")) |l| {
                        if (l == .integer) line = l.integer;
                    }
                    if (start.object.get("character")) |c| {
                        if (c == .integer) col = c.integer;
                    }
                }
            }
        }
    }
    const line_1: u64 = @intCast(@max(line, 0) + 1);
    const col_1: u64 = @intCast(@max(col, 0) + 1);
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}:{d}:{d}", .{ display, line_1, col_1 }) catch return gpa.dupe(u8, uri);
    return gpa.dupe(u8, s);
}

/// Workspace-relative display path when the URI sits inside the root,
/// else null (caller falls back to the server-supplied URI verbatim).
fn relDisplay(gpa: std.mem.Allocator, root_uri: []const u8, uri: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, uri, root_uri) and uri.len > root_uri.len and uri[root_uri.len] == '/') {
        return gpa.dupe(u8, uri[root_uri.len + 1 ..]) catch null;
    }
    return null;
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// Set O_NONBLOCK on a pipe end. Linux: raw fcntl syscall (no libc).
/// macOS/BSD: libc fcntl (platform ABI). Mirrors sigint.zig's shim.
fn setNonblocking(f: Io.File) error{ Io, Unexpected }!void {
    const fd = f.handle;
    if (builtin.os.tag == .linux) {
        const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
        if (std.os.linux.errno(cur) != .SUCCESS) return error.Io;
        const cur_u: u32 = @intCast(cur);
        const nonblock_bit: u32 = 0o4000; // O_NONBLOCK on Linux.
        const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, cur_u | nonblock_bit);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.Io;
        return;
    }
    if (builtin.os.tag == .macos or builtin.os.tag == .ios or builtin.os.tag == .tvos or
        builtin.os.tag == .watchos or builtin.os.tag == .visionos or builtin.os.tag == .freebsd or
        builtin.os.tag == .netbsd or builtin.os.tag == .dragonfly or builtin.os.tag == .openbsd)
    {
        const cur = std.c.fcntl(fd, std.c.F.GETFL);
        if (cur < 0) return error.Io;
        if (std.c.fcntl(fd, std.c.F.SETFL, cur | 0x0004) < 0) return error.Io; // O_NONBLOCK.
        return;
    }
    return error.Unexpected;
}

// ── tests ───────────────────────────────────────────────────────────────

test "utf8OffsetToUtf16Units counts surrogate pairs" {
    // Line 0: "a😀b" — utf-16 units: a(1) 😀(2) b(1).
    const content = "a\xf0\x9f\x98\x80b\nsecond";
    try std.testing.expectEqual(@as(u32, 0), utf8OffsetToUtf16Units(content, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), utf8OffsetToUtf16Units(content, 0, 1));
    // Byte 2 (middle of the 4-byte emoji) clamps to 3 utf-16 units (a+😀).
    try std.testing.expectEqual(@as(u32, 3), utf8OffsetToUtf16Units(content, 0, 2));
    try std.testing.expectEqual(@as(u32, 3), utf8OffsetToUtf16Units(content, 0, 4));
    // Byte 5 is 'b': a (1) + emoji (2) = 3 utf-16 units up to (exclusive) byte 5.
    try std.testing.expectEqual(@as(u32, 3), utf8OffsetToUtf16Units(content, 0, 5));
    // Whole line: a + emoji + b = 4 utf-16 units.
    try std.testing.expectEqual(@as(u32, 4), utf8OffsetToUtf16Units(content, 0, 6));
    // Line 1 is ASCII.
    try std.testing.expectEqual(@as(u32, 2), utf8OffsetToUtf16Units(content, 1, 2));
}

test "uriForPath percent-encodes specials and keeps slashes" {
    const gpa = std.testing.allocator;
    const uri = try uriForPath(gpa, "/tmp/ws dir/a#b.zig");
    defer gpa.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/ws%20dir/a%23b.zig", uri);
}

test "setNonblocking rejects bad fd" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const bad: Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    try std.testing.expectError(error.Io, setNonblocking(bad));
}
