const std = @import("std");
const zig = std.zig;

const embedded_json = @embedFile("entities.json");

pub fn main(minimal: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = try std.process.Args.iterateAllocator(minimal.args, alloc);
    defer args.deinit();
    _ = args.next(); // argv[0]
    const out_file_path = args.next() orelse std.debug.panic("wrong number of arguments", .{});

    var tree = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        embedded_json,
        .{},
    );

    var buffer = std.array_list.Managed(u8).init(alloc);
    var writer = std.Io.Writer.Allocating.init(alloc);
    defer writer.deinit();

    try writer.writer.writeAll(
        \\pub const Entity = struct {
        \\    entity: []const u8,
        \\    codepoints: Codepoints,
        \\    characters: []const u8,
        \\};
        \\
        \\pub const Codepoints = union(enum) {
        \\    Single: u32,
        \\    Double: [2]u32,
        \\};
        \\
        \\pub const ENTITIES = [_]Entity{
        \\
    );

    var keys = try std.ArrayList([]const u8).initCapacity(
        alloc,
        tree.value.object.count(),
    );

    var entries_it = tree.value.object.iterator();
    while (entries_it.next()) |entry| {
        keys.appendAssumeCapacity(entry.key_ptr.*);
    }

    std.mem.sortUnstable([]const u8, keys.items, {}, strLessThan);

    for (keys.items) |key| {
        var value = tree.value.object.get(key).?.object;

        try writer.writer.print(
            ".{{ .entity = \"{s}\", .codepoints = ",
            .{try escapeString(alloc, key)},
        );

        const codepoints_array = value.get("codepoints").?.array;
        if (codepoints_array.items.len == 1) {
            try writer.writer.print(
                ".{{ .Single = {} }}, ",
                .{codepoints_array.items[0].integer},
            );
        } else {
            try writer.writer.print(
                ".{{ .Double = [2]u32{{ {}, {} }} }}, ",
                .{
                    codepoints_array.items[0].integer,
                    codepoints_array.items[1].integer,
                },
            );
        }

        try writer.writer.print(
            ".characters = \"{s}\" }},\n",
            .{try escapeString(alloc, value.get("characters").?.string)},
        );
    }

    try writer.writer.writeAll("};\n");

    try buffer.appendSlice(writer.written());
    try buffer.append(0);

    const formatted = f: {
        var zig_tree = try zig.Ast.parse(
            alloc,
            buffer.items[0 .. buffer.items.len - 1 :0],
            .zig,
        );

        defer zig_tree.deinit(alloc);
        break :f try zig_tree.renderAlloc(alloc);
    };

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_file_path,
        .data = formatted,
    });
}

fn strLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn escapeString(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    try std.zig.stringEscape(bytes, &w.writer);
    return w.written();
}
