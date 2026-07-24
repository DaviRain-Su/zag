//! Read-only filesystem tools: `list_dir`, `read_file`, `grep`, `glob`.
//!
//! Walk/glob are iterative (TigerStyle: no recursion; fixed upper bounds).
//! Each handler enforces symlink-aware workspace containment (h-workspace-001)
//! so raw `Registry.execute` cannot bypass the jail.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const workspace = core.workspace;

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

pub const grep_def: tool.Definition = .{
    .name = "grep",
    .description =
    \\Search for a literal substring in text files under a relative path (default ".").
    \\Returns path:line:content hits with a result budget. Absolute paths and '..' are denied by jail.
    \\Skips .git and common build dirs. Prefer this over shell grep.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Literal substring to find (not a regex)."
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Relative file or directory to search. Default \".\"."
    \\    }
    \\  },
    \\  "required": ["pattern"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const glob_def: tool.Definition = .{
    .name = "glob",
    .description =
    \\List relative file paths matching a glob under the working directory.
    \\Supports * (within a path segment) and ** (any depth). Example: "**/*.zig", "src/*.md".
    \\Optional path scopes the walk. Absolute paths and '..' are denied by jail.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": {
    \\      "type": "string",
    \\      "description": "Glob pattern relative to path (or cwd)."
    \\    },
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Relative directory to search under. Default \".\"."
    \\    }
    \\  },
    \\  "required": ["pattern"],
    \\  "additionalProperties": false
    \\}
    ,
};

const max_list_entries: u32 = 500;
const max_file_bytes: u32 = @intCast(tool.max_result_bytes);
const max_grep_hits: u32 = 80;
const max_grep_file_bytes: u32 = 256 * 1024;
const max_glob_hits: u32 = 200;
/// Hard cap on BFS nodes so walks cannot explode on huge trees.
const walk_nodes_max: u32 = 4096;
const max_walk_depth: u32 = 32;
const glob_frame_stack_max: u32 = 128;

