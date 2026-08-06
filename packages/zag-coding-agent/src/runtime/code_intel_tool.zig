//! `code_intel` tool handler (lsp-001): LSP-backed code intelligence
//! (hover / definition / references / diagnostics) against a persistent
//! per-workspace-root server session (v1: zig → zls).
//!
//! Contract: [docs/modules/lsp.md](../../../docs/modules/lsp.md).
//!
//! - text tool results only; success first line `intel-v1: op=<op> status=ok`
//! - honest absence: missing server / spawn failure / unresolved root /
//!   empty answer → body exactly `null` (4 bytes, no first line)
//! - session lifecycle: lazy start on first call, kill on Agent.deinit,
//!   10 min idle timeout, restart after crash; per-root session cache
//! - handler runs the product workspace Guard on `path` before any server
//!   interaction (raw `Registry.execute` cannot bypass the jail)
//! - private `builtin.is_test` seam overrides server binary/argv/deadlines/
//!   idle (never in Tool JSON, Agent.Options, CLI, or session schema)

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const tool_error = core.tool_error;
const workspace = @import("../workspace.zig");
const client = @import("lsp/client.zig");
const jsonrpc = @import("lsp/jsonrpc.zig");

pub const max_hover_bytes: usize = 32 * 1024;
pub const max_definition_locations: usize = 16;
pub const max_reference_hits: usize = 50;
pub const max_source_line_bytes: usize = 1024;
const truncation_marker = "...[truncated]";
const file_read_limit = client.max_file_bytes;

/// fmt.allocPrint + append (0.16 ArrayList has no writer method).
fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

pub const Op = enum {
    hover,
    definition,
    references,
    diagnostics,

    pub fn fromString(s: []const u8) ?Op {
        const ops = [_]Op{ .hover, .definition, .references, .diagnostics };
        for (ops) |o| {
            if (std.mem.eql(u8, s, @tagName(o))) return o;
        }
        return null;
    }
};

pub const code_intel_def: tool.Definition = .{
    .name = "code_intel",
    .description =
    \\Ask the language server (zls for Zig) for code intelligence at a position in a file.
    \\op is hover | definition | references | diagnostics. path is workspace-relative.
    \\line and col are 0-based LSP positions, required for hover/definition/references
    \\and ignored for diagnostics. Diagnostics are pulled from the server's
    \\publishDiagnostics cache. Returns "null" when the server is unavailable or
    \\has no answer. Subject to the workspace jail.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "op": {
    \\      "type": "string",
    \\      "enum": ["hover", "definition", "references", "diagnostics"]
    \\    },
    \\    "path": { "type": "string", "description": "Workspace-relative file path." },
    \\    "line": { "type": "integer", "minimum": 0, "description": "0-based line (LSP)." },
    \\    "col": { "type": "integer", "minimum": 0, "description": "0-based column (LSP)." }
    \\  },
    \\  "required": ["op", "path"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const code_intel_caps: tool.ToolCapabilities = .{
    .risk = .read,
    .workspace = .{ .path_field = "path" },
    .cancellation = .none,
    .shell = .none,
};

// ── Agent-owned heap-stable state ────────────────────────────────────────

const SessionEntry = struct {
    root: []u8,
    session: *client.Session,
};

/// Agent-owned heap-stable state for the `code_intel` tool. Borrowed by
/// the handler via the `instance` pointer (same pattern as ApplyHunkState /
/// TaskToolState). Lifetime: same as the parent Agent.
pub const CodeIntelState = struct {
    gpa: std.mem.Allocator,
    io: Io,
    sessions: std.ArrayListUnmanaged(SessionEntry) = .empty,

    pub fn deinit(self: *CodeIntelState) void {
        for (self.sessions.items) |e| {
            e.session.deinit();
            self.gpa.destroy(e.session);
            self.gpa.free(e.root);
        }
        self.sessions.deinit(self.gpa);
        self.* = undefined;
    }

    /// Session for `root`, or null (start failure → `null` body this call;
    /// the next call retries). Handles idle teardown + crash restart.
    fn sessionFor(self: *CodeIntelState, root: []const u8) error{ OutOfMemory, SpawnFailed, InitializeFailed }!*client.Session {
        const cfg = activeConfig();
        for (self.sessions.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.root, root)) continue;
            e.session.checkIdle();
            if (e.session.isDead()) {
                // Crash / idle teardown: drop and restart (one restart per call).
                e.session.deinit();
                self.gpa.destroy(e.session);
                self.gpa.free(e.root);
                _ = self.sessions.orderedRemove(i);
                return self.startNew(root, cfg);
            }
            return e.session;
        }
        return self.startNew(root, cfg);
    }

    fn startNew(self: *CodeIntelState, root: []const u8, cfg: client.Config) error{ OutOfMemory, SpawnFailed, InitializeFailed }!*client.Session {
        const session = client.Session.start(self.gpa, self.io, cfg, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SpawnFailed => return error.SpawnFailed,
            error.InitializeFailed => return error.InitializeFailed,
            // Io / ServerExited / ProtocolError / RequestTimeout during the
            // handshake are treated as a failed start (tool body `null`).
            else => return error.InitializeFailed,
        };
        errdefer {
            session.deinit();
            self.gpa.destroy(session);
        }
        const root_owned = self.gpa.dupe(u8, root) catch return error.OutOfMemory;
        errdefer self.gpa.free(root_owned);
        // Bounded cache: ≤ 8 roots, drop the oldest entry on overflow.
        if (self.sessions.items.len >= 8) {
            const evicted = self.sessions.orderedRemove(0);
            evicted.session.deinit();
            self.gpa.destroy(evicted.session);
            self.gpa.free(evicted.root);
        }
        self.sessions.append(self.gpa, .{ .root = root_owned, .session = session }) catch return error.OutOfMemory;
        return session;
    }
};

