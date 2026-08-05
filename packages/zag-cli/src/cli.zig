//! Zag CLI application logic (args, resolve, one-shot / REPL).
//!
//! Product shell only — no loop/tool protocol. Invoked from a thin `main`.

const std = @import("std");
const Io = std.Io;
const ai = @import("zag-ai");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");
const hw = @import("headless_writer.zig");
const sigint = @import("sigint.zig");
const cli_stream = @import("cli_stream.zig");
const build_options = @import("build_options");
const tui_enabled: bool = build_options.tui_enabled;
const tui_entry = if (tui_enabled) @import("tui_entry.zig") else struct {};

const default_system =
    \\You are Zag, a coding agent that can read and modify the working directory.
    \\Tools:
    \\- list_dir, read_file, grep, glob — explore (always allowed after jail check)
    \\- search_replace — default edit: unique old_string anchor → new_string (permission + jail)
    \\- apply_hunk — single-hunk edit with full-file SHA-256 precondition + mandatory hunk review
    \\- write_file — create new files or intentional full overwrite (permission + jail)
    \\- run_shell — shell commands (permission + policy denylist)
    \\Rules:
    \\- Prefer tools over guessing about files on disk.
    \\- Paths must be relative to the working directory; absolute paths and '..' escapes are denied.
    \\- For edits: read first (include_digest when using apply_hunk), then prefer search_replace or apply_hunk; use write_file only for new files or full rewrites.
    \\- If search_replace/apply_hunk returns anchor_not_found, ambiguous_anchor, or stale_precondition, re-read and widen the anchor; do not blindly overwrite.
    \\- If a tool is denied (permission, jail, or policy), do not retry blindly; explain and wait.
    \\- Honor project instructions from AGENTS.md when present.
    \\- Be concise. When finished, answer without further tool calls.
    \\
;

/// Pure stdin-line decision for interactive hunk review (B6).
/// `null` models EOF/read failure → reject. Never accept on empty/other.
pub fn decideHunkReviewLine(line: ?[]const u8) coding.HunkReviewDecision {
    const raw = line orelse return .reject;
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 1 and (trimmed[0] == 'y' or trimmed[0] == 'Y')) return .accept;
    if (std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "YES")) return .accept;
    return .reject;
}

/// Interactive one-hunk reviewer (B6). Stderr prompt+preview only; not StdinPrompter.
pub const InteractiveHunkReviewer = struct {
    io: Io,
    /// Cooperative cancel; reject if set before decision (never accept).
    cancel: ?*const core.cancel.Flag = null,
    /// Test seam: when set, skip stdin and use this line (or null = EOF). Production null.
    test_line: if (@import("builtin").is_test) ?[]const u8 else void =
        if (@import("builtin").is_test) null else {},
    test_use_line: if (@import("builtin").is_test) bool else void =
        if (@import("builtin").is_test) false else {},
    /// Counts stderr write attempts (test observability only).
    stderr_writes: if (@import("builtin").is_test) u32 else void =
        if (@import("builtin").is_test) 0 else {},

    pub fn asReviewer(self: *InteractiveHunkReviewer) coding.HunkReviewer {
        return .{
            .ptr = self,
            .reviewFn = reviewImpl,
        };
    }

    fn reviewImpl(ptr: ?*anyopaque, preview: coding.HunkReviewPreview) coding.HunkReviewDecision {
        const self: *InteractiveHunkReviewer = @ptrCast(@alignCast(ptr.?));
        if (self.cancel) |c| {
            if (c.isSet()) return .reject;
        }

        // Human prompt + bounded preview on stderr only (never stdout).
        var stderr_buf: [512]u8 = undefined;
        var stderr_writer = Io.File.stderr().writer(self.io, &stderr_buf);
        const w = &stderr_writer.interface;
        w.print(
            "hunk review: path={s} old_len={d} new_len={d} expected_sha256={s}\n",
            .{ preview.path, preview.old_len, preview.new_len, preview.expected_sha256 },
        ) catch {};
        w.writeAll(preview.preview_text) catch {};
        if (preview.preview_text.len == 0 or preview.preview_text[preview.preview_text.len - 1] != '\n') {
            w.writeAll("\n") catch {};
        }
        w.writeAll("accept hunk? [y/N] > ") catch {};
        w.flush() catch {};
        if (@import("builtin").is_test) self.stderr_writes += 1;

        const line: ?[]const u8 = blk: {
            if (@import("builtin").is_test) {
                if (self.test_use_line) break :blk self.test_line;
            }
            var line_buf: [64]u8 = undefined;
            var reader = Io.File.stdin().reader(self.io, &line_buf);
            break :blk reader.interface.takeDelimiterExclusive('\n') catch null;
        };
        if (self.cancel) |c| {
            if (c.isSet()) return .reject;
        }
        return decideHunkReviewLine(line);
    }
};

/// B2 first-match bind for product CLI default composition.
fn resolveHunkReviewer(
    permission_mode: coding.permissions.Mode,
    headless_mode: ?hw.HeadlessMode,
    interactive: *InteractiveHunkReviewer,
) ?coding.HunkReviewer {
    // Plan/permission deny is handled before handler entry — no bind change here.
    // (1) yolo → AutoAccept for all modes including --json/--json-stream.
    if (permission_mode == .yolo) {
        return coding.autoAcceptHunkReviewer();
    }
    // (2) interactive non-headless ask → InteractiveHunkReviewer.
    if (permission_mode == .ask and headless_mode == null) {
        const stdin_tty = Io.File.stdin().isTty(interactive.io) catch false;
        if (stdin_tty) return interactive.asReviewer();
    }
    // (3) headless ask / noninteractive → null (review_unavailable if handler reached).
    return null;
}

