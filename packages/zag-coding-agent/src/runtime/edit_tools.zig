//! Write / edit / shell tools: `search_replace`, `write_file`, `run_shell`.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;

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

pub fn searchReplace(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
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

pub fn writeFile(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
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

    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) {
            ctx.cwd.createDirPath(ctx.io, dir_path) catch return error.ToolFailed;
        }
    }

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

pub fn runShell(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
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

pub fn phase1ExtraTools() [3]tool.Tool {
    return .{
        .{ .definition = search_replace_def, .handler = searchReplace },
        .{ .definition = write_file_def, .handler = writeFile },
        .{ .definition = run_shell_def, .handler = runShell },
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

    const written = try writeFile(
        ctx,
        \\{"path":"hello.txt","content":"line one\nline two\nline one\n"}
    );
    defer gpa.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "ok:") != null);

    const amb = try searchReplace(
        ctx,
        \\{"path":"hello.txt","old_string":"line one","new_string":"LINE"}
    );
    defer gpa.free(amb);
    try std.testing.expect(std.mem.indexOf(u8, amb, "ambiguous_anchor") != null);

    const ok = try searchReplace(
        ctx,
        \\{"path":"hello.txt","old_string":"line two","new_string":"line 2"}
    );
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "ok: search_replace") != null);

    const read_back = try tmp.dir.readFileAlloc(io, "hello.txt", gpa, .limited(1024));
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings("line one\nline 2\nline one\n", read_back);

    const missing = try searchReplace(
        ctx,
        \\{"path":"hello.txt","old_string":"nope","new_string":"x"}
    );
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "anchor_not_found") != null);

    const shell = try runShell(ctx, "{\"command\":\"echo shell-ok\"}");
    defer gpa.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "exit_code: 0") != null);
}