// ── test seam (builtin.is_test only; never in Tool JSON / Options / CLI) ──

const TestSeam = struct {
    server_path: ?[]const u8 = null,
    server_argv: ?[]const []const u8 = null,
    startup_deadline_ms: u32 = 20_000,
    request_deadline_ms: u32 = 15_000,
    diag_wait_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 10 * 60 * 1000,
    teardown_grace_ms: u32 = 2_000,
};

var test_seam: if (builtin.is_test) TestSeam else void = if (builtin.is_test) .{} else {};

/// Mock server source embedded at compile time (relative to this file:
/// src/runtime → ../../tests/mock_lsp_server.py). No build-module wiring
/// and no runtime path resolution — the fixture writes it into the
/// workspace root and spawns it by relative name under the spawn cwd.
const mock_source = @embedFile("mock_lsp_server.py");

fn activeConfig() client.Config {
    if (builtin.is_test) {
        const path = test_seam.server_path orelse "mock_lsp_server.py";
        return .{
            .binary = path,
            .argv = test_seam.server_argv orelse &.{ "python3", path },
            .startup_deadline_ms = test_seam.startup_deadline_ms,
            .request_deadline_ms = test_seam.request_deadline_ms,
            .diag_wait_ms = test_seam.diag_wait_ms,
            .idle_timeout_ms = test_seam.idle_timeout_ms,
            .teardown_grace_ms = test_seam.teardown_grace_ms,
        };
    }
    return .{};
}

/// Private test seam (module §10): deterministic fixture over real pipes.
pub const testing = struct {
    pub fn setServerPath(p: ?[]const u8) void {
        if (builtin.is_test) test_seam.server_path = p;
    }
    pub fn setServerArgv(argv: ?[]const []const u8) void {
        if (builtin.is_test) test_seam.server_argv = argv;
    }
    pub fn setDeadlines(startup_ms: u32, request_ms: u32, diag_wait_ms: u32) void {
        if (builtin.is_test) {
            test_seam.startup_deadline_ms = startup_ms;
            test_seam.request_deadline_ms = request_ms;
            test_seam.diag_wait_ms = diag_wait_ms;
        }
    }
    pub fn setIdleTimeoutMs(ms: u32) void {
        if (builtin.is_test) test_seam.idle_timeout_ms = ms;
    }
    pub fn setTeardownGraceMs(ms: u32) void {
        if (builtin.is_test) test_seam.teardown_grace_ms = ms;
    }
    pub fn reset() void {
        if (builtin.is_test) test_seam = .{};
    }
};

// ── tool construction ────────────────────────────────────────────────────

pub fn makeCodeIntelTool(state: *CodeIntelState) tool.Tool {
    return .{
        .descriptor = .{
            .definition = code_intel_def,
            .capabilities = code_intel_caps,
        },
        .instance = state,
        .handler = handleCodeIntel,
    };
}

// ── argument parsing ─────────────────────────────────────────────────────

const Args = struct {
    op: Op,
    path: []const u8,
    line: u32,
    col: u32,
    has_position: bool,
};

fn parseArgs(gpa: std.mem.Allocator, arguments_json: []const u8) error{ OutOfMemory, InvalidArguments }!Args {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments_json, .{}) catch
        return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;

    const op_v = obj.get("op") orelse return error.InvalidArguments;
    if (op_v != .string) return error.InvalidArguments;
    const op = Op.fromString(op_v.string) orelse return error.InvalidArguments;

    const path_v = obj.get("path") orelse return error.InvalidArguments;
    if (path_v != .string or path_v.string.len == 0) return error.InvalidArguments;
    const path = try gpa.dupe(u8, path_v.string);

    var args: Args = .{ .op = op, .path = path, .line = 0, .col = 0, .has_position = false };
    errdefer gpa.free(path);

    if (op != .diagnostics) {
        const line_v = obj.get("line") orelse return error.InvalidArguments;
        const col_v = obj.get("col") orelse return error.InvalidArguments;
        if (line_v != .integer or line_v.integer < 0) return error.InvalidArguments;
        if (col_v != .integer or col_v.integer < 0) return error.InvalidArguments;
        args.line = @intCast(line_v.integer);
        args.col = @intCast(col_v.integer);
        args.has_position = true;
    }
    return args;
}

// ── handler ──────────────────────────────────────────────────────────────

