//! Zag CLI application logic (args, resolve, one-shot / REPL).
//!
//! Product shell only — no loop/tool protocol. Invoked from a thin `main`.

const std = @import("std");
const Io = std.Io;
const ai = @import("zag-ai");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");

const default_system =
    \\You are Zag, a coding agent that can read and modify the working directory.
    \\Tools:
    \\- list_dir, read_file, grep, glob — explore (always allowed after jail check)
    \\- search_replace — default edit: unique old_string anchor → new_string (permission + jail)
    \\- write_file — create new files or intentional full overwrite (permission + jail)
    \\- run_shell — shell commands (permission + policy denylist)
    \\Rules:
    \\- Prefer tools over guessing about files on disk.
    \\- Paths must be relative to the working directory; absolute paths and '..' escapes are denied.
    \\- For edits: read first, then prefer search_replace; use write_file only for new files or full rewrites.
    \\- If search_replace returns anchor_not_found or ambiguous_anchor, re-read and widen the anchor; do not blindly overwrite.
    \\- If a tool is denied (permission, jail, or policy), do not retry blindly; explain and wait.
    \\- Honor project instructions from AGENTS.md when present.
    \\- Be concise. When finished, answer without further tool calls.
    \\
;

/// Entry used by the executable's `main`.
pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    var verbose = false;
    var show_help = false;
    var permission_mode: core.permissions.Mode = .ask;
    var session_kind: core.permissions.SessionKind = .agent;
    var remember_writes = true;
    var shell_policy: core.shell_policy.Mode = .protect;
    var session_path: ?[]const u8 = null;
    var continue_session = false;
    var no_project = false;
    var trace_path: ?[]const u8 = null;
    var enable_trace = false;
    var want_stream = false;
    var config_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, a, "--plan")) {
            session_kind = .plan;
        } else if (std.mem.eql(u8, a, "--no-remember")) {
            remember_writes = false;
        } else if (std.mem.eql(u8, a, "--permission") or std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("{s} requires ask|yolo", .{a});
                std.process.exit(2);
            }
            permission_mode = core.permissions.Mode.parse(args[i]) orelse {
                std.log.err("unknown permission mode: {s}", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--shell-policy")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--shell-policy requires protect|off", .{});
                std.process.exit(2);
            }
            shell_policy = core.shell_policy.Mode.parse(args[i]) orelse {
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
        } else if (std.mem.startsWith(u8, a, "--trace=")) {
            enable_trace = true;
            const p = a["--trace=".len..];
            if (p.len == 0) {
                std.log.err("--trace= requires a path", .{});
                std.process.exit(2);
            }
            trace_path = p;
        } else if (std.mem.eql(u8, a, "--trace")) {
            enable_trace = true;
            // Only consume the next argv when it looks like a path — never a prompt.
            if (i + 1 < args.len and looksLikeTracePath(args[i + 1])) {
                i += 1;
                trace_path = args[i];
            }
        } else if (std.mem.eql(u8, a, "--stream")) {
            want_stream = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--config requires a path", .{});
                std.process.exit(2);
            }
            config_path = args[i];
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

    // D-006: -s PATH → create_new; -c → resume_existing.
    // open_or_create is SDK-only and is not selected by CLI flags.
    if (session_path) |sp| {
        core.session_store.validateSessionPath(sp) catch {
            std.log.err("session path must be a relative workspace path (no absolute/'..'): {s}", .{sp});
            std.process.exit(2);
        };
    }

    if (enable_trace and trace_path == null) {
        trace_path = ".zag/traces/latest.jsonl";
    }

    var resolve_result = ai.resolve(gpa, io, init.environ_map, config_path) catch |err| {
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
                std.log.err("unknown ZAG_PROVIDER (see packages/zag-ai presets)", .{});
                std.process.exit(1);
            },
            error.MissingBaseUrl => {
                std.log.err("ZAG_API_KEY requires ZAG_BASE_URL for custom endpoints", .{});
                std.process.exit(1);
            },
            error.UnsupportedApiStyle => {
                std.log.err("unsupported ZAG_API_STYLE (use openai_compat or anthropic_messages)", .{});
                std.process.exit(1);
            },
            else => {
                std.log.err("provider resolve failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            },
        }
    };
    defer resolve_result.deinit(gpa);

    const resolved = resolve_result.resolved;
    const use_stream = want_stream or resolve_result.stream;

    const context_defaults = core.context.Options{};
    const context_opts = core.context.optionsFromBudget(
        resolve_result.contextCharBudget(context_defaults.max_chars),
        .{
            .max_chars = resolve_result.context_max_chars,
            .max_tail_messages = resolve_result.context_max_tail_messages,
        },
    );

    if (verbose) {
        std.log.info("provider id={s} name={s} model={s} key_from={s} stream={any} permission={s} session={s} remember={any} shell_policy={s}", .{
            resolved.spec_id,
            resolved.display_name,
            resolved.config.model,
            resolved.api_key_source,
            use_stream,
            permission_mode.name(),
            session_kind.name(),
            remember_writes,
            shell_policy.name(),
        });
        if (resolve_result.model_info) |mi| {
            std.log.info(
                "catalog context_window={d} max_output={d} view_max_chars={d}",
                .{ mi.context_window, mi.max_output_tokens, context_opts.max_chars },
            );
        } else {
            std.log.info("catalog miss; view_max_chars={d}", .{context_opts.max_chars});
        }
        if (resolve_result.chat_options.temperature) |t| {
            std.log.info("chat temperature={d}", .{t});
        }
        if (resolve_result.chat_options.max_tokens) |mt| {
            std.log.info("chat max_tokens={d}", .{mt});
        }
        std.log.info(
            "wire={s} retries transport={d} chat={d} timeout_ms={any}",
            .{
                resolved.api_style.jsonName(),
                resolved.config.max_retries,
                resolve_result.chat_retries,
                resolved.config.timeout_ms,
            },
        );
        if (session_path) |sp| std.log.info("session path={s}", .{sp});
        if (trace_path) |tp| std.log.info("trace path={s}", .{tp});
    }

    const wire = resolved.createWire(gpa, io) catch |err| {
        std.log.err("wire adapter init failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    var wire_prov = coding.WireProvider.init(wire, use_stream, true);
    wire_prov.chat_options = resolve_result.chat_options;
    if (use_stream and verbose) {
        wire_prov.on_event = streamLogHandler;
        wire_prov.on_event_ctx = null;
    }
    defer wire_prov.deinit();

    var agent_opts: coding.agent.Options = .{
        .verbose = verbose,
        .permission_mode = permission_mode,
        .session_kind = session_kind,
        .remember_writes = remember_writes,
        .shell_policy = shell_policy,
        .trace_path = trace_path,
        .version = coding.version,
        .context = context_opts,
        .chat_retries = resolve_result.chat_retries,
        .retry_base_delay_ms = resolve_result.retry_base_delay_ms,
        .model_info = resolve_result.model_info,
    };
    if (resolve_result.max_turns) |mt| {
        agent_opts.max_turns = mt;
    }

    var agent = coding.Agent.init(gpa, io, wire_prov.asProvider(), agent_opts);
    defer agent.deinit();
    core.cancel.installSigInt(&agent.cancel);

    // -c → resume_existing; -s without -c → create_new; no path → ephemeral (create_new with null path).
    const open_mode: coding.OpenMode = if (continue_session) .resume_existing else .create_new;

    if (prompt_parts.items.len > 0) {
        const prompt = try std.mem.join(arena, " ", prompt_parts.items);
        try runOneShot(&agent, prompt, verbose, session_path, open_mode, !no_project);
        return;
    }

    try runRepl(&agent, io, permission_mode, session_path, open_mode, !no_project);
}

fn runOneShot(
    agent: *coding.Agent,
    prompt: []const u8,
    verbose: bool,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
) !void {
    const result = agent.completeWithSession(default_system, prompt, .{
        .path = session_path,
        .open_mode = open_mode,
        .load_project_instructions = load_project,
    }) catch |err| {
        std.log.err("agent failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(agent.gpa);

    if (verbose) {
        std.log.info("completed in {d} turn(s) stop={s}", .{ result.turns, @tagName(result.stop_reason) });
        agent.logCostSummary();
    } else if (agent.ledger.turns > 0) {
        // Quiet one-liner on run_end so cost is visible without -v.
        agent.logCostSummary();
    }
    if (result.stop_reason == .max_turns) {
        std.log.warn("stopped: max_turns reached ({d})", .{result.turns});
    } else if (result.stop_reason == .cancelled) {
        std.log.warn("stopped: cancelled (SIGINT)", .{});
    }

    try writeStdout(agent.io, result.final_text);
    if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
        try writeStdout(agent.io, "\n");
    }
}

fn runRepl(
    agent: *coding.Agent,
    io: Io,
    mode: core.permissions.Mode,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
) !void {
    try writeStdout(io, "zag (jail + policy + trace, permission=");
    try writeStdout(io, mode.name());
    try writeStdout(io, "). Empty line or Ctrl-D to exit.\n");
    if (session_path) |sp| {
        try writeStdout(io, "session: ");
        try writeStdout(io, sp);
        try writeStdout(io, "\n");
    }

    var session = coding.Session.start(agent.gpa, io, .{
        .base_system = default_system,
        .path = session_path,
        .open_mode = open_mode,
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

        if (agent.options.verbose) {
            agent.logCostSummary();
        }

        try writeStdout(io, "zag> ");
        try writeStdout(io, result.final_text);
        if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
            try writeStdout(io, "\n");
        }
    }

    // Session-end cost line (even without -v) when any usage was recorded.
    agent.logCostSummary();
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn streamLogHandler(_: ?*anyopaque, event: ai.StreamEvent) anyerror!void {
    switch (event) {
        .content_delta => |d| {
            if (d.len > 0) std.debug.print("{s}", .{d});
        },
        .finish_reason => |fr| {
            if (fr.len > 0) std.log.info("stream finish_reason={s}", .{fr});
        },
        .tool_call_delta => |tc| {
            if (tc.name.len > 0) std.log.info("stream tool_call[{d}] {s}", .{ tc.index, tc.name });
        },
        .done => {
            std.debug.print("\n", .{});
        },
    }
}

fn printUsage() !void {
    const usage =
        \\zag — Zig coding agent
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
        \\  --plan                     plan session: read + plan.md only (H3 stub)
        \\  --no-remember              re-prompt every write path in ask mode
        \\  --shell-policy MODE        protect (default) | off
        \\  -s, --session PATH         create session at PATH (fails if exists; relative only)
        \\  -c, --continue             resume session (default PATH .zag/sessions/default.jsonl)
        \\  --no-project               skip AGENTS.md injection
        \\  --trace                    write run trace (.zag/traces/latest.jsonl)
        \\  --trace=PATH / --trace PATH  same, with explicit path (.jsonl or path-like)
        \\                             (bare words after --trace are treated as prompt)
        \\  --stream                   SSE streaming completions
        \\  --config PATH              JSON config (.zag/config.json also auto-loaded)
        \\
        \\Tools: list_dir, read_file, grep, glob, search_replace, write_file, run_shell
        \\Security: relative paths only; shell denylist even under --yolo
        \\
        \\Model (packages/zag-ai):
        \\  Env: DEEPSEEK_API_KEY, XAI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY, …
        \\  ZAG_PROVIDER  ZAG_MODEL  ZAG_BASE_URL
        \\  ZAG_API_STYLE=openai_compat|anthropic_messages
        \\  ZAG_TEMPERATURE  ZAG_MAX_TOKENS  ZAG_MAX_RETRIES  ZAG_TIMEOUT_MS  ZAG_CHAT_RETRIES
        \\
        \\  Anthropic example:
        \\    ANTHROPIC_API_KEY=…  ZAG_PROVIDER=anthropic
        \\
        \\Packages: zag-cli → coding-agent → agent-core → zag-types
        \\                       ↘ zag-ai → openai-zig
        \\
    ;
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeStdout(io, usage);
}

/// True when `s` is safe to treat as an optional `--trace` path argument
/// (not a natural-language prompt).
pub fn looksLikeTracePath(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-') return false;
    if (std.mem.endsWith(u8, s, ".jsonl")) return true;
    if (std.mem.indexOfScalar(u8, s, '/') != null) return true;
    // Relative hidden paths like `.zag/traces/x` (also matched by `/` above)
    // or `.trace.jsonl` already covered; bare `.foo` without slash:
    if (s[0] == '.' and s.len > 1) return true;
    return false;
}

test "looksLikeTracePath" {
    try std.testing.expect(looksLikeTracePath(".zag/traces/latest.jsonl"));
    try std.testing.expect(looksLikeTracePath("out/run.jsonl"));
    try std.testing.expect(looksLikeTracePath("trace.jsonl"));
    try std.testing.expect(looksLikeTracePath("./t.jsonl"));
    try std.testing.expect(!looksLikeTracePath("list_dir ."));
    try std.testing.expect(!looksLikeTracePath("list_dir"));
    try std.testing.expect(!looksLikeTracePath("--yolo"));
    try std.testing.expect(!looksLikeTracePath("hello world"));
}
