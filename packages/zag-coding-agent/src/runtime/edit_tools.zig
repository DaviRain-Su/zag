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

const TestEditFault = enum {
    none,
    parent_create,
    temp_create,
    write_after_prefix,
    flush,
    containment,
    replace,
    post_commit_enrichment,
};

var test_shell_config: if (builtin.is_test) ShellConfig else void =
    if (builtin.is_test) .{} else {};
var test_edit_fault: if (builtin.is_test) TestEditFault else void =
    if (builtin.is_test) .none else {};
var test_fail_temp_cleanup_delete: if (builtin.is_test) bool else void =
    if (builtin.is_test) false else {};
var test_replace_observed_closed: if (builtin.is_test) bool else void =
    if (builtin.is_test) false else {};

fn activeShellConfig() ShellConfig {
    if (builtin.is_test) return test_shell_config;
    return .{};
}

fn takeEditFault(comptime expected: TestEditFault) bool {
    if (!builtin.is_test) return false;
    if (test_edit_fault != expected) return false;
    test_edit_fault = .none;
    return true;
}

fn takeTempCleanupDeleteFault() bool {
    if (!builtin.is_test) return false;
    if (!test_fail_temp_cleanup_delete) return false;
    test_fail_temp_cleanup_delete = false;
    return true;
}

