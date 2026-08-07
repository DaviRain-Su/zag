//! ACP (Agent Client Protocol) v1 wire types (zag-cli, acp.md §5-§6).
//!
//! Newline-delimited JSON-RPC 2.0 — one object per `\n`-terminated line
//! (acp.md §4; the line discipline itself lives in the reused
//! `rpc/framing.zig`, imported read-only). This module owns the JSON-RPC 2.0
//! envelope (`jsonrpc: "2.0"`, string-or-number ids echoed verbatim, numeric
//! error codes), the frozen v1 method subset (§6), the error model (§11) and
//! the budgets (§12). Pure — no IO; unit-testable without a process.
//!
//! Frame kinds (client → server):
//!   request      — id + method + params (id is a string or integer, echoed)
//!   notification — method + params, NO id (never answered; unknown methods
//!                  silently ignored — JSON-RPC rule, also how `initialized`
//!                  and unknown extensions are tolerated)
//!   response     — id + result/error, NO method: the client's answer to the
//!                  adapter's `session/request_permission` request (§9)
//!   reject       — envelope/param-level error; answered with the echoed id
//!                  (null when the id cannot be trusted)
//!   ignore       — unknown notification or unmatched response: no reply

const std = @import("std");

// ── Versioning and session identity (acp.md §4, §7) ─────────────────────────

/// Negotiated once in `initialize`; no per-frame version field.
pub const protocol_version: i64 = 1;
/// The adapter's opaque single-row session id (never a path, acp.md §7).
pub const session_id = "sess_1";

// ── Budgets (acp.md §12, checked arithmetic) ────────────────────────────────

/// Flattened prompt text cap (inbound; `-32602` beyond).
pub const prompt_max_bytes: usize = 1024 * 1024;
/// `session/steer` text cap (= `control_queue.message_max_bytes`,
/// wire-enforced; `-32003` beyond).
pub const steer_max_bytes: usize = 4096;
/// `session/request_permission.toolCall.fields` cap (excess → truncation marker).
pub const permission_fields_max_bytes: usize = 64 * 1024;
/// Literal truncation marker appended to capped fields.
pub const truncation_marker = "...[truncated]";

// ── Error model (acp.md §11) ────────────────────────────────────────────────

/// Frozen JSON-RPC 2.0 + application error codes.
pub const ErrorCode = enum(i64) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    run_error = -32000,
    busy = -32001,
    queue_full = -32002,
    message_too_long = -32003,

    pub fn code(self: ErrorCode) i64 {
        return @intFromEnum(self);
    }
};

/// The wire error object (response `error`).
pub const ErrorObj = struct {
    code: i64,
    message: []const u8,
};

pub fn errorOf(code: ErrorCode, message: []const u8) ErrorObj {
    return .{ .code = code.code(), .message = message };
}

// ── Ids (acp.md §5) ─────────────────────────────────────────────────────────

/// JSON-RPC id: string or integer, echoed verbatim; `null` only on
/// envelope-level rejections (parse/invalid-request). `.string` is owned.
pub const Id = union(enum) {
    int: i64,
    string: []const u8,
    null_val,

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .int => |v| try jw.write(v),
            .string => |s| try jw.write(s),
            .null_val => try jw.write(null),
        }
    }

    pub fn clone(self: Id, gpa: std.mem.Allocator) std.mem.Allocator.Error!Id {
        return switch (self) {
            .int => |v| .{ .int = v },
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            .null_val => .null_val,
        };
    }

    pub fn deinit(self: *Id, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| gpa.free(s),
            else => {},
        }
        self.* = undefined;
    }
};

// ── Methods (acp.md §6.1) ───────────────────────────────────────────────────

