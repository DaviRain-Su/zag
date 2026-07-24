//! Write / edit / shell tools: `search_replace`, `write_file`, `run_shell`.
//!
//! File mutators enforce symlink-aware workspace containment (h-workspace-001)
//! so raw `Registry.execute` cannot bypass the jail. Shell remains a separate
//! boundary (not contained by the path jail).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const trace = core.trace;
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
    \\Run a foreground shell command in the working directory via /bin/sh -c.
    \\Stdout and stderr are captured with fixed limits and a 30s capture deadline.
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
const production_shell_path = "/bin/sh";
const shell_capture_timeout_ms: u32 = 30_000;
const max_shell_stream_bytes: usize = 30 * 1024;
const max_shell_envelope_bytes: usize = 4 * 1024;
const max_diff_bytes: u32 = 4 * 1024;

const ShellConfig = struct {
    shell_path: []const u8 = production_shell_path,
    timeout_ms: u32 = shell_capture_timeout_ms,
    stdout_limit: usize = max_shell_stream_bytes,
    stderr_limit: usize = max_shell_stream_bytes,
};

var test_shell_config: if (builtin.is_test) ShellConfig else void =
    if (builtin.is_test) .{} else {};

fn activeShellConfig() ShellConfig {
    if (builtin.is_test) return test_shell_config;
    return .{};
}

/// Test-only shell seam. The empty production namespace exposes no controls.
/// It deliberately contains only the four contract-approved settings.
pub const testing = if (builtin.is_test) struct {
    pub fn configure(
        shell_path: []const u8,
        timeout_ms: u32,
        stdout_limit: usize,
        stderr_limit: usize,
    ) void {
        test_shell_config = .{
            .shell_path = shell_path,
            .timeout_ms = timeout_ms,
            .stdout_limit = stdout_limit,
            .stderr_limit = stderr_limit,
        };
    }

    pub fn reset() void {
        test_shell_config = .{};
    }
} else struct {};

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

/// Replace `slot` with a freshly owned copy of `bytes`.
///
/// Allocates **before** freeing the previous value so OOM leaves the old
/// slice installed (defer cannot double-free an already-freed pointer).
fn replaceOwnedSlice(
    allocator: std.mem.Allocator,
    slot: *?[]u8,
    bytes: []const u8,
) error{OutOfMemory}!void {
    const fresh = try allocator.dupe(u8, bytes);
    if (slot.*) |old| allocator.free(old);
    slot.* = fresh;
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

const ShellResultCode = enum {
    shell_success,
    shell_nonzero,
    shell_signal,
    shell_timeout,
    shell_output_limit,
    shell_process_failure,

    fn name(self: ShellResultCode) []const u8 {
        return @tagName(self);
    }
};

const stdout_section = "--- stdout ---\n";
const stderr_section = "--- stderr ---\n";

const ShellStreamEncoding = enum {
    utf8,
    base64,

    fn name(self: ShellStreamEncoding) []const u8 {
        return @tagName(self);
    }
};

const ShellStreamRepresentation = struct {
    bytes: []const u8,
    encoding: ShellStreamEncoding,
    represented_len: usize,
    needs_newline: bool,
};

const ShellFormatError = error{
    OutOfMemory,
    ShellEnvelopeTooLong,
    ShellBodyTooLong,
};

const ShellBodyLayout = struct {
    envelope_len: usize,
    body_len: usize,
};

pub fn runShell(ctx: tool.Context, instance: ?*anyopaque, arguments_json: []const u8) tool.HandlerError![]u8 {
    _ = instance;
    const command = try tool.requireStringField(ctx.allocator, arguments_json, "command");
    defer ctx.allocator.free(command);
    if (command.len == 0) return error.InvalidArguments;

    const config = activeShellConfig();
    const argv = [_][]const u8{ config.shell_path, "-c", command };

    // Convert the one 30,000 ms `.awake` duration to one absolute capture
    // deadline before entering `std.process.run`. Passing a duration here would
    // let each MultiReader fill convert it afresh and reset the capture budget.
    const capture_duration: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(@intCast(config.timeout_ms)),
        .clock = .awake,
    } };
    const capture_deadline = capture_duration.toDeadline(ctx.io);

    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = &argv,
        .cwd = .{ .dir = ctx.cwd },
        .stdout_limit = .limited(config.stdout_limit),
        .stderr_limit = .limited(config.stderr_limit),
        .timeout = capture_deadline,
    }) catch |err| return shellRunError(ctx.allocator, config, err);
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    return formatShellResult(ctx.allocator, result.term, result.stdout, result.stderr) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ShellEnvelopeTooLong, error.ShellBodyTooLong => error.ToolFailed,
    };
}