/// Test-only seams. The empty production namespace exposes no controls.
/// Edit faults are one-shot and are consumed inside the production commit path.
pub const testing = if (builtin.is_test) struct {
    pub const EditFault = TestEditFault;

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

    pub fn failNextEditAt(fault: EditFault) void {
        std.debug.assert(fault != .none);
        if (fault == .replace) test_replace_observed_closed = false;
        test_edit_fault = fault;
    }

    pub fn failNextTempCleanupDelete() void {
        test_fail_temp_cleanup_delete = true;
    }

    pub fn replaceFaultObservedClosed() bool {
        return test_replace_observed_closed;
    }

    pub fn reset() void {
        test_shell_config = .{};
        test_edit_fault = .none;
        test_fail_temp_cleanup_delete = false;
        test_replace_observed_closed = false;
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

    workspace.checkToolPath(path) catch |err| return lexicalJail(ctx, path, err);
    try validateFileEndpointShape(path);

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    // Existing target (or contained final symlink) must resolve inside root.
    guard.checkExisting(ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };
    validateMutationEndpoint(ctx, guard, path, false) catch |err| {
        return mutationEndpointFailure(ctx, path, err);
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

    // Allocate the mandatory success body before the commit boundary. Once the
    // atomic replacement succeeds, only best-effort non-failing enrichment runs.
    const base = try softError(
        ctx.allocator,
        "ok: search_replace path={s} removed={d} inserted={d} bytes file_size={d}",
        .{ path, old_string.len, new_string.len, replaced.len },
    );
    errdefer ctx.allocator.free(base);

    if (try atomicCommit(ctx, guard, .search_replace, path, replaced)) |failure_body| {
        ctx.allocator.free(base);
        return failure_body;
    }
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

    workspace.checkToolPath(path) catch |err| return lexicalJail(ctx, path, err);
    try validateFileEndpointShape(path);

    var guard = obtainGuard(ctx) catch |err| return jailOrFail(ctx, path, err);
    defer guard.deinit(ctx.allocator);

    // Ancestor walk before any create: escaping/dangling parents denied.
    guard.checkCreate(ctx.allocator, ctx.io, ctx.cwd, path) catch |err| {
        return jailOrFail(ctx, path, err);
    };
    validateMutationEndpoint(ctx, guard, path, true) catch |err| {
        return mutationEndpointFailure(ctx, path, err);
    };

    // Allocate the mandatory success body before parent creation or commit.
    // A completed replacement can therefore never surface as post-commit OOM.
    const base = try softError(
        ctx.allocator,
        "ok: wrote {d} bytes to {s}",
        .{ content.len, path },
    );
    errdefer ctx.allocator.free(base);

    if (try atomicCommit(ctx, guard, .write_file, path, content)) |failure_body| {
        ctx.allocator.free(base);
        return failure_body;
    }
    return maybeAppendGitDiff(ctx, path, base);
}

const EditOperation = enum {
    write_file,
    search_replace,

    fn name(self: EditOperation) []const u8 {
        return @tagName(self);
    }
};

const EditStage = enum {
    parent_create,
    temp_create,
    write,
    flush,
    replace,
    temp_cleanup,

    fn name(self: EditStage) []const u8 {
        return @tagName(self);
    }
};

const ParentDirs = enum {
    unchanged,
    may_remain,

    fn name(self: ParentDirs) []const u8 {
        return @tagName(self);
    }
};

const TempArtifact = enum {
    absent,
    may_remain,

    fn name(self: TempArtifact) []const u8 {
        return @tagName(self);
    }
};

const MutationEndpointError = workspace.ContainError || error{InvalidFileEndpoint};

fn isHostPathSeparator(byte: u8) bool {
    return if (builtin.os.tag == .windows)
        byte == '/' or byte == '\\'
    else
        byte == '/';
}

fn validateFileEndpointShape(path: []const u8) error{InvalidArguments}!void {
    std.debug.assert(path.len > 0);
    if (isHostPathSeparator(path[path.len - 1])) return error.InvalidArguments;

    var final_start = path.len;
    while (final_start > 0 and !isHostPathSeparator(path[final_start - 1])) {
        final_start -= 1;
    }
    const final_component = path[final_start..];
    if (std.mem.eql(u8, final_component, ".") or
        std.mem.eql(u8, final_component, ".."))
    {
        return error.InvalidArguments;
    }
}

fn validateMutationEndpoint(
    ctx: tool.Context,
    guard: workspace.Guard,
    request_path: []const u8,
    allow_missing: bool,
) MutationEndpointError!void {
    const selected = guard.resolveContained(ctx.allocator, ctx.io, ctx.cwd, request_path) catch |err| switch (err) {
        error.NotFound => if (allow_missing) return else return error.NotFound,
        else => return err,
    };
    defer ctx.allocator.free(selected);

    if (!guard.root.contains(selected)) return error.OutsideWorkspace;
    if (std.mem.eql(u8, selected, guard.root.path)) return error.InvalidFileEndpoint;

    const stat = ctx.cwd.statFile(ctx.io, selected, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound => if (allow_missing) return else return error.NotFound,
        else => return error.ResolveFailed,
    };
    if (stat.kind != .file) return error.InvalidFileEndpoint;
}

fn mutationEndpointFailure(
    ctx: tool.Context,
    path: []const u8,
    err: MutationEndpointError,
) tool.HandlerError![]u8 {
    return switch (err) {
        error.InvalidFileEndpoint => error.InvalidArguments,
        error.OutsideWorkspace => jailOrFail(ctx, path, error.OutsideWorkspace),
        error.InvalidPath => jailOrFail(ctx, path, error.InvalidPath),
        error.NotFound => jailOrFail(ctx, path, error.NotFound),
        error.ResolveFailed => jailOrFail(ctx, path, error.ResolveFailed),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn lexicalJail(
    ctx: tool.Context,
    path: []const u8,
    err: workspace.Error,
) tool.HandlerError![]u8 {
    return switch (err) {
        error.OutsideWorkspace => jailOrFail(ctx, path, error.OutsideWorkspace),
        error.InvalidPath => jailOrFail(ctx, path, error.InvalidPath),
    };
}

/// Publish one complete edit with Zig 0.16 `Io.File.Atomic`.
///
/// The selected destination is canonicalized first so a contained final file
/// symlink commits to its real target rather than renaming over the symlink.
/// Opening that target's canonical parent and passing only its basename to
/// `createFileAtomic` keeps staging and replacement on the same parent
/// filesystem. Failures explicitly close/delete/check the temporary because
/// Zig 0.16 `Atomic.deinit` swallows deletion errors. `flush` is the buffered
/// Zig writer flush, not file/dir fsync.
const AtomicPrimaryFailure = union(enum) {
    write,
    flush,
    containment: workspace.ContainError,
    replace,

    fn name(self: AtomicPrimaryFailure) []const u8 {
        return @tagName(self);
    }
};

/// Owned failure bodies prepared before the selected parent is opened.
///
/// Once a temporary exists, cleanup outcome classification only takes one of
/// these slices and nulls its slot. `deinit` frees every unselected body once;
/// the caller owns the selected slice. No result allocation follows staging.
const PreparedAtomicFailureBodies = struct {
    allocator: std.mem.Allocator,
    temp_create: ?[]u8 = null,
    write: ?[]u8 = null,
    flush: ?[]u8 = null,
    containment: ?[]u8 = null,
    replace: ?[]u8 = null,
    cleanup_write: ?[]u8 = null,
    cleanup_flush: ?[]u8 = null,
    cleanup_containment: ?[]u8 = null,
    cleanup_replace: ?[]u8 = null,

    fn init(
        ctx: tool.Context,
        operation: EditOperation,
        request_path: []const u8,
        parent_dirs: ParentDirs,
    ) tool.HandlerError!PreparedAtomicFailureBodies {
        var prepared: PreparedAtomicFailureBodies = .{ .allocator = ctx.allocator };
        errdefer prepared.deinit();

        prepared.temp_create = try editIoFailure(
            ctx.allocator,
            operation,
            .temp_create,
            parent_dirs,
            .absent,
        );
        prepared.write = try editIoFailure(ctx.allocator, operation, .write, parent_dirs, .absent);
        prepared.flush = try editIoFailure(ctx.allocator, operation, .flush, parent_dirs, .absent);
        prepared.replace = try editIoFailure(ctx.allocator, operation, .replace, parent_dirs, .absent);

        // Every non-OOM containment failure has the same stable jail body.
        // Guard OOM remains typed if cleanup succeeds.
        prepared.containment = try finalContainmentFailure(
            ctx,
            request_path,
            parent_dirs,
            .absent,
            error.OutsideWorkspace,
        );

        prepared.cleanup_write = try tempCleanupFailure(
            ctx.allocator,
            operation,
            .write,
            parent_dirs,
        );
        prepared.cleanup_flush = try tempCleanupFailure(
            ctx.allocator,
            operation,
            .flush,
            parent_dirs,
        );
        prepared.cleanup_containment = try tempCleanupFailure(
            ctx.allocator,
            operation,
            .{ .containment = error.OutsideWorkspace },
            parent_dirs,
        );
        prepared.cleanup_replace = try tempCleanupFailure(
            ctx.allocator,
            operation,
            .replace,
            parent_dirs,
        );
        return prepared;
    }

    fn deinit(self: *PreparedAtomicFailureBodies) void {
        self.freeSlot(&self.temp_create);
        self.freeSlot(&self.write);
        self.freeSlot(&self.flush);
        self.freeSlot(&self.containment);
        self.freeSlot(&self.replace);
        self.freeSlot(&self.cleanup_write);
        self.freeSlot(&self.cleanup_flush);
        self.freeSlot(&self.cleanup_containment);
        self.freeSlot(&self.cleanup_replace);
    }

    fn takeTempCreate(self: *PreparedAtomicFailureBodies) []u8 {
        return takeSlot(&self.temp_create);
    }

    fn takeAfterCleanup(
        self: *PreparedAtomicFailureBodies,
        primary: AtomicPrimaryFailure,
        temp_artifact: TempArtifact,
    ) tool.HandlerError![]u8 {
        if (temp_artifact == .may_remain) {
            return switch (primary) {
                .write => takeSlot(&self.cleanup_write),
                .flush => takeSlot(&self.cleanup_flush),
                .containment => takeSlot(&self.cleanup_containment),
                .replace => takeSlot(&self.cleanup_replace),
            };
        }

        return switch (primary) {
            .write => takeSlot(&self.write),
            .flush => takeSlot(&self.flush),
            .containment => |err| if (err == error.OutOfMemory)
                error.OutOfMemory
            else
                takeSlot(&self.containment),
            .replace => takeSlot(&self.replace),
        };
    }

    fn freeSlot(self: *PreparedAtomicFailureBodies, slot: *?[]u8) void {
        if (slot.*) |body| self.allocator.free(body);
        slot.* = null;
    }

    fn takeSlot(slot: *?[]u8) []u8 {
        std.debug.assert(slot.* != null);
        const body = slot.*.?;
        slot.* = null;
        return body;
    }
};

fn atomicCommit(
    ctx: tool.Context,
    guard: workspace.Guard,
    operation: EditOperation,
    request_path: []const u8,
    complete_bytes: []const u8,
) tool.HandlerError!?[]u8 {
    var parent_dirs: ParentDirs = .unchanged;
    if (operation == .write_file) {
        ensureParentDirs(ctx, request_path, &parent_dirs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try editIoFailure(ctx.allocator, operation, .parent_create, parent_dirs, .absent),
        };
        if (takeEditFault(.parent_create)) {
            return try editIoFailure(ctx.allocator, operation, .parent_create, parent_dirs, .absent);
        }
    }

    const selected_path = selectCommitPath(ctx, guard, operation, request_path) catch |err| {
        return try finalContainmentFailure(ctx, request_path, parent_dirs, .absent, err);
    };
    defer ctx.allocator.free(selected_path);

    const parent_path = std.fs.path.dirname(selected_path) orelse {
        return try editIoFailure(ctx.allocator, operation, .temp_create, parent_dirs, .absent);
    };
    const target_basename = std.fs.path.basename(selected_path);
    if (target_basename.len == 0) {
        return try editIoFailure(ctx.allocator, operation, .temp_create, parent_dirs, .absent);
    }

    // Prepare every stable body before opening the selected parent. From this
    // point through cleanup and result selection, only a Guard OOM may remain
    // typed; no result allocation can hide a staged temporary or target state.
    var prepared = try PreparedAtomicFailureBodies.init(
        ctx,
        operation,
        request_path,
        parent_dirs,
    );
    defer prepared.deinit();

    return stageAtomicCommit(
        ctx,
        guard,
        operation,
        request_path,
        complete_bytes,
        parent_path,
        target_basename,
        &prepared,
    );
}

fn stageAtomicCommit(
    ctx: tool.Context,
    guard: workspace.Guard,
    operation: EditOperation,
    request_path: []const u8,
    complete_bytes: []const u8,
    parent_path: []const u8,
    target_basename: []const u8,
    prepared: *PreparedAtomicFailureBodies,
) tool.HandlerError!?[]u8 {
    var target_parent = Io.Dir.openDirAbsolute(ctx.io, parent_path, .{}) catch {
        return prepared.takeTempCreate();
    };
    defer target_parent.close(ctx.io);

    if (takeEditFault(.temp_create)) return prepared.takeTempCreate();

    var atomic_file = target_parent.createFileAtomic(ctx.io, target_basename, .{
        .replace = true,
    }) catch {
        return prepared.takeTempCreate();
    };
    var atomic_needs_deinit = true;
    defer if (atomic_needs_deinit) atomic_file.deinit(ctx.io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(ctx.io, &write_buffer);
    writeCompleteForCommit(&file_writer, complete_bytes) catch {
        return try finishAtomicFailure(
            ctx.io,
            &atomic_file,
            &atomic_needs_deinit,
            prepared,
            .write,
        );
    };
    flushCompleteForCommit(&file_writer) catch {
        return try finishAtomicFailure(
            ctx.io,
            &atomic_file,
            &atomic_needs_deinit,
            prepared,
            .flush,
        );
    };

    recheckForCommit(ctx, guard, operation, request_path) catch |err| {
        return try finishAtomicFailure(
            ctx.io,
            &atomic_file,
            &atomic_needs_deinit,
            prepared,
            .{ .containment = err },
        );
    };

    replaceForCommit(&atomic_file, ctx.io) catch {
        return try finishAtomicFailure(
            ctx.io,
            &atomic_file,
            &atomic_needs_deinit,
            prepared,
            .replace,
        );
    };
    return null;
}

fn finishAtomicFailure(
    io: Io,
    atomic_file: *Io.File.Atomic,
    atomic_needs_deinit: *bool,
    prepared: *PreparedAtomicFailureBodies,
    primary: AtomicPrimaryFailure,
) tool.HandlerError![]u8 {
    std.debug.assert(atomic_needs_deinit.*);
    const temp_artifact = cleanupTemporary(atomic_file, io);
    atomic_needs_deinit.* = false;
    return prepared.takeAfterCleanup(primary, temp_artifact);
}

fn cleanupTemporary(atomic_file: *Io.File.Atomic, io: Io) TempArtifact {
    std.debug.assert(atomic_file.file_exists);
    std.debug.assert(!atomic_file.close_dir_on_deinit);
    if (atomic_file.file_open) {
        atomic_file.file.close(io);
        atomic_file.file_open = false;
    }

    const temp_sub_path = std.fmt.hex(atomic_file.file_basename_hex);
    const delete_failed = takeTempCleanupDeleteFault() or delete_failed: {
        atomic_file.dir.deleteFile(io, &temp_sub_path) catch |err| switch (err) {
            error.FileNotFound => break :delete_failed false,
            else => break :delete_failed true,
        };
        break :delete_failed false;
    };

    const outcome: TempArtifact = if (!delete_failed)
        .absent
    else verify: {
        _ = atomic_file.dir.statFile(io, &temp_sub_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break :verify .absent,
            else => break :verify .may_remain,
        };
        break :verify .may_remain;
    };

    // Disarm Zig 0.16 Atomic.deinit: it would otherwise retry deletion while
    // swallowing the outcome, making `temp_artifact=may_remain` unobservable.
    atomic_file.file_exists = false;
    return outcome;
}

fn selectCommitPath(
    ctx: tool.Context,
    guard: workspace.Guard,
    operation: EditOperation,
    request_path: []const u8,
) workspace.ContainError![]u8 {
    if (guard.resolveContained(ctx.allocator, ctx.io, ctx.cwd, request_path)) |existing| {
        errdefer ctx.allocator.free(existing);
        try validateSelectedCommitPath(ctx, guard, operation, existing);
        return existing;
    } else |err| switch (err) {
        error.NotFound => {
            if (operation == .search_replace) return error.NotFound;
        },
        else => return err,
    }

    // `write_file` absent target: parents now exist and are contained. Join the
    // lexical final basename beneath the canonical parent selected by Guard.
    const parent_rel = std.fs.path.dirname(request_path) orelse ".";
    const parent_real = try guard.resolveContained(ctx.allocator, ctx.io, ctx.cwd, parent_rel);
    defer ctx.allocator.free(parent_real);
    const basename = std.fs.path.basename(request_path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
        return error.InvalidPath;
    const selected = std.fs.path.join(ctx.allocator, &.{ parent_real, basename }) catch
        return error.OutOfMemory;
    errdefer ctx.allocator.free(selected);
    try validateSelectedCommitPath(ctx, guard, operation, selected);
    return selected;
}

fn validateSelectedCommitPath(
    ctx: tool.Context,
    guard: workspace.Guard,
    operation: EditOperation,
    selected_path: []const u8,
) workspace.ContainError!void {
    if (!guard.root.contains(selected_path)) return error.OutsideWorkspace;
    if (std.mem.eql(u8, selected_path, guard.root.path)) return error.InvalidPath;

    const parent_path = std.fs.path.dirname(selected_path) orelse return error.InvalidPath;
    if (!guard.root.contains(parent_path)) return error.OutsideWorkspace;

    const stat = ctx.cwd.statFile(ctx.io, selected_path, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound => if (operation == .write_file) return else return error.NotFound,
        else => return error.ResolveFailed,
    };
    if (stat.kind != .file) return error.InvalidPath;
}

fn writeCompleteForCommit(file_writer: *Io.File.Writer, complete_bytes: []const u8) !void {
    if (takeEditFault(.write_after_prefix)) {
        const prefix_len = @min(complete_bytes.len, 3);
        std.debug.assert(prefix_len > 0);
        try file_writer.interface.writeAll(complete_bytes[0..prefix_len]);
        // Force the nonzero prefix into the temporary before injecting the
        // later write failure; cleanup must remove this genuinely partial temp.
        try file_writer.flush();
        return error.InjectedEditWriteFailure;
    }
    try file_writer.interface.writeAll(complete_bytes);
}

fn flushCompleteForCommit(file_writer: *Io.File.Writer) !void {
    if (takeEditFault(.flush)) {
        // Drain the complete buffered bytes, then inject the flush outcome so
        // the fixture proves cleanup of a fully staged, uncommitted temporary.
        try file_writer.flush();
        return error.InjectedEditFlushFailure;
    }
    try file_writer.flush();
}

fn recheckForCommit(
    ctx: tool.Context,
    guard: workspace.Guard,
    operation: EditOperation,
    request_path: []const u8,
) workspace.ContainError!void {
    switch (operation) {
        .write_file => try guard.checkCreate(ctx.allocator, ctx.io, ctx.cwd, request_path),
        .search_replace => try guard.checkExisting(ctx.io, ctx.cwd, request_path),
    }
    if (takeEditFault(.containment)) return error.OutsideWorkspace;
}

fn replaceForCommit(atomic_file: *Io.File.Atomic, io: Io) !void {
    std.debug.assert(atomic_file.file_exists);
    if (atomic_file.file_open) {
        atomic_file.file.close(io);
        atomic_file.file_open = false;
    }
    if (takeEditFault(.replace)) {
        if (builtin.is_test) test_replace_observed_closed = !atomic_file.file_open;
        return error.InjectedEditReplaceFailure;
    }
    // Zig 0.16 Atomic.replace now enters directly at its rename boundary.
    try atomic_file.replace(io);
}

fn editIoFailure(
    gpa: std.mem.Allocator,
    operation: EditOperation,
    stage: EditStage,
    parent_dirs: ParentDirs,
    temp_artifact: TempArtifact,
) tool.HandlerError![]u8 {
    std.debug.assert(stage != .temp_cleanup);
    var line_buf: [trace.cap_tool_result_body]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "error: code=edit_io_failed format=edit-v1 operation={s} stage={s} target=preserved parent_dirs={s} temp_artifact={s}",
        .{ operation.name(), stage.name(), parent_dirs.name(), temp_artifact.name() },
    ) catch return error.ToolFailed;
    std.debug.assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    return gpa.dupe(u8, line) catch return error.OutOfMemory;
}

fn tempCleanupFailure(
    gpa: std.mem.Allocator,
    operation: EditOperation,
    primary: AtomicPrimaryFailure,
    parent_dirs: ParentDirs,
) tool.HandlerError![]u8 {
    var line_buf: [trace.cap_tool_result_body]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "error: code=edit_io_failed format=edit-v1 operation={s} stage=temp_cleanup primary_stage={s} target=preserved parent_dirs={s} temp_artifact=may_remain",
        .{ operation.name(), primary.name(), parent_dirs.name() },
    ) catch return error.ToolFailed;
    std.debug.assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    return gpa.dupe(u8, line) catch return error.OutOfMemory;
}

fn finalContainmentFailure(
    ctx: tool.Context,
    path: []const u8,
    parent_dirs: ParentDirs,
    temp_artifact: TempArtifact,
    err: workspace.ContainError,
) tool.HandlerError![]u8 {
    std.debug.assert(temp_artifact == .absent);
    // At the final security-critical boundary, disappearance is unresolved
    // containment rather than an ordinary pre-edit missing-file result.
    const deny_err: workspace.ContainError = if (err == error.NotFound)
        error.ResolveFailed
    else
        err;
    const base = try jailOrFail(ctx, path, deny_err);
    defer ctx.allocator.free(base);

    const jail_prefix = "error: code=jail_deny ";
    if (!std.mem.startsWith(u8, base, jail_prefix)) return error.ToolFailed;
    const parent_field = if (parent_dirs == .may_remain)
        "parent_dirs=may_remain "
    else
        "";
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}{s}temp_artifact=absent {s}",
        .{ jail_prefix, parent_field, base[jail_prefix.len..] },
    ) catch return error.OutOfMemory;
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
/// `parent_dirs` becomes `may_remain` immediately before the one create call;
/// rollback is intentionally forbidden because unrelated workspace activity
/// may already depend on directories that appeared.
fn ensureParentDirs(
    ctx: tool.Context,
    file_path: []const u8,
    parent_dirs: *ParentDirs,
) !void {
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
        parent_dirs.* = .may_remain;
        try base.createDirPath(ctx.io, rel_create);
    } else {
        parent_dirs.* = .may_remain;
        try ctx.cwd.createDirPath(ctx.io, rel_create);
    }
}

fn maybeAppendGitDiff(ctx: tool.Context, path: []const u8, base: []u8) []u8 {
    // Best-effort enrichment: the edit already succeeded. This function is
    // deliberately non-failing; allocation/process errors retain `base`.
    if (takeEditFault(.post_commit_enrichment)) return base;
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
    var parent_dirs: ParentDirs = .unchanged;
    try std.testing.expectError(
        error.OutOfMemory,
        ensureParentDirs(ctx, "a/b/c/file.txt", &parent_dirs),
    );
    try std.testing.expect(parent_dirs == .unchanged);

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

const edit_commit_faults = [_]TestEditFault{
    .temp_create,
    .write_after_prefix,
    .flush,
    .containment,
    .replace,
};

fn invokeEditFixture(
    ctx: tool.Context,
    operation: EditOperation,
    path: []const u8,
) tool.HandlerError![]u8 {
    const arguments = switch (operation) {
        .write_file => std.fmt.allocPrint(
            ctx.allocator,
            "{{\"path\":{f},\"content\":\"complete replacement bytes\\n\"}}",
            .{std.json.fmt(path, .{})},
        ) catch return error.OutOfMemory,
        .search_replace => std.fmt.allocPrint(
            ctx.allocator,
            "{{\"path\":{f},\"old_string\":\"OLD\",\"new_string\":\"NEW\"}}",
            .{std.json.fmt(path, .{})},
        ) catch return error.OutOfMemory,
    };
    defer ctx.allocator.free(arguments);
    return switch (operation) {
        .write_file => writeFile(ctx, null, arguments),
        .search_replace => searchReplace(ctx, null, arguments),
    };
}

fn expectEditFaultBody(
    body: []const u8,
    operation: EditOperation,
    fault: TestEditFault,
    parent_dirs: ParentDirs,
) !void {
    try std.testing.expect(body.len <= trace.cap_tool_result_body);
    try std.testing.expect(std.mem.indexOf(u8, body, "InjectedEdit") == null);
    if (fault == .replace) try std.testing.expect(testing.replaceFaultObservedClosed());
    if (fault == .containment) {
        try std.testing.expect(std.mem.startsWith(u8, body, "error: code=jail_deny "));
        try std.testing.expect(std.mem.indexOf(u8, body, "edit_io_failed") == null);
        if (parent_dirs == .may_remain) {
            try std.testing.expect(std.mem.indexOf(u8, body, "parent_dirs=may_remain") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, body, "parent_dirs=") == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, body, "temp_artifact=absent") != null);
        return;
    }

    const stage: EditStage = switch (fault) {
        .parent_create => .parent_create,
        .temp_create => .temp_create,
        .write_after_prefix => .write,
        .flush => .flush,
        .replace => .replace,
        else => return error.TestUnexpectedResult,
    };
    var expected_buf: [trace.cap_tool_result_body]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "error: code=edit_io_failed format=edit-v1 operation={s} stage={s} target=preserved parent_dirs={s} temp_artifact=absent",
        .{ operation.name(), stage.name(), parent_dirs.name() },
    );
    try std.testing.expectEqualStrings(expected, body);
    try std.testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
}

fn expectFileBytes(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    expected: []const u8,
) !void {
    const actual = try dir.readFileAlloc(io, path, gpa, .limited(expected.len + 1));
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPathAbsentIn(dir: Io.Dir, io: Io, path: []const u8) !void {
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.TestUnexpectedResult;
}

fn expectDirEntries(
    io: Io,
    dir: Io.Dir,
    expected_names: []const []const u8,
) !void {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        count += 1;
        var found = false;
        for (expected_names) |expected| {
            if (std.mem.eql(u8, entry.name, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(expected_names.len, count);
}

fn expectSymlink(
    dir: Io.Dir,
    io: Io,
    path: []const u8,
    expected_text: []const u8,
) !void {
    const st = try dir.statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expect(st.kind == .sym_link);
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const link_len = try dir.readLink(io, path, &link_buf);
    try std.testing.expectEqualStrings(expected_text, link_buf[0..link_len]);
}

fn executePublicEdit(
    ctx: tool.Context,
    operation: EditOperation,
    arguments: []const u8,
) std.mem.Allocator.Error![]u8 {
    var tools = phase1ExtraTools();
    const fixture_toolset: tool.Toolset = .{ .tools = &tools };
    const registry = fixture_toolset.registry();
    return registry.execute(ctx, operation.name(), arguments);
}

fn expectInvalidEndpointBody(body: []const u8) !void {
    try std.testing.expect(core.tool_error.hasCode(body, .invalid_arguments));
    try std.testing.expect(std.mem.indexOf(u8, body, "edit_io_failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "temp_artifact") == null);
}

fn expectEndpointWorkspaceState(
    gpa: std.mem.Allocator,
    io: Io,
    parent: Io.Dir,
    ws: Io.Dir,
    expected_ws_entries: []const []const u8,
) !void {
    try expectDirEntries(io, parent, &.{ "outside", "ws" });
    try expectDirEntries(io, ws, expected_ws_entries);

    var outside = try parent.openDir(io, "outside", .{ .iterate = true });
    defer outside.close(io);
    try expectDirEntries(io, outside, &.{"sentinel.txt"});
    try expectFileBytes(gpa, io, outside, "sentinel.txt", "OUTSIDE_SENTINEL\n");
}

test "edit endpoints reject final dot trailing separator and root resolution before staging" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/sentinel.txt", .data = "OUTSIDE_SENTINEL\n" });
    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    try expectPathAbsentIn(ws, io, "new-dir");
    try expectPathAbsentIn(ws, io, "new-dir/.");
    const final_dot = try executePublicEdit(
        ctx,
        .write_file,
        "{\"path\":\"new-dir/.\",\"content\":\"NEW_BYTES\\n\"}",
    );
    defer gpa.free(final_dot);
    try expectInvalidEndpointBody(final_dot);
    try expectPathAbsentIn(ws, io, "new-dir");
    try expectPathAbsentIn(ws, io, "new-dir/.");
    try expectEndpointWorkspaceState(gpa, io, parent.dir, ws, &.{});

    try expectPathAbsentIn(ws, io, "alias.txt");
    try expectPathAbsentIn(ws, io, "alias.txt/");
    const trailing = try executePublicEdit(
        ctx,
        .write_file,
        "{\"path\":\"alias.txt/\",\"content\":\"NEW_BYTES\\n\"}",
    );
    defer gpa.free(trailing);
    try expectInvalidEndpointBody(trailing);
    try expectPathAbsentIn(ws, io, "alias.txt");
    try expectPathAbsentIn(ws, io, "alias.txt/");
    try expectEndpointWorkspaceState(gpa, io, parent.dir, ws, &.{});

    const root_before = try parent.dir.statFile(io, "ws", .{ .follow_symlinks = false });
    try std.testing.expect(root_before.kind == .directory);
    for ([_]struct { path: []const u8, arguments: []const u8 }{
        .{ .path = ".", .arguments = "{\"path\":\".\",\"content\":\"NEW_BYTES\\n\"}" },
        .{ .path = "./", .arguments = "{\"path\":\"./\",\"content\":\"NEW_BYTES\\n\"}" },
    }) |case| {
        const requested_before = try ws.statFile(io, case.path, .{ .follow_symlinks = false });
        try std.testing.expect(requested_before.kind == .directory);
        const body = try executePublicEdit(ctx, .write_file, case.arguments);
        defer gpa.free(body);
        try expectInvalidEndpointBody(body);
        const requested_after = try ws.statFile(io, case.path, .{ .follow_symlinks = false });
        try std.testing.expect(requested_after.kind == .directory);
        const root_after = try parent.dir.statFile(io, "ws", .{ .follow_symlinks = false });
        try std.testing.expect(root_after.kind == .directory);
        try expectEndpointWorkspaceState(gpa, io, parent.dir, ws, &.{});
    }

    try ws.createDirPath(io, "sub");
    const sub_before = try ws.statFile(io, "sub", .{ .follow_symlinks = false });
    try std.testing.expect(sub_before.kind == .directory);
    const parent_alias_before = try ws.statFile(io, "sub/..", .{ .follow_symlinks = false });
    try std.testing.expect(parent_alias_before.kind == .directory);
    const parent_alias = try executePublicEdit(
        ctx,
        .write_file,
        "{\"path\":\"sub/..\",\"content\":\"NEW_BYTES\\n\"}",
    );
    defer gpa.free(parent_alias);
    try expectInvalidEndpointBody(parent_alias);
    const sub_after = try ws.statFile(io, "sub", .{ .follow_symlinks = false });
    try std.testing.expect(sub_after.kind == .directory);
    const parent_alias_after = try ws.statFile(io, "sub/..", .{ .follow_symlinks = false });
    try std.testing.expect(parent_alias_after.kind == .directory);
    var sub = try ws.openDir(io, "sub", .{ .iterate = true });
    defer sub.close(io);
    try expectDirEntries(io, sub, &.{});
    try expectEndpointWorkspaceState(gpa, io, parent.dir, ws, &.{"sub"});
}

test "edit endpoints reject contained directory and root aliases for both handlers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/subdir");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/sentinel.txt", .data = "OUTSIDE_SENTINEL\n" });
    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);
    try ws.symLink(io, "subdir", "dir_alias", .{ .is_directory = true });
    try ws.symLink(io, ".", "root_alias", .{ .is_directory = true });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    const endpoints = [_][]const u8{ "subdir", "dir_alias", "root_alias", ".", "./" };
    for ([_]EditOperation{ .write_file, .search_replace }) |operation| {
        for (endpoints) |endpoint| {
            const subdir_before = try ws.statFile(io, "subdir", .{ .follow_symlinks = false });
            try std.testing.expect(subdir_before.kind == .directory);
            try expectSymlink(ws, io, "dir_alias", "subdir");
            try expectSymlink(ws, io, "root_alias", ".");
            var subdir_before_dir = try ws.openDir(io, "subdir", .{ .iterate = true });
            defer subdir_before_dir.close(io);
            try expectDirEntries(io, subdir_before_dir, &.{});
            try expectEndpointWorkspaceState(
                gpa,
                io,
                parent.dir,
                ws,
                &.{ "dir_alias", "root_alias", "subdir" },
            );

            const arguments = switch (operation) {
                .write_file => try std.fmt.allocPrint(
                    gpa,
                    "{{\"path\":{f},\"content\":\"NEW_BYTES\\n\"}}",
                    .{std.json.fmt(endpoint, .{})},
                ),
                .search_replace => try std.fmt.allocPrint(
                    gpa,
                    "{{\"path\":{f},\"old_string\":\"OLD\",\"new_string\":\"NEW\"}}",
                    .{std.json.fmt(endpoint, .{})},
                ),
            };
            defer gpa.free(arguments);
            const body = try executePublicEdit(ctx, operation, arguments);
            defer gpa.free(body);
            try expectInvalidEndpointBody(body);

            const subdir_after = try ws.statFile(io, "subdir", .{ .follow_symlinks = false });
            try std.testing.expect(subdir_after.kind == .directory);
            try expectSymlink(ws, io, "dir_alias", "subdir");
            try expectSymlink(ws, io, "root_alias", ".");
            var subdir_after_dir = try ws.openDir(io, "subdir", .{ .iterate = true });
            defer subdir_after_dir.close(io);
            try expectDirEntries(io, subdir_after_dir, &.{});
            try expectEndpointWorkspaceState(
                gpa,
                io,
                parent.dir,
                ws,
                &.{ "dir_alias", "root_alias", "subdir" },
            );
        }
    }
}

test "edit endpoint preserves contained interior normalization" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/dir");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/sentinel.txt", .data = "OUTSIDE_SENTINEL\n" });
    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = ws };

    const written = try executePublicEdit(
        ctx,
        .write_file,
        "{\"path\":\"dir/../file.txt\",\"content\":\"alpha OLD omega\\n\"}",
    );
    defer gpa.free(written);
    try std.testing.expect(std.mem.startsWith(u8, written, "ok:"));
    try expectFileBytes(gpa, io, ws, "file.txt", "alpha OLD omega\n");

    const replaced = try executePublicEdit(
        ctx,
        .search_replace,
        "{\"path\":\"dir/../file.txt\",\"old_string\":\"OLD\",\"new_string\":\"NEW\"}",
    );
    defer gpa.free(replaced);
    try std.testing.expect(std.mem.startsWith(u8, replaced, "ok:"));
    try expectFileBytes(gpa, io, ws, "file.txt", "alpha NEW omega\n");

    var dir = try ws.openDir(io, "dir", .{ .iterate = true });
    defer dir.close(io);
    try expectDirEntries(io, dir, &.{});
    try expectEndpointWorkspaceState(gpa, io, parent.dir, ws, &.{ "dir", "file.txt" });
}

