//! Coding Agent facade — product layer over Agent Core.
//!
//! ```
//! var agent = Agent.init(gpa, io, provider, .{ .permission_mode = .ask });
//! var session = try Session.start(gpa, io, .{ .base_system = sys, .path = "..." });
//! defer session.deinit();
//! const result = try agent.reply(&session, user_text);
//! ```

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const ai = @import("zag-ai");
const toolset_mod = @import("toolset.zig");
const project_mod = @import("project.zig");

const message = core.message;
const tool = core.tool;
const transcript_mod = core.transcript;
const provider_mod = core.provider;
const observer_mod = core.observer;
const permissions = core.permissions;
const context_mod = core.context;
const session_store = core.session_store;
const shell_policy = core.shell_policy;
const trace_mod = core.trace;
const loop = core.loop;
const cancel_mod = core.cancel;

pub const Options = struct {
    max_turns: u32 = loop.default_max_turns,
    verbose: bool = false,
    permission_mode: permissions.Mode = .ask,
    permission_gate: ?permissions.Gate = null,
    /// Session overlay: `plan` blocks general write/shell (H3 stub).
    session_kind: permissions.SessionKind = .agent,
    /// When true (default), approved write paths skip re-prompt in ask mode.
    remember_writes: bool = true,
    context: context_mod.Options = .{},
    shell_policy: shell_policy.Mode = .protect,
    /// Relative path for JSONL run trace; null disables.
    trace_path: ?[]const u8 = null,
    /// Package version string for trace metadata.
    version: []const u8 = "0.5.0",
    /// Loop-level retries on retryable provider errors.
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    /// Catalog row for cost rates / context (from `ai.resolve`); null = no USD estimate.
    model_info: ?ai.ModelInfo = null,
};

pub const OpenMode = enum {
    /// Create a new session file; fail if it already exists.
    create_new,
    /// Resume an existing session; fail if missing, invalid, unsupported, or busy.
    resume_existing,
    /// Resume if present, otherwise create; only `SessionNotFound` triggers creation.
    open_or_create,
};

pub const SessionStartOptions = struct {
    /// Base system prompt (agent identity + tool rules).
    base_system: []const u8,
    /// If set, load/save transcript here (relative to cwd).
    path: ?[]const u8 = null,
    /// Explicit open semantics for the configured path.
    open_mode: OpenMode = .create_new,
    /// Inject AGENTS.md / README into system (default true).
    load_project_instructions: bool = true,
};

pub const StartError = loop.RunError || session_store.Error;
/// Loop + session + explicit-trace errors. `TraceIoFailed` is distinct from session `IoFailed`.
pub const ReplyError = loop.RunError || session_store.Error || trace_mod.Error;