/// `std.process.run` does not expose a reliable finer-grained phase. All run
/// errors therefore use fixed `stage=run`; no command, shell path, or raw error
/// name is admitted to diagnostics. OOM remains a hard typed host error.
fn shellRunError(
    gpa: std.mem.Allocator,
    config: ShellConfig,
    err: anyerror,
) tool.HandlerError![]u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => ownShellHeader(
            gpa,
            "error: code={s} format=shell-v1 timeout_ms={d} partial_output_available=false cleanup_scope=direct_child",
            .{ ShellResultCode.shell_timeout.name(), config.timeout_ms },
        ),
        error.StreamTooLong => ownShellHeader(
            gpa,
            "error: code={s} format=shell-v1 limit_scope=capture stdout_limit_bytes={d} stderr_limit_bytes={d} exceeded_stream=unknown partial_output_available=false cleanup_scope=direct_child",
            .{
                ShellResultCode.shell_output_limit.name(),
                config.stdout_limit,
                config.stderr_limit,
            },
        ),
        else => ownShellHeader(
            gpa,
            "error: code={s} format=shell-v1 stage=run partial_output_available=false",
            .{ShellResultCode.shell_process_failure.name()},
        ),
    };
}

fn ownShellHeader(
    gpa: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) tool.HandlerError![]u8 {
    var header_buf: [trace.cap_tool_result_body]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, fmt, args) catch return error.ToolFailed;
    std.debug.assert(std.mem.indexOfScalar(u8, header, '\n') == null);
    return gpa.dupe(u8, header) catch return error.OutOfMemory;
}

fn formatShellResult(
    gpa: std.mem.Allocator,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
) ShellFormatError![]u8 {
    const stdout_rep = try classifyShellStream(stdout);
    const stderr_rep = try classifyShellStream(stderr);

    var header_buf: [trace.cap_tool_result_body]u8 = undefined;
    const header = formatShellTermHeader(&header_buf, term, stdout_rep, stderr_rep) catch
        return error.ShellEnvelopeTooLong;
    std.debug.assert(std.mem.indexOfScalar(u8, header, '\n') == null);

    const layout = checkedShellBodyLayout(
        header.len,
        stdout_rep.represented_len,
        stderr_rep.represented_len,
        stdout_rep.needs_newline,
        stderr_rep.needs_newline,
    ) catch |err| switch (err) {
        error.ShellBodyTooLong => return formatShellBodyEncodingLimit(gpa, stdout_rep, stderr_rep),
        error.ShellEnvelopeTooLong => return error.ShellEnvelopeTooLong,
        error.OutOfMemory => unreachable,
    };

    // The one allocation happens only after checked represented lengths prove
    // both the 4 KiB envelope and shared 64 KiB Tool-result ceiling. Base64 is
    // encoded directly into this final buffer; there is no intermediate copy.
    const body = try gpa.alloc(u8, layout.body_len);
    errdefer gpa.free(body);
    var cursor: usize = 0;
    appendBodyBytes(body, &cursor, header);
    appendBodyBytes(body, &cursor, "\n");
    appendBodyBytes(body, &cursor, stdout_section);
    appendRepresentedStream(body, &cursor, stdout_rep);
    if (stdout_rep.needs_newline) appendBodyBytes(body, &cursor, "\n");
    appendBodyBytes(body, &cursor, stderr_section);
    appendRepresentedStream(body, &cursor, stderr_rep);
    if (stderr_rep.needs_newline) appendBodyBytes(body, &cursor, "\n");
    std.debug.assert(cursor == layout.body_len);
    return body;
}

