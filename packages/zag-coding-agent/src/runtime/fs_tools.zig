//! Read-only filesystem tools: `list_dir`, `read_file`, `grep`, `glob`.
//!
//! Walk/glob are iterative (TigerStyle: no recursion; fixed upper bounds).
//! Each handler enforces symlink-aware workspace containment (h-workspace-001)
//! so raw `Registry.execute` cannot bypass the jail.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const workspace = @import("../workspace.zig");

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
const max_dir_entries: u32 = 4096;
const glob_frame_stack_max: u32 = 128;
const binary_probe_bytes: usize = 4096;

const FsLimitReason = enum {
    body_limit,
    entry_limit,
    hit_limit,
    node_limit,
    depth_limit,
    source_limit,
    io_skip,
    pattern_limit,

    fn text(self: FsLimitReason) []const u8 {
        return switch (self) {
            .body_limit => "body_limit",
            .entry_limit => "entry_limit",
            .hit_limit => "hit_limit",
            .node_limit => "node_limit",
            .depth_limit => "depth_limit",
            .source_limit => "source_limit",
            .io_skip => "io_skip",
            .pattern_limit => "pattern_limit",
        };
    }
};

const incomplete_prefix = "... incomplete: format=fs-v1 reason=";
const incomplete_suffix = "\n";
const max_reason_text_len = "pattern_limit".len;
const max_incomplete_marker_len = incomplete_prefix.len + max_reason_text_len + incomplete_suffix.len;

const FsLimits = struct {
    body_bytes: usize = tool.max_result_bytes,
    list_entries: u32 = max_list_entries,
    file_bytes: usize = max_file_bytes,
    grep_hits: u32 = max_grep_hits,
    grep_file_bytes: usize = max_grep_file_bytes,
    glob_hits: u32 = max_glob_hits,
    walk_nodes: u32 = walk_nodes_max,
    walk_depth: u32 = max_walk_depth,
    dir_entries: u32 = max_dir_entries,
    glob_frames: u32 = glob_frame_stack_max,
};

var test_limits: ?FsLimits = null;

const TestFaultPoint = enum {
    list_iter_next,
    grep_stat,
    grep_read,
    binary_probe_short_once,
    read_after_open_grow,
    walk_check_existing,
    walk_realpath,
};

const TestFaults = struct {
    point: TestFaultPoint,
    observed: bool = false,
};

var test_faults: ?*TestFaults = null;

fn takeTestFault(point: TestFaultPoint) bool {
    if (builtin.is_test) {
        if (test_faults) |faults| {
            if (!faults.observed and faults.point == point) {
                faults.observed = true;
                return true;
            }
        }
    }
    return false;
}

fn activeLimits() FsLimits {
    if (builtin.is_test) {
        if (test_limits) |limits| return limits;
    }
    return .{};
}

fn markerLen(reason: FsLimitReason) usize {
    return incomplete_prefix.len + reason.text().len + incomplete_suffix.len;
}

