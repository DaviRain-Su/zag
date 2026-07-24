//! Coding Agent facade — product layer over Agent Core.
//!
//! ```
//! var agent = Agent.init(gpa, io, provider, .{ .permission_mode = .ask });
//! var session = try Session.start(gpa, io, .{ .base_system = sys, .path = "..." });
//! defer session.deinit();
//! const result = try agent.reply(&session, user_text);
//! ```

const std = @import("std");
const builtin = @import("builtin");
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
    /// Test-only: next `noteCompaction` returns OOM without mutating gen/summary.
    fail_next_note_compaction: if (builtin.is_test) bool else void =
        if (builtin.is_test) false else {},

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

    /// Apply one final compaction event. Increments `compaction_gen` exactly once
    /// on success. On OOM leaves gen/summary unchanged so callers can fail the
    /// turn without claiming a session update that did not stick (h-context-001).
    pub fn noteCompaction(self: *Session, event: context_mod.CompactionEvent) error{OutOfMemory}!void {
        if (builtin.is_test) {
            if (self.fail_next_note_compaction) {
                self.fail_next_note_compaction = false;
                return error.OutOfMemory;
            }
        }
        const arena = self.arena_impl.allocator();
        const owned = try arena.dupe(u8, event.summary);
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
    /// Test-only toolset override for InvalidToolset fixtures (production always null).
    test_tools: if (builtin.is_test) ?[]const tool.Tool else void =
        if (builtin.is_test) null else {},

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
            self.trace = trace_mod.Trace.init(gpa, io, tp, Io.Dir.cwd());
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

    fn effectiveToolset(self: *Agent) tool.Toolset {
        if (builtin.is_test) {
            if (self.test_tools) |override| return .{ .tools = override };
        }
        return self.tools_storage.toolset();
    }

    fn deps(self: *Agent, session: *Session) loop.Deps {
        const gate = self.resolveGate();
        return .{
            .gpa = self.gpa,
            .provider = self.provider,
            .toolset = self.effectiveToolset(),
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

    fn onSessionCompaction(ctx: ?*anyopaque, event: context_mod.CompactionEvent) error{OutOfMemory}!void {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        try session.noteCompaction(event);
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

    /// Per-reply prep: reset ledger + trace buffer, non-destructive preflight,
    /// then `run_start`. Lifecycle owner: facade (loop + session save + persist).
    fn beginRun(self: *Agent, session: *Session) ReplyError!void {
        // Fresh run-local cost ledger each reply.
        self.ledger = .{};
        const tr = if (self.trace) |*t| t else return;
        try tr.beginReply();
        try tr.emitRunStart(.{
            .version = self.options.version,
            .permission = self.options.permission_mode.name(),
            .shell_policy = self.options.shell_policy.name(),
            .session = session.path,
        });
    }

    /// Commit exactly one terminal for the open run. No-op when tracing is off
    /// or the run already closed. Propagates persistence I/O as `TraceIoFailed`.
    fn commitTerminal(
        self: *Agent,
        turns: u32,
        ok: bool,
        stop_reason: loop.StopReason,
    ) trace_mod.Error!void {
        const tr = if (self.trace) |*t| t else return;
        if (!tr.run_open or tr.finished) return;
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

    /// Commit a failure terminal; never swallow commit errors.
    ///
    /// Fail-closed precedence: if persisting/serializing the failure terminal
    /// itself fails, return the **trace** error (or OOM), not the primary.
    /// When commit succeeds, return `primary`.
    ///
    /// `turns_hint` is merged with `Trace.last_emitted_turn` so mid-run failures
    /// report progress when turn events were emitted.
    fn failRun(
        self: *Agent,
        turns_hint: u32,
        stop_reason: loop.StopReason,
        primary: ReplyError,
    ) ReplyError {
        const turns: u32 = if (self.trace) |*tr|
            @max(turns_hint, tr.last_emitted_turn)
        else
            turns_hint;
        self.commitTerminal(turns, false, stop_reason) catch |terr| return terr;
        return primary;
    }

    fn stopReasonForRunError(err: loop.RunError) loop.StopReason {
        return switch (err) {
            error.ProviderFailed => .provider_error,
            error.TraceFailed => .trace_error,
            error.OutOfMemory => .out_of_memory,
            error.InvalidToolset => .invalid_toolset,
            error.InvalidContext => .invalid_context,
            error.MaxTurnsExceeded => .max_turns,
        };
    }

    fn resultOk(stop: loop.StopReason) bool {
        return switch (stop) {
            // Clean cooperative cancel is a normal Result, not a harness failure.
            .completed, .max_turns, .cancelled => true,
            .provider_error, .session_error, .trace_error, .out_of_memory, .invalid_toolset, .invalid_context => false,
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
    /// Terminal ownership (h-trace-001) — one reply = one run:
    /// 1. reset run-local ledger + trace buffer; non-destructive preflight;
    /// 2. `run_start` (run is "started");
    /// 3. appendUser / loop / session save (each caught; no terminal gaps);
    /// 4. session save **before** a successful terminal is committed;
    /// 5. exactly one `run_end` with truthful `ok` / `stop_reason`.
    ///
    /// Explicit path atomically stores the **latest completed reply** only.
    ///
    /// Persistence failure after a normal outcome → `TraceIoFailed` and in-memory
    /// `ok=false, stop_reason=trace_error` (no committed ok=true). Fail-closed:
    /// if committing a failure terminal itself fails, the trace error is returned
    /// rather than silently keeping only the primary error.
    pub fn reply(self: *Agent, session: *Session, user_text: []const u8) ReplyError!loop.Result {
        try self.beginRun(session);
        session.zag_version = self.options.version;

        session.transcript.appendUser(user_text) catch |err| {
            return self.failRun(0, .out_of_memory, err);
        };

        const result = loop.run(self.deps(session), &session.transcript) catch |err| {
            return self.failRun(0, stopReasonForRunError(err), err);
        };

        // Save before committing a successful terminal so save failure cannot leave ok=true.
        session.save() catch |err| {
            return self.failRun(result.turns, .session_error, err);
        };

        // Final persist on success path: TraceIoFailed (no audited success).
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
    mode: enum { text, text_with_usage, provider_fail, max_turns_then_text, tool_then_fail },
    /// Distinct usage per call for multi-reply ledger tests.
    usage_prompt: u32 = 10,

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
            .text_with_usage => {
                const p = self.usage_prompt;
                self.usage_prompt += 100; // next reply gets different usage
                return .{
                    .content = try arena.dupe(u8, "done"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                    .usage = .{
                        .prompt_tokens = p,
                        .completion_tokens = 5,
                        .total_tokens = p + 5,
                    },
                };
            },
            .provider_fail => return error.AuthenticationFailed,
            .tool_then_fail => {
                if (self.calls.* == 1) {
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
                }
                return error.AuthenticationFailed;
            },
            .max_turns_then_text => {
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
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_start"));
    try std.testing.expect(!tr.run_open);
    try std.testing.expect(tr.finished);
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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
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
    // Parent is a file → Guard ResolveFailed/InvalidPath (fail-closed before provider).
    try std.testing.expect(err == error.TraceIoFailed or err == error.InvalidPath);
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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

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

test "h-trace: two consecutive replies reset buffer seq and ledger" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-two-reply";
    const path = ".zag-test-trace-two-reply/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text_with_usage, .usage_prompt = 10 };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = path,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    _ = try agent.reply(&session, "first");
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "completed");
    try std.testing.expectEqual(@as(u64, 10), agent.ledger.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 1), agent.ledger.turns);
    const file1 = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(file1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file1, "\"kind\":\"run_start\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file1, "\"kind\":\"run_end\""));
    try std.testing.expect(std.mem.indexOf(u8, file1, "\"prompt_tokens\":10") != null);

    _ = try agent.reply(&session, "second");
    try expectRunEnd(tr, true, "completed");
    try std.testing.expectEqual(@as(u64, 110), agent.ledger.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 1), agent.ledger.turns);
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_start"));
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"seq\":0") != null);

    const file2 = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(file2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file2, "\"kind\":\"run_start\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file2, "\"kind\":\"run_end\""));
    // Durable second-run usage only; first-run prompt_tokens=10 must be gone.
    try std.testing.expect(std.mem.indexOf(u8, file2, "\"prompt_tokens\":110") != null);
    try std.testing.expect(std.mem.indexOf(u8, file2, "\"prompt_tokens\":10") == null);
}

test "h-trace: fail-before-replace returns TraceIoFailed single false terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-agent-fault";
    const path = ".zag-test-trace-agent-fault/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const original = "{\"kind\":\"keep-me\"}\n";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original });

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = path,
    });
    defer agent.deinit();
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    trace_mod.testing.setFailBeforeReplace(tr, true);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.TraceIoFailed, err);
    try std.testing.expect(calls >= 1);
    try expectRunEnd(tr, false, "trace_error");
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"ok\":true") == null);

    const after = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);

    // No temp residue.
    var dir = try Io.Dir.cwd().openDir(io, dir_name, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) try std.testing.expectEqualStrings("run.jsonl", entry.name);
    }
}