fn classifyShellStream(bytes: []const u8) ShellFormatError!ShellStreamRepresentation {
    const encoding: ShellStreamEncoding = if (std.unicode.utf8ValidateSlice(bytes))
        .utf8
    else
        .base64;
    const represented_len = switch (encoding) {
        .utf8 => bytes.len,
        .base64 => try checkedBase64EncodedLen(bytes.len),
    };
    const needs_newline = represented_len > 0 and switch (encoding) {
        .utf8 => bytes[bytes.len - 1] != '\n',
        .base64 => true,
    };
    return .{
        .bytes = bytes,
        .encoding = encoding,
        .represented_len = represented_len,
        .needs_newline = needs_newline,
    };
}

fn checkedBase64EncodedLen(raw_len: usize) error{ShellBodyTooLong}!usize {
    const complete_groups = raw_len / 3;
    var encoded_len = std.math.mul(usize, complete_groups, 4) catch
        return error.ShellBodyTooLong;
    if (raw_len % 3 != 0) {
        encoded_len = std.math.add(usize, encoded_len, 4) catch
            return error.ShellBodyTooLong;
    }
    return encoded_len;
}

fn formatShellTermHeader(
    buf: []u8,
    term: std.process.Child.Term,
    stdout: ShellStreamRepresentation,
    stderr: ShellStreamRepresentation,
) error{NoSpaceLeft}![]u8 {
    return switch (term) {
        .exited => |exit_code| if (exit_code == 0)
            std.fmt.bufPrint(
                buf,
                "ok: code={s} format=shell-v1 exit_code=0 stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} stdout_truncated=false stderr_truncated=false",
                .{
                    ShellResultCode.shell_success.name(),
                    stdout.bytes.len,
                    stderr.bytes.len,
                    stdout.encoding.name(),
                    stderr.encoding.name(),
                },
            )
        else
            std.fmt.bufPrint(
                buf,
                "error: code={s} format=shell-v1 exit_code={d} stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} stdout_truncated=false stderr_truncated=false",
                .{
                    ShellResultCode.shell_nonzero.name(),
                    exit_code,
                    stdout.bytes.len,
                    stderr.bytes.len,
                    stdout.encoding.name(),
                    stderr.encoding.name(),
                },
            ),
        .signal => |signal| std.fmt.bufPrint(
            buf,
            "error: code={s} format=shell-v1 signal={d} stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} stdout_truncated=false stderr_truncated=false",
            .{
                ShellResultCode.shell_signal.name(),
                @intFromEnum(signal),
                stdout.bytes.len,
                stderr.bytes.len,
                stdout.encoding.name(),
                stderr.encoding.name(),
            },
        ),
        .stopped => |signal| std.fmt.bufPrint(
            buf,
            "error: code={s} format=shell-v1 stage=term term=stopped signal={d} stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} stdout_truncated=false stderr_truncated=false",
            .{
                ShellResultCode.shell_process_failure.name(),
                @intFromEnum(signal),
                stdout.bytes.len,
                stderr.bytes.len,
                stdout.encoding.name(),
                stderr.encoding.name(),
            },
        ),
        .unknown => |status| std.fmt.bufPrint(
            buf,
            "error: code={s} format=shell-v1 stage=term term=unknown status={d} stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} stdout_truncated=false stderr_truncated=false",
            .{
                ShellResultCode.shell_process_failure.name(),
                status,
                stdout.bytes.len,
                stderr.bytes.len,
                stdout.encoding.name(),
                stderr.encoding.name(),
            },
        ),
    };
}

fn formatShellBodyEncodingLimit(
    gpa: std.mem.Allocator,
    stdout: ShellStreamRepresentation,
    stderr: ShellStreamRepresentation,
) ShellFormatError![]u8 {
    var header_buf: [trace.cap_tool_result_body]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "error: code={s} format=shell-v1 limit_scope=body_encoding stdout_bytes={d} stderr_bytes={d} stdout_encoding={s} stderr_encoding={s} body_limit_bytes={d} partial_output_available=false cleanup_scope=direct_child",
        .{
            ShellResultCode.shell_output_limit.name(),
            stdout.bytes.len,
            stderr.bytes.len,
            stdout.encoding.name(),
            stderr.encoding.name(),
            tool.max_result_bytes,
        },
    ) catch return error.ShellEnvelopeTooLong;
    return gpa.dupe(u8, header) catch return error.OutOfMemory;
}

