//! rpc-v1 wire protocol types (zag-cli): parse/serialize, error codes, event
//! groups, budgets. Pure — no IO; unit-testable without a process (rpc-v1 §2.1).
//!
//! Every frame is one NDJSON object carrying `protocol_version` + `type`
//! (`request` / `response` / `notification`) in the headless-v1 envelope
//! family, with JSON-RPC-shaped `id` correlation (rpc-v1 §4).

const std = @import("std");

pub const protocol_version = "rpc-v1";

// ── Budgets (rpc-v1 §10, checked arithmetic) ────────────────────────────────

/// Prompt text cap (inbound).
pub const prompt_max_bytes: usize = 1024 * 1024;
/// steer / follow_up text cap (= `control_queue.message_max_bytes`, wire-enforced).
pub const control_max_bytes: usize = 4096;
/// `subscribe.events` entry cap.
pub const subscribe_max_events: usize = 32;
/// `permission_request.arguments_json` cap (excess → truncation marker).
pub const permission_args_max_bytes: usize = 64 * 1024;
/// `prompt` result `final_text` cap (excess → truncation marker).
pub const final_text_max_bytes: usize = 1024 * 1024;
/// Literal truncation marker appended to capped fields.
pub const truncation_marker = "...[truncated]";

// ── Error model (rpc-v1 §9.1) ───────────────────────────────────────────────

/// Frozen request error codes. Each maps to exactly one documented behavior;
/// `out_of_memory` and `internal_error` are followed by process exit 40 / 70.
pub const ErrorCode = enum {
    invalid_arguments,
    unknown_method,
    unknown_event,
    unsupported_protocol,
    session_busy,
    queue_full,
    message_too_long,
    prompt_too_large,
    session_not_configured,
    session_not_found,
    session_already_exists,
    session_invalid,
    session_unsupported_schema,
    session_io_failed,
    permission_unknown,
    out_of_memory,
    internal_error,

    pub fn jsonName(self: ErrorCode) []const u8 {
        return @tagName(self);
    }

    /// `retryable` is true only for `session_io_failed` in v1 (rpc-v1 §9.1).
    pub fn retryable(self: ErrorCode) bool {
        return switch (self) {
            .session_io_failed => true,
            else => false,
        };
    }

    /// Category mirrors headless (`auth` / `provider` / `session` / `runtime` /
    /// `argument`).
    pub fn category(self: ErrorCode) []const u8 {
        return switch (self) {
            .invalid_arguments, .unknown_method, .unknown_event,
            .unsupported_protocol, .message_too_long, .prompt_too_large => "argument",
            .session_busy, .queue_full, .session_not_configured,
            .session_not_found, .session_already_exists, .session_invalid,
            .session_unsupported_schema, .session_io_failed,
            .permission_unknown => "session",
            .out_of_memory, .internal_error => "runtime",
        };
    }
};

/// The wire error object (response `error`, fatal `error` notification).
pub const ErrorObj = struct {
    code: []const u8,
    message: []const u8,
    retryable: bool,
    category: []const u8,

    pub fn of(code: ErrorCode, message: []const u8) ErrorObj {
        return .{
            .code = code.jsonName(),
            .message = message,
            .retryable = code.retryable(),
            .category = code.category(),
        };
    }
};

// ── Event groups (rpc-v1 §6.2) ──────────────────────────────────────────────