/// One conversation. Owns the transcript arena (heap-stable so Session is movable)
/// and, when persisted, the active writer lease for that path.
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena_impl: *std.heap.ArenaAllocator,
    transcript: transcript_mod.Transcript,
    /// Owned path for auto-save, or null for ephemeral.
    path: ?[]u8 = null,
    /// Active writer lease when `path` is persisted.
    writer: ?session_store.Writer = null,
    /// Base system prompt (owned by session arena).
    base_system: []const u8 = "",
    /// Project instructions body (owned by session arena); empty if none.
    project_body: []const u8 = "",
    /// Which project file was loaded, if any.
    project_source: ?[]const u8 = null,
    compaction_gen: u32 = 0,
    /// Latest compaction summary for the session layer / header (arena-owned).
    compaction_summary: ?[]const u8 = null,
    zag_version: []const u8 = "0.5.0",

    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        opts: SessionStartOptions,
    ) StartError!Session {
        const arena_impl = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_impl.* = .init(gpa);
        errdefer {
            arena_impl.deinit();
            gpa.destroy(arena_impl);
        }
        const arena = arena_impl.allocator();

        var transcript = transcript_mod.Transcript.init(arena);
        var path_owned: ?[]u8 = null;
        errdefer if (path_owned) |p| gpa.free(p);

        if (opts.path) |p| {
            try session_store.validateSessionPath(p);
            path_owned = gpa.dupe(u8, p) catch return error.OutOfMemory;
        }

        const base_owned = arena.dupe(u8, opts.base_system) catch return error.OutOfMemory;
        var project_body: []const u8 = "";
        var project_source: ?[]const u8 = null;
        var compaction_gen: u32 = 0;
        var compaction_summary: ?[]const u8 = null;
        var writer: ?session_store.Writer = null;
        errdefer if (writer) |*w| w.deinit();
        var resumed = false;

        if (opts.path) |p| {
            switch (opts.open_mode) {
                .create_new => {
                    try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
                    writer = try session_store.createNew(gpa, io, Io.Dir.cwd(), p, transcript.items(), .{
                        .schema_version = session_store.current_schema_version,
                        .zag_version = "0.5.0",
                        .compaction_gen = compaction_gen,
                        .compaction_summary = compaction_summary,
                    });
                },
                .resume_existing => {
                    var meta: session_store.SessionMeta = .{};
                    writer = try session_store.resumeExisting(gpa, io, Io.Dir.cwd(), p, &transcript, &meta);
                    compaction_gen = meta.compaction_gen;
                    compaction_summary = meta.compaction_summary;
                    resumed = true;
                },
                .open_or_create => {
                    // SDK convenience: create only after typed not-found; never on parse/schema/I/O.
                    var meta: session_store.SessionMeta = .{};
                    if (session_store.resumeExisting(gpa, io, Io.Dir.cwd(), p, &transcript, &meta)) |w| {
                        writer = w;
                        compaction_gen = meta.compaction_gen;
                        compaction_summary = meta.compaction_summary;
                        resumed = true;
                    } else |err| switch (err) {
                        error.SessionNotFound => {
                            try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
                            writer = try session_store.createNew(gpa, io, Io.Dir.cwd(), p, transcript.items(), .{
                                .schema_version = session_store.current_schema_version,
                                .zag_version = "0.5.0",
                                .compaction_gen = compaction_gen,
                                .compaction_summary = compaction_summary,
                            });
                            // created path: project already seeded; not a resume.
                        },
                        else => |e| return e,
                    }
                },
            }
            // Reload live project file for Layers on resume only.
            if (resumed and opts.load_project_instructions) {
                if (project_mod.load(gpa, io, Io.Dir.cwd()) catch null) |loaded| {
                    defer gpa.free(loaded.body);
                    project_source = loaded.source;
                    project_body = arena.dupe(u8, loaded.body) catch return error.OutOfMemory;
                }
            }
        } else {
            try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
        }

        return finishSession(
            gpa,
            io,
            arena_impl,
            transcript,
            path_owned,
            writer,
            base_owned,
            project_body,
            project_source,
            compaction_gen,
            compaction_summary,
        );
    }

    fn finishSession(
        gpa: std.mem.Allocator,
        io: Io,
        arena_impl: *std.heap.ArenaAllocator,
        transcript: transcript_mod.Transcript,
        path_owned: ?[]u8,
        writer: ?session_store.Writer,
        base_system: []const u8,
        project_body: []const u8,
        project_source: ?[]const u8,
        compaction_gen: u32,
        compaction_summary: ?[]const u8,
    ) Session {
        return .{
            .gpa = gpa,
            .io = io,
            .arena_impl = arena_impl,
            .transcript = transcript,
            .path = path_owned,
            .writer = writer,
            .base_system = base_system,
            .project_body = project_body,
            .project_source = project_source,
            .compaction_gen = compaction_gen,
            .compaction_summary = compaction_summary,
        };
    }

    fn seedNewTranscript(
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        opts: SessionStartOptions,
        project_body: *[]const u8,
        project_source: *?[]const u8,
    ) StartError!void {
        if (opts.load_project_instructions) {
            if (project_mod.load(gpa, io, Io.Dir.cwd()) catch null) |loaded| {
                defer gpa.free(loaded.body);
                project_source.* = loaded.source;
                project_body.* = arena.dupe(u8, loaded.body) catch return error.OutOfMemory;
                // Keep a merged system row for legacy resume / audit; view skips it.
                const composed = project_mod.composeSystemPrompt(gpa, opts.base_system, .{
                    .source = loaded.source,
                    .body = loaded.body,
                }) catch return error.OutOfMemory;
                defer gpa.free(composed);
                try transcript.appendSystem(composed);
                return;
            }
        }
        try transcript.appendSystem(opts.base_system);
    }

    pub fn layers(self: *const Session) context_mod.Layers {
        return .{
            .system = self.base_system,
            .project = self.project_body,
            .session = self.compaction_summary orelse "",
            .ephemeral = "",
        };
    }

    pub fn noteCompaction(self: *Session, event: context_mod.CompactionEvent) void {
        const arena = self.arena_impl.allocator();
        const owned = arena.dupe(u8, event.summary) catch return;
        self.compaction_summary = owned;
        self.compaction_gen += 1;
    }

    pub fn deinit(self: *Session) void {
        if (self.writer) |*w| w.deinit();
        if (self.path) |p| self.gpa.free(p);
        self.arena_impl.deinit();
        self.gpa.destroy(self.arena_impl);
        self.* = undefined;
    }

    /// Persist transcript if a path is configured.
    pub fn save(self: *Session) session_store.Error!void {
        if (self.writer) |*w| {
            try w.save(self.transcript.items(), .{
                .schema_version = session_store.current_schema_version,
                .zag_version = self.zag_version,
                .compaction_gen = self.compaction_gen,
                .compaction_summary = self.compaction_summary,
            });
        }
    }
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: provider_mod.Provider,
    tools_storage: toolset_mod.Phase1Storage,
    options: Options,
    stdin_prompter: permissions.StdinPrompter,
    permission_gate: permissions.Gate,
    remember_store: permissions.Remember,
    /// Owned when options.trace_path is set.
    trace: ?trace_mod.Trace = null,
    /// Session/run cost accumulator (updated on each provider usage event).
    ledger: ai.cost.Ledger = .{},
    /// Cooperative cancel; CLI installs SIGINT against this flag.
    cancel: cancel_mod.Flag = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) Agent {
        var self: Agent = .{
            .gpa = gpa,
            .io = io,
            .provider = provider,
            .tools_storage = .init(),
            .options = options,
            .stdin_prompter = .{ .io = io },
            .permission_gate = .yolo(),
            .remember_store = .init(gpa, options.remember_writes),
            .trace = null,
            .ledger = .{},
            .cancel = .{},
        };
        self.permission_gate = self.resolveGate();
        if (options.trace_path) |tp| {
            self.trace = trace_mod.Trace.init(gpa, io, tp);
        }
        return self;
    }

    /// Release resources only. Never invents a successful `run_end` for an open trace.
    pub fn deinit(self: *Agent) void {
        self.remember_store.deinit();
        if (self.trace) |*tr| {
            tr.deinit();
        }
        self.* = undefined;
    }

    pub fn initPhase0(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) Agent {
        return init(gpa, io, provider, options);
    }

    fn resolveGate(self: *Agent) permissions.Gate {
        var gate: permissions.Gate = if (self.options.permission_gate) |g|
            g
        else switch (self.options.permission_mode) {
            .yolo => permissions.Gate.yolo(),
            .ask => self.stdin_prompter.gate(),
        };
        gate.session_kind = self.options.session_kind;
        self.remember_store.enabled = self.options.remember_writes;
        if (gate.remember == null) {
            gate.remember = &self.remember_store;
        }
        return gate;
    }

    fn deps(self: *Agent, session: *Session) loop.Deps {
        const gate = self.resolveGate();
        return .{
            .gpa = self.gpa,
            .provider = self.provider,
            .toolset = self.tools_storage.toolset(),
            .tool_ctx = .{
                .allocator = self.gpa,
                .io = self.io,
                .cwd = Io.Dir.cwd(),
            },
            .options = .{
                .max_turns = self.options.max_turns,
                .observer = .{
                    .ptr = self,
                    .on_event = onAgentEvent,
                },
                .permission_gate = gate,
                .context = self.options.context,
                .get_layers = sessionLayers,
                .layers_ctx = session,
                .shell_policy = self.options.shell_policy,
                .trace = if (self.trace) |*tr| tr else null,
                .chat_retries = self.options.chat_retries,
                .retry_base_delay_ms = self.options.retry_base_delay_ms,
                .cancel = &self.cancel,
                .on_compaction = onSessionCompaction,
                .compaction_ctx = session,
            },
        };
    }

    fn sessionLayers(ctx: ?*anyopaque) context_mod.Layers {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        return session.layers();
    }

    fn onSessionCompaction(ctx: ?*anyopaque, event: context_mod.CompactionEvent) void {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        session.noteCompaction(event);
    }

    fn onAgentEvent(ptr: ?*anyopaque, event: observer_mod.Event) void {
        const self: *Agent = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .usage => |u| {
                self.ledger.recordModel(u, self.options.model_info);
                if (self.options.verbose) {
                    observer_mod.Observer.stderrLog().emit(event);
                    if (self.ledger.cost.known) {
                        std.log.info("cost est cumulative=${d:.6}", .{self.ledger.cost.total});
                    }
                }
            },
            else => {
                if (self.options.verbose) {
                    observer_mod.Observer.stderrLog().emit(event);
                }
            },
        }
    }

    /// Fail-closed preflight + `run_start` for an explicit/memory trace.
    /// Lifecycle owner: the facade (sees loop result, session save, and flush).
    fn beginRun(self: *Agent, session: *Session) ReplyError!void {
        const tr = if (self.trace) |*t| t else return;
        try tr.preflight();
        if (tr.run_open) return;
        try tr.emitRunStart(.{
            .version = self.options.version,
            .permission = self.options.permission_mode.name(),
            .shell_policy = self.options.shell_policy.name(),
            .session = session.path,
        });
    }

    /// Commit exactly one terminal for the open run. No-op when tracing is off
    /// or the run already closed. Propagates flush I/O as `TraceIoFailed`.
    fn commitTerminal(
        self: *Agent,
        turns: u32,
        ok: bool,
        stop_reason: loop.StopReason,
    ) trace_mod.Error!void {
        const tr = if (self.trace) |*t| t else return;
        if (!tr.run_open) return;
        const usd: ?f64 = if (self.ledger.cost.known) self.ledger.cost.total else null;
        try tr.emitRunEnd(.{
            .turns = turns,
            .ok = ok,
            .prompt_tokens = self.ledger.prompt_tokens,
            .completion_tokens = self.ledger.completion_tokens,
            .total_tokens = self.ledger.total_tokens,
            .estimated_usd = usd,
            .stop_reason = stop_reason.name(),
        });
    }

    /// Best-effort terminal on a primary failure path.
    /// Precedence: keep the original typed error; if flush also fails after a
    /// failure terminal, still return the original error (trace was secondary).
    fn commitTerminalOnError(
        self: *Agent,
        turns: u32,
        stop_reason: loop.StopReason,
    ) void {
        self.commitTerminal(turns, false, stop_reason) catch {};
    }

    fn stopReasonForRunError(err: loop.RunError) loop.StopReason {
        return switch (err) {
            error.ProviderFailed => .provider_error,
            error.TraceFailed => .trace_error,
            error.OutOfMemory, error.InvalidToolset, error.MaxTurnsExceeded => .provider_error,
        };
    }

    fn resultOk(stop: loop.StopReason) bool {
        return switch (stop) {
            .completed, .max_turns, .cancelled => true,
            .provider_error, .session_error, .trace_error => false,
        };
    }

    /// Log session ledger to stderr (no-op when nothing was recorded).
    pub fn logCostSummary(self: *const Agent) void {
        if (self.ledger.turns == 0) return;
        if (self.ledger.cost.known) {
            std.log.info(
                "cost api_calls={d} prompt={d} completion={d} total_tokens={d} est_usd=${d:.6}",
                .{
                    self.ledger.turns,
                    self.ledger.prompt_tokens,
                    self.ledger.completion_tokens,
                    self.ledger.total_tokens,
                    self.ledger.cost.total,
                },
            );
        } else {
            std.log.info(
                "usage api_calls={d} prompt={d} completion={d} total_tokens={d} (no catalog rates)",
                .{
                    self.ledger.turns,
                    self.ledger.prompt_tokens,
                    self.ledger.completion_tokens,
                    self.ledger.total_tokens,
                },
            );
        }
    }

    /// Append a user message, run harness, auto-save session when path set.
    ///
    /// Terminal ownership (h-trace-001):
    /// 1. preflight explicit trace path (fail before provider when possible);
    /// 2. `run_start`;
    /// 3. loop;
    /// 4. session save **before** a successful terminal is committed;
    /// 5. exactly one `run_end` with truthful `ok` / `stop_reason`.
    ///
    /// Flush failure after a successful loop+save → `TraceIoFailed` (no audited success).
    /// Flush failure after provider/session failure → original error preserved.
    pub fn reply(self: *Agent, session: *Session, user_text: []const u8) ReplyError!loop.Result {
        try self.beginRun(session);
        session.zag_version = self.options.version;
        try session.transcript.appendUser(user_text);

        const result = loop.run(self.deps(session), &session.transcript) catch |err| {
            self.commitTerminalOnError(0, stopReasonForRunError(err));
            return err;
        };

        // Save before committing a successful terminal so save failure cannot leave ok=true.
        session.save() catch |err| {
            self.commitTerminalOnError(result.turns, .session_error);
            return err;
        };

        // Final flush on success path: TraceIoFailed is returned (fail closed).
        try self.commitTerminal(result.turns, resultOk(result.stop_reason), result.stop_reason);
        return result;
    }

    /// One-shot: optional session path for durability.
    pub fn complete(
        self: *Agent,
        system_prompt: []const u8,
        user_prompt: []const u8,
    ) ReplyError!OwnedResult {
        return self.completeWithSession(system_prompt, user_prompt, .{});
    }

    pub fn completeWithSession(
        self: *Agent,
        system_prompt: []const u8,
        user_prompt: []const u8,
        session_opts: struct {
            path: ?[]const u8 = null,
            open_mode: OpenMode = .create_new,
            load_project_instructions: bool = true,
        },
    ) ReplyError!OwnedResult {
        var session = try Session.start(self.gpa, self.io, .{
            .base_system = system_prompt,
            .path = session_opts.path,
            .open_mode = session_opts.open_mode,
            .load_project_instructions = session_opts.load_project_instructions,
        });
        defer session.deinit();

        // `reply` owns the single terminal (including flush / failure paths).
        const result = try self.reply(&session, user_prompt);
        const owned = self.gpa.dupe(u8, result.final_text) catch return error.OutOfMemory;
        return .{
            .final_text = owned,
            .turns = result.turns,
            .usage = result.usage,
            .stop_reason = result.stop_reason,
        };
    }
};

