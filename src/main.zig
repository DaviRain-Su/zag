//! Zag CLI — thin product shell. Business lives in `agent/`.

const std = @import("std");
const Io = std.Io;
const zag = @import("zag");

const default_system =
    \\You are Zag, a coding agent that can read and modify the working directory.
    \\Tools:
    \\- list_dir, read_file — explore (always allowed after jail check)
    \\- write_file — create/overwrite files (permission + workspace jail)
    \\- run_shell — shell commands (permission + policy denylist)
    \\Rules:
    \\- Prefer tools over guessing about files on disk.
    \\- Paths must be relative to the working directory; absolute paths and '..' escapes are denied.
    \\- For edits: read first when possible, then write the full file content.
    \\- If a tool is denied (permission, jail, or policy), do not retry blindly; explain and wait.
    \\- Honor project instructions from AGENTS.md when present.
    \\- Be concise. When finished, answer without further tool calls.
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    var verbose = false;
    var show_help = false;
    var permission_mode: zag.permissions.Mode = .ask;
    var shell_policy: zag.shell_policy.Mode = .protect;
    var session_path: ?[]const u8 = null;
    var continue_session = false;
    var no_project = false;
    var trace_path: ?[]const u8 = null;
    var enable_trace = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--yolo")) {
            permission_mode = .yolo;
        } else if (std.mem.eql(u8, a, "--ask")) {
            permission_mode = .ask;
        } else if (std.mem.eql(u8, a, "--permission") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("{s} requires ask|yolo", .{a});
                std.process.exit(2);
            }
            permission_mode = zag.permissions.Mode.parse(args[i]) orelse {
                std.log.err("unknown permission mode: {s}", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--shell-policy")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--shell-policy requires protect|off", .{});
                std.process.exit(2);
            }
            shell_policy = zag.shell_policy.Mode.parse(args[i]) orelse {
                std.log.err("unknown shell policy: {s}", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--session") or std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("{s} requires a path", .{a});
                std.process.exit(2);
            }
            session_path = args[i];
        } else if (std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c")) {
            continue_session = true;
            if (session_path == null) session_path = ".zag/sessions/default.jsonl";
        } else if (std.mem.eql(u8, a, "--no-project")) {
            no_project = true;
        } else if (std.mem.eql(u8, a, "--trace")) {
            enable_trace = true;
            if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                trace_path = args[i];
            }
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try prompt_parts.append(arena, args[i]);
            }
            break;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.log.err("unknown flag: {s}", .{a});
            try printUsage();
            std.process.exit(2);
        } else {
            try prompt_parts.append(arena, a);
        }
    }

    if (show_help) {
        try printUsage();
        return;
    }

    if (session_path != null and !continue_session and prompt_parts.items.len == 0) {
        continue_session = true;
    }

    if (enable_trace and trace_path == null) {
        trace_path = ".zag/traces/latest.jsonl";
    }

    const resolved = zag.provider_registry.resolveFromEnv(init.environ_map) catch |err| {
        switch (err) {
            error.MissingApiKey => {
                std.log.err(
                    \\missing API key. Configure a preset env var (see --help), or:
                    \\  ZAG_API_KEY + ZAG_BASE_URL [+ ZAG_MODEL]
                    \\  ZAG_PROVIDER=<id>  (optional explicit preset)
                , .{});
                std.process.exit(1);
            },
            error.UnknownProvider => {
                std.log.err("unknown ZAG_PROVIDER (see presets in provider/presets.zig)", .{});
                std.process.exit(1);
            },
            error.MissingBaseUrl => {
                std.log.err("ZAG_API_KEY requires ZAG_BASE_URL for custom endpoints", .{});
                std.process.exit(1);
            },
        }
    };

    if (verbose) {
        std.log.info("provider id={s} name={s} model={s} key_from={s} permission={s} shell_policy={s}", .{
            resolved.spec_id,
            resolved.display_name,
            resolved.config.model,
            resolved.api_key_source,
            permission_mode.name(),
            shell_policy.name(),
        });
        if (session_path) |sp| std.log.info("session path={s}", .{sp});
        if (trace_path) |tp| std.log.info("trace path={s}", .{tp});
    }

    var client = zag.openai_compat.Client.init(gpa, io, resolved.config);
    defer client.deinit();

    var agent = zag.agent.Agent.init(gpa, io, client.provider(), .{
        .verbose = verbose,
        .permission_mode = permission_mode,
        .shell_policy = shell_policy,
        .trace_path = trace_path,
        .version = zag.version,
    });
    defer agent.deinit();

    if (prompt_parts.items.len > 0) {
        const prompt = try std.mem.join(arena, " ", prompt_parts.items);
        try runOneShot(&agent, prompt, verbose, session_path, continue_session, !no_project);
        return;
    }

    try runRepl(&agent, io, permission_mode, session_path, continue_session, !no_project);
}