pub fn listDir(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);

    const sub = if (path.len == 0) "." else path;

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, sub, err);
    defer guard.deinit(ctx.allocator);

    guard.checkExisting(ctx.io, ctx.cwd, sub) catch |err| {
        return jailOrFail(ctx, sub, err);
    };

    // Open without following a directory symlink that somehow changed post-check
    // when possible; verified path is contained so follow is OK for real dirs.
    var dir = ctx.cwd.openDir(ctx.io, sub, .{ .iterate = true }) catch {
        return error.ToolFailed;
    };
    defer dir.close(ctx.io);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var it = dir.iterate();
    var count: u32 = 0;
    while (it.next(ctx.io) catch return error.ToolFailed) |entry| {
        if (count >= max_list_entries) {
            out.writer.print("... truncated after {d} entries\n", .{max_list_entries}) catch
                return error.OutOfMemory;
            break;
        }
        // Symlink names are listed by kind; targets are never opened/read here.
        const kind = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
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

pub fn readFile(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);

    if (path.len == 0) return error.InvalidArguments;

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    guard.checkExisting(ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };

    const contents = ctx.cwd.readFileAlloc(
        ctx.io,
        path,
        ctx.allocator,
        .limited(max_file_bytes + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
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

pub fn grep(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const pattern = try tool.requireStringField(ctx.allocator, arguments_json, "pattern");
    defer ctx.allocator.free(pattern);
    if (pattern.len == 0) return error.InvalidArguments;

    const root = try resolveRootPath(ctx.allocator, arguments_json);
    defer ctx.allocator.free(root);

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, root, err);
    defer guard.deinit(ctx.allocator);

    // Root argument escaping/dangling → machine-readable jail_deny.
    guard.checkExisting(ctx.io, ctx.cwd, root) catch |err| {
        return jailOrFail(ctx, root, err);
    };

    var out: Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var hits: u32 = 0;
    var truncated = false;
    try walkTree(ctx, &guard, root, .{
        .kind = .grep,
        .pattern = pattern,
        .out = &out,
        .hits = &hits,
        .truncated = &truncated,
        .hits_max = max_grep_hits,
    });

    try finishSearchOutput(&out, .grep, hits, truncated, pattern);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn glob(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const pattern = try tool.requireStringField(ctx.allocator, arguments_json, "pattern");
    defer ctx.allocator.free(pattern);
    if (pattern.len == 0) return error.InvalidArguments;

    const root = try resolveRootPath(ctx.allocator, arguments_json);
    defer ctx.allocator.free(root);

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, root, err);
    defer guard.deinit(ctx.allocator);

    guard.checkExisting(ctx.io, ctx.cwd, root) catch |err| {
        return jailOrFail(ctx, root, err);
    };

    var out: Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var hits: u32 = 0;
    var truncated = false;
    try walkTree(ctx, &guard, root, .{
        .kind = .glob,
        .pattern = pattern,
        .out = &out,
        .hits = &hits,
        .truncated = &truncated,
        .hits_max = max_glob_hits,
    });

    try finishSearchOutput(&out, .glob, hits, truncated, pattern);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn obtainGuard(ctx: tool.Context) workspace.ContainError!workspace.Guard {
    return workspace.guardFrom(ctx.allocator, ctx.io, ctx.cwd, ctx.workspace_root_real);
}

fn jailOrFail(ctx: tool.Context, path: []const u8, err: workspace.ContainError) tool.HandlerError![]u8 {
    return workspace.denyBody(ctx.allocator, path, err) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.ToolFailed,
    };
}

fn resolveRootPath(gpa: std.mem.Allocator, arguments_json: []const u8) tool.HandlerError![]u8 {
    const path_opt = try tool.optionalStringField(gpa, arguments_json, "path");
    defer if (path_opt) |p| gpa.free(p);
    const root = if (path_opt) |p| (if (p.len == 0) "." else p) else ".";
    return gpa.dupe(u8, root) catch return error.OutOfMemory;
}

const WalkMode = enum { grep, glob };

fn finishSearchOutput(
    out: *Io.Writer.Allocating,
    kind: WalkMode,
    hits: u32,
    truncated: bool,
    label: []const u8,
) tool.HandlerError!void {
    if (hits == 0 and !truncated) {
        switch (kind) {
            .grep => out.writer.print("(no matches for {s})\n", .{label}) catch return error.OutOfMemory,
            .glob => out.writer.print("(no paths matched {s})\n", .{label}) catch return error.OutOfMemory,
        }
    } else if (truncated) {
        switch (kind) {
            .grep => out.writer.print("... truncated after {d} hits\n", .{max_grep_hits}) catch
                return error.OutOfMemory,
            .glob => out.writer.print("... truncated after {d} paths\n", .{max_glob_hits}) catch
                return error.OutOfMemory,
        }
    }
}

const WalkOpts = struct {
    kind: WalkMode,
    pattern: []const u8,
    out: *Io.Writer.Allocating,
    hits: *u32,
    truncated: *bool,
    hits_max: u32,
};

/// Bounded BFS over relative paths (no recursion).
/// Does not follow escaping/dangling symlinks; nested escapes are skipped (no leak).
/// Contained directory identity is deduped by real path to bound symlink loops.
fn walkTree(
    ctx: tool.Context,
    guard: *const workspace.Guard,
    root: []const u8,
    opts: WalkOpts,
) tool.HandlerError!void {
    std.debug.assert(root.len > 0);
    std.debug.assert(opts.pattern.len > 0);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| ctx.allocator.free(p);
        paths.deinit(ctx.allocator);
    }

    var visited_dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = visited_dirs.keyIterator();
        while (it.next()) |k| ctx.allocator.free(k.*);
        visited_dirs.deinit(ctx.allocator);
    }

    try paths.append(ctx.allocator, try ctx.allocator.dupe(u8, root));

    var index: u32 = 0;
    while (index < paths.items.len) : (index += 1) {
        if (opts.truncated.*) return;
        if (index >= walk_nodes_max) {
            opts.truncated.* = true;
            return;
        }

        const rel = paths.items[index];
        std.debug.assert(rel.len > 0);

        // Containment: skip nested escapes/dangling without leaking outside bytes.
        // Root was already verified by the caller; re-check for children.
        if (index != 0) {
            guard.checkExisting(ctx.io, ctx.cwd, rel) catch continue;
        }

        const st = ctx.cwd.statFile(ctx.io, rel, .{
            .follow_symlinks = true,
        }) catch continue;

        switch (st.kind) {
            .file => {
                try visitFile(ctx, rel, opts);
            },
            .directory => {
                const real_owned = (try resolveRealOwned(ctx, rel)) orelse continue;
                if (visited_dirs.contains(real_owned)) {
                    ctx.allocator.free(real_owned);
                    continue;
                }
                visited_dirs.put(ctx.allocator, real_owned, {}) catch {
                    ctx.allocator.free(real_owned);
                    return error.OutOfMemory;
                };
                try enqueueDirChildren(ctx, rel, &paths);
            },
            else => {},
        }
    }
}