pub const OwnedResult = struct {
    final_text: []u8,
    turns: u32,
    usage: message.Usage = .{},
    stop_reason: loop.StopReason = .completed,

    pub fn deinit(self: OwnedResult, gpa: std.mem.Allocator) void {
        gpa.free(self.final_text);
    }
};

pub const Result = loop.Result;
pub const RunError = loop.RunError;
pub const Transcript = transcript_mod.Transcript;
pub const Provider = provider_mod.Provider;
pub const Message = message.Message;
pub const Tool = tool.Tool;
pub const Mode = permissions.Mode;

// ── D-006 facade contract tests ─────────────────────────────────────────────

test "Session.start create_new fails when path exists without seeding overwrite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Use cwd-relative path under a unique subdir so create uses real workspace rules.
    // Session.start always uses Dir.cwd(); write the fixture there and clean up.
    const dir_name = ".zag-test-session-create";
    const path = ".zag-test-session-create/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const original =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"keep-me"}
        \\
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    const err = Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    try std.testing.expectError(error.SessionAlreadyExists, err);

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(raw);
    try std.testing.expectEqualStrings(original, raw);
}

test "Session.start resume_existing distinguishes not-found" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const err = Session.start(gpa, io, .{
        .base_system = "sys",
        .path = ".zag-test-session-missing/nope.jsonl",
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    try std.testing.expectError(error.SessionNotFound, err);
}

test "Session.start rejects absolute session path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const err = Session.start(gpa, io, .{
        .base_system = "sys",
        .path = "/tmp/outside.jsonl",
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    try std.testing.expectError(error.InvalidPath, err);
}