test "h-trace: recovery A success, B persist fault, C success latest-run only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-recovery";
    const path = ".zag-test-trace-recovery/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text_with_usage, .usage_prompt = 7 };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = path,
    });
    defer agent.deinit();
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    // A: success
    _ = try agent.reply(&session, "A");
    try expectRunEnd(tr, true, "completed");
    const file_a = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(file_a);
    try std.testing.expect(std.mem.indexOf(u8, file_a, "\"prompt_tokens\":7") != null);

    // B: fail before replace — durable A preserved, one in-memory failure terminal
    trace_mod.testing.setFailBeforeReplace(tr, true);
    try std.testing.expectError(error.TraceIoFailed, agent.reply(&session, "B"));
    try expectRunEnd(tr, false, "trace_error");
    const file_b = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(file_b);
    try std.testing.expectEqualStrings(file_a, file_b);

    // C: clear fault, succeed; file is only C
    trace_mod.testing.setFailBeforeReplace(tr, false);
    _ = try agent.reply(&session, "C");
    try expectRunEnd(tr, true, "completed");
    try std.testing.expectEqual(@as(u32, 1), agent.ledger.turns);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"seq\":0") != null);
    const file_c = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024));
    defer gpa.free(file_c);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file_c, "\"kind\":\"run_start\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, file_c, "\"kind\":\"run_end\""));
    try std.testing.expect(std.mem.indexOf(u8, file_c, "\"ok\":true") != null);
    // C usage is 7 + 100 + 100 = 207 from mock advancement (A=7, B attempted with 107, C=207)
    try std.testing.expect(std.mem.indexOf(u8, file_c, "\"prompt_tokens\":7") == null);
    try std.testing.expect(std.mem.indexOf(u8, file_c, "\"prompt_tokens\":207") != null);
}

