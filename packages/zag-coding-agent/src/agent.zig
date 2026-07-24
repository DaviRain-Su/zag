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

pub const Options = struct {
    max_turns: u32 = loop.default_max_turns,
    verbose: bool = false,
    permission_mode: permissions.Mode = .ask,
    permission_gate: ?permissions.Gate = null,
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

pub const SessionStartOptions = struct {
    /// Base system prompt (agent identity + tool rules).
    base_system: []const u8,
    /// If set, load/save transcript here (relative to cwd).
    path: ?[]const u8 = null,
    /// Inject AGENTS.md / README into system (default true).
    load_project_instructions: bool = true,
    /// When true, load transcript from path if the file exists.
    continue_existing: bool = false,
};

/// One conversation. Owns the transcript arena (heap-stable so Session is movable).
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena_impl: *std.heap.ArenaAllocator,
    transcript: transcript_mod.Transcript,
    /// Owned path for auto-save, or null for ephemeral.
    path: ?[]u8 = null,
    /// Which project file was injected, if any (borrowed into system text).
    project_source: ?[]const u8 = null,

    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        opts: SessionStartOptions,
    ) loop.RunError!Session {
        const arena_impl = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_impl.* = .init(gpa);
        errdefer {
            arena_impl.deinit();
            gpa.destroy(arena_impl);
        }

        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        var path_owned: ?[]u8 = null;
        errdefer if (path_owned) |p| gpa.free(p);

        if (opts.path) |p| {
            path_owned = gpa.dupe(u8, p) catch return error.OutOfMemory;
        }

        var project_source: ?[]const u8 = null;

        if (opts.continue_existing) {
            if (path_owned) |p| {
                session_store.load(gpa, io, Io.Dir.cwd(), p, &transcript) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.IoFailed, error.InvalidSession => {
                        try seedNewTranscript(gpa, io, &transcript, opts, &project_source);
                    },
                };
                if (transcript.items().len == 0) {
                    try seedNewTranscript(gpa, io, &transcript, opts, &project_source);
                }
            } else {
                try seedNewTranscript(gpa, io, &transcript, opts, &project_source);
            }
        } else {
            try seedNewTranscript(gpa, io, &transcript, opts, &project_source);
        }

        return .{
            .gpa = gpa,
            .io = io,
            .arena_impl = arena_impl,
            .transcript = transcript,
            .path = path_owned,
            .project_source = project_source,
        };
    }

    fn seedNewTranscript(
        gpa: std.mem.Allocator,
        io: Io,
        transcript: *transcript_mod.Transcript,
        opts: SessionStartOptions,
        project_source: *?[]const u8,
    ) loop.RunError!void {
        var project_body: ?[]u8 = null;
        defer if (project_body) |b| gpa.free(b);

        if (opts.load_project_instructions) {
            if (project_mod.load(gpa, io, Io.Dir.cwd()) catch null) |loaded| {
                project_source.* = loaded.source;
                project_body = loaded.body;
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

    pub fn deinit(self: *Session) void {
        if (self.path) |p| self.gpa.free(p);
        self.arena_impl.deinit();
        self.gpa.destroy(self.arena_impl);
        self.* = undefined;
    }

    /// Persist transcript if a path is configured.
    pub fn save(self: *Session) session_store.Error!void {
        const p = self.path orelse return;
        try session_store.save(self.gpa, self.io, Io.Dir.cwd(), p, self.transcript.items());
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
    /// Owned when options.trace_path is set.
    trace: ?trace_mod.Trace = null,
    /// Session/run cost accumulator (updated on each provider usage event).
    ledger: ai.cost.Ledger = .{},

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
            .trace = null,
            .ledger = .{},
        };
        self.permission_gate = self.resolveGate();
        if (options.trace_path) |tp| {
            self.trace = trace_mod.Trace.init(gpa, io, tp);
        }
        return self;
    }

    pub fn deinit(self: *Agent) void {
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
        if (self.options.permission_gate) |g| return g;
        return switch (self.options.permission_mode) {
            .yolo => permissions.Gate.yolo(),
            .ask => self.stdin_prompter.gate(),
        };
    }

    fn deps(self: *Agent) loop.Deps {
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
                .shell_policy = self.options.shell_policy,
                .trace = if (self.trace) |*tr| tr else null,
                .chat_retries = self.options.chat_retries,
                .retry_base_delay_ms = self.options.retry_base_delay_ms,
            },
        };
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
    pub fn reply(self: *Agent, session: *Session, user_text: []const u8) loop.RunError!loop.Result {
        self.ensureRunStart(session);
        try session.transcript.appendUser(user_text);
        const result = try loop.run(self.deps(), &session.transcript);
        session.save() catch |err| {
            if (self.options.verbose) {
                std.log.warn("session save failed: {s}", .{@errorName(err)});
            }
        };
        return result;
    }

    /// One-shot: optional session path for durability.
    pub fn complete(
        self: *Agent,
        system_prompt: []const u8,
        user_prompt: []const u8,
    ) loop.RunError!OwnedResult {
        return self.completeWithSession(system_prompt, user_prompt, .{});
    }

    pub fn completeWithSession(
        self: *Agent,
        system_prompt: []const u8,
        user_prompt: []const u8,
        session_opts: struct {
            path: ?[]const u8 = null,
            continue_existing: bool = false,
            load_project_instructions: bool = true,
        },
    ) loop.RunError!OwnedResult {
        var session = try Session.start(self.gpa, self.io, .{
            .base_system = system_prompt,
            .path = session_opts.path,
            .continue_existing = session_opts.continue_existing,
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