/// `code_intel` handler. See module docs for the full contract.
pub fn handleCodeIntel(
    ctx: tool.Context,
    instance: ?*anyopaque,
    arguments_json: []const u8,
) tool.HandlerError![]u8 {
    const state: *CodeIntelState = @ptrCast(@alignCast(instance.?));

    const args = parseArgs(ctx.allocator, arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return softError(ctx.allocator, "invalid_arguments", "invalid arguments: op must be hover|definition|references|diagnostics, path must be a non-empty relative string, and line/col (required for position ops) must be non-negative integers", .{}),
    };
    defer ctx.allocator.free(args.path);

    // Unresolved workspace root → session cannot start → `null`.
    const root = ctx.workspace_root_real orelse return nullBody(ctx.allocator);

    // Guard containment before ANY server interaction (module §3.2).
    var guard = workspace.guardFrom(ctx.allocator, ctx.io, ctx.cwd, root) catch
        return jailDeny(ctx.allocator);
    defer guard.deinit(ctx.allocator);
    guard.checkExisting(ctx.io, ctx.cwd, args.path) catch |err| switch (err) {
        error.NotFound => return nullBody(ctx.allocator), // missing file → `null`
        error.OutOfMemory => return error.OutOfMemory,
        else => return jailDeny(ctx.allocator),
    };

    // File read budget (module §3.1: 4 MiB; over → too_large, no didOpen).
    const content = ctx.cwd.readFileAlloc(ctx.io, args.path, ctx.allocator, .limited(file_read_limit)) catch |err| switch (err) {
        error.StreamTooLong => return tooLarge(ctx.allocator),
        error.OutOfMemory => return error.OutOfMemory,
        else => return softError(ctx.allocator, "tool_failed", "failed to read the requested file", .{}),
    };
    defer ctx.allocator.free(content);

    // Session (lazy start / idle / crash restart).
    const session = state.sessionFor(root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SpawnFailed, error.InitializeFailed => return nullBody(ctx.allocator),
    };
    session.touch();

    const uri_owned = buildUri(ctx, args.path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return softError(ctx.allocator, "tool_failed", "failed to resolve the requested path", .{}),
    };
    defer ctx.allocator.free(uri_owned);

    session.syncDocument(uri_owned, content) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ServerExited, error.ProtocolError => return sessionFailed(ctx, session),
        else => return softError(ctx.allocator, "tool_failed", "document sync failed", .{}),
    };

    return switch (args.op) {
        .hover => opHover(ctx, session, uri_owned, args),
        .definition => opDefinition(ctx, session, uri_owned, args),
        .references => opReferences(ctx, session, uri_owned, args),
        .diagnostics => opDiagnostics(ctx, session, uri_owned),
    };
}

fn buildUri(ctx: tool.Context, rel: []const u8) tool.HandlerError![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = ctx.cwd.realPathFile(ctx.io, rel, &buf) catch return error.ToolFailed;
    return client.uriForPath(ctx.allocator, buf[0..n]) catch return error.OutOfMemory;
}

// ── per-op implementations ───────────────────────────────────────────────

fn opHover(ctx: tool.Context, session: *client.Session, uri: []const u8, args: Args) tool.HandlerError![]u8 {
    const params = session.positionParams(uri, args.line, args.col) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sessionFailed(ctx, session),
    };
    defer ctx.allocator.free(params);

    const msg = session.request("textDocument/hover", params, session.cfg.request_deadline_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimeout => return sessionFailed(ctx, session),
        error.ServerExited, error.ProtocolError => return sessionFailed(ctx, session),
        else => return softError(ctx.allocator, "tool_failed", "hover request failed", .{}),
    };
    defer jsonrpc.deinitMessage(ctx.allocator, msg);
    if (msg != .response) return softError(ctx.allocator, "tool_failed", "protocol error: expected a response", .{});
    const resp = msg.response;
    if (resp.err) |e| return softError(ctx.allocator, "tool_failed", "server error: {s}", .{e.message});

    const result = resp.result orelse return nullBody(ctx.allocator);
    const joined = hoverContents(ctx.allocator, result) catch return error.OutOfMemory;
    defer ctx.allocator.free(joined);
    if (joined.len == 0) return nullBody(ctx.allocator);

    return okBody(ctx.allocator, "hover", joined);
}

fn opDefinition(ctx: tool.Context, session: *client.Session, uri: []const u8, args: Args) tool.HandlerError![]u8 {
    const params = session.positionParams(uri, args.line, args.col) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sessionFailed(ctx, session),
    };
    defer ctx.allocator.free(params);

    const msg = session.request("textDocument/definition", params, session.cfg.request_deadline_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimeout => return sessionFailed(ctx, session),
        error.ServerExited, error.ProtocolError => return sessionFailed(ctx, session),
        else => return softError(ctx.allocator, "tool_failed", "definition request failed", .{}),
    };
    defer jsonrpc.deinitMessage(ctx.allocator, msg);
    if (msg != .response) return softError(ctx.allocator, "tool_failed", "protocol error: expected a response", .{});
    const resp = msg.response;
    if (resp.err) |e| return softError(ctx.allocator, "tool_failed", "server error: {s}", .{e.message});

    const locations = extractLocations(ctx.allocator, resp.result) catch return error.OutOfMemory;
    defer freeLocations(ctx.allocator, locations);
    if (locations.len == 0) return nullBody(ctx.allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.allocator);
    const shown = @min(locations.len, max_definition_locations);
    for (locations[0..shown]) |loc| {
        appendLocation(ctx, session, &out, loc) catch return error.OutOfMemory;
    }
    if (locations.len > shown) {
        try appendFmt(ctx.allocator, &out, "...\n", .{});
    }
    return okBody(ctx.allocator, "definition", out.items);
}