pub const Method = enum {
    initialize,
    @"session/new",
    @"session/prompt",
    @"session/cancel",
    @"session/list",
    @"session/steer",
    @"authentication/getUser",
    ping,

    pub fn parse(s: []const u8) ?Method {
        inline for (std.meta.fields(Method)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

// ── Per-method params (owned string slices; call `Params.deinit`) ──────────

pub const InitializeParams = struct {
    /// Integer `protocolVersion` from the client. The adapter answers `1`
    /// and rejects nothing on the envelope (acp.md §4).
    protocol_version: i64,
};

pub const SessionNewParams = struct {
    cwd: []const u8,
    mcp_servers_nonempty: bool = false,
    additional_dirs_nonempty: bool = false,
    prompt_present: bool = false,
};

pub const SessionPromptParams = struct {
    session_id: []const u8,
    /// Flattened prompt text (text + resource-with-inline-text blocks).
    /// `allowInterruptions` / `maxTurns` / `canUseMcp` are accepted and
    /// ignored in v1 (acp.md §7, §17 q.3-4) — not surfaced here.
    prompt_text: []const u8,
};

pub const SessionIdParams = struct {
    session_id: []const u8,
};

pub const SteerParams = struct {
    session_id: []const u8,
    text: []const u8,
    interjection_id: ?[]const u8 = null,
};

pub const Params = union(Method) {
    initialize: InitializeParams,
    @"session/new": SessionNewParams,
    @"session/prompt": SessionPromptParams,
    @"session/cancel": SessionIdParams,
    @"session/list": void,
    @"session/steer": SteerParams,
    @"authentication/getUser": void,
    ping: void,

    pub fn deinit(self: *Params, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .initialize => {},
            .@"session/new" => |p| gpa.free(p.cwd),
            .@"session/prompt" => |p| {
                gpa.free(p.session_id);
                gpa.free(p.prompt_text);
            },
            .@"session/cancel" => |p| gpa.free(p.session_id),
            .@"session/list" => {},
            .@"session/steer" => |p| {
                gpa.free(p.session_id);
                gpa.free(p.text);
                if (p.interjection_id) |i| gpa.free(i);
            },
            .@"authentication/getUser" => {},
            .ping => {},
        }
        self.* = undefined;
    }
};

// ── Client → server frames ──────────────────────────────────────────────────

pub const Request = struct {
    id: Id,
    method: Method,
    params: Params,
};

pub const Notification = struct {
    method: Method,
    params: Params,
};

/// Outcome carried by a client response to `session/request_permission`
/// (acp.md §9). `.option` owns the optionId string.
pub const PermissionOutcome = union(enum) {
    option: []const u8,
    cancelled,
    /// Malformed / error response to a permission request: fail closed (deny).
    invalid,

    pub fn deinit(self: *PermissionOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .option => |s| gpa.free(s),
            else => {},
        }
        self.* = undefined;
    }
};

pub const Response = struct {
    id: Id,
    outcome: PermissionOutcome,
};

pub const Reject = struct {
    id: Id,
    code: ErrorCode,
    message: []const u8,

    pub fn deinit(self: *Reject, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.* = undefined;
    }
};

pub const Frame = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    reject: Reject,
    ignore,

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .request => |*r| {
                r.id.deinit(gpa);
                r.params.deinit(gpa);
            },
            .notification => |*n| n.params.deinit(gpa),
            .response => |*r| {
                r.id.deinit(gpa);
                r.outcome.deinit(gpa);
            },
            .reject => |*r| r.deinit(gpa),
            .ignore => {},
        }
        self.* = undefined;
    }
};

fn reject(id: Id, code: ErrorCode, message: []const u8) Frame {
    return .{ .reject = .{ .id = id, .code = code, .message = message } };
}

fn rejectNull(code: ErrorCode, message: []const u8) Frame {
    return reject(.null_val, code, message);
}