fn runOneShot(
    agent: *zag.agent.Agent,
    prompt: []const u8,
    verbose: bool,
    session_path: ?[]const u8,
    continue_existing: bool,
    load_project: bool,
) !void {
    const result = agent.completeWithSession(default_system, prompt, .{
        .path = session_path,
        .continue_existing = continue_existing or session_path != null,
        .load_project_instructions = load_project,
    }) catch |err| {
        std.log.err("agent failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(agent.gpa);

    if (verbose) {
        std.log.info("completed in {d} turn(s)", .{result.turns});
    }

    try writeStdout(agent.io, result.final_text);
    if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
        try writeStdout(agent.io, "\n");
    }
}

fn runRepl(
    agent: *zag.agent.Agent,
    io: Io,
    mode: zag.permissions.Mode,
    session_path: ?[]const u8,
    continue_existing: bool,
    load_project: bool,
) !void {
    try writeStdout(io, "zag phase-3 (jail + policy + trace, permission=");
    try writeStdout(io, mode.name());
    try writeStdout(io, "). Empty line or Ctrl-D to exit.\n");
    if (session_path) |sp| {
        try writeStdout(io, "session: ");
        try writeStdout(io, sp);
        try writeStdout(io, "\n");
    }

    var session = zag.agent.Session.start(agent.gpa, io, .{
        .base_system = default_system,
        .path = session_path,
        .continue_existing = continue_existing or session_path != null,
        .load_project_instructions = load_project,
    }) catch |err| {
        std.log.err("session failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    if (session.project_source) |src| {
        try writeStdout(io, "project instructions: ");
        try writeStdout(io, src);
        try writeStdout(io, "\n");
    }

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_reader.interface;

    while (true) {
        try writeStdout(io, "you> ");
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try writeStdout(io, "\n");
                break;
            },
            else => return err,
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) break;

        const result = agent.reply(&session, trimmed) catch |err| {
            std.log.err("agent failed: {s}", .{@errorName(err)});
            continue;
        };

        try writeStdout(io, "zag> ");
        try writeStdout(io, result.final_text);
        if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
            try writeStdout(io, "\n");
        }
    }
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn printUsage() !void {
    const usage =
        \\zag — Zig coding agent (Phase 3: workspace jail + shell policy + trace)
        \\
        \\Usage:
        \\  zag [flags] <prompt...>     one-shot
        \\  zag [flags]                 interactive REPL
        \\
        \\Flags:
        \\  -h, --help                 show help
        \\  -v, --verbose              stderr tool / permission log
        \\  --ask / --yolo             human permission mode (default ask)
        \\  -p, --permission MODE      ask | yolo
        \\  --shell-policy MODE        protect (default) | off
        \\  -s, --session PATH         session JSONL
        \\  -c, --continue             resume session
        \\  --no-project               skip AGENTS.md injection
        \\  --trace [PATH]             write structured run trace JSONL
        \\                             (default .zag/traces/latest.jsonl)
        \\
        \\Tools: list_dir, read_file, write_file, run_shell
        \\Security: relative paths only; shell denylist even under --yolo
        \\
        \\Model providers (OpenAI Chat Completions wire format only):
        \\  Auto-detect first set key among presets (order in provider/presets.zig),
        \\  or set ZAG_PROVIDER=deepseek|xai|openai|openrouter|together|groq
        \\  Custom: ZAG_API_KEY + ZAG_BASE_URL [+ ZAG_MODEL]
        \\  Override any preset: ZAG_BASE_URL, ZAG_MODEL
        \\
    ;
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeStdout(io, usage);
}