/// Observer adapter that forwards harness events to the headless NDJSON writer.
const HeadlessObserver = struct {
    writer: *hw.HeadlessWriter,

    fn asObserver(self: *HeadlessObserver) coding.observer.Observer {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    fn onEvent(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *HeadlessObserver = @ptrCast(@alignCast(ptr.?));
        self.writer.dispatchEvent(event) catch |err| {
            self.writer.setHalted(if (err == error.OutOfMemory)
                hw.HeadlessError{ .code = .out_of_memory, .message = "headless stream out of memory" }
            else
                hw.HeadlessError{ .code = .trace_error, .message = "headless stream write failed" });
        };
    }
};

/// Entry used by the executable's `main`.
pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    var verbose = false;
    var show_help = false;
    var permission_mode: coding.permissions.Mode = .ask;
    var session_kind: coding.permissions.SessionKind = .agent;
    var remember_writes = true;
    var shell_policy: coding.shell_policy.Mode = .protect;
    var session_path: ?[]const u8 = null;
    var continue_session = false;
    var no_project = false;
    var no_skills = false;
    var trust_project_skills = false;
    var no_prompt_templates = false;
    var trust_project_templates = false;
    var trace_path: ?[]const u8 = null;
    var enable_trace = false;
    var want_stream = false;
    var config_path: ?[]const u8 = null;
    var want_doctor = false;
    var headless_mode: ?hw.HeadlessMode = null;
    var want_tui = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--tui")) {
            want_tui = true;
        } else if (std.mem.eql(u8, a, "--doctor")) {
            want_doctor = true;
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
            permission_mode = coding.permissions.Mode.parse(args[i]) orelse {
                std.log.err("{s}", .{invalidPermissionModeMessage()});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--shell-policy")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--shell-policy requires protect|off", .{});
                std.process.exit(2);
            }
            shell_policy = coding.shell_policy.Mode.parse(args[i]) orelse {
                std.log.err("{s}", .{invalidShellPolicyMessage()});
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
        } else if (std.mem.eql(u8, a, "--no-skills")) {
            no_skills = true;
        } else if (std.mem.eql(u8, a, "--trust-project-skills")) {
            trust_project_skills = true;
        } else if (std.mem.eql(u8, a, "--no-prompt-templates")) {
            no_prompt_templates = true;
        } else if (std.mem.eql(u8, a, "--trust-project-templates")) {
            trust_project_templates = true;
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
        } else if (std.mem.eql(u8, a, "--json")) {
            if (headless_mode) |_| {
                std.log.err("--json and --json-stream are mutually exclusive", .{});
                std.process.exit(2);
            }
            headless_mode = .json;
        } else if (std.mem.eql(u8, a, "--json-stream")) {
            if (headless_mode) |_| {
                std.log.err("--json and --json-stream are mutually exclusive", .{});
                std.process.exit(2);
            }
            headless_mode = .json_stream;
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
            std.log.err("unknown flag", .{});
            try printUsage(io);
            std.process.exit(2);
        } else {
            try prompt_parts.append(arena, a);
        }
    }

    // --tui mode matrix (tui-minimal.md §9.2). Help+tui → 0 no init (except
    // json+help keeps existing headless help path). Mutual exclusions exit 2
    // with empty stdout (no silent REPL fallback).
    if (want_tui) {
        if (headless_mode != null) {
            std.log.err("--tui is mutually exclusive with --json/--json-stream", .{});
            std.process.exit(2);
        }
        if (want_doctor) {
            std.log.err("--tui is mutually exclusive with --doctor", .{});
            std.process.exit(2);
        }
        if (verbose) {
            std.log.err("--tui is mutually exclusive with --verbose/-v", .{});
            std.process.exit(2);
        }
        if (prompt_parts.items.len > 0) {
            std.log.err("--tui is an interactive shell only (no positional prompt)", .{});
            std.process.exit(2);
        }
        if (!tui_enabled) {
            std.log.err("TUI unavailable (binary built without -Dtui=true)", .{});
            std.process.exit(2);
        }
    }

    if (show_help) {
        if (headless_mode) |_| {
            try printUsageToStderr(io);
        } else {
            try printUsage(io);
        }
        return;
    }

    // Argument validation (session path semantics) runs for every product path,
    // including `--doctor`, before any doctor/provider work. Validation does not
    // open or create session files.
    if (session_path) |sp| {
        coding.session_store.validateSessionPath(sp) catch {
            std.log.err("session path must be a relative workspace path (no absolute/'..')", .{});
            std.process.exit(2);
        };
    }

    // h-doctor-001: after argument validation, before provider resolve / wire /
    // Agent / session / trace / network. No API key required. Does not mutate policy.
    // Other legal flags/prompt with --doctor are accepted then ignored (P2 UX debt).
    if (want_doctor) {
        if (headless_mode) |_| {
            try runDoctorHeadless(gpa, io, doctorOptionsFromFlags(permission_mode, shell_policy, no_project));
        } else {
            try runDoctor(gpa, io, doctorOptionsFromFlags(permission_mode, shell_policy, no_project));
        }
        return;
    }

    // TUI requires both stdin and stdout TTYs (exit 2, empty stdout).
    if (want_tui) {
        const stdin_tty = Io.File.stdin().isTty(io) catch false;
        const stdout_tty = Io.File.stdout().isTty(io) catch false;
        if (!stdin_tty or !stdout_tty) {
            std.log.err("tui requires a tty on stdin and stdout", .{});
            std.process.exit(2);
        }
    }

    // D-006: -s PATH → create_new; -c → resume_existing.
    // open_or_create is SDK-only and is not selected by CLI flags.

    if (enable_trace and trace_path == null) {
        trace_path = ".zag/traces/latest.jsonl";
    }

    var resolve_result = ai.resolve(gpa, io, init.environ_map, config_path) catch |err| {
        if (headless_mode) |mode| {
            headlessErrorExit(gpa, io, mode, null, resolveErrorToHeadless(err));
        }
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

    const context_defaults = coding.context.Options{};
    const context_opts = coding.context.optionsFromBudget(
        resolve_result.contextCharBudget(context_defaults.max_chars),
        .{
            .max_chars = resolve_result.context_max_chars,
            .max_tail_messages = resolve_result.context_max_tail_messages,
        },
    );

    if (verbose) {
        // h-redact-001: fixed/enum/numeric metadata only — no arbitrary model/provider text.
        var ready_buf: [384]u8 = undefined;
        const ready = formatVerboseStartup(&ready_buf, .{
            .use_stream = use_stream,
            .permission = permission_mode.name(),
            .session_kind = session_kind.name(),
            .remember = remember_writes,
            .shell_policy = shell_policy.name(),
            .wire = resolved.api_style.jsonName(),
            .transport_retries = resolved.config.max_retries,
            .chat_retries = resolve_result.chat_retries,
            .timeout_ms = resolved.config.timeout_ms,
            .view_max_chars = context_opts.max_chars,
        });
        std.log.info("{s}", .{ready});
        if (session_path != null) std.log.info("session: configured", .{});
        if (trace_path != null) std.log.info("trace: enabled", .{});
    }

    const wire = resolved.createWire(gpa, io) catch |err| {
        if (headless_mode) |mode| {
            headlessErrorExit(gpa, io, mode, null, wireErrorToHeadless(err));
        }
        std.log.err("wire adapter init failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    var wire_prov = coding.WireProvider.init(wire, use_stream, true);
    wire_prov.chat_options = resolve_result.chat_options;
    // timeout_ms is enforced by std/curl transports (or rejected); no silent store.
    wire_prov.timeout_ms = resolved.config.timeout_ms;
    if (use_stream and verbose) {
        wire_prov.on_event = streamLogHandler;
        wire_prov.on_event_ctx = null;
    }
    defer wire_prov.deinit();

    // Wire resolved API key into redaction policy without logging the value.
    // Stack-owned slice list lives for Agent.init, which copies secret bytes.
    const secret_slots = [_][]const u8{resolved.config.api_key};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    var headless_writer: hw.HeadlessWriter = undefined;
    var headless_observer: HeadlessObserver = undefined;
    var human_stream = cli_stream.CliStreamStdout.init(gpa, io);
    if (headless_mode) |mode| {
        headless_writer = hw.HeadlessWriter.init(gpa, io, &stdout_writer.interface, mode, null);
        if (mode == .json_stream) {
            headless_observer = .{ .writer = &headless_writer };
        }
    }

    // B2/B6: stack-stable interactive adapter; cancel pointer fixed after Agent.init.
    // TUI ask uses hunk_reviewer=null; TUI yolo uses AutoAccept (never Interactive).
    var interactive_hunk_reviewer: InteractiveHunkReviewer = .{ .io = io, .cancel = null };
    const bound_hunk_reviewer: ?coding.HunkReviewer = if (want_tui)
        (if (permission_mode == .yolo) coding.autoAcceptHunkReviewer() else null)
    else
        resolveHunkReviewer(permission_mode, headless_mode, &interactive_hunk_reviewer);

    // -c → resume_existing; -s without -c → create_new; no path → ephemeral.
    const open_mode = selectOpenMode(continue_session);

    // skills-001 + prompt-templates-001: CLI resolves HOME → user roots; SDK never getenv.
    const skills_enabled = !no_skills;
    const project_skills_trust: coding.ProjectSkillsTrust = if (trust_project_skills) .trusted else .untrusted;
    const user_skills_root: ?[]const u8 = if (skills_enabled)
        try resolveUserSkillsRoot(arena, init.environ_map)
    else
        null;

    const templates_enabled = !no_prompt_templates;
    const project_templates_trust: coding.ProjectTemplatesTrust = if (trust_project_templates) .trusted else .untrusted;
    const user_templates_root: ?[]const u8 = if (templates_enabled)
        try resolveUserTemplatesRoot(arena, init.environ_map)
    else
        null;

    const host_opts: HostResourceOptions = .{
        .skills_enabled = skills_enabled,
        .project_skills_trust = project_skills_trust,
        .user_skills_root = user_skills_root,
        .templates_enabled = templates_enabled,
        .project_templates_trust = project_templates_trust,
        .user_templates_root = user_templates_root,
    };

    // Shared base options (TUI path overrides permission/lifecycle/observer).
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
        .provider_timeout_ms = resolved.config.timeout_ms,
        .model_info = resolve_result.model_info,
        .secrets = &secret_slots,
        .pattern_redaction = true,
        .observer = if (headless_mode == .json_stream)
            headless_observer.asObserver()
        else if (headless_mode == null)
            human_stream.asObserver()
        else
            .none(),
        .hunk_reviewer = bound_hunk_reviewer,
        .post_edit_verifier = null,
    };
    if (resolve_result.max_turns) |mt| {
        agent_opts.max_turns = mt;
    }

    // ── TUI path (comptime-gated so -Dtui=false never types zag-tui) ────────
    // Explicit teardown before process.exit — defers do not run across exit().
    // Order: Guard.deinit (in runTui) → Session.deinit (in runTui) → Agent → App last.
    if (comptime tui_enabled) {
        if (want_tui) {
            const app = tui_entry.App.create(gpa) catch {
                std.log.err("tui: preallocate failed", .{});
                std.process.exit(1);
            };

            agent_opts.permission_gate = if (permission_mode == .yolo)
                coding.permissions.Gate.yolo()
            else
                coding.permissions.Gate.ask(tui_entry.App.askFn, app);
            agent_opts.lifecycle = app.lifecycleObserver();
            agent_opts.observer = app.observer();
            // TUI ask: hunk_reviewer already null; yolo: AutoAccept (bound above).

            var agent = coding.Agent.init(gpa, io, wire_prov.asProvider(), agent_opts) catch {
                std.log.err("agent init failed (out of memory)", .{});
                app.destroy();
                std.process.exit(1);
            };

            var sigint_guard = sigint.Guard.install(&agent.cancel) catch {
                std.log.err("sigint guard init failed", .{});
                agent.deinit();
                app.destroy();
                std.process.exit(1);
            };
            const tui_host_opts: tui_entry.HostResourceOptions = .{
                .skills_enabled = host_opts.skills_enabled,
                .project_skills_trust = host_opts.project_skills_trust,
                .user_skills_root = host_opts.user_skills_root,
                .templates_enabled = host_opts.templates_enabled,
                .project_templates_trust = host_opts.project_templates_trust,
                .user_templates_root = host_opts.user_templates_root,
            };
            const result = tui_entry.runTui(.{
                .gpa = gpa,
                .io = io,
                .app = app,
                .agent = &agent,
                .guard = &sigint_guard,
                .session_path = session_path,
                .open_mode = open_mode,
                .load_project = !no_project,
                .host_opts = tui_host_opts,
                .base_system = default_system,
                .permission_label = permission_mode.name(),
                .shell_label = shell_policy.name(),
            });
            // Guard + Session already freed inside runTui. Explicit Agent then App.
            agent.deinit();
            app.destroy();
            std.process.exit(result.exit_code);
        }
    }

    var agent = coding.Agent.init(gpa, io, wire_prov.asProvider(), agent_opts) catch {
        if (headless_mode) |mode| {
            headlessErrorExit(gpa, io, mode, null, .{ .code = .out_of_memory, .message = "agent init failed" });
        }
        std.log.err("agent init failed (out of memory)", .{});
        std.process.exit(1);
    };
    defer agent.deinit();
    // Progressive human CLI: redact deltas with the agent-owned redactor.
    human_stream.setRedactor(agent.activeRedactor());
    // Wire cancel only after Agent address is stable (B6 cancel-before-decision → reject).
    interactive_hunk_reviewer.cancel = &agent.cancel;
    // cli-sigint-001: CLI owns the SIGINT handler.
    var sigint_guard = sigint.Guard.install(&agent.cancel) catch {
        if (headless_mode) |mode| {
            headlessErrorExit(gpa, io, mode, null, .{ .code = .trace_error, .message = "sigint guard init failed" });
        }
        std.log.err("sigint guard init failed", .{});
        std.process.exit(1);
    };
    defer sigint_guard.deinit();

    if (headless_mode) |mode| {
        if (prompt_parts.items.len == 0) {
            std.log.err("headless mode requires a prompt", .{});
            std.process.exit(2);
        }
        const prompt = try std.mem.join(arena, " ", prompt_parts.items);
        try runOneShotHeadless(gpa, io, &agent, prompt, session_path, open_mode, !no_project, host_opts, mode, &headless_writer);
        return;
    }

    if (prompt_parts.items.len > 0) {
        const prompt = try std.mem.join(arena, " ", prompt_parts.items);
        try runOneShot(&agent, prompt, verbose, session_path, open_mode, !no_project, host_opts, &human_stream);
        return;
    }

    try runRepl(&agent, io, permission_mode, session_path, open_mode, !no_project, host_opts, &sigint_guard, &human_stream);
}

const HostResourceOptions = struct {
    skills_enabled: bool = true,
    project_skills_trust: coding.ProjectSkillsTrust = .untrusted,
    user_skills_root: ?[]const u8 = null,
    templates_enabled: bool = true,
    project_templates_trust: coding.ProjectTemplatesTrust = .untrusted,
    user_templates_root: ?[]const u8 = null,
};

/// CLI-only: `$HOME/.agents/skills` when HOME is set; missing HOME → no user root.
/// Allocation failure is hard `error.OutOfMemory` (fail closed/visible), not a
/// silent null that leaves skills_enabled true without a user root.
fn resolveUserSkillsRoot(arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{OutOfMemory}!?[]const u8 {
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}/.agents/skills", .{home});
}

/// CLI-only: `$HOME/.agents/prompts` when HOME is set; missing HOME → no user root.
/// Allocation failure is hard `error.OutOfMemory` (fail closed/visible).
fn resolveUserTemplatesRoot(arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{OutOfMemory}!?[]const u8 {
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}/.agents/prompts", .{home});
}

/// Pure open-mode decision for CLI flags.
/// `-c` / `--continue` → resume_existing; otherwise create_new (`-s PATH` create, or ephemeral).
/// `open_or_create` is never selected by CLI flags (SDK convenience only).
pub fn selectOpenMode(continue_session: bool) coding.OpenMode {
    return if (continue_session) .resume_existing else .create_new;
}

/// Build doctor options from already-parsed flags (wired into `run`; report only).
pub fn doctorOptionsFromFlags(
    permission: coding.permissions.Mode,
    shell_policy: coding.shell_policy.Mode,
    no_project: bool,
) coding.doctor.Options {
    return .{
        .permission = permission,
        .shell_policy = shell_policy,
        .load_project_instructions = !no_project,
    };
}

fn runDoctor(gpa: std.mem.Allocator, io: Io, opts: coding.doctor.Options) !void {
    const report = coding.doctor.collect(gpa, io, Io.Dir.cwd(), opts);
    var buf: [coding.doctor.report_buf_len]u8 = undefined;
    const text = coding.doctor.formatReport(&buf, report) catch {
        std.log.err("doctor report format failed", .{});
        std.process.exit(1);
    };
    try writeStdout(io, text);
}

test "CLI selectOpenMode: -s is create_new, -c is resume_existing" {
    // -s PATH alone (or no session flags) → create_new
    try std.testing.expectEqual(coding.OpenMode.create_new, selectOpenMode(false));
    // -c / --continue → resume_existing
    try std.testing.expectEqual(coding.OpenMode.resume_existing, selectOpenMode(true));
}

test "doctorOptionsFromFlags reports explicit selections without side effects" {
    const def = doctorOptionsFromFlags(.ask, .protect, false);
    try std.testing.expectEqual(coding.permissions.Mode.ask, def.permission);
    try std.testing.expectEqual(coding.shell_policy.Mode.protect, def.shell_policy);
    try std.testing.expect(def.load_project_instructions);

    const expl = doctorOptionsFromFlags(.yolo, .off, true);
    try std.testing.expectEqual(coding.permissions.Mode.yolo, expl.permission);
    try std.testing.expectEqual(coding.shell_policy.Mode.off, expl.shell_policy);
    try std.testing.expect(!expl.load_project_instructions);
}

test "resolveUserSkillsRoot: HOME path; empty/missing null; alloc OOM hard-fails" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    // Missing HOME → no user root (not an error).
    try std.testing.expect((try resolveUserSkillsRoot(gpa, &env)) == null);

    try env.put("HOME", "");
    try std.testing.expect((try resolveUserSkillsRoot(gpa, &env)) == null);

    try env.put("HOME", "/tmp/home-test");
    const root = (try resolveUserSkillsRoot(gpa, &env)).?;
    defer gpa.free(root);
    try std.testing.expectEqualStrings("/tmp/home-test/.agents/skills", root);

    // Configured user-root construction OOM must fail closed, not silent null.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolveUserSkillsRoot(failing.allocator(), &env));
}