const LimitedBody = struct {
    out: Io.Writer.Allocating,
    limit: usize,
    reason: ?FsLimitReason = null,

    fn init(gpa: std.mem.Allocator, limit: usize) LimitedBody {
        return .{ .out = .init(gpa), .limit = limit };
    }

    fn deinit(self: *LimitedBody) void {
        self.out.deinit();
    }

    fn writtenLen(self: *LimitedBody) usize {
        return self.out.written().len;
    }

    fn setIncomplete(self: *LimitedBody, reason: FsLimitReason) void {
        if (self.reason == null) self.reason = reason;
    }

    fn canAppend(self: *LimitedBody, bytes_len: usize, if_omitted: FsLimitReason) bool {
        _ = if_omitted;
        const with_item = std.math.add(usize, self.writtenLen(), bytes_len) catch return false;
        const with_marker = std.math.add(usize, with_item, max_incomplete_marker_len) catch return false;
        return with_marker <= self.limit;
    }

    fn appendRaw(self: *LimitedBody, bytes: []const u8, if_omitted: FsLimitReason) tool.HandlerError!bool {
        if (!self.canAppend(bytes.len, if_omitted)) {
            self.setIncomplete(.body_limit);
            return false;
        }
        self.out.writer.writeAll(bytes) catch return error.OutOfMemory;
        return true;
    }

    fn appendOwnedLine(self: *LimitedBody, line: []const u8, if_omitted: FsLimitReason) tool.HandlerError!bool {
        const bytes_len = std.math.add(usize, line.len, 1) catch {
            self.setIncomplete(.body_limit);
            return false;
        };
        if (!self.canAppend(bytes_len, if_omitted)) {
            self.setIncomplete(.body_limit);
            return false;
        }
        self.out.writer.print("{s}\n", .{line}) catch return error.OutOfMemory;
        return true;
    }

    fn appendFmtLine(self: *LimitedBody, comptime fmt: []const u8, args: anytype, if_omitted: FsLimitReason) tool.HandlerError!bool {
        const gpa = self.out.allocator;
        const line = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
        defer gpa.free(line);
        return self.appendOwnedLine(line, if_omitted);
    }

    fn finish(self: *LimitedBody) tool.HandlerError![]u8 {
        if (self.reason) |reason| {
            const len = markerLen(reason);
            const final_len = std.math.add(usize, self.writtenLen(), len) catch return error.OutOfMemory;
            if (final_len > self.limit) return error.OutOfMemory;
            self.out.writer.print("{s}{s}{s}", .{ incomplete_prefix, reason.text(), incomplete_suffix }) catch return error.OutOfMemory;
        }
        std.debug.assert(self.out.written().len <= self.limit);
        return self.out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

pub fn listDir(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);
    if (path.len == 0) return error.InvalidArguments;

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    guard.checkExisting(ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };

    // Open without following a directory symlink that somehow changed post-check
    // when possible; verified path is contained so follow is OK for real dirs.
    var dir = ctx.cwd.openDir(ctx.io, path, .{ .iterate = true }) catch {
        return error.ToolFailed;
    };
    defer dir.close(ctx.io);

    const limits = activeLimits();
    var body = LimitedBody.init(ctx.allocator, limits.body_bytes);
    errdefer body.deinit();

    var it = dir.iterate();
    var count: u32 = 0;
    while (true) {
        const maybe_entry = nextListEntry(ctx, &it) catch {
            body.setIncomplete(.io_skip);
            break;
        };
        const entry = maybe_entry orelse break;
        if (count >= limits.list_entries) {
            body.setIncomplete(.entry_limit);
            break;
        }
        // Symlink names are listed by kind; targets are never opened/read here.
        const kind = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "other",
        };
        if (!try body.appendFmtLine("{s}\t{s}", .{ entry.name, kind }, .entry_limit)) break;
        count = std.math.add(u32, count, 1) catch return error.OutOfMemory;
    }

    if (count == 0 and body.reason == null) {
        _ = try body.appendOwnedLine("(empty directory)", .body_limit);
    }

    return body.finish();
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

    const limits = activeLimits();
    return readFileBounded(ctx, path, limits);
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

    const limits = activeLimits();
    var body = LimitedBody.init(ctx.allocator, limits.body_bytes);
    errdefer body.deinit();
    if (try isDirectScopeFixedExcluded(ctx, &guard, root)) {
        const hits: u32 = 0;
        try finishSearchOutput(&body, .grep, hits, pattern);
        return body.finish();
    }

    var hits: u32 = 0;
    try walkTree(ctx, &guard, root, .{
        .kind = .grep,
        .pattern = pattern,
        .scope_root = ".",
        .body = &body,
        .hits = &hits,
        .hits_max = limits.grep_hits,
        .limits = limits,
    });

    try finishSearchOutput(&body, .grep, hits, pattern);
    return body.finish();
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

    const limits = activeLimits();
    var body = LimitedBody.init(ctx.allocator, limits.body_bytes);
    errdefer body.deinit();
    if (try isDirectScopeFixedExcluded(ctx, &guard, root)) {
        const hits: u32 = 0;
        try finishSearchOutput(&body, .glob, hits, pattern);
        return body.finish();
    }

    const scope_root = try normalizeRelativeForGlob(ctx.allocator, root);
    defer ctx.allocator.free(scope_root);

    var hits: u32 = 0;
    try walkTree(ctx, &guard, root, .{
        .kind = .glob,
        .pattern = pattern,
        .scope_root = scope_root,
        .body = &body,
        .hits = &hits,
        .hits_max = limits.glob_hits,
        .limits = limits,
    });

    try finishSearchOutput(&body, .glob, hits, pattern);
    return body.finish();
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

fn nextListEntry(ctx: tool.Context, it: *Io.Dir.Iterator) !?Io.Dir.Entry {
    if (takeTestFault(.list_iter_next)) return error.SystemResources;
    return it.next(ctx.io);
}

fn readFileBounded(ctx: tool.Context, path: []const u8, limits: FsLimits) tool.HandlerError![]u8 {
    const complete_limit = @min(limits.body_bytes, limits.file_bytes);
    const sentinel_len = std.math.add(usize, complete_limit, 1) catch return error.OutOfMemory;
    const bytes = try readFilePrefixAlloc(ctx, path, sentinel_len);
    defer ctx.allocator.free(bytes);

    if (bytes.len <= complete_limit) {
        const owned = ctx.allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
        @memcpy(owned, bytes);
        return owned;
    }

    const prefix_len = limits.body_bytes - max_incomplete_marker_len;
    const prefix = bytes[0..@min(prefix_len, bytes.len)];
    var body = LimitedBody.init(ctx.allocator, limits.body_bytes);
    errdefer body.deinit();
    if (!try body.appendRaw(prefix, .body_limit)) return body.finish();
    body.setIncomplete(.body_limit);
    return body.finish();
}

fn readFilePrefixAlloc(ctx: tool.Context, path: []const u8, prefix_len: usize) tool.HandlerError![]u8 {
    const buf = ctx.allocator.alloc(u8, prefix_len) catch return error.OutOfMemory;
    errdefer ctx.allocator.free(buf);

    var file = ctx.cwd.openFile(ctx.io, path, .{}) catch return error.ToolFailed;
    defer file.close(ctx.io);

    if (takeTestFault(.read_after_open_grow)) {
        const grown = ctx.allocator.alloc(u8, prefix_len) catch return error.OutOfMemory;
        defer ctx.allocator.free(grown);
        @memset(grown, 'r');
        ctx.cwd.writeFile(ctx.io, .{ .sub_path = path, .data = grown }) catch return error.ToolFailed;
    }

    var filled: usize = 0;
    while (filled < prefix_len) {
        const n = file.readPositional(ctx.io, &.{buf[filled..prefix_len]}, filled) catch return error.ToolFailed;
        if (n == 0) break;
        filled = std.math.add(usize, filled, n) catch return error.OutOfMemory;
    }
    if (filled == prefix_len) return buf;
    const exact = ctx.allocator.alloc(u8, filled) catch return error.OutOfMemory;
    @memcpy(exact, buf[0..filled]);
    ctx.allocator.free(buf);
    return exact;
}

fn resolveRootPath(gpa: std.mem.Allocator, arguments_json: []const u8) tool.HandlerError![]u8 {
    const path_opt = try tool.optionalStringField(gpa, arguments_json, "path");
    defer if (path_opt) |p| gpa.free(p);
    const root = if (path_opt) |p| (if (p.len == 0) "." else p) else ".";
    return gpa.dupe(u8, root) catch return error.OutOfMemory;
}

const WalkMode = enum { grep, glob };

fn finishSearchOutput(
    body: *LimitedBody,
    kind: WalkMode,
    hits: u32,
    label: []const u8,
) tool.HandlerError!void {
    if (hits == 0 and body.reason == null) {
        switch (kind) {
            .grep => _ = try body.appendFmtLine("(no matches for {s})", .{label}, .body_limit),
            .glob => _ = try body.appendFmtLine("(no paths matched {s})", .{label}, .body_limit),
        }
    }
}

const WalkOpts = struct {
    kind: WalkMode,
    pattern: []const u8,
    scope_root: []const u8,
    body: *LimitedBody,
    hits: *u32,
    hits_max: u32,
    limits: FsLimits,
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

    {
        const root_owned = try ctx.allocator.dupe(u8, root);
        errdefer ctx.allocator.free(root_owned);
        try paths.append(ctx.allocator, root_owned);
    }

    var index: u32 = 0;
    while (index < paths.items.len) : (index += 1) {
        if (opts.body.reason != null) return;
        if (index >= opts.limits.walk_nodes) {
            opts.body.setIncomplete(.node_limit);
            return;
        }

        const rel = paths.items[index];
        std.debug.assert(rel.len > 0);

        // Containment: skip nested escapes/dangling without leaking outside bytes.
        // Root was already verified by the caller; re-check for children.
        // OutOfMemory must propagate (never swallow as skip).
        if (index != 0) {
            checkNestedExisting(ctx, guard, rel) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OutsideWorkspace, error.InvalidPath, error.NotFound => continue,
                error.ResolveFailed => {
                    opts.body.setIncomplete(.io_skip);
                    return;
                },
            };
        }

        const st = ctx.cwd.statFile(ctx.io, rel, .{
            .follow_symlinks = true,
        }) catch {
            opts.body.setIncomplete(.io_skip);
            return;
        };

        switch (st.kind) {
            .file => {
                try visitFile(ctx, rel, opts);
            },
            .directory => {
                const real_owned = resolveRealOwned(ctx, rel) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.IoSkip => {
                        opts.body.setIncomplete(.io_skip);
                        return;
                    },
                };
                if (visited_dirs.contains(real_owned)) {
                    ctx.allocator.free(real_owned);
                    continue;
                }
                visited_dirs.put(ctx.allocator, real_owned, {}) catch {
                    ctx.allocator.free(real_owned);
                    return error.OutOfMemory;
                };
                try enqueueDirChildren(ctx, guard, rel, &paths, opts);
            },
            else => {},
        }
    }
}