fn resolveRealOwned(ctx: tool.Context, rel: []const u8) error{OutOfMemory}!?[]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = ctx.cwd.realPathFile(ctx.io, rel, &buf) catch return null;
    return ctx.allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
}

fn visitFile(ctx: tool.Context, rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    switch (opts.kind) {
        .grep => try grepFile(ctx, rel, opts),
        .glob => try globFile(rel, opts),
    }
}

fn enqueueDirChildren(
    ctx: tool.Context,
    rel: []const u8,
    paths: *std.ArrayList([]u8),
) tool.HandlerError!void {
    if (pathDepth(rel) >= max_walk_depth) return;

    // Directory was containment-checked; open it. Do not follow an unexpected
    // symlink-at-open by preferring iterate on the verified path.
    var dir = ctx.cwd.openDir(ctx.io, rel, .{ .iterate = true, .follow_symlinks = true }) catch return;
    defer dir.close(ctx.io);

    var it = dir.iterate();
    var entries_seen: u32 = 0;
    while (it.next(ctx.io) catch return) |entry| {
        entries_seen += 1;
        if (entries_seen > walk_nodes_max) return;
        if (shouldSkipDir(entry.name)) continue;

        const child = if (std.mem.eql(u8, rel, "."))
            ctx.allocator.dupe(u8, entry.name) catch return error.OutOfMemory
        else
            std.fs.path.join(ctx.allocator, &.{ rel, entry.name }) catch return error.OutOfMemory;

        if (paths.items.len >= walk_nodes_max) {
            ctx.allocator.free(child);
            return;
        }
        paths.append(ctx.allocator, child) catch {
            ctx.allocator.free(child);
            return error.OutOfMemory;
        };
    }
}

fn pathDepth(rel: []const u8) u32 {
    if (std.mem.eql(u8, rel, ".")) return 0;
    var depth: u32 = 0;
    for (rel) |c| {
        if (c == '/' or c == '\\') depth += 1;
    }
    return depth + 1;
}

fn grepFile(ctx: tool.Context, rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    if (opts.truncated.*) return;

    const contents = ctx.cwd.readFileAlloc(
        ctx.io,
        rel,
        ctx.allocator,
        .limited(max_grep_file_bytes),
    ) catch return;
    defer ctx.allocator.free(contents);

    // Skip likely-binary files (NUL in the first chunk).
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return;

    var line_no: u32 = 1;
    var start: usize = 0;
    while (start <= contents.len) {
        const end = std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse contents.len;
        const line = contents[start..end];
        if (std.mem.indexOf(u8, line, opts.pattern) != null) {
            if (opts.hits.* >= opts.hits_max) {
                opts.truncated.* = true;
                return;
            }
            if (opts.out.written().len + line.len + rel.len + 32 > tool.max_result_bytes) {
                opts.truncated.* = true;
                return;
            }
            opts.out.writer.print("{s}:{d}:{s}\n", .{ rel, line_no, line }) catch
                return error.OutOfMemory;
            opts.hits.* += 1;
        }
        if (end == contents.len) break;
        start = end + 1;
        line_no += 1;
    }
}

fn globFile(rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    if (!matchGlob(opts.pattern, rel)) return;
    if (opts.hits.* >= opts.hits_max) {
        opts.truncated.* = true;
        return;
    }
    opts.out.writer.print("{s}\n", .{rel}) catch return error.OutOfMemory;
    opts.hits.* += 1;
}

fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "target");
}

/// Glob: `*` = within one path segment; `**` = any depth (including `/`).
/// Iterative backtracking stack — no call recursion.
pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    const Frame = struct { pat_index: u32, text_index: u32 };

    var stack: [glob_frame_stack_max]Frame = undefined;
    var stack_len: u32 = 0;
    stack[0] = .{ .pat_index = 0, .text_index = 0 };
    stack_len = 1;

    while (stack_len > 0) {
        stack_len -= 1;
        var pat_index = stack[stack_len].pat_index;
        var text_index = stack[stack_len].text_index;

        while (true) {
            if (pat_index == pattern.len) {
                if (text_index == path.len) return true;
                break;
            }

            if (pat_index + 1 < pattern.len and
                pattern[pat_index] == '*' and
                pattern[pat_index + 1] == '*')
            {
                var rest: u32 = pat_index + 2;
                if (rest < pattern.len and pattern[rest] == '/') rest += 1;
                if (rest == pattern.len) return true;

                // Try every split point; push frames (bounded).
                var split: u32 = text_index;
                while (split <= path.len) : (split += 1) {
                    if (stack_len >= glob_frame_stack_max) break;
                    stack[stack_len] = .{ .pat_index = rest, .text_index = split };
                    stack_len += 1;
                }
                break;
            }

            if (pattern[pat_index] == '*') {
                // Match zero or more chars that are not '/'.
                var split: u32 = text_index;
                while (true) {
                    if (stack_len >= glob_frame_stack_max) break;
                    stack[stack_len] = .{
                        .pat_index = pat_index + 1,
                        .text_index = split,
                    };
                    stack_len += 1;
                    if (split == path.len) break;
                    if (path[split] == '/') break;
                    split += 1;
                }
                break;
            }

            if (text_index == path.len) break;
            if (pattern[pat_index] != path[text_index] and pattern[pat_index] != '?') break;
            pat_index += 1;
            text_index += 1;
        }
    }
    return false;
}