fn opReferences(ctx: tool.Context, session: *client.Session, uri: []const u8, args: Args) tool.HandlerError![]u8 {
    const pos_params = session.positionParams(uri, args.line, args.col) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sessionFailed(ctx, session),
    };
    defer ctx.allocator.free(pos_params);
    const uri_json = jsonrpc.jsonString(ctx.allocator, uri) catch return error.OutOfMemory;
    defer ctx.allocator.free(uri_json);
    const params = std.fmt.allocPrint(ctx.allocator, "{{\"textDocument\":{{\"uri\":{s}}},\"position\":{{\"line\":{d},\"character\":{d}}},\"context\":{{\"includeDeclaration\":true}}}}", .{
        uri_json, args.line, args.col,
    }) catch return error.OutOfMemory;
    defer ctx.allocator.free(params);

    const msg = session.request("textDocument/references", params, session.cfg.request_deadline_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimeout => return sessionFailed(ctx, session),
        error.ServerExited, error.ProtocolError => return sessionFailed(ctx, session),
        else => return softError(ctx.allocator, "tool_failed", "references request failed", .{}),
    };
    defer jsonrpc.deinitMessage(ctx.allocator, msg);
    if (msg != .response) return softError(ctx.allocator, "tool_failed", "protocol error: expected a response", .{});
    const resp = msg.response;
    if (resp.err) |e| return softError(ctx.allocator, "tool_failed", "server error: {s}", .{e.message});

    const locations = extractLocations(ctx.allocator, resp.result) catch return error.OutOfMemory;
    defer freeLocations(ctx.allocator, locations);
    if (locations.len == 0) return nullBody(ctx.allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.allocator);
    const shown = @min(locations.len, max_reference_hits);
    for (locations[0..shown]) |loc| {
        appendLocation(ctx, session, &out, loc) catch return error.OutOfMemory;
    }
    if (locations.len > shown) {
        try appendFmt(ctx.allocator, &out, "...[truncated {d} more]", .{locations.len - shown});
    }
    return okBody(ctx.allocator, "references", out.items);
}

fn opDiagnostics(ctx: tool.Context, session: *client.Session, uri: []const u8) tool.HandlerError![]u8 {
    const text = session.pullDiagnostics(uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ServerExited, error.ProtocolError => return sessionFailed(ctx, session),
        else => return softError(ctx.allocator, "tool_failed", "diagnostics pull failed", .{}),
    };
    const cached = text orelse return nullBody(ctx.allocator);
    return okBody(ctx.allocator, "diagnostics", cached);
}

// ── result formatting (module §3.3 / §3.4) ───────────────────────────────