fn checkNestedExisting(ctx: tool.Context, guard: *const workspace.Guard, rel: []const u8) workspace.ContainError!void {
    if (takeTestFault(.walk_check_existing)) return error.ResolveFailed;
    return guard.checkExisting(ctx.io, ctx.cwd, rel);
}

fn resolveRealOwned(ctx: tool.Context, rel: []const u8) error{ OutOfMemory, IoSkip }![]u8 {
    if (takeTestFault(.walk_realpath)) return error.IoSkip;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = ctx.cwd.realPathFile(ctx.io, rel, &buf) catch return error.IoSkip;
    return ctx.allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
}

fn visitFile(ctx: tool.Context, rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    switch (opts.kind) {
        .grep => try grepFile(ctx, rel, opts),
        .glob => try globFile(ctx, rel, opts),
    }
}

fn enqueueDirChildren(
    ctx: tool.Context,
    guard: *const workspace.Guard,
    rel: []const u8,
    paths: *std.ArrayList([]u8),
    opts: WalkOpts,
) tool.HandlerError!void {
    const depth = pathDepth(rel) orelse {
        opts.body.setIncomplete(.depth_limit);
        return;
    };
    if (depth >= opts.limits.walk_depth) {
        opts.body.setIncomplete(.depth_limit);
        return;
    }

    // Directory was containment-checked; open it. Do not follow an unexpected
    // symlink-at-open by preferring iterate on the verified path.
    var dir = ctx.cwd.openDir(ctx.io, rel, .{ .iterate = true, .follow_symlinks = true }) catch {
        opts.body.setIncomplete(.io_skip);
        return;
    };
    defer dir.close(ctx.io);

    var it = dir.iterate();
    var entries_seen: u32 = 0;
    while (it.next(ctx.io) catch {
        opts.body.setIncomplete(.io_skip);
        return;
    }) |entry| {
        entries_seen = std.math.add(u32, entries_seen, 1) catch {
            opts.body.setIncomplete(.node_limit);
            return;
        };
        if (entries_seen > opts.limits.dir_entries) {
            opts.body.setIncomplete(.node_limit);
            return;
        }
        const child = if (std.mem.eql(u8, rel, "."))
            ctx.allocator.dupe(u8, entry.name) catch return error.OutOfMemory
        else
            std.fs.path.join(ctx.allocator, &.{ rel, entry.name }) catch return error.OutOfMemory;

        if (try shouldExcludeWalkChild(ctx, guard, opts, child)) {
            ctx.allocator.free(child);
            if (opts.body.reason != null) return;
            continue;
        }

        if (paths.items.len >= opts.limits.walk_nodes) {
            ctx.allocator.free(child);
            opts.body.setIncomplete(.node_limit);
            return;
        }
        paths.append(ctx.allocator, child) catch {
            ctx.allocator.free(child);
            return error.OutOfMemory;
        };
    }
}

fn shouldExcludeWalkChild(
    ctx: tool.Context,
    guard: *const workspace.Guard,
    opts: WalkOpts,
    rel: []const u8,
) tool.HandlerError!bool {
    checkNestedExisting(ctx, guard, rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutsideWorkspace, error.InvalidPath, error.NotFound => return true,
        error.ResolveFailed => {
            opts.body.setIncomplete(.io_skip);
            return true;
        },
    };

    const st = ctx.cwd.statFile(ctx.io, rel, .{ .follow_symlinks = true }) catch {
        opts.body.setIncomplete(.io_skip);
        return true;
    };
    return fixedExclusionForExisting(ctx, guard, rel, st.kind) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IoSkip => {
            opts.body.setIncomplete(.io_skip);
            return true;
        },
    };
}

fn isDirectScopeFixedExcluded(ctx: tool.Context, guard: *const workspace.Guard, rel: []const u8) tool.HandlerError!bool {
    const st = ctx.cwd.statFile(ctx.io, rel, .{ .follow_symlinks = true }) catch return error.ToolFailed;
    return fixedExclusionForExisting(ctx, guard, rel, st.kind) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IoSkip => return error.ToolFailed,
    };
}

fn fixedExclusionForExisting(
    ctx: tool.Context,
    guard: *const workspace.Guard,
    rel: []const u8,
    kind: Io.File.Kind,
) error{ OutOfMemory, IoSkip }!bool {
    const rel_norm = normalizeRelativeForGlob(ctx.allocator, rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return error.IoSkip,
    };
    defer ctx.allocator.free(rel_norm);
    if (std.mem.eql(u8, rel_norm, ".")) return false;
    if (kind == .directory and shouldSkipDir(lastNormalizedComponent(rel_norm))) return true;

    const real_owned = try resolveRealOwned(ctx, rel);
    defer ctx.allocator.free(real_owned);
    return fixedExclusionForReal(guard, real_owned, kind);
}

fn lastNormalizedComponent(rel_norm: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, rel_norm, '/') orelse return rel_norm;
    return rel_norm[index + 1 ..];
}

fn fixedExclusionForReal(guard: *const workspace.Guard, real_abs: []const u8, kind: Io.File.Kind) bool {
    if (!guard.root.contains(real_abs)) return false;
    if (std.mem.eql(u8, guard.root.path, real_abs)) return false;
    if (real_abs.len <= guard.root.path.len) return false;
    const rel_real = real_abs[guard.root.path.len + 1 ..];

    var count: usize = 0;
    var it_count = std.mem.tokenizeScalar(u8, rel_real, std.fs.path.sep);
    while (it_count.next()) |_| count += 1;

    var index: usize = 0;
    var it = std.mem.tokenizeScalar(u8, rel_real, std.fs.path.sep);
    while (it.next()) |part| : (index += 1) {
        if (!shouldSkipDir(part)) continue;
        const is_final = index + 1 == count;
        if (!is_final) return true;
        return kind == .directory;
    }
    return false;
}