fn checkedShellBodyLayout(
    header_len: usize,
    stdout_represented_len: usize,
    stderr_represented_len: usize,
    stdout_needs_newline: bool,
    stderr_needs_newline: bool,
) ShellFormatError!ShellBodyLayout {
    var envelope_len: usize = 0;
    envelope_len = std.math.add(usize, envelope_len, header_len) catch
        return error.ShellEnvelopeTooLong;
    envelope_len = std.math.add(usize, envelope_len, 1) catch
        return error.ShellEnvelopeTooLong;
    envelope_len = std.math.add(usize, envelope_len, stdout_section.len) catch
        return error.ShellEnvelopeTooLong;
    if (stdout_needs_newline) {
        envelope_len = std.math.add(usize, envelope_len, 1) catch
            return error.ShellEnvelopeTooLong;
    }
    envelope_len = std.math.add(usize, envelope_len, stderr_section.len) catch
        return error.ShellEnvelopeTooLong;
    if (stderr_needs_newline) {
        envelope_len = std.math.add(usize, envelope_len, 1) catch
            return error.ShellEnvelopeTooLong;
    }
    if (envelope_len > max_shell_envelope_bytes) return error.ShellEnvelopeTooLong;

    var body_len = std.math.add(usize, stdout_represented_len, stderr_represented_len) catch
        return error.ShellBodyTooLong;
    body_len = std.math.add(usize, body_len, envelope_len) catch
        return error.ShellBodyTooLong;
    if (body_len > tool.max_result_bytes) return error.ShellBodyTooLong;

    return .{ .envelope_len = envelope_len, .body_len = body_len };
}

fn appendBodyBytes(body: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(cursor.* <= body.len);
    std.debug.assert(bytes.len <= body.len - cursor.*);
    @memcpy(body[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn appendRepresentedStream(
    body: []u8,
    cursor: *usize,
    stream: ShellStreamRepresentation,
) void {
    switch (stream.encoding) {
        .utf8 => appendBodyBytes(body, cursor, stream.bytes),
        .base64 => {
            std.debug.assert(cursor.* <= body.len);
            std.debug.assert(stream.represented_len <= body.len - cursor.*);
            const dest = body[cursor.*..][0..stream.represented_len];
            const encoded = std.base64.standard.Encoder.encode(dest, stream.bytes);
            std.debug.assert(encoded.len == stream.represented_len);
            cursor.* += stream.represented_len;
        },
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
    // Ownership must be allocate → swap → free old so FailingAllocator dupe OOM
    // cannot leave a freed pointer for an outer defer.
    const gpa = std.testing.allocator;

    var slot: ?[]u8 = try gpa.dupe(u8, "first-prefix");
    defer if (slot) |p| gpa.free(p);

    var failing_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expect(failing_state.has_induced_failure == false);
    try std.testing.expectError(
        error.OutOfMemory,
        replaceOwnedSlice(failing_state.allocator(), &slot, "second-prefix"),
    );
    try std.testing.expect(failing_state.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing_state.alloc_index);
    // Previous value still installed and owned exactly once (gpa leak check).
    try std.testing.expect(slot != null);
    try std.testing.expectEqualStrings("first-prefix", slot.?);

    try replaceOwnedSlice(gpa, &slot, "second-prefix");
    try std.testing.expectEqualStrings("second-prefix", slot.?);
}

test "ensureParentDirs OOM after openable prefix: no leak, no create, no outside write" {
    // Short path a/b/c/file.txt with a and a/b already present.
    // Zig 0.16 allocation sequence under FailingAllocator (measured):
    //   #0 acc first growth (appendSlice "a")
    //   #1 replaceOwnedSlice dupe "a"   ← first openable install
    //   #2 replaceOwnedSlice dupe "a/b" ← fail_index=2 fails this real dupe
    // So the second openable update hits allocator.dupe OOM while openable_owned
    // still holds "a"; defer must free it once (no double-free / leak via gpa).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/a/b");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/marker.txt", .data = "OUT\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .access_sub_paths = true });
    defer ws.close(io);

    var failing_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    const ctx: tool.Context = .{
        .allocator = failing_state.allocator(),
        .io = io,
        .cwd = ws,
    };
    try std.testing.expectError(error.OutOfMemory, ensureParentDirs(ctx, "a/b/c/file.txt"));

    // Real allocator failure on the third allocation attempt (second prefix dupe).
    try std.testing.expect(failing_state.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 2), failing_state.alloc_index);
    // Two successful allocs (#0 acc, #1 dupe "a") then free of openable "a" on error path.
    try std.testing.expectEqual(@as(usize, 2), failing_state.allocations);
    try std.testing.expect(failing_state.deallocations >= 1);
    try std.testing.expectEqual(failing_state.allocated_bytes, failing_state.freed_bytes);

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
    try std.testing.expect(std.mem.startsWith(u8, shell, "ok: code=shell_success format=shell-v1 exit_code=0 "));
}

fn requireRealPosixShellFixture() !void {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return error.SkipZigTest,
    }
}

fn firstLine(body: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    return body[0..end];
}

fn expectRecordedDirectChildGone(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
) !void {
    const raw = try cwd.readFileAlloc(io, path, gpa, .limited(64));
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const pid = try std.fmt.parseInt(std.posix.pid_t, trimmed, 10);
    try std.testing.expect(pid > 0);

    // Signal zero performs no mutation. `ProcessNotFound` proves only that the
    // recorded direct PID is absent after handler return. Pinned Zig 0.16
    // source separately establishes the `defer child.kill(io)` mechanism.
    const signal_zero: std.posix.SIG = @enumFromInt(0);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, signal_zero));
}