test "edit-v1 existing ordinary targets preserve exact bytes and clean temps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for ([_]EditOperation{ .write_file, .search_replace }) |operation| {
        for (edit_commit_faults) |fault| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const original = "alpha OLD omega\n";
            try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
            const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

            testing.failNextEditAt(fault);
            const body = try invokeEditFixture(ctx, operation, "target.txt");
            defer gpa.free(body);
            try expectEditFaultBody(body, operation, fault, .unchanged);
            try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
            try expectDirEntries(io, tmp.dir, &.{"target.txt"});
        }
    }
}

test "edit-v1 cleanup deletion failure is truthful observable and safely removable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "alpha OLD omega\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    testing.failNextEditAt(.write_after_prefix);
    testing.failNextTempCleanupDelete();
    const body = try invokeEditFixture(ctx, .write_file, "target.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=edit_io_failed format=edit-v1 operation=write_file stage=temp_cleanup primary_stage=write target=preserved parent_dirs=unchanged temp_artifact=may_remain",
        body,
    );
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);

    var artifact_name: ?[]u8 = null;
    defer if (artifact_name) |name| gpa.free(name);
    var file_count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        file_count += 1;
        try std.testing.expect(entry.kind == .file);
        if (std.mem.eql(u8, entry.name, "target.txt")) continue;
        try std.testing.expect(artifact_name == null);
        artifact_name = try gpa.dupe(u8, entry.name);
    }
    try std.testing.expectEqual(@as(usize, 2), file_count);
    const artifact = artifact_name orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, body, artifact) == null);
    try std.testing.expect((try tmp.dir.statFile(io, artifact, .{ .follow_symlinks = false })).kind == .file);

    try tmp.dir.deleteFile(io, artifact);
    try expectPathAbsentIn(tmp.dir, io, artifact);
    try expectDirEntries(io, tmp.dir, &.{"target.txt"});
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
}

