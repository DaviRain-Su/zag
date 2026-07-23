//! Phase 1 write / shell tools: `write_file`, `run_shell`.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;

pub const write_file_def: tool.Definition = .{
    .name = "write_file",
    .description =
        \\Write or overwrite a UTF-8 text file relative to the working directory.
        \\Creates parent directories if needed. Prefer reading the file first when editing.
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

const max_write_bytes: usize = 512 * 1024;
const max_shell_output: usize = tool.max_result_bytes;
const shell_timeout_secs: i64 = 30;

pub fn writeFile(ctx: tool.Context, arguments_json: []const u8) tool.HandlerError![]u8 {
    const path = try tool.requireStringField(ctx.allocator, arguments_json, "path");
    defer ctx.allocator.free(path);
    const content = try tool.requireStringField(ctx.allocator, arguments_json, "content");
    defer ctx.allocator.free(content);

    if (path.len == 0) return error.InvalidArguments;
    if (content.len > max_write_bytes) return error.InvalidArguments;

    // Create parent directories when path has a directory component.
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

    return std.fmt.allocPrint(
        ctx.allocator,
        "ok: wrote {d} bytes to {s}",
        .{ content.len, path },
    ) catch return error.OutOfMemory;
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
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => {
            return std.fmt.allocPrint(
                ctx.allocator,
                "error: command timed out after {d}s: {s}",
                .{ shell_timeout_secs, command },
            ) catch return error.OutOfMemory;
        },
        error.StreamTooLong => {
            return std.fmt.allocPrint(
                ctx.allocator,
                "error: command output exceeded {d} bytes (truncated). Command: {s}",
                .{ max_shell_output, command },
            ) catch return error.OutOfMemory;
        },
        else => {
            return std.fmt.allocPrint(
                ctx.allocator,
                "error: failed to run command ({s}): {s}",
                .{ @errorName(err), command },
            ) catch return error.OutOfMemory;
        },
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    var out: Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    switch (result.term) {
        .exited => |c| out.writer.print("exit_code: {d}\n", .{c}) catch return error.OutOfMemory,
        .signal => |s| out.writer.print("signal: {d}\n", .{@intFromEnum(s)}) catch return error.OutOfMemory,
        .stopped => |s| out.writer.print("stopped: {d}\n", .{@intFromEnum(s)}) catch return error.OutOfMemory,
        .unknown => |u| out.writer.print("unknown_status: {d}\n", .{u}) catch return error.OutOfMemory,
    }
    if (result.stdout.len > 0) {
        out.writer.writeAll("--- stdout ---\n") catch return error.OutOfMemory;
        out.writer.writeAll(result.stdout) catch return error.OutOfMemory;
        if (result.stdout[result.stdout.len - 1] != '\n') {
            out.writer.writeAll("\n") catch return error.OutOfMemory;
        }
    }
    if (result.stderr.len > 0) {
        out.writer.writeAll("--- stderr ---\n") catch return error.OutOfMemory;
        out.writer.writeAll(result.stderr) catch return error.OutOfMemory;
        if (result.stderr[result.stderr.len - 1] != '\n') {
            out.writer.writeAll("\n") catch return error.OutOfMemory;
        }
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        out.writer.writeAll("(no output)\n") catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn phase1ExtraTools() [2]tool.Tool {
    return .{
        .{ .definition = write_file_def, .handler = writeFile },
        .{ .definition = run_shell_def, .handler = runShell },
    };
}

test "write_file and run_shell in tmp dir" {
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
        \\{"path":"hello.txt","content":"hi from zag\n"}
    );
    defer gpa.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "ok:") != null);

    const read_back = try tmp.dir.readFileAlloc(io, "hello.txt", gpa, .limited(1024));
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings("hi from zag\n", read_back);

    const shell = try runShell(ctx, "{\"command\":\"echo shell-ok\"}");
    defer gpa.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "shell-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell, "exit_code: 0") != null);
}
