//! Session durability — JSONL transcript on disk.
//!
//! Format (one JSON object per line):
//! ```
//! {"schema_version":1,"v":1,"type":"zag_session","compaction_gen":0}
//! {"role":"system","content":"..."}
//! {"role":"user","content":"..."}
//! {"role":"assistant","content":"...","tool_calls":[...]}
//! {"role":"tool","tool_call_id":"...","content":"..."}
//! ```
//!
//! `schema_version` (or legacy `v`) must be 1. Unknown versions → `UnsupportedSchema`.
//! Header-less legacy files still load (implied v1).

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const transcript_mod = @import("transcript.zig");

pub const Error = error{
    OutOfMemory,
    IoFailed,
    InvalidSession,
    UnsupportedSchema,
};

pub const header_type = "zag_session";
pub const current_schema_version: u32 = 1;

/// Metadata written on the session header line (H4).
pub const SessionMeta = struct {
    schema_version: u32 = current_schema_version,
    /// Optional package version string at write time (not owned here).
    zag_version: ?[]const u8 = null,
    compaction_gen: u32 = 0,
    /// Optional heuristic compaction summary (not owned here).
    compaction_summary: ?[]const u8 = null,
};

/// Write full transcript to `path` (creates parent dirs). Overwrites existing file.
pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
) Error!void {
    try saveWithMeta(gpa, io, cwd, path, messages, .{});
}

pub fn saveWithMeta(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
) Error!void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) {
            cwd.createDirPath(io, dir_path) catch return error.IoFailed;
        }
    }

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    writeHeader(&body.writer, meta) catch return error.OutOfMemory;
    for (messages) |msg| {
        writeMessage(&body.writer, msg) catch return error.OutOfMemory;
    }

    cwd.writeFile(io, .{
        .sub_path = path,
        .data = body.written(),
        .flags = .{ .truncate = true },
    }) catch return error.IoFailed;
}

/// Load jsonl into an empty transcript (messages are arena-owned via transcript).
pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    transcript: *transcript_mod.Transcript,
) Error!void {
    _ = try loadWithMeta(gpa, io, cwd, path, transcript);
}

/// Like `load`, but also returns header meta. String fields in the result are
/// duped into `transcript.arena` (live as long as the transcript arena).
pub fn loadWithMeta(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    transcript: *transcript_mod.Transcript,
) Error!SessionMeta {
    const raw = cwd.readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(raw);

    var meta: SessionMeta = .{};
    var saw_header = false;
    var saw_message = false;
    var line_start: usize = 0;
    while (line_start < raw.len) {
        const rest = raw[line_start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        line_start += nl + 1;
        if (line.len == 0) continue;

        if (isHeaderLine(line)) {
            meta = try parseHeaderLine(gpa, transcript.arena, line);
            saw_header = true;
            continue;
        }

        try appendMessageFromJson(gpa, transcript, line);
        saw_message = true;
    }

    if (!saw_message) return error.InvalidSession;
    if (!saw_header) {
        // Legacy file without header: implied schema v1.
        meta = .{};
    }
    return meta;
}

fn isHeaderLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\"") != null and
        std.mem.indexOf(u8, line, header_type) != null;
}

fn parseHeaderLine(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    line: []const u8,
) Error!SessionMeta {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
        return error.InvalidSession;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSession;
    const obj = parsed.value.object;

    const version = blk: {
        if (obj.get("schema_version")) |sv| {
            break :blk try jsonInt(sv);
        }
        if (obj.get("v")) |v| {
            break :blk try jsonInt(v);
        }
        break :blk current_schema_version;
    };
    if (version != current_schema_version) return error.UnsupportedSchema;

    var meta: SessionMeta = .{
        .schema_version = version,
        .compaction_gen = 0,
    };
    if (obj.get("compaction_gen")) |cg| {
        meta.compaction_gen = @intCast(try jsonInt(cg));
    }
    if (obj.get("zag_version")) |zv| {
        if (zv == .string) {
            meta.zag_version = arena.dupe(u8, zv.string) catch return error.OutOfMemory;
        }
    }
    if (obj.get("compaction_summary")) |cs| {
        if (cs == .string) {
            meta.compaction_summary = arena.dupe(u8, cs.string) catch return error.OutOfMemory;
        }
    }
    return meta;
}

fn jsonInt(v: std.json.Value) Error!u32 {
    return switch (v) {
        .integer => |i| blk: {
            if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidSession;
            break :blk @intCast(i);
        },
        .float => |f| blk: {
            if (f < 0 or f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidSession;
            break :blk @intFromFloat(f);
        },
        else => error.InvalidSession,
    };
}

fn writeHeader(w: *Io.Writer, meta: SessionMeta) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("schema_version");
    try s.write(meta.schema_version);
    // Legacy alias for older readers.
    try s.objectField("v");
    try s.write(meta.schema_version);
    try s.objectField("type");
    try s.write(header_type);
    if (meta.zag_version) |zv| {
        try s.objectField("zag_version");
        try s.write(zv);
    }
    try s.objectField("compaction_gen");
    try s.write(meta.compaction_gen);
    if (meta.compaction_summary) |sum| {
        try s.objectField("compaction_summary");
        try s.write(sum);
    }
    try s.endObject();
    try w.writeAll("\n");
}