test "edit-v1 cleanup result selection allocates nothing after preparation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "alpha OLD omega\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });

    const guard_ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    var guard = try obtainGuard(guard_ctx);
    defer guard.deinit(gpa);

    // Measure the exact production preparation boundary without staging.
    var probe = std.testing.FailingAllocator.init(gpa, .{});
    const probe_allocator = probe.allocator();
    const probe_ctx: tool.Context = .{ .allocator = probe_allocator, .io = io, .cwd = tmp.dir };
    {
        const selected_path = try selectCommitPath(probe_ctx, guard, .write_file, "target.txt");
        defer probe_allocator.free(selected_path);
        var prepared = try PreparedAtomicFailureBodies.init(
            probe_ctx,
            .write_file,
            "target.txt",
            .unchanged,
        );
        defer prepared.deinit();
    }
    const allocations_before_stage = probe.alloc_index;
    try std.testing.expect(allocations_before_stage > 0);
    try std.testing.expectEqual(probe.allocations, probe.deallocations);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    // The next allocation after the measured boundary cannot succeed. The
    // former tempCleanupFailure allocation would therefore mask the artifact.
    var failing = std.testing.FailingAllocator.init(gpa, .{
        .fail_index = allocations_before_stage,
    });
    const allocator = failing.allocator();
    const ctx: tool.Context = .{ .allocator = allocator, .io = io, .cwd = tmp.dir };

    {
        testing.failNextEditAt(.write_after_prefix);
        testing.failNextTempCleanupDelete();
        const body = (try atomicCommit(
            ctx,
            guard,
            .write_file,
            "target.txt",
            "complete replacement bytes\n",
        )) orelse return error.TestUnexpectedResult;
        defer allocator.free(body);

        try std.testing.expectEqualStrings(
            "error: code=edit_io_failed format=edit-v1 operation=write_file stage=temp_cleanup primary_stage=write target=preserved parent_dirs=unchanged temp_artifact=may_remain",
            body,
        );
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(allocations_before_stage, failing.alloc_index);
        try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);

        var artifact_name: ?[]u8 = null;
        defer if (artifact_name) |name| gpa.free(name);
        var file_count: usize = 0;
        var it = tmp.dir.iterate();
        while (try it.next(io)) |entry| {
            file_count += 1;
            try std.testing.expect(entry.kind == .file);
            if (std.mem.eql(u8, entry.name, "target.txt")) continue;
            try std.testing.expect(artifact_name == null);
            artifact_name = try gpa.dupe(u8, entry.name);
        }
        try std.testing.expectEqual(@as(usize, 2), file_count);
        const artifact = artifact_name orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, body, artifact) == null);
        try std.testing.expect((try tmp.dir.statFile(
            io,
            artifact,
            .{ .follow_symlinks = false },
        )).kind == .file);
        try expectFileBytes(gpa, io, tmp.dir, artifact, "com");

        try tmp.dir.deleteFile(io, artifact);
        try expectPathAbsentIn(tmp.dir, io, artifact);
        try expectDirEntries(io, tmp.dir, &.{"target.txt"});
        try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
    }

    try std.testing.expectEqual(failing.allocations, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

    // A true Guard allocation failure after staging remains typed when cleanup
    // succeeds; all prepared bodies and the temporary are still released.
    var guard_oom = std.testing.FailingAllocator.init(gpa, .{
        .fail_index = allocations_before_stage,
    });
    const guard_oom_allocator = guard_oom.allocator();
    const guard_oom_ctx: tool.Context = .{
        .allocator = guard_oom_allocator,
        .io = io,
        .cwd = tmp.dir,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        atomicCommit(
            guard_oom_ctx,
            guard,
            .write_file,
            "target.txt",
            "complete replacement bytes\n",
        ),
    );
    try std.testing.expect(guard_oom.has_induced_failure);
    try std.testing.expectEqual(allocations_before_stage, guard_oom.alloc_index);
    try std.testing.expectEqual(guard_oom.allocations, guard_oom.deallocations);
    try std.testing.expectEqual(guard_oom.allocated_bytes, guard_oom.freed_bytes);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
    try expectDirEntries(io, tmp.dir, &.{"target.txt"});
}