const path_read_caps: tool.ToolCapabilities = .{
    .risk = .read,
    .workspace = .{ .path_field = "path" },
    .cancellation = .none,
    .shell = .none,
};

pub fn phase0Tools() [2]tool.Tool {
    return .{
        tool.stateless(.{ .definition = list_dir_def, .capabilities = path_read_caps }, listDir),
        tool.stateless(.{ .definition = read_file_def, .capabilities = path_read_caps }, readFile),
    };
}

pub fn searchTools() [2]tool.Tool {
    return .{
        tool.stateless(.{ .definition = grep_def, .capabilities = path_read_caps }, grep),
        tool.stateless(.{ .definition = glob_def, .capabilities = path_read_caps }, glob),
    };
}

test "list_dir and read_file on project files" {
    // Goal: smoke-test registry dispatch against the real workspace.
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
    try std.testing.expect(std.mem.indexOf(u8, unknown, "code=unknown_tool") != null);
}

test "matchGlob basics" {
    // Goal: cover segment `*`, recursive `**`, and non-match across `/`.
    try std.testing.expect(matchGlob("*.zig", "main.zig"));
    try std.testing.expect(!matchGlob("*.zig", "src/main.zig"));
    try std.testing.expect(matchGlob("**/*.zig", "src/main.zig"));
    try std.testing.expect(matchGlob("src/*.zig", "src/main.zig"));
    try std.testing.expect(!matchGlob("src/*.zig", "src/a/main.zig"));
}

test "grep and glob in tmp dir" {
    // Goal: jail deny + literal grep + recursive glob on a tiny tree.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const x = 1;\nfindme here\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.md", .data = "nope\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "findme top\n" });

    const ctx: tool.Context = .{
        .allocator = gpa,
        .io = io,
        .cwd = tmp.dir,
    };

    const hits = try grep(ctx, null, "{\"pattern\":\"findme\"}");
    defer gpa.free(hits);
    try std.testing.expect(std.mem.indexOf(u8, hits, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, hits, "readme.txt") != null);

    const abs = try grep(ctx, null, "{\"pattern\":\"x\",\"path\":\"/etc\"}");
    defer gpa.free(abs);
    try std.testing.expect(std.mem.indexOf(u8, abs, "code=jail_deny") != null);

    const paths = try glob(ctx, null, "{\"pattern\":\"**/*.zig\"}");
    defer gpa.free(paths);
    try std.testing.expect(std.mem.indexOf(u8, paths, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths, "b.md") == null);
}

/// Sibling outside + workspace fixture for symlink containment (not nested outside).
const SymlinkFixture = struct {
    parent: std.testing.TmpDir,
    ws: Io.Dir,

    fn setup(io: Io) !SymlinkFixture {
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

        var parent = std.testing.tmpDir(.{ .iterate = true });
        errdefer parent.cleanup();

        try parent.dir.createDirPath(io, "outside");
        try parent.dir.createDirPath(io, "ws");
        try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "OUTSIDE_SECRET_MARKER\n" });
        try parent.dir.writeFile(io, .{ .sub_path = "ws/inside.txt", .data = "inside-ok findme\n" });
        try parent.dir.createDirPath(io, "ws/sub");
        try parent.dir.writeFile(io, .{ .sub_path = "ws/sub/nested.txt", .data = "nested findme\n" });

        var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
        errdefer ws.close(io);

        // Escaping file symlink
        try ws.symLink(io, "../outside/secret.txt", "escape_file", .{});
        // Contained file symlink
        try ws.symLink(io, "inside.txt", "link_in", .{});
        // Contained directory symlink
        try ws.symLink(io, "sub", "link_dir", .{ .is_directory = true });
        // Nested escaping symlink
        try ws.symLink(io, "../../outside/secret.txt", "sub/escape_nested", .{});
        // Dangling
        try ws.symLink(io, "../missing-target", "dangling", .{});
        // Directory escape
        try ws.symLink(io, "../outside", "escape_dir", .{ .is_directory = true });
        // Symlink loop (bounded by walker)
        try ws.createDirPath(io, "loop_a");
        try ws.createDirPath(io, "loop_b");
        try ws.symLink(io, "../loop_b", "loop_a/to_b", .{ .is_directory = true });
        try ws.symLink(io, "../loop_a", "loop_b/to_a", .{ .is_directory = true });
        try ws.writeFile(io, .{ .sub_path = "loop_a/note.txt", .data = "loop-note findme\n" });

        return .{ .parent = parent, .ws = ws };
    }

    fn cleanup(self: *SymlinkFixture, io: Io) void {
        self.ws.close(io);
        self.parent.cleanup();
    }

    fn ctx(self: *SymlinkFixture, gpa: std.mem.Allocator, io: Io) tool.Context {
        return .{ .allocator = gpa, .io = io, .cwd = self.ws };
    }
};

