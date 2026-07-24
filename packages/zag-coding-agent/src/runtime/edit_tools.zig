//! Write / edit / shell tools: `search_replace`, `write_file`, `run_shell`.
//!
//! File mutators enforce symlink-aware workspace containment (h-workspace-001)
//! so raw `Registry.execute` cannot bypass the jail. Shell remains a separate
//! boundary (not contained by the path jail).

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const workspace = core.workspace;

pub const search_replace_def: tool.Definition = .{
    .name = "search_replace",
    .description =
    \\Default edit tool: replace an exact old_string anchor with new_string in a file.
    \\old_string must appear exactly once (unique content anchor). If missing or ambiguous,
    \\re-read the file and widen the anchor. Prefer this over write_file for existing files.
    \\Subject to permission checks (ask/yolo) and workspace jail.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path relative to the working directory."
    \\    },
    \\    "old_string": {
    \\      "type": "string",
    \\      "description": "Exact text that must appear once in the file."
    \\    },
    \\    "new_string": {
    \\      "type": "string",
    \\      "description": "Replacement text (may be empty to delete the anchor)."
    \\    }
    \\  },
    \\  "required": ["path", "old_string", "new_string"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const write_file_def: tool.Definition = .{
    .name = "write_file",
    .description =
    \\Create a new file or overwrite an entire UTF-8 text file (relative path).
    \\Prefer search_replace for editing existing files. Use write_file for new files
    \\or when intentionally replacing the whole contents. Creates parent directories.
    \\Subject to permission checks (ask/yolo).
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "File path relative to the working directory."
    \\    },
    \\    "content": {
    \\      "type": "string",
    \\      "description": "Full new file contents."
    \\    }
    \\  },
    \\  "required": ["path", "content"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const run_shell_def: tool.Definition = .{
    .name = "run_shell",
    .description =
    \\Run a shell command in the working directory via /bin/sh -c.
    \\Stdout and stderr are captured and truncated. Default timeout ~30s.
    \\Subject to permission checks (ask/yolo). Prefer for build/test/git status, not interactive programs.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Shell command string executed as `sh -c <command>`."
    \\    }
    \\  },
    \\  "required": ["command"],
    \\  "additionalProperties": false
    \\}
    ,
};

const max_write_bytes: u32 = 512 * 1024;
const max_read_for_edit: u32 = max_write_bytes + 1;
const max_shell_output: u32 = @intCast(tool.max_result_bytes);
const shell_timeout_secs: i64 = 30;
const max_diff_bytes: u32 = 4 * 1024;

pub const ReplaceError = error{
    AnchorNotFound,
    AmbiguousAnchor,
};

/// Count non-overlapping occurrences of `needle` in `haystack`.
pub fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    if (needle.len == 0) return 0;
    var count: u32 = 0;
    var start: usize = 0;
    // Loop is bounded by haystack length (each match advances by needle.len ≥ 1).
    while (start < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, start, needle)) |idx| {
            count += 1;
            start = idx + needle.len;
        } else break;
    }
    return count;
}

/// Apply a unique anchor replace. Caller owns returned slice on success.
pub fn applyUniqueReplace(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    old_string: []const u8,
    new_string: []const u8,
) (ReplaceError || error{OutOfMemory})![]u8 {
    if (old_string.len == 0) return error.AnchorNotFound;
    const match_count = countOccurrences(haystack, old_string);
    if (match_count == 0) return error.AnchorNotFound;
    if (match_count > 1) return error.AmbiguousAnchor;

    const idx = std.mem.indexOf(u8, haystack, old_string).?;
    std.debug.assert(match_count == 1);
    std.debug.assert(idx + old_string.len <= haystack.len);

    const new_len = haystack.len - old_string.len + new_string.len;
    var out = try gpa.alloc(u8, new_len);
    errdefer gpa.free(out);
    @memcpy(out[0..idx], haystack[0..idx]);
    @memcpy(out[idx..][0..new_string.len], new_string);
    @memcpy(out[idx + new_string.len ..], haystack[idx + old_string.len ..]);
    return out;
}