test "edit-v1 cleanup failure takes precedence over final containment jail" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "alpha OLD omega\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    testing.failNextEditAt(.containment);
    testing.failNextTempCleanupDelete();
    const body = try invokeEditFixture(ctx, .write_file, "target.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "error: code=edit_io_failed format=edit-v1 operation=write_file stage=temp_cleanup primary_stage=containment target=preserved parent_dirs=unchanged temp_artifact=may_remain",
        body,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "code=jail_deny") == null);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);

    var artifact_name: ?[]u8 = null;
    defer if (artifact_name) |name| gpa.free(name);
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, "target.txt")) {
            try std.testing.expect(artifact_name == null);
            artifact_name = try gpa.dupe(u8, entry.name);
        }
    }
    const artifact = artifact_name orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, body, artifact) == null);
    try tmp.dir.deleteFile(io, artifact);
    try expectDirEntries(io, tmp.dir, &.{"target.txt"});
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
}

test "edit-v1 absent write_file target stays absent and temp-free on commit faults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for (edit_commit_faults) |fault| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

        testing.failNextEditAt(fault);
        const body = try invokeEditFixture(ctx, .write_file, "target.txt");
        defer gpa.free(body);
        try expectEditFaultBody(body, .write_file, fault, .unchanged);
        try expectPathAbsentIn(tmp.dir, io, "target.txt");
        try expectDirEntries(io, tmp.dir, &.{});
    }
}