test "resolveUserTemplatesRoot: HOME path; empty/missing null; alloc OOM hard-fails" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try std.testing.expect((try resolveUserTemplatesRoot(gpa, &env)) == null);

    try env.put("HOME", "");
    try std.testing.expect((try resolveUserTemplatesRoot(gpa, &env)) == null);

    try env.put("HOME", "/tmp/home-test");
    const root = (try resolveUserTemplatesRoot(gpa, &env)).?;
    defer gpa.free(root);
    try std.testing.expectEqualStrings("/tmp/home-test/.agents/prompts", root);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, resolveUserTemplatesRoot(failing.allocator(), &env));
}

fn runOneShot(
    agent: *coding.Agent,
    prompt: []const u8,
    verbose: bool,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
    host_opts: HostResourceOptions,
    stream: *cli_stream.CliStreamStdout,
) !void {
    // skills-001 + prompt-templates-001: expand before reply; local errors → no provider.
    var session = coding.Session.start(agent.gpa, agent.io, .{
        .base_system = default_system,
        .path = session_path,
        .open_mode = open_mode,
        .load_project_instructions = load_project,
        .redactor = agent.activeRedactor(),
        .skills_enabled = host_opts.skills_enabled,
        .project_skills_trust = host_opts.project_skills_trust,
        .user_skills_root = host_opts.user_skills_root,
        .templates_enabled = host_opts.templates_enabled,
        .project_templates_trust = host_opts.project_templates_trust,
        .user_templates_root = host_opts.user_templates_root,
    }) catch |err| {
        std.log.err("session failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    const user_text = resolvePromptRouted(agent.gpa, &session, prompt) catch |err| {
        logRouteError(err);
        std.process.exit(1);
    };
    defer if (user_text.owned) agent.gpa.free(user_text.text);

    const result = agent.reply(&session, user_text.text) catch |err| {
        std.log.err("agent failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

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

    try stream.finishReply(result.final_text);
}

const ResolvedPrompt = struct {
    text: []const u8,
    owned: bool,
};

const RouteError = coding.SkillActivationError || coding.TemplateExpansionError;

/// Host routing precedence (prompt-templates.md §6.2 / skills.md):
/// 1. exact `/skill:` form → skill expand or UnknownSkill local error
/// 2. else known `/name` in template catalog → one-pass expand
/// 3. else raw user text (including unknown slash)
fn resolvePromptRouted(
    gpa: std.mem.Allocator,
    session: *const coding.Session,
    prompt: []const u8,
) RouteError!ResolvedPrompt {
    if (coding.parseSkillCommand(prompt)) |cmd| {
        const act = try coding.expandSkillActivation(gpa, session, cmd.name, cmd.rest);
        return .{ .text = act.user_text, .owned = true };
    }
    if (coding.parseTemplateCommand(prompt)) |cmd| {
        if (session.templates_enabled and session.templates_catalog.find(cmd.name) != null) {
            const exp = try coding.expandTemplate(gpa, session, cmd.name, cmd.rest);
            return .{ .text = exp.user_text, .owned = true };
        }
    }
    return .{ .text = prompt, .owned = false };
}

fn logRouteError(err: RouteError) void {
    switch (err) {
        error.UnknownSkill => std.log.err("unknown skill", .{}),
        error.UnknownTemplate => std.log.err("unknown template", .{}),
        error.ArgumentsTooLarge => std.log.err("template arguments too large", .{}),
        error.ExpansionTooLarge => std.log.err("template expansion too large", .{}),
        error.OutOfMemory => std.log.err("slash expansion failed: OutOfMemory", .{}),
    }
}

const ReplInput = union(enum) {
    text: []const u8,
    explicit_empty,
    eof,
};

/// Reads and classifies one submitted REPL line. `takeDelimiter` consumes the
/// newline so a persistent reader advances to the next user turn.
fn readReplInput(reader: *Io.Reader) !ReplInput {
    const line = (try reader.takeDelimiter('\n')) orelse return .eof;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return if (trimmed.len == 0) .explicit_empty else .{ .text = trimmed };
}

test "REPL input consumes delimiters across two turns before explicit empty" {
    var reader: Io.Reader = .fixed("first\nsecond\n\n");

    switch (try readReplInput(&reader)) {
        .text => |text| try std.testing.expectEqualStrings("first", text),
        else => return error.TestUnexpectedResult,
    }
    switch (try readReplInput(&reader)) {
        .text => |text| try std.testing.expectEqualStrings("second", text),
        else => return error.TestUnexpectedResult,
    }
    switch (try readReplInput(&reader)) {
        .explicit_empty => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try readReplInput(&reader)) {
        .eof => {},
        else => return error.TestUnexpectedResult,
    }
}

test "REPL input trims spaces tabs and CRLF" {
    var reader: Io.Reader = .fixed(" \t first turn \t\r\n\t \r\n");

    switch (try readReplInput(&reader)) {
        .text => |text| try std.testing.expectEqualStrings("first turn", text),
        else => return error.TestUnexpectedResult,
    }
    switch (try readReplInput(&reader)) {
        .explicit_empty => {},
        else => return error.TestUnexpectedResult,
    }
}

test "REPL input classifies immediate EOF" {
    var reader: Io.Reader = .fixed("");
    switch (try readReplInput(&reader)) {
        .eof => {},
        else => return error.TestUnexpectedResult,
    }
}

test "REPL input submits final unterminated nonempty bytes then EOF" {
    var reader: Io.Reader = .fixed(" \t final turn \r");

    switch (try readReplInput(&reader)) {
        .text => |text| try std.testing.expectEqualStrings("final turn", text),
        else => return error.TestUnexpectedResult,
    }
    switch (try readReplInput(&reader)) {
        .eof => {},
        else => return error.TestUnexpectedResult,
    }
}

test "REPL input exposes StreamTooLong beyond the 4096-byte reader capacity" {
    var overlong: [4097]u8 = @splat('x');
    var source: Io.Reader = .fixed(&overlong);
    var repl_buf: [4096]u8 = undefined;
    var bounded = source.limited(.unlimited, &repl_buf);

    try std.testing.expectError(error.StreamTooLong, readReplInput(&bounded.interface));
}

fn runRepl(
    agent: *coding.Agent,
    io: Io,
    mode: coding.permissions.Mode,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
    host_opts: HostResourceOptions,
    guard: *sigint.Guard,
    stream: *cli_stream.CliStreamStdout,
) !void {
    try writeStdout(io, "zag (jail + policy + trace, permission=");
    try writeStdout(io, mode.name());
    try writeStdout(io, "). Empty line or Ctrl-D to exit.\n");
    // h-redact-001: generic session/project status only (no raw paths).
    if (session_path != null) {
        try writeStdout(io, "session: configured\n");
    }

    var session = coding.Session.start(agent.gpa, io, .{
        .base_system = default_system,
        .path = session_path,
        .open_mode = open_mode,
        .load_project_instructions = load_project,
        .redactor = agent.activeRedactor(),
        .skills_enabled = host_opts.skills_enabled,
        .project_skills_trust = host_opts.project_skills_trust,
        .user_skills_root = host_opts.user_skills_root,
        .templates_enabled = host_opts.templates_enabled,
        .project_templates_trust = host_opts.project_templates_trust,
        .user_templates_root = host_opts.user_templates_root,
    }) catch |err| {
        std.log.err("session failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    if (session.project_source != null) {
        try writeStdout(io, "project instructions: loaded\n");
    }

    // cli-sigint-001: idle REPL reads are interruptible. We poll stdin and the
    // sigint self-pipe with a bounded timeout so the first SIGINT wakes the
    // blocking read and the direct process exits cleanly with code 0. The
    // self-pipe + poll path is POSIX-only (macOS/Linux), which are the only
    // platforms Zag targets; the guard is inert on others.
    //
    // A persistent LineBuffer retains same-batch stdin bytes across calls so
    // a raw read of "first\nsecond\n" yields "first" then "second" (review
    // item 4), never dropping the second line.
    const stdin_fd = std.posix.STDIN_FILENO;
    var line_state = sigint.LineBuffer.init();

    while (true) {
        try writeStdout(io, "you> ");

        var line_buf: [4096]u8 = undefined;
        const read_out = sigint.readInterruptibleLine(guard, &line_state, stdin_fd, &line_buf, 250) catch |err| {
            std.log.err("repl read failed: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        const user_text: []const u8 = switch (read_out) {
            .interrupted => {
                try writeStdout(io, "\n");
                break;
            },
            .eof => {
                try writeStdout(io, "\n");
                break;
            },
            .line => |l| std.mem.trim(u8, l, " \t\r"),
        };
        if (user_text.len == 0) break;

        // skills-001 + prompt-templates-001: route slash expand before reply.
        const reply_text = resolvePromptRouted(agent.gpa, &session, user_text) catch |err| {
            switch (err) {
                error.UnknownSkill => try writeStdout(io, "unknown skill\n"),
                error.UnknownTemplate => try writeStdout(io, "unknown template\n"),
                error.ArgumentsTooLarge => try writeStdout(io, "template arguments too large\n"),
                error.ExpansionTooLarge => try writeStdout(io, "template expansion too large\n"),
                error.OutOfMemory => std.log.err("slash expansion failed: OutOfMemory", .{}),
            }
            continue;
        };
        defer if (reply_text.owned) agent.gpa.free(reply_text.text);

        try writeStdout(io, "zag> ");
        const result = agent.reply(&session, reply_text.text) catch |err| {
            std.log.err("agent failed: {s}", .{@errorName(err)});
            // Acknowledge any SIGINT-driven cancel so the next Ctrl+C works
            // afresh; the flag was cleared at the reply completion boundary.
            guard.acknowledgeCancel();
            try writeStdout(io, "\n");
            continue;
        };

        // Acknowledge the SIGINT-driven cancel now that the run has consumed
        // it (review item 3): the next interaction can use Ctrl+C again. The
        // cancel flag itself was cleared at the reply completion boundary.
        guard.acknowledgeCancel();

        if (agent.options.verbose) {
            agent.logCostSummary();
        }

        try stream.finishReply(result.final_text);
    }

    // Session-end cost line (even without -v) when any usage was recorded.
    agent.logCostSummary();
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn runDoctorHeadless(gpa: std.mem.Allocator, io: Io, opts: coding.doctor.Options) !void {
    const report = coding.doctor.collect(gpa, io, Io.Dir.cwd(), opts);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    var writer = hw.HeadlessWriter.init(gpa, io, &stdout_writer.interface, .json, null);
    defer writer.deinit();
    try writer.writeDoctorReport(report);
    try stdout_writer.flush();
}

fn headlessErrorExit(
    gpa: std.mem.Allocator,
    io: Io,
    mode: hw.HeadlessMode,
    redactor: ?*const coding.redact.Redactor,
    err: hw.HeadlessError,
) noreturn {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    var writer = hw.HeadlessWriter.init(gpa, io, &stdout_writer.interface, mode, redactor);
    defer writer.deinit();
    writer.writeError(err) catch {};
    stdout_writer.flush() catch {};
    std.process.exit(err.code.exitCode());
}

fn runOneShotHeadless(
    gpa: std.mem.Allocator,
    io: Io,
    agent: *coding.Agent,
    prompt: []const u8,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
    host_opts: HostResourceOptions,
    mode: hw.HeadlessMode,
    writer: *hw.HeadlessWriter,
) noreturn {
    _ = io;
    writer.setRedactor(agent.activeRedactor());

    if (mode == .json_stream) {
        writer.emitRunStart(coding.version, agent.options.permission_mode.name(), agent.options.shell_policy.name()) catch |err| {
            writer.flush() catch {};
            std.process.exit(if (err == error.OutOfMemory) 40 else 60);
        };
    }

    // skills-001 + prompt-templates-001: expand before reply; local error → no provider.
    // Headless schemas unchanged — expansion becomes ordinary user text.
    var session = coding.Session.start(gpa, agent.io, .{
        .base_system = default_system,
        .path = session_path,
        .open_mode = open_mode,
        .load_project_instructions = load_project,
        .redactor = agent.activeRedactor(),
        .skills_enabled = host_opts.skills_enabled,
        .project_skills_trust = host_opts.project_skills_trust,
        .user_skills_root = host_opts.user_skills_root,
        .templates_enabled = host_opts.templates_enabled,
        .project_templates_trust = host_opts.project_templates_trust,
        .user_templates_root = host_opts.user_templates_root,
    }) catch |err| {
        const he = replyErrorToHeadless(err);
        const code = replyErrorExitCode(err);
        if (mode == .json or (mode == .json_stream and !writer.hasTerminal())) {
            writer.writeError(he) catch {};
        }
        writer.flush() catch {};
        std.process.exit(code);
    };
    defer session.deinit();

    const user_text = resolvePromptRouted(gpa, &session, prompt) catch |err| {
        const he: hw.HeadlessError = switch (err) {
            error.UnknownSkill => .{ .code = .session_invalid, .message = "Unknown skill." },
            error.UnknownTemplate => .{ .code = .session_invalid, .message = "Unknown template." },
            error.ArgumentsTooLarge => .{ .code = .session_invalid, .message = "Template arguments too large." },
            error.ExpansionTooLarge => .{ .code = .session_invalid, .message = "Template expansion too large." },
            error.OutOfMemory => .{ .code = .out_of_memory, .message = "Out of memory." },
        };
        if (mode == .json or (mode == .json_stream and !writer.hasTerminal())) {
            writer.writeError(he) catch {};
        }
        writer.flush() catch {};
        std.process.exit(he.code.exitCode());
    };
    defer if (user_text.owned) gpa.free(user_text.text);

    const loop_result = agent.reply(&session, user_text.text) catch |err| {
        const he = replyErrorToHeadless(err);
        const code = replyErrorExitCode(err);
        if (mode == .json or (mode == .json_stream and !writer.hasTerminal())) {
            writer.writeError(he) catch {};
        }
        writer.flush() catch {};
        std.process.exit(code);
    };
    const owned = gpa.dupe(u8, loop_result.final_text) catch {
        const he = hw.HeadlessError{ .code = .out_of_memory, .message = "Out of memory." };
        writer.writeError(he) catch {};
        writer.flush() catch {};
        std.process.exit(40);
    };
    const result = coding.OwnedResult{
        .final_text = owned,
        .turns = loop_result.turns,
        .usage = loop_result.usage,
        .stop_reason = loop_result.stop_reason,
    };
    defer result.deinit(agent.gpa);

    if (mode == .json) {
        writer.writeResult(result) catch |err| {
            writer.flush() catch {};
            std.process.exit(if (err == error.OutOfMemory) 40 else 60);
        };
    } else if (writer.isHalted()) {
        // Stream observer halted mid-run (JSON/write OOM). Agent may still
        // succeed; contract requires exactly one terminal — emit the halt error.
        const he = writer.haltError() orelse hw.HeadlessError{
            .code = .trace_error,
            .message = "Headless stream halted.",
        };
        writer.writeError(he) catch {};
        writer.flush() catch {};
        std.process.exit(he.code.exitCode());
    } else {
        writer.writeRunEnd(result) catch |err| {
            writer.flush() catch {};
            std.process.exit(if (err == error.OutOfMemory) 40 else 60);
        };
    }
    writer.flush() catch {};
    std.process.exit(hw.exitCodeForStopReason(result.stop_reason));
}

fn resolveErrorToHeadless(err: anyerror) hw.HeadlessError {
    return switch (err) {
        error.MissingApiKey => .{ .code = .provider_configuration, .message = "Missing API key." },
        error.UnknownProvider => .{ .code = .provider_configuration, .message = "Unknown provider." },
        error.MissingBaseUrl => .{ .code = .provider_configuration, .message = "Missing base URL for custom endpoint." },
        error.UnsupportedApiStyle => .{ .code = .provider_configuration, .message = "Unsupported API style." },
        error.OutOfMemory => .{ .code = .out_of_memory, .message = "Out of memory." },
        else => .{ .code = .provider_configuration, .message = "Provider configuration failed." },
    };
}

fn wireErrorToHeadless(err: ai.WireError) hw.HeadlessError {
    return switch (err) {
        error.OutOfMemory => .{ .code = .out_of_memory, .message = "Out of memory." },
        error.AuthenticationFailed => .{ .code = .provider_configuration, .message = "Provider authentication configuration failed." },
        else => .{ .code = .provider_error, .message = "Provider wire initialization failed." },
    };
}

fn replyErrorToHeadless(err: coding.agent.ReplyError) hw.HeadlessError {
    return switch (err) {
        error.ProviderFailed => .{ .code = .provider_error, .message = "Provider request failed." },
        error.TraceFailed => .{ .code = .trace_error, .message = "Trace persistence failed." },
        error.OutOfMemory => .{ .code = .out_of_memory, .message = "Out of memory." },
        error.InvalidToolset => .{ .code = .invalid_toolset, .message = "Toolset validation failed." },
        error.InvalidContext => .{ .code = .invalid_context, .message = "Context validation failed." },
        error.MaxTurnsExceeded => .{ .code = .provider_error, .message = "Max turns exceeded." },
        error.SessionNotFound => .{ .code = .session_not_found, .message = "Session not found." },
        error.SessionAlreadyExists => .{ .code = .session_already_exists, .message = "Session already exists." },
        error.InvalidSession => .{ .code = .session_invalid, .message = "Session invalid." },
        error.UnsupportedSchema => .{ .code = .session_unsupported_schema, .message = "Session schema unsupported." },
        error.SessionBusy => .{ .code = .session_busy, .message = "Session busy." },
        error.IoFailed => .{ .code = .session_io_failed, .message = "Session I/O failed." },
        error.InvalidPath => .{ .code = .session_invalid, .message = "Session path invalid." },
        error.TraceIoFailed => .{ .code = .trace_error, .message = "Trace I/O failed." },
        error.TraceSerializationFailed => .{ .code = .trace_error, .message = "Trace serialization failed." },
    };
}

fn replyErrorExitCode(err: coding.agent.ReplyError) u8 {
    return switch (err) {
        error.ProviderFailed => 31,
        error.TraceFailed => 60,
        error.OutOfMemory => 40,
        error.InvalidToolset => 32,
        error.InvalidContext => 33,
        error.MaxTurnsExceeded => 10,
        error.SessionNotFound => 50,
        error.SessionAlreadyExists => 51,
        error.InvalidSession => 52,
        error.UnsupportedSchema => 53,
        error.SessionBusy => 54,
        error.IoFailed => 55,
        error.InvalidPath => 52,
        error.TraceIoFailed => 60,
        error.TraceSerializationFailed => 60,
    };
}

/// Generic CLI validation messages (never echo the invalid argv token).
pub fn invalidPermissionModeMessage() []const u8 {
    return "unknown permission mode";
}

pub fn invalidShellPolicyMessage() []const u8 {
    return "unknown shell policy";
}

pub const VerboseStartupInfo = struct {
    use_stream: bool,
    permission: []const u8,
    session_kind: []const u8,
    remember: bool,
    shell_policy: []const u8,
    wire: []const u8,
    transport_retries: u8,
    chat_retries: u8,
    timeout_ms: ?u64,
    view_max_chars: usize,
};

/// Pure verbose startup formatter (enum/numeric/generic only — no model/key/path).
pub fn formatVerboseStartup(buf: []u8, info: VerboseStartupInfo) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "provider ready stream={any} permission={s} session_kind={s} remember={any} shell_policy={s} wire={s} transport_retries={d} chat_retries={d} timeout_ms={any} view_max_chars={d}",
        .{
            info.use_stream,
            info.permission,
            info.session_kind,
            info.remember,
            info.shell_policy,
            info.wire,
            info.transport_retries,
            info.chat_retries,
            info.timeout_ms,
            info.view_max_chars,
        },
    ) catch "provider ready";
}

/// Pure stream diagnostic formatter used by `streamLogHandler`.
/// Fixed/numeric only — never raw chunk bytes (secrets may span SSE chunks).
pub fn formatStreamLogEvent(buf: []u8, event: ai.StreamEvent) ?[]const u8 {
    return switch (event) {
        .content_delta => |d| {
            if (d.len == 0) return null;
            return std.fmt.bufPrint(buf, "stream content_delta bytes={d}", .{d.len}) catch null;
        },
        .finish_reason => std.fmt.bufPrint(buf, "stream finish_reason", .{}) catch null,
        .tool_call_delta => |tc| std.fmt.bufPrint(buf, "stream tool_call_delta index={d}", .{tc.index}) catch null,
        .done => std.fmt.bufPrint(buf, "stream done", .{}) catch null,
    };
}

/// Verbose stream diagnostics: fixed/numeric events only (never raw chunk bytes;
/// secrets may span SSE chunks so per-chunk redaction is insufficient).
fn streamLogHandler(_: ?*anyopaque, event: ai.StreamEvent) anyerror!void {
    var buf: [96]u8 = undefined;
    if (formatStreamLogEvent(&buf, event)) |line| {
        std.log.info("{s}", .{line});
    }
}

fn printUsage(io: Io) !void {
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
        \\  --doctor                   readiness report (no API key / provider / network)
        \\  --json                     headless one-shot: single JSON result envelope
        \\  --json-stream              headless one-shot: NDJSON event stream
        \\  --tui                      minimal interactive TUI (requires -Dtui=true build; TTY)
        \\  -s, --session PATH         create session at PATH (fails if exists; relative only)
        \\  -c, --continue             resume session (default PATH .zag/sessions/default.jsonl)
        \\  --no-project               skip AGENTS.md injection
        \\  --no-skills                disable Agent Skills discovery (user + project)
        \\  --trust-project-skills     allow <workspace>/.agents/skills discovery
        \\  --no-prompt-templates      disable Prompt Templates discovery (user + project)
        \\  --trust-project-templates  allow <workspace>/.agents/prompts discovery
        \\  --trace                    write run trace (.zag/traces/latest.jsonl)
        \\  --trace=PATH / --trace PATH  same, with explicit path (.jsonl or path-like)
        \\                             (bare words after --trace are treated as prompt)
        \\  --stream                   SSE streaming completions
        \\  --config PATH              JSON config (.zag/config.json also auto-loaded)
        \\
        \\Tools: list_dir, read_file, grep, glob, search_replace, write_file, run_shell
        \\  (+ read_skill when Skills are discovered)
        \\Skills: /skill:<name> [rest] expands once before reply (manual activation)
        \\Templates: /name [args] expands once when discovered (after /skill: precedence)
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
        \\            (+ zag-tui when -Dtui=true)
        \\
    ;
    try Io.File.stdout().writeStreamingAll(io, usage);
}

fn printUsageToStderr(io: Io) !void {
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
        \\  --doctor                   readiness report (no API key / provider / network)
        \\  --json                     headless one-shot: single JSON result envelope
        \\  --json-stream              headless one-shot: NDJSON event stream
        \\  --tui                      minimal interactive TUI (requires -Dtui=true build; TTY)
        \\  -s, --session PATH         create session at PATH (fails if exists; relative only)
        \\  -c, --continue             resume session (default PATH .zag/sessions/default.jsonl)
        \\  --no-project               skip AGENTS.md injection
        \\  --no-skills                disable Agent Skills discovery (user + project)
        \\  --trust-project-skills     allow <workspace>/.agents/skills discovery
        \\  --no-prompt-templates      disable Prompt Templates discovery (user + project)
        \\  --trust-project-templates  allow <workspace>/.agents/prompts discovery
        \\  --trace                    write run trace (.zag/traces/latest.jsonl)
        \\  --trace=PATH / --trace PATH  same, with explicit path (.jsonl or path-like)
        \\                             (bare words after --trace are treated as prompt)
        \\  --stream                   SSE streaming completions
        \\  --config PATH              JSON config (.zag/config.json also auto-loaded)
        \\
        \\Tools: list_dir, read_file, grep, glob, search_replace, write_file, run_shell
        \\  (+ read_skill when Skills are discovered)
        \\Skills: /skill:<name> [rest] expands once before reply (manual activation)
        \\Templates: /name [args] expands once when discovered (after /skill: precedence)
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
        \\            (+ zag-tui when -Dtui=true)
        \\
    ;
    try Io.File.stderr().writeStreamingAll(io, usage);
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

test "invalid permission/shell-policy messages are generic" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    try std.testing.expectEqualStrings("unknown permission mode", invalidPermissionModeMessage());
    try std.testing.expectEqualStrings("unknown shell policy", invalidShellPolicyMessage());
    // Helpers must not interpolate argv; secret fixtures never appear.
    try std.testing.expect(std.mem.indexOf(u8, invalidPermissionModeMessage(), secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, invalidShellPolicyMessage(), secret) == null);
}

test "formatVerboseStartup uses enums/numerics only even with secret fixtures" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const model = "gpt-secret-" ++ secret;
    const path = ".zag/sessions/" ++ secret ++ ".jsonl";
    _ = model;
    _ = path;
    var buf: [384]u8 = undefined;
    const out = formatVerboseStartup(&buf, .{
        .use_stream = true,
        .permission = "ask",
        .session_kind = "agent",
        .remember = true,
        .shell_policy = "protect",
        .wire = "openai_compat",
        .transport_retries = 2,
        .chat_retries = 1,
        .timeout_ms = 5000,
        .view_max_chars = 8000,
    });
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "permission=ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_policy=protect") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "view_max_chars=8000") != null);
}