test "Session.start open_or_create creates then resumes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-session-ooc";
    const path = ".zag-test-session-ooc/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var s = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .open_or_create,
            .load_project_instructions = false,
        });
        defer s.deinit();
        try std.testing.expect(s.writer != null);
        try s.transcript.appendUser("hello");
        try s.save();
    }

    var s2 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .open_or_create,
        .load_project_instructions = false,
    });
    defer s2.deinit();
    // Resumed transcript has system + user.
    try std.testing.expect(s2.transcript.items().len >= 2);
}

test "Session.save is no-op for ephemeral session without writer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var s = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer s.deinit();
    try s.save();
}

test "Agent.reply save failure returns IoFailed and preserves session bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-session-reply-save";
    const path = ".zag-test-session-reply-save/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    const original = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(original);
    try std.testing.expect(original.len > 0);

    // Per-Writer test-only fault: fail after temp write, before replace.
    const writer = if (session.writer) |*w| w else return error.TestUnexpectedResult;
    session_store.testing.setFailBeforeReplace(writer, true);

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock_state: u8 = 0;
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };

    var agent = Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();

    const reply_err = agent.reply(&session, "hello");
    try std.testing.expectError(error.IoFailed, reply_err);

    const after = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);

    // Prior bytes remain loadable via the held Writer (load does not re-acquire the lock).
    session_store.testing.setFailBeforeReplace(writer, false);
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = transcript_mod.Transcript.init(load_arena.allocator());
    const meta = try writer.load(&loaded);
    try std.testing.expectEqual(session_store.current_schema_version, meta.schema_version);
    try std.testing.expect(loaded.items().len >= 1);
}

