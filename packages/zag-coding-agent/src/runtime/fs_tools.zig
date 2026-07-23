//! Phase 0 read-only filesystem tools: `list_dir` and `read_file`.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;

pub const list_dir_def: tool.Definition = .{
    .name = "list_dir",
    .description =
        \\List entries in a directory relative to the working directory.
        \\Returns one entry per line as "name\tkind" where kind is file, directory, or other.
    ,
    .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "Directory path relative to the working directory. Use \".\" for the current directory."
        \\    }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
    ,
};

pub const read_file_def: tool.Definition = .{
    .name = "read_file",
    .description =
        \\Read a UTF-8 text file relative to the working directory.
        \\Large files are truncated. Returns the file contents as text.
    ,
    .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": {
        \\      "type": "string",
        \\      "description": "File path relative to the working directory."
        \\    }
        \\  },
        \\  "required": ["path"],
        \\  "additionalProperties": false
        \\}
    ,
};

const max_list_entries: usize = 500;
const max_file_bytes: usize = tool.max_result_bytes;

pub fn listDir(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);

    const sub = if (path.len == 0) "." else path;

    var dir = ctx.cwd.openDir(ctx.io, sub, .{ .iterate = true }) catch {
        return error.ToolFailed;
    };
    defer dir.close(ctx.io);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(ctx.io) catch return error.ToolFailed) |entry| {
        if (count >= max_list_entries) {
            out.writer.print("... truncated after {d} entries\n", .{max_list_entries}) catch
                return error.OutOfMemory;
            break;
        }
        const kind = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            else => "other",
        };
        out.writer.print("{s}\t{s}\n", .{ entry.name, kind }) catch return error.OutOfMemory;
        count += 1;
    }

    if (count == 0) {
        out.writer.writeAll("(empty directory)\n") catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn readFile(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);

    if (path.len == 0) return error.InvalidArguments;

    const contents = ctx.cwd.readFileAlloc(
        ctx.io,
        path,
        ctx.allocator,
        .limited(max_file_bytes + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            // Still return the first max_file_bytes when possible.
            const partial = ctx.cwd.readFileAlloc(
                ctx.io,
                path,
                ctx.allocator,
                .limited(max_file_bytes),
            ) catch return error.ToolFailed;
            defer ctx.allocator.free(partial);
            return std.fmt.allocPrint(
                ctx.allocator,
                "{s}\n\n... truncated at {d} bytes\n",
                .{ partial, max_file_bytes },
            ) catch return error.OutOfMemory;
        },
        else => return error.ToolFailed,
    };

    return contents;
}

pub fn phase0Tools() [2]tool.Tool {
    return .{
        .{ .definition = list_dir_def, .handler = listDir },
        .{ .definition = read_file_def, .handler = readFile },
    };
}

test "list_dir and read_file on project files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const tools = phase0Tools();
    const registry: tool.Registry = .{ .tools = &tools };
    const ctx: tool.Context = .{
        .allocator = gpa,
        .io = io,
        .cwd = Io.Dir.cwd(),
    };

    const listing = try registry.execute(ctx, "list_dir", "{\"path\":\".\"}");
    defer gpa.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "build.zig") != null);

    const build_txt = try registry.execute(ctx, "read_file", "{\"path\":\"build.zig\"}");
    defer gpa.free(build_txt);
    try std.testing.expect(std.mem.indexOf(u8, build_txt, "pub fn build") != null);

    const unknown = try registry.execute(ctx, "nope", "{}");
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "unknown tool") != null);
}