/// Parse one inbound line into a Frame. All string slices in the returned
/// frame are gpa-owned (call `Frame.deinit`).
pub fn parseFrame(gpa: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!Frame {
    if (line.len == 0) return rejectNull(.parse_error, "parse error: empty frame");
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
        return rejectNull(.parse_error, "parse error: invalid JSON");
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return rejectNull(.invalid_request, "invalid request: frame must be a JSON object");

    const jr = root.object.get("jsonrpc") orelse
        return rejectNull(.invalid_request, "invalid request: missing jsonrpc");
    if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) {
        return rejectNull(.invalid_request, "invalid request: jsonrpc must be \"2.0\"");
    }

    const method = root.object.get("method");
    if (method != null) {
        // Request or notification.
        if (method.? != .string) {
            const id = (try parseId(gpa, root.object.get("id"))) orelse Id.null_val;
            return reject(id, .invalid_request, "invalid request: method must be a string");
        }
        const m = Method.parse(method.?.string) orelse {
            // Unknown method: request → -32601 (echo id); notification →
            // silently ignored (JSON-RPC rule; also `initialized` and
            // ecosystem extensions we do not implement).
            const idv_unknown = root.object.get("id");
            if (idv_unknown == null or idv_unknown.? == .null) return .{ .ignore = {} };
            const id = (try parseId(gpa, idv_unknown)) orelse Id.null_val;
            return reject(id, .method_not_found, "method not found");
        };
        const idv = root.object.get("id");
        const is_request = idv != null and idv.? != .null;
        if (!is_request) {
            // Notification. Params are validated best-effort; a malformed
            // notification is ignored (no response channel exists).
            const params = parseParams(gpa, m, root.object) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidParams, error.MessageTooLong => return .{ .ignore = {} },
            };
            return .{ .notification = .{ .method = m, .params = params } };
        }
        const id = (try parseId(gpa, idv)) orelse
            return rejectNull(.invalid_request, "invalid request: id must be a string or integer");
        const params = parseParams(gpa, m, root.object) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidParams => return reject(id, .invalid_params, "invalid params"),
            error.MessageTooLong => return reject(id, .message_too_long, "steer text exceeds the 4096 B cap"),
        };
        return .{ .request = .{ .id = id, .method = m, .params = params } };
    }

    // No method: client response (permission outcome). Unmatched ids are
    // ignored server-side; a response without a trustworthy id is unmatched.
    const id = (try parseId(gpa, root.object.get("id"))) orelse return .{ .ignore = {} };
    const outcome = try parsePermissionOutcome(gpa, root.object);
    return .{ .response = .{ .id = id, .outcome = outcome } };
}

const ParseError = error{ OutOfMemory, InvalidParams, MessageTooLong };

fn parseParams(
    gpa: std.mem.Allocator,
    method: Method,
    root: std.json.ObjectMap,
) ParseError!Params {
    const p = root.get("params");
    var obj: ?std.json.ObjectMap = null;
    if (p) |pv| {
        if (pv != .object) return error.InvalidParams;
        obj = pv.object;
    }
    const empty = std.json.ObjectMap{};
    const o = obj orelse empty;

    const params: Params = switch (method) {
        .initialize => blk: {
            const pv = o.get("protocolVersion") orelse
                return error.InvalidParams;
            if (pv != .integer) return error.InvalidParams;
            break :blk .{ .initialize = .{ .protocol_version = pv.integer } };
        },
        .@"session/new" => blk: {
            const cwd = getString(o, "cwd") orelse
                return error.InvalidParams;
            var mcp_nonempty = false;
            if (o.get("mcpServers")) |v| {
                if (v != .array) return error.InvalidParams;
                mcp_nonempty = v.array.items.len > 0;
            }
            var dirs_nonempty = false;
            if (o.get("additionalDirectories")) |v| {
                if (v != .array) return error.InvalidParams;
                dirs_nonempty = v.array.items.len > 0;
            }
            break :blk .{ .@"session/new" = .{
                .cwd = try gpa.dupe(u8, cwd),
                .mcp_servers_nonempty = mcp_nonempty,
                .additional_dirs_nonempty = dirs_nonempty,
                .prompt_present = o.get("prompt") != null,
            } };
        },
        .@"session/prompt" => blk: {
            const sid = getString(o, "sessionId") orelse
                return error.InvalidParams;
            const prompt = o.get("prompt") orelse
                return error.InvalidParams;
            if (prompt != .array) return error.InvalidParams;
            const text = try flattenPrompt(gpa, prompt.array.items, prompt_max_bytes);
            if (text.len == 0) {
                gpa.free(text);
                return error.InvalidParams;
            }
            break :blk .{ .@"session/prompt" = .{
                .session_id = try gpa.dupe(u8, sid),
                .prompt_text = text,
            } };
        },
        .@"session/cancel" => blk: {
            const sid = getString(o, "sessionId") orelse
                return error.InvalidParams;
            break :blk .{ .@"session/cancel" = .{ .session_id = try gpa.dupe(u8, sid) } };
        },
        .@"session/list" => .{ .@"session/list" = {} },
        .@"session/steer" => blk: {
            const sid = getString(o, "sessionId") orelse
                return error.InvalidParams;
            const text = getString(o, "text") orelse
                return error.InvalidParams;
            if (text.len == 0) return error.InvalidParams;
            if (text.len > steer_max_bytes) return error.MessageTooLong;
            const interjection = if (o.get("interjectionId")) |iv| blk2: {
                if (iv != .string) return error.InvalidParams;
                break :blk2 try gpa.dupe(u8, iv.string);
            } else null;
            break :blk .{ .@"session/steer" = .{
                .session_id = try gpa.dupe(u8, sid),
                .text = try gpa.dupe(u8, text),
                .interjection_id = interjection,
            } };
        },
        .@"authentication/getUser" => .{ .@"authentication/getUser" = {} },
        .ping => .{ .ping = {} },
    };
    return params;
}