test "h-trace: provider fail with persist fault returns TraceIoFailed (fail-closed)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-trace-provider-fault";
    const path = ".zag-test-trace-provider-fault/run.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .provider_fail };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
        .trace_path = path,
    });
    defer agent.deinit();
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    trace_mod.testing.setFailBeforeReplace(tr, true);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.TraceIoFailed, err);
    try expectRunEnd(tr, false, "provider_error");
}

test "h-trace: Agent.reply invalid toolset provider=0 and invalid_toolset terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const forged: tool.Tool = .{
        .descriptor = .{
            .definition = .{
                .name = "forged_path",
                .description = "",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .capabilities = .{
                .risk = .read,
                .workspace = .{ .path_field = "" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .handler = struct {
            fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                return error.ToolFailed;
            }
        }.h,
    };
    const tools = [_]tool.Tool{forged};

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    agent.test_tools = &tools;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.InvalidToolset, err);
    try std.testing.expectEqual(@as(u32, 0), calls);
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "invalid_toolset");
}

test "h-trace: parent symlink escape fails before provider" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Nested ws + sibling outside (Guard root = ws, not monorepo).
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.jsonl", .data = "KEEP\n" });
    var ws = try parent.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    ws.symLink(io, "../outside", "escape", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => |e| return e,
    };

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        // Path relative to agent cwd (process cwd); for unit isolation we install
        // Trace with ws cwd directly below.
        .trace_path = null,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, "escape/trace.jsonl", ws);

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try std.testing.expectError(error.InvalidPath, agent.reply(&session, "hi"));
    try std.testing.expectEqual(@as(u32, 0), calls);

    const after = try parent.dir.readFileAlloc(io, "outside/secret.jsonl", gpa, .limited(32));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("KEEP\n", after);
}