fn okBody(gpa: std.mem.Allocator, op: []const u8, content: []const u8) tool.HandlerError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendFmt(gpa, &out, "intel-v1: op={s} status=ok\n\n", .{op});
    try out.appendSlice(gpa, content);
    // Hard result-body cap (tool.max_result_bytes); explicit marker.
    if (out.items.len > tool.max_result_bytes) {
        const cut = out.items[0..tool.max_result_bytes];
        const capped = std.fmt.allocPrint(gpa, "{s}...[truncated]", .{cut}) catch return error.OutOfMemory;
        out.deinit(gpa);
        return capped;
    }
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Join hover contents (MarkupContent value or MarkedString[]), markdown
/// preserved; cap 32 KiB + marker (module §3.4).
fn hoverContents(gpa: std.mem.Allocator, result: std.json.Value) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    // Hover result: {"contents": MarkupContent | MarkedString[] | string}.
    const contents: std.json.Value = if (result == .object)
        result.object.get("contents") orelse return gpa.dupe(u8, "")
    else
        result;
    switch (contents) {
        .object => |obj| {
            if (obj.get("value")) |v| {
                if (v == .string) {
                    try out.appendSlice(gpa, v.string);
                    n += 1;
                }
            }
        },
        .array => |items| {
            for (items.items) |item| {
                switch (item) {
                    .string => |s| {
                        if (n > 0) try out.append(gpa, '\n');
                        try out.appendSlice(gpa, s);
                        n += 1;
                    },
                    .object => |o| {
                        if (o.get("value")) |v| {
                            if (v == .string) {
                                if (n > 0) try out.append(gpa, '\n');
                                try out.appendSlice(gpa, v.string);
                                n += 1;
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        .string => |s| try out.appendSlice(gpa, s),
        else => {},
    }
    if (n == 0) return gpa.dupe(u8, "");
    if (out.items.len > max_hover_bytes) {
        const cut = out.items[0..max_hover_bytes];
        const capped = try std.fmt.allocPrint(gpa, "{s}{s}", .{ cut, truncation_marker });
        out.deinit(gpa);
        return capped;
    }
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

const Location = struct {
    uri: []const u8,
    line: u32,
    col: u32,
};

/// Extract Location | Location[] | null from a response result. The uri
/// slices are borrowed from the parsed response tree; the array is owned.
fn extractLocations(gpa: std.mem.Allocator, result: ?std.json.Value) std.mem.Allocator.Error![]Location {
    var out: std.ArrayListUnmanaged(Location) = .empty;
    errdefer out.deinit(gpa);
    const r = result orelse return out.toOwnedSlice(gpa);
    switch (r) {
        .object => try appendLocationValue(gpa, &out, r),
        .array => |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                try appendLocationValue(gpa, &out, item);
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

fn appendLocationValue(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Location), v: std.json.Value) std.mem.Allocator.Error!void {
    const uri_v = v.object.get("uri") orelse return;
    if (uri_v != .string) return;
    const range_v = v.object.get("range") orelse return;
    if (range_v != .object) return;
    const start = range_v.object.get("start") orelse return;
    if (start != .object) return;
    var line: u32 = 0;
    var col: u32 = 0;
    if (start.object.get("line")) |l| {
        if (l == .integer and l.integer >= 0) line = @intCast(l.integer);
    }
    if (start.object.get("character")) |c| {
        if (c == .integer and c.integer >= 0) col = @intCast(c.integer);
    }
    try out.append(gpa, .{ .uri = uri_v.string, .line = line, .col = col });
}

fn freeLocations(gpa: std.mem.Allocator, locations: []Location) void {
    gpa.free(locations);
}

/// Append one location row: `<path>:<line+1>:<col+1>` + indented
/// in-workspace source line (module §3.4). External targets print URI only.
fn appendLocation(ctx: tool.Context, session: *client.Session, out: *std.ArrayList(u8), loc: Location) tool.HandlerError!void {
    const display = relDisplay(ctx.allocator, session.root_uri, loc.uri) orelse loc.uri;
    defer if (display.ptr != loc.uri.ptr) ctx.allocator.free(display);
    try appendFmt(ctx.allocator, out, "{s}:{d}:{d}", .{ display, loc.line + 1, loc.col + 1 });
    if (display.ptr != loc.uri.ptr) {
        if (sourceLine(ctx, session, loc.uri, loc.line)) |line| {
            defer ctx.allocator.free(line);
            try appendFmt(ctx.allocator, out, "\n  {s}", .{line});
        }
    }
    out.append(ctx.allocator, '\n') catch return error.OutOfMemory;
}

/// Read the in-workspace source line at `line` (0-based) for a location URI.
/// Bounded by the 4 MiB file budget; the copied line is capped.
fn sourceLine(ctx: tool.Context, session: *client.Session, uri: []const u8, line: u32) ?[]u8 {
    const rel = relDisplay(ctx.allocator, session.root_uri, uri) orelse return null;
    defer ctx.allocator.free(rel);
    const content = ctx.cwd.readFileAlloc(ctx.io, rel, ctx.allocator, .limited(file_read_limit)) catch return null;
    defer ctx.allocator.free(content);
    return lineAt(ctx.allocator, content, line);
}

/// Extract line `line` (0-based) from file content, capped at 1 KiB + marker.
fn lineAt(gpa: std.mem.Allocator, content: []const u8, line: u32) ?[]u8 {
    var line_no: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            if (line_no == line) break;
            line_no += 1;
            start = i + 1;
        }
    }
    if (line_no != line or i < start) return null;
    var end = i;
    if (end > start and content[end - 1] == '\r') end -= 1;
    var slice = content[start..end];
    if (slice.len > max_source_line_bytes) {
        const cut = gpa.dupe(u8, slice[0..max_source_line_bytes]) catch return null;
        defer gpa.free(cut);
        return std.fmt.allocPrint(gpa, "{s}...[truncated]", .{cut}) catch return null;
    }
    return gpa.dupe(u8, slice) catch return null;
}

/// Workspace-relative display path when the URI sits inside the root URI.
fn relDisplay(gpa: std.mem.Allocator, root_uri: []const u8, uri: []const u8) ?[]u8 {
    if (std.mem.startsWith(u8, uri, root_uri) and uri.len > root_uri.len and uri[root_uri.len] == '/') {
        return gpa.dupe(u8, uri[root_uri.len + 1 ..]) catch null;
    }
    return null;
}

// ── soft bodies ──────────────────────────────────────────────────────────

fn nullBody(gpa: std.mem.Allocator) tool.HandlerError![]u8 {
    return gpa.dupe(u8, "null") catch return error.OutOfMemory;
}

fn jailDeny(gpa: std.mem.Allocator) tool.HandlerError![]u8 {
    return workspace.deniedMessage(gpa) catch return error.OutOfMemory;
}

fn tooLarge(gpa: std.mem.Allocator) tool.HandlerError![]u8 {
    return std.fmt.allocPrint(gpa, "error: code=too_large message=file exceeds LSP read budget", .{}) catch return error.OutOfMemory;
}

fn softError(gpa: std.mem.Allocator, comptime code: []const u8, comptime fmt: []const u8, args: anytype) tool.HandlerError![]u8 {
    const message = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
    defer gpa.free(message);
    return std.fmt.allocPrint(gpa, "error: code={s} message={s}", .{ code, message }) catch return error.OutOfMemory;
}

/// tool_failed body with the bounded stderr ring tail (module §7).
fn sessionFailed(ctx: tool.Context, session: *client.Session) tool.HandlerError![]u8 {
    const tail = session.stderrTail();
    if (tail.len == 0) {
        return softError(ctx.allocator, "tool_failed", "language server session failed", .{});
    }
    return std.fmt.allocPrint(ctx.allocator, "error: code=tool_failed message=language server session failed\nstderr: {s}", .{tail}) catch return error.OutOfMemory;
}

// ── Fixture tests (module §10: mock LSP server over real pipes) ──────────

const testing_io = std.testing.io;

fn sleepMs(ms: u64) void {
    Io.sleep(testing_io, .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms }, .awake) catch {};
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    ctx: tool.Context,
    cfg_path: []u8,
    log_path: []u8,
    state: *CodeIntelState,
    /// Heap-stable argv for the mock server (the seam borrows this slice;
    /// the Fixture must not move after init).
    argv_buf: [3][]const u8 = undefined,

    fn init(self: *Fixture, gpa: std.mem.Allocator, io: Io, config: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        const root = try workspace.resolveCwdReal(gpa, io, self.tmp.dir);
        errdefer gpa.free(root);
        const cfg_path = try std.fmt.allocPrint(gpa, "{s}/cfg.json", .{root});
        errdefer gpa.free(cfg_path);
        const log_path = try std.fmt.allocPrint(gpa, "{s}/log.jsonl", .{root});
        errdefer gpa.free(log_path);
        // Config gets the log path injected; "__ROOT_URI__" is replaced with
        // the real workspace root URI (fixture locations use it).
        const root_uri = try client.uriForPath(gpa, root);
        defer gpa.free(root_uri);
        const cfg_body = config[0 .. config.len - 1]; // drop trailing '}'
        const cfg_json0 = if (std.mem.eql(u8, cfg_body, "{"))
            try std.fmt.allocPrint(gpa, "{{\"log_path\": \"{s}\"}}", .{log_path})
        else
            try std.fmt.allocPrint(gpa, "{s},\"log_path\": \"{s}\"}}", .{ cfg_body, log_path });
        defer gpa.free(cfg_json0);
        const cfg_json = try std.mem.replaceOwned(u8, gpa, cfg_json0, "__ROOT_URI__", root_uri);
        defer gpa.free(cfg_json);
        try self.tmp.dir.writeFile(io, .{ .sub_path = "cfg.json", .data = cfg_json });
        try self.tmp.dir.createDirPath(io, "src");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "line zero\nline one\nline two\n" });

        const state = try gpa.create(CodeIntelState);
        errdefer gpa.destroy(state);
        state.* = .{ .gpa = gpa, .io = io };

        self.* = .{
            .tmp = self.tmp,
            .root = root,
            .ctx = .{ .allocator = gpa, .io = io, .cwd = self.tmp.dir, .workspace_root_real = root },
            .cfg_path = cfg_path,
            .log_path = log_path,
            .state = state,
        };
        // Absolute interpreter: the test binary's environ is not guaranteed
        // to carry PATH (default_PATH lacks Homebrew), so resolve python3
        // deterministically (/usr/bin/python3 exists on macOS + Linux CI).
        // The mock is embedded at compile time and written into the
        // workspace root so the RELATIVE argv resolves under the client's
        // spawn cwd (the workspace root) — no runtime path resolution.
        try self.tmp.dir.writeFile(io, .{ .sub_path = "mock_lsp_server.py", .data = mock_source });
        self.argv_buf = .{ "/usr/bin/python3", "mock_lsp_server.py", cfg_path };

        testing.reset();
        testing.setServerArgv(&self.argv_buf);
        testing.setDeadlines(8_000, 3_000, 2_000);
        testing.setTeardownGraceMs(60);
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.state.deinit();
        gpa.destroy(self.state);
        gpa.free(self.cfg_path);
        gpa.free(self.log_path);
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn call(self: *Fixture, args: []const u8) ![]u8 {
        return handleCodeIntel(self.ctx, self.state, args);
    }

    /// Re-point the global test seam at this fixture (needed when several
    /// fixtures exist; the seam holds one argv at a time).
    fn arm(self: *Fixture) void {
        testing.setServerArgv(&self.argv_buf);
    }

    fn readLog(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing_io, "log.jsonl", self.ctx.allocator, .limited(256 * 1024));
    }

    fn startCount(log: []const u8) usize {
        return std.mem.count(u8, log, "\"event\": \"start\"");
    }
};

fn hoverArgs(gpa: std.mem.Allocator, path: []const u8, line: u32, col: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"op\":\"hover\",\"path\":\"{s}\",\"line\":{d},\"col\":{d}}}", .{ path, line, col });
}

test "lsp-001 class 1+14: happy hover with initialize handshake and position mapping" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"hover_text\":\"mock hover\",\"echo_position\":true}");
    defer fx.deinit(gpa);

    const args = try hoverArgs(gpa, "src/a.zig", 2, 3);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);

    const log_debug = fx.readLog() catch "no-log";
    defer if (log_debug.len > 0 and log_debug.ptr != "no-log".ptr) gpa.free(log_debug);

    try std.testing.expectEqualStrings("intel-v1: op=hover status=ok\n\npos=2:3 mock hover", body);

    const log = try fx.readLog();
    defer gpa.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"event\": \"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"event\": \"textDocument/didOpen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"event\": \"textDocument/hover\"") != null);
}