fn isHostPathSep(c: u8) bool {
    if (@import("builtin").os.tag == .windows) return c == '/' or c == '\\';
    return c == '/';
}

fn pathDepth(rel: []const u8) ?u32 {
    var depth: u32 = 0;
    var start: usize = 0;
    while (start <= rel.len) {
        var end = start;
        while (end < rel.len and !isHostPathSep(rel[end])) : (end += 1) {}
        const part = rel[start..end];
        if (part.len != 0 and !std.mem.eql(u8, part, ".")) {
            if (std.mem.eql(u8, part, "..")) {
                if (depth == 0) return null;
                depth -= 1;
            } else {
                depth = std.math.add(u32, depth, 1) catch return null;
            }
        }
        if (end == rel.len) break;
        start = end + 1;
    }
    return depth;
}

fn statFileForGrep(ctx: tool.Context, rel: []const u8) !Io.File.Stat {
    if (takeTestFault(.grep_stat)) return error.InputOutput;
    return ctx.cwd.statFile(ctx.io, rel, .{ .follow_symlinks = true });
}

fn readFileAllocForGrep(ctx: tool.Context, rel: []const u8, read_limit: usize) ![]u8 {
    if (takeTestFault(.grep_read)) return error.InputOutput;
    return ctx.cwd.readFileAlloc(ctx.io, rel, ctx.allocator, .limited(read_limit));
}

fn readBinaryProbeChunk(ctx: tool.Context, file: *Io.File, dest: []u8, offset: usize) error{IoSkip}!usize {
    const window = if (offset == 0 and takeTestFault(.binary_probe_short_once)) dest[0..1] else dest;
    return file.readPositional(ctx.io, &.{window}, offset) catch return error.IoSkip;
}

fn probeLikelyBinary(ctx: tool.Context, rel: []const u8) error{ OutOfMemory, IoSkip }!bool {
    const probe = ctx.allocator.alloc(u8, binary_probe_bytes) catch return error.OutOfMemory;
    defer ctx.allocator.free(probe);

    var file = ctx.cwd.openFile(ctx.io, rel, .{}) catch return error.IoSkip;
    defer file.close(ctx.io);

    var filled: usize = 0;
    while (filled < probe.len) {
        const n = try readBinaryProbeChunk(ctx, &file, probe[filled..], filled);
        if (n == 0) return false;
        const end = std.math.add(usize, filled, n) catch return error.IoSkip;
        if (std.mem.indexOfScalar(u8, probe[filled..end], 0) != null) return true;
        filled = end;
    }
    return false;
}

fn grepFile(ctx: tool.Context, rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    if (opts.body.reason != null) return;

    const st = statFileForGrep(ctx, rel) catch {
        opts.body.setIncomplete(.io_skip);
        return;
    };
    const binary = probeLikelyBinary(ctx, rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IoSkip => {
            opts.body.setIncomplete(.io_skip);
            return;
        },
    };
    if (binary) return;

    if (st.size > opts.limits.grep_file_bytes) {
        opts.body.setIncomplete(.source_limit);
        return;
    }
    const read_limit = std.math.add(usize, opts.limits.grep_file_bytes, 1) catch return error.OutOfMemory;
    const contents = readFileAllocForGrep(ctx, rel, read_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            opts.body.setIncomplete(.source_limit);
            return;
        },
        else => {
            opts.body.setIncomplete(.io_skip);
            return;
        },
    };
    defer ctx.allocator.free(contents);

    // Skip likely-binary files (NUL in the first chunk): intentional search-scope exclusion.
    if (std.mem.indexOfScalar(u8, contents, 0) != null) return;

    var line_no: u32 = 1;
    var start: usize = 0;
    while (start <= contents.len) {
        const end = std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse contents.len;
        const line = contents[start..end];
        if (std.mem.indexOf(u8, line, opts.pattern) != null) {
            if (opts.hits.* >= opts.hits_max) {
                opts.body.setIncomplete(.hit_limit);
                return;
            }
            if (!try opts.body.appendFmtLine("{s}:{d}:{s}", .{ rel, line_no, line }, .hit_limit)) return;
            opts.hits.* = std.math.add(u32, opts.hits.*, 1) catch return error.OutOfMemory;
        }
        if (end == contents.len) break;
        start = end + 1;
        line_no = std.math.add(u32, line_no, 1) catch return error.OutOfMemory;
    }
}

fn globFile(ctx: tool.Context, rel: []const u8, opts: WalkOpts) tool.HandlerError!void {
    const rel_norm = normalizeRelativeForGlob(ctx.allocator, rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => {
            opts.body.setIncomplete(.io_skip);
            return;
        },
    };
    defer ctx.allocator.free(rel_norm);
    const candidate = scopedGlobCandidate(opts.scope_root, rel_norm);
    const matched = matchGlobDetailed(opts.pattern, candidate, opts.limits.glob_frames) catch |err| switch (err) {
        error.PatternLimit => {
            opts.body.setIncomplete(.pattern_limit);
            return;
        },
    };
    if (!matched) return;
    if (opts.hits.* >= opts.hits_max) {
        opts.body.setIncomplete(.hit_limit);
        return;
    }
    if (!try opts.body.appendOwnedLine(rel, .hit_limit)) return;
    opts.hits.* = std.math.add(u32, opts.hits.*, 1) catch return error.OutOfMemory;
}