fn writeMessage(w: *Io.Writer, msg: message.Message) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("role");
    try s.write(msg.role.jsonName());

    switch (msg.role) {
        .tool => {
            try s.objectField("tool_call_id");
            try s.write(msg.tool_call_id orelse "");
            try s.objectField("content");
            try s.write(msg.content);
        },
        .assistant => {
            try s.objectField("content");
            try s.write(msg.content);
            if (msg.tool_calls) |calls| {
                try s.objectField("tool_calls");
                try s.beginArray();
                for (calls) |c| {
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(c.id);
                    try s.objectField("name");
                    try s.write(c.name);
                    try s.objectField("arguments");
                    try s.write(c.arguments);
                    try s.endObject();
                }
                try s.endArray();
            }
        },
        .system, .user => {
            try s.objectField("content");
            try s.write(msg.content);
        },
    }

    try s.endObject();
    try w.writeAll("\n");
}

fn appendMessageFromJson(
    gpa: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    line: []const u8,
) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
        return error.InvalidSession;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSession;
    const obj = parsed.value.object;

    const role_v = obj.get("role") orelse return error.InvalidSession;
    if (role_v != .string) return error.InvalidSession;
    const role = parseRole(role_v.string) orelse return error.InvalidSession;

    const content = blk: {
        if (obj.get("content")) |c| {
            if (c == .string) break :blk c.string;
            if (c == .null) break :blk "";
            return error.InvalidSession;
        }
        break :blk "";
    };

    switch (role) {
        .system => try transcript.appendSystem(content),
        .user => try transcript.appendUser(content),
        .assistant => {
            if (obj.get("tool_calls")) |tc| {
                if (tc != .array) return error.InvalidSession;
                if (tc.array.items.len == 0) {
                    try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = &.{} });
                    return;
                }
                const calls = gpa.alloc(message.ToolCall, tc.array.items.len) catch
                    return error.OutOfMemory;
                defer gpa.free(calls);
                for (tc.array.items, 0..) |item, i| {
                    if (item != .object) return error.InvalidSession;
                    const id = item.object.get("id") orelse return error.InvalidSession;
                    const name = item.object.get("name") orelse return error.InvalidSession;
                    const args = item.object.get("arguments") orelse return error.InvalidSession;
                    if (id != .string or name != .string or args != .string) return error.InvalidSession;
                    calls[i] = .{
                        .id = id.string,
                        .name = name.string,
                        .arguments = args.string,
                    };
                }
                try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = calls });
            } else {
                try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = &.{} });
            }
        },
        .tool => {
            const id_v = obj.get("tool_call_id") orelse return error.InvalidSession;
            if (id_v != .string) return error.InvalidSession;
            try appendToolWithOwnedId(transcript, id_v.string, content);
        },
    }
}

fn appendToolWithOwnedId(
    transcript: *transcript_mod.Transcript,
    tool_call_id: []const u8,
    content: []const u8,
) transcript_mod.Error!void {
    const id = transcript.arena.dupe(u8, tool_call_id) catch return error.OutOfMemory;
    const body = transcript.arena.dupe(u8, content) catch return error.OutOfMemory;
    transcript.messages.append(transcript.arena, message.Message.toolResult(id, body)) catch
        return error.OutOfMemory;
}

fn parseRole(s: []const u8) ?message.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

test "save and load roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hello");
    try t1.appendAssistantTurn(.{ .content = "hi", .tool_calls = &.{} });

    try save(gpa, io, tmp.dir, "s.jsonl", t1.items());

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "s.jsonl", &t2);

    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 3), t2.items().len);
    try std.testing.expectEqualStrings("sys", t2.items()[0].content);
    try std.testing.expectEqualStrings("hello", t2.items()[1].content);
    try std.testing.expectEqualStrings("hi", t2.items()[2].content);
}

test "save load with tool_calls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("ls");
    const calls = [_]message.ToolCall{.{
        .id = "call1",
        .name = "list_dir",
        .arguments = "{\"path\":\".\"}",
    }};
    try t1.appendAssistantTurn(.{ .content = "", .tool_calls = &calls });
    try t1.appendToolResult("call1", "file\tfile\n");

    try save(gpa, io, tmp.dir, "t.jsonl", t1.items());

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    try load(gpa, io, tmp.dir, "t.jsonl", &t2);

    try std.testing.expectEqual(@as(usize, 4), t2.items().len);
    try std.testing.expect(t2.items()[2].tool_calls != null);
    try std.testing.expectEqualStrings("list_dir", t2.items()[2].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call1", t2.items()[3].tool_call_id.?);
}

test "saveWithMeta persists compaction fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hi");

    try saveWithMeta(gpa, io, tmp.dir, "m.jsonl", t1.items(), .{
        .zag_version = "0.5.0",
        .compaction_gen = 2,
        .compaction_summary = "earlier: user asked about files",
    });

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "m.jsonl", &t2);
    try std.testing.expectEqual(@as(u32, 2), meta.compaction_gen);
    try std.testing.expectEqualStrings("0.5.0", meta.zag_version.?);
    try std.testing.expectEqualStrings("earlier: user asked about files", meta.compaction_summary.?);
}

test "unsupported schema_version is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad =
        \\{"schema_version":99,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jsonl", .data = bad });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const err = load(gpa, io, tmp.dir, "bad.jsonl", &t);
    try std.testing.expectError(error.UnsupportedSchema, err);
}

test "legacy header with only v loads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy =
        \\{"v":1,"type":"zag_session"}
        \\{"role":"system","content":"sys"}
        \\{"role":"user","content":"hi"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.jsonl", .data = legacy });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "legacy.jsonl", &t);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 2), t.items().len);
}

test "headerless file still loads as v1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bare =
        \\{"role":"user","content":"only"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bare.jsonl", .data = bare });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "bare.jsonl", &t);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 1), t.items().len);
}