test "lsp-001 class 2: definition renders path line col and in-workspace source line" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"definition_hits\":[{\"uri\":\"__ROOT_URI__/src/a.zig\",\"line\":1,\"character\":2}]}");
    defer fx.deinit(gpa);
    const args = try std.fmt.allocPrint(gpa, "{{\"op\":\"definition\",\"path\":\"src/a.zig\",\"line\":0,\"col\":0}}", .{});
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "intel-v1: op=definition status=ok\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "src/a.zig:2:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "line one") != null);
}

test "lsp-001 class 3: references list hits and truncates beyond 50" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"reference_hits\":{\"count\":55,\"uri\":\"__ROOT_URI__/src/a.zig\",\"start_line\":0}}");
    defer fx.deinit(gpa);
    const args = try std.fmt.allocPrint(gpa, "{{\"op\":\"references\",\"path\":\"src/a.zig\",\"line\":0,\"col\":0}}", .{});
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "intel-v1: op=references status=ok\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "...[truncated 5 more]") != null);
    try std.testing.expect(std.mem.count(u8, body, "src/a.zig:") == 50);
}

test "lsp-001 class 4: diagnostics pulled after didOpen then served from cache" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"diag_count\":2,\"diag_text\":\"mock diag\"}");
    defer fx.deinit(gpa);
    const args = "{\"op\":\"diagnostics\",\"path\":\"src/a.zig\"}";
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "intel-v1: op=diagnostics status=ok\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "error: src/a.zig:1:1: mock diag 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "error: src/a.zig:2:1: mock diag 1") != null);

    // Second call: served from the cache (no new publish).
    const body2 = try fx.call(args);
    defer gpa.free(body2);
    try std.testing.expectEqualStrings(body, body2);
    const log = try fx.readLog();
    defer gpa.free(log);
    try std.testing.expect(std.mem.count(u8, log, "publishDiagnostics") == 1);
}