test "edit-v1 contained final symlink failures preserve target link text and cleanup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for ([_]EditOperation{ .write_file, .search_replace }) |operation| {
        for (edit_commit_faults) |fault| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const original = "alpha OLD omega\n";
            try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = original });
            try tmp.dir.symLink(io, "real.txt", "link.txt", .{});
            const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

            testing.failNextEditAt(fault);
            const body = try invokeEditFixture(ctx, operation, "link.txt");
            defer gpa.free(body);
            try expectEditFaultBody(body, operation, fault, .unchanged);
            try expectFileBytes(gpa, io, tmp.dir, "real.txt", original);
            try expectSymlink(tmp.dir, io, "link.txt", "real.txt");
            try expectDirEntries(io, tmp.dir, &.{ "real.txt", "link.txt" });
        }
    }
}

test "atomic edit success commits through contained final symlink without replacing link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for ([_]EditOperation{ .write_file, .search_replace }) |operation| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "alpha OLD omega\n" });
        try tmp.dir.symLink(io, "real.txt", "link.txt", .{});
        const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

        const body = try invokeEditFixture(ctx, operation, "link.txt");
        defer gpa.free(body);
        try std.testing.expect(std.mem.startsWith(u8, body, "ok:"));
        const expected = switch (operation) {
            .write_file => "complete replacement bytes\n",
            .search_replace => "alpha NEW omega\n",
        };
        try expectFileBytes(gpa, io, tmp.dir, "real.txt", expected);
        try expectSymlink(tmp.dir, io, "link.txt", "real.txt");
        try expectDirEntries(io, tmp.dir, &.{ "real.txt", "link.txt" });
    }
}