test "shell-v1 success preserves exact stdout and stderr sections" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const body = try runShell(ctx, null,
        \\{"command":"printf out; printf err >&2"}
    );
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=3 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\nout\n--- stderr ---\nerr\n",
        body,
    );
}

test "shell-v1 nonzero exit and POSIX signal retain exact terms" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const nonzero = try runShell(ctx, null,
        \\{"command":"printf no; printf bad >&2; exit 7"}
    );
    defer gpa.free(nonzero);
    try std.testing.expectEqualStrings(
        "error: code=shell_nonzero format=shell-v1 exit_code=7 stdout_bytes=2 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\nno\n--- stderr ---\nbad\n",
        nonzero,
    );

    const signaled = try runShell(ctx, null,
        \\{"command":"kill -TERM $$"}
    );
    defer gpa.free(signaled);
    var expected: [512]u8 = undefined;
    const expected_body = try std.fmt.bufPrint(
        &expected,
        "error: code=shell_signal format=shell-v1 signal={d} stdout_bytes=0 stderr_bytes=0 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n--- stderr ---\n",
        .{@intFromEnum(std.posix.SIG.TERM)},
    );
    try std.testing.expectEqualStrings(expected_body, signaled);
}

test "shell-v1 timeout return leaves recorded direct PID absent" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.configure(production_shell_path, 500, max_shell_stream_bytes, max_shell_stream_bytes);
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const body = try runShell(ctx, null,
        \\{"command":": RAW_TIMEOUT_COMMAND_SECRET; echo $$ > timeout.pid; while :; do :; done"}
    );
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=shell_timeout format=shell-v1 timeout_ms=500 partial_output_available=false cleanup_scope=direct_child",
        body,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "RAW_TIMEOUT_COMMAND_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stdout ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stderr ---") == null);
    try expectRecordedDirectChildGone(gpa, io, tmp.dir, "timeout.pid");
}

test "shell-v1 capture output limit has no partial and recorded direct PID is absent" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.configure(production_shell_path, shell_capture_timeout_ms, 16, 17);
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const body = try runShell(ctx, null,
        \\{"command":": RAW_OUTPUT_COMMAND_SECRET; echo $$ > output.pid; while :; do printf 0123456789; done"}
    );
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=shell_output_limit format=shell-v1 limit_scope=capture stdout_limit_bytes=16 stderr_limit_bytes=17 exceeded_stream=unknown partial_output_available=false cleanup_scope=direct_child",
        body,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "RAW_OUTPUT_COMMAND_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stdout ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stderr ---") == null);
    try expectRecordedDirectChildGone(gpa, io, tmp.dir, "output.pid");
}