test "formatStreamLogEvent emits kind/length/index only" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    // Cross-chunk fake token: content may contain secret material; formatter uses length only.
    const chunk_a = secret[0 .. secret.len / 2];
    const chunk_b = secret[secret.len / 2 ..];
    var buf: [96]u8 = undefined;
    const a = formatStreamLogEvent(&buf, .{ .content_delta = chunk_a }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, a, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, a, chunk_a) == null);
    try std.testing.expect(std.mem.indexOf(u8, a, "content_delta") != null);
    const b = formatStreamLogEvent(&buf, .{ .content_delta = chunk_b }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, b, chunk_b) == null);
    const fr = formatStreamLogEvent(&buf, .{ .finish_reason = "stop" }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("stream finish_reason", fr);
    try std.testing.expect(std.mem.indexOf(u8, fr, "stop") == null);
    const tc = formatStreamLogEvent(&buf, .{
        .tool_call_delta = .{ .index = 3, .id = secret, .name = "run_" ++ secret, .arguments_delta = secret },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tc, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, tc, "index=3") != null);
    const done = formatStreamLogEvent(&buf, .done) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("stream done", done);
}

test "edit-sharp §10.6 B2 reviewer bind precedence yolo autoaccept headless" {
    const io = std.testing.io;
    var interactive: InteractiveHunkReviewer = .{ .io = io, .cancel = null };

    // yolo + no headless → AutoAccept (bound; no stderr UI from AutoAccept itself)
    const yolo = resolveHunkReviewer(.yolo, null, &interactive);
    try std.testing.expect(yolo != null);
    try std.testing.expect(yolo.?.reviewFn(null, .{
        .path = "p",
        .expected_sha256 = "0" ** 64,
        .old_len = 1,
        .new_len = 1,
        .preview_text = "x",
    }) == .accept);
    try std.testing.expectEqual(@as(u32, 0), interactive.stderr_writes);

    // yolo + json headless → still AutoAccept (no null; no review UI on stdout path)
    const yolo_json = resolveHunkReviewer(.yolo, .json, &interactive);
    try std.testing.expect(yolo_json != null);
    try std.testing.expect(yolo_json.?.reviewFn(null, .{
        .path = "p",
        .expected_sha256 = "0" ** 64,
        .old_len = 1,
        .new_len = 1,
        .preview_text = "x",
    }) == .accept);

    // yolo + json_stream → AutoAccept
    const yolo_stream = resolveHunkReviewer(.yolo, .json_stream, &interactive);
    try std.testing.expect(yolo_stream != null);

    // ask + headless → null (review_unavailable if handler reached)
    const ask_json = resolveHunkReviewer(.ask, .json, &interactive);
    try std.testing.expect(ask_json == null);
    const ask_stream = resolveHunkReviewer(.ask, .json_stream, &interactive);
    try std.testing.expect(ask_stream == null);

    // ask + non-headless: depends on TTY; if non-TTY in test, null is correct fail-closed.
    const ask_human = resolveHunkReviewer(.ask, null, &interactive);
    if (ask_human) |r| {
        _ = r;
        try std.testing.expect(interactive.cancel == null);
    }
}