test "lsp-001 class 13: empty diagnostics cache after wait budget returns null" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"no_diagnostics\":true}");
    defer fx.deinit(gpa);
    const body = try fx.call("{\"op\":\"diagnostics\",\"path\":\"src/a.zig\"}");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("null", body);
}

test "lsp-001 class 5: server not found returns exact null body" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    testing.setServerPath("/nonexistent/zls-missing-xyz");
    testing.setServerArgv(&.{"zls-missing-xyz"});
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("null", body);
}

test "lsp-001 class 6: crash mid-request fails soft with stderr tail and restarts" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"crash_after_requests\":1,\"crash_stderr\":\"mock crash boom\"}");
    defer fx.deinit(gpa);

    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "error: code=tool_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mock crash boom") != null);

    // Next call restarts with a fresh config (one-shot crash).
    const cfg2 = try std.fmt.allocPrint(gpa, "{{\"hover_text\":\"after\",\"log_path\":\"{s}\"}}", .{fx.log_path});
    defer gpa.free(cfg2);
    try fx.tmp.dir.writeFile(testing_io, .{ .sub_path = "cfg.json", .data = cfg2 });
    const body2 = try fx.call(args);
    defer gpa.free(body2);
    try std.testing.expect(std.mem.startsWith(u8, body2, "intel-v1: op=hover status=ok"));
    const log = try fx.readLog();
    defer gpa.free(log);
    try std.testing.expectEqual(@as(usize, 2), Fixture.startCount(log));
}

test "lsp-001 class 7: response timeout fails bounded tool_failed and tears down" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"ignore_methods\":[\"textDocument/hover\"]}");
    defer fx.deinit(gpa);
    testing.setDeadlines(8_000, 400, 2_000);

    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "error: code=tool_failed") != null);

    // Session was torn down; a fresh config lets the next call succeed.
    const cfg2 = try std.fmt.allocPrint(gpa, "{{\"hover_text\":\"after\",\"log_path\":\"{s}\"}}", .{fx.log_path});
    defer gpa.free(cfg2);
    try fx.tmp.dir.writeFile(testing_io, .{ .sub_path = "cfg.json", .data = cfg2 });
    const body2 = try fx.call(args);
    defer gpa.free(body2);
    try std.testing.expect(std.mem.startsWith(u8, body2, "intel-v1: op=hover status=ok"));
    const log = try fx.readLog();
    defer gpa.free(log);
    try std.testing.expectEqual(@as(usize, 2), Fixture.startCount(log));
}

test "lsp-001 class 8: idle timeout kills the child and the next call restarts" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    testing.setIdleTimeoutMs(300);

    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    if (fx.readLog()) |lg| {
            gpa.free(lg);
    } else |_| {
        }
    try std.testing.expect(std.mem.startsWith(u8, body, "intel-v1: op=hover status=ok"));

    sleepMs(450);
    const body2 = try fx.call(args);
    defer gpa.free(body2);
    try std.testing.expect(std.mem.startsWith(u8, body2, "intel-v1: op=hover status=ok"));

    const log = try fx.readLog();
    defer gpa.free(log);
    try std.testing.expectEqual(@as(usize, 2), Fixture.startCount(log));
    try std.testing.expect(std.mem.indexOf(u8, log, "\"event\": \"exit\"") != null);
}

test "lsp-001 class 9: jail escape denies without spawning" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "../escape.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=jail_deny") != null);
    // No spawn: the mock log file was never created.
    try std.testing.expectError(error.FileNotFound, fx.readLog());
}