test "edit-v1 missing-parent failures leave only declared directory residue" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for ([_]TestEditFault{
        .parent_create,
        .temp_create,
        .write_after_prefix,
        .flush,
        .containment,
        .replace,
    }) |fault| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

        testing.failNextEditAt(fault);
        const body = try invokeEditFixture(ctx, .write_file, "new/a/b/file.txt");
        defer gpa.free(body);
        try expectEditFaultBody(body, .write_file, fault, .may_remain);
        try expectPathAbsentIn(tmp.dir, io, "new/a/b/file.txt");
        try expectDirEntries(io, tmp.dir, &.{"new"});

        var new_dir = try tmp.dir.openDir(io, "new", .{ .iterate = true });
        defer new_dir.close(io);
        try expectDirEntries(io, new_dir, &.{"a"});
        var a_dir = try new_dir.openDir(io, "a", .{ .iterate = true });
        defer a_dir.close(io);
        try expectDirEntries(io, a_dir, &.{"b"});
        var b_dir = try a_dir.openDir(io, "b", .{ .iterate = true });
        defer b_dir.close(io);
        try expectDirEntries(io, b_dir, &.{});
    }
}

test "search_replace stale missing ambiguous and oversize outcomes do not mutate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

    const current = "current bytes\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = current });
    const stale = try searchReplace(
        ctx,
        null,
        "{\"path\":\"target.txt\",\"old_string\":\"stale bytes\",\"new_string\":\"new\"}",
    );
    defer gpa.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "code=anchor_not_found") != null);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", current);

    try std.testing.expectError(
        error.ToolFailed,
        searchReplace(
            ctx,
            null,
            "{\"path\":\"missing.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}",
        ),
    );
    try expectPathAbsentIn(tmp.dir, io, "missing.txt");

    const ambiguous_bytes = "OLD and OLD\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = ambiguous_bytes, .flags = .{ .truncate = true } });
    const ambiguous = try invokeEditFixture(ctx, .search_replace, "target.txt");
    defer gpa.free(ambiguous);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous, "code=ambiguous_anchor") != null);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", ambiguous_bytes);

    const oversized_replacement = try gpa.alloc(u8, @as(usize, max_write_bytes) + 1);
    defer gpa.free(oversized_replacement);
    @memset(oversized_replacement, 'R');
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "OLD\n", .flags = .{ .truncate = true } });
    const replace_args = try std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"target.txt\",\"old_string\":\"OLD\",\"new_string\":\"{s}\"}}",
        .{oversized_replacement},
    );
    defer gpa.free(replace_args);
    const result_too_large = try searchReplace(ctx, null, replace_args);
    defer gpa.free(result_too_large);
    try std.testing.expect(std.mem.indexOf(u8, result_too_large, "code=too_large") != null);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", "OLD\n");

    const write_args = try std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"target.txt\",\"content\":\"{s}\"}}",
        .{oversized_replacement},
    );
    defer gpa.free(write_args);
    const write_too_large = try writeFile(ctx, null, write_args);
    defer gpa.free(write_too_large);
    try std.testing.expect(std.mem.indexOf(u8, write_too_large, "code=too_large") != null);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", "OLD\n");

    const oversized = try gpa.alloc(u8, max_read_for_edit);
    defer gpa.free(oversized);
    @memset(oversized, 'Q');
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = oversized, .flags = .{ .truncate = true } });
    const too_large = try invokeEditFixture(ctx, .search_replace, "target.txt");
    defer gpa.free(too_large);
    try std.testing.expect(std.mem.indexOf(u8, too_large, "code=too_large") != null);
    const after = try tmp.dir.readFileAlloc(io, "target.txt", gpa, .limited(oversized.len + 1));
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, oversized, after);
    try expectDirEntries(io, tmp.dir, &.{"target.txt"});
}