// ── h-trace-001 lifecycle fixtures ──────────────────────────────────────────

const MockChat = struct {
    calls: *u32,
    mode: enum { text, provider_fail, max_turns_then_text, cancel_cooperates },

    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        _: []const message.Message,
        _: []const tool.Definition,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *MockChat = @ptrCast(@alignCast(ptr));
        self.calls.* += 1;
        switch (self.mode) {
            .text => {
                return .{
                    .content = try arena.dupe(u8, "done"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            },
            .provider_fail => return error.AuthenticationFailed,
            .max_turns_then_text => {
                // Always request a tool so the loop hits max_turns.
                const calls = try arena.alloc(message.ToolCall, 1);
                calls[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "list_dir"),
                    .arguments = try arena.dupe(u8, "{\"path\":\".\"}"),
                };
                return .{
                    .content = try arena.dupe(u8, "working"),
                    .tool_calls = calls,
                    .finish_reason = "tool_calls",
                };
            },
            .cancel_cooperates => {
                return .{
                    .content = try arena.dupe(u8, "should-not-matter"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            },
        }
    }
};

fn mockProvider(state: *MockChat) provider_mod.Provider {
    return .{
        .ptr = state,
        .vtable = &.{ .chat = MockChat.chat },
    };
}

fn expectRunEnd(tr: *const trace_mod.Trace, ok: bool, stop: []const u8) !void {
    try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_end"));
    try std.testing.expect(!tr.run_open);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"run_end\"") != null);
    if (ok) {
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"ok\":true") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"ok\":false") != null);
    }
    var stop_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&stop_buf, "\"stop_reason\":\"{s}\"", .{stop});
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, needle) != null);
}