fn softError(
    gpa: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) tool.HandlerError![]u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
}

pub fn searchReplace(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);
    const old_string = try tool.requireStringField(ctx.allocator, arguments_json, "old_string");
    defer ctx.allocator.free(old_string);
    const new_string = try tool.requireStringField(ctx.allocator, arguments_json, "new_string");
    defer ctx.allocator.free(new_string);

    if (path.len == 0) return error.InvalidArguments;
    if (old_string.len == 0) {
        return softError(
            ctx.allocator,
            "error: code=anchor_not_found path={s}: old_string must be non-empty. Re-read the file and provide an exact unique anchor.",
            .{path},
        );
    }

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    // Existing target (or contained final symlink) must resolve inside root.
    guard.checkExisting(ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };

    const contents = readEditTarget(ctx, path) catch |err| switch (err) {
        error.FileTooLarge => return softError(
            ctx.allocator,
            "error: code=too_large path={s}: file exceeds {d} bytes; use a smaller edit target or split the change.",
            .{ path, max_write_bytes },
        ),
        else => |e| return e,
    };
    defer ctx.allocator.free(contents);

    const replaced = applyUniqueReplace(ctx.allocator, contents, old_string, new_string) catch |err| {
        return replaceSoftFail(ctx.allocator, path, contents, old_string, err);
    };
    defer ctx.allocator.free(replaced);

    if (replaced.len > max_write_bytes) {
        return softError(
            ctx.allocator,
            "error: code=too_large path={s}: result would be {d} bytes (max {d}).",
            .{ path, replaced.len, max_write_bytes },
        );
    }

    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = path,
        .data = replaced,
        .flags = .{ .truncate = true },
    }) catch return error.ToolFailed;

    const base = try softError(
        ctx.allocator,
        "ok: search_replace path={s} removed={d} inserted={d} bytes file_size={d}",
        .{ path, old_string.len, new_string.len, replaced.len },
    );
    return maybeAppendGitDiff(ctx, path, base);
}

fn readEditTarget(ctx: tool.Context, path: []const u8) (tool.HandlerError || error{FileTooLarge})![]u8 {
    std.debug.assert(path.len > 0);
    return ctx.cwd.readFileAlloc(
        ctx.io,
        path,
        ctx.allocator,
        .limited(max_read_for_edit),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.FileTooLarge,
        else => return error.ToolFailed,
    };
}

fn replaceSoftFail(
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    old_string: []const u8,
    err: anyerror,
) tool.HandlerError![]u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AnchorNotFound => softError(
            gpa,
            "error: code=anchor_not_found path={s}: old_string not found. Re-read the file and retry with exact current content.",
            .{path},
        ),
        error.AmbiguousAnchor => softError(
            gpa,
            "error: code=ambiguous_anchor path={s}: old_string matched {d} times. Widen the anchor with surrounding context so it is unique.",
            .{ path, countOccurrences(contents, old_string) },
        ),
        else => error.ToolFailed,
    };
}

pub fn writeFile(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);
    const content = try tool.requireStringField(ctx.allocator, arguments_json, "content");
    defer ctx.allocator.free(content);

    if (path.len == 0) return error.InvalidArguments;
    if (content.len > max_write_bytes) {
        return softError(
            ctx.allocator,
            "error: code=too_large path={s}: content is {d} bytes (max {d}).",
            .{ path, content.len, max_write_bytes },
        );
    }

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    // Ancestor walk before any create: escaping/dangling parents denied.
    guard.checkCreate(ctx.allocator, ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };

    // Create only missing parent dirs. Do not createDirPath over an existing
    // contained directory symlink (that returns ToolFailed on Zig createDirPath).
    ensureParentDirs(ctx, path) catch return error.ToolFailed;

    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .truncate = true },
    }) catch return error.ToolFailed;

    const base = try softError(
        ctx.allocator,
        "ok: wrote {d} bytes to {s}",
        .{ content.len, path },
    );
    return maybeAppendGitDiff(ctx, path, base);
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