test "shell-v1 invalid shell path is sanitized stage=run process failure" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const invalid_path = "/zag-test-does-not-exist/RAW_SHELL_PATH_SECRET";
    testing.configure(invalid_path, shell_capture_timeout_ms, max_shell_stream_bytes, max_shell_stream_bytes);
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    const body = try runShell(ctx, null,
        \\{"command":": RAW_PROCESS_COMMAND_SECRET"}
    );
    defer gpa.free(body);

    try std.testing.expectEqualStrings(
        "error: code=shell_process_failure format=shell-v1 stage=run partial_output_available=false",
        body,
    );
    for ([_][]const u8{
        invalid_path,
        "RAW_SHELL_PATH_SECRET",
        "RAW_PROCESS_COMMAND_SECRET",
        "FileNotFound",
        "AccessDenied",
        "InvalidExe",
    }) |forbidden| {
        try std.testing.expect(std.mem.indexOf(u8, body, forbidden) == null);
    }
}

test "shell-v1 stopped and unknown terms use fixed stage=term taxonomy" {
    const gpa = std.testing.allocator;

    const stopped = try formatShellResult(gpa, .{ .stopped = .STOP }, "s", "ee\n");
    defer gpa.free(stopped);
    var stopped_expected_buf: [512]u8 = undefined;
    const stopped_expected = try std.fmt.bufPrint(
        &stopped_expected_buf,
        "error: code=shell_process_failure format=shell-v1 stage=term term=stopped signal={d} stdout_bytes=1 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\ns\n--- stderr ---\nee\n",
        .{@intFromEnum(std.posix.SIG.STOP)},
    );
    try std.testing.expectEqualStrings(stopped_expected, stopped);

    const unknown_status = std.math.maxInt(u32);
    const unknown = try formatShellResult(gpa, .{ .unknown = unknown_status }, "", "u");
    defer gpa.free(unknown);
    try std.testing.expectEqualStrings(
        "error: code=shell_process_failure format=shell-v1 stage=term term=unknown status=4294967295 stdout_bytes=0 stderr_bytes=1 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n--- stderr ---\nu\n",
        unknown,
    );
}

test "shell-v1 valid UTF-8 is exact and invalid whole streams use padded base64" {
    const gpa = std.testing.allocator;

    const valid_utf8 = "h\xc3\xa9\n";
    const valid = try formatShellResult(gpa, .{ .exited = 0 }, valid_utf8, "err");
    defer gpa.free(valid);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=4 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\nh\xc3\xa9\n--- stderr ---\nerr\n",
        valid,
    );

    const invalid_only = [_]u8{0xff};
    const encoded_only = try formatShellResult(gpa, .{ .exited = 0 }, &invalid_only, "");
    defer gpa.free(encoded_only);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=1 stderr_bytes=0 stdout_encoding=base64 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n/w==\n--- stderr ---\n",
        encoded_only,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded_only));

    const mixed_invalid = [_]u8{ 'o', 'k', 0xff, '!' };
    const mixed = try formatShellResult(gpa, .{ .exited = 7 }, "plain", &mixed_invalid);
    defer gpa.free(mixed);
    try std.testing.expectEqualStrings(
        "error: code=shell_nonzero format=shell-v1 exit_code=7 stdout_bytes=5 stderr_bytes=4 stdout_encoding=utf8 stderr_encoding=base64 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\nplain\n--- stderr ---\nb2v/IQ==\n",
        mixed,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(mixed));

    // Exactly one successful allocation is the final body. A hypothetical
    // second/base64-intermediate allocation would trip fail_index=1.
    var one_allocation = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    const direct = try formatShellResult(one_allocation.allocator(), .{ .exited = 0 }, &invalid_only, "");
    defer one_allocation.allocator().free(direct);
    try std.testing.expect(!one_allocation.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), one_allocation.allocations);
}