test "h-trace: provider failure after prior turn reports last_emitted_turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .tool_then_fail };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
        .max_turns = 8,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try std.testing.expectError(error.ProviderFailed, agent.reply(&session, "hi"));
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "provider_error");
    // Turn 1 tool batch then turn 2 emitted before provider fail.
    try std.testing.expect(tr.last_emitted_turn >= 1);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"turns\":") != null);
    // Terminal should not claim zero turns if a turn was emitted.
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"turns\":0") == null);
}

// ── h-context-001 integration fixtures ──────────────────────────────────────

/// Mock that records the last provider view and returns a short text reply.
const CaptureViewChat = struct {
    calls: *u32,
    /// Gpa-owned copy of last message roles+contents for assertions.
    gpa: std.mem.Allocator,
    last_roles: std.ArrayListUnmanaged(u8) = .empty,
    last_contents: std.ArrayListUnmanaged([]const u8) = .empty,
    last_view_len: usize = 0,

    fn deinit(self: *CaptureViewChat) void {
        for (self.last_contents.items) |c| self.gpa.free(c);
        self.last_contents.deinit(self.gpa);
        self.last_roles.deinit(self.gpa);
    }

    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        _: []const tool.Definition,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *CaptureViewChat = @ptrCast(@alignCast(ptr));
        self.calls.* += 1;
        // Reset previous capture.
        for (self.last_contents.items) |c| self.gpa.free(c);
        self.last_contents.clearRetainingCapacity();
        self.last_roles.clearRetainingCapacity();
        self.last_view_len = messages.len;
        for (messages) |m| {
            const role_ch: u8 = switch (m.role) {
                .system => 'S',
                .user => 'U',
                .assistant => 'A',
                .tool => 'T',
            };
            self.last_roles.append(self.gpa, role_ch) catch return error.OutOfMemory;
            const owned = self.gpa.dupe(u8, m.content) catch return error.OutOfMemory;
            self.last_contents.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return error.OutOfMemory;
            };
        }
        return .{
            .content = try arena.dupe(u8, "compacted-reply"),
            .tool_calls = &.{},
            .finish_reason = "stop",
        };
    }
};

fn parseCompactionFromTrace(gpa: std.mem.Allocator, buf: []const u8) !struct { dropped: usize, summary: []const u8 } {
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"kind\":\"compaction\"") == null) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const obj = parsed.value.object;
        const dropped_v = obj.get("dropped") orelse return error.TestUnexpectedResult;
        const summary_v = obj.get("summary") orelse return error.TestUnexpectedResult;
        const dropped: usize = switch (dropped_v) {
            .integer => |i| @intCast(i),
            else => return error.TestUnexpectedResult,
        };
        const summary = try gpa.dupe(u8, summary_v.string);
        return .{ .dropped = dropped, .summary = summary };
    }
    return error.TestUnexpectedResult;
}