/// Test-only: after this many successful `replaceOwnedSlice` installs, the next
/// call returns `error.OutOfMemory` before allocating (exercises ownership).
var test_replace_fail_after: ?usize = null;
var test_replace_success_count: usize = 0;

/// Replace `slot` with a freshly owned copy of `bytes`.
///
/// Allocates **before** freeing the previous value so OOM leaves the old
/// slice installed (defer cannot double-free an already-freed pointer).
fn replaceOwnedSlice(
    allocator: std.mem.Allocator,
    slot: *?[]u8,
    bytes: []const u8,
) error{OutOfMemory}!void {
    if (test_replace_fail_after) |limit| {
        if (test_replace_success_count >= limit) return error.OutOfMemory;
    }
    const fresh = try allocator.dupe(u8, bytes);
    if (slot.*) |old| allocator.free(old);
    slot.* = fresh;
    if (test_replace_fail_after != null) test_replace_success_count += 1;
}

/// Ensure parent directories exist without recreating existing symlink/dir parents.
///
/// After Guard.checkCreate, existing prefixes are contained. If the full parent
/// already opens as a directory (plain dir or contained dir symlink), skip
/// create. Otherwise create only the pure-missing suffix under the longest
/// openable prefix so `link_dir/nested/file` works when `link_dir` is a symlink.
fn ensureParentDirs(ctx: tool.Context, file_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(file_path) orelse return;
    if (dir_path.len == 0 or std.mem.eql(u8, dir_path, ".")) return;

    // Fast path: whole parent already a directory (plain or contained symlink).
    if (ctx.cwd.statFile(ctx.io, dir_path, .{ .follow_symlinks = true })) |st| {
        if (st.kind == .directory) return;
        return error.NotDir;
    } else |_| {}

    const seps: []const u8 = if (@import("builtin").os.tag == .windows) "/\\" else "/";

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(ctx.allocator);

    // Owned path of longest openable prefix; null means workspace cwd.
    var openable_owned: ?[]u8 = null;
    defer if (openable_owned) |p| ctx.allocator.free(p);

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(ctx.allocator);

    var saw_missing = false;
    var it = std.mem.tokenizeAny(u8, dir_path, seps);
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;

        if (saw_missing) {
            if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
            try missing.append(ctx.allocator, part);
            continue;
        }

        if (acc.items.len > 0) try acc.append(ctx.allocator, std.fs.path.sep);
        try acc.appendSlice(ctx.allocator, part);

        const partial = acc.items;
        if (ctx.cwd.statFile(ctx.io, partial, .{ .follow_symlinks = true })) |st| {
            if (st.kind != .directory) return error.NotDir;
            try replaceOwnedSlice(ctx.allocator, &openable_owned, partial);
        } else |_| {
            saw_missing = true;
            try missing.append(ctx.allocator, part);
        }
    }

    if (missing.items.len == 0) return;

    // Join missing parts into a relative create path.
    const rel_create = try std.fs.path.join(ctx.allocator, missing.items);
    defer ctx.allocator.free(rel_create);

    if (openable_owned) |prefix| {
        var base = try ctx.cwd.openDir(ctx.io, prefix, .{ .access_sub_paths = true });
        defer base.close(ctx.io);
        try base.createDirPath(ctx.io, rel_create);
    } else {
        try ctx.cwd.createDirPath(ctx.io, rel_create);
    }
}

fn maybeAppendGitDiff(ctx: tool.Context, path: []const u8, base: []u8) tool.HandlerError![]u8 {
    // Best-effort enrichment: the edit already succeeded.
    const diff = captureGitDiff(ctx, path) catch return base;
    defer ctx.allocator.free(diff);
    if (diff.len == 0) return base;

    const clipped = if (diff.len > max_diff_bytes) diff[0..max_diff_bytes] else diff;
    const merged = std.fmt.allocPrint(
        ctx.allocator,
        "{s}\n--- git diff ---\n{s}{s}",
        .{ base, clipped, if (diff.len > max_diff_bytes) "\n... diff truncated\n" else "" },
    ) catch return base;
    ctx.allocator.free(base);
    return merged;
}