fn normalizeRelativeForGlob(gpa: std.mem.Allocator, raw: []const u8) error{ OutOfMemory, InvalidArguments }![]u8 {
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(gpa);

    var start: usize = 0;
    while (start <= raw.len) {
        var end = start;
        while (end < raw.len and !isHostPathSep(raw[end])) : (end += 1) {}
        const part = raw[start..end];
        if (part.len != 0 and !std.mem.eql(u8, part, ".")) {
            if (std.mem.eql(u8, part, "..")) {
                if (components.items.len == 0) return error.InvalidArguments;
                _ = components.pop();
            } else {
                try components.append(gpa, part);
            }
        }
        if (end == raw.len) break;
        start = end + 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (components.items, 0..) |part, i| {
        if (i != 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

fn scopedGlobCandidate(scope_root: []const u8, rel: []const u8) []const u8 {
    if (std.mem.eql(u8, scope_root, ".")) return rel;
    if (std.mem.eql(u8, scope_root, rel)) return std.fs.path.basename(rel);
    if (std.mem.startsWith(u8, rel, scope_root) and rel.len > scope_root.len and rel[scope_root.len] == '/') {
        return rel[scope_root.len + 1 ..];
    }
    return rel;
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
    return matchGlobDetailed(pattern, path, glob_frame_stack_max) catch false;
}

fn matchGlobDetailed(pattern: []const u8, path: []const u8, frame_limit: u32) error{PatternLimit}!bool {
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
                    if (stack_len >= frame_limit or stack_len >= glob_frame_stack_max) return error.PatternLimit;
                    stack[stack_len] = .{ .pat_index = rest, .text_index = split };
                    stack_len += 1;
                }
                break;
            }

            if (pattern[pat_index] == '*') {
                // Match zero or more chars that are not '/'.
                var split: u32 = text_index;
                while (true) {
                    if (stack_len >= frame_limit or stack_len >= glob_frame_stack_max) return error.PatternLimit;
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

const defaulted_search_path_caps: tool.ToolCapabilities = .{
    .risk = .read,
    .workspace = .{ .path_field_default = .{ .field = "path", .default_path = "." } },
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
        tool.stateless(.{ .definition = grep_def, .capabilities = defaulted_search_path_caps }, grep),
        tool.stateless(.{ .definition = glob_def, .capabilities = defaulted_search_path_caps }, glob),
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

    try std.testing.expectError(error.InvalidArguments, listDir(ctx, null, "{\"path\":\"\"}"));
    const empty_list = try registry.execute(ctx, "list_dir", "{\"path\":\"\"}");
    defer gpa.free(empty_list);
    try std.testing.expect(core.tool_error.hasCode(empty_list, .invalid_arguments));
    try std.testing.expect(std.mem.indexOf(u8, empty_list, "build.zig") == null);

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

    try tmp.dir.createDirPath(io, "src/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const x = 1;\nfindme here\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.md", .data = "nope\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/nested/c.zig", .data = "const c = 1;\n" });
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

    const grep_interior = try grep(ctx, null, "{\"pattern\":\"findme\",\"path\":\"src/../src\"}");
    defer gpa.free(grep_interior);
    try std.testing.expect(std.mem.indexOf(u8, grep_interior, "findme here") != null);

    const paths = try glob(ctx, null, "{\"pattern\":\"**/*.zig\"}");
    defer gpa.free(paths);
    try std.testing.expect(std.mem.indexOf(u8, paths, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths, "b.md") == null);

    const scoped = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src\"}");
    defer gpa.free(scoped);
    try std.testing.expect(std.mem.indexOf(u8, scoped, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped, "src/nested/c.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, scoped, "readme.txt") == null);

    const scoped_trailing = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src/\"}");
    defer gpa.free(scoped_trailing);
    try std.testing.expect(std.mem.indexOf(u8, scoped_trailing, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped_trailing, "src/nested/c.zig") == null);

    const scoped_dot = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"./src\"}");
    defer gpa.free(scoped_dot);
    try std.testing.expect(std.mem.indexOf(u8, scoped_dot, "src/a.zig") != null);

    const scoped_interior = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src/../src\"}");
    defer gpa.free(scoped_interior);
    try std.testing.expect(std.mem.indexOf(u8, scoped_interior, "src/../src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped_interior, "src/../src/nested/c.zig") == null);

    const escape = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src/../../src\"}");
    defer gpa.free(escape);
    try std.testing.expect(std.mem.indexOf(u8, escape, "code=jail_deny") != null);

    const nested_trailing = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src/nested/\"}");
    defer gpa.free(nested_trailing);
    try std.testing.expect(std.mem.indexOf(u8, nested_trailing, "src/nested/c.zig") != null);

    const scoped_file = try glob(ctx, null, "{\"pattern\":\"*.zig\",\"path\":\"src/a.zig\"}");
    defer gpa.free(scoped_file);
    try std.testing.expect(std.mem.indexOf(u8, scoped_file, "src/a.zig") != null);
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

    const glob_link_scoped = try glob(ctx, null, "{\"pattern\":\"*.txt\",\"path\":\"link_dir/\"}");
    defer gpa.free(glob_link_scoped);
    try std.testing.expect(std.mem.indexOf(u8, glob_link_scoped, "link_dir/nested.txt") != null);

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

test "jail deny bodies for long absolute raw handler paths are bounded and path-free" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const sentinel = "FS_LONG_ABS_SENTINEL_4b76";
    const filler = try gpa.alloc(u8, 70 * 1024);
    defer gpa.free(filler);
    @memset(filler, 'q');
    const path_json = try std.fmt.allocPrint(gpa, "\"/{s}{s}\"", .{ sentinel, filler });
    defer gpa.free(path_json);

    const list_args = try std.fmt.allocPrint(gpa, "{{\"path\":{s}}}", .{path_json});
    defer gpa.free(list_args);
    const read_args = list_args;
    const grep_args = try std.fmt.allocPrint(gpa, "{{\"pattern\":\"needle\",\"path\":{s}}}", .{path_json});
    defer gpa.free(grep_args);
    const glob_args = try std.fmt.allocPrint(gpa, "{{\"pattern\":\"**/*\",\"path\":{s}}}", .{path_json});
    defer gpa.free(glob_args);

    const cases = .{
        try listDir(ctx, null, list_args),
        try readFile(ctx, null, read_args),
        try grep(ctx, null, grep_args),
        try glob(ctx, null, glob_args),
    };
    inline for (cases) |body| {
        defer gpa.free(body);
        try std.testing.expect(body.len <= tool.max_result_bytes);
        try std.testing.expect(std.mem.indexOf(u8, body, "code=jail_deny") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, sentinel) == null);
    }
}

test "fixed search exclusions apply to directories only and direct scopes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "needle target-file\n" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "needle GIT_SECRET\n" });
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/artifact.txt", .data = "needle BUILD_SECRET\n" });
    try tmp.dir.createDirPath(io, "cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "cache/dep.txt", .data = "not-a-search-hit\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.txt", .data = "needle src-ok\n" });
    if (builtin.os.tag != .windows) {
        try tmp.dir.symLink(io, "cache", "node_modules", .{ .is_directory = true });
    }

    const grep_target = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"target\"}");
    defer gpa.free(grep_target);
    try std.testing.expect(std.mem.indexOf(u8, grep_target, "target-file") != null);
    const glob_target = try glob(ctx, null, "{\"pattern\":\"target\"}");
    defer gpa.free(glob_target);
    try std.testing.expect(std.mem.indexOf(u8, glob_target, "target") != null);

    const direct_git_file = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\".git/config\"}");
    defer gpa.free(direct_git_file);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_file, "GIT_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_file, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_file, "no matches") != null);

    const direct_git_dir = try glob(ctx, null, "{\"pattern\":\"**/*\",\"path\":\".git\"}");
    defer gpa.free(direct_git_dir);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_dir, "config") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_dir, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_git_dir, "no paths") != null);

    const direct_build_file = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"zig-out/artifact.txt\"}");
    defer gpa.free(direct_build_file);
    try std.testing.expect(std.mem.indexOf(u8, direct_build_file, "BUILD_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_build_file, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, direct_build_file, "no matches") != null);

    if (builtin.os.tag != .windows) {
        const symlink_fixed = try glob(ctx, null, "{\"pattern\":\"**/*\",\"path\":\"node_modules\"}");
        defer gpa.free(symlink_fixed);
        try std.testing.expect(std.mem.indexOf(u8, symlink_fixed, "dep.txt") == null);
        try std.testing.expect(std.mem.indexOf(u8, symlink_fixed, incomplete_prefix) == null);
    }

    const root_grep = try grep(ctx, null, "{\"pattern\":\"needle\"}");
    defer gpa.free(root_grep);
    try std.testing.expect(std.mem.indexOf(u8, root_grep, "target-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_grep, "src-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_grep, "GIT_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_grep, "BUILD_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_grep, incomplete_prefix) == null);

    const interior = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"zig-out/../src\"}");
    defer gpa.free(interior);
    try std.testing.expect(std.mem.indexOf(u8, interior, "src-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, interior, "no matches") == null);
}

test "POSIX backslash sibling: all file tools deny without leak" {
    // parent/ws and parent/ws\outside (literal backslash filename) are siblings.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();

    try parent.dir.createDirPath(io, "ws");
    const sibling = "ws\\outside";
    try parent.dir.writeFile(io, .{ .sub_path = sibling, .data = "BACKSLASH_OUTSIDE_SECRET\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);
    try ws.symLink(io, "../ws\\outside", "to_bs", .{});
    try ws.writeFile(io, .{ .sub_path = "ok.txt", .data = "inside findme\n" });

    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    const r = try readFile(ctx, null, "{\"path\":\"to_bs\"}");
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "code=jail_deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "BACKSLASH_OUTSIDE") == null);

    // list_dir on the symlink file path fails as not-a-dir or jail — never leaks content
    const ld = try listDir(ctx, null, "{\"path\":\"to_bs\"}");
    defer gpa.free(ld);
    try std.testing.expect(std.mem.indexOf(u8, ld, "BACKSLASH_OUTSIDE") == null);

    const g = try grep(ctx, null, "{\"pattern\":\"BACKSLASH\",\"path\":\"to_bs\"}");
    defer gpa.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "code=jail_deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "BACKSLASH_OUTSIDE") == null);

    const gl = try glob(ctx, null, "{\"pattern\":\"**/*\",\"path\":\"to_bs\"}");
    defer gpa.free(gl);
    try std.testing.expect(std.mem.indexOf(u8, gl, "code=jail_deny") != null or std.mem.indexOf(u8, gl, "BACKSLASH") == null);

    const edit = @import("edit_tools.zig");
    const w = try edit.writeFile(ctx, null,
        \\{"path":"to_bs","content":"PWNED\n"}
    );
    defer gpa.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "code=jail_deny") != null);
    const outside = try parent.dir.readFileAlloc(io, sibling, gpa, .limited(64));
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("BACKSLASH_OUTSIDE_SECRET\n", outside);

    const sr = try edit.searchReplace(ctx, null,
        \\{"path":"to_bs","old_string":"BACKSLASH_OUTSIDE_SECRET","new_string":"PWNED"}
    );
    defer gpa.free(sr);
    try std.testing.expect(std.mem.indexOf(u8, sr, "code=jail_deny") != null);
    const outside2 = try parent.dir.readFileAlloc(io, sibling, gpa, .limited(64));
    defer gpa.free(outside2);
    try std.testing.expectEqualStrings("BACKSLASH_OUTSIDE_SECRET\n", outside2);
}

fn setFsTestLimits(limits: FsLimits) void {
    std.debug.assert(builtin.is_test);
    std.debug.assert(limits.body_bytes >= max_incomplete_marker_len);
    test_limits = limits;
}

fn clearFsTestLimits() void {
    if (builtin.is_test) test_limits = null;
}

fn setFsTestFaults(faults: *TestFaults) void {
    std.debug.assert(builtin.is_test);
    test_faults = faults;
}

fn clearFsTestFaults() void {
    if (builtin.is_test) test_faults = null;
}

fn expectFsMarker(body: []const u8, reason: []const u8) !void {
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ incomplete_prefix, reason, incomplete_suffix });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(std.mem.endsWith(u8, body, expected));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, incomplete_prefix));
}

