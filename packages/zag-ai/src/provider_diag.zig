//! Provider-failure diagnostics (status + request shape + parsed API error).
//!
//! h-redact-001: never logs Authorization, raw HTTP bodies, prompts, or tool
//! args. Parsed `error.type` / `code` / `param` / truncated `error.message`
//! are allowed after control-char strip + key-shape scrub. Request shape is
//! counts/flags/model id only.
//!
//! Product path writes `.zag/logs/provider-last.json` (overwrite) and
//! appends `.zag/logs/provider.jsonl`. Tests leave `diag_dir` unset.

const std = @import("std");
const Io = std.Io;
const openai = @import("openai_zig");
const types = @import("types.zig");
const wire = @import("wire.zig");

pub const msg_cap: usize = 240;
pub const field_cap: usize = 64;

pub const HttpHint = struct {
    status: u16 = 0,
    body_len: usize = 0,
    err_type: [field_cap]u8 = undefined,
    err_type_len: u8 = 0,
    code: [field_cap]u8 = undefined,
    code_len: u8 = 0,
    param: [field_cap]u8 = undefined,
    param_len: u8 = 0,
    message: [msg_cap]u8 = undefined,
    message_len: u8 = 0,

    pub fn typeSlice(self: *const HttpHint) []const u8 {
        return self.err_type[0..self.err_type_len];
    }
    pub fn codeSlice(self: *const HttpHint) []const u8 {
        return self.code[0..self.code_len];
    }
    pub fn paramSlice(self: *const HttpHint) []const u8 {
        return self.param[0..self.param_len];
    }
    pub fn messageSlice(self: *const HttpHint) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const RequestShape = struct {
    model: [field_cap]u8 = undefined,
    model_len: u8 = 0,
    style: []const u8 = "",
    mapped_err: []const u8 = "",
    stream: bool = false,
    tool_count: u16 = 0,
    msg_count: u16 = 0,
    sys: u16 = 0,
    user: u16 = 0,
    asst: u16 = 0,
    tool: u16 = 0,
    asst_with_tools: u16 = 0,
    asst_with_reasoning: u16 = 0,
    asst_tools_missing_reasoning: u16 = 0,
    last_role: []const u8 = "",
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,

    pub fn modelSlice(self: *const RequestShape) []const u8 {
        return self.model[0..self.model_len];
    }
};

pub const Snapshot = struct {
    http: HttpHint = .{},
    shape: RequestShape = .{},
};

/// Process-local last failure (one in-flight provider call at a time).
pub var last: Snapshot = .{};

const ApiErrObj = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

const ApiErrBody = struct {
    @"error": ?ApiErrObj = null,
    type: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub fn clearHttp() void {
    last.http = .{};
}

pub fn recordHttp(status: u16, body: []const u8) void {
    last.http = .{};
    last.http.status = status;
    last.http.body_len = body.len;
    fillHintFromJson(&last.http, body);
}

pub fn pullOpenAiHint() void {
    const src = openai.errors.last_http_hint;
    if (src.status == 0) return;
    last.http.status = src.status;
    last.http.body_len = src.body_len;
    copyField(&last.http.err_type, &last.http.err_type_len, src.typeSlice());
    copyField(&last.http.code, &last.http.code_len, src.codeSlice());
    copyField(&last.http.param, &last.http.param_len, src.paramSlice());
    const msg = sanitize(src.messageSlice(), &last.http.message);
    last.http.message_len = @intCast(msg.len);
}

pub fn recordShape(
    mapped_err: []const u8,
    model: []const u8,
    style: wire.ApiStyle,
    stream: bool,
    messages: []const types.Message,
    tools: []const types.ToolDefinition,
    opts: types.ChatOptions,
) void {
    last.shape = .{
        .style = style.jsonName(),
        .mapped_err = mapped_err,
        .stream = stream,
        .tool_count = satU16(tools.len),
        .msg_count = satU16(messages.len),
        .max_tokens = opts.max_tokens,
        .max_completion_tokens = opts.max_completion_tokens,
    };
    const m = sanitize(model, &last.shape.model);
    last.shape.model_len = @intCast(m.len);

    if (messages.len > 0) {
        last.shape.last_role = messages[messages.len - 1].role.jsonName();
    }
    for (messages) |msg| {
        switch (msg.role) {
            .system => last.shape.sys +|= 1,
            .user => last.shape.user +|= 1,
            .assistant => {
                last.shape.asst +|= 1;
                const has_tools = msg.tool_calls != null and msg.tool_calls.?.len > 0;
                const has_reason = msg.reasoning != null and msg.reasoning.?.len > 0;
                if (has_tools) last.shape.asst_with_tools +|= 1;
                if (has_reason) last.shape.asst_with_reasoning +|= 1;
                if (has_tools and !has_reason) last.shape.asst_tools_missing_reasoning +|= 1;
            },
            .tool => last.shape.tool +|= 1,
        }
    }
}

/// stderr summary always; workspace files when `io` and `diag_dir` are set.
pub fn emit(io: ?Io, diag_dir: ?[]const u8) void {
    var line_buf: [512]u8 = undefined;
    const line = formatWarnLine(&line_buf, &last) catch return;
    std.log.warn("{s}", .{line});

    const dir_io = io orelse return;
    const dir_path = diag_dir orelse return;
    Io.Dir.cwd().createDirPath(dir_io, dir_path) catch {};

    var json_buf: [1536]u8 = undefined;
    const json = formatJson(&json_buf, &last) catch return;

    var last_path_buf: [256]u8 = undefined;
    const last_path = std.fmt.bufPrint(&last_path_buf, "{s}/provider-last.json", .{dir_path}) catch return;
    overwriteFile(dir_io, last_path, json);

    var jsonl_path_buf: [256]u8 = undefined;
    const jsonl_path = std.fmt.bufPrint(&jsonl_path_buf, "{s}/provider.jsonl", .{dir_path}) catch return;
    appendFile(dir_io, jsonl_path, json);
}

pub fn formatWarnLine(buf: []u8, snap: *const Snapshot) error{NoSpaceLeft}![]u8 {
    const h = snap.http;
    const s = snap.shape;
    return std.fmt.bufPrint(buf, "provider diag err={s} status={d} body_len={d} type={s} code={s} param={s} msg={s} model={s} style={s} stream={d} tools={d} msgs={d} last={s} asst_tools={d} asst_reason={d} asst_tools_no_reason={d} max_tokens={s} max_completion={s}", .{
        dash(s.mapped_err),
        h.status,
        h.body_len,
        dash(h.typeSlice()),
        dash(h.codeSlice()),
        dash(h.paramSlice()),
        dash(h.messageSlice()),
        dash(s.modelSlice()),
        dash(s.style),
        @intFromBool(s.stream),
        s.tool_count,
        s.msg_count,
        dash(s.last_role),
        s.asst_with_tools,
        s.asst_with_reasoning,
        s.asst_tools_missing_reasoning,
        optU32(s.max_tokens),
        optU32(s.max_completion_tokens),
    });
}

fn formatJson(buf: []u8, snap: *const Snapshot) error{WriteFailed}![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    var js: std.json.Stringify = .{ .writer = &w };
    js.beginObject() catch return error.WriteFailed;
    try writeJsonField(&js, "err", snap.shape.mapped_err);
    js.objectField("status") catch return error.WriteFailed;
    js.write(snap.http.status) catch return error.WriteFailed;
    js.objectField("body_len") catch return error.WriteFailed;
    js.write(snap.http.body_len) catch return error.WriteFailed;
    try writeJsonField(&js, "type", snap.http.typeSlice());
    try writeJsonField(&js, "code", snap.http.codeSlice());
    try writeJsonField(&js, "param", snap.http.paramSlice());
    try writeJsonField(&js, "msg", snap.http.messageSlice());
    try writeJsonField(&js, "model", snap.shape.modelSlice());
    try writeJsonField(&js, "style", snap.shape.style);
    js.objectField("stream") catch return error.WriteFailed;
    js.write(snap.shape.stream) catch return error.WriteFailed;
    js.objectField("tools") catch return error.WriteFailed;
    js.write(snap.shape.tool_count) catch return error.WriteFailed;
    js.objectField("msgs") catch return error.WriteFailed;
    js.write(snap.shape.msg_count) catch return error.WriteFailed;
    try writeJsonField(&js, "last_role", snap.shape.last_role);
    js.objectField("roles") catch return error.WriteFailed;
    js.beginObject() catch return error.WriteFailed;
    js.objectField("sys") catch return error.WriteFailed;
    js.write(snap.shape.sys) catch return error.WriteFailed;
    js.objectField("user") catch return error.WriteFailed;
    js.write(snap.shape.user) catch return error.WriteFailed;
    js.objectField("asst") catch return error.WriteFailed;
    js.write(snap.shape.asst) catch return error.WriteFailed;
    js.objectField("tool") catch return error.WriteFailed;
    js.write(snap.shape.tool) catch return error.WriteFailed;
    js.endObject() catch return error.WriteFailed;
    js.objectField("asst_tools") catch return error.WriteFailed;
    js.write(snap.shape.asst_with_tools) catch return error.WriteFailed;
    js.objectField("asst_reason") catch return error.WriteFailed;
    js.write(snap.shape.asst_with_reasoning) catch return error.WriteFailed;
    js.objectField("asst_tools_no_reason") catch return error.WriteFailed;
    js.write(snap.shape.asst_tools_missing_reasoning) catch return error.WriteFailed;
    js.objectField("max_tokens") catch return error.WriteFailed;
    if (snap.shape.max_tokens) |n| {
        js.write(n) catch return error.WriteFailed;
    } else {
        js.write(null) catch return error.WriteFailed;
    }
    js.objectField("max_completion") catch return error.WriteFailed;
    if (snap.shape.max_completion_tokens) |n| {
        js.write(n) catch return error.WriteFailed;
    } else {
        js.write(null) catch return error.WriteFailed;
    }
    js.endObject() catch return error.WriteFailed;
    return w.buffered();
}

fn writeJsonField(js: *std.json.Stringify, name: []const u8, value: []const u8) error{WriteFailed}!void {
    js.objectField(name) catch return error.WriteFailed;
    js.write(value) catch return error.WriteFailed;
}

fn overwriteFile(io: Io, path: []const u8, body: []const u8) void {
    var file = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, body) catch {};
    file.writeStreamingAll(io, "\n") catch {};
}

fn appendFile(io: Io, path: []const u8, body: []const u8) void {
    var file = Io.Dir.createFile(.cwd(), io, path, .{ .truncate = false }) catch return;
    defer file.close(io);
    const offset = file.length(io) catch return;
    var line_buf: [1600]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{body}) catch return;
    file.writePositionalAll(io, line, offset) catch {};
}