fn captureGitDiff(ctx: tool.Context, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);
    const argv = [_][]const u8{ "git", "diff", "--", path };
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = &argv,
        .cwd = .{ .dir = ctx.cwd },
        .stdout_limit = .limited(max_diff_bytes + 1),
        .stderr_limit = .limited(1024),
        .timeout = .{
            .duration = .{
                .raw = .fromSeconds(5),
                .clock = .real,
            },
        },
    });
    defer ctx.allocator.free(result.stderr);
    errdefer ctx.allocator.free(result.stdout);

    switch (result.term) {
        .exited => {},
        else => {
            ctx.allocator.free(result.stdout);
            return error.ToolFailed;
        },
    }
    return result.stdout;
}

pub fn runShell(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const command = try tool.requireStringField(ctx.allocator, arguments_json, "command");
    defer ctx.allocator.free(command);
    if (command.len == 0) return error.InvalidArguments;

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = &argv,
        .cwd = .{ .dir = ctx.cwd },
        .stdout_limit = .limited(max_shell_output),
        .stderr_limit = .limited(max_shell_output),
        .timeout = .{
            .duration = .{
                .raw = .fromSeconds(shell_timeout_secs),
                .clock = .real,
            },
        },
    }) catch |err| return shellRunError(ctx.allocator, command, err);
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    return formatShellResult(ctx.allocator, result.term, result.stdout, result.stderr);
}

fn shellRunError(
    gpa: std.mem.Allocator,
    command: []const u8,
    err: anyerror,
) tool.HandlerError![]u8 {
    const core_err = @import("zag-agent-core").tool_error;
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => {
            const msg = try std.fmt.allocPrint(
                gpa,
                "command timed out after {d}s: {s}",
                .{ shell_timeout_secs, command },
            );
            defer gpa.free(msg);
            return core_err.format(gpa, .tool_failed, msg);
        },
        error.StreamTooLong => {
            const msg = try std.fmt.allocPrint(
                gpa,
                "command output exceeded {d} bytes (truncated). Command: {s}",
                .{ max_shell_output, command },
            );
            defer gpa.free(msg);
            return core_err.format(gpa, .tool_failed, msg);
        },
        else => {
            const msg = try std.fmt.allocPrint(
                gpa,
                "failed to run command ({s}): {s}",
                .{ @errorName(err), command },
            );
            defer gpa.free(msg);
            return core_err.format(gpa, .tool_failed, msg);
        },
    };
}