test "h-context: session+trace same final dropped/summary; provider gets final view; save/resume gen" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-context-session";
    const path = ".zag-test-h-context-session/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var gen_saved: u32 = 0;
    var summary_saved: []u8 = undefined;

    {
        var calls: u32 = 0;
        var capture: CaptureViewChat = .{ .calls = &calls, .gpa = gpa };
        defer capture.deinit();

        var agent = Agent.init(gpa, io, .{
            .ptr = &capture,
            .vtable = &.{ .chat = CaptureViewChat.chat },
        }, .{
            .permission_mode = .yolo,
            .verbose = false,
            .max_turns = 4,
            // Force count-trim compaction on a long seeded transcript.
            .context = .{
                .max_tail_messages = 4,
                .max_chars = 0,
                .min_tail_messages = 2,
                .summary_max_chars = 400,
            },
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        // Seed a long body so the next view drops history.
        const pad = "seed-msg-";
        var n: usize = 0;
        while (n < 12) : (n += 1) {
            var buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&buf, "{s}{d}", .{ pad, n });
            if (n % 2 == 0) {
                try session.transcript.appendUser(label);
            } else {
                try session.transcript.appendAssistantTurn(.{
                    .content = label,
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                });
            }
        }

        var roles_before: [64]u8 = undefined;
        const items_before = session.transcript.items();
        var rb: usize = 0;
        for (items_before) |m| {
            if (rb >= roles_before.len) break;
            roles_before[rb] = switch (m.role) {
                .system => 'S',
                .user => 'U',
                .assistant => 'A',
                .tool => 'T',
            };
            rb += 1;
        }
        const len_before = items_before.len;
        const first_content = try gpa.dupe(u8, items_before[0].content);
        defer gpa.free(first_content);

        const result = try agent.reply(&session, "please compact");
        try std.testing.expectEqualStrings("compacted-reply", result.final_text);

        // Transcript grew by user + assistant only; earlier rows unchanged.
        const items_after = session.transcript.items();
        try std.testing.expectEqual(len_before + 2, items_after.len);
        try std.testing.expectEqualStrings(first_content, items_after[0].content);
        var ra: usize = 0;
        for (items_after[0..rb]) |m| {
            const ch: u8 = switch (m.role) {
                .system => 'S',
                .user => 'U',
                .assistant => 'A',
                .tool => 'T',
            };
            try std.testing.expectEqual(roles_before[ra], ch);
            ra += 1;
        }

        // Session received exactly one generation bump for this event.
        try std.testing.expectEqual(@as(u32, 1), session.compaction_gen);
        try std.testing.expect(session.compaction_summary != null);
        const sess_summary = session.compaction_summary.?;

        // Trace compaction event matches session (strict JSON).
        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("compaction"));
        const parsed = try parseCompactionFromTrace(gpa, tr.buf.items);
        defer gpa.free(parsed.summary);
        try std.testing.expectEqualStrings(sess_summary, parsed.summary);

        // Header count in summary equals dropped.
        var count_buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{parsed.dropped});
        try std.testing.expect(std.mem.indexOf(u8, sess_summary, needle) != null);
        try std.testing.expect(parsed.dropped >= 2);

        // Provider received the compacted final view (shorter than full transcript).
        try std.testing.expect(capture.last_view_len < items_after.len);
        try std.testing.expect(capture.last_view_len > 0);
        // Session context layer present in provider view.
        var saw_session_layer = false;
        for (capture.last_contents.items) |c| {
            if (std.mem.indexOf(u8, c, "Session context") != null) saw_session_layer = true;
        }
        try std.testing.expect(saw_session_layer);

        // Persist; copy gen/summary out before session ends.
        try session.save();
        gen_saved = session.compaction_gen;
        summary_saved = try gpa.dupe(u8, sess_summary);
    }
    defer gpa.free(summary_saved);

    // Resume preserves gen and summary.
    {
        var resumed = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        defer resumed.deinit();
        try std.testing.expectEqual(gen_saved, resumed.compaction_gen);
        try std.testing.expect(resumed.compaction_summary != null);
        try std.testing.expectEqualStrings(summary_saved, resumed.compaction_summary.?);

        // Second compaction bumps gen exactly once more and keeps lineage.
        var calls2: u32 = 0;
        var capture2: CaptureViewChat = .{ .calls = &calls2, .gpa = gpa };
        defer capture2.deinit();
        var agent2 = Agent.init(gpa, io, .{
            .ptr = &capture2,
            .vtable = &.{ .chat = CaptureViewChat.chat },
        }, .{
            .permission_mode = .yolo,
            .verbose = false,
            .max_turns = 4,
            .context = .{
                .max_tail_messages = 2,
                .max_chars = 0,
                .min_tail_messages = 2,
                .summary_max_chars = 500,
            },
        });
        defer agent2.deinit();
        agent2.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

        const gen_before = resumed.compaction_gen;
        _ = try agent2.reply(&resumed, "again");
        try std.testing.expectEqual(gen_before + 1, resumed.compaction_gen);
        try std.testing.expect(std.mem.indexOf(u8, resumed.compaction_summary.?, "Prior session context") != null);

        // Trace for second run also carries matching summary.
        const tr2 = if (agent2.trace) |*t| t else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 1), tr2.countKind("compaction"));
        const p2 = try parseCompactionFromTrace(gpa, tr2.buf.items);
        defer gpa.free(p2.summary);
        try std.testing.expectEqualStrings(resumed.compaction_summary.?, p2.summary);
    }
}