fn expectNoFsMarker(body: []const u8, reason: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, body, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, reason) == null);
}

fn repeatedTrailingHostSeparators(gpa: std.mem.Allocator, base: []const u8, count: usize) ![]u8 {
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    try out.appendNTimes(gpa, sep, count);
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

fn searchArgsJson(gpa: std.mem.Allocator, pattern: []const u8, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("pattern");
    try s.write(pattern);
    try s.objectField("path");
    try s.write(path);
    try s.endObject();
    return out.toOwnedSlice();
}

test "pathDepth uses normalized host components" {
    try std.testing.expectEqual(@as(?u32, 0), pathDepth(""));
    try std.testing.expectEqual(@as(?u32, 0), pathDepth("."));
    try std.testing.expectEqual(@as(?u32, 0), pathDepth("./"));
    try std.testing.expectEqual(@as(?u32, 1), pathDepth("src"));
    try std.testing.expectEqual(@as(?u32, 1), pathDepth("src////////////////"));
    try std.testing.expectEqual(@as(?u32, 2), pathDepth("src/./nested"));
    try std.testing.expectEqual(@as(?u32, 2), pathDepth("src/a/../b"));
    try std.testing.expectEqual(@as(?u32, 0), pathDepth("src/.."));
    try std.testing.expectEqual(@as(?u32, null), pathDepth(".."));
    try std.testing.expectEqual(@as(?u32, null), pathDepth("src/../.."));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(?u32, 1), pathDepth("src\\\\\\\\"));
        try std.testing.expectEqual(@as(?u32, 2), pathDepth("src\\.\\nested"));
        try std.testing.expectEqual(@as(?u32, 2), pathDepth("src\\a\\..\\b"));
    } else {
        try std.testing.expectEqual(@as(?u32, 1), pathDepth("src\\\\literal"));
    }
}