test "symlink containment: read/list/grep/glob deny escape, allow contained" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var fix = try SymlinkFixture.setup(io);
    defer fix.cleanup(io);
    const ctx = fix.ctx(gpa, io);

    // read escaping symlink → jail_deny, no outside bytes
    const esc = try readFile(ctx, null, "{\"path\":\"escape_file\"}");
    defer gpa.free(esc);
    try std.testing.expect(std.mem.indexOf(u8, esc, "code=jail_deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, esc, "OUTSIDE_SECRET") == null);

    // list escaping dir symlink → jail_deny
    const list_esc = try listDir(ctx, null, "{\"path\":\"escape_dir\"}");
    defer gpa.free(list_esc);
    try std.testing.expect(std.mem.indexOf(u8, list_esc, "code=jail_deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_esc, "secret.txt") == null);

    // list workspace root: symlink names OK, no follow
    const listing = try listDir(ctx, null, "{\"path\":\".\"}");
    defer gpa.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "escape_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing, "OUTSIDE_SECRET") == null);

    // contained file symlink works
    const linked = try readFile(ctx, null, "{\"path\":\"link_in\"}");
    defer gpa.free(linked);
    try std.testing.expect(std.mem.indexOf(u8, linked, "inside-ok") != null);

    // contained dir symlink list works
    const list_in = try listDir(ctx, null, "{\"path\":\"link_dir\"}");
    defer gpa.free(list_in);
    try std.testing.expect(std.mem.indexOf(u8, list_in, "nested.txt") != null);

    // grep root escape → jail_deny
    const grep_esc = try grep(ctx, null, "{\"pattern\":\"OUTSIDE\",\"path\":\"escape_dir\"}");
    defer gpa.free(grep_esc);
    try std.testing.expect(std.mem.indexOf(u8, grep_esc, "code=jail_deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep_esc, "OUTSIDE_SECRET") == null);

    // grep workspace: finds inside, does not leak nested escape
    const grep_ok = try grep(ctx, null, "{\"pattern\":\"findme\"}");
    defer gpa.free(grep_ok);
    try std.testing.expect(std.mem.indexOf(u8, grep_ok, "inside.txt") != null or std.mem.indexOf(u8, grep_ok, "inside-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep_ok, "OUTSIDE_SECRET") == null);

    // glob: no outside paths
    const glob_all = try glob(ctx, null, "{\"pattern\":\"**/*\"}");
    defer gpa.free(glob_all);
    try std.testing.expect(std.mem.indexOf(u8, glob_all, "OUTSIDE_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, glob_all, "secret.txt") == null);

    // dangling path deny
    const dang = try readFile(ctx, null, "{\"path\":\"dangling\"}");
    defer gpa.free(dang);
    try std.testing.expect(std.mem.indexOf(u8, dang, "code=jail_deny") != null);

    // ordinary missing → ToolFailed (not jail_deny)
    const missing = readFile(ctx, null, "{\"path\":\"no_such_file.txt\"}");
    try std.testing.expectError(error.ToolFailed, missing);

    // loop walker is bounded (does not hang / OOM)
    const loop_grep = try grep(ctx, null, "{\"pattern\":\"loop-note\",\"path\":\".\"}");
    defer gpa.free(loop_grep);
    try std.testing.expect(std.mem.indexOf(u8, loop_grep, "loop-note") != null or std.mem.indexOf(u8, loop_grep, "note.txt") != null);
}