test "h-context: noteCompaction OOM leaves gen and summary unchanged" {
    const io = std.testing.io;

    // Bound the session allocator so summary dupe can fail after start.
    var storage: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const limited = fba.allocator();

    var session = try Session.start(limited, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try std.testing.expectEqual(@as(u32, 0), session.compaction_gen);
    try std.testing.expect(session.compaction_summary == null);

    // Exhaust remaining arena capacity.
    const arena = session.arena_impl.allocator();
    while (arena.alloc(u8, 64)) |_| {} else |_| {}

    const err = session.noteCompaction(.{
        .dropped = 3,
        .summary = "this-summary-must-not-be-applied-on-oom",
    });
    try std.testing.expectError(error.OutOfMemory, err);
    try std.testing.expectEqual(@as(u32, 0), session.compaction_gen);
    try std.testing.expect(session.compaction_summary == null);
}

test "h-context: on_compaction OOM aborts before trace compaction line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Loop-level: sink returns OOM; trace must not receive compaction; run errors.
    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "should-not-reach"),
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

    const OomSink = struct {
        fn onCompaction(ctx: ?*anyopaque, _: context_mod.CompactionEvent) error{OutOfMemory}!void {
            const called: *bool = @ptrCast(@alignCast(ctx.?));
            called.* = true;
            return error.OutOfMemory;
        }
    };
    var sink_called = false;

    var tr = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    defer tr.deinit();
    // Open a run so mid-run emit would be legal if reached (it must not be).
    try tr.beginReply();
    try tr.emitRunStart(.{
        .version = "0.5.0",
        .permission = "yolo",
        .shell_policy = "protect",
    });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendSystem("sys");
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try transcript.appendUser("u");
        try transcript.appendAssistantTurn(.{
            .content = "a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });
    }

    const result = loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = Io.Dir.cwd(),
        },
        .options = .{
            .max_turns = 2,
            .permission_gate = .yolo(),
            .layers = .{ .system = "base" },
            .context = .{
                .max_tail_messages = 2,
                .max_chars = 0,
                .min_tail_messages = 1,
            },
            .trace = &tr,
            .on_compaction = OomSink.onCompaction,
            .compaction_ctx = &sink_called,
        },
    }, &transcript);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(sink_called);
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("compaction"));
    // Provider must not have been called after sink failure.
    // (Mock would have returned text; no assistant event expected from loop.)
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("assistant"));
}

test "h-context: Agent.reply malformed tools invalid_context provider=0" {
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
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    // Seed a malformed incomplete tool bundle into the authoritative transcript.
    const calls_tc = try session.arena_impl.allocator().alloc(message.ToolCall, 2);
    calls_tc[0] = .{
        .id = try session.arena_impl.allocator().dupe(u8, "a1"),
        .name = try session.arena_impl.allocator().dupe(u8, "list_dir"),
        .arguments = try session.arena_impl.allocator().dupe(u8, "{}"),
    };
    calls_tc[1] = .{
        .id = try session.arena_impl.allocator().dupe(u8, "a2"),
        .name = try session.arena_impl.allocator().dupe(u8, "read_file"),
        .arguments = try session.arena_impl.allocator().dupe(u8, "{}"),
    };
    try session.transcript.appendUser("ask");
    try session.transcript.appendAssistantTurn(.{
        .content = "tools",
        .tool_calls = calls_tc,
        .finish_reason = "tool_calls",
    });
    // Only one of two results — incomplete bundle.
    try session.transcript.appendToolResult("a1", "partial");

    const err = agent.reply(&session, "continue");
    try std.testing.expectError(error.InvalidContext, err);
    try std.testing.expectEqual(@as(u32, 0), calls);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "invalid_context");
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("compaction"));
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("assistant"));
}

