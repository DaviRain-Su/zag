//! Session durability — JSONL transcript on disk.
//!
//! Format (one JSON object per line):
//! ```
//! {"v":1,"type":"zag_session"}
//! {"role":"system","content":"..."}
//! {"role":"user","content":"..."}
//! {"role":"assistant","content":"...","tool_calls":[{"id":"...","name":"...","arguments":"..."}]}
//! {"role":"tool","tool_call_id":"...","content":"..."}
//! ```

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const transcript_mod = @import("transcript.zig");

pub const Error = error{
    OutOfMemory,
    IoFailed,
    InvalidSession,
};

pub const header_type = "zag_session";

/// Write full transcript to `path` (creates parent dirs). Overwrites existing file.
pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
) Error!void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) {
            cwd.createDirPath(io, dir_path) catch return error.IoFailed;
        }
    }

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    writeHeader(&body.writer) catch return error.OutOfMemory;
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
    const raw = cwd.readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(raw);

    var line_start: usize = 0;
    var saw_message = false;
    while (line_start < raw.len) {
        const rest = raw[line_start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        line_start += nl + 1;
        if (line.len == 0) continue;

        // Header line (optional).
        if (std.mem.indexOf(u8, line, "\"type\"") != null and std.mem.indexOf(u8, line, header_type) != null) {
            continue;
        }

        try appendMessageFromJson(gpa, transcript, line);
        saw_message = true;
    }

    if (!saw_message) return error.InvalidSession;
}

fn writeHeader(w: *Io.Writer) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("v");
    try s.write(1);
    try s.objectField("type");
    try s.write(header_type);
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
                // Build temporary calls on gpa then let appendAssistantTurn copy into arena.
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
            // tool_call_id must be owned by transcript arena for later appendToolResult pattern;
            // appendToolResult only dupes content — id is stored as-is. Dup into arena via helper.
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
    try load(gpa, io, tmp.dir, "s.jsonl", &t2);

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