fn formatShellResult(
    gpa: std.mem.Allocator,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
) tool.HandlerError![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    switch (term) {
        .exited => |c| out.writer.print("exit_code: {d}\n", .{c}) catch return error.OutOfMemory,
        .signal => |s| out.writer.print("signal: {d}\n", .{@intFromEnum(s)}) catch return error.OutOfMemory,
        .stopped => |s| out.writer.print("stopped: {d}\n", .{@intFromEnum(s)}) catch return error.OutOfMemory,
        .unknown => |u| out.writer.print("unknown_status: {d}\n", .{u}) catch return error.OutOfMemory,
    }
    try appendStream(&out, "--- stdout ---\n", stdout);
    try appendStream(&out, "--- stderr ---\n", stderr);
    if (stdout.len == 0 and stderr.len == 0) {
        out.writer.writeAll("(no output)\n") catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn appendStream(out: *Io.Writer.Allocating, header: []const u8, body: []const u8) tool.HandlerError!void {
    if (body.len == 0) return;
    out.writer.writeAll(header) catch return error.OutOfMemory;
    out.writer.writeAll(body) catch return error.OutOfMemory;
    if (body[body.len - 1] != '\n') {
        out.writer.writeAll("\n") catch return error.OutOfMemory;
    }
}

const path_write_caps: tool.ToolCapabilities = .{
    .risk = .write,
    .workspace = .{ .path_field = "path" },
    .cancellation = .none,
    .shell = .none,
};

const shell_caps: tool.ToolCapabilities = .{
    .risk = .execute,
    .workspace = .none,
    .cancellation = .none,
    .shell = .command_argument,
};

pub fn phase1ExtraTools() [3]tool.Tool {
    return .{
        tool.stateless(.{ .definition = search_replace_def, .capabilities = path_write_caps }, searchReplace),
        tool.stateless(.{ .definition = write_file_def, .capabilities = path_write_caps }, writeFile),
        tool.stateless(.{ .definition = run_shell_def, .capabilities = shell_caps }, runShell),
    };
}

test "applyUniqueReplace happy path" {
    // Goal: single unique anchor is replaced exactly once.
    const gpa = std.testing.allocator;
    const out = try applyUniqueReplace(gpa, "alpha beta gamma", "beta", "BETA");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("alpha BETA gamma", out);
}

test "applyUniqueReplace not found and ambiguous" {
    // Goal: zero and multi match map to distinct soft-fail errors.
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.AnchorNotFound,
        applyUniqueReplace(gpa, "abc", "zz", "x"),
    );
    try std.testing.expectError(
        error.AmbiguousAnchor,
        applyUniqueReplace(gpa, "aa aa", "aa", "b"),
    );
}

test "replaceOwnedSlice OOM leaves previous value (no double-free)" {
    // Regression for ensureParentDirs openable update: free-then-dupe double-freed
    // on OOM via outer defer. Ownership must be allocate → swap → free old.
    const gpa = std.testing.allocator;

    // --- real allocator OOM on first attempt (slot already set) ---
    var slot: ?[]u8 = try gpa.dupe(u8, "first-prefix");
    defer if (slot) |p| gpa.free(p);

    var failing_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        replaceOwnedSlice(failing_state.allocator(), &slot, "second-prefix"),
    );
    try std.testing.expect(slot != null);
    try std.testing.expectEqualStrings("first-prefix", slot.?);

    // --- success path swaps cleanly ---
    try replaceOwnedSlice(gpa, &slot, "second-prefix");
    try std.testing.expectEqualStrings("second-prefix", slot.?);

    // --- hook: fail after one successful install (mirrors openable walk) ---
    test_replace_fail_after = 1;
    test_replace_success_count = 0;
    defer {
        test_replace_fail_after = null;
        test_replace_success_count = 0;
    }

    var slot2: ?[]u8 = null;
    defer if (slot2) |p| gpa.free(p);
    try replaceOwnedSlice(gpa, &slot2, "a");
    try std.testing.expectEqualStrings("a", slot2.?);
    try std.testing.expectError(error.OutOfMemory, replaceOwnedSlice(gpa, &slot2, "a/b"));
    // Still owns "a" exactly once — gpa leak check + equal proves no double-free.
    try std.testing.expectEqualStrings("a", slot2.?);
}

test "ensureParentDirs OOM after openable prefix: no leak, no create, no outside write" {
    // Path a/b/c/file.txt with a and a/b existing: first openable install succeeds,
    // second (a/b) hits test_replace_fail_after → OOM with first prefix still deferred.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/a/b");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/marker.txt", .data = "OUT\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .access_sub_paths = true });
    defer ws.close(io);

    test_replace_fail_after = 1; // succeed once ("a"), fail on "a/b"
    test_replace_success_count = 0;
    defer {
        test_replace_fail_after = null;
        test_replace_success_count = 0;
    }

    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };
    try std.testing.expectError(error.OutOfMemory, ensureParentDirs(ctx, "a/b/c/file.txt"));

    // No partial create of missing suffix.
    try std.testing.expectError(error.FileNotFound, ws.statFile(io, "a/b/c", .{}));
    try std.testing.expectError(error.FileNotFound, ws.statFile(io, "a/b/c/file.txt", .{}));
    // Existing prefixes intact.
    const b_st = try ws.statFile(io, "a/b", .{});
    try std.testing.expect(b_st.kind == .directory);
    // Outside sibling untouched / not created into.
    const marker = try parent.dir.readFileAlloc(io, "outside/marker.txt", gpa, .limited(16));
    defer gpa.free(marker);
    try std.testing.expectEqualStrings("OUT\n", marker);
    try std.testing.expectError(error.FileNotFound, parent.dir.statFile(io, "outside/c", .{}));
}