/// Flatten ACP prompt ContentBlocks into one text string (acp.md §8, §6.1):
/// `text` blocks concatenated; `resource` blocks flattened when they carry
/// inline text (a `text` field or `contents` with text items); `image` and
/// any other block type → InvalidParams. The result is capped at `cap`
/// (checked during accumulation).
fn flattenPrompt(
    gpa: std.mem.Allocator,
    blocks: []std.json.Value,
    cap: usize,
) ParseError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (blocks) |block| {
        if (block != .object) return error.InvalidParams;
        const ty = block.object.get("type") orelse return error.InvalidParams;
        if (ty != .string) return error.InvalidParams;
        if (std.mem.eql(u8, ty.string, "text")) {
            const t = block.object.get("text") orelse return error.InvalidParams;
            if (t != .string) return error.InvalidParams;
            if (out.items.len + t.string.len > cap) return error.InvalidParams;
            try out.appendSlice(gpa, t.string);
        } else if (std.mem.eql(u8, ty.string, "resource")) {
            try appendResourceText(gpa, &out, block.object, cap);
        } else if (std.mem.eql(u8, ty.string, "image")) {
            return error.InvalidParams;
        } else {
            return error.InvalidParams;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn appendResourceText(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: std.json.ObjectMap,
    cap: usize,
) ParseError!void {
    const res = block.get("resource") orelse return error.InvalidParams;
    if (res != .object) return error.InvalidParams;
    if (res.object.get("text")) |t| {
        if (t != .string) return error.InvalidParams;
        if (out.items.len + t.string.len > cap) return error.InvalidParams;
        try out.appendSlice(gpa, t.string);
        return;
    }
    const contents = res.object.get("contents") orelse return error.InvalidParams;
    if (contents != .array) return error.InvalidParams;
    for (contents.array.items) |item| {
        if (item != .object) return error.InvalidParams;
        const ty = item.object.get("type") orelse return error.InvalidParams;
        if (ty != .string or !std.mem.eql(u8, ty.string, "text")) return error.InvalidParams;
        const t = item.object.get("text") orelse return error.InvalidParams;
        if (t != .string) return error.InvalidParams;
        if (out.items.len + t.string.len > cap) return error.InvalidParams;
        try out.appendSlice(gpa, t.string);
    }
}

/// Parse the client's permission outcome from a response frame: a
/// `result.outcome` object carrying `optionId`, a `result.outcome` string
/// `"cancelled"`, or anything else (including an error response) → `.invalid`
/// (the server resolves the gate as deny, acp.md §9).
fn parsePermissionOutcome(
    gpa: std.mem.Allocator,
    root: std.json.ObjectMap,
) std.mem.Allocator.Error!PermissionOutcome {
    const result = root.get("result") orelse return .invalid;
    if (result != .object) return .invalid;
    const outcome = result.object.get("outcome") orelse return .invalid;
    if (outcome == .string) {
        if (std.mem.eql(u8, outcome.string, "cancelled")) return .cancelled;
        return .invalid;
    }
    if (outcome != .object) return .invalid;
    const opt = outcome.object.get("optionId") orelse return .invalid;
    if (opt != .string) return .invalid;
    return .{ .option = try gpa.dupe(u8, opt.string) };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Parse an id value: string or integer (owned string). Invalid shapes
/// return null (the caller decides: reject -32600 or ignore).
fn parseId(gpa: std.mem.Allocator, v: ?std.json.Value) std.mem.Allocator.Error!?Id {
    const val = v orelse return null;
    return switch (val) {
        .integer => |n| .{ .int = n },
        .string => |s| .{ .string = try gpa.dupe(u8, s) },
        else => null,
    };
}

// ── Server → client serialization (acp.md §5, §6.2) ─────────────────────────

/// Server response envelope. Exactly one of `result` / `error` is non-null;
/// the other is omitted (`emit_null_optional_fields = false`).
pub fn ServerResponse(comptime ResultT: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: Id,
        result: ?ResultT = null,
        @"error": ?ErrorObj = null,
    };
}

/// Server notification envelope (session/update).
pub fn ServerNotification(comptime ParamsT: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: ParamsT,
    };
}

/// Agent → client request envelope (session/request_permission, acp.md §9).
/// The adapter's own id counter is used (separate namespace from client ids).
pub fn ServerRequest(comptime ParamsT: type) type {
    return struct {
        jsonrpc: []const u8 = "2.0",
        id: Id,
        method: []const u8,
        params: ParamsT,
    };
}

pub const InitializeResult = struct {
    protocolVersion: i64 = protocol_version,
    agentCapabilities: AgentCapabilities,
    agentInfo: AgentInfo,
    authMethods: []const []const u8 = &.{},
};

pub const AgentCapabilities = struct {
    sessionCapabilities: SessionCapabilities,
};

pub const SessionCapabilities = struct {
    list: ListCap = .{},
};

/// `{}` — the list capability is present, session/load etc. are not
/// advertised (acp.md §6.1).
pub const ListCap = struct {};

pub const AgentInfo = struct {
    name: []const u8,
    title: []const u8,
    version: []const u8,
};

pub const SessionNewResult = struct {
    sessionId: []const u8,
};

pub const PromptResult = struct {
    stopReason: []const u8,
};

pub const SessionRow = struct {
    sessionId: []const u8,
    cwd: []const u8,
};

pub const SessionListResult = struct {
    sessions: []const SessionRow,
};

pub const SteerResult = struct {
    status: []const u8 = "queued",
    interjectionId: []const u8,
};

pub const EmptyResult = struct {};

/// `authentication/getUser` stub: zag has no user concept. `userId` and
/// `userName` must be present with explicit null values (the general
/// serializer omits null optionals), so this type writes itself.
pub const GetUserResult = struct {
    pub fn jsonStringify(self: GetUserResult, jw: anytype) !void {
        _ = self;
        try jw.beginObject();
        try jw.objectField("userId");
        try jw.write(null);
        try jw.objectField("userName");
        try jw.write(null);
        try jw.endObject();
    }
};

// ── session/update variants (acp.md §8) ─────────────────────────────────────

pub const TextContent = struct {
    @"type": []const u8 = "text",
    text: []const u8,
};

pub const ToolCallFrame = struct {
    toolCallId: []const u8,
    title: []const u8,
    kind: []const u8 = "other",
    status: []const u8 = "pending",
};

pub const ToolCallContentItem = struct {
    @"type": []const u8 = "content",
    content: TextContent,
};

pub const ToolCallUpdateFrame = struct {
    toolCallId: []const u8,
    status: []const u8,
    /// Omitted when the tool body is empty (acp.md §8).
    content: ?[]const ToolCallContentItem = null,
};

/// One `session/update` payload. Serialized as an object with the
/// discriminant field `sessionUpdate` followed by the variant fields.
pub const Update = union(enum) {
    agent_message_chunk: TextContent,
    agent_thought_chunk: TextContent,
    tool_call: ToolCallFrame,
    tool_call_update: ToolCallUpdateFrame,

    pub fn jsonStringify(self: Update, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write(@tagName(self));
        switch (self) {
            .agent_message_chunk => |c| {
                try jw.objectField("content");
                try jw.write(c);
            },
            .agent_thought_chunk => |c| {
                try jw.objectField("content");
                try jw.write(c);
            },
            .tool_call => |t| {
                try jw.objectField("toolCallId");
                try jw.write(t.toolCallId);
                try jw.objectField("title");
                try jw.write(t.title);
                try jw.objectField("kind");
                try jw.write(t.kind);
                try jw.objectField("status");
                try jw.write(t.status);
            },
            .tool_call_update => |t| {
                try jw.objectField("toolCallId");
                try jw.write(t.toolCallId);
                try jw.objectField("status");
                try jw.write(t.status);
                if (t.content) |c| {
                    try jw.objectField("content");
                    try jw.write(c);
                }
            },
        }
        try jw.endObject();
    }
};

pub const UpdateParams = struct {
    sessionId: []const u8,
    update: Update,
};

// ── session/request_permission (acp.md §6.2, §9) ────────────────────────────

pub const PermissionOption = struct {
    id: []const u8,
    kind: []const u8,
};

pub const ToolCall = struct {
    toolCallId: []const u8,
    title: []const u8,
    kind: []const u8 = "other",
    /// Redacted raw arguments (string, ≤ 64 KiB + marker; acp.md §13.3).
    fields: []const u8,
};

pub const PermissionRequestParams = struct {
    sessionId: []const u8,
    toolCall: ToolCall,
    options: [4]PermissionOption,
};

pub const PermissionOptionSpec = struct {
    id: []const u8,
    kind: []const u8,
};

pub const permission_options: [4]PermissionOptionSpec = .{
    .{ .id = "allow_once", .kind = "allow_once" },
    .{ .id = "allow_always", .kind = "allow_always" },
    .{ .id = "reject_once", .kind = "reject_once" },
    .{ .id = "reject_always", .kind = "reject_always" },
};

/// Serialize `value` as a compact JSON object into `out`. The result is one
/// NDJSON line body (no trailing newline; framing adds it).
pub fn stringify(value: anytype, out: *std.Io.Writer.Allocating) error{OutOfMemory}!void {
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    json.write(value) catch return error.OutOfMemory;
}

/// Cap `text` at `cap` bytes appending `truncation_marker` when truncated.
/// Returns a gpa-owned slice.
pub fn capText(
    gpa: std.mem.Allocator,
    text: []const u8,
    cap: usize,
) std.mem.Allocator.Error![]u8 {
    if (text.len <= cap) return gpa.dupe(u8, text);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text[0..cap]);
    try out.appendSlice(gpa, truncation_marker);
    return out.toOwnedSlice(gpa);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseOk(gpa: std.mem.Allocator, line: []const u8) !Frame {
    var frame = try parseFrame(gpa, line);
    if (frame == .reject) {
        frame.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    return frame;
}

test "parseFrame initialize request" {
    const gpa = testing.allocator;
    var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientInfo\":{\"name\":\"zed\"}}}");
    defer frame.deinit(gpa);
    switch (frame) {
        .request => |r| {
            try testing.expectEqual(Method.initialize, r.method);
            try testing.expectEqual(@as(i64, 1), r.id.int);
            try testing.expectEqual(@as(i64, 1), r.params.initialize.protocol_version);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame missing jsonrpc rejects invalid_request id null" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{\"id\":1,\"method\":\"ping\"}");
    defer frame.deinit(gpa);
    switch (frame) {
        .reject => |r| {
            try testing.expectEqual(ErrorCode.invalid_request, r.code);
            try testing.expect(r.id == .null_val);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame malformed JSON rejects parse_error id null" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{not json");
    defer frame.deinit(gpa);
    switch (frame) {
        .reject => |r| try testing.expectEqual(ErrorCode.parse_error, r.code),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame unknown method request echoes string id method_not_found" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"bogus\"}");
    defer frame.deinit(gpa);
    switch (frame) {
        .reject => |r| {
            try testing.expectEqual(ErrorCode.method_not_found, r.code);
            try testing.expectEqualStrings("abc", r.id.string);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame unknown notification ignored" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    defer frame.deinit(gpa);
    try testing.expect(frame == .ignore);
}

test "parseFrame id null treated as notification" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}");
    defer frame.deinit(gpa);
    try testing.expect(frame == .notification);
}

test "parseFrame invalid id shape rejects invalid_request" {
    const gpa = testing.allocator;
    var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"ping\"}");
    defer frame.deinit(gpa);
    switch (frame) {
        .reject => |r| {
            try testing.expectEqual(ErrorCode.invalid_request, r.code);
            try testing.expect(r.id == .null_val);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame session/new params" {
    const gpa = testing.allocator;
    var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/workspace\"}}");
    defer frame.deinit(gpa);
    switch (frame) {
        .request => |r| {
            try testing.expectEqualStrings("/workspace", r.params.@"session/new".cwd);
            try testing.expect(!r.params.@"session/new".mcp_servers_nonempty);
            try testing.expect(!r.params.@"session/new".prompt_present);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame session/new detects mcpServers and prompt" {
    const gpa = testing.allocator;
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\",\"mcpServers\":[{\"a\":1}]}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .request => |r| try testing.expect(r.params.@"session/new".mcp_servers_nonempty),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\",\"mcpServers\":[],\"prompt\":[]}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .request => |r| {
                try testing.expect(!r.params.@"session/new".mcp_servers_nonempty);
                try testing.expect(r.params.@"session/new".prompt_present);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame session/prompt flattens text and resource blocks" {
    const gpa = testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[{\"type\":\"text\",\"text\":\"alpha\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"x\",\"text\":\"gamma\"}},{\"type\":\"resource\",\"resource\":{\"uri\":\"y\",\"contents\":[{\"type\":\"text\",\"text\":\"delta\"}]}}]}}";
    var frame = try parseOk(gpa, line);
    defer frame.deinit(gpa);
    switch (frame) {
        .request => |r| try testing.expectEqualStrings("alphagammadelta", r.params.@"session/prompt".prompt_text),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame session/prompt rejects image and empty prompt" {
    const gpa = testing.allocator;
    {
        const line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[{\"type\":\"image\",\"image\":{}}]}}";
        var frame = try parseFrame(gpa, line);
        defer frame.deinit(gpa);
        switch (frame) {
            .reject => |r| try testing.expectEqual(ErrorCode.invalid_params, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess_1\",\"prompt\":[]}}";
        var frame = try parseFrame(gpa, line);
        defer frame.deinit(gpa);
        switch (frame) {
            .reject => |r| try testing.expectEqual(ErrorCode.invalid_params, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame session/prompt oversized flattened text rejects" {
    const gpa = testing.allocator;
    var text = std.ArrayList(u8).empty;
    defer text.deinit(gpa);
    var i: usize = 0;
    while (i < prompt_max_bytes + 1) : (i += 1) try text.append(gpa, 'p');
    const line = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"sess_1\",\"prompt\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{text.items});
    defer gpa.free(line);
    var frame = try parseFrame(gpa, line);
    defer frame.deinit(gpa);
    switch (frame) {
        .reject => |r| try testing.expectEqual(ErrorCode.invalid_params, r.code),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame steer caps and interjection" {
    const gpa = testing.allocator;
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/steer\",\"params\":{\"sessionId\":\"sess_1\",\"text\":\"go left\",\"interjectionId\":\"ij-9\"}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .request => |r| {
                try testing.expectEqualStrings("go left", r.params.@"session/steer".text);
                try testing.expectEqualStrings("ij-9", r.params.@"session/steer".interjection_id.?);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const big = "x" ** (steer_max_bytes + 1);
        const line = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/steer\",\"params\":{{\"sessionId\":\"sess_1\",\"text\":\"{s}\"}}}}", .{big});
        defer gpa.free(line);
        var frame = try parseFrame(gpa, line);
        defer frame.deinit(gpa);
        switch (frame) {
            .reject => |r| try testing.expectEqual(ErrorCode.message_too_long, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/steer\",\"params\":{\"sessionId\":\"sess_1\",\"text\":\"\"}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .reject => |r| try testing.expectEqual(ErrorCode.invalid_params, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame cancel notification owns sessionId" {
    const gpa = testing.allocator;
    var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"sess_1\"}}");
    defer frame.deinit(gpa);
    switch (frame) {
        .notification => |n| try testing.expectEqualStrings("sess_1", n.params.@"session/cancel".session_id),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame permission response outcomes" {
    const gpa = testing.allocator;
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"outcome\":{\"optionId\":\"allow_once\"}}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .response => |r| {
                try testing.expectEqual(@as(i64, 7), r.id.int);
                try testing.expectEqualStrings("allow_once", r.outcome.option);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"outcome\":\"cancelled\"}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .response => |r| try testing.expect(r.outcome == .cancelled),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"nope\"}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .response => |r| try testing.expect(r.outcome == .invalid),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseOk(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"outcome\":{\"optionId\":7}}}");
        defer frame.deinit(gpa);
        switch (frame) {
            .response => |r| try testing.expect(r.outcome == .invalid),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseFrame(gpa, "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{\"outcome\":{\"optionId\":\"allow_once\"}}}");
        defer frame.deinit(gpa);
        try testing.expect(frame == .ignore);
    }
}

test "Id serializes int string and null" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(ServerResponse(EmptyResult){ .id = .{ .int = 7 }, .result = EmptyResult{} }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"jsonrpc\":\"2.0\"") != null);
    out.clearRetainingCapacity();
    try stringify(ServerResponse(EmptyResult){ .id = .{ .string = "abc" }, .result = EmptyResult{} }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"abc\"") != null);
    out.clearRetainingCapacity();
    try stringify(ServerResponse(EmptyResult){ .id = .null_val, .@"error" = errorOf(.invalid_request, "bad") }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":{\"code\":-32600,\"message\":\"bad\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"result\"") == null);
}

test "InitializeResult serializes frozen capability shape" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(InitializeResult{
        .agentCapabilities = .{ .sessionCapabilities = .{} },
        .agentInfo = .{ .name = "zag", .title = "Zag", .version = "0.5.0" },
    }, &out);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "\"protocolVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"sessionCapabilities\":{\"list\":{}}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"name\":\"zag\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"authMethods\":[]") != null);
    // Not advertised: no loadSession / mcpCapabilities.
    try testing.expect(std.mem.indexOf(u8, text, "loadSession") == null);
    try testing.expect(std.mem.indexOf(u8, text, "mcpCapabilities") == null);
}

test "Update variants serialize with sessionUpdate discriminant" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(ServerNotification(UpdateParams){
        .method = "session/update",
        .params = .{
            .sessionId = "sess_1",
            .update = .{ .agent_message_chunk = .{ .text = "hi" } },
        },
    }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"sessionUpdate\":\"agent_message_chunk\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"content\":{\"type\":\"text\",\"text\":\"hi\"}") != null);
    out.clearRetainingCapacity();

    try stringify(ServerNotification(UpdateParams){
        .method = "session/update",
        .params = .{
            .sessionId = "sess_1",
            .update = .{ .tool_call = .{ .toolCallId = "t1", .title = "write_file" } },
        },
    }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"sessionUpdate\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"toolCallId\":\"t1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"kind\":\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"status\":\"pending\"") != null);
    out.clearRetainingCapacity();

    try stringify(ServerNotification(UpdateParams){
        .method = "session/update",
        .params = .{
            .sessionId = "sess_1",
            .update = .{ .tool_call_update = .{
                .toolCallId = "t1",
                .status = "completed",
                .content = &.{.{ .content = .{ .text = "body" } }},
            } },
        },
    }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"sessionUpdate\":\"tool_call_update\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"type\":\"content\"") != null);
    out.clearRetainingCapacity();

    // Empty body → content omitted.
    try stringify(ServerNotification(UpdateParams){
        .method = "session/update",
        .params = .{
            .sessionId = "sess_1",
            .update = .{ .tool_call_update = .{ .toolCallId = "t1", .status = "completed", .content = null } },
        },
    }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"content\"") == null);
}

test "GetUserResult keeps explicit nulls" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(ServerResponse(GetUserResult){ .id = .{ .int = 1 }, .result = GetUserResult{} }, &out);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"userId\":null") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"userName\":null") != null);
}

test "capText truncates with marker" {
    const gpa = testing.allocator;
    const small = try capText(gpa, "hello", 10);
    defer gpa.free(small);
    try testing.expectEqualStrings("hello", small);
    const big = "z" ** 100;
    const capped = try capText(gpa, big, 10);
    defer gpa.free(capped);
    try testing.expectEqualStrings("zzzzzzzzzz" ++ truncation_marker, capped);
}

test "error code values are frozen" {
    try testing.expectEqual(@as(i64, -32700), ErrorCode.parse_error.code());
    try testing.expectEqual(@as(i64, -32600), ErrorCode.invalid_request.code());
    try testing.expectEqual(@as(i64, -32601), ErrorCode.method_not_found.code());
    try testing.expectEqual(@as(i64, -32602), ErrorCode.invalid_params.code());
    try testing.expectEqual(@as(i64, -32603), ErrorCode.internal_error.code());
    try testing.expectEqual(@as(i64, -32000), ErrorCode.run_error.code());
    try testing.expectEqual(@as(i64, -32001), ErrorCode.busy.code());
    try testing.expectEqual(@as(i64, -32002), ErrorCode.queue_full.code());
    try testing.expectEqual(@as(i64, -32003), ErrorCode.message_too_long.code());
}