test "h-context: Agent.reply noteCompaction OOM provider=0 one out_of_memory terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .context = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 1,
            .summary_max_chars = 400,
        },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try session.transcript.appendUser("u");
        try session.transcript.appendAssistantTurn(.{
            .content = "a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });
    }

    session.fail_next_note_compaction = true;
    const gen_before = session.compaction_gen;
    try std.testing.expect(session.compaction_summary == null);

    const err = agent.reply(&session, "please compact");
    try std.testing.expectError(error.OutOfMemory, err);
    try std.testing.expectEqual(@as(u32, 0), calls);
    try std.testing.expectEqual(gen_before, session.compaction_gen);
    try std.testing.expect(session.compaction_summary == null);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "out_of_memory");
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("compaction"));
    try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
}

test "h-context: session layer summary and trace byte-equal under shared cap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-context-cap";
    const path = ".zag-test-h-context-cap/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var calls: u32 = 0;
    var capture: CaptureViewChat = .{ .calls = &calls, .gpa = gpa };
    defer capture.deinit();

    var agent = Agent.init(gpa, io, .{
        .ptr = &capture,
        .vtable = &.{ .chat = CaptureViewChat.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .context = .{
            .max_tail_messages = 3,
            .max_chars = 0,
            .min_tail_messages = 2,
            .summary_max_chars = 50_000, // over shared cap → clamp
        },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    var n: usize = 0;
    while (n < 12) : (n += 1) {
        var buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "seed-{d}", .{n});
        if (n % 2 == 0) {
            try session.transcript.appendUser(label);
        } else {
            try session.transcript.appendAssistantTurn(.{
                .content = label,
                .tool_calls = &.{},
                .finish_reason = "stop",
            });
        }
    }

    _ = try agent.reply(&session, "go");
    try std.testing.expect(session.compaction_summary != null);
    const sess = session.compaction_summary.?;
    try std.testing.expect(sess.len <= context_mod.summary_cap);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    const parsed = try parseCompactionFromTrace(gpa, tr.buf.items);
    defer gpa.free(parsed.summary);
    try std.testing.expectEqualStrings(sess, parsed.summary);
    try std.testing.expect(parsed.summary.len <= context_mod.summary_cap);

    // Provider session layer embeds the same summary text.
    var found = false;
    for (capture.last_contents.items) |c| {
        if (std.mem.indexOf(u8, c, sess) != null) found = true;
    }
    try std.testing.expect(found);

    try session.save();
    // Header persists same summary.
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = transcript_mod.Transcript.init(load_arena.allocator());
    const writer = if (session.writer) |*w| w else return error.TestUnexpectedResult;
    const meta = try writer.load(&loaded);
    try std.testing.expect(meta.compaction_summary != null);
    try std.testing.expectEqualStrings(sess, meta.compaction_summary.?);
    try std.testing.expectEqual(session.compaction_gen, meta.compaction_gen);
}

test "h-context: large prior lineage survives save/resume with marker or exact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-context-lineage";
    const path = ".zag-test-h-context-lineage/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var prior: [790]u8 = undefined;
    @memset(&prior, 'Q');

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .context = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 2,
            .summary_max_chars = context_mod.summary_cap,
        },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    // Install a large prior as if a previous compaction left it.
    session.compaction_summary = try session.arena_impl.allocator().dupe(u8, &prior);
    session.compaction_gen = 1;

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try session.transcript.appendUser("u");
        try session.transcript.appendAssistantTurn(.{
            .content = "a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });
    }

    _ = try agent.reply(&session, "again");
    try std.testing.expectEqual(@as(u32, 2), session.compaction_gen);
    try std.testing.expect(session.compaction_summary != null);
    const sum = session.compaction_summary.?;
    try std.testing.expect(sum.len <= context_mod.summary_cap);
    try std.testing.expect(std.mem.indexOf(u8, sum, context_mod.lineage_truncated_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=790") != null);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    const parsed = try parseCompactionFromTrace(gpa, tr.buf.items);
    defer gpa.free(parsed.summary);
    try std.testing.expectEqualStrings(sum, parsed.summary);

    try session.save();
    const gen_saved = session.compaction_gen;
    const summary_saved = try gpa.dupe(u8, sum);
    defer gpa.free(summary_saved);
    session.deinit();

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    try std.testing.expectEqual(gen_saved, resumed.compaction_gen);
    try std.testing.expectEqualStrings(summary_saved, resumed.compaction_summary.?);
}