test "h-trace: schema_version on run_start and completed terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .trace_path = null, // memory-only via manual trace install below
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    // Install memory-only trace (init with null path).
    agent.trace = trace_mod.Trace.init(gpa, io, null);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expect(calls >= 1);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "schema_version") != null);
    var ver_buf: [32]u8 = undefined;
    const ver_needle = try std.fmt.bufPrint(&ver_buf, "\"schema_version\":{d}", .{trace_mod.current_schema_version});
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, ver_needle) != null);
    try expectRunEnd(tr, true, "completed");
}

test "h-trace: provider failure ok=false provider_error exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .provider_fail };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.ProviderFailed, err);
    try std.testing.expect(calls >= 1);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "provider_error");
}

test "h-trace: max_turns terminal ok=true stop_reason=max_turns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .max_turns_then_text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 2,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.max_turns, result.stop_reason);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "max_turns");
}

test "h-trace: cancelled terminal ok=true stop_reason=cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null);
    agent.cancel.request();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.cancelled, result.stop_reason);
    // Cancel checked before first provider call when flag already set.
    try std.testing.expectEqual(@as(u32, 0), calls);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "cancelled");
}

test "h-trace: session save failure ok=false session_error not completed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-trace-save-fail";
    const path = ".zag-test-trace-save-fail/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    const writer = if (session.writer) |*w| w else return error.TestUnexpectedResult;
    session_store.testing.setFailBeforeReplace(writer, true);

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null);

    const reply_err = agent.reply(&session, "hello");
    try std.testing.expectError(error.IoFailed, reply_err);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "session_error");
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"ok\":true") == null);
}