test "lsp-001 class 10: invalid args fail with invalid_arguments" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);

    const cases = [_][]const u8{
        "{\"op\":\"rename\",\"path\":\"src/a.zig\"}",
        "{\"path\":\"src/a.zig\"}",
        "{\"op\":\"hover\",\"path\":\"src/a.zig\",\"line\":-1,\"col\":0}",
        "{\"op\":\"hover\",\"path\":\"src/a.zig\",\"line\":0}",
        "{\"op\":\"hover\",\"path\":\"src/a.zig\",\"line\":0,\"col\":\"x\"}",
        "not-json",
    };
    for (cases) |c| {
        const body = try fx.call(c);
        defer gpa.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "code=invalid_arguments") != null);
    }
}

test "lsp-001 class 11: file over 4 MiB fails too_large with no open" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    var big: [client.max_file_bytes + 1]u8 = undefined;
    @memset(&big, 'x');
    try fx.tmp.dir.writeFile(testing_io, .{ .sub_path = "big.zig", .data = &big });
    const args = try hoverArgs(gpa, "big.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("error: code=too_large message=file exceeds LSP read budget", body);
    // No spawn, no didOpen.
    try std.testing.expectError(error.FileNotFound, fx.readLog());
}

test "lsp-001 class 12: hover budget capped with marker" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"huge_hover\":true}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "...[truncated]") != null);
    try std.testing.expect(body.len <= max_hover_bytes + 64);
}

test "lsp-001 class 12: diagnostics over 200 entries capped with marker" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"diag_count\":250,\"diag_text\":\"d\"}");
    defer fx.deinit(gpa);
    const body = try fx.call("{\"op\":\"diagnostics\",\"path\":\"src/a.zig\"}");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "...[truncated]") != null);
    try std.testing.expect(std.mem.count(u8, body, "error: ") == 200);
}

test "lsp-001 class 12: message over 8 MiB is a bounded protocol error" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"huge_message\":true}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=tool_failed") != null);
}

test "lsp-001 class 13: empty hover answer returns null" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{\"empty_hover\":true}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("null", body);
}

test "lsp-001 class 14: multi-root isolation keeps one session per root" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);

    // Second workspace root (own tmp dir + config + log).
    var fx2: Fixture = undefined;
    try fx2.init(gpa, testing_io, "{}");
    defer fx2.deinit(gpa);

    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    fx.arm();
    const b1 = try fx.call(args);
    defer gpa.free(b1);
    fx2.arm();
    const b2 = try fx2.call(args);
    defer gpa.free(b2);
    fx.arm();
    const b3 = try fx.call(args);
    defer gpa.free(b3);
    try std.testing.expect(std.mem.startsWith(u8, b1, "intel-v1"));
    try std.testing.expect(std.mem.startsWith(u8, b2, "intel-v1"));
    try std.testing.expectEqualStrings(b1, b3);

    const log1 = try fx.readLog();
    defer gpa.free(log1);
    const log2 = try fx2.readLog();
    defer gpa.free(log2);
    try std.testing.expectEqual(@as(usize, 1), Fixture.startCount(log1));
    try std.testing.expectEqual(@as(usize, 1), Fixture.startCount(log2));
}

test "lsp-001 class 14: Agent-owned state deinit kills the server child" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "intel-v1"));

    // Capture the child pid from the log, then deinit the state.
    const log = try fx.readLog();
    defer gpa.free(log);
    const pid_start = std.mem.indexOf(u8, log, "\"pid\": ") orelse return error.TestUnexpectedResult;
    const pid = try std.fmt.parseInt(std.posix.pid_t, log[pid_start + 7 .. std.mem.indexOfScalar(u8, log[pid_start..], '}').? + pid_start], 10);

    fx.state.deinit();
    fx.state.* = .{ .gpa = gpa, .io = testing_io };
    // Child must be gone (reaped).
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, std.posix.SIG.INT));
    // Graceful shutdown path ran: the mock logged exit.
    const log2 = try fx.readLog();
    defer gpa.free(log2);
    try std.testing.expect(std.mem.indexOf(u8, log2, "\"event\": \"exit\"") != null);
}

test "lsp-001 class 14: tool args are redacted through the trace" {
    const gpa = std.testing.allocator;
    const redact_mod = @import("../redact.zig");
    const trace_mod = @import("../trace.zig");
    const secret = redact_mod.testing.fake_api_key;
    var r = try redact_mod.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = false });
    defer r.deinit();
    var tr = trace_mod.Trace.init(gpa, testing_io, null, Io.Dir.cwd());
    defer tr.deinit();
    tr.setRedactor(&r);
    try tr.beginReply();
    const args = try std.fmt.allocPrint(gpa, "{{\"op\":\"hover\",\"path\":\"{s}\",\"line\":0,\"col\":0}}", .{secret});
    defer gpa.free(args);
    try tr.emitToolCall(.{ .id = "ci-1", .name = "code_intel", .arguments = args });
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, redact_mod.marker) != null);
}

test "lsp-001 class 14: unresolved workspace root returns null" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    fx.ctx.workspace_root_real = null;
    const args = try hoverArgs(gpa, "src/a.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("null", body);
}

test "lsp-001 class 14: missing file returns null without spawning" {
    const gpa = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, testing_io, "{}");
    defer fx.deinit(gpa);
    const args = try hoverArgs(gpa, "no_such.zig", 0, 0);
    defer gpa.free(args);
    const body = try fx.call(args);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("null", body);
    try std.testing.expectError(error.FileNotFound, fx.readLog());
}