test "edit-sharp decideHunkReviewLine EOF accept reject matrix" {
    try std.testing.expect(decideHunkReviewLine(null) == .reject);
    try std.testing.expect(decideHunkReviewLine("") == .reject);
    try std.testing.expect(decideHunkReviewLine("   ") == .reject);
    try std.testing.expect(decideHunkReviewLine("n") == .reject);
    try std.testing.expect(decideHunkReviewLine("no") == .reject);
    try std.testing.expect(decideHunkReviewLine("maybe") == .reject);
    try std.testing.expect(decideHunkReviewLine("y") == .accept);
    try std.testing.expect(decideHunkReviewLine("Y") == .accept);
    try std.testing.expect(decideHunkReviewLine("yes") == .accept);
    try std.testing.expect(decideHunkReviewLine("YES") == .accept);
    try std.testing.expect(decideHunkReviewLine("  yes  ") == .accept);
    try std.testing.expect(decideHunkReviewLine("Yes") == .reject); // only exact y/Y/yes/YES
}

test "edit-sharp InteractiveHunkReviewer rejects on cancel and EOF seam" {
    const io = std.testing.io;
    const preview = coding.HunkReviewPreview{
        .path = "p",
        .expected_sha256 = "0" ** 64,
        .old_len = 0,
        .new_len = 0,
        .preview_text = "preview",
    };

    // Cancel before decision → reject
    {
        var flag: core.cancel.Flag = .{};
        flag.request();
        var interactive: InteractiveHunkReviewer = .{ .io = io, .cancel = &flag };
        const rev = interactive.asReviewer();
        try std.testing.expect(rev.reviewFn(rev.ptr, preview) == .reject);
    }
    // EOF/read-fail seam (null line) → reject via pure helper; stderr used once
    {
        var interactive: InteractiveHunkReviewer = .{
            .io = io,
            .cancel = null,
            .test_use_line = true,
            .test_line = null,
        };
        const rev = interactive.asReviewer();
        try std.testing.expect(rev.reviewFn(rev.ptr, preview) == .reject);
        try std.testing.expect(interactive.stderr_writes >= 1);
    }
    // explicit n → reject; y → accept
    {
        var interactive: InteractiveHunkReviewer = .{
            .io = io,
            .test_use_line = true,
            .test_line = "n",
        };
        const rev = interactive.asReviewer();
        try std.testing.expect(rev.reviewFn(rev.ptr, preview) == .reject);
        interactive.test_line = "y";
        try std.testing.expect(rev.reviewFn(rev.ptr, preview) == .accept);
    }
}