test "h-trace: Agent.deinit does not invent success terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .provider_fail };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
    });
    // Manual trace; start a run then abandon without reply completing.
    agent.trace = trace_mod.Trace.init(gpa, io, null);
    const tr_ptr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try tr_ptr.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    try std.testing.expect(tr_ptr.run_open);
    try std.testing.expectEqual(@as(u32, 0), tr_ptr.terminal_count);

    // Snapshot buffer before deinit (deinit frees it).
    const had_run_start = std.mem.indexOf(u8, tr_ptr.buf.items, "run_start") != null;
    try std.testing.expect(had_run_start);
    // deinit must not call emitRunEnd with ok=true.
    agent.deinit();
    // If we reached here without a false terminal write, the contract holds:
    // deinit only frees. (Buffer is gone; we asserted open+zero terminals pre-deinit.)
}

test "h-trace: unwritable explicit path fails before provider" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-trace-unwritable";
    const blocker = ".zag-test-trace-unwritable/not-a-dir";
    const bad_path = ".zag-test-trace-unwritable/not-a-dir/trace.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blocker, .data = "file" });

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = bad_path,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.TraceIoFailed, err);
    try std.testing.expectEqual(@as(u32, 0), calls);
}

test "h-trace: absolute trace path is InvalidPath before provider" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = "/tmp/zag-trace-absolute.jsonl",
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.InvalidPath, err);
    try std.testing.expectEqual(@as(u32, 0), calls);
}

test "h-trace: completeWithSession does not double-terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null);

    const owned = try agent.completeWithSession("sys", "hi", .{
        .load_project_instructions = false,
    });
    defer owned.deinit(gpa);
    try std.testing.expectEqual(loop.StopReason.completed, owned.stop_reason);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "completed");
    // A second commit must not add another run_end.
    try agent.commitTerminal(0, true, .completed);
    try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_end"));
}