test "shell-v1 base64 expansion over body budget is scoped soft output limit" {
    const gpa = std.testing.allocator;
    var stdout: [max_shell_stream_bytes]u8 = undefined;
    var stderr: [max_shell_stream_bytes]u8 = undefined;
    @memset(&stdout, 0xff);
    @memset(&stderr, 0xfe);

    const body = try formatShellResult(gpa, .{ .exited = 0 }, &stdout, &stderr);
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=shell_output_limit format=shell-v1 limit_scope=body_encoding stdout_bytes=30720 stderr_bytes=30720 stdout_encoding=base64 stderr_encoding=base64 body_limit_bytes=65536 partial_output_available=false cleanup_scope=direct_child",
        body,
    );
    try std.testing.expect(body.len <= tool.max_result_bytes);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stdout ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--- stderr ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=tool_failed") == null);
    try std.testing.expectError(
        error.ShellBodyTooLong,
        checkedBase64EncodedLen(std.math.maxInt(usize)),
    );
}

test "shell-v1 real runner enforces exactly N and N+1 capture boundaries" {
    try requireRealPosixShellFixture();
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const limit: usize = 8;
    testing.configure(production_shell_path, shell_capture_timeout_ms, limit, limit);
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const stdout_n = try runShell(ctx, null,
        \\{"command":"printf 12345678"}
    );
    defer gpa.free(stdout_n);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=8 stderr_bytes=0 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n12345678\n--- stderr ---\n",
        stdout_n,
    );

    const stderr_n = try runShell(ctx, null,
        \\{"command":"printf 12345678 >&2"}
    );
    defer gpa.free(stderr_n);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=0 stderr_bytes=8 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n--- stderr ---\n12345678\n",
        stderr_n,
    );

    const both_n = try runShell(ctx, null,
        \\{"command":"printf 12345678; printf 87654321 >&2"}
    );
    defer gpa.free(both_n);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=8 stderr_bytes=8 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false\n" ++
            "--- stdout ---\n12345678\n--- stderr ---\n87654321\n",
        both_n,
    );

    const capture_limit_header =
        "error: code=shell_output_limit format=shell-v1 limit_scope=capture stdout_limit_bytes=8 stderr_limit_bytes=8 exceeded_stream=unknown partial_output_available=false cleanup_scope=direct_child";
    const stdout_n_plus_one = try runShell(ctx, null,
        \\{"command":"printf 123456789"}
    );
    defer gpa.free(stdout_n_plus_one);
    try std.testing.expectEqualStrings(capture_limit_header, stdout_n_plus_one);
    try std.testing.expect(std.mem.indexOf(u8, stdout_n_plus_one, "--- stdout ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_n_plus_one, "--- stderr ---") == null);

    const stderr_n_plus_one = try runShell(ctx, null,
        \\{"command":"printf 123456789 >&2"}
    );
    defer gpa.free(stderr_n_plus_one);
    try std.testing.expectEqualStrings(capture_limit_header, stderr_n_plus_one);
    try std.testing.expect(std.mem.indexOf(u8, stderr_n_plus_one, "--- stdout ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_n_plus_one, "--- stderr ---") == null);
}

test "shell-v1 maximum formatter is checked before allocation and stays under 64 KiB" {
    const gpa = std.testing.allocator;
    var stdout: [max_shell_stream_bytes]u8 = undefined;
    var stderr: [max_shell_stream_bytes]u8 = undefined;
    @memset(&stdout, 'O');
    @memset(&stderr, 'E');

    const body = try formatShellResult(gpa, .{ .exited = 0 }, &stdout, &stderr);
    defer gpa.free(body);
    const envelope_len = body.len - stdout.len - stderr.len;
    try std.testing.expect(envelope_len <= max_shell_envelope_bytes);
    try std.testing.expect(body.len <= tool.max_result_bytes);
    try std.testing.expectEqualStrings(
        "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=30720 stderr_bytes=30720 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false",
        firstLine(body),
    );
    try std.testing.expect(std.mem.indexOf(u8, body, stdout_section) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, stderr_section) != null);

    try std.testing.expectError(
        error.ShellEnvelopeTooLong,
        checkedShellBodyLayout(std.math.maxInt(usize), 0, 0, false, false),
    );
    try std.testing.expectError(
        error.ShellBodyTooLong,
        checkedShellBodyLayout(1, std.math.maxInt(usize), 1, false, false),
    );
    try std.testing.expectError(
        error.ShellBodyTooLong,
        checkedShellBodyLayout(1, tool.max_result_bytes, 0, false, false),
    );
}

test "shell-v1 longest realizable header remains complete in parsed capped trace" {
    const gpa = std.testing.allocator;
    var stdout: [max_shell_stream_bytes]u8 = undefined;
    var stderr: [max_shell_stream_bytes]u8 = undefined;
    @memset(&stdout, 0xff);
    @memset(&stderr, 0xfe);

    // Two maximum invalid streams realize the body_encoding-limit header. It
    // is longer than the maximum term and production capture-limit variants.
    const header = try formatShellResult(gpa, .{ .exited = 0 }, &stdout, &stderr);
    defer gpa.free(header);
    const stdout_rep = try classifyShellStream(&stdout);
    const stderr_rep = try classifyShellStream(&stderr);
    var term_buf: [trace.cap_tool_result_body]u8 = undefined;
    const term_header = try formatShellTermHeader(
        &term_buf,
        .{ .unknown = std.math.maxInt(u32) },
        stdout_rep,
        stderr_rep,
    );
    const capture_header = try shellRunError(gpa, .{}, error.StreamTooLong);
    defer gpa.free(capture_header);
    try std.testing.expect(header.len > term_header.len);
    try std.testing.expect(header.len > capture_header.len);
    try std.testing.expect(header.len <= trace.cap_tool_result_body);
    try std.testing.expectEqualStrings(header, firstLine(header));

    const full_len = header.len + 1 + trace.cap_tool_result_body;
    const full = try gpa.alloc(u8, full_len);
    defer gpa.free(full);
    @memcpy(full[0..header.len], header);
    full[header.len] = '\n';
    @memset(full[header.len + 1 ..], 'x');

    var tr = trace.Trace.init(gpa, std.testing.io, null, Io.Dir.cwd());
    defer tr.deinit();
    try tr.emitRunStart(.{ .version = "test", .permission = "yolo", .shell_policy = "protect" });
    try tr.emitToolResult("run_shell", full);
    try tr.emitRunEnd(.{ .turns = 1, .ok = true, .stop_reason = "completed" });

    var tool_result_count: u32 = 0;
    var lines = std.mem.splitScalar(u8, tr.buf.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestUnexpectedResult;
        const kind_value = parsed.value.object.get("kind") orelse return error.TestUnexpectedResult;
        if (kind_value != .string) return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, kind_value.string, "tool_result")) continue;
        tool_result_count += 1;
        const body_value = parsed.value.object.get("body") orelse return error.TestUnexpectedResult;
        if (body_value != .string) return error.TestUnexpectedResult;
        try std.testing.expect(body_value.string.len <= trace.cap_tool_result_body);
        try std.testing.expectEqualStrings(header, firstLine(body_value.string));
    }
    try std.testing.expectEqual(@as(u32, 1), tool_result_count);
}

test "shell-v1 OOM is hard typed for run error and formatter" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, shellRunError(gpa, .{}, error.OutOfMemory));

    var failing_format = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        formatShellResult(failing_format.allocator(), .{ .exited = 0 }, "", ""),
    );
    try std.testing.expect(failing_format.has_induced_failure);

    var failing_header = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        shellRunError(failing_header.allocator(), .{}, error.Timeout),
    );
    try std.testing.expect(failing_header.has_induced_failure);

    var invalid_stdout: [max_shell_stream_bytes]u8 = undefined;
    var invalid_stderr: [max_shell_stream_bytes]u8 = undefined;
    @memset(&invalid_stdout, 0xff);
    @memset(&invalid_stderr, 0xfe);
    var failing_encoding_limit = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        formatShellResult(
            failing_encoding_limit.allocator(),
            .{ .exited = 0 },
            &invalid_stdout,
            &invalid_stderr,
        ),
    );
    try std.testing.expect(failing_encoding_limit.has_induced_failure);
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
