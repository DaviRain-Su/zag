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
pub const ReplyError = loop.RunError || session_store.Error;

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

    pub fn deinit(self: *Agent) void {
        self.remember_store.deinit();
        if (self.trace) |*tr| {
            if (!tr.finished and tr.event_count > 0) {
                self.emitRunEnd(tr, 0, true, .completed);
            }
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

    fn ensureRunStart(self: *Agent, session: *Session) void {
        const tr = if (self.trace) |*t| t else return;
        if (tr.event_count > 0) return;
        tr.emitRunStart(.{
            .version = self.options.version,
            .permission = self.options.permission_mode.name(),
            .shell_policy = self.options.shell_policy.name(),
            .session = session.path,
        }) catch {};
    }

    fn emitRunEnd(self: *Agent, tr: *trace_mod.Trace, turns: u32, ok: bool, stop_reason: loop.StopReason) void {
        const usd: ?f64 = if (self.ledger.cost.known) self.ledger.cost.total else null;
        tr.emitRunEnd(.{
            .turns = turns,
            .ok = ok,
            .prompt_tokens = self.ledger.prompt_tokens,
            .completion_tokens = self.ledger.completion_tokens,
            .total_tokens = self.ledger.total_tokens,
            .estimated_usd = usd,
            .stop_reason = stop_reason.name(),
        }) catch {};
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
    pub fn reply(self: *Agent, session: *Session, user_text: []const u8) ReplyError!loop.Result {
        self.ensureRunStart(session);
        session.zag_version = self.options.version;
        try session.transcript.appendUser(user_text);
        const result = try loop.run(self.deps(session), &session.transcript);
        try session.save();
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

        const result = try self.reply(&session, user_prompt);
        if (self.trace) |*tr| {
            self.emitRunEnd(tr, result.turns, true, result.stop_reason);
        }
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
    const writer = &(session.writer orelse return error.TestUnexpectedResult);
    session_store.testing.setFailBeforeReplace(writer, true);

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Tool,
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

    // Prior bytes remain loadable as a session (without the active writer).
    session_store.testing.setFailBeforeReplace(writer, false);
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = transcript_mod.Transcript.init(load_arena.allocator());
    // Public load would take a brief lock while Session still holds the writer → Busy.
    // Parse the preserved bytes directly.
    const meta = try session_store.parseSessionBytes(gpa, &loaded, after);
    try std.testing.expectEqual(session_store.current_schema_version, meta.schema_version);
    try std.testing.expect(loaded.items().len >= 1);
}