test "fs-v1 marker reservation and helper N/N+1 body budget" {
    const gpa = std.testing.allocator;
    const limit = max_incomplete_marker_len + 4;
    var body = LimitedBody.init(gpa, limit);
    errdefer body.deinit();
    try std.testing.expect(try body.appendOwnedLine("abc", .pattern_limit));
    try std.testing.expect(!try body.appendOwnedLine("d", .pattern_limit));
    const out = try body.finish();
    defer gpa.free(out);
    try std.testing.expect(out.len <= limit);
    try expectFsMarker(out, "body_limit");
}

test "read_file exact boundary N+1 far oversized and growth race stay bounded" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const limit = max_incomplete_marker_len + 16;
    setFsTestLimits(.{ .body_bytes = limit, .file_bytes = limit });
    defer clearFsTestLimits();

    const exact = try gpa.alloc(u8, limit);
    defer gpa.free(exact);
    @memset(exact, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "exact.txt", .data = exact });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    const exact_body = try readFile(ctx, null, "{\"path\":\"exact.txt\"}");
    defer gpa.free(exact_body);
    try std.testing.expectEqual(limit, exact_body.len);
    try std.testing.expect(std.mem.indexOf(u8, exact_body, incomplete_prefix) == null);

    const over = try gpa.alloc(u8, limit + 1);
    defer gpa.free(over);
    @memset(over, 'y');
    try tmp.dir.writeFile(io, .{ .sub_path = "over.txt", .data = over });
    const over_body = try readFile(ctx, null, "{\"path\":\"over.txt\"}");
    defer gpa.free(over_body);
    try std.testing.expect(over_body.len <= limit);
    try expectFsMarker(over_body, "body_limit");

    const far = try gpa.alloc(u8, limit * 3);
    defer gpa.free(far);
    @memset(far, 'z');
    try tmp.dir.writeFile(io, .{ .sub_path = "far.txt", .data = far });
    const far_body = try readFile(ctx, null, "{\"path\":\"far.txt\"}");
    defer gpa.free(far_body);
    try std.testing.expect(far_body.len <= limit);
    try expectFsMarker(far_body, "body_limit");

    try tmp.dir.writeFile(io, .{ .sub_path = "race.txt", .data = exact });
    var faults: TestFaults = .{ .point = .read_after_open_grow };
    setFsTestFaults(&faults);
    defer clearFsTestFaults();
    const race_body = try readFile(ctx, null, "{\"path\":\"race.txt\"}");
    defer gpa.free(race_body);
    try std.testing.expect(faults.observed);
    try std.testing.expect(race_body.len <= limit);
    try expectFsMarker(race_body, "body_limit");
}

test "list_dir entry and body cutoffs emit bounded markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const limit = max_incomplete_marker_len + 20;
    setFsTestLimits(.{ .body_bytes = limit, .list_entries = 1 });
    defer clearFsTestLimits();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });
    const entry_body = try listDir(ctx, null, "{\"path\":\".\"}");
    defer gpa.free(entry_body);
    try std.testing.expect(entry_body.len <= limit);
    try expectFsMarker(entry_body, "entry_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = max_incomplete_marker_len + 4, .list_entries = 10 });
    const byte_body = try listDir(ctx, null, "{\"path\":\".\"}");
    defer gpa.free(byte_body);
    try std.testing.expect(byte_body.len <= max_incomplete_marker_len + 4);
    try expectFsMarker(byte_body, "body_limit");
}

test "grep hit body and source cutoffs emit bounded markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const limit = max_incomplete_marker_len + 48;
    try tmp.dir.writeFile(io, .{ .sub_path = "hits.txt", .data = "needle one\nneedle two\n" });
    setFsTestLimits(.{ .body_bytes = limit, .grep_hits = 1 });
    defer clearFsTestLimits();
    const hit_body = try grep(ctx, null, "{\"pattern\":\"needle\"}");
    defer gpa.free(hit_body);
    try std.testing.expect(hit_body.len <= limit);
    try expectFsMarker(hit_body, "hit_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = max_incomplete_marker_len + 8, .grep_hits = 10 });
    const byte_body = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"hits.txt\"}");
    defer gpa.free(byte_body);
    try std.testing.expect(byte_body.len <= max_incomplete_marker_len + 8);
    try expectFsMarker(byte_body, "body_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = limit, .grep_file_bytes = 4 });
    const source_body = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"hits.txt\"}");
    defer gpa.free(source_body);
    try std.testing.expect(source_body.len <= limit);
    try expectFsMarker(source_body, "source_limit");
}

test "grep oversized binary remains intentional exclusion before source limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const big_binary = "\x00BINARY_SECRET padding padding\n";
    const big_text = "plain text padding padding\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = big_binary });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big_text });

    const limit = max_incomplete_marker_len + 32;
    setFsTestLimits(.{ .body_bytes = limit, .grep_file_bytes = 4 });
    defer clearFsTestLimits();

    const binary_body = try grep(ctx, null, "{\"pattern\":\"absent\",\"path\":\"big.bin\"}");
    defer gpa.free(binary_body);
    try std.testing.expect(binary_body.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, binary_body, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, binary_body, "BINARY_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, binary_body, "no matches") != null);

    const text_body = try grep(ctx, null, "{\"pattern\":\"absent\",\"path\":\"big.txt\"}");
    defer gpa.free(text_body);
    try std.testing.expect(text_body.len <= limit);
    try expectFsMarker(text_body, "source_limit");
}

test "grep binary probe continues after short nonzero read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    try tmp.dir.writeFile(io, .{ .sub_path = "short.bin", .data = "A\x00BINARY_SECRET padding padding\n" });

    const limit = max_incomplete_marker_len + 32;
    setFsTestLimits(.{ .body_bytes = limit, .grep_file_bytes = 4 });
    defer clearFsTestLimits();
    var faults: TestFaults = .{ .point = .binary_probe_short_once };
    setFsTestFaults(&faults);
    defer clearFsTestFaults();

    const body = try grep(ctx, null, "{\"pattern\":\"absent\",\"path\":\"short.bin\"}");
    defer gpa.free(body);
    try std.testing.expect(faults.observed);
    try std.testing.expect(body.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, body, incomplete_prefix) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "source_limit") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "BINARY_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "no matches") != null);
}