fn fillHintFromJson(hint: *HttpHint, body: []const u8) void {
    if (body.len == 0) return;
    const parsed = std.json.parseFromSlice(ApiErrBody, std.heap.page_allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    const v = parsed.value;
    if (v.@"error") |e| {
        copySanitized(&hint.err_type, &hint.err_type_len, e.type);
        copySanitized(&hint.code, &hint.code_len, e.code);
        copySanitized(&hint.param, &hint.param_len, e.param);
        copySanitized(&hint.message, &hint.message_len, e.message);
        return;
    }
    copySanitized(&hint.err_type, &hint.err_type_len, v.type);
    copySanitized(&hint.message, &hint.message_len, v.message orelse v.detail);
}

fn copySanitized(dest: []u8, dest_len: *u8, src: ?[]const u8) void {
    const raw = src orelse return;
    const out = sanitize(raw, dest);
    dest_len.* = @intCast(out.len);
}

fn copyField(dest: []u8, dest_len: *u8, src: []const u8) void {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    dest_len.* = @intCast(n);
}

/// Strip controls, cap length, scrub common key shapes. Never returns `src`.
pub fn sanitize(src: []const u8, dest: []u8) []u8 {
    var n: usize = 0;
    for (src) |c| {
        if (n >= dest.len) break;
        if (c == '\n' or c == '\r' or c == '\t') {
            dest[n] = ' ';
            n += 1;
            continue;
        }
        if (c < 0x20) continue;
        dest[n] = c;
        n += 1;
    }
    scrubKeyShapes(dest[0..n]);
    return dest[0..n];
}

fn scrubKeyShapes(buf: []u8) void {
    scrubPrefix(buf, "sk-");
    scrubPrefix(buf, "sk-ant-");
    scrubPrefix(buf, "Bearer ");
    scrubPrefix(buf, "xai-");
    scrubPrefix(buf, "ghp_");
}

fn scrubPrefix(buf: []u8, prefix: []const u8) void {
    var i: usize = 0;
    while (i + prefix.len < buf.len) {
        if (std.mem.startsWith(u8, buf[i..], prefix)) {
            var j = i + prefix.len;
            var token: usize = 0;
            while (j < buf.len and token < 128 and isTokenChar(buf[j])) {
                j += 1;
                token += 1;
            }
            if (token >= 8) {
                @memset(buf[i + prefix.len .. j], '*');
            }
            i = j;
            continue;
        }
        i += 1;
    }
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

fn satU16(n: usize) u16 {
    return if (n > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(n);
}

fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

fn optU32(n: ?u32) []const u8 {
    if (n == null) return "-";
    return "set";
}

test "sanitize strips controls and scrubs sk- keys" {
    var buf: [64]u8 = undefined;
    const secret = "sk-test-fake-secret-key-NOT-REAL";
    const out = sanitize("bad\nkey " ++ secret, &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bad key") != null);
}

test "recordHttp parses OpenAI error envelope" {
    last = .{};
    recordHttp(400, "{\"error\":{\"message\":\"The reasoning_content must be passed back\",\"type\":\"invalid_request_error\",\"code\":\"invalid_request_error\"}}");
    try std.testing.expectEqual(@as(u16, 400), last.http.status);
    try std.testing.expectEqualStrings("invalid_request_error", last.http.typeSlice());
    try std.testing.expect(std.mem.indexOf(u8, last.http.messageSlice(), "reasoning_content") != null);
}

test "recordShape flags tool turns missing reasoning" {
    last = .{};
    const calls = [_]types.ToolCall{.{ .id = "c1", .name = "list_dir", .arguments = "{}" }};
    const msgs = [_]types.Message{
        types.Message.user("edit"),
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        types.Message.toolResult("c1", "ok"),
    };
    const tools = [_]types.ToolDefinition{.{
        .name = "list_dir",
        .description = "d",
        .parameters_json = "{\"type\":\"object\"}",
    }};
    recordShape("BadRequest", "deepseek-v4-flash", .openai_compat, true, &msgs, &tools, .{ .max_tokens = 1024 });
    try std.testing.expectEqual(@as(u16, 1), last.shape.asst_with_tools);
    try std.testing.expectEqual(@as(u16, 1), last.shape.asst_tools_missing_reasoning);
    try std.testing.expectEqualStrings("tool", last.shape.last_role);

    var line_buf: [512]u8 = undefined;
    const line = try formatWarnLine(&line_buf, &last);
    try std.testing.expect(std.mem.indexOf(u8, line, "asst_tools_no_reason=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "deepseek-v4-flash") != null);
}

test "formatJson omits raw body and scrubs secrets in msg" {
    last = .{};
    recordHttp(401, "{\"error\":{\"message\":\"invalid api key sk-test-fake-secret-key-NOT-REAL\",\"type\":\"auth\"}}");
    recordShape("AuthenticationFailed", "m", .openai_compat, false, &.{}, &.{}, .{});
    var buf: [1536]u8 = undefined;
    const json = try formatJson(&buf, &last);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-test-fake-secret-key-NOT-REAL") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Authorization") == null);
}