pub const EventGroup = enum {
    delta,
    thinking,
    tools,
    permission,
    usage,
    lifecycle,
    session,

    pub fn parse(s: []const u8) ?EventGroup {
        inline for (std.meta.fields(EventGroup)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

// ── Requests (rpc-v1 §5) ────────────────────────────────────────────────────

pub const PromptParams = struct {
    text: []const u8,
    stream: bool = true,
};

pub const ControlParams = struct {
    text: []const u8,
};

pub const SubscribeParams = struct {
    events: []const []const u8,
};

pub const PermissionDecisionParams = struct {
    request_id: i64,
    allowed: bool,
    remember: bool = false,
};

pub const ResumeParams = struct {
    path: ?[]const u8 = null,
};

pub const Method = enum {
    prompt,
    cancel,
    steer,
    follow_up,
    subscribe,
    permission_decision,
    @"resume",
    exit,

    pub fn parse(s: []const u8) ?Method {
        inline for (std.meta.fields(Method)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Per-method params. String slices are **owned** (gpa dupes made at parse
/// time); call `deinit` to release.
pub const Params = union(Method) {
    prompt: PromptParams,
    cancel: void,
    steer: ControlParams,
    follow_up: ControlParams,
    subscribe: SubscribeParams,
    permission_decision: PermissionDecisionParams,
    @"resume": ResumeParams,
    exit: void,

    pub fn deinit(self: *Params, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .prompt => |p| gpa.free(p.text),
            .steer => |c| gpa.free(c.text),
            .follow_up => |c| gpa.free(c.text),
            .subscribe => |s| {
                for (s.events) |e| gpa.free(e);
                gpa.free(s.events);
            },
            .@"resume" => |r| {
                if (r.path) |p| gpa.free(p);
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub const Request = struct {
    id: i64,
    method: Method,
    params: Params,
};

/// Outcome of parsing one inbound frame.
pub const Frame = union(enum) {
    request: Request,
    /// Frame rejected at the envelope or method level: respond with the
    /// echoed `id` (null when the id could not be trusted) and continue.
    reject: Reject,
};

pub const Reject = struct {
    id: ?i64,
    code: ErrorCode,
    message: []const u8,
};

fn reject(id: ?i64, code: ErrorCode, message: []const u8) Frame {
    return .{ .reject = .{ .id = id, .code = code, .message = message } };
}

/// Parse one inbound line. The returned Request owns its string slices.
pub fn parseFrame(gpa: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!Frame {
    if (line.len == 0) return reject(null, .invalid_arguments, "empty frame");
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
        return reject(null, .invalid_arguments, "invalid JSON frame");
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return reject(null, .invalid_arguments, "frame must be a JSON object");

    const pv = root.object.get("protocol_version") orelse
        return reject(null, .invalid_arguments, "missing protocol_version");
    if (pv != .string or !std.mem.eql(u8, pv.string, protocol_version)) {
        return reject(null, .unsupported_protocol, "unsupported protocol_version");
    }

    const ty = root.object.get("type") orelse
        return reject(null, .invalid_arguments, "missing type");
    if (ty != .string or !std.mem.eql(u8, ty.string, "request")) {
        // Client-to-server responses/notifications are not part of rpc-v1
        // (the frozen sets are one-directional); the id is not trusted.
        return reject(null, .invalid_arguments, "client frames must be requests");
    }

    const idv = root.object.get("id") orelse
        return reject(null, .invalid_arguments, "missing id");
    if (idv != .integer) return reject(null, .invalid_arguments, "id must be an integer");
    const id = idv.integer;

    const mv = root.object.get("method") orelse
        return reject(id, .invalid_arguments, "missing method");
    if (mv != .string) return reject(id, .invalid_arguments, "method must be a string");
    const method = Method.parse(mv.string) orelse
        return reject(id, .unknown_method, "unknown method");

    if (method == .cancel or method == .exit) {
        return .{ .request = .{ .id = id, .method = method, .params = if (method == .cancel) .cancel else .exit } };
    }
    const p = root.object.get("params");
    if (p == null) {
        // `resume` params are optional (omitted → configured path, §5).
        if (method == .@"resume") {
            return .{ .request = .{ .id = id, .method = method, .params = .{ .@"resume" = .{ .path = null } } } };
        }
        return reject(id, .invalid_arguments, "missing params");
    }
    if (p.? != .object) return reject(id, .invalid_arguments, "params must be an object");
    return try parseParams(gpa, method, p.?.object, id);
}

fn parseParams(
    gpa: std.mem.Allocator,
    method: Method,
    obj: std.json.ObjectMap,
    id: i64,
) std.mem.Allocator.Error!Frame {
    const params: Params = switch (method) {
        .prompt => blk: {
            const text = getString(obj, "text") orelse
                return reject(id, .invalid_arguments, "prompt requires a text string");
            const stream = getBool(obj, "stream", true) orelse
                return reject(id, .invalid_arguments, "stream must be a boolean");
            if (text.len > prompt_max_bytes) {
                return reject(id, .prompt_too_large, "prompt text exceeds the 1 MiB cap");
            }
            break :blk .{ .prompt = .{
                .text = try gpa.dupe(u8, text),
                .stream = stream,
            } };
        },
        .steer, .follow_up => blk: {
            const text = getString(obj, "text") orelse
                return reject(id, .invalid_arguments, "text must be a string");
            if (text.len == 0) {
                return reject(id, .invalid_arguments, "text must be non-empty");
            }
            if (text.len > control_max_bytes) {
                return reject(id, .message_too_long, "control text exceeds the 4096 B cap");
            }
            if (method == .steer) {
                break :blk .{ .steer = .{ .text = try gpa.dupe(u8, text) } };
            }
            break :blk .{ .follow_up = .{ .text = try gpa.dupe(u8, text) } };
        },
        .subscribe => blk: {
            const ev = obj.get("events") orelse
                return reject(id, .invalid_arguments, "subscribe requires events");
            if (ev != .array) return reject(id, .invalid_arguments, "events must be an array");
            if (ev.array.items.len > subscribe_max_events) {
                return reject(id, .invalid_arguments, "too many events (cap 32)");
            }
            // Validate every entry BEFORE any allocation: a strict reject
            // (`unknown_event`, no partial apply) must not leak.
            for (ev.array.items) |item| {
                if (item != .string) {
                    return reject(id, .invalid_arguments, "events entries must be strings");
                }
                if (EventGroup.parse(item.string) == null) {
                    return reject(id, .unknown_event, "unknown event group");
                }
            }
            var list = std.ArrayList([]const u8).empty;
            errdefer {
                for (list.items) |e| gpa.free(e);
                list.deinit(gpa);
            }
            try list.ensureTotalCapacity(gpa, ev.array.items.len);
            for (ev.array.items) |item| {
                list.appendAssumeCapacity(try gpa.dupe(u8, item.string));
            }
            break :blk .{ .subscribe = .{ .events = try list.toOwnedSlice(gpa) } };
        },
        .permission_decision => blk: {
            const rid = obj.get("request_id") orelse
                return reject(id, .invalid_arguments, "permission_decision requires request_id");
            if (rid != .integer) {
                return reject(id, .invalid_arguments, "request_id must be an integer");
            }
            const allowed = getBool(obj, "allowed", null) orelse
                return reject(id, .invalid_arguments, "allowed must be a boolean");
            const remember = getBool(obj, "remember", false) orelse
                return reject(id, .invalid_arguments, "remember must be a boolean");
            break :blk .{ .permission_decision = .{
                .request_id = rid.integer,
                .allowed = allowed,
                .remember = remember,
            } };
        },
        .@"resume" => blk: {
            const path = if (obj.get("path")) |p| blk2: {
                if (p != .string) {
                    return reject(id, .invalid_arguments, "path must be a string");
                }
                break :blk2 try gpa.dupe(u8, p.string);
            } else null;
            break :blk .{ .@"resume" = .{ .path = path } };
        },
        .cancel, .exit => unreachable, // handled by the caller branch
    };
    return .{ .request = .{ .id = id, .method = method, .params = params } };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8, default: ?bool) ?bool {
    const v = obj.get(key) orelse return default;
    if (v != .bool) return null;
    return v.bool;
}

// ── Serialization (rpc-v1 §4 envelope) ──────────────────────────────────────

/// Response `id`: positive integer chosen by the client, echoed verbatim;
/// `null` for envelope-level rejections. Serialized as a bare JSON value.
pub const ResponseId = union(enum) {
    int: i64,
    null_val,

    pub fn jsonStringify(self: ResponseId, jw: anytype) !void {
        switch (self) {
            .int => |v| try jw.write(v),
            .null_val => try jw.write(null),
        }
    }
};

pub const UsageObj = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// `prompt` response result (rpc-v1 §5). `final_text` ≤ 1 MiB + marker
/// (applied by the server before serialization).
pub const PromptResult = struct {
    ok: bool,
    stop_reason: []const u8,
    turns: u32,
    final_text: []const u8,
    usage: UsageObj,
};

pub const OkResult = struct {
    ok: bool,
};

pub const SubscribeResult = struct {
    ok: bool,
    subscribed: []const []const u8,
};

pub const ResumeResult = struct {
    ok: bool,
    resumed: bool,
    path: []const u8,
    turns: u32,
};

/// Response envelope. Exactly one of `result` / `error` is non-null; the
/// other is omitted (`emit_null_optional_fields = false`).
pub fn Response(comptime ResultT: type) type {
    return struct {
        protocol_version: []const u8,
        @"type": []const u8 = "response",
        id: ResponseId,
        result: ?ResultT = null,
        @"error": ?ErrorObj = null,
    };
}

// ── Notifications (rpc-v1 §6) ───────────────────────────────────────────────

pub const ReadySession = struct {
    configured: bool,
    path: ?[]const u8 = null,
    turns: u32,
    resumed: bool,
};

pub const ReadyParams = struct {
    protocol_version: []const u8,
    zag_version: []const u8,
    permission: []const u8,
    shell_policy: []const u8,
    session: ReadySession,
};

pub const PermissionRequestParams = struct {
    request_id: i64,
    tool_name: []const u8,
    risk: []const u8,
    arguments_json: []const u8,
};

pub const FatalErrorParams = struct {
    @"error": ErrorObj,
};

pub const AssistantDeltaParams = struct {
    text: []const u8,
};

pub const EmptyParams = struct {};

pub const RunStartParams = struct {
    session_configured: bool,
};

pub const AssistantMessageParams = struct {
    turn: u32,
    text: []const u8,
    has_tools: bool,
    reasoning: ?[]const u8 = null,
};

pub const ToolStartParams = struct {
    turn: u32,
    call_index: u32,
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolEndParams = struct {
    turn: u32,
    call_index: u32,
    id: []const u8,
    name: []const u8,
    body: []const u8,
};

pub const ControlAppliedParams = struct {
    kind: []const u8,
    next_turn: u32,
    text: []const u8,
};

pub const PermissionNotifParams = struct {
    tool_name: []const u8,
    allowed: bool,
    remembered: bool,
    risk: []const u8,
};

pub const UsageNotifParams = UsageObj;

pub const SessionNotifParams = struct {
    path: []const u8,
    turns: u32,
    resumed: bool,
};

/// Notification envelope.
pub fn Notification(comptime ParamsT: type) type {
    return struct {
        protocol_version: []const u8,
        @"type": []const u8 = "notification",
        method: []const u8,
        params: ParamsT,
    };
}

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

test "ErrorCode retryable and category matrix" {
    try std.testing.expectEqualStrings("session_io_failed", ErrorCode.session_io_failed.jsonName());
    try std.testing.expect(ErrorCode.session_io_failed.retryable());
    try std.testing.expect(!ErrorCode.session_busy.retryable());
    try std.testing.expect(!ErrorCode.invalid_arguments.retryable());
    try std.testing.expectEqualStrings("argument", ErrorCode.invalid_arguments.category());
    try std.testing.expectEqualStrings("session", ErrorCode.queue_full.category());
    try std.testing.expectEqualStrings("runtime", ErrorCode.out_of_memory.category());
    try std.testing.expectEqualStrings("runtime", ErrorCode.internal_error.category());
    try std.testing.expectEqualStrings("argument", ErrorCode.unsupported_protocol.category());
}

test "EventGroup parse round trip" {
    try std.testing.expectEqual(EventGroup.delta, EventGroup.parse("delta").?);
    try std.testing.expectEqual(EventGroup.session, EventGroup.parse("session").?);
    try std.testing.expect(EventGroup.parse("nope") == null);
    try std.testing.expect(EventGroup.parse("") == null);
}

test "parseFrame prompt with defaults and caps" {
    const gpa = std.testing.allocator;
    const line = "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":7,\"method\":\"prompt\",\"params\":{\"text\":\"hi\"}}";
    var frame = try parseFrame(gpa, line);
    defer switch (frame) {
        .request => |*r| r.params.deinit(gpa),
        else => {},
    };
    switch (frame) {
        .request => |r| {
            try std.testing.expectEqual(@as(i64, 7), r.id);
            try std.testing.expectEqual(Method.prompt, r.method);
            try std.testing.expectEqualStrings("hi", r.params.prompt.text);
            try std.testing.expect(r.params.prompt.stream);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame prompt stream false and extra params ignored" {
    const gpa = std.testing.allocator;
    const line = "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"prompt\",\"params\":{\"text\":\"x\",\"stream\":false,\"future\":123}}";
    var frame = try parseFrame(gpa, line);
    defer switch (frame) {
        .request => |*r| r.params.deinit(gpa),
        else => {},
    };
    switch (frame) {
        .request => |r| try std.testing.expect(!r.params.prompt.stream),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame bad JSON rejects id null" {
    const gpa = std.testing.allocator;
    const frame = try parseFrame(gpa, "{not json");
    switch (frame) {
        .reject => |r| {
            try std.testing.expect(r.id == null);
            try std.testing.expectEqual(ErrorCode.invalid_arguments, r.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame wrong protocol version rejects unsupported_protocol" {
    const gpa = std.testing.allocator;
    const frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v9\",\"type\":\"request\",\"id\":3,\"method\":\"exit\"}");
    switch (frame) {
        .reject => |r| {
            try std.testing.expectEqual(ErrorCode.unsupported_protocol, r.code);
            try std.testing.expect(r.id == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame unknown method echoes id with unknown_method" {
    const gpa = std.testing.allocator;
    const frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":42,\"method\":\"frobnicate\"}");
    switch (frame) {
        .reject => |r| {
            try std.testing.expectEqual(@as(?i64, 42), r.id);
            try std.testing.expectEqual(ErrorCode.unknown_method, r.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame client notification and response frames rejected" {
    const gpa = std.testing.allocator;
    const n = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"notification\",\"method\":\"x\"}");
    switch (n) {
        .reject => |r| try std.testing.expectEqual(ErrorCode.invalid_arguments, r.code),
        else => return error.TestUnexpectedResult,
    }
    const resp = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"response\",\"id\":1,\"result\":{}}");
    switch (resp) {
        .reject => |r| try std.testing.expectEqual(ErrorCode.invalid_arguments, r.code),
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame control caps message_too_long and empty" {
    const gpa = std.testing.allocator;
    {
        const too_long = "x" ** (control_max_bytes + 1);
        const line = try std.fmt.allocPrint(gpa, "{{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"steer\",\"params\":{{\"text\":\"{s}\"}}}}", .{too_long});
        defer gpa.free(line);
        const frame = try parseFrame(gpa, line);
        switch (frame) {
            .reject => |r| try std.testing.expectEqual(ErrorCode.message_too_long, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":2,\"method\":\"follow_up\",\"params\":{\"text\":\"\"}}");
        switch (frame) {
            .reject => |r| try std.testing.expectEqual(ErrorCode.invalid_arguments, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame subscribe strict unknown_event no partial apply" {
    const gpa = std.testing.allocator;
    const frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":5,\"method\":\"subscribe\",\"params\":{\"events\":[\"delta\",\"bogus\"]}}");
    switch (frame) {
        .reject => |r| {
            try std.testing.expectEqual(@as(?i64, 5), r.id);
            try std.testing.expectEqual(ErrorCode.unknown_event, r.code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame subscribe success owns strings" {
    const gpa = std.testing.allocator;
    var frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":6,\"method\":\"subscribe\",\"params\":{\"events\":[\"delta\",\"tools\"]}}");
    defer switch (frame) {
        .request => |*r| r.params.deinit(gpa),
        else => {},
    };
    switch (frame) {
        .request => |r| {
            try std.testing.expectEqual(@as(usize, 2), r.params.subscribe.events.len);
            try std.testing.expectEqualStrings("delta", r.params.subscribe.events[0]);
            try std.testing.expectEqualStrings("tools", r.params.subscribe.events[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseFrame permission_decision full and missing" {
    const gpa = std.testing.allocator;
    {
        var frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":9,\"method\":\"permission_decision\",\"params\":{\"request_id\":3,\"allowed\":true,\"remember\":true}}");
        defer switch (frame) {
            .request => |*r| r.params.deinit(gpa),
            else => {},
        };
        switch (frame) {
            .request => |r| {
                try std.testing.expectEqual(@as(i64, 3), r.params.permission_decision.request_id);
                try std.testing.expect(r.params.permission_decision.allowed);
                try std.testing.expect(r.params.permission_decision.remember);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":9,\"method\":\"permission_decision\",\"params\":{\"request_id\":3}}");
        switch (frame) {
            .reject => |r| try std.testing.expectEqual(ErrorCode.invalid_arguments, r.code),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame resume optional path" {
    const gpa = std.testing.allocator;
    {
        var frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":4,\"method\":\"resume\"}");
        defer switch (frame) {
            .request => |*r| r.params.deinit(gpa),
            else => {},
        };
        switch (frame) {
            .request => |r| try std.testing.expect(r.params.@"resume".path == null),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var frame = try parseFrame(gpa, "{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":4,\"method\":\"resume\",\"params\":{\"path\":\".zag/sessions/a.jsonl\"}}");
        defer switch (frame) {
            .request => |*r| r.params.deinit(gpa),
            else => {},
        };
        switch (frame) {
            .request => |r| try std.testing.expectEqualStrings(".zag/sessions/a.jsonl", r.params.@"resume".path.?),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame cancel and exit need no params" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "cancel", "exit" }) |m| {
        const line = try std.fmt.allocPrint(gpa, "{{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"{s}\"}}", .{m});
        defer gpa.free(line);
        var frame = try parseFrame(gpa, line);
        defer switch (frame) {
            .request => |*r| r.params.deinit(gpa),
            else => {},
        };
        switch (frame) {
            .request => |r| try std.testing.expectEqualStrings(m, @tagName(r.method)),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parseFrame prompt over 1 MiB rejects prompt_too_large" {
    const gpa = std.testing.allocator;
    const big = "p" ** (prompt_max_bytes + 1);
    const line = try std.fmt.allocPrint(gpa, "{{\"protocol_version\":\"rpc-v1\",\"type\":\"request\",\"id\":1,\"method\":\"prompt\",\"params\":{{\"text\":\"{s}\"}}}}", .{big});
    defer gpa.free(line);
    const frame = try parseFrame(gpa, line);
    switch (frame) {
        .reject => |r| try std.testing.expectEqual(ErrorCode.prompt_too_large, r.code),
        else => return error.TestUnexpectedResult,
    }
}

test "ResponseId serializes int and null" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(Response(OkResult){ .protocol_version = protocol_version, .id = .{ .int = 7 }, .result = OkResult{ .ok = true } }, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":{\"ok\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"error\"") == null);
    out.clearRetainingCapacity();

    try stringify(Response(OkResult){ .protocol_version = protocol_version, .id = .null_val, .@"error" = ErrorObj.of(.invalid_arguments, "bad") }, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":{\"code\":\"invalid_arguments\",\"message\":\"bad\",\"retryable\":false,\"category\":\"argument\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"result\"") == null);
}

test "Notification envelope serializes with method and params" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try stringify(Notification(ReadyParams){
        .protocol_version = protocol_version,
        .method = "ready",
        .params = ReadyParams{
            .protocol_version = protocol_version,
            .zag_version = "0.5.0",
            .permission = "ask",
            .shell_policy = "protect",
            .session = .{ .configured = false, .path = null, .turns = 0, .resumed = false },
        },
    }, &out);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"protocol_version\":\"rpc-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"notification\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"method\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"permission\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"configured\":false") != null);
    // null optional path is omitted
    try std.testing.expect(std.mem.indexOf(u8, text, "\"path\"") == null);
}

test "capText truncates with marker and passes through small text" {
    const gpa = std.testing.allocator;
    const small = try capText(gpa, "hello", 10);
    defer gpa.free(small);
    try std.testing.expectEqualStrings("hello", small);
    const big = "z" ** 100;
    const capped = try capText(gpa, big, 10);
    defer gpa.free(capped);
    try std.testing.expectEqualStrings("zzzzzzzzzz" ++ truncation_marker, capped);
}