test "atomic commit OOM before temp is typed and preserves target" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const original = "original before OOM\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = original });

    const normal_ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };
    var guard = try obtainGuard(normal_ctx);
    defer guard.deinit(gpa);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const failing_ctx: tool.Context = .{
        .allocator = failing.allocator(),
        .io = io,
        .cwd = tmp.dir,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        atomicCommit(failing_ctx, guard, .write_file, "target.txt", "complete new bytes\n"),
    );
    try std.testing.expect(failing.has_induced_failure);
    try expectFileBytes(gpa, io, tmp.dir, "target.txt", original);
    try expectDirEntries(io, tmp.dir, &.{"target.txt"});
}

test "post-commit enrichment failure remains successful with complete target bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    testing.reset();
    defer testing.reset();

    for ([_]EditOperation{ .write_file, .search_replace }) |operation| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "alpha OLD omega\n" });
        const ctx: tool.Context = .{ .allocator = gpa, .io = io, .cwd = tmp.dir };

        testing.failNextEditAt(.post_commit_enrichment);
        const body = try invokeEditFixture(ctx, operation, "target.txt");
        defer gpa.free(body);
        try std.testing.expect(std.mem.startsWith(u8, body, "ok:"));
        try std.testing.expect(std.mem.indexOf(u8, body, "git diff") == null);
        const expected = switch (operation) {
            .write_file => "complete replacement bytes\n",
            .search_replace => "alpha NEW omega\n",
        };
        try expectFileBytes(gpa, io, tmp.dir, "target.txt", expected);
        try expectDirEntries(io, tmp.dir, &.{"target.txt"});
    }
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