test "glob hit body and pattern-frame cutoffs emit bounded markers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "" });
    const limit = max_incomplete_marker_len + 24;
    setFsTestLimits(.{ .body_bytes = limit, .glob_hits = 1 });
    defer clearFsTestLimits();
    const hit_body = try glob(ctx, null, "{\"pattern\":\"*.zig\"}");
    defer gpa.free(hit_body);
    try std.testing.expect(hit_body.len <= limit);
    try expectFsMarker(hit_body, "hit_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = max_incomplete_marker_len + 2, .glob_hits = 10 });
    const byte_body = try glob(ctx, null, "{\"pattern\":\"*.zig\"}");
    defer gpa.free(byte_body);
    try std.testing.expect(byte_body.len <= max_incomplete_marker_len + 2);
    try expectFsMarker(byte_body, "body_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = limit, .glob_frames = 1 });
    const pattern_body = try glob(ctx, null, "{\"pattern\":\"*z\"}");
    defer gpa.free(pattern_body);
    try std.testing.expect(pattern_body.len <= limit);
    try expectFsMarker(pattern_body, "pattern_limit");
}

test "walker node depth and per-directory cutoffs emit first stable marker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    try tmp.dir.createDirPath(io, "d/e");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/e/file.txt", .data = "nope" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "nope" });

    const limit = max_incomplete_marker_len + 32;
    setFsTestLimits(.{ .body_bytes = limit, .walk_nodes = 1 });
    defer clearFsTestLimits();
    const node_body = try grep(ctx, null, "{\"pattern\":\"absent\"}");
    defer gpa.free(node_body);
    try std.testing.expect(node_body.len <= limit);
    try expectFsMarker(node_body, "node_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = limit, .walk_depth = 1 });
    const depth_body = try glob(ctx, null, "{\"pattern\":\"**/*.txt\"}");
    defer gpa.free(depth_body);
    try std.testing.expect(depth_body.len <= limit);
    try expectFsMarker(depth_body, "depth_limit");

    clearFsTestLimits();
    setFsTestLimits(.{ .body_bytes = limit, .dir_entries = 1 });
    const per_dir_body = try glob(ctx, null, "{\"pattern\":\"nomatch\"}");
    defer gpa.free(per_dir_body);
    try std.testing.expect(per_dir_body.len <= limit);
    try expectFsMarker(per_dir_body, "node_limit");
}

test "grep and glob normalize trailing separators for walk depth only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "needle\n" });

    const noisy_src = try repeatedTrailingHostSeparators(gpa, "src", max_walk_depth + 5);
    defer gpa.free(noisy_src);
    const grep_args = try searchArgsJson(gpa, "needle", noisy_src);
    defer gpa.free(grep_args);
    const glob_args = try searchArgsJson(gpa, "*.zig", noisy_src);
    defer gpa.free(glob_args);

    const limit = max_incomplete_marker_len + 128;
    setFsTestLimits(.{ .body_bytes = limit, .walk_depth = 2 });
    defer clearFsTestLimits();

    const grep_body = try grep(ctx, null, grep_args);
    defer gpa.free(grep_body);
    try std.testing.expect(grep_body.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, grep_body, "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, grep_body, "needle") != null);
    try expectNoFsMarker(grep_body, "depth_limit");

    const glob_body = try glob(ctx, null, glob_args);
    defer gpa.free(glob_body);
    try std.testing.expect(glob_body.len <= limit);
    try std.testing.expect(std.mem.indexOf(u8, glob_body, "a.zig") != null);
    try expectNoFsMarker(glob_body, "depth_limit");
}

test "fs tool OOM remains hard error not fake complete result" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var body = LimitedBody.init(failing.allocator(), max_incomplete_marker_len + 16);
    defer body.deinit();
    try std.testing.expectError(error.OutOfMemory, body.appendFmtLine("{s}", .{"needle"}, .body_limit));
    try std.testing.expect(failing.has_induced_failure);
}

test "list_dir iterator I/O failure emits bounded io_skip through handler branch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const limit = max_incomplete_marker_len + 8;
    setFsTestLimits(.{ .body_bytes = limit });
    defer clearFsTestLimits();
    var faults: TestFaults = .{ .point = .list_iter_next };
    setFsTestFaults(&faults);
    defer clearFsTestFaults();

    const body = try listDir(ctx, null, "{\"path\":\".\"}");
    defer gpa.free(body);
    try std.testing.expect(faults.observed);
    try std.testing.expect(body.len <= limit);
    try expectFsMarker(body, "io_skip");
}

test "grep stat and read I/O failures emit bounded io_skip through handler branches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "needle\n" });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const limit = max_incomplete_marker_len + 16;
    setFsTestLimits(.{ .body_bytes = limit });
    defer clearFsTestLimits();

    {
        var faults: TestFaults = .{ .point = .grep_stat };
        setFsTestFaults(&faults);
        defer clearFsTestFaults();
        const body = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"a.txt\"}");
        defer gpa.free(body);
        try std.testing.expect(faults.observed);
        try std.testing.expect(body.len <= limit);
        try expectFsMarker(body, "io_skip");
    }

    {
        var faults: TestFaults = .{ .point = .grep_read };
        setFsTestFaults(&faults);
        defer clearFsTestFaults();
        const body = try grep(ctx, null, "{\"pattern\":\"needle\",\"path\":\"a.txt\"}");
        defer gpa.free(body);
        try std.testing.expect(faults.observed);
        try std.testing.expect(body.len <= limit);
        try expectFsMarker(body, "io_skip");
    }
}

test "walker nested resolve failures emit bounded io_skip while exclusions remain silent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/a.txt", .data = "needle\n" });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const limit = max_incomplete_marker_len + 16;
    setFsTestLimits(.{ .body_bytes = limit });
    defer clearFsTestLimits();

    {
        var faults: TestFaults = .{ .point = .walk_check_existing };
        setFsTestFaults(&faults);
        defer clearFsTestFaults();
        const body = try grep(ctx, null, "{\"pattern\":\"absent\"}");
        defer gpa.free(body);
        try std.testing.expect(faults.observed);
        try std.testing.expect(body.len <= limit);
        try expectFsMarker(body, "io_skip");
    }

    {
        var faults: TestFaults = .{ .point = .walk_realpath };
        setFsTestFaults(&faults);
        defer clearFsTestFaults();
        const body = try glob(ctx, null, "{\"pattern\":\"nomatch\"}");
        defer gpa.free(body);
        try std.testing.expect(faults.observed);
        try std.testing.expect(body.len <= limit);
        try expectFsMarker(body, "io_skip");
    }
}