test "search_replace write_file run_shell in tmp dir" {
    // Goal: ambiguous / success / missing anchors + shell smoke in an isolated dir.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ctx: tool.Context = .{
        .allocator = gpa,
        .io = io,
        .cwd = tmp.dir,
    };

    const written = try writeFile(ctx, null,
        \\{"path":"hello.txt","content":"line one\nline two\nline one\n"}
    );
    defer gpa.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "ok:") != null);

    const amb = try searchReplace(ctx, null,
        \\{"path":"hello.txt","old_string":"line one","new_string":"LINE"}
    );
    defer gpa.free(amb);
    try std.testing.expect(std.mem.indexOf(u8, amb, "ambiguous_anchor") != null);

    const ok = try searchReplace(ctx, null,
        \\{"path":"hello.txt","old_string":"line two","new_string":"line 2"}
    );
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "ok: search_replace") != null);

    const read_back = try tmp.dir.readFileAlloc(io, "hello.txt", gpa, .limited(1024));
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings("line one\nline 2\nline one\n", read_back);

    const missing = try searchReplace(ctx, null,
        \\{"path":"hello.txt","old_string":"nope","new_string":"x"}
    );
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "anchor_not_found") != null);

    // Nested create under containment still works.
    const nested = try writeFile(ctx, null,
        \\{"path":"a/b/c.txt","content":"nested-ok\n"}
    );
    defer gpa.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "ok:") != null);
    const nested_read = try tmp.dir.readFileAlloc(io, "a/b/c.txt", gpa, .limited(64));
    defer gpa.free(nested_read);
    try std.testing.expectEqualStrings("nested-ok\n", nested_read);

    const shell = try runShell(ctx, null, "{\"command\":\"echo shell-ok\"}");
    defer gpa.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "exit_code: 0") != null);
}

test "symlink containment: write/search_replace cannot mutate outside" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();

    try parent.dir.createDirPath(io, "outside");
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "OUTSIDE_ORIGINAL\n" });
    try parent.dir.writeFile(io, .{ .sub_path = "ws/inside.txt", .data = "alpha beta gamma\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);

    try ws.symLink(io, "../outside/secret.txt", "escape_file", .{});
    try ws.symLink(io, "inside.txt", "link_in", .{});
    try ws.symLink(io, "../outside", "escape_dir", .{ .is_directory = true });
    try ws.symLink(io, "../missing", "dangling", .{});

    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    // write via escaping final symlink denied; outside unchanged
    const w_esc = try writeFile(ctx, null,
        \\{"path":"escape_file","content":"PWNED\n"}
    );
    defer gpa.free(w_esc);
    try std.testing.expect(std.mem.indexOf(u8, w_esc, "code=jail_deny") != null);
    const outside1 = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
    defer gpa.free(outside1);
    try std.testing.expectEqualStrings("OUTSIDE_ORIGINAL\n", outside1);

    // write under escaping parent denied
    const w_parent = try writeFile(ctx, null,
        \\{"path":"escape_dir/new.txt","content":"nope\n"}
    );
    defer gpa.free(w_parent);
    try std.testing.expect(std.mem.indexOf(u8, w_parent, "code=jail_deny") != null);

    // dangling parent denied
    const w_dang = try writeFile(ctx, null,
        \\{"path":"dangling/x.txt","content":"nope\n"}
    );
    defer gpa.free(w_dang);
    try std.testing.expect(std.mem.indexOf(u8, w_dang, "code=jail_deny") != null);

    // search_replace escaping denied; outside unchanged
    const sr_esc = try searchReplace(ctx, null,
        \\{"path":"escape_file","old_string":"OUTSIDE_ORIGINAL","new_string":"PWNED"}
    );
    defer gpa.free(sr_esc);
    try std.testing.expect(std.mem.indexOf(u8, sr_esc, "code=jail_deny") != null);
    const outside2 = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
    defer gpa.free(outside2);
    try std.testing.expectEqualStrings("OUTSIDE_ORIGINAL\n", outside2);

    // contained file symlink write/replace allowed and only mutates inside target
    const w_in = try writeFile(ctx, null,
        \\{"path":"link_in","content":"alpha BETA gamma\n"}
    );
    defer gpa.free(w_in);
    try std.testing.expect(std.mem.indexOf(u8, w_in, "ok:") != null);
    const inside1 = try ws.readFileAlloc(io, "inside.txt", gpa, .limited(64));
    defer gpa.free(inside1);
    try std.testing.expectEqualStrings("alpha BETA gamma\n", inside1);

    const sr_in = try searchReplace(ctx, null,
        \\{"path":"link_in","old_string":"BETA","new_string":"beta"}
    );
    defer gpa.free(sr_in);
    try std.testing.expect(std.mem.indexOf(u8, sr_in, "ok: search_replace") != null);
    const inside2 = try ws.readFileAlloc(io, "inside.txt", gpa, .limited(64));
    defer gpa.free(inside2);
    try std.testing.expectEqualStrings("alpha beta gamma\n", inside2);

    // outside still original
    const outside3 = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
    defer gpa.free(outside3);
    try std.testing.expectEqualStrings("OUTSIDE_ORIGINAL\n", outside3);

    // Exploit: missing prefix + `..` + escape dir must not create outside files.
    const exploit = try writeFile(ctx, null,
        \\{"path":"brand_new/../escape_dir/pwned.txt","content":"PWNED\n"}
    );
    defer gpa.free(exploit);
    try std.testing.expect(std.mem.indexOf(u8, exploit, "code=jail_deny") != null);
    // outside has no pwned; brand_new should not be left as a partial escape path
    const pwned = parent.dir.statFile(io, "outside/pwned.txt", .{});
    try std.testing.expectError(error.FileNotFound, pwned);
}

test "contained directory symlink write and nested create" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();

    try parent.dir.createDirPath(io, "ws/inside_dir");
    try parent.dir.writeFile(io, .{ .sub_path = "ws/inside_dir/a.txt", .data = "hello world\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);
    try ws.symLink(io, "inside_dir", "link_dir", .{ .is_directory = true });

    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    // write under contained dir symlink (existing parent is symlink)
    const w_new = try writeFile(ctx, null,
        \\{"path":"link_dir/new.txt","content":"from-link\n"}
    );
    defer gpa.free(w_new);
    try std.testing.expect(std.mem.indexOf(u8, w_new, "ok:") != null);
    const on_real = try ws.readFileAlloc(io, "inside_dir/new.txt", gpa, .limited(64));
    defer gpa.free(on_real);
    try std.testing.expectEqualStrings("from-link\n", on_real);

    // nested create under contained dir symlink
    const w_nest = try writeFile(ctx, null,
        \\{"path":"link_dir/sub/deep.txt","content":"deep-ok\n"}
    );
    defer gpa.free(w_nest);
    try std.testing.expect(std.mem.indexOf(u8, w_nest, "ok:") != null);
    const deep = try ws.readFileAlloc(io, "inside_dir/sub/deep.txt", gpa, .limited(64));
    defer gpa.free(deep);
    try std.testing.expectEqualStrings("deep-ok\n", deep);

    // read/list/search_replace via dir link
    const listed = try @import("fs_tools.zig").listDir(ctx, null, "{\"path\":\"link_dir\"}");
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "new.txt") != null);

    const read = try @import("fs_tools.zig").readFile(ctx, null, "{\"path\":\"link_dir/a.txt\"}");
    defer gpa.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "hello world") != null);

    const sr = try searchReplace(ctx, null,
        \\{"path":"link_dir/a.txt","old_string":"hello","new_string":"HELLO"}
    );
    defer gpa.free(sr);
    try std.testing.expect(std.mem.indexOf(u8, sr, "ok: search_replace") != null);
    const a_after = try ws.readFileAlloc(io, "inside_dir/a.txt", gpa, .limited(64));
    defer gpa.free(a_after);
    try std.testing.expectEqualStrings("HELLO world\n", a_after);
}
