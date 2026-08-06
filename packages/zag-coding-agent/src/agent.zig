//! Coding Agent facade — product layer over Agent Core.
//!
//! ```
//! var agent = try Agent.init(gpa, io, provider, .{ .permission_mode = .ask });
//! var session = try Session.start(gpa, io, .{ .base_system = sys, .path = "..." });
//! defer session.deinit();
//! const result = try agent.reply(&session, user_text);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ztypes = @import("zag-types");
const core = @import("zag-agent-core");
const ai = @import("zag-ai");
const toolset_mod = @import("toolset.zig");
const project_mod = @import("project.zig");
const skills_mod = @import("skills.zig");
const prompt_templates_mod = @import("prompt_templates.zig");
const edit_tools = @import("runtime/edit_tools.zig");

const message = core.message;
const tool = core.tool;
const tool_args = core.tool_args;
const transcript_mod = core.transcript;
const provider_mod = core.provider;
const observer_mod = @import("observer.zig");
const permissions = @import("permissions.zig");
const context_mod = @import("context.zig");
const session_store = @import("session_store.zig");
const shell_policy = @import("shell_policy.zig");
const workspace = @import("workspace.zig");
const trace_mod = @import("trace.zig");
const redact_mod = @import("redact.zig");
const lifecycle_mod = @import("lifecycle.zig");
const control_queue_mod = @import("control_queue.zig");
const loop = core.loop;
const cancel_mod = core.cancel;
const control_input_mod = core.control_input;

// D-011 seam ports (adapted over current product behavior).
const tool_policy_mod = core.tool_policy;
const jail_mod = core.jail;
const shell_policy_mod = core.shell_policy;
const context_view_mod = core.context_view;
const loop_event_mod = core.loop_event;

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
    /// Timeout and Cancelled are never retried (end-to-end deadline).
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    /// End-to-end provider deadline (ms); null = no deadline (default).
    /// Wired into loop RequestControl; 0 = immediate Timeout.
    provider_timeout_ms: ?u64 = null,
    /// Catalog row for cost rates / context (from `ai.resolve`); null = no USD estimate.
    model_info: ?ai.ModelInfo = null,
    /// Exact secrets to redact (copied into Agent-owned Redactor at init).
    /// CLI wires the resolved provider API key here without logging it.
    /// Empty/short entries are ignored by the redactor.
    secrets: []const []const u8 = &.{},
    /// Apply documented common API-key/token patterns (default true).
    pattern_redaction: bool = true,
    /// Optional custom toolset. When null the default `Phase1Storage` built-ins are used.
    /// The slice and the `Tool` descriptors/instance pointers it references are
    /// **borrowed from the caller** and must outlive every `Agent.reply` call.
    /// When non-null, `hunk_reviewer` / `post_edit_verifier` are **not** auto-spliced
    /// into custom tools (B7); the caller owns custom Tool instance lifetimes.
    toolset: ?[]const tool.Tool = null,
    /// Optional hunk reviewer for the default built-in `apply_hunk` Tool (B7).
    /// Null → soft `review_unavailable` if `apply_hunk` runs. Not auto-spliced into custom toolsets.
    hunk_reviewer: ?edit_tools.HunkReviewer = null,
    /// Optional post-edit verifier for default `apply_hunk` (B7). Null → `verification=not_configured`.
    /// Not auto-spliced into custom toolsets. Receives workspace-relative request path only.
    post_edit_verifier: ?edit_tools.PostEditVerifier = null,
    /// Optional observer invoked before the Agent's internal usage/verbose handler.
    /// The observer value is copied into options; the pointer/data it references
    /// must remain valid for the lifetime of every `Agent.reply` call.
    observer: ?observer_mod.Observer = null,
    /// Optional SDK lifecycle observer (harness-events-001). Synchronous,
    /// callback-borrowed, infallible. Invoked in program order during
    /// `Agent.reply`. Not a replacement for the required Core sink or the
    /// existing `Observer`. Copy retained data inside the callback.
    lifecycle: ?lifecycle_mod.LifecycleObserver = null,
    /// Optional source redactor to **clone** into Agent-owned policy.
    /// When set, `secrets` / `pattern_redaction` are ignored for construction.
    redactor: ?*const redact_mod.Redactor = null,
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
    /// Exact secrets to copy into Session-owned Redactor (product path).
    secrets: []const []const u8 = &.{},
    /// Apply common API-key patterns (default true).
    pattern_redaction: bool = true,
    /// Optional source redactor to **clone** (takes precedence over secrets list).
    redactor: ?*const redact_mod.Redactor = null,
    /// skills-001: discover Agent Skills (default on). `--no-skills` / SDK false disables both roots.
    skills_enabled: bool = true,
    /// Project root scanned only when `.trusted` (default untrusted).
    project_skills_trust: skills_mod.ProjectSkillsTrust = .untrusted,
    /// Host-owned user skills root (`$HOME/.agents/skills`). SDK must pass explicitly; never getenv.
    user_skills_root: ?[]const u8 = null,
    /// prompt-templates-001: discover Prompt Templates (default on). Independent of Skills knobs.
    templates_enabled: bool = true,
    /// Project template root scanned only when `.trusted` (default untrusted).
    project_templates_trust: prompt_templates_mod.ProjectTemplatesTrust = .untrusted,
    /// Host-owned user templates root (`$HOME/.agents/prompts`). SDK must pass explicitly; never getenv.
    user_templates_root: ?[]const u8 = null,
    /// Session-store workspace root for `path` resolution (session-swap-001).
    /// Defaults to `Io.Dir.cwd()`; a TUI swap resolves the newly selected
    /// session against the same root the resume overlay listed.
    cwd: ?Io.Dir = null,
};

pub const StartError = loop.RunError || session_store.Error;
/// Loop + session + explicit-trace errors. `TraceIoFailed` is distinct from session `IoFailed`.
pub const ReplyError = loop.RunError || session_store.Error || trace_mod.Error;

pub const control_queue_capacity = control_queue_mod.capacity;
pub const control_message_max_bytes = control_queue_mod.message_max_bytes;
pub const ControlError = control_queue_mod.ControlError;
pub const ControlKind = control_queue_mod.Kind;

/// One conversation. Owns the transcript arena (heap-stable so Session is movable
/// while idle), Session-owned control queues, and when persisted the active writer
/// lease for that path. Address must remain stable while reply or queue ops run.
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
    /// Session-owned redaction policy (cloned at start; survives Agent deinit).
    owned_redactor: ?redact_mod.Redactor = null,
    /// harness-steering-001: Session-owned dual control queues (32 KiB backing).
    /// Preallocated before create/resume I/O or writer lease; process-memory only.
    control_queues: control_queue_mod.DualQueues,
    /// skills-001: process-memory skill catalog (never session/Trace schema fields).
    skills_catalog: skills_mod.Catalog = .{},
    /// skills-001: enable flag retained for tool composition (reply-time).
    skills_enabled: bool = true,
    /// prompt-templates-001: process-memory template catalog (never session/Trace schema fields).
    templates_catalog: prompt_templates_mod.Catalog = .{},
    /// prompt-templates-001: enable flag retained for host routing.
    templates_enabled: bool = true,
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
        // session-swap-001: session files resolve against the caller's chosen
        // workspace root (product = process cwd, unchanged).
        const start_cwd = opts.cwd orelse Io.Dir.cwd();

        // Control queues: preallocate BEFORE create/resume I/O or writer lease so
        // preallocation OOM cannot create a file or retain a lease (harness-steering-001).
        var control_queues = try control_queue_mod.DualQueues.init(gpa);
        errdefer control_queues.deinit(gpa);

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

        // Product path: own a redactor BEFORE any create write (fail closed on OOM).
        var owned_redactor: ?redact_mod.Redactor = null;
        errdefer if (owned_redactor) |*r| r.deinit();
        if (opts.redactor) |src| {
            owned_redactor = try src.clone(gpa);
        } else {
            owned_redactor = try redact_mod.Redactor.init(gpa, .{
                .secrets = opts.secrets,
                .patterns = opts.pattern_redaction,
            });
        }
        const redactor_ref: *const redact_mod.Redactor = &owned_redactor.?;

        // skills-001 + prompt-templates-001: discover BEFORE durable create / resume
        // writer lease paths that follow. OOM here commits no file and holds no lease
        // (errdefer cleans queues). Both complete before durable create.
        const skills_catalog = try skills_mod.discover(gpa, io, arena, .{
            .skills_enabled = opts.skills_enabled,
            .project_skills_trust = opts.project_skills_trust,
            .user_skills_root = opts.user_skills_root,
            .workspace_cwd = Io.Dir.cwd(),
        });
        const templates_catalog = try prompt_templates_mod.discover(gpa, io, arena, .{
            .templates_enabled = opts.templates_enabled,
            .project_templates_trust = opts.project_templates_trust,
            .user_templates_root = opts.user_templates_root,
            .workspace_cwd = Io.Dir.cwd(),
        });

        if (opts.path) |p| {
            switch (opts.open_mode) {
                .create_new => {
                    try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
                    writer = try session_store.createNewWithRedactor(gpa, io, start_cwd, p, transcript.items(), .{
                        .schema_version = session_store.current_schema_version,
                        .zag_version = "0.5.0",
                        .compaction_gen = compaction_gen,
                        .compaction_summary = compaction_summary,
                    }, redactor_ref);
                },
                .resume_existing => {
                    var meta: session_store.SessionMeta = .{};
                    writer = try session_store.resumeExisting(gpa, io, start_cwd, p, &transcript, &meta);
                    compaction_gen = meta.compaction_gen;
                    compaction_summary = meta.compaction_summary;
                    resumed = true;
                },
                .open_or_create => {
                    // SDK convenience: create only after typed not-found; never on parse/schema/I/O.
                    var meta: session_store.SessionMeta = .{};
                    if (session_store.resumeExisting(gpa, io, start_cwd, p, &transcript, &meta)) |w| {
                        writer = w;
                        compaction_gen = meta.compaction_gen;
                        compaction_summary = meta.compaction_summary;
                        resumed = true;
                    } else |err| switch (err) {
                        error.SessionNotFound => {
                            try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
                            writer = try session_store.createNewWithRedactor(gpa, io, start_cwd, p, transcript.items(), .{
                                .schema_version = session_store.current_schema_version,
                                .zag_version = "0.5.0",
                                .compaction_gen = compaction_gen,
                                .compaction_summary = compaction_summary,
                            }, redactor_ref);
                            // created path: project already seeded; not a resume.
                        },
                        else => |e| return e,
                    }
                },
            }
            // Reload live project file for Layers on resume only.
            if (resumed and opts.load_project_instructions) {
                if (project_mod.load(gpa, io, start_cwd) catch null) |loaded| {
                    defer gpa.free(loaded.body);
                    project_source = loaded.source;
                    project_body = arena.dupe(u8, loaded.body) catch return error.OutOfMemory;
                }
            }
        } else {
            try seedNewTranscript(gpa, io, arena, &transcript, opts, &project_body, &project_source);
        }

        // Move owned_redactor into Session (disable errdefer free).
        const moved_redactor = owned_redactor;
        owned_redactor = null;
        // Move control queues (disable errdefer free).
        const moved_queues = control_queues;
        control_queues = undefined;
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
            moved_redactor,
            moved_queues,
            skills_catalog,
            opts.skills_enabled,
            templates_catalog,
            opts.templates_enabled,
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
        owned_redactor: ?redact_mod.Redactor,
        control_queues: control_queue_mod.DualQueues,
        skills_catalog: skills_mod.Catalog,
        skills_enabled: bool,
        templates_catalog: prompt_templates_mod.Catalog,
        templates_enabled: bool,
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
            .owned_redactor = owned_redactor,
            .control_queues = control_queues,
            .skills_catalog = skills_catalog,
            .skills_enabled = skills_enabled,
            .templates_catalog = templates_catalog,
            .templates_enabled = templates_enabled,
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
            // skills-001: view-only Skills block (not a transcript row).
            .ephemeral = if (self.skills_enabled) self.skills_catalog.summary else "",
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
        // Idle-only by contract (externally synchronized against reply/enqueue).
        self.control_queues.deinit(self.gpa);
        if (self.writer) |*w| w.deinit();
        if (self.path) |p| self.gpa.free(p);
        if (self.owned_redactor) |*r| r.deinit();
        self.arena_impl.deinit();
        self.gpa.destroy(self.arena_impl);
        self.* = undefined;
    }

    /// Queue a steering message for the next safe model/Tool boundary.
    /// Copies input; caller bytes may be released after return. No allocation.
    pub fn enqueueSteering(self: *Session, text: []const u8) ControlError!void {
        return self.control_queues.enqueueSteering(text);
    }

    /// Queue a follow-up message for the next would-complete boundary.
    pub fn enqueueFollowUp(self: *Session, text: []const u8) ControlError!void {
        return self.control_queues.enqueueFollowUp(text);
    }

    pub fn steeringPending(self: *Session) usize {
        return self.control_queues.steeringPending();
    }

    pub fn followUpPending(self: *Session) usize {
        return self.control_queues.followUpPending();
    }

    /// Idle-only: discard unapplied process-memory control items.
    pub fn clearControlQueues(self: *Session) void {
        self.control_queues.clear();
    }

    /// Borrowed ControlInput bound to this Session for one `loop.run`.
    fn controlInput(self: *Session) control_input_mod.ControlInput {
        return self.control_queues.asControlInput();
    }

    /// Active session redactor (owned); null only if construction failed (should not happen).
    pub fn activeRedactor(self: *Session) ?*const redact_mod.Redactor {
        if (self.owned_redactor != null) return &self.owned_redactor.?;
        return null;
    }

    /// Const-safe borrow of the owned redactor (session-fork-001). No mutation.
    pub fn activeRedactorConst(self: *const Session) ?*const redact_mod.Redactor {
        if (self.owned_redactor != null) return &self.owned_redactor.?;
        return null;
    }

    /// Clone `src` into this session (replaces any prior owned policy).
    pub fn adoptRedactorClone(self: *Session, src: *const redact_mod.Redactor) error{OutOfMemory}!void {
        const cloned = try src.clone(self.gpa);
        if (self.owned_redactor) |*old| old.deinit();
        self.owned_redactor = cloned;
    }

    /// Persist transcript if a path is configured.
    /// Redacts arbitrary fields into temporary buffers; does not mutate in-memory transcript.
    /// Safe after Agent deinit (session owns its policy). Requires owned redactor.
    pub fn save(self: *Session) session_store.Error!void {
        if (self.writer) |*w| {
            const r = self.activeRedactor() orelse return error.OutOfMemory; // should not happen on product path
            try w.save(self.transcript.items(), .{
                .schema_version = session_store.current_schema_version,
                .zag_version = self.zag_version,
                .compaction_gen = self.compaction_gen,
                .compaction_summary = self.compaction_summary,
            }, r);
        }
    }

    /// Idle-only durable fork (session-fork-001). Parent is unchanged on every
    /// success and every failure. `child_path` is a distinct lexical relative path.
    /// Receiver is `*const Session`: no parent mutation and no const-cast to
    /// call mutable `activeRedactor`. Exclusive `createNewWithRedactor` only.
    pub fn fork(self: *const Session, child_path: []const u8) ForkError!Session {
        const gpa = self.gpa;
        const io = self.io;

        // 1. validate child_path (lexical relative)
        try session_store.validateSessionPath(child_path);

        // 2. same-as-parent durable path → typed AlreadyExists; never replace parent.
        // Honest mapping: same path is AlreadyExists (not Busy), even when parent
        // holds the writer lease on that path.
        if (self.path) |pp| {
            if (std.mem.eql(u8, pp, child_path)) return error.SessionAlreadyExists;
        }

        // Null product redactor: fail-closed **before** any durable create
        // (typed path; no panic dependency, no createNewUnredacted).
        const parent_redactor = self.activeRedactorConst() orelse return error.OutOfMemory;

        // 3. heap-stable arena (gpa.create), same as Session.start
        const arena_impl = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_impl.* = .init(gpa);
        errdefer {
            arena_impl.deinit();
            gpa.destroy(arena_impl);
        }
        const arena = arena_impl.allocator();

        // 4. empty DualQueues (do not copy parent pending); preallocate before create I/O
        var control_queues = try control_queue_mod.DualQueues.init(gpa);
        errdefer control_queues.deinit(gpa);

        // 5. const-safe Redactor.clone (field path / *const accessor; no const-cast)
        var owned_redactor = try parent_redactor.clone(gpa);
        errdefer owned_redactor.deinit();

        // 6. deep-copy transcript + live layers (not JSONL roundtrip)
        var transcript = transcript_mod.Transcript.init(arena);
        try deepCopyTranscriptInto(arena, self.transcript.items(), &transcript);

        const base_system = arena.dupe(u8, self.base_system) catch return error.OutOfMemory;
        const project_body = arena.dupe(u8, self.project_body) catch return error.OutOfMemory;
        // project_source points at static candidates; rebind, do not free/dupe required
        const project_source = self.project_source;
        const compaction_gen = self.compaction_gen;
        const compaction_summary: ?[]const u8 = if (self.compaction_summary) |s|
            arena.dupe(u8, s) catch return error.OutOfMemory
        else
            null;
        // zag_version is borrowed/static; rebind same pointer bytes
        const zag_version = self.zag_version;
        // skills-001: deep-copy live catalog/summary; no FS re-scan at fork.
        const skills_catalog = try skills_mod.deepCopyCatalog(arena, self.skills_catalog);
        const skills_enabled = self.skills_enabled;
        // prompt-templates-001: deep-copy live catalog; no FS re-scan at fork.
        const templates_catalog = try prompt_templates_mod.deepCopyCatalog(arena, self.templates_catalog);
        const templates_enabled = self.templates_enabled;

        // 7. Session.path independent of Writer.path
        const path_owned = gpa.dupe(u8, child_path) catch return error.OutOfMemory;
        errdefer gpa.free(path_owned);

        // 8. SessionMeta (schema v1)
        const meta: session_store.SessionMeta = .{
            .schema_version = session_store.current_schema_version,
            .zag_version = zag_version,
            .compaction_gen = compaction_gen,
            .compaction_summary = compaction_summary,
        };

        // 9. sole durable fallible step (create_new + redaction only)
        const redactor_ref: *const redact_mod.Redactor = &owned_redactor;
        const writer = try session_store.createNewWithRedactor(
            gpa,
            io,
            Io.Dir.cwd(),
            child_path,
            transcript.items(),
            meta,
            redactor_ref,
        );
        // 10. infallible assembly only after successful create
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
            .zag_version = zag_version,
            .owned_redactor = owned_redactor,
            .control_queues = control_queues,
            .skills_catalog = skills_catalog,
            .skills_enabled = skills_enabled,
            .templates_catalog = templates_catalog,
            .templates_enabled = templates_enabled,
            .fail_next_note_compaction = if (builtin.is_test) false else {},
        };
    }
};

/// Typed errors for `Session.fork` (session_store vocabulary).
pub const ForkError = session_store.Error;

/// Deep-copy one live Message into `arena` (nested content / tool_calls /
/// tool_call_id / content_parts). Always copies `tool_call_id` even when the
/// parent live path aliases an assistant call id in the same arena.
fn deepCopyMessage(arena: std.mem.Allocator, src: message.Message) error{OutOfMemory}!message.Message {
    const content = arena.dupe(u8, src.content) catch return error.OutOfMemory;

    var tool_calls: ?[]const message.ToolCall = null;
    if (src.tool_calls) |calls| {
        const out = arena.alloc(message.ToolCall, calls.len) catch return error.OutOfMemory;
        for (calls, 0..) |c, i| {
            out[i] = .{
                .id = arena.dupe(u8, c.id) catch return error.OutOfMemory,
                .name = arena.dupe(u8, c.name) catch return error.OutOfMemory,
                .arguments = arena.dupe(u8, c.arguments) catch return error.OutOfMemory,
            };
        }
        tool_calls = out;
    }

    var tool_call_id: ?[]const u8 = null;
    if (src.tool_call_id) |id| {
        tool_call_id = arena.dupe(u8, id) catch return error.OutOfMemory;
    }

    var content_parts: ?[]const message.ContentPart = null;
    if (src.content_parts) |parts| {
        const out = arena.alloc(message.ContentPart, parts.len) catch return error.OutOfMemory;
        for (parts, 0..) |p, i| {
            out[i] = switch (p) {
                .text => |t| .{ .text = arena.dupe(u8, t) catch return error.OutOfMemory },
                .image_url => |img| blk: {
                    const url = arena.dupe(u8, img.url) catch return error.OutOfMemory;
                    const detail: ?[]const u8 = if (img.detail) |d|
                        arena.dupe(u8, d) catch return error.OutOfMemory
                    else
                        null;
                    break :blk .{ .image_url = .{ .url = url, .detail = detail } };
                },
            };
        }
        content_parts = out;
    }

    return .{
        .role = src.role,
        .content = content,
        .content_parts = content_parts,
        .tool_calls = tool_calls,
        .tool_call_id = tool_call_id,
    };
}

fn deepCopyTranscriptInto(
    arena: std.mem.Allocator,
    src_items: []const message.Message,
    dest: *transcript_mod.Transcript,
) error{OutOfMemory}!void {
    dest.messages.ensureTotalCapacity(arena, src_items.len) catch return error.OutOfMemory;
    for (src_items) |m| {
        const copied = try deepCopyMessage(arena, m);
        dest.messages.append(arena, copied) catch return error.OutOfMemory;
    }
}

// ── D-011 RunBridge: local owner of the five seam pointers for one reply ─────
//
// A `RunBridge` is constructed as a local in `Agent.reply` BEFORE any seam
// pointer is formed, lives on the stack for the entire synchronous `loop.run`,
// and is never copied/moved/returned. The five seam values borrow its fields,
// so their `ptr` arguments remain stable for the whole run. The current
// product behavior (Observer fan-out, durable Trace, session compaction note,
// generic warnings) is preserved byte-for-byte by the adapter vtables below.

const RunBridge = struct {
    agent: *Agent,
    session: *Session,
    /// Resolved permission gate (borrowed by the tool_policy seam).
    gate: permissions.Gate,
    /// Borrowed trace pointer for this reply (null when tracing is off).
    trace: ?*trace_mod.Trace,
    /// Owned resolved workspace root real path (absolute). Allocated in
    /// `Agent.reply` with the same gpa used for `loop.run`; the slice address/
    /// bytes cover the entire synchronous `loop.run` and are freed on reply
    /// exit. Null when resolve failed (handlers/jail lazy-resolve or fail closed).
    workspace_root_real: ?[]u8 = null,
    /// skills-001: per-reply gpa-owned base+read_skill tool slice (null = base only).
    composed_tools: ?[]tool.Tool = null,

    // ── harness-events-001 lifecycle derivation ────────────────────────────
    //
    // `current_turn` and `next_call_index` are derived from the Core source
    // facts that flow through `bridgeSinkEmit`. `turn_start` resets
    // `next_call_index` to 0 and sets `current_turn`. `tool_start` uses the
    // current index but does NOT increment (the matching `tool_end` increments
    // after emit). `tool_end` (including end-only cancelled) uses the current
    // index and increments after emit. This keeps ordinary start→end pairs at
    // the same index, and pending-cancel end-only calls at the index they would
    // have occupied in program order.

    /// 1-based turn counter, derived from `LoopEvent.turn_start`.
    current_turn: u32 = 0,
    /// 0-based call index within the current turn, derived from tool_start/tool_end.
    /// A start uses this index without advancing it; the corresponding end (or
    /// an end-only pending cancellation) advances it after successful fan-out.
    next_call_index: u32 = 0,

    fn deinitComposedTools(self: *RunBridge) void {
        if (self.composed_tools) |t| {
            self.agent.gpa.free(t);
            self.composed_tools = null;
        }
    }

    /// skills-001: dynamically append `read_skill` when invocable skills exist.
    /// Duplicate reserved name → InvalidToolset before provider. No fixed [8].
    fn prepareToolset(self: *RunBridge) error{ OutOfMemory, InvalidToolset }!tool.Toolset {
        const base = self.agent.effectiveToolset();
        if (!self.session.skills_enabled or !self.session.skills_catalog.hasInvocable()) {
            return base;
        }
        const composed = try skills_mod.composeToolsetWithReadSkill(
            self.agent.gpa,
            base.tools,
            &self.session.skills_catalog,
        );
        if (composed) |slice| {
            self.composed_tools = slice;
            return .{ .tools = slice };
        }
        return base;
    }

    /// Build the `loop.Deps` borrowing this bridge's fields. The caller must
    /// keep this `RunBridge` alive and unmoved for the duration of `loop.run`.
    /// `toolset` must already be prepared via `prepareToolset`.
    fn deps(self: *RunBridge, toolset: tool.Toolset) loop.Deps {
        const a = self.agent;
        return .{
            .gpa = a.gpa,
            .provider = a.provider,
            .toolset = toolset,
            .tool_ctx = .{
                .allocator = a.gpa,
                .io = a.io,
                .cwd = Io.Dir.cwd(),
                .workspace_root_real = self.workspace_root_real,
            },
            .tool_policy = .{ .ptr = self, .vtable = &bridge_policy_vtable },
            .jail = .{ .ptr = null, .vtable = &workspace_guard_jail_vtable },
            .shell_policy = if (a.options.shell_policy == .off)
                shell_policy_mod.ShellPolicy.allowAllForTrustedHost()
            else
                .{ .ptr = null, .vtable = &protect_shell_vtable },
            .context_view = .{ .ptr = self, .vtable = &bridge_context_vtable },
            .event_sink = .{ .ptr = self, .vtable = &bridge_sink_vtable },
            // Bound to the exact *Session of this reply; Agent does not cache Session.
            .control_input = self.session.controlInput(),
            .options = .{
                .max_turns = a.options.max_turns,
                .chat_retries = a.options.chat_retries,
                .retry_base_delay_ms = a.options.retry_base_delay_ms,
                .cancel = &a.cancel,
                .provider_timeout_ms = a.options.provider_timeout_ms,
            },
        };
    }
};

// ── ToolPolicy adapter over `permissions.Gate` ────────────────────────────────

const bridge_policy_vtable: tool_policy_mod.ToolPolicyVTable = .{
    .check = bridgePolicyCheck,
    .deniedBody = bridgePolicyDeniedBody,
};

fn bridgePolicyCheck(
    ptr: ?*anyopaque,
    descriptor: tool.ToolDescriptor,
    arguments_json: []const u8,
    path: ?[]const u8,
) tool_policy_mod.Outcome {
    const bridge: *RunBridge = @ptrCast(@alignCast(ptr.?));
    const o = bridge.gate.check(descriptor, arguments_json, path);
    return .{
        .decision = switch (o.decision) {
            .allow => .allow,
            .deny => .deny,
        },
        .remembered = o.remembered,
        .plan_blocked = o.plan_blocked,
    };
}

/// Product deny body renderer: calls the moved `permissions.deniedMessage` /
/// `permissions.deniedMessageWithReason` so body bytes stay identical to the
/// baseline. Called only after a deny decision; returns an owned body.
fn bridgePolicyDeniedBody(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    descriptor: tool.ToolDescriptor,
    outcome: tool_policy_mod.Outcome,
) error{OutOfMemory}![]u8 {
    _ = ptr;
    if (outcome.plan_blocked)
        return permissions.deniedMessageWithReason(allocator, descriptor.definition.name, .plan_mode)
    else
        return permissions.deniedMessage(allocator, descriptor.definition.name);
}

// ── Jail adapter over Coding `workspace.Guard` containment ────────────────────
//
// The product jail adapter wraps the moved `workspace.Guard` containment logic.
// It lives in `zag-coding-agent` (moved from Core by core-policy-ownership-001);
// behavior is byte-identical to the prior inline loop gate
// (`guardCheckOwned` + `workspace.deniedMessage`).

const workspace_guard_jail_vtable: jail_mod.JailVTable = .{
    .check = workspaceGuardJailCheck,
};

fn workspaceGuardJailCheck(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    workspace_root_real: ?[]const u8,
    tool_name: []const u8,
    path: ?[]const u8,
) jail_mod.JailError!jail_mod.Check {
    _ = tool_name;
    const p = path orelse return .{ .verdict = .allow };
    if (try guardCheckOwned(allocator, io, cwd, workspace_root_real, p)) |deny_body| {
        return .{ .verdict = .deny, .deny_body = deny_body };
    }
    return .{ .verdict = .allow };
}

/// Jail check on an already-extracted path (lexical + real containment).
/// Returns an owned deny message, or null if path is OK for the handler.
/// Ordinary `NotFound` is allowed through — handlers report ToolFailed, not
/// jail_deny. Behavior matches the prior inline `guardCheckOwned`.
fn guardCheckOwned(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    workspace_root_real: ?[]const u8,
    path: []const u8,
) jail_mod.JailError!?[]u8 {
    var guard = workspace.guardFrom(allocator, io, cwd, workspace_root_real) catch {
        return @as(?[]u8, try workspace.deniedMessage(allocator));
    };
    defer guard.deinit(allocator);

    guard.checkExisting(io, cwd, path) catch |err| switch (err) {
        error.NotFound => {
            guard.checkCreate(allocator, io, cwd, path) catch |cerr| switch (cerr) {
                error.NotFound => {},
                error.OutOfMemory => return error.OutOfMemory,
                error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
                    return @as(?[]u8, try workspace.deniedMessage(allocator));
                },
            };
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => {
            return @as(?[]u8, try workspace.deniedMessage(allocator));
        },
    };
    return null;
}

// ── ShellPolicy adapter over Coding `shell_policy` denylist ───────────────────

const protect_shell_vtable: shell_policy_mod.ShellPolicyVTable = .{
    .check = protectShellCheck,
    .deniedBody = protectShellDeniedBody,
};

fn protectShellCheck(_: ?*anyopaque, command: []const u8) shell_policy_mod.Decision {
    return switch (shell_policy.check(.protect, command)) {
        .allow => .allow,
        .deny => .deny,
    };
}

/// Product shell deny body: calls the moved `shell_policy.deniedMessage` so
/// body bytes stay identical to the baseline.
fn protectShellDeniedBody(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    command: []const u8,
) error{OutOfMemory}![]u8 {
    return shell_policy.deniedMessage(allocator, command);
}

// ── ContextView adapter over `context.viewForModel` + session layers ──────────

const bridge_context_vtable: context_view_mod.ContextViewVTable = .{
    .view = bridgeContextView,
};

fn bridgeContextView(
    ptr: ?*anyopaque,
    scratch: std.mem.Allocator,
    transcript_items: []const message.Message,
) context_view_mod.ContextViewError!context_view_mod.View {
    const bridge: *RunBridge = @ptrCast(@alignCast(ptr.?));
    const a = bridge.agent;
    const session = bridge.session;
    const layers = session.layers();
    const v = context_mod.viewForModel(
        a.io,
        scratch,
        transcript_items,
        a.options.context,
        layers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidContext => return error.InvalidContext,
    };
    return .{ .messages = v.messages, .compaction = v.compaction };
}

// ── compaction-llm-001: product CompactionSummarizer over the provider ──────

/// Bounded deadline for one summarizer provider call (ms). No new config key;
/// the existing `provider_timeout_ms` caps it when set.
const summary_call_deadline_ms: u64 = 60_000;

const agent_summarizer_vtable: ztypes.CompactionSummarizerVTable = .{
    .summarize = agentSummarize,
};

/// Product `CompactionSummarizer` over the existing provider (compaction-llm-001).
/// `agent` is borrowed and must outlive every `reply`; install the result in
/// `options.context.summarizer` before `Agent.init`:
/// ```zig
/// var agent: Agent = undefined;
/// agent = try Agent.init(gpa, io, provider, .{
///     .context = .{ .summarizer = compactionSummarizer(&agent) },
/// });
/// ```
pub fn compactionSummarizer(agent: *Agent) ztypes.CompactionSummarizer {
    return .{ .ptr = agent, .vtable = &agent_summarizer_vtable };
}

/// One summary provider call: single system + user message, bounded
/// `RequestControl` deadline, errors mapped to `SummaryErrorKind`. The
/// response text is allocated from the Agent's per-call scratch arena and is
/// valid until the summarizer's next call (the retry ladder copies it
/// immediately).
fn agentSummarize(ptr: *anyopaque, request: ztypes.SummaryRequest) ztypes.SummaryResult {
    const a: *Agent = @ptrCast(@alignCast(ptr));
    // Previous responses were already consumed; start each call clean.
    _ = a.summary_scratch.reset(.retain_capacity);
    const arena = a.summary_scratch.allocator();

    const messages = [_]message.Message{
        .{ .role = .system, .content = request.system },
        .{ .role = .user, .content = request.prompt },
    };

    const timeout_ms = if (a.options.provider_timeout_ms) |pt|
        @min(pt, summary_call_deadline_ms)
    else
        summary_call_deadline_ms;
    var control = ztypes.RequestControl.withTimeoutMs(ztypes.monoNowNs(), timeout_ms);
    control = control.withCancel(&a.cancel);

    const turn = a.provider.chat(arena, &messages, &.{}, control, null) catch |err| {
        return .{ .err = .{ .kind = mapSummaryErrorKind(err), .message = @errorName(err) } };
    };
    return .{ .ok = .{ .text = turn.content } };
}

/// Map provider `ChatError` to `SummaryErrorKind` (binding §5): timeout →
/// `.timeout`; auth/schema/capability/cancel → `.deterministic` (never
/// retried); rate-limit/network/server → `.transient`. `request.max_tokens`
/// is the requested output ceiling; the wire applies its own configured
/// `chat_options.max_tokens` as the provider cap (the type-erased Provider
/// port has no per-call max_tokens parameter).
fn mapSummaryErrorKind(err: provider_mod.ChatError) ztypes.SummaryErrorKind {
    return switch (err) {
        error.Timeout => .timeout,
        error.RateLimited, error.HttpFailed, error.StreamFailed, error.WriteFailed, error.ServerError, error.Unexpected, error.BadStatus => .transient,
        error.AuthenticationFailed, error.PermissionDenied, error.InvalidResponse, error.BadRequest, error.NotSupported, error.UnsupportedControl, error.Cancelled, error.OutOfMemory => .deterministic,
    };
}

// ── LoopEventSink adapter: the existing per-event fan-out (Observer + Trace) ─

const bridge_sink_vtable: loop_event_mod.LoopEventSinkVTable = .{
    .emit = bridgeSinkEmit,
};

fn bridgeSinkEmit(ptr: ?*anyopaque, event: loop_event_mod.LoopEvent) loop_event_mod.SinkError!void {
    const bridge: *RunBridge = @ptrCast(@alignCast(ptr.?));
    const a = bridge.agent;
    switch (event) {
        .turn_start => |turn| {
            bridge.current_turn = turn;
            bridge.next_call_index = 0;
            if (bridge.trace) |tr| {
                tr.emitTurn(turn) catch |err| return mapTraceToSink(err);
            }
        },
        .assistant_message => |am| {
            // Existing Observer remains first; lifecycle is an infallible
            // product projection; durable Trace keeps its prior final position.
            emitObserver(a, .{ .assistant_text = am.text });
            a.emitLifecycle(.{ .assistant_message = .{
                .turn = bridge.current_turn,
                .text = am.text,
                .has_tools = am.has_tools,
                .reasoning = am.reasoning,
            } });
            if (bridge.trace) |tr| {
                tr.emitAssistant(am.text) catch |err| return mapTraceToSink(err);
            }
        },
        .assistant_delta => |delta| {
            // Observer first, then lifecycle (same order as assistant_message).
            // No Trace kind: deltas are UI-visible only (tui-streaming-001).
            emitObserver(a, .{ .assistant_delta = delta });
            a.emitLifecycle(.{ .assistant_delta = delta });
        },
        .assistant_delta_clear => {
            // Observer first, then lifecycle. No Trace kind, no persistence.
            emitObserver(a, .{ .assistant_delta_clear = {} });
            a.emitLifecycle(.{ .assistant_delta_clear = {} });
        },
        .thinking_delta => |delta| {
            // Lifecycle only (tui-thinking-streaming-001): the observer stays
            // unchanged so headless/CLI stdout is byte-identical — thinking is
            // UI-visible only, same discipline as assistant_delta. No Trace
            // kind, no persistence.
            a.emitLifecycle(.{ .thinking_delta = delta });
        },
        .usage => |u| {
            // Trace usage, then user Observer/ledger/verbose/cost.
            if (bridge.trace) |tr| {
                tr.emitUsage(.{ .usage = u }) catch |err| return mapTraceToSink(err);
            }
            emitObserver(a, .{ .usage = u });
        },
        .tool_start => |call| {
            // Existing Observer remains first, then lifecycle, then Trace.
            // The index advances only when the final tool_end source fact arrives.
            emitObserver(a, .{ .tool_call = call });
            a.emitLifecycle(.{ .tool_start = .{
                .turn = bridge.current_turn,
                .call_index = bridge.next_call_index,
                .id = call.id,
                .name = call.name,
                .arguments = call.arguments,
            } });
            if (bridge.trace) |tr| {
                tr.emitToolCall(call) catch |err| return mapTraceToSink(err);
            }
        },
        .tool_end => |r| {
            // End-only pending cancellations use the next program-order index;
            // no synthetic tool_start is invented for a call that never ran.
            emitObserver(a, .{ .tool_result = .{ .name = r.name, .body = r.body } });
            a.emitLifecycle(.{ .tool_end = .{
                .turn = bridge.current_turn,
                .call_index = bridge.next_call_index,
                .id = r.id,
                .name = r.name,
                .body = r.body,
            } });
            if (bridge.trace) |tr| {
                tr.emitToolResult(r.name, r.body) catch |err| return mapTraceToSink(err);
            }
            bridge.next_call_index +|= 1;
        },
        .policy_decision => |p| {
            // Observer, then Trace permission.
            emitObserver(a, .{
                .permission = .{
                    .tool_name = p.tool_name,
                    .allowed = p.allowed,
                    .remembered = p.remembered,
                    .risk = p.risk,
                },
            });
            if (bridge.trace) |tr| {
                tr.emitPermission(p.tool_name, p.risk orelse "?", p.allowed, p.remembered) catch |err| return mapTraceToSink(err);
            }
        },
        .jail_decision => |j| {
            // Trace first, then generic warning. The warning is unconditional here
            // because the RunBridge represents the high-level product composition,
            // whose baseline loop always wired an internal Observer callback
            // (onAgentEvent) with on_event != null; that internal path was always
            // active on the product path regardless of whether the caller supplied
            // a user Observer. The guard content stays generic (no raw path).
            if (bridge.trace) |tr| {
                tr.emitJailDeny(j.tool_name, j.path) catch |err| return mapTraceToSink(err);
            }
            std.log.warn("jail deny", .{});
        },
        .shell_decision => |command| {
            // Trace first, then generic warning (unconditional product path; see
            // jail_decision). Generic only — never log raw command (secrets).
            if (bridge.trace) |tr| {
                tr.emitShellDeny(command) catch |err| return mapTraceToSink(err);
            }
            std.log.warn("shell policy deny", .{});
        },
        .provider_retry => |r| {
            // Trace first, then generic warning (unconditional product path; see
            // jail_decision). The err_name is a stable error tag, not raw detail.
            if (bridge.trace) |tr| {
                tr.emitProviderRetry(r.attempt, r.err_name) catch |err| return mapTraceToSink(err);
            }
            std.log.warn(
                "provider retry {d}/{d} after {s}",
                .{ r.attempt, a.options.chat_retries, r.err_name },
            );
        },
        .provider_failed => |r| {
            // Terminal ChatError tag before error.ProviderFailed. Trace reuses
            // provider_retry with attempt=0 so the cause is auditable without a
            // new Trace kind. err_name is a stable @errorName only.
            // warn (not err): zig test fails the suite on error-level logs even
            // when assertions pass — provider-failure fixtures would red CI.
            if (bridge.trace) |tr| {
                tr.emitProviderRetry(0, r.err_name) catch |err| return mapTraceToSink(err);
            }
            std.log.warn("provider failed: {s}", .{r.err_name});
        },
        .context_compaction => |ev| {
            // Session note first, then Trace compaction (h-context-001).
            bridge.session.noteCompaction(ev) catch return error.OutOfMemory;
            if (bridge.trace) |tr| {
                tr.emitCompactionEvent(ev) catch |err| return mapTraceToSink(err);
            }
        },
        .control_applied => |c| {
            // Lifecycle-only projection (harness-steering-001). No Trace kind,
            // no Observer event, no headless serialization.
            a.emitLifecycle(.{ .control_applied = .{
                .kind = switch (c.kind) {
                    .steering => .steering,
                    .follow_up => .follow_up,
                },
                .next_turn = c.next_turn,
                .text = c.text,
            } });
        },
    }
}

/// Emit to the user Observer and run the internal usage/verbose ledger path.
/// Mirrors the prior `onAgentEvent` exactly (user observer first, then
/// ledger/verbose).
fn emitObserver(a: *Agent, event: observer_mod.Event) void {
    if (a.options.observer) |user| {
        user.emit(event);
    }
    switch (event) {
        .usage => |u| {
            a.ledger.recordModel(u, a.options.model_info);
            if (a.options.verbose) {
                observer_mod.logEventRedacted(a.gpa, a.activeRedactor(), event);
                if (a.ledger.cost.known) {
                    std.log.info("cost est cumulative=${d:.6}", .{a.ledger.cost.total});
                }
            }
        },
        else => {
            if (a.options.verbose) {
                observer_mod.logEventRedacted(a.gpa, a.activeRedactor(), event);
            }
        },
    }
}

/// Map `trace.Error` to the sink error set. `OutOfMemory` stays `OutOfMemory`;
/// durable/serialization/path faults become `SinkFailed` (→ loop `TraceFailed`).
fn mapTraceToSink(err: trace_mod.Error) loop_event_mod.SinkError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TraceIoFailed, error.InvalidPath, error.TraceSerializationFailed => error.SinkFailed,
    };
}

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: provider_mod.Provider,
    tools_storage: toolset_mod.Phase1Storage,
    /// Heap-stable default `apply_hunk` state (B7). Outlives all reply/Tool copies.
    apply_hunk_state: *edit_tools.ApplyHunkState,
    /// Heap-stable scratch arena for LLM compaction-summary responses
    /// (compaction-llm-001). Reset before each summarizer call; the response
    /// text only needs to live until the retry ladder copies it.
    summary_scratch: *std.heap.ArenaAllocator,
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
    /// Facade-owned public lifecycle state for the current synchronous reply.
    /// Set only after beginRun succeeds; cleared before the terminal callback.
    lifecycle_run_open: bool = false,
    /// Always owned after successful init (clone of options.redactor or built from secrets).
    owned_redactor: redact_mod.Redactor,
    /// Test-only toolset override for InvalidToolset fixtures (production always null).
    test_tools: if (builtin.is_test) ?[]const tool.Tool else void =
        if (builtin.is_test) null else {},

    /// Fail-closed: redactor construction OOM returns before any network/disk use.
    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) error{OutOfMemory}!Agent {
        // Build owned redactor first (never swallow OOM).
        var owned_redactor: redact_mod.Redactor = if (options.redactor) |src|
            try src.clone(gpa)
        else
            try redact_mod.Redactor.init(gpa, .{
                .secrets = options.secrets,
                .patterns = options.pattern_redaction,
            });
        errdefer owned_redactor.deinit();

        // B7: heap-stable ApplyHunkState for default toolset instance pointer.
        // Ports borrowed from Options at init; custom toolset does not auto-splice them.
        const apply_state = try gpa.create(edit_tools.ApplyHunkState);
        errdefer gpa.destroy(apply_state);
        apply_state.* = .{
            .reviewer = options.hunk_reviewer,
            .verifier = options.post_edit_verifier,
        };

        // compaction-llm-001: per-Agent scratch for summarizer provider
        // responses (reset per summarize call; deinit'd with the Agent).
        const summary_scratch = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(summary_scratch);
        summary_scratch.* = .init(gpa);

        var self: Agent = .{
            .gpa = gpa,
            .io = io,
            .provider = provider,
            .tools_storage = .init(apply_state),
            .apply_hunk_state = apply_state,
            .summary_scratch = summary_scratch,
            .options = options,
            .stdin_prompter = .{ .io = io },
            .permission_gate = .yolo(),
            .remember_store = .init(gpa, options.remember_writes),
            .trace = null,
            .ledger = .{},
            .cancel = .{},
            .lifecycle_run_open = false,
            .owned_redactor = owned_redactor,
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
            tr.setRedactor(null);
            tr.deinit();
        }
        self.owned_redactor.deinit();
        self.gpa.destroy(self.apply_hunk_state);
        self.summary_scratch.deinit();
        self.gpa.destroy(self.summary_scratch);
        self.* = undefined;
    }

    /// Live rebind of default-toolset reviewer (CLI post-init cancel wiring). No-op for custom toolset use.
    pub fn setHunkReviewer(self: *Agent, reviewer: ?edit_tools.HunkReviewer) void {
        self.apply_hunk_state.reviewer = reviewer;
        self.options.hunk_reviewer = reviewer;
    }

    /// Live rebind of default-toolset verifier. No-op semantics for custom toolsets (not auto-spliced).
    pub fn setPostEditVerifier(self: *Agent, verifier: ?edit_tools.PostEditVerifier) void {
        self.apply_hunk_state.verifier = verifier;
        self.options.post_edit_verifier = verifier;
    }

    /// Active redactor (Agent-owned; stable for Agent lifetime).
    pub fn activeRedactor(self: *Agent) *const redact_mod.Redactor {
        return &self.owned_redactor;
    }

    pub fn getRedactor(self: *const Agent) *const redact_mod.Redactor {
        return &self.owned_redactor;
    }

    /// Open the optional public lifecycle only after facade preflight and Trace
    /// run_start preparation succeed. Preflight failures never call this.
    fn startLifecycle(self: *Agent, session_configured: bool) void {
        std.debug.assert(!self.lifecycle_run_open);
        self.lifecycle_run_open = true;
        if (self.options.lifecycle) |observer| {
            observer.emit(.{ .run_start = .{ .session_configured = session_configured } });
        }
    }

    /// Emit one nonterminal lifecycle projection while this reply is open.
    /// The callback is infallible and receives callback-borrowed slices.
    fn emitLifecycle(self: *Agent, event: lifecycle_mod.LifecycleEvent) void {
        if (!self.lifecycle_run_open) return;
        if (self.options.lifecycle) |observer| observer.emit(event);
    }

    fn lifecycleUsage(self: *const Agent) message.Usage {
        return lifecycle_mod.usageFromLedger(
            self.ledger.prompt_tokens,
            self.ledger.completion_tokens,
            self.ledger.total_tokens,
            self.ledger.reasoning_tokens,
        );
    }

    /// Emit the exactly-once final public lifecycle fact. Close the run before
    /// entering host code so unsupported callback re-entry cannot duplicate it.
    fn emitLifecycleTerminal(
        self: *Agent,
        turns: u32,
        ok: bool,
        stop_reason: loop.StopReason,
    ) void {
        if (!self.lifecycle_run_open) {
            std.debug.assert(false);
            return;
        }
        self.lifecycle_run_open = false;
        if (self.options.lifecycle) |observer| {
            observer.emit(.{ .run_terminal = .{
                .turns = turns,
                .ok = ok,
                .stop_reason = stop_reason,
                .usage = self.lifecycleUsage(),
            } });
        }
    }

    pub fn initPhase0(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) error{OutOfMemory}!Agent {
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
        // Caller-provided custom toolset takes precedence; lifetime is borrowed
        // from the caller and must outlive all `Agent.reply` calls.
        if (self.options.toolset) |tools| return .{ .tools = tools };
        if (builtin.is_test) {
            if (self.test_tools) |override| return .{ .tools = override };
        }
        return self.tools_storage.toolset();
    }

    /// Cooperative cancel request; safe to call from another thread/signal handler.
    /// The flag is checked between turns and between tools, not mid-handler.
    pub fn requestCancel(self: *Agent) void {
        self.cancel.request();
    }

    /// Ensure session owns a redactor (clone from Agent if missing); bind trace for this reply only.
    fn ensureSessionRedactor(self: *Agent, session: *Session) error{OutOfMemory}!void {
        if (session.owned_redactor == null) {
            try session.adoptRedactorClone(self.activeRedactor());
        }
    }

    fn clearTraceRedactor(self: *Agent) void {
        if (self.trace) |*tr| tr.setRedactor(null);
    }

    /// Per-reply prep: reset ledger + trace buffer, non-destructive preflight,
    /// then `run_start`. Lifecycle owner: facade (loop + session save + persist).
    fn beginRun(self: *Agent, session: *Session) ReplyError!void {
        // cli-sigint-001 (review item 3): the cancel flag is cleared at the
        // run-COMPLETION boundary (see `reply`/`completeWithSession`), NOT
        // here. Clearing here would silently drop a SIGINT that arrived after
        // the guard was installed but before this run began (a pre-run pending
        // cancel that must apply to the current run). A flag set before this
        // run's first loop iteration is observed immediately by `loop.run` as
        // a cooperative cancel, so a pre-run interrupt lands on this run
        // instead of being erased. The completion boundary clears the flag so
        // the NEXT interaction starts clean (no stale cancel inherited).
        // Fresh run-local cost ledger each reply.
        self.ledger = .{};
        // Drop any stale borrowed redactor **before** fallible ensure/bind so a
        // clone OOM cannot leave a prior-reply pointer on the Trace.
        self.clearTraceRedactor();
        try self.ensureSessionRedactor(session);
        // Trace borrows session policy only for this synchronous reply.
        if (self.trace) |*tr| tr.setRedactor(session.activeRedactor());
        errdefer self.clearTraceRedactor();
        const tr = if (self.trace) |*t| t else return;
        try tr.beginReply();
        try tr.emitRunStart(.{
            .version = self.options.version,
            .permission = self.options.permission_mode.name(),
            .shell_policy = self.options.shell_policy.name(),
            // Do not put raw session path into trace (may contain secrets).
            .session = if (session.path != null) "configured" else null,
        });
    }

    /// Commit exactly one terminal for the open run. No-op when tracing is off
    /// or the run already closed. Propagates persistence I/O as `TraceIoFailed`.
    fn controlledStop(stop: loop.StopReason) trace_mod.Trace.ControlledStop {
        return switch (stop) {
            .completed => .completed,
            .max_turns => .max_turns,
            .cancelled => .cancelled,
            .timeout => .timeout,
            .unsupported_control => .unsupported_control,
            .provider_error => .provider_error,
            .session_error => .session_error,
            .trace_error => .trace_error,
            .out_of_memory => .out_of_memory,
            .invalid_toolset => .invalid_toolset,
            .invalid_context => .invalid_context,
        };
    }

    fn commitTerminal(
        self: *Agent,
        turns: u32,
        ok: bool,
        stop_reason: loop.StopReason,
    ) trace_mod.Error!void {
        const tr = if (self.trace) |*t| t else return;
        if (!tr.run_open or tr.finished) return;
        const usd: ?f64 = if (self.ledger.cost.known) self.ledger.cost.total else null;
        // Controlled vocabulary: allocation-free, no public free-form redaction path.
        try tr.emitRunEndControlled(turns, ok, controlledStop(stop_reason), .{
            .prompt_tokens = self.ledger.prompt_tokens,
            .completion_tokens = self.ledger.completion_tokens,
            .total_tokens = self.ledger.total_tokens,
            .estimated_usd = usd,
        }); // ControlledUsage
    }

    /// Commit a failure terminal; never swallow commit errors.
    ///
    /// Fail-closed precedence: if persisting/serializing the failure terminal
    /// itself fails, return the **trace** error (or OOM), not the primary.
    /// When commit succeeds, return `primary`.
    ///
    /// `turns_hint` is the facade-owned progress (typically `RunBridge.current_turn`
    /// after loop source facts, or `Result.turns` after a normal Result). When
    /// Trace is active it is merged with `Trace.last_emitted_turn` so mid-run
    /// failures report progress even if the hint lags; without Trace the hint
    /// alone must be truthful for public lifecycle terminals.
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
        // Redactor clear is owned by reply()'s defer covering all exits.
        // The public terminal reflects final error precedence even when the
        // durable Trace terminal operation itself fails.
        self.commitTerminal(turns, false, stop_reason) catch |terr| {
            self.emitLifecycleTerminal(turns, false, stopReasonForTraceError(terr));
            return terr;
        };
        self.emitLifecycleTerminal(turns, false, stop_reason);
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

    /// A terminal Trace operation can itself fail. Preserve the established
    /// facade distinction: allocator failure remains out_of_memory; durable,
    /// path, and serialization failures become trace_error.
    fn stopReasonForTraceError(err: trace_mod.Error) loop.StopReason {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.TraceIoFailed, error.InvalidPath, error.TraceSerializationFailed => .trace_error,
        };
    }

    fn resultOk(stop: loop.StopReason) bool {
        return switch (stop) {
            // Clean cooperative cancel is a normal Result, not a harness failure.
            .completed, .max_turns, .cancelled => true,
            // Deadline / unsupported control are failed runs (ok=false).
            .timeout, .unsupported_control, .provider_error, .session_error, .trace_error, .out_of_memory, .invalid_toolset, .invalid_context => false,
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
        // cli-sigint-001 (review item 3 + P2 follow-up): clear the cancel flag
        // at the run-completion boundary so the next interaction starts clean.
        // The defer is registered BEFORE `beginRun` so a beginRun preflight
        // failure (trace/session-redactor OOM) still clears the flag — a
        // pre-set cancel cannot survive a failed run start and bleed into the
        // next reply. A cancel that landed during a successful run already
        // produced its `.cancelled` result (or was observed by `loop.run`);
        // pre-run pending cancels are applied to this run by `loop.run` (which
        // checks the flag before the first provider call), not erased here.
        defer self.cancel.clear();
        // Clear borrowed trace redactor on every exit (success, failRun, persist fault).
        defer self.clearTraceRedactor();
        // Public lifecycle open-flag hygiene:
        // - A prior reply must not leave the flag open (missing terminal). Debug
        //   asserts; release still clears so the next reply can start clean.
        // - On exit, if the flag is still open, Debug asserts (forgotten
        //   terminal path). Never fabricate a public terminal here — cleanup only.
        if (self.lifecycle_run_open) {
            std.debug.assert(false);
            self.lifecycle_run_open = false;
        }
        defer {
            if (self.lifecycle_run_open) {
                std.debug.assert(false);
                self.lifecycle_run_open = false;
            }
        }
        try self.beginRun(session);
        self.startLifecycle(session.path != null);
        session.zag_version = self.options.version;

        session.transcript.appendUser(user_text) catch |err| {
            return self.failRun(0, .out_of_memory, err);
        };

        // D-011: build the local RunBridge owning the five seam pointers for
        // this synchronous run. Its address is stable for the whole loop.run
        // and is never copied/moved/returned. The seams borrow its fields.
        //
        // The workspace root is resolved once here (product facade), BEFORE any
        // seam pointer is formed, using the same gpa/io/cwd that `loop.run` will
        // use. The owned slice is stored on the bridge and freed on reply exit;
        // its address/bytes cover the entire synchronous `loop.run`. This matches
        // the prior Core loop behavior (resolveCwdReal catch null) but moves
        // ownership to the product facade where it belongs (D-011).
        var bridge: RunBridge = .{
            .agent = self,
            .session = session,
            .gate = self.resolveGate(),
            .trace = if (self.trace) |*tr| tr else null,
            .workspace_root_real = workspace.resolveCwdReal(self.gpa, self.io, Io.Dir.cwd()) catch null,
        };
        defer if (bridge.workspace_root_real) |r| self.gpa.free(r);
        defer bridge.deinitComposedTools();

        // skills-001: per-reply toolset composition (append read_skill when invocable).
        // Session address remains stable; allocation is bridge-scoped.
        const reply_toolset = bridge.prepareToolset() catch |err| {
            return self.failRun(0, stopReasonForRunError(err), err);
        };

        // On loop error, public turns come from the facade-owned bridge turn
        // counter (updated on Core `turn_start`). failRun still maxes with
        // Trace.last_emitted_turn when Trace is present.
        const result = loop.run(bridge.deps(reply_toolset), &session.transcript) catch |err| {
            return self.failRun(bridge.current_turn, stopReasonForRunError(err), err);
        };

        // Save before committing a successful terminal so save failure cannot leave ok=true.
        session.save() catch |err| {
            return self.failRun(result.turns, .session_error, err);
        };

        // Final persist on success path. A terminal Trace failure overrides the
        // earlier Result for both the returned error and public lifecycle truth.
        const ok = resultOk(result.stop_reason);
        self.commitTerminal(result.turns, ok, result.stop_reason) catch |terr| {
            self.emitLifecycleTerminal(result.turns, false, stopReasonForTraceError(terr));
            return terr;
        };
        self.emitLifecycleTerminal(result.turns, ok, result.stop_reason);
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
            skills_enabled: bool = true,
            project_skills_trust: skills_mod.ProjectSkillsTrust = .untrusted,
            user_skills_root: ?[]const u8 = null,
            templates_enabled: bool = true,
            project_templates_trust: prompt_templates_mod.ProjectTemplatesTrust = .untrusted,
            user_templates_root: ?[]const u8 = null,
        },
    ) ReplyError!OwnedResult {
        var session = try Session.start(self.gpa, self.io, .{
            .base_system = system_prompt,
            .path = session_opts.path,
            .open_mode = session_opts.open_mode,
            .load_project_instructions = session_opts.load_project_instructions,
            .redactor = self.activeRedactor(),
            .skills_enabled = session_opts.skills_enabled,
            .project_skills_trust = session_opts.project_skills_trust,
            .user_skills_root = session_opts.user_skills_root,
            .templates_enabled = session_opts.templates_enabled,
            .project_templates_trust = session_opts.project_templates_trust,
            .user_templates_root = session_opts.user_templates_root,
        });
        defer session.deinit();

        // `reply` owns the single public lifecycle terminal (including flush /
        // failure paths). The OwnedResult text copy below is a caller-side
        // presentation allocation after that terminal; it may OOM without
        // rewriting or fabricating a second lifecycle terminal.
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

test "Agent pre-handler jail deny for long path is bounded and handler not executed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sentinel = "AGENT_LONG_ABS_SENTINEL_2741";

    const State = struct { executed: bool = false };
    const Stub = struct {
        fn handle(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const state: *State = @ptrCast(@alignCast(instance.?));
            state.executed = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{ .name = "read_file", .description = "", .parameters_json = "{\"type\":\"object\"}" },
            .capabilities = .{ .risk = .read, .workspace = .{ .path_field = "path" }, .cancellation = .none, .shell = .none },
        },
        .instance = &state,
        .handler = Stub.handle,
    }};

    const Mock = struct {
        sentinel: []const u8,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const filler = try arena.alloc(u8, 70 * 1024);
            @memset(filler, 'z');
            const args = try std.fmt.allocPrint(arena, "{{\"path\":\"/{s}{s}\"}}", .{ self.sentinel, filler });
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "c1"),
                .name = try arena.dupe(u8, "read_file"),
                .arguments = args,
            };
            return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
        }
    };

    var mock: Mock = .{ .sentinel = sentinel };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var agent = try Agent.init(gpa, io, provider, .{ .max_turns = 1, .permission_mode = .yolo });
    defer agent.deinit();
    agent.test_tools = &tools;
    var session = try Session.start(gpa, io, .{ .base_system = "sys", .load_project_instructions = false });
    defer session.deinit();

    _ = try agent.reply(&session, "read long path");
    try std.testing.expect(!state.executed);
    var found = false;
    for (session.transcript.items()) |m| {
        if (m.role == .tool) {
            found = true;
            try std.testing.expect(m.content.len <= tool.max_result_bytes);
            try std.testing.expect(core.tool_error.hasCode(m.content, .jail_deny));
            try std.testing.expect(std.mem.indexOf(u8, m.content, sentinel) == null);
        }
    }
    try std.testing.expect(found);
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
            _: provider_mod.RequestControl,
            _: ?*?u64,
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

    var agent = try Agent.init(gpa, io, provider, .{
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

test "Agent Phase1Storage grep and glob default missing and empty path in tmp cwd" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws/src");
    try parent.dir.writeFile(io, .{ .sub_path = "ws/src/hit.zig", .data = "pub const needle = true;\n" });

    // Handle-based cwd switching reaches the raw `fchdir(2)` syscall through
    // Io.Threaded on non-libc Linux, while ScopedCwd restores fail-loud.
    var ws = try parent.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    var scoped = try ScopedCwd.enter(io, ws);
    defer scoped.leave();

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            defs: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                var saw_grep = false;
                var saw_glob = false;
                for (defs) |def| {
                    if (std.mem.eql(u8, def.name, "grep")) saw_grep = true;
                    if (std.mem.eql(u8, def.name, "glob")) saw_glob = true;
                }
                if (!saw_grep or !saw_glob) return error.InvalidResponse;
                const tc = try arena.alloc(message.ToolCall, 2);
                tc[0] = .{ .id = try arena.dupe(u8, "grep-1"), .name = try arena.dupe(u8, "grep"), .arguments = try arena.dupe(u8, "{\"pattern\":\"needle\"}") };
                tc[1] = .{ .id = try arena.dupe(u8, "glob-1"), .name = try arena.dupe(u8, "glob"), .arguments = try arena.dupe(u8, "{\"pattern\":\"**/*.zig\",\"path\":\"\"}") };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }

            var saw_grep_hit = false;
            var saw_glob_hit = false;
            var saw_invalid = false;
            var saw_grep_id = false;
            var saw_glob_id = false;
            for (messages) |m| {
                if (m.role == .tool) {
                    const id = m.tool_call_id orelse "";
                    if (std.mem.eql(u8, id, "grep-1")) saw_grep_id = true;
                    if (std.mem.eql(u8, id, "glob-1")) saw_glob_id = true;
                    if (std.mem.indexOf(u8, m.content, "src/hit.zig") != null and std.mem.indexOf(u8, m.content, "needle") != null) saw_grep_hit = true;
                    if (std.mem.indexOf(u8, m.content, "src/hit.zig") != null) saw_glob_hit = true;
                    if (std.mem.indexOf(u8, m.content, "invalid_arguments") != null) saw_invalid = true;
                }
            }
            if (!saw_grep_id or !saw_glob_id or !saw_grep_hit or !saw_glob_hit or saw_invalid) return error.InvalidResponse;
            return .{ .content = try arena.dupe(u8, "terminal"), .tool_calls = &.{}, .finish_reason = "stop" };
        }
    };

    var mock: Mock = .{};
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var agent = try Agent.init(gpa, io, provider, .{ .permission_mode = .yolo, .max_turns = 3, .chat_retries = 0 });
    defer agent.deinit();
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = ".zag/sessions/default-search.jsonl",
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "search without path");
    try std.testing.expectEqualStrings("terminal", result.final_text);
    try std.testing.expectEqual(@as(u32, 2), mock.calls);

    var saw_grep = false;
    var saw_glob = false;
    for (session.transcript.items()) |m| {
        if (m.role == .tool) {
            try std.testing.expect(std.mem.indexOf(u8, m.content, "invalid_arguments") == null);
            const id = m.tool_call_id orelse "";
            if (std.mem.eql(u8, id, "grep-1") and std.mem.indexOf(u8, m.content, "src/hit.zig") != null and std.mem.indexOf(u8, m.content, "needle") != null) saw_grep = true;
            if (std.mem.eql(u8, id, "glob-1") and std.mem.indexOf(u8, m.content, "src/hit.zig") != null) saw_glob = true;
        }
    }
    try std.testing.expect(saw_grep);
    try std.testing.expect(saw_glob);

    const saved = try Io.Dir.cwd().readFileAlloc(io, ".zag/sessions/default-search.jsonl", gpa, .limited(64 * 1024));
    defer gpa.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "grep-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "glob-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "invalid_arguments") == null);
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
        _: provider_mod.RequestControl,
        _: ?*?u64,
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    // Terminal ChatError tag is recorded (attempt=0 provider_retry) so the
    // cause is not lost behind the opaque ProviderFailed collapse.
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "AuthenticationFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"attempt\":0") != null);
}

test "h-trace: max_turns terminal ok=true stop_reason=max_turns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .max_turns_then_text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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

test "h-provider: unsupported_control exact run_end once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return error.UnsupportedControl;
        }
    };
    var calls: u32 = 0;
    var mock: Mock = .{ .calls = &calls };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{ .permission_mode = .yolo, .chat_retries = 3, .verbose = false });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.unsupported_control, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), calls); // not retried
    // system + user only; no assistant/tool after failure.
    for (session.transcript.items()) |m| {
        try std.testing.expect(m.role == .system or m.role == .user);
    }
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "unsupported_control");
}

test "h-provider: timeout exact run_end once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return error.Timeout;
        }
    };
    var calls: u32 = 0;
    var mock: Mock = .{ .calls = &calls };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{ .permission_mode = .yolo, .chat_retries = 5, .verbose = false });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.timeout, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), calls);
    for (session.transcript.items()) |m| {
        try std.testing.expect(m.role == .system or m.role == .user);
    }
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "timeout");
}

test "h-provider: retryable error exact chat_retries+1 attempts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return error.RateLimited;
        }
    };
    var calls: u32 = 0;
    var mock: Mock = .{ .calls = &calls };
    const retries: u8 = 2;
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .chat_retries = retries,
        .retry_base_delay_ms = 1,
        .verbose = false,
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
    try std.testing.expectEqual(@as(u32, retries + 1), calls);
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, false, "provider_error");
}

test "h-trace: per-run cancel clears stale flag; second reply completes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Provider requests cancel in-flight and returns a multi-tool turn. The
    // pending tools are never executed and the run ends cancelled.
    const Mock = struct {
        calls: *u32,
        agent: *Agent,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            // In-flight cooperative cancel only on the first reply; all later replies complete.
            if (self.calls.* == 1) {
                self.agent.cancel.request();
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "cancel_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{
                    .content = "batch",
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var agent = try Agent.init(gpa, io, .{
        .ptr = undefined,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var mock_state: Mock = .{ .calls = undefined, .agent = &agent };
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };
    // Patch the provider pointer into the Agent after both are initialized.
    agent.provider = provider;
    var calls: u32 = 0;
    mock_state.calls = &calls;

    var session1 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session1.deinit();
    const result1 = try agent.reply(&session1, "first");
    try std.testing.expectEqual(loop.StopReason.cancelled, result1.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), calls);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "cancelled");

    // A second reply on the same Agent must start clean (stale flag cleared).
    var session2 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session2.deinit();
    const result2 = try agent.reply(&session2, "second");
    try std.testing.expectEqual(loop.StopReason.completed, result2.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), calls);
}

test "h-trace: pre-run pending cancel applies to the current run (cli-sigint-001 review item 3)" {
    // Goal: a cancel flag set BEFORE reply begins (simulating a SIGINT that
    // arrived after the guard was installed but before the run started) must
    // apply to the current run, not be silently cleared. The run must observe
    // the cancel and end `.cancelled` without ever calling the provider; the
    // completion boundary then clears the flag so the next reply starts clean.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var agent = try Agent.init(gpa, io, .{
        .ptr = undefined,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var mock_state: Mock = .{ .calls = undefined };
    const provider = provider_mod.Provider{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    };
    agent.provider = provider;
    var calls: u32 = 0;
    mock_state.calls = &calls;

    // Pre-run pending cancel: set the flag BEFORE the first reply (mirrors a
    // SIGINT that landed between guard install and the first run).
    agent.cancel.request();
    try std.testing.expect(agent.cancel.isSet());

    var session1 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session1.deinit();
    const result1 = try agent.reply(&session1, "first");
    // The pre-run pending cancel applied to this run; provider never called.
    try std.testing.expectEqual(loop.StopReason.cancelled, result1.stop_reason);
    try std.testing.expectEqual(@as(u32, 0), calls);
    // Completion boundary cleared the flag.
    try std.testing.expect(!agent.cancel.isSet());

    // Second reply starts clean and completes normally.
    var session2 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session2.deinit();
    const result2 = try agent.reply(&session2, "second");
    try std.testing.expectEqual(loop.StopReason.completed, result2.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "h-trace: beginRun preflight OOM clears a pre-set cancel flag (cli-sigint-001 P2)" {
    // Goal (P2 follow-up): the run-completion cancel clear must cover the
    // beginRun-failure path. Preset the cancel flag, then make beginRun fail
    // in its ensureSessionRedactor preflight (OOM). After the failed reply
    // returns, the flag MUST be cleared so the next reply is not stale-cancel.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Mock = struct {
        calls: *u32,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var agent = try Agent.init(gpa, io, .{
        .ptr = undefined,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .toolset = &[_]tool.Tool{},
        .verbose = false,
        .max_turns = 4,
        .secrets = &.{redact_mod.testing.fake_api_key},
        .pattern_redaction = true,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var mock_state: Mock = .{ .calls = undefined };
    agent.provider = .{ .ptr = &mock_state, .vtable = &.{ .chat = Mock.chat } };
    var calls: u32 = 0;
    mock_state.calls = &calls;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();
    // Force the ensureSessionRedactor clone path so a failing allocator can
    // trigger OOM inside beginRun's preflight.
    if (session.owned_redactor) |*old| {
        old.deinit();
        session.owned_redactor = null;
    }

    // Preset the cancel flag (simulates a pre-run SIGINT).
    agent.cancel.request();
    try std.testing.expect(agent.cancel.isSet());

    // Make beginRun's ensureSessionRedactor allocation fail.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const saved = session.gpa;
    session.gpa = failing.allocator();
    const err = agent.reply(&session, "hi");
    session.gpa = saved;
    try std.testing.expectError(error.OutOfMemory, err);
    // P2: the completion-boundary clear ran (defer registered before beginRun),
    // so the pre-set cancel flag did NOT survive the failed run start.
    try std.testing.expect(!agent.cancel.isSet());
    try std.testing.expectEqual(@as(u32, 0), calls);

    // A subsequent reply must NOT inherit a stale cancel; it completes.
    var session2 = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session2.deinit();
    const result2 = try agent.reply(&session2, "again");
    try std.testing.expectEqual(loop.StopReason.completed, result2.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "h-trace: explicit .observer = .none() runs without event chain error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .observer = .none(),
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
        _: provider_mod.RequestControl,
        _: ?*?u64,
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

        var agent = try Agent.init(gpa, io, .{
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
        var agent2 = try Agent.init(gpa, io, .{
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
    // Budget must cover harness-steering-001 control queue preallocation
    // (32 KiB text backing) plus arena/redactor overhead for Session.start.
    var storage: [96 * 1024]u8 = undefined;
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

// ── h-context-001: loop-level on_compaction OOM fixture helpers ──────────────
//
// Locally-defined low-level context_view + event_sink vtables for the loop
// fixture that exercises compaction OOM. No public concrete test adapter is
// leaked; these are file-local test scaffolding.

const LayeredCtx = struct {
    io: std.Io,
    layers: context_mod.Layers,
    opts: context_mod.Options,
};

const layered_context_vtable: context_view_mod.ContextViewVTable = .{
    .view = layeredContextView,
};
fn layeredContextView(
    ptr: ?*anyopaque,
    scratch: std.mem.Allocator,
    transcript_items: []const message.Message,
) context_view_mod.ContextViewError!context_view_mod.View {
    const ctx: *LayeredCtx = @ptrCast(@alignCast(ptr.?));
    const v = context_mod.viewForModel(ctx.io, scratch, transcript_items, ctx.opts, ctx.layers) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidContext => return error.InvalidContext,
    };
    return .{ .messages = v.messages, .compaction = v.compaction };
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
            _: provider_mod.RequestControl,
            _: ?*?u64,
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

    // Local sink that runs the session note first (failing OOM) so no trace
    // compaction line is written — preserving the prior on_compaction OOM contract.
    const OomEventSink = struct {
        called: *bool,
        fn emit(ptr: ?*anyopaque, event: loop_event_mod.LoopEvent) loop_event_mod.SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .context_compaction => {
                    self.called.* = true;
                    return error.OutOfMemory;
                },
                .turn_start => {},
                else => {},
            }
        }
    };
    var oom_sink: OomEventSink = .{ .called = &sink_called };
    const oom_sink_vtable: loop_event_mod.LoopEventSinkVTable = .{ .emit = OomEventSink.emit };

    var ctx_state: LayeredCtx = .{
        .io = io,
        .layers = .{ .system = "base" },
        .opts = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 1,
        },
    };

    const result = loop.run(.{
        .gpa = gpa,
        .provider = provider,
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = io,
            .cwd = Io.Dir.cwd(),
        },
        .tool_policy = loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = loop.Jail.allowAllForTrustedHost(),
        .shell_policy = loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = .{ .ptr = &ctx_state, .vtable = &layered_context_vtable },
        .event_sink = .{ .ptr = &oom_sink, .vtable = &oom_sink_vtable },
        .control_input = loop.ControlInput.none(),
        .options = .{
            .max_turns = 2,
        },
    }, &transcript);

    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(sink_called);
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("compaction"));
    // Provider must not have been called after sink failure.
    // (Mock would have returned text; no assistant event expected from loop.)
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("assistant"));
}

test "compaction-llm: product summarizer feeds LLM text into session meta + trace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const healthy = ("hello world\n" ** 59) ++ "hello world";

    const Mock = struct {
        calls: u32 = 0,
        healthy: []const u8,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            // Summarizer call: system prompt + user message with <conversation>.
            if (messages.len == 2 and messages[0].role == .system and
                std.mem.indexOf(u8, messages[1].content, "<conversation>") != null)
            {
                return .{
                    .content = try arena.dupe(u8, self.healthy),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            return .{ .content = try arena.dupe(u8, "turn-ok"), .tool_calls = &.{}, .finish_reason = "stop" };
        }
    };
    var mock: Mock = .{ .healthy = healthy };

    // The summarizer seam borrows the Agent (stable address after init).
    var agent: Agent = undefined;
    agent = try Agent.init(gpa, io, .{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
        .context = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 2,
            .summarizer = compactionSummarizer(&agent),
        },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    // Long transcript: the count cap (2) forces compaction on this reply.
    for (0..10) |_| {
        try session.transcript.appendUser("u");
        try session.transcript.appendAssistantTurn(.{
            .content = "a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });
    }

    const result = try agent.reply(&session, "final");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    // One summarizer call + one turn call.
    try std.testing.expectEqual(@as(u32, 2), mock.calls);

    // Session meta (header gen 1) carries the LLM summary.
    try std.testing.expectEqual(@as(u32, 1), session.compaction_gen);
    const summary = session.compaction_summary orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(healthy, summary);

    // Trace compaction line carries the same LLM text (newlines are
    // JSON-escaped, so assert on a newline-free substring).
    const tr = agent.trace.?;
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("compaction"));
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "hello world") != null);
}

test "compaction-llm: product summarizer provider failure falls back to heuristic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (messages.len == 2 and messages[0].role == .system and
                std.mem.indexOf(u8, messages[1].content, "<conversation>") != null)
            {
                return error.AuthenticationFailed;
            }
            return .{ .content = try arena.dupe(u8, "turn-ok"), .tool_calls = &.{}, .finish_reason = "stop" };
        }
    };
    var mock: Mock = .{};

    var agent: Agent = undefined;
    agent = try Agent.init(gpa, io, .{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
        .context = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 2,
            .summarizer = compactionSummarizer(&agent),
        },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    for (0..10) |_| {
        try session.transcript.appendUser("u");
        try session.transcript.appendAssistantTurn(.{
            .content = "a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });
    }

    const result = try agent.reply(&session, "final");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    // Deterministic auth failure → 1 summarizer call, heuristic fallback.
    try std.testing.expectEqual(@as(u32, 2), mock.calls);
    const summary = session.compaction_summary orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, summary, "compaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "hello world") == null);
    const tr = agent.trace.?;
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("compaction"));
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "hello world") == null);
}

test "h-context: Agent.reply malformed tools invalid_context provider=0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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

    var agent = try Agent.init(gpa, io, .{
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
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
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

test "h-context: tiny-budget prior lineage survives save/resume/recompact chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-context-tiny-lineage";
    const path = ".zag-test-h-context-tiny-lineage/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var prior: [790]u8 = undefined;
    @memset(&prior, 'T');
    const digest = std.hash.Wyhash.hash(0, &prior);
    var dig_buf: [48]u8 = undefined;
    const dig_needle = try std.fmt.bufPrint(&dig_buf, "digest=wyhash64:{x:0>16}", .{digest});

    var gen_after_first: u32 = 0;
    var summary_after_first: []u8 = undefined;

    {
        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .max_turns = 4,
            .context = .{
                .max_tail_messages = 2,
                .max_chars = 0,
                .min_tail_messages = 2,
                .summary_max_chars = 1, // tiny → floor with prior lineage
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

        _ = try agent.reply(&session, "compact-1");
        try std.testing.expectEqual(@as(u32, 2), session.compaction_gen);
        try std.testing.expect(session.compaction_summary != null);
        const sum = session.compaction_summary.?;
        try std.testing.expect(sum.len <= context_mod.summary_cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(sum));
        try std.testing.expect(std.mem.indexOf(u8, sum, "earlier messages omitted") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=790") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, dig_needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, context_mod.lineage_truncated_marker) != null);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        const parsed = try parseCompactionFromTrace(gpa, tr.buf.items);
        defer gpa.free(parsed.summary);
        try std.testing.expectEqualStrings(sum, parsed.summary);

        try session.save();
        gen_after_first = session.compaction_gen;
        summary_after_first = try gpa.dupe(u8, sum);
    }
    defer gpa.free(summary_after_first);

    // Resume → compact again → gen +1; lineage still auditable.
    {
        var resumed = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        // Manual deinit before second resume (exclusive writer lock).
        try std.testing.expectEqual(gen_after_first, resumed.compaction_gen);
        try std.testing.expectEqualStrings(summary_after_first, resumed.compaction_summary.?);

        var calls2: u32 = 0;
        var mock2: MockChat = .{ .calls = &calls2, .mode = .text };
        var agent2 = try Agent.init(gpa, io, mockProvider(&mock2), .{
            .permission_mode = .yolo,
            .verbose = false,
            .max_turns = 4,
            .context = .{
                .max_tail_messages = 2,
                .max_chars = 0,
                .min_tail_messages = 2,
                .summary_max_chars = 8,
            },
        });
        defer agent2.deinit();
        agent2.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

        // Seed more body so another compaction is needed.
        try resumed.transcript.appendUser("extra-u");
        try resumed.transcript.appendAssistantTurn(.{
            .content = "extra-a",
            .tool_calls = &.{},
            .finish_reason = "stop",
        });

        _ = try agent2.reply(&resumed, "compact-2");
        try std.testing.expectEqual(gen_after_first + 1, resumed.compaction_gen);
        try std.testing.expect(resumed.compaction_summary != null);
        const sum2 = resumed.compaction_summary.?;
        try std.testing.expect(sum2.len <= context_mod.summary_cap);
        try std.testing.expect(std.mem.indexOf(u8, sum2, context_mod.lineage_truncated_marker) != null);
        try std.testing.expect(std.mem.indexOf(u8, sum2, "digest=wyhash64:") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum2, "prior_bytes=") != null);

        const tr2 = if (agent2.trace) |*t| t else return error.TestUnexpectedResult;
        const p2 = try parseCompactionFromTrace(gpa, tr2.buf.items);
        defer gpa.free(p2.summary);
        try std.testing.expectEqualStrings(sum2, p2.summary);

        try resumed.save();
        const gen2 = resumed.compaction_gen;
        const sum2_owned = try gpa.dupe(u8, sum2);
        // Release writer lock before a second resume on the same path.
        resumed.deinit();

        // Second resume still durable.
        var resumed2 = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        defer resumed2.deinit();
        try std.testing.expectEqual(gen2, resumed2.compaction_gen);
        try std.testing.expectEqualStrings(sum2_owned, resumed2.compaction_summary.?);
        gpa.free(sum2_owned);
    }
}

// ── h-redact-001 permanent fixtures ─────────────────────────────────────────

/// Provider that echoes user text (and can plant secrets in assistant/tool paths).
const EchoSecretChat = struct {
    secret: []const u8,
    mode: enum { text, tool_then_text } = .text,
    step: u32 = 0,

    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        _: []const tool.Definition,
        _: provider_mod.RequestControl,
        _: ?*?u64,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *EchoSecretChat = @ptrCast(@alignCast(ptr));
        self.step += 1;
        // Ensure provider still sees the raw secret when present in history.
        for (messages) |m| {
            if (std.mem.indexOf(u8, m.content, self.secret) != null) {
                // observed raw — ok
            }
        }
        switch (self.mode) {
            .text => {
                const last = if (messages.len > 0) messages[messages.len - 1].content else "";
                const body = try std.fmt.allocPrint(arena, "echo:{s}", .{last});
                return .{ .content = body, .tool_calls = &.{}, .finish_reason = "stop" };
            },
            .tool_then_text => {
                if (self.step == 1) {
                    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{self.secret});
                    const calls = try arena.alloc(message.ToolCall, 1);
                    calls[0] = .{
                        .id = "c-secret",
                        .name = "list_dir",
                        .arguments = args,
                    };
                    return .{
                        .content = try arena.dupe(u8, "calling"),
                        .tool_calls = calls,
                        .finish_reason = "tool_calls",
                    };
                }
                return .{
                    .content = try arena.dupe(u8, "done"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            },
        }
    }
};

fn assertNoSecret(hay: []const u8, secret: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, hay, secret) == null);
}

test "h-redact: secret absent from session bytes, trace, while in-memory raw" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    const dir_name = ".zag-test-h-redact-session";
    const sess_path = ".zag-test-h-redact-session/s.jsonl";
    const tr_path = ".zag-test-h-redact-session/t.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
    const secret_slots = [_][]const u8{secret};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = tr_path,
        .secrets = &secret_slots,
        .pattern_redaction = true,
    });
    defer agent.deinit();

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        // User message plants the configured secret.
        const user_text = try std.fmt.allocPrint(gpa, "key={s}", .{secret});
        defer gpa.free(user_text);
        const result = try agent.reply(&session, user_text);
        try std.testing.expect(std.mem.indexOf(u8, result.final_text, secret) != null);

        // In-memory transcript keeps the raw secret.
        var found_raw = false;
        for (session.transcript.items()) |m| {
            if (std.mem.indexOf(u8, m.content, secret) != null) found_raw = true;
        }
        try std.testing.expect(found_raw);

        // Session file must not contain the secret.
        const sess_bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
        defer gpa.free(sess_bytes);
        try assertNoSecret(sess_bytes, secret);
        try std.testing.expect(std.mem.indexOf(u8, sess_bytes, redact_mod.marker) != null);

        // Trace buffer + file must not contain the secret.
        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try assertNoSecret(tr.buf.items, secret);
        const tr_bytes = try Io.Dir.cwd().readFileAlloc(io, tr_path, gpa, .limited(2 * 1024 * 1024));
        defer gpa.free(tr_bytes);
        try assertNoSecret(tr_bytes, secret);
    }

    // Resume sees redacted bytes (not the original secret).
    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    var resumed_has_secret = false;
    for (resumed.transcript.items()) |m| {
        if (std.mem.indexOf(u8, m.content, secret) != null) resumed_has_secret = true;
    }
    try std.testing.expect(!resumed_has_secret);
}

test "h-redact: tool args/result and pattern shapes redacted in trace+session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    const dir_name = ".zag-test-h-redact-tools";
    const sess_path = ".zag-test-h-redact-tools/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = secret, .mode = .tool_then_text };
    const secret_slots = [_][]const u8{secret};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .secrets = &secret_slots,
        .pattern_redaction = true,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    if (agent.trace) |*tr| tr.setRedactor(agent.activeRedactor());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    // Plant pattern-shaped secrets in user text too.
    const user_text = try std.fmt.allocPrint(gpa, "use {s} and {s}", .{
        secret,
        redact_mod.testing.fake_aws,
    });
    defer gpa.free(user_text);
    _ = try agent.reply(&session, user_text);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try assertNoSecret(tr.buf.items, secret);
    try assertNoSecret(tr.buf.items, redact_mod.testing.fake_aws);
    // Near-miss / code-like must remain if present in trace (tool name list_dir).
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "list_dir") != null);

    const sess_bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(sess_bytes);
    try assertNoSecret(sess_bytes, secret);
    try assertNoSecret(sess_bytes, redact_mod.testing.fake_aws);
}

test "h-redact: redaction OOM on session save preserves prior bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    const dir_name = ".zag-test-h-redact-oom";
    const sess_path = ".zag-test-h-redact-oom/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
    const secret_slots = [_][]const u8{secret};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &secret_slots,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    // First successful save establishes prior bytes.
    _ = try agent.reply(&session, "hello");
    const prior = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(prior);

    // Inject redact OOM on next writer save.
    if (session.writer) |*w| {
        session_store.testing.setFailNextRedact(w, true);
    }

    const leak_msg = try std.fmt.allocPrint(gpa, "leak {s}", .{secret});
    defer gpa.free(leak_msg);
    // append user + force save path via reply
    const err = agent.reply(&session, leak_msg);
    try std.testing.expectError(error.OutOfMemory, err);

    const after = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(prior, after);
    try assertNoSecret(after, secret);
}

test "h-redact: redaction OOM on trace emit fails closed no raw in buffer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    var r = try redact_mod.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();

    var t = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    defer t.deinit();
    t.setRedactor(&r);
    try t.beginReply();
    try t.emitRunStart(.{
        .version = "0.5.0",
        .permission = "ask",
        .shell_policy = "protect",
    });
    const before_len = t.buf.items.len;
    const before_seq = t.event_count;

    trace_mod.testing.setFailNextRedact(&t, true);
    try std.testing.expectError(error.OutOfMemory, t.emitAssistant("has " ++ secret));
    // Transactional: buffer unchanged (prepare fails before writeObj).
    try std.testing.expectEqual(before_len, t.buf.items.len);
    try std.testing.expectEqual(before_seq, t.event_count);
    try assertNoSecret(t.buf.items, secret);
}

test "h-redact: near-miss strings survive session roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-redact-nearmiss";
    const sess_path = ".zag-test-h-redact-nearmiss/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = "unused-secret-value-xxxx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .pattern_redaction = true,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();

    const near = "use my_api_key and sk-short and OPENAI_API_KEY var";
    _ = try agent.reply(&session, near);

    const sess_bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(sess_bytes);
    try std.testing.expect(std.mem.indexOf(u8, sess_bytes, "my_api_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, sess_bytes, "sk-short") != null);
    try std.testing.expect(std.mem.indexOf(u8, sess_bytes, "OPENAI_API_KEY") != null);
}

// ── h-redact-001 follow-up permanent gates ──────────────────────────────────

const FailAlwaysChat = struct {
    fn chat(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: []const message.Message,
        _: []const tool.Definition,
        _: provider_mod.RequestControl,
        _: ?*?u64,
    ) provider_mod.ChatError!message.AssistantTurn {
        return error.AuthenticationFailed;
    }
};

test "h-redact: initial create redacts system secret before provider failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    const dir_name = ".zag-test-h-redact-initcreate";
    const sess_path = ".zag-test-h-redact-initcreate/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const sys = try std.fmt.allocPrint(gpa, "system with {s}", .{secret});
    defer gpa.free(sys);

    const secret_slots = [_][]const u8{secret};
    var mock: FailAlwaysChat = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = FailAlwaysChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &secret_slots,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = sys,
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    // Initial create already on disk — must not contain raw secret.
    const initial = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(initial);
    try std.testing.expect(std.mem.indexOf(u8, initial, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, initial, redact_mod.marker) != null);

    // Provider failure path must not write raw.
    try std.testing.expectError(error.ProviderFailed, agent.reply(&session, "hi"));
    const after = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, secret) == null);
}

test "h-redact: Agent.init Redactor OOM before disk/network" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: FailAlwaysChat = .{};
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const err = Agent.init(failing.allocator(), io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = FailAlwaysChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &.{redact_mod.testing.fake_api_key},
    });
    try std.testing.expectError(error.OutOfMemory, err);
}

test "h-redact: Session save safe after Agent deinit (owned policy)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    const dir_name = ".zag-test-h-redact-after-agent";
    const sess_path = ".zag-test-h-redact-after-agent/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const secret_slots = [_][]const u8{secret};
    var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{ .permission_mode = .yolo, .secrets = &secret_slots });

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    // Session owns its policy — safe after Agent deinit (no UAF).
    agent.deinit();

    try session.transcript.appendUser(try std.fmt.allocPrint(session.arena_impl.allocator(), "k={s}", .{secret}));
    try session.save();
    const bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
}

test "h-redact: multi-tool secret IDs get unique pseudonyms on save/resume" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s1 = redact_mod.testing.fake_api_key;
    const s2 = redact_mod.testing.fake_anthropic;

    const dir_name = ".zag-test-h-redact-toolids";
    const sess_path = ".zag-test-h-redact-toolids/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const secret_slots = [_][]const u8{ s1, s2 };
    {
        var mock: EchoSecretChat = .{ .secret = s1, .mode = .text };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = EchoSecretChat.chat },
        }, .{ .permission_mode = .yolo, .secrets = &secret_slots });
        defer agent.deinit();

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .redactor = agent.activeRedactor(),
        });
        defer session.deinit();

        const id_a = try std.fmt.allocPrint(session.arena_impl.allocator(), "call-{s}", .{s1});
        const id_b = try std.fmt.allocPrint(session.arena_impl.allocator(), "call-{s}", .{s2});
        const calls = try session.arena_impl.allocator().alloc(message.ToolCall, 2);
        calls[0] = .{ .id = id_a, .name = "list_dir", .arguments = "{}" };
        calls[1] = .{ .id = id_b, .name = "list_dir", .arguments = "{}" };
        try session.transcript.appendAssistantTurn(.{
            .content = "tools",
            .tool_calls = calls,
            .finish_reason = "tool_calls",
        });
        try session.transcript.appendToolResult(id_a, "ra");
        try session.transcript.appendToolResult(id_b, "rb");
        try session.save();

        const bytes = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(2 * 1024 * 1024));
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, s1) == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, s2) == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "zag-rtid-0") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "zag-rtid-1") != null);
        // Distinct pseudonyms.
        try std.testing.expect(std.mem.indexOf(u8, bytes, "zag-rtid-0") !=
            std.mem.indexOf(u8, bytes, "zag-rtid-1"));
    }

    // Resume: tool pairs still coherent under pseudonyms.
    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .pattern_redaction = true,
    });
    defer resumed.deinit();
    var saw0 = false;
    var saw1 = false;
    for (resumed.transcript.items()) |m| {
        if (m.tool_calls) |calls| {
            for (calls) |c| {
                if (std.mem.eql(u8, c.id, "zag-rtid-0")) saw0 = true;
                if (std.mem.eql(u8, c.id, "zag-rtid-1")) saw1 = true;
            }
        }
        if (m.tool_call_id) |tid| {
            if (std.mem.eql(u8, tid, "zag-rtid-0")) saw0 = true;
            if (std.mem.eql(u8, tid, "zag-rtid-1")) saw1 = true;
        }
    }
    try std.testing.expect(saw0 and saw1);
}

test "h-redact: mid-trace redaction OOM still one out_of_memory terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;

    // Arm fail_next only after run_start, on the first provider turn.
    const LeakChat = struct {
        secret: []const u8,
        agent: *Agent,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.agent.trace) |*tr| {
                trace_mod.testing.setFailNextRedact(tr, true);
            }
            const body = try std.fmt.allocPrint(arena, "secret={s}", .{self.secret});
            return .{ .content = body, .tool_calls = &.{}, .finish_reason = "stop" };
        }
    };
    const secret_slots = [_][]const u8{secret};
    var agent = try Agent.init(gpa, io, .{
        .ptr = undefined, // filled after agent exists
        .vtable = &.{ .chat = LeakChat.chat },
    }, .{ .permission_mode = .yolo, .secrets = &secret_slots });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var mock: LeakChat = .{ .secret = secret, .agent = &agent };
    agent.provider.ptr = &mock;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expectError(error.OutOfMemory, err);
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_end"));
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "out_of_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, secret) == null);
}

test "h-redact: reply clears trace redactor on success and failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{ .permission_mode = .yolo, .pattern_redaction = true });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    _ = try agent.reply(&session, "hi");
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expect(tr.redactor == null);

    // Failure path
    const FailChat = struct {
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            return error.AuthenticationFailed;
        }
    };
    var fail: FailChat = .{};
    agent.provider = .{ .ptr = &fail, .vtable = &.{ .chat = FailChat.chat } };
    try std.testing.expectError(error.ProviderFailed, agent.reply(&session, "again"));
    try std.testing.expect(tr.redactor == null);
}

test "h-redact: ensure/clone OOM clears stale trace redactor before bind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &.{redact_mod.testing.fake_api_key},
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    // Force ensureSessionRedactor clone path.
    if (session.owned_redactor) |*old| {
        old.deinit();
        session.owned_redactor = null;
    }
    // Plant a stale borrowed pointer that must not survive ensure OOM.
    var stale = try redact_mod.Redactor.init(gpa, .{
        .secrets = &.{"stale-secret-value-zz"},
        .patterns = false,
    });
    defer stale.deinit();
    if (agent.trace) |*tr| tr.setRedactor(&stale);
    try std.testing.expect(agent.trace.?.redactor != null);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const saved = session.gpa;
    session.gpa = failing.allocator();
    const err = agent.reply(&session, "hi");
    session.gpa = saved;
    try std.testing.expectError(error.OutOfMemory, err);
    try std.testing.expect(failing.has_induced_failure);
    // reply's completion boundary clears the cancel flag after the OOM; ensure
    // OOM never re-binds a stale redactor pointer.
    try std.testing.expect(agent.trace.?.redactor == null);
}

test "h-redact: run_start redaction OOM clears trace redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &.{redact_mod.testing.fake_api_key},
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    // Fail first prepareTracedString inside emitRunStart (version field).
    if (agent.trace) |*tr| trace_mod.testing.setFailNextRedact(tr, true);
    try std.testing.expectError(error.OutOfMemory, agent.reply(&session, "hi"));
    try std.testing.expect(agent.trace.?.redactor == null);
}

test "h-redact: preflight failure clears trace redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-h-redact-preflight-clear";
    const blocker = ".zag-test-h-redact-preflight-clear/not-a-dir";
    const bad_path = ".zag-test-h-redact-preflight-clear/not-a-dir/trace.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = blocker, .data = "file-not-dir" });

    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .trace_path = bad_path,
        .secrets = &.{redact_mod.testing.fake_api_key},
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    const err = agent.reply(&session, "hi");
    try std.testing.expect(err == error.TraceIoFailed or err == error.InvalidPath);
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expect(tr.redactor == null);
}

test "h-redact: invalid_context terminal clears trace redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{ .permission_mode = .yolo, .pattern_redaction = true });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

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
    try session.transcript.appendToolResult("a1", "partial");

    try std.testing.expectError(error.InvalidContext, agent.reply(&session, "continue"));
    try std.testing.expect(agent.trace.?.redactor == null);
}

test "h-redact: session-save failure clears trace redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;
    const dir_name = ".zag-test-h-redact-save-clear";
    const sess_path = ".zag-test-h-redact-save-clear/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .secrets = &.{secret},
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    if (session.writer) |*w| session_store.testing.setFailNextRedact(w, true);
    try std.testing.expectError(error.OutOfMemory, agent.reply(&session, "hi"));
    try std.testing.expect(agent.trace.?.redactor == null);
}

test "h-redact: terminal persist fault clears trace redactor" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-h-redact-term-persist";
    const tr_path = ".zag-test-h-redact-term-persist/t.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var mock: EchoSecretChat = .{ .secret = "unused-secret-xx", .mode = .text };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = EchoSecretChat.chat },
    }, .{
        .permission_mode = .yolo,
        .trace_path = tr_path,
        .pattern_redaction = true,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
    });
    defer session.deinit();

    if (agent.trace) |*tr| trace_mod.testing.setFailBeforeReplace(tr, true);
    try std.testing.expectError(error.TraceIoFailed, agent.reply(&session, "hi"));
    try std.testing.expect(agent.trace.?.redactor == null);
}

test "h-redact: save/resume then new secret id avoids prior zag-rtid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = redact_mod.testing.fake_api_key;
    const dir_name = ".zag-test-h-redact-rtid-reuse";
    const sess_path = ".zag-test-h-redact-rtid-reuse/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const slots = [_][]const u8{secret};
    {
        var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = EchoSecretChat.chat },
        }, .{ .permission_mode = .yolo, .secrets = &slots });
        defer agent.deinit();
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
            .redactor = agent.activeRedactor(),
        });
        defer session.deinit();
        const id = try std.fmt.allocPrint(session.arena_impl.allocator(), "c-{s}", .{secret});
        const calls = try session.arena_impl.allocator().alloc(message.ToolCall, 1);
        calls[0] = .{ .id = id, .name = "list_dir", .arguments = "{}" };
        try session.transcript.appendAssistantTurn(.{ .content = "", .tool_calls = calls, .finish_reason = "tool_calls" });
        try session.transcript.appendToolResult(id, "ok");
        try session.save();
        const b1 = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(1024 * 1024));
        defer gpa.free(b1);
        try std.testing.expect(std.mem.indexOf(u8, b1, "zag-rtid-0") != null);
        try std.testing.expect(std.mem.indexOf(u8, b1, secret) == null);
    }
    // Resume and add another secret-bearing id — must not reuse zag-rtid-0.
    {
        var mock: EchoSecretChat = .{ .secret = secret, .mode = .text };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = EchoSecretChat.chat },
        }, .{ .permission_mode = .yolo, .secrets = &slots });
        defer agent.deinit();
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
            .redactor = agent.activeRedactor(),
        });
        defer session.deinit();
        const id2 = try std.fmt.allocPrint(session.arena_impl.allocator(), "d-{s}", .{secret});
        const calls2 = try session.arena_impl.allocator().alloc(message.ToolCall, 1);
        calls2[0] = .{ .id = id2, .name = "list_dir", .arguments = "{}" };
        try session.transcript.appendAssistantTurn(.{ .content = "", .tool_calls = calls2, .finish_reason = "tool_calls" });
        try session.transcript.appendToolResult(id2, "ok2");
        try session.save();
        const b2 = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(1024 * 1024));
        defer gpa.free(b2);
        try std.testing.expect(std.mem.indexOf(u8, b2, "zag-rtid-0") != null);
        try std.testing.expect(std.mem.indexOf(u8, b2, "zag-rtid-1") != null);
        try std.testing.expect(std.mem.indexOf(u8, b2, secret) == null);
    }
}

// ── h-integration-001 Agent composition fixtures ────────────────────────────
// Real product Agent.reply + default/policy/session/trace (not raw Registry).
// Does not claim mid-flight Tool/shell preemption (post-H process work).
//
// Trace schema notes (locked by loop/trace contract, not guessed):
// - executeOneTool always emits tool_call then (after work) tool_result.
// - finishRemainingCancelled only emits tool_result (no tool_call, no id field).
// - permission / jail_deny emit once per gated call when denied at that gate.
// - tool_result lines carry name+body only; pairing IDs live on transcript/session.

const tool_error = core.tool_error;

/// Scoped process-cwd switch for tests that need a real workspace root.
/// Always restore via defer.
///
/// Process-global cwd is hygiene debt (hostile to future parallel tests); restore
/// is fail-loud. Prefer Dir-scoped Agent/tool cwd when product API allows (P2 backlog).
const ScopedCwd = struct {
    io: Io,
    saved: Io.Dir,

    fn enter(io: Io, target: Io.Dir) !ScopedCwd {
        // Open a durable handle to the current directory before switching.
        const saved = try Io.Dir.cwd().openDir(io, ".", .{});
        errdefer saved.close(io);
        try std.process.setCurrentDir(io, target);
        return .{ .io = io, .saved = saved };
    }

    /// Always closes the saved handle. Restore failure panics with a fixed
    /// message (no path leak) so later tests cannot run under a wrong cwd.
    fn leave(self: *ScopedCwd) void {
        const restore_err = std.process.setCurrentDir(self.io, self.saved);
        self.saved.close(self.io);
        self.* = undefined;
        restore_err catch @panic("test process cwd restore failed");
    }
};

/// Target must be absent: only `FileNotFound` is success; other access errors fail.
fn expectPathAbsent(io: Io, path: []const u8) !void {
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.TestUnexpectedResult;
}

fn toolBodyById(items: []const message.Message, id: []const u8) ?[]const u8 {
    for (items) |m| {
        if (m.role != .tool) continue;
        if (m.tool_call_id) |tid| {
            if (std.mem.eql(u8, tid, id)) return m.content;
        }
    }
    return null;
}

fn assistantHasCallId(items: []const message.Message, id: []const u8) bool {
    for (items) |m| {
        if (m.role != .assistant) continue;
        if (m.tool_calls) |calls| {
            for (calls) |c| {
                if (std.mem.eql(u8, c.id, id)) return true;
            }
        }
    }
    return false;
}

fn expectPairedToolId(items: []const message.Message, id: []const u8) ![]const u8 {
    try std.testing.expect(assistantHasCallId(items, id));
    const body = toolBodyById(items, id) orelse return error.TestUnexpectedResult;
    return body;
}

/// Expected durable tool-body check bound to one original provider call id.
const SessionBodyExpect = union(enum) {
    /// Full body string equality on the tool record with this tool_call_id.
    exact: []const u8,
    /// Machine-readable harness code present on that tool record only.
    code: tool_error.Code,
};

/// Structured session JSONL pairing on raw bytes (no whole-file independent needles).
/// Skips header lines without `role`. Counts every assistant `tool_calls[].id`
/// occurrence for `id` across all assistant records (and within one array);
/// second hit fails immediately; final count must be exactly 1. Tool rows for
/// `id` must also appear exactly once with the expected body.
fn expectSessionPairedOutcomeBytes(
    gpa: std.mem.Allocator,
    raw: []const u8,
    id: []const u8,
    body_expect: SessionBodyExpect,
) !void {
    var assistant_id_hits: u32 = 0;
    var tool_hits: u32 = 0;
    var matched_body = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
            return error.TestUnexpectedResult;
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestUnexpectedResult;
        const obj = parsed.value.object;

        // Header / meta lines: schema_version / type without role.
        const role_v = obj.get("role") orelse continue;
        if (role_v != .string) return error.TestUnexpectedResult;
        const role = role_v.string;

        if (std.mem.eql(u8, role, "assistant")) {
            if (obj.get("tool_calls")) |tc_v| {
                if (tc_v != .array) return error.TestUnexpectedResult;
                for (tc_v.array.items) |item| {
                    if (item != .object) return error.TestUnexpectedResult;
                    const cid_v = item.object.get("id") orelse return error.TestUnexpectedResult;
                    if (cid_v != .string) return error.TestUnexpectedResult;
                    if (std.mem.eql(u8, cid_v.string, id)) {
                        assistant_id_hits += 1;
                        if (assistant_id_hits > 1) return error.TestUnexpectedResult;
                    }
                }
            }
            continue;
        }

        if (std.mem.eql(u8, role, "tool")) {
            const tid_v = obj.get("tool_call_id") orelse return error.TestUnexpectedResult;
            if (tid_v != .string) return error.TestUnexpectedResult;
            if (!std.mem.eql(u8, tid_v.string, id)) continue;
            tool_hits += 1;
            if (tool_hits > 1) return error.TestUnexpectedResult; // duplicate tool for id
            const content_v = obj.get("content") orelse return error.TestUnexpectedResult;
            if (content_v != .string) return error.TestUnexpectedResult;
            const body = content_v.string;
            switch (body_expect) {
                .exact => |want| {
                    if (std.mem.eql(u8, body, want)) matched_body = true;
                },
                .code => |code| {
                    if (tool_error.hasCode(body, code)) matched_body = true;
                },
            }
            continue;
        }
    }

    if (assistant_id_hits != 1) return error.TestUnexpectedResult;
    if (tool_hits != 1) return error.TestUnexpectedResult;
    if (!matched_body) return error.TestUnexpectedResult;
}

fn expectSessionPairedOutcome(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    id: []const u8,
    body_expect: SessionBodyExpect,
) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);
    try expectSessionPairedOutcomeBytes(gpa, raw, id, body_expect);
}

/// Independent raw-byte forbid (separate from semantic id↔tool pairing).
/// Any occurrence of `needle` in durable session bytes fails.
fn expectSessionBytesForbidNeedle(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    needle: []const u8,
) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);
    try expectRawForbidsNeedle(raw, needle);
}

fn expectRawForbidsNeedle(raw: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, raw, needle) != null) return error.TestUnexpectedResult;
}

test "h-integration helper: paired outcome accepts unique assistant+tool" {
    const gpa = std.testing.allocator;
    // Shape matches product session JSONL (header + roles + tool_calls array).
    const raw =
        \\{"schema_version":1,"type":"zag_session","compaction_gen":0}
        \\{"role":"system","content":"sys"}
        \\{"role":"user","content":"hi"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"call-a","name":"read_file","arguments":"{\"path\":\"x\"}"}]}
        \\{"role":"tool","tool_call_id":"call-a","content":"error: code=jail_deny message=blocked"}
        \\
    ;
    try expectSessionPairedOutcomeBytes(gpa, raw, "call-a", .{ .code = .jail_deny });
    try expectSessionPairedOutcomeBytes(gpa, raw, "call-a", .{
        .exact = "error: code=jail_deny message=blocked",
    });
}

test "h-integration helper: same-array duplicate assistant id fails" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"hi"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"dup","name":"a","arguments":"{}"},{"id":"dup","name":"b","arguments":"{}"}]}
        \\{"role":"tool","tool_call_id":"dup","content":"error: code=cancelled message=x"}
        \\
    ;
    try std.testing.expectError(
        error.TestUnexpectedResult,
        expectSessionPairedOutcomeBytes(gpa, raw, "dup", .{ .code = .cancelled }),
    );
}

test "h-integration helper: cross-assistant duplicate id fails with one tool" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"hi"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"x1","name":"a","arguments":"{}"}]}
        \\{"role":"tool","tool_call_id":"x1","content":"error: code=permission_denied message=no"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"x1","name":"a","arguments":"{}"}]}
        \\
    ;
    try std.testing.expectError(
        error.TestUnexpectedResult,
        expectSessionPairedOutcomeBytes(gpa, raw, "x1", .{ .code = .permission_denied }),
    );
}

test "h-integration helper: raw forbid needle fails when secret present in any field" {
    const secret = "OUTSIDE_SECRET_BYTES_v1";
    // Secret in arguments (or any raw field) must fail independent forbid check.
    const contaminated =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"j1","name":"read_file","arguments":"{\"leak\":\"OUTSIDE_SECRET_BYTES_v1\"}"}]}
        \\{"role":"tool","tool_call_id":"j1","content":"error: code=jail_deny message=blocked"}
        \\
    ;
    try std.testing.expectError(
        error.TestUnexpectedResult,
        expectRawForbidsNeedle(contaminated, secret),
    );
    // Clean durable bytes must pass forbid.
    const clean =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"assistant","content":"","tool_calls":[{"id":"j1","name":"read_file","arguments":"{\"path\":\"escape_file\"}"}]}
        \\{"role":"tool","tool_call_id":"j1","content":"error: code=jail_deny message=blocked"}
        \\
    ;
    try expectRawForbidsNeedle(clean, secret);
}

/// Integration Gate terminal: exactly one parsed `kind=run_end` object with
/// matching `ok` bool and `stop_reason` string (same object). Fail-loud on
/// malformed lines, missing fields, wrong types, or duplicate terminals.
fn expectUniqueStructuredRunEnd(
    gpa: std.mem.Allocator,
    buf: []const u8,
    ok: bool,
    stop_reason: []const u8,
) !void {
    var run_end_count: u32 = 0;
    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
            return error.TestUnexpectedResult;
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestUnexpectedResult;
        const obj = parsed.value.object;
        const kind_v = obj.get("kind") orelse return error.TestUnexpectedResult;
        if (kind_v != .string) return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, kind_v.string, "run_end")) continue;

        run_end_count += 1;
        if (run_end_count > 1) return error.TestUnexpectedResult;

        const ok_v = obj.get("ok") orelse return error.TestUnexpectedResult;
        if (ok_v != .bool) return error.TestUnexpectedResult;
        if (ok_v.bool != ok) return error.TestUnexpectedResult;

        const stop_v = obj.get("stop_reason") orelse return error.TestUnexpectedResult;
        if (stop_v != .string) return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, stop_v.string, stop_reason)) return error.TestUnexpectedResult;
    }
    if (run_end_count != 1) return error.TestUnexpectedResult;
}

const ShellTraceBodyExpect = union(enum) {
    first_line: []const u8,
    exact: []const u8,
    code: tool_error.Code,
};

const StructuredShellTraceExpect = struct {
    call_id: []const u8,
    body: ShellTraceBodyExpect,
    shell_deny_count: u32,
};

fn bodyFirstLine(body: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    return body[0..end];
}

/// Parse one single-call trace and correlate its descriptor-selected shell
/// decision by exact-one call/result counts plus name/body. `tool_result` has
/// no call ID; exact ID pairing remains transcript/session-owned. Runtime
/// shell-v1 results have no shell_deny event; policy denial has exactly one.
fn expectStructuredShellTrace(
    gpa: std.mem.Allocator,
    buf: []const u8,
    expected: StructuredShellTraceExpect,
) !void {
    var run_start_count: u32 = 0;
    var permission_count: u32 = 0;
    var shell_deny_count: u32 = 0;
    var tool_call_count: u32 = 0;
    var tool_result_count: u32 = 0;
    var run_end_count: u32 = 0;

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
            return error.TestUnexpectedResult;
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestUnexpectedResult;
        const obj = parsed.value.object;
        const kind_v = obj.get("kind") orelse return error.TestUnexpectedResult;
        if (kind_v != .string) return error.TestUnexpectedResult;
        const kind = kind_v.string;

        if (std.mem.eql(u8, kind, "run_start")) {
            run_start_count += 1;
            const policy_v = obj.get("shell_policy") orelse return error.TestUnexpectedResult;
            if (policy_v != .string or !std.mem.eql(u8, policy_v.string, "protect"))
                return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "permission")) {
            permission_count += 1;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            const risk_v = obj.get("risk") orelse return error.TestUnexpectedResult;
            const allowed_v = obj.get("allowed") orelse return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "run_shell"))
                return error.TestUnexpectedResult;
            if (risk_v != .string or !std.mem.eql(u8, risk_v.string, "execute"))
                return error.TestUnexpectedResult;
            if (allowed_v != .bool or !allowed_v.bool) return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "shell_deny")) {
            shell_deny_count += 1;
            continue;
        }
        if (std.mem.eql(u8, kind, "tool_call")) {
            tool_call_count += 1;
            const id_v = obj.get("id") orelse return error.TestUnexpectedResult;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            if (id_v != .string or !std.mem.eql(u8, id_v.string, expected.call_id))
                return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "run_shell"))
                return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "tool_result")) {
            tool_result_count += 1;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            const body_v = obj.get("body") orelse return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "run_shell"))
                return error.TestUnexpectedResult;
            if (body_v != .string) return error.TestUnexpectedResult;
            switch (expected.body) {
                .first_line => |header| {
                    if (!std.mem.eql(u8, bodyFirstLine(body_v.string), header))
                        return error.TestUnexpectedResult;
                },
                .exact => |body| {
                    if (!std.mem.eql(u8, body_v.string, body)) return error.TestUnexpectedResult;
                },
                .code => |code| {
                    if (!tool_error.hasCode(body_v.string, code)) return error.TestUnexpectedResult;
                },
            }
            continue;
        }
        if (std.mem.eql(u8, kind, "run_end")) {
            run_end_count += 1;
            const ok_v = obj.get("ok") orelse return error.TestUnexpectedResult;
            const stop_v = obj.get("stop_reason") orelse return error.TestUnexpectedResult;
            if (ok_v != .bool or !ok_v.bool) return error.TestUnexpectedResult;
            if (stop_v != .string or !std.mem.eql(u8, stop_v.string, "completed"))
                return error.TestUnexpectedResult;
        }
    }

    try std.testing.expectEqual(@as(u32, 1), run_start_count);
    try std.testing.expectEqual(@as(u32, 1), permission_count);
    try std.testing.expectEqual(expected.shell_deny_count, shell_deny_count);
    try std.testing.expectEqual(@as(u32, 1), tool_call_count);
    try std.testing.expectEqual(@as(u32, 1), tool_result_count);
    try std.testing.expectEqual(@as(u32, 1), run_end_count);
}

test "h-integration: default Agent ask-deny write leaves target, permission_denied, save/resume+trace" {
    // Goal: default built-in write_file through Agent.reply under ask/deny gate —
    // no FS mutation, descriptor-derived permission_denied, original Tool-call ID
    // paired in transcript + resumed session, permission trace event, soft-deny
    // recovery ends with one completed terminal.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-int-policy-deny";
    const sess_path = ".zag-test-h-int-policy-deny/s.jsonl";
    const target = ".zag-test-h-int-policy-deny/must-not-write.txt";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "int-policy-write-1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(
                        u8,
                        "{\"path\":\".zag-test-h-int-policy-deny/must-not-write.txt\",\"content\":\"MUST_NOT_PERSIST\"}",
                    ),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "ok-denied-and-recovered"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        // Default product policy surface: ask mode + deny gate (no stdin HITL).
        .permission_mode = .ask,
        .permission_gate = permissions.Gate.denyAllDangerous(),
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    // Memory-only product trace (same facade path as durable trace).
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "write the secret file");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expectEqualStrings("ok-denied-and-recovered", result.final_text);

        const body = try expectPairedToolId(session.transcript.items(), "int-policy-write-1");
        try std.testing.expect(tool_error.hasCode(body, .permission_denied));
        try std.testing.expect(std.mem.indexOf(u8, body, "MUST_NOT_PERSIST") == null);

        // Target must be absent (handler never ran / no mutation).
        try expectPathAbsent(io, target);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectRunEnd(tr, true, "completed");
        try expectUniqueStructuredRunEnd(gpa, tr.buf.items, true, "completed");
        // One gated write denial: exactly one permission event (+ tool_call/result).
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("permission"));
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_result"));
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"permission\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"allowed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"risk\":\"write\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "write_file") != null);
        try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);

        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "int-policy-write-1",
            .{ .code = .permission_denied },
        );
    }

    // Atomic save survived; resume preserves original non-secret Tool-call ID pairing.
    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const resumed_body = try expectPairedToolId(resumed.transcript.items(), "int-policy-write-1");
    try std.testing.expect(tool_error.hasCode(resumed_body, .permission_denied));
    try expectPathAbsent(io, target);
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        "int-policy-write-1",
        .{ .code = .permission_denied },
    );
}

test "h-integration: default Agent yolo escaping-symlink jail_deny, outside intact, save/resume+trace" {
    // Goal: real default built-in read_file through Agent.reply under permissive
    // gate; escaping workspace symlink does not expose outside bytes; jail_deny
    // machine body + jail_deny trace; ID pairing survives save/resume; soft deny
    // recovers to completed terminal.
    // Platform: Windows lacks portable symlink fixtures here (SkipZigTest only);
    // AccessDenied on symlink create also skips — not a false green on hosts that support links.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    const outside_bytes = "OUTSIDE_SECRET_BYTES_v1\n";
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = outside_bytes });

    var ws = try parent.dir.openDir(io, "ws", .{});
    defer ws.close(io);
    ws.symLink(io, "../outside/secret.txt", "escape_file", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => |e| return e,
    };

    var scoped = try ScopedCwd.enter(io, ws);
    defer scoped.leave();

    const sess_path = "s-h-int-jail.jsonl";

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "int-jail-read-1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"escape_file\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "ok-jailed-and-recovered"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    // Trace cwd = workspace (process cwd after ScopedCwd).
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "read escape symlink");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expectEqualStrings("ok-jailed-and-recovered", result.final_text);

        const body = try expectPairedToolId(session.transcript.items(), "int-jail-read-1");
        try std.testing.expect(tool_error.hasCode(body, .jail_deny));
        try std.testing.expect(std.mem.indexOf(u8, body, "OUTSIDE_SECRET") == null);

        const after = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(outside_bytes, after);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectRunEnd(tr, true, "completed");
        try expectUniqueStructuredRunEnd(gpa, tr.buf.items, true, "completed");
        // One escaping read: exactly one jail_deny (+ tool_call/result).
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("jail_deny"));
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_result"));
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"jail_deny\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "read_file") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "OUTSIDE_SECRET") == null);
        try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);

        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "int-jail-read-1",
            .{ .code = .jail_deny },
        );
        // Independent of semantic pairing: no outside secret substring in durable bytes.
        try expectSessionBytesForbidNeedle(gpa, io, sess_path, "OUTSIDE_SECRET");
        try expectSessionBytesForbidNeedle(gpa, io, sess_path, outside_bytes);
    }

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const resumed_body = try expectPairedToolId(resumed.transcript.items(), "int-jail-read-1");
    try std.testing.expect(tool_error.hasCode(resumed_body, .jail_deny));
    try std.testing.expect(std.mem.indexOf(u8, resumed_body, "OUTSIDE_SECRET") == null);
    const after2 = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
    defer gpa.free(after2);
    try std.testing.expectEqualStrings(outside_bytes, after2);
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        "int-jail-read-1",
        .{ .code = .jail_deny },
    );
    try expectSessionBytesForbidNeedle(gpa, io, sess_path, "OUTSIDE_SECRET");
    try expectSessionBytesForbidNeedle(gpa, io, sess_path, outside_bytes);
}

const edit_agent_call_id = "edit-fault-write-1";
const edit_agent_target = ".zag-test-h-edit-agent/edits/target.txt";
const edit_agent_failure_body =
    "error: code=edit_io_failed format=edit-v1 operation=write_file stage=write target=preserved parent_dirs=unchanged temp_artifact=absent";

fn expectStructuredEditFailureTrace(gpa: std.mem.Allocator, buf: []const u8) !void {
    var permission_count: u32 = 0;
    var tool_call_count: u32 = 0;
    var tool_result_count: u32 = 0;
    var run_end_count: u32 = 0;

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
            return error.TestUnexpectedResult;
        defer parsed.deinit();
        if (parsed.value != .object) return error.TestUnexpectedResult;
        const obj = parsed.value.object;
        const kind_v = obj.get("kind") orelse return error.TestUnexpectedResult;
        if (kind_v != .string) return error.TestUnexpectedResult;
        const kind = kind_v.string;

        if (std.mem.eql(u8, kind, "permission")) {
            permission_count += 1;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            const risk_v = obj.get("risk") orelse return error.TestUnexpectedResult;
            const allowed_v = obj.get("allowed") orelse return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "write_file"))
                return error.TestUnexpectedResult;
            if (risk_v != .string or !std.mem.eql(u8, risk_v.string, "write"))
                return error.TestUnexpectedResult;
            if (allowed_v != .bool or !allowed_v.bool) return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "tool_call")) {
            tool_call_count += 1;
            const id_v = obj.get("id") orelse return error.TestUnexpectedResult;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            if (id_v != .string or !std.mem.eql(u8, id_v.string, edit_agent_call_id))
                return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "write_file"))
                return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "tool_result")) {
            tool_result_count += 1;
            // Schema truth: trace results have name+body, not a Tool-call ID.
            if (obj.get("id") != null or obj.get("tool_call_id") != null)
                return error.TestUnexpectedResult;
            const name_v = obj.get("name") orelse return error.TestUnexpectedResult;
            const body_v = obj.get("body") orelse return error.TestUnexpectedResult;
            if (name_v != .string or !std.mem.eql(u8, name_v.string, "write_file"))
                return error.TestUnexpectedResult;
            if (body_v != .string or !std.mem.eql(u8, body_v.string, edit_agent_failure_body))
                return error.TestUnexpectedResult;
            continue;
        }
        if (std.mem.eql(u8, kind, "run_end")) {
            run_end_count += 1;
            const ok_v = obj.get("ok") orelse return error.TestUnexpectedResult;
            const stop_v = obj.get("stop_reason") orelse return error.TestUnexpectedResult;
            if (ok_v != .bool or !ok_v.bool) return error.TestUnexpectedResult;
            if (stop_v != .string or !std.mem.eql(u8, stop_v.string, "completed"))
                return error.TestUnexpectedResult;
        }
    }

    try std.testing.expectEqual(@as(u32, 1), permission_count);
    try std.testing.expectEqual(@as(u32, 1), tool_call_count);
    try std.testing.expectEqual(@as(u32, 1), tool_result_count);
    try std.testing.expectEqual(@as(u32, 1), run_end_count);
}

fn expectEditTargetAndNoTemp(io: Io, gpa: std.mem.Allocator, expected: []const u8) !void {
    const actual = try Io.Dir.cwd().readFileAlloc(io, edit_agent_target, gpa, .limited(expected.len + 1));
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);

    var dir = try Io.Dir.cwd().openDir(io, ".zag-test-h-edit-agent/edits", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        count += 1;
        try std.testing.expectEqualStrings("target.txt", entry.name);
        try std.testing.expect(entry.kind == .file);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "h-edit: recoverable write fault composes transcript session resume parsed trace terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-h-edit-agent";
    const sess_path = ".zag-test-h-edit-agent/s.jsonl";
    const original = "ORIGINAL_TARGET_BYTES\n";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, ".zag-test-h-edit-agent/edits");
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit_agent_target, .data = original });
    edit_tools.testing.reset();
    defer edit_tools.testing.reset();

    const Mock = struct {
        step: u32 = 0,

        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const calls = try arena.alloc(message.ToolCall, 1);
                calls[0] = .{
                    .id = try arena.dupe(u8, edit_agent_call_id),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(
                        u8,
                        "{\"path\":\".zag-test-h-edit-agent/edits/target.txt\",\"content\":\"COMPLETE_NEW_BYTES\\n\"}",
                    ),
                };
                return .{ .content = "", .tool_calls = calls, .finish_reason = "tool_calls" };
            }
            if (self.step != 2) return error.InvalidResponse;
            const body = toolBodyById(messages, edit_agent_call_id) orelse
                return error.InvalidResponse;
            if (!assistantHasCallId(messages, edit_agent_call_id)) return error.InvalidResponse;
            if (!std.mem.eql(u8, body, edit_agent_failure_body)) return error.InvalidResponse;
            return .{
                .content = try arena.dupe(u8, "edit-failure-recovered"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    // This fixture owns edit-fault composition only. Separate core tests own
    // ask/remember prompting and execution-time Guard evidence.
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    edit_tools.testing.failNextEditAt(.write_after_prefix);
    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "replace the target");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expectEqualStrings("edit-failure-recovered", result.final_text);
        try std.testing.expectEqual(@as(u32, 2), mock.step);

        const body = try expectPairedToolId(session.transcript.items(), edit_agent_call_id);
        try std.testing.expectEqualStrings(edit_agent_failure_body, body);
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            edit_agent_call_id,
            .{ .exact = edit_agent_failure_body },
        );
        try expectEditTargetAndNoTemp(io, gpa, original);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectStructuredEditFailureTrace(gpa, tr.buf.items);
        try expectUniqueStructuredRunEnd(gpa, tr.buf.items, true, "completed");
        try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
    }

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const resumed_body = try expectPairedToolId(resumed.transcript.items(), edit_agent_call_id);
    try std.testing.expectEqualStrings(edit_agent_failure_body, resumed_body);
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        edit_agent_call_id,
        .{ .exact = edit_agent_failure_body },
    );
    try expectEditTargetAndNoTemp(io, gpa, original);
}

const ShellRecoveryProvider = struct {
    call_id: []const u8,
    command: []const u8,
    recovery: []const u8,
    expected_body: ShellTraceBodyExpect,
    step: u32 = 0,

    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        _: []const tool.Definition,
        _: provider_mod.RequestControl,
        _: ?*?u64,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.step += 1;
        if (self.step == 1) {
            const calls = try arena.alloc(message.ToolCall, 1);
            calls[0] = .{
                .id = try arena.dupe(u8, self.call_id),
                .name = try arena.dupe(u8, "run_shell"),
                .arguments = try std.fmt.allocPrint(arena, "{{\"command\":{f}}}", .{
                    std.json.fmt(self.command, .{}),
                }),
            };
            return .{ .content = "", .tool_calls = calls, .finish_reason = "tool_calls" };
        }
        if (self.step != 2) return error.InvalidResponse;

        const body = toolBodyById(messages, self.call_id) orelse return error.InvalidResponse;
        if (!assistantHasCallId(messages, self.call_id)) return error.InvalidResponse;
        switch (self.expected_body) {
            .first_line => |header| {
                if (!std.mem.eql(u8, bodyFirstLine(body), header)) return error.InvalidResponse;
            },
            .exact => |expected| {
                if (!std.mem.eql(u8, body, expected)) return error.InvalidResponse;
            },
            .code => |code| {
                if (!tool_error.hasCode(body, code)) return error.InvalidResponse;
            },
        }
        return .{
            .content = try arena.dupe(u8, self.recovery),
            .tool_calls = &.{},
            .finish_reason = "stop",
        };
    }
};

const fixed_shell_deny_body =
    "error: code=shell_deny message=shell command blocked by policy; use a safer command or ask the user to adjust policy";
const shell_deny_command_sentinel = "rm -rf / # SHELL_DENY_COMMAND_SENTINEL";

const ShellDenyProbe = struct {
    invocations: *u32,

    fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
        const self: *ShellDenyProbe = @ptrCast(@alignCast(instance.?));
        self.invocations.* += 1;
        return ctx.allocator.dupe(u8, "unexpected shell handler invocation") catch
            return error.OutOfMemory;
    }
};

test "h-shell: default protect policy deny skips handler and roundtrips session trace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-h-shell-policy";
    const sess_path = ".zag-test-h-shell-policy/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    edit_tools.testing.reset();
    defer edit_tools.testing.reset();

    var provider_state: ShellRecoveryProvider = .{
        .call_id = "shell-policy-1",
        .command = shell_deny_command_sentinel,
        .recovery = "policy-deny-recovered",
        .expected_body = .{ .exact = fixed_shell_deny_body },
    };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &provider_state,
        .vtable = &.{ .chat = ShellRecoveryProvider.chat },
    }, .{
        .permission_mode = .yolo,
        // `shell_policy` intentionally omitted: product default `.protect`.
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var handler_invocations: u32 = 0;
    var probe: ShellDenyProbe = .{ .invocations = &handler_invocations };
    const deny_tools = [_]tool.Tool{.{
        .descriptor = agent.tools_storage.tools[8].descriptor, // run_shell (after apply_transaction)
        .instance = &probe,
        .handler = ShellDenyProbe.handle,
    }};
    agent.test_tools = &deny_tools;

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "attempt denied shell command");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expectEqualStrings("policy-deny-recovered", result.final_text);
        try std.testing.expectEqual(@as(u32, 0), handler_invocations);
        try std.testing.expectEqual(@as(u32, 2), provider_state.step);

        const body = try expectPairedToolId(session.transcript.items(), "shell-policy-1");
        try std.testing.expectEqualStrings(fixed_shell_deny_body, body);
        try std.testing.expect(tool_error.hasCode(body, .shell_deny));
        try std.testing.expect(std.mem.indexOf(u8, body, "SHELL_DENY_COMMAND_SENTINEL") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "format=shell-v1") == null);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectStructuredShellTrace(gpa, tr.buf.items, .{
            .call_id = "shell-policy-1",
            .body = .{ .exact = fixed_shell_deny_body },
            .shell_deny_count = 1,
        });
        try expectRunEnd(tr, true, "completed");
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "shell-policy-1",
            .{ .exact = fixed_shell_deny_body },
        );
    }

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const resumed_body = try expectPairedToolId(resumed.transcript.items(), "shell-policy-1");
    try std.testing.expectEqualStrings(fixed_shell_deny_body, resumed_body);
    try std.testing.expect(std.mem.indexOf(u8, resumed_body, "SHELL_DENY_COMMAND_SENTINEL") == null);
    try std.testing.expectEqual(@as(u32, 0), handler_invocations);
}

const AgentShellFixture = struct {
    dir_name: []const u8,
    call_id: []const u8,
    command: []const u8,
    shell_path: []const u8 = "/bin/sh",
    timeout_ms: u32 = 30_000,
    stdout_limit: usize = 30 * 1024,
    stderr_limit: usize = 30 * 1024,
    expected_header: []const u8,
    expected_body: ?[]const u8 = null,
    forbidden_result_bytes: []const []const u8 = &.{},
};

fn requireAgentRealShellFixture() !void {
    switch (builtin.os.tag) {
        .macos, .linux => {},
        else => return error.SkipZigTest,
    }
}

fn runAgentShellFixture(fixture: AgentShellFixture) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sess_path = try std.fmt.allocPrint(gpa, "{s}/s.jsonl", .{fixture.dir_name});
    defer gpa.free(sess_path);
    Io.Dir.cwd().deleteTree(io, fixture.dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, fixture.dir_name);
    defer Io.Dir.cwd().deleteTree(io, fixture.dir_name) catch {};

    edit_tools.testing.configure(
        fixture.shell_path,
        fixture.timeout_ms,
        fixture.stdout_limit,
        fixture.stderr_limit,
    );
    defer edit_tools.testing.reset();

    var provider_state: ShellRecoveryProvider = .{
        .call_id = fixture.call_id,
        .command = fixture.command,
        .recovery = "shell-runtime-recovered",
        .expected_body = .{ .first_line = fixture.expected_header },
    };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &provider_state,
        .vtable = &.{ .chat = ShellRecoveryProvider.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var expected_body: ?[]u8 = null;
    defer if (expected_body) |body| gpa.free(body);
    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "run shell fixture");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expectEqualStrings("shell-runtime-recovered", result.final_text);
        try std.testing.expectEqual(@as(u32, 2), provider_state.step);

        const body = try expectPairedToolId(session.transcript.items(), fixture.call_id);
        try std.testing.expectEqualStrings(fixture.expected_header, bodyFirstLine(body));
        if (fixture.expected_body) |exact| try std.testing.expectEqualStrings(exact, body);
        try std.testing.expect(std.unicode.utf8ValidateSlice(body));
        try std.testing.expect(body.len <= tool.max_result_bytes);
        try std.testing.expect(std.mem.indexOf(u8, body, "code=shell_deny") == null);
        for (fixture.forbidden_result_bytes) |forbidden| {
            try std.testing.expect(std.mem.indexOf(u8, body, forbidden) == null);
        }
        expected_body = try gpa.dupe(u8, body);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectStructuredShellTrace(gpa, tr.buf.items, .{
            .call_id = fixture.call_id,
            .body = .{ .first_line = fixture.expected_header },
            .shell_deny_count = 0,
        });
        try expectRunEnd(tr, true, "completed");
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"stop_reason\":\"timeout\"") == null);
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            fixture.call_id,
            .{ .exact = expected_body.? },
        );
    }

    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const resumed_body = try expectPairedToolId(resumed.transcript.items(), fixture.call_id);
    try std.testing.expectEqualStrings(expected_body.?, resumed_body);
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        fixture.call_id,
        .{ .exact = expected_body.? },
    );
}

test "h-shell: Agent success and nonzero compose transcript session resume trace terminal" {
    try requireAgentRealShellFixture();
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-success",
        .call_id = "shell-success-1",
        .command = "printf agent-out; printf agent-err >&2",
        .expected_header = "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=9 stderr_bytes=9 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false",
    });
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-nonzero",
        .call_id = "shell-nonzero-1",
        .command = "printf nz; printf bad >&2; exit 7",
        .expected_header = "error: code=shell_nonzero format=shell-v1 exit_code=7 stdout_bytes=2 stderr_bytes=3 stdout_encoding=utf8 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false",
    });
}

test "h-shell: Agent invalid UTF-8 base64 roundtrips session resume parsed trace completed" {
    try requireAgentRealShellFixture();
    const header = "ok: code=shell_success format=shell-v1 exit_code=0 stdout_bytes=1 stderr_bytes=0 stdout_encoding=base64 stderr_encoding=utf8 stdout_truncated=false stderr_truncated=false";
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-invalid-utf8",
        .call_id = "shell-invalid-utf8-1",
        .command = "printf '\\377'",
        .expected_header = header,
        .expected_body = header ++ "\n--- stdout ---\n/w==\n--- stderr ---\n",
    });
}

test "h-shell: Agent timeout and output limit are soft recovered completed outcomes" {
    try requireAgentRealShellFixture();
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-timeout",
        .call_id = "shell-timeout-1",
        .command = ": AGENT_TIMEOUT_COMMAND_SECRET; while :; do :; done",
        .timeout_ms = 100,
        .expected_header = "error: code=shell_timeout format=shell-v1 timeout_ms=100 partial_output_available=false cleanup_scope=direct_child",
        .forbidden_result_bytes = &.{ "AGENT_TIMEOUT_COMMAND_SECRET", "--- stdout ---", "--- stderr ---" },
    });
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-output",
        .call_id = "shell-output-1",
        .command = ": AGENT_OUTPUT_COMMAND_SECRET; while :; do printf abcdefghijklmnop; done",
        .stdout_limit = 12,
        .stderr_limit = 13,
        .expected_header = "error: code=shell_output_limit format=shell-v1 limit_scope=capture stdout_limit_bytes=12 stderr_limit_bytes=13 exceeded_stream=unknown partial_output_available=false cleanup_scope=direct_child",
        .forbidden_result_bytes = &.{ "AGENT_OUTPUT_COMMAND_SECRET", "--- stdout ---", "--- stderr ---" },
    });
}

test "h-shell: Agent sanitized process failure composes and recovers" {
    try requireAgentRealShellFixture();
    const invalid_path = "/zag-test-missing/AGENT_RAW_SHELL_PATH_SECRET";
    try runAgentShellFixture(.{
        .dir_name = ".zag-test-h-shell-agent-process-failure",
        .call_id = "shell-process-failure-1",
        .command = ": AGENT_PROCESS_COMMAND_SECRET",
        .shell_path = invalid_path,
        .expected_header = "error: code=shell_process_failure format=shell-v1 stage=run partial_output_available=false",
        .forbidden_result_bytes = &.{
            invalid_path,
            "AGENT_RAW_SHELL_PATH_SECRET",
            "AGENT_PROCESS_COMMAND_SECRET",
            "FileNotFound",
            "AccessDenied",
            "InvalidExe",
        },
    });
}

/// Instance state for between-Tool cancel: first handler runs, then requests cancel.
const BetweenCancelFirst = struct {
    cancel: *cancel_mod.Flag,
    ran: *u32,

    fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
        const self: *BetweenCancelFirst = @ptrCast(@alignCast(instance.?));
        self.ran.* += 1;
        // Between-invocation only: flag is observed before the next call starts.
        self.cancel.request();
        return ctx.allocator.dupe(u8, "first-handler-done") catch return error.OutOfMemory;
    }
};

const BetweenCancelPending = struct {
    ran: *u32,
    label: []const u8,

    fn handle(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
        const self: *BetweenCancelPending = @ptrCast(@alignCast(instance.?));
        self.ran.* += 1;
        return std.fmt.allocPrint(ctx.allocator, "{s}-must-not-run", .{self.label}) catch
            return error.OutOfMemory;
    }
};

test "h-integration: cancel between accepted Tools preserves IDs, skips pending, one cancelled terminal" {
    // Goal: one complete provider turn with ≥2 accepted calls; first handler finishes
    // and requests cancel; pending handlers never execute and get code=cancelled;
    // original provider IDs pair across Result/transcript/session/trace; single
    // cancelled terminal. Not mid-flight preemption of a running handler.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-h-int-between-cancel";
    const sess_path = ".zag-test-h-int-between-cancel/s.jsonl";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            // Single complete multi-tool turn (validated AssistantTurn).
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 3);
                tc[0] = .{
                    .id = try arena.dupe(u8, "provider-multi-1"),
                    .name = try arena.dupe(u8, "first_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "provider-multi-2"),
                    .name = try arena.dupe(u8, "second_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                tc[2] = .{
                    .id = try arena.dupe(u8, "provider-multi-3"),
                    .name = try arena.dupe(u8, "third_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{ .content = "batch", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            // Must not be reached after between-tool cancel.
            return .{
                .content = try arena.dupe(u8, "unexpected-continue"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var first_ran: u32 = 0;
    var second_ran: u32 = 0;
    var third_ran: u32 = 0;
    var first_state: BetweenCancelFirst = .{ .cancel = &agent.cancel, .ran = &first_ran };
    var second_state: BetweenCancelPending = .{ .ran = &second_ran, .label = "second" };
    var third_state: BetweenCancelPending = .{ .ran = &third_ran, .label = "third" };

    // Test-only tool override (no production escape hatch): cancel state only.
    // Distinct second/third names + instances so each pending handler is counted.
    const tools = [_]tool.Tool{
        .{
            .descriptor = .{
                .definition = .{
                    .name = "first_tool",
                    .description = "runs then requests cancel",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .none,
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = &first_state,
            .handler = BetweenCancelFirst.handle,
        },
        .{
            .descriptor = .{
                .definition = .{
                    .name = "second_tool",
                    .description = "must not run after cancel",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .none,
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = &second_state,
            .handler = BetweenCancelPending.handle,
        },
        .{
            .descriptor = .{
                .definition = .{
                    .name = "third_tool",
                    .description = "must not run after cancel",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .none,
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = &third_state,
            .handler = BetweenCancelPending.handle,
        },
    };
    agent.test_tools = &tools;

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        const result = try agent.reply(&session, "run multi tools");
        try std.testing.expectEqual(loop.StopReason.cancelled, result.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), first_ran);
        try std.testing.expectEqual(@as(u32, 0), second_ran);
        try std.testing.expectEqual(@as(u32, 0), third_ran);
        try std.testing.expectEqual(@as(u32, 1), mock.step);

        const body1 = try expectPairedToolId(session.transcript.items(), "provider-multi-1");
        try std.testing.expectEqualStrings("first-handler-done", body1);
        try std.testing.expect(!tool_error.hasCode(body1, .cancelled));

        const body2 = try expectPairedToolId(session.transcript.items(), "provider-multi-2");
        try std.testing.expect(tool_error.hasCode(body2, .cancelled));
        try std.testing.expect(std.mem.indexOf(u8, body2, "second-must-not-run") == null);

        const body3 = try expectPairedToolId(session.transcript.items(), "provider-multi-3");
        try std.testing.expect(tool_error.hasCode(body3, .cancelled));
        try std.testing.expect(std.mem.indexOf(u8, body3, "third-must-not-run") == null);

        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try expectRunEnd(tr, true, "cancelled");
        try expectUniqueStructuredRunEnd(gpa, tr.buf.items, true, "cancelled");
        try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("run_end"));
        // Between-call cancel: only the executed call emits tool_call; every
        // accepted call (executed + pending cancelled) emits tool_result.
        // Pending tool_result has no id field (schema); IDs pair on transcript/session.
        try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
        try std.testing.expectEqual(@as(u32, 3), tr.countKind("tool_result"));
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "provider-multi-1") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "code=cancelled") != null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "first-handler-done") != null);

        // Durable session: each original id bound to its own tool record outcome.
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "provider-multi-1",
            .{ .exact = "first-handler-done" },
        );
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "provider-multi-2",
            .{ .code = .cancelled },
        );
        try expectSessionPairedOutcome(
            gpa,
            io,
            sess_path,
            "provider-multi-3",
            .{ .code = .cancelled },
        );
    }

    // Resume pairing: executed + pending cancelled bodies keep provider IDs.
    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = sess_path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    const r1 = try expectPairedToolId(resumed.transcript.items(), "provider-multi-1");
    try std.testing.expectEqualStrings("first-handler-done", r1);
    try std.testing.expect(!tool_error.hasCode(r1, .cancelled));
    const r2 = try expectPairedToolId(resumed.transcript.items(), "provider-multi-2");
    try std.testing.expect(tool_error.hasCode(r2, .cancelled));
    const r3 = try expectPairedToolId(resumed.transcript.items(), "provider-multi-3");
    try std.testing.expect(tool_error.hasCode(r3, .cancelled));
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        "provider-multi-1",
        .{ .exact = "first-handler-done" },
    );
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        "provider-multi-2",
        .{ .code = .cancelled },
    );
    try expectSessionPairedOutcome(
        gpa,
        io,
        sess_path,
        "provider-multi-3",
        .{ .code = .cancelled },
    );
}

// ── core-policy-ownership-001 regression tests ──────────────────────────────

test "core-policy-ownership-001: product deny body bytes match baseline fixture" {
    // The product ToolPolicy adapter renders deny bodies via the moved
    // permissions.deniedMessage/deniedMessageWithReason. These must produce
    // the exact baseline bytes: "error: code=permission_denied message=...".
    const gpa = std.testing.allocator;

    // User deny body.
    const user_body = try permissions.deniedMessage(gpa, "write_file");
    defer gpa.free(user_body);
    try std.testing.expect(tool_error.hasCode(user_body, .permission_denied));
    try std.testing.expect(std.mem.indexOf(u8, user_body, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_body, "user rejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_body, "Do not retry") != null);

    // Plan-mode deny body.
    const plan_body = try permissions.deniedMessageWithReason(gpa, "run_shell", .plan_mode);
    defer gpa.free(plan_body);
    try std.testing.expect(tool_error.hasCode(plan_body, .permission_denied));
    try std.testing.expect(std.mem.indexOf(u8, plan_body, "run_shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_body, "plan mode") != null);

    // Shell deny body.
    const shell_body = try shell_policy.deniedMessage(gpa, "rm -rf /");
    defer gpa.free(shell_body);
    try std.testing.expectEqualStrings(
        "error: code=shell_deny message=shell command blocked by policy; use a safer command or ask the user to adjust policy",
        shell_body,
    );

    // Jail deny body.
    const jail_body = try workspace.deniedMessage(gpa);
    defer gpa.free(jail_body);
    try std.testing.expectEqualStrings(
        "error: code=jail_deny message=" ++ workspace.jail_deny_message,
        jail_body,
    );
}

test "core-policy-ownership-001: product yolo still jail-denies escaping symlink" {
    // Yolo bypasses confirmation only; it must NOT bypass jail or shell policy.
    // The existing h-integration test already proves this with full Agent.reply;
    // here we verify the guard directly under yolo.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "OUTSIDE\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .access_sub_paths = true });
    defer ws.close(io);
    try ws.symLink(io, "../outside/secret.txt", "escape_file", .{});

    // Yolo gate allows everything; Guard must still deny.
    const gate = permissions.Gate.yolo();
    const desc = permissions.testDescriptor("read_file", .read);
    const outcome = gate.check(desc, "{}", "escape_file");
    try std.testing.expect(outcome.decision == .allow); // yolo allows

    var guard = try workspace.guardFrom(gpa, io, ws, null);
    defer guard.deinit(gpa);
    try std.testing.expectError(
        error.OutsideWorkspace,
        guard.checkExisting(io, ws, "escape_file"),
    );

    // Outside file is intact.
    const outside = try parent.dir.readFileAlloc(io, "outside/secret.txt", gpa, .limited(64));
    defer gpa.free(outside);
    try std.testing.expectEqualStrings("OUTSIDE\n", outside);
}

test "core-policy-ownership-001: remember alias still re-enters Guard" {
    // A remembered approval for one path must not bypass the Guard for an alias
    // that resolves outside the workspace. The Guard is a separate gate.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.createDirPath(io, "outside");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/keep.txt", .data = "outside-original\n" });
    var ws = try parent.dir.openDir(io, "ws", .{ .access_sub_paths = true });
    defer ws.close(io);
    try ws.symLink(io, "../outside/keep.txt", "escape_file", .{});

    var store = permissions.Remember.init(gpa, true);
    defer store.deinit();
    var allow_count: u32 = 0;
    const Ctx = struct {
        fn ask(ptr: ?*anyopaque, _: tool.ToolDescriptor, _: []const u8) permissions.Decision {
            const c: *u32 = @ptrCast(@alignCast(ptr.?));
            c.* += 1;
            return .allow;
        }
    };
    var gate = permissions.Gate.ask(Ctx.ask, &allow_count);
    gate.remember = &store;
    const descriptor = permissions.testDescriptor("write_file", .write);
    var guard = try workspace.guardFrom(gpa, io, ws, null);
    defer guard.deinit(gpa);

    // First call: allowed but not remembered.
    const approved = gate.check(descriptor, "{}", "escape_file");
    try std.testing.expect(approved.decision == .allow and !approved.remembered);
    // Guard still denies even though policy allowed.
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "escape_file"));

    // Second call: remembered (policy allows), but Guard still denies.
    const remembered = gate.check(descriptor, "{}", "escape_file");
    try std.testing.expect(remembered.decision == .allow and remembered.remembered);
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "escape_file"));

    // Lexical alias re-prompts at policy AND still fails Guard.
    const alias = gate.check(descriptor, "{}", "./escape_file");
    try std.testing.expect(alias.decision == .allow and !alias.remembered);
    try std.testing.expectEqual(@as(u32, 2), allow_count);
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "./escape_file"));
}

// ── harness-events-001: public LifecycleObserver product adapter ────────────
//
// Records the full public callback sequence with owned copies of borrowed
// slices. Proves start/terminal invariants, Tool correlation (including
// end-only pending cancel), soft-result paths, and terminal error mapping.

const LifecycleKind = enum {
    run_start,
    assistant_message,
    assistant_delta,
    thinking_delta,
    assistant_delta_clear,
    tool_start,
    tool_end,
    control_applied,
    run_terminal,
};

const OwnedLifecycleEvent = struct {
    kind: LifecycleKind,
    session_configured: bool = false,
    turn: u32 = 0,
    call_index: u32 = 0,
    text: ?[]u8 = null,
    has_tools: bool = false,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: ?[]u8 = null,
    body: ?[]u8 = null,
    reasoning: ?[]u8 = null,
    control_kind: ?lifecycle_mod.ControlKind = null,
    next_turn: u32 = 0,
    turns: u32 = 0,
    ok: bool = false,
    stop_reason: loop.StopReason = .completed,
    usage: message.Usage = .{},

    fn deinit(self: *OwnedLifecycleEvent, gpa: std.mem.Allocator) void {
        if (self.text) |s| gpa.free(s);
        if (self.id) |s| gpa.free(s);
        if (self.name) |s| gpa.free(s);
        if (self.arguments) |s| gpa.free(s);
        if (self.body) |s| gpa.free(s);
        if (self.reasoning) |s| gpa.free(s);
        self.* = .{ .kind = self.kind };
    }
};

const LifecycleRecorder = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayListUnmanaged(OwnedLifecycleEvent) = .empty,
    /// True when a callback arrives outside an open run (after terminal without a
    /// new start, or terminal when not open). Multi-reply: start after terminal is OK.
    after_terminal: bool = false,
    terminal_count: u32 = 0,
    /// Facade-open mirror: true between run_start and run_terminal.
    open: bool = false,

    fn init(gpa: std.mem.Allocator) LifecycleRecorder {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *LifecycleRecorder) void {
        for (self.events.items) |*e| e.deinit(self.gpa);
        self.events.deinit(self.gpa);
    }

    fn observer(self: *LifecycleRecorder) lifecycle_mod.LifecycleObserver {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    fn onEvent(ptr: ?*anyopaque, event: lifecycle_mod.LifecycleEvent) void {
        const self: *LifecycleRecorder = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .run_start => {
                // A start while still open would be a duplicate/re-entry bug.
                if (self.open) self.after_terminal = true;
                self.open = true;
            },
            .run_terminal => {
                if (!self.open) self.after_terminal = true;
                self.open = false;
            },
            else => {
                // Non-terminal events after a closed run (no callback after terminal).
                if (!self.open) self.after_terminal = true;
            },
        }
        var owned: OwnedLifecycleEvent = switch (event) {
            .run_start => |rs| .{
                .kind = .run_start,
                .session_configured = rs.session_configured,
            },
            .assistant_message => |am| blk: {
                const text = self.gpa.dupe(u8, am.text) catch return;
                const reasoning = if (am.reasoning) |r|
                    self.gpa.dupe(u8, r) catch {
                        self.gpa.free(text);
                        return;
                    }
                else
                    null;
                break :blk .{
                    .kind = .assistant_message,
                    .turn = am.turn,
                    .text = text,
                    .has_tools = am.has_tools,
                    .reasoning = reasoning,
                };
            },
            .assistant_delta => |d| blk: {
                const text = self.gpa.dupe(u8, d) catch return;
                break :blk .{
                    .kind = .assistant_delta,
                    .text = text,
                };
            },
            .thinking_delta => |d| blk: {
                // Recorder owns an independent copy (tui-thinking-streaming-001);
                // freed by OwnedLifecycleEvent.deinit like every other payload.
                const text = self.gpa.dupe(u8, d) catch return;
                break :blk .{
                    .kind = .thinking_delta,
                    .text = text,
                };
            },
            .assistant_delta_clear => .{ .kind = .assistant_delta_clear },
            .tool_start => |ts| blk: {
                const id = self.gpa.dupe(u8, ts.id) catch return;
                const name = self.gpa.dupe(u8, ts.name) catch {
                    self.gpa.free(id);
                    return;
                };
                const arguments = self.gpa.dupe(u8, ts.arguments) catch {
                    self.gpa.free(id);
                    self.gpa.free(name);
                    return;
                };
                break :blk .{
                    .kind = .tool_start,
                    .turn = ts.turn,
                    .call_index = ts.call_index,
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
            },
            .tool_end => |te| blk: {
                const id = self.gpa.dupe(u8, te.id) catch return;
                const name = self.gpa.dupe(u8, te.name) catch {
                    self.gpa.free(id);
                    return;
                };
                const body = self.gpa.dupe(u8, te.body) catch {
                    self.gpa.free(id);
                    self.gpa.free(name);
                    return;
                };
                break :blk .{
                    .kind = .tool_end,
                    .turn = te.turn,
                    .call_index = te.call_index,
                    .id = id,
                    .name = name,
                    .body = body,
                };
            },
            .control_applied => |c| blk: {
                const text = self.gpa.dupe(u8, c.text) catch return;
                break :blk .{
                    .kind = .control_applied,
                    .control_kind = c.kind,
                    .next_turn = c.next_turn,
                    .text = text,
                };
            },
            .run_terminal => |rt| .{
                .kind = .run_terminal,
                .turns = rt.turns,
                .ok = rt.ok,
                .stop_reason = rt.stop_reason,
                .usage = rt.usage,
            },
        };
        if (event == .run_terminal) self.terminal_count += 1;
        self.events.append(self.gpa, owned) catch {
            owned.deinit(self.gpa);
        };
    }

    fn firstTerminal(self: *const LifecycleRecorder) ?OwnedLifecycleEvent {
        for (self.events.items) |e| {
            if (e.kind == .run_terminal) return e;
        }
        return null;
    }

    fn countKind(self: *const LifecycleRecorder, kind: LifecycleKind) u32 {
        var n: u32 = 0;
        for (self.events.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }

    /// Find the first tool_end with the given id (owned copy).
    fn toolEndById(self: *const LifecycleRecorder, id: []const u8) ?OwnedLifecycleEvent {
        for (self.events.items) |e| {
            if (e.kind == .tool_end and e.id != null and std.mem.eql(u8, e.id.?, id)) return e;
        }
        return null;
    }

    fn toolStartById(self: *const LifecycleRecorder, id: []const u8) ?OwnedLifecycleEvent {
        for (self.events.items) |e| {
            if (e.kind == .tool_start and e.id != null and std.mem.eql(u8, e.id.?, id)) return e;
        }
        return null;
    }
};

fn expectKindSequence(rec: *const LifecycleRecorder, expected: []const LifecycleKind) !void {
    try std.testing.expectEqual(expected.len, rec.events.items.len);
    for (expected, rec.events.items) |want, got| {
        try std.testing.expectEqual(want, got.kind);
    }
}

test "harness-events: completed run_start → assistant → run_terminal(completed)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text_with_usage };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try expectKindSequence(&rec, &.{ .run_start, .assistant_message, .run_terminal });
    try std.testing.expect(!rec.events.items[0].session_configured);
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[1].turn);
    try std.testing.expectEqualStrings("done", rec.events.items[1].text.?);
    try std.testing.expect(!rec.events.items[1].has_tools);
    const term = rec.firstTerminal().?;
    try std.testing.expect(term.ok);
    try std.testing.expectEqual(loop.StopReason.completed, term.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), term.turns);
    try std.testing.expectEqual(@as(u32, 10), term.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 5), term.usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 15), term.usage.total_tokens);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);
    try std.testing.expect(!agent.lifecycle_run_open);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "completed");
    try std.testing.expectEqual(@as(u32, 1), tr.terminal_count);
}

test "harness-events: tool start/end correlation + soft permission deny" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    const Stub = struct {
        ran: bool = false,
        fn h(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.ran = true;
            return error.ToolFailed;
        }
    };
    var stub: Stub = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{
                .name = "write_file",
                .description = "write",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .capabilities = .{
                .risk = .write,
                .workspace = .{ .path_field = "path" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = &stub,
        .handler = Stub.h,
    }};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "deny-1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"x.txt\",\"content\":\"y\"}"),
                };
                return .{
                    .content = try arena.dupe(u8, "calling"),
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = try arena.dupe(u8, "soft-done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        // Default product policy surface: ask mode + deny gate (no stdin HITL).
        .permission_mode = .ask,
        .permission_gate = permissions.Gate.denyAllDangerous(),
        .verbose = false,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();
    agent.test_tools = &tools;
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "write");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expect(!stub.ran);

    try expectKindSequence(&rec, &.{
        .run_start,
        .assistant_message,
        .tool_start,
        .tool_end,
        .assistant_message,
        .run_terminal,
    });
    try std.testing.expect(rec.events.items[1].has_tools);
    try std.testing.expectEqualStrings("calling", rec.events.items[1].text.?);
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[2].turn);
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[2].call_index);
    try std.testing.expectEqualStrings("deny-1", rec.events.items[2].id.?);
    try std.testing.expectEqualStrings("write_file", rec.events.items[2].name.?);
    try std.testing.expectEqualStrings("{\"path\":\"x.txt\",\"content\":\"y\"}", rec.events.items[2].arguments.?);
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[3].call_index);
    try std.testing.expectEqualStrings("deny-1", rec.events.items[3].id.?);
    try std.testing.expectEqualStrings("write_file", rec.events.items[3].name.?);
    try std.testing.expect(core.tool_error.hasCode(rec.events.items[3].body.?, .permission_denied));
    try std.testing.expect(!rec.events.items[4].has_tools);
    try std.testing.expectEqualStrings("soft-done", rec.events.items[4].text.?);
    const term = rec.firstTerminal().?;
    try std.testing.expect(term.ok);
    try std.testing.expectEqual(loop.StopReason.completed, term.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "completed");
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_result"));
}

test "harness-events: cancel end-only pending tools preserve program-order index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var first_ran: u32 = 0;
    var second_ran: u32 = 0;
    var third_ran: u32 = 0;

    const Mock = struct {
        step: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 3);
                tc[0] = .{
                    .id = try arena.dupe(u8, "lc-1"),
                    .name = try arena.dupe(u8, "first_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "lc-2"),
                    .name = try arena.dupe(u8, "second_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                tc[2] = .{
                    .id = try arena.dupe(u8, "lc-3"),
                    .name = try arena.dupe(u8, "third_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{ .content = "batch", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "unexpected"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    var first_state: BetweenCancelFirst = .{ .cancel = &agent.cancel, .ran = &first_ran };
    var second_state: BetweenCancelPending = .{ .ran = &second_ran, .label = "second" };
    var third_state: BetweenCancelPending = .{ .ran = &third_ran, .label = "third" };
    const tools = [_]tool.Tool{
        .{
            .descriptor = .{
                .definition = .{ .name = "first_tool", .description = "", .parameters_json = "{\"type\":\"object\"}" },
                .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
            },
            .instance = &first_state,
            .handler = BetweenCancelFirst.handle,
        },
        .{
            .descriptor = .{
                .definition = .{ .name = "second_tool", .description = "", .parameters_json = "{\"type\":\"object\"}" },
                .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
            },
            .instance = &second_state,
            .handler = BetweenCancelPending.handle,
        },
        .{
            .descriptor = .{
                .definition = .{ .name = "third_tool", .description = "", .parameters_json = "{\"type\":\"object\"}" },
                .capabilities = .{ .risk = .read, .workspace = .none, .cancellation = .none, .shell = .none },
            },
            .instance = &third_state,
            .handler = BetweenCancelPending.handle,
        },
    };
    agent.test_tools = &tools;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "multi");
    try std.testing.expectEqual(loop.StopReason.cancelled, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), first_ran);
    try std.testing.expectEqual(@as(u32, 0), second_ran);
    try std.testing.expectEqual(@as(u32, 0), third_ran);

    // run_start, assistant(has_tools), tool_start/end for first, end-only for 2+3, terminal.
    try expectKindSequence(&rec, &.{
        .run_start,
        .assistant_message,
        .tool_start,
        .tool_end,
        .tool_end,
        .tool_end,
        .run_terminal,
    });
    try std.testing.expect(rec.events.items[1].has_tools);
    // Ordinary first call: start+end at index 0.
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[2].call_index);
    try std.testing.expectEqualStrings("lc-1", rec.events.items[2].id.?);
    try std.testing.expectEqual(@as(u32, 0), rec.events.items[3].call_index);
    try std.testing.expectEqualStrings("lc-1", rec.events.items[3].id.?);
    try std.testing.expectEqualStrings("first-handler-done", rec.events.items[3].body.?);
    // Pending cancel end-only at program-order indices 1 and 2 — no fabricated starts.
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[4].call_index);
    try std.testing.expectEqualStrings("lc-2", rec.events.items[4].id.?);
    try std.testing.expect(core.tool_error.hasCode(rec.events.items[4].body.?, .cancelled));
    try std.testing.expectEqual(@as(u32, 2), rec.events.items[5].call_index);
    try std.testing.expectEqualStrings("lc-3", rec.events.items[5].id.?);
    try std.testing.expect(core.tool_error.hasCode(rec.events.items[5].body.?, .cancelled));
    const term = rec.firstTerminal().?;
    try std.testing.expect(term.ok); // cancelled is ok=true (cooperative)
    try std.testing.expectEqual(loop.StopReason.cancelled, term.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try expectRunEnd(tr, true, "cancelled");
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
    try std.testing.expectEqual(@as(u32, 3), tr.countKind("tool_result"));
}

test "harness-events: preflight failure emits no lifecycle events" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .trace_path = "/tmp/zag-lifecycle-absolute.jsonl",
        .lifecycle = rec.observer(),
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
    try std.testing.expectEqual(@as(usize, 0), rec.events.items.len);
    try std.testing.expectEqual(@as(u32, 0), rec.terminal_count);
    try std.testing.expect(!agent.lifecycle_run_open);
}

test "harness-events: provider/session/timeout/unsupported terminals are exact-one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // provider_error
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .provider_fail };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .chat_retries = 0,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        try std.testing.expectError(error.ProviderFailed, agent.reply(&session, "hi"));
        try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
        try std.testing.expect(!rec.firstTerminal().?.ok);
        try std.testing.expectEqual(loop.StopReason.provider_error, rec.firstTerminal().?.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
        try std.testing.expect(!rec.after_terminal);
        try expectRunEnd(&(agent.trace.?), false, "provider_error");
    }

    // timeout (Result path, ok=false)
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        const Mock = struct {
            calls: *u32,
            fn chat(
                ptr: *anyopaque,
                _: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
                _: ?*?u64,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.calls.* += 1;
                return error.Timeout;
            }
        };
        var calls: u32 = 0;
        var mock: Mock = .{ .calls = &calls };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        }, .{
            .permission_mode = .yolo,
            .verbose = false,
            .chat_retries = 2,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        const result = try agent.reply(&session, "hi");
        try std.testing.expectEqual(loop.StopReason.timeout, result.stop_reason);
        try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
        try std.testing.expect(!rec.firstTerminal().?.ok);
        try std.testing.expectEqual(loop.StopReason.timeout, rec.firstTerminal().?.stop_reason);
        try expectRunEnd(&(agent.trace.?), false, "timeout");
    }

    // unsupported_control
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        const Mock = struct {
            calls: *u32,
            fn chat(
                ptr: *anyopaque,
                _: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
                _: ?*?u64,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.calls.* += 1;
                return error.UnsupportedControl;
            }
        };
        var calls: u32 = 0;
        var mock: Mock = .{ .calls = &calls };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        }, .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        const result = try agent.reply(&session, "hi");
        try std.testing.expectEqual(loop.StopReason.unsupported_control, result.stop_reason);
        try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
        try std.testing.expect(!rec.firstTerminal().?.ok);
        try std.testing.expectEqual(loop.StopReason.unsupported_control, rec.firstTerminal().?.stop_reason);
        try expectRunEnd(&(agent.trace.?), false, "unsupported_control");
    }

    // session_error (save fail after successful loop)
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        const dir_name = ".zag-test-lifecycle-session-err";
        const path = ".zag-test-lifecycle-session-err/s.jsonl";
        Io.Dir.cwd().createDirPath(io, dir_name) catch {};
        defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = rec.observer(),
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
        // Seed a successful first save so the writer exists, then force replace fail.
        const writer = if (session.writer) |*w| w else return error.TestUnexpectedResult;
        session_store.testing.setFailBeforeReplace(writer, true);

        try std.testing.expectError(error.IoFailed, agent.reply(&session, "hi"));
        try std.testing.expect(rec.events.items.len >= 2);
        try std.testing.expectEqual(LifecycleKind.run_start, rec.events.items[0].kind);
        try std.testing.expect(rec.events.items[0].session_configured);
        const term = rec.firstTerminal().?;
        try std.testing.expect(!term.ok);
        try std.testing.expectEqual(loop.StopReason.session_error, term.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
        try std.testing.expect(!rec.after_terminal);
        try expectRunEnd(&(agent.trace.?), false, "session_error");
    }
}

test "tui-streaming: facade forwards deltas observer-first, clear before retry deltas" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Streaming provider: attempt 1 streams 2 deltas then fails (retryable);
    // attempt 2 streams 1 delta then completes.
    const StreamMock = struct {
        attempts: u32 = 0,
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "final"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chatStream(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            if (self.attempts == 1) {
                handler(handler_ctx, "part1", null);
                handler(handler_ctx, " part2", null);
                return error.RateLimited;
            }
            handler(handler_ctx, "final", null);
            return .{
                .content = try arena.dupe(u8, "final"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    // Combined recorder: lowercase = observer fact, uppercase = lifecycle fact.
    // Proves per-fact order (observer first) and cross-fact order (clear
    // before attempt-2 deltas; complete message after all deltas).
    const Rec = struct {
        tags: [64]u8 = undefined,
        len: usize = 0,
        fn note(self: *@This(), tag: u8) void {
            if (self.len < self.tags.len) {
                self.tags[self.len] = tag;
                self.len += 1;
            }
        }
        fn count(self: *const @This(), tag: u8) u32 {
            var n: u32 = 0;
            for (self.tags[0..self.len]) |t| {
                if (t == tag) n += 1;
            }
            return n;
        }
        fn onObserver(ptr: ?*anyopaque, event: observer_mod.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .assistant_delta => self.note('d'),
                .assistant_delta_clear => self.note('c'),
                .assistant_text => self.note('m'),
                else => self.note('x'),
            }
        }
        fn onLifecycle(ptr: ?*anyopaque, event: lifecycle_mod.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .assistant_delta => self.note('D'),
                .assistant_delta_clear => self.note('C'),
                .assistant_message => self.note('M'),
                else => self.note('y'),
            }
        }
    };
    var rec: Rec = .{};

    var mock: StreamMock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = StreamMock.chat, .chat_stream = StreamMock.chatStream },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 1,
        .retry_base_delay_ms = 0,
        .observer = .{ .ptr = &rec, .on_event = Rec.onObserver },
        .lifecycle = .{ .ptr = &rec, .on_event = Rec.onLifecycle },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqualStrings("final", result.final_text);

    // run_start (lifecycle) → attempt-1 deltas (observer+lifecycle each) →
    // clear → attempt-2 delta → complete message → run_terminal. No delta
    // after the terminal message.
    try std.testing.expectEqualStrings("ydDdDcCdDmMy", rec.tags[0..rec.len]);
    try std.testing.expectEqual(@as(u32, 3), rec.count('D'));
    try std.testing.expectEqual(@as(u32, 1), rec.count('C'));
    try std.testing.expectEqual(@as(u32, 1), rec.count('M'));
    // Deltas never reach the durable Trace (UI-visible only).
    try std.testing.expectEqual(@as(u32, 1), agent.trace.?.countKind("assistant"));
}

test "tui-thinking-streaming: facade forwards thinking_delta to lifecycle only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ThinkStreamMock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            return .{
                .content = try arena.dupe(u8, "answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "chain of thought"),
            };
        }
        fn chatStream(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            handler: provider_mod.DeltaHandler,
            handler_ctx: *anyopaque,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            handler(handler_ctx, "", "chain");
            handler(handler_ctx, " of", null);
            handler(handler_ctx, "", " thought");
            return .{
                .content = try arena.dupe(u8, "answer"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .reasoning = try arena.dupe(u8, "chain of thought"),
            };
        }
    };

    const Rec = struct {
        tags: [64]u8 = undefined,
        len: usize = 0,
        fn note(self: *@This(), tag: u8) void {
            if (self.len < self.tags.len) {
                self.tags[self.len] = tag;
                self.len += 1;
            }
        }
        fn count(self: *const @This(), tag: u8) u32 {
            var n: u32 = 0;
            for (self.tags[0..self.len]) |t| {
                if (t == tag) n += 1;
            }
            return n;
        }
        fn onObserver(ptr: ?*anyopaque, event: observer_mod.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .assistant_delta => self.note('d'),
                .assistant_text => self.note('m'),
                else => self.note('x'),
            }
        }
        fn onLifecycle(ptr: ?*anyopaque, event: lifecycle_mod.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .thinking_delta => self.note('T'),
                .assistant_delta => self.note('D'),
                .assistant_message => self.note('M'),
                else => self.note('y'),
            }
        }
    };
    var rec: Rec = .{};

    var mock: ThinkStreamMock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = ThinkStreamMock.chat, .chat_stream = ThinkStreamMock.chatStream },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .observer = .{ .ptr = &rec, .on_event = Rec.onObserver },
        .lifecycle = .{ .ptr = &rec, .on_event = Rec.onLifecycle },
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqualStrings("answer", result.final_text);

    // run_start → thinking delta (lifecycle ONLY — observer gets no 't') →
    // content delta (observer+lifecycle) → thinking delta (lifecycle only) →
    // complete message (observer text + lifecycle) → run_terminal.
    try std.testing.expectEqualStrings("yTdDTmMy", rec.tags[0..rec.len]);
    try std.testing.expectEqual(@as(u32, 2), rec.count('T'));
    // Observer saw exactly the content delta + full text — byte-identical to
    // the pre-thinking stream surface (headless/CLI stdout unchanged).
    try std.testing.expectEqual(@as(u32, 0), rec.count('t'));
    try std.testing.expectEqual(@as(u32, 1), rec.count('d'));
    try std.testing.expectEqual(@as(u32, 1), rec.count('m'));
}

test "tui-thinking-streaming: lifecycle recorder owns thinking_delta text" {
    const gpa = std.testing.allocator;
    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    const obs = rec.observer();
    obs.emit(.{ .run_start = .{ .session_configured = false } });
    obs.emit(.{ .thinking_delta = "chain" });
    obs.emit(.{ .thinking_delta = " of thought" });
    obs.emit(.{ .assistant_message = .{ .turn = 1, .text = "answer", .has_tools = false, .reasoning = "chain of thought" } });
    obs.emit(.{ .run_terminal = .{ .turns = 1, .ok = true, .stop_reason = .completed, .usage = .{} } });

    try std.testing.expectEqual(@as(u32, 2), rec.countKind(.thinking_delta));
    // Independent owned copies (recorder memory, not the borrowed callback).
    try std.testing.expectEqualStrings("chain", rec.events.items[1].text.?);
    try std.testing.expectEqualStrings(" of thought", rec.events.items[2].text.?);
    try std.testing.expectEqualStrings("chain of thought", rec.events.items[3].reasoning.?);
    // deinit frees every owned payload without double-free (leak-checked by GPA).
}

test "harness-events: invalid_toolset + invalid_context post-start terminals" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // invalid_toolset
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
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
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        agent.test_tools = &tools;
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        try std.testing.expectError(error.InvalidToolset, agent.reply(&session, "hi"));
        try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
        try std.testing.expect(!rec.firstTerminal().?.ok);
        try std.testing.expectEqual(loop.StopReason.invalid_toolset, rec.firstTerminal().?.stop_reason);
        try std.testing.expectEqual(@as(u32, 0), calls);
        try expectRunEnd(&(agent.trace.?), false, "invalid_toolset");
    }

    // invalid_context
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
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
        try session.transcript.appendToolResult("a1", "partial");
        try std.testing.expectError(error.InvalidContext, agent.reply(&session, "continue"));
        try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
        try std.testing.expect(!rec.firstTerminal().?.ok);
        try std.testing.expectEqual(loop.StopReason.invalid_context, rec.firstTerminal().?.stop_reason);
        try std.testing.expectEqual(@as(u32, 0), calls);
        try expectRunEnd(&(agent.trace.?), false, "invalid_context");
    }
}

// F-2: Trace terminal commit I/O failure → public stop_reason=trace_error.
// OutOfMemory mapping for post-start terminals is covered by the noteCompaction
// OOM fixture below (and by stopReasonForTraceError); this test does not inject
// a Trace-terminal OOM fault (no reliable existing hook for terminal-only OOM).
test "harness-events: Trace terminal replace failure maps IO→trace_error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Durable Trace replace failure after successful provider → trace_error.
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        const dir_name = ".zag-test-lifecycle-trace-err";
        const path = ".zag-test-lifecycle-trace-err/run.jsonl";
        Io.Dir.cwd().createDirPath(io, dir_name) catch {};
        defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .trace_path = path,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        trace_mod.testing.setFailBeforeReplace(tr, true);

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();

        try std.testing.expectError(error.TraceIoFailed, agent.reply(&session, "hi"));
        try std.testing.expectEqual(LifecycleKind.run_start, rec.events.items[0].kind);
        const term = rec.firstTerminal().?;
        try std.testing.expect(!term.ok);
        try std.testing.expectEqual(loop.StopReason.trace_error, term.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
        try std.testing.expect(!rec.after_terminal);
        // Public lifecycle prefers Trace commit error over completed Result.
        try std.testing.expect(calls >= 1);
    }

    // Provider failure + Trace terminal replace failure still maps to trace_error.
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        const dir_name = ".zag-test-lifecycle-trace-err2";
        const path = ".zag-test-lifecycle-trace-err2/run.jsonl";
        Io.Dir.cwd().createDirPath(io, dir_name) catch {};
        defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .provider_fail };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .chat_retries = 0,
            .trace_path = path,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        trace_mod.testing.setFailBeforeReplace(tr, true);

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();

        try std.testing.expectError(error.TraceIoFailed, agent.reply(&session, "hi"));
        const term = rec.firstTerminal().?;
        try std.testing.expect(!term.ok);
        try std.testing.expectEqual(loop.StopReason.trace_error, term.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
        try std.testing.expect(!rec.after_terminal);
    }
}

test "harness-events: noteCompaction OOM maps to out_of_memory terminal exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .context = .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 1,
            .summary_max_chars = 400,
        },
        .lifecycle = rec.observer(),
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

    try std.testing.expectError(error.OutOfMemory, agent.reply(&session, "hi"));
    try std.testing.expectEqual(@as(u32, 0), calls);
    try expectKindSequence(&rec, &.{ .run_start, .run_terminal });
    try std.testing.expect(!rec.firstTerminal().?.ok);
    try std.testing.expectEqual(loop.StopReason.out_of_memory, rec.firstTerminal().?.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);
    try expectRunEnd(&(agent.trace.?), false, "out_of_memory");
}

test "harness-events: no lifecycle without observer; no duplicate terminal on two replies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Null observer is silent.
    {
        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = null,
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        const result = try agent.reply(&session, "hi");
        try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
        try std.testing.expect(!agent.lifecycle_run_open);
        try expectRunEnd(&(agent.trace.?), true, "completed");
    }

    // Two consecutive replies: each has exactly one start + one terminal.
    {
        var rec = LifecycleRecorder.init(gpa);
        defer rec.deinit();
        var calls: u32 = 0;
        var mock: MockChat = .{ .calls = &calls, .mode = .text };
        var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .verbose = false,
            .lifecycle = rec.observer(),
        });
        defer agent.deinit();
        agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
        });
        defer session.deinit();
        _ = try agent.reply(&session, "one");
        _ = try agent.reply(&session, "two");

        var starts: u32 = 0;
        var terminals: u32 = 0;
        for (rec.events.items) |e| {
            switch (e.kind) {
                .run_start => starts += 1,
                .run_terminal => terminals += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(u32, 2), starts);
        try std.testing.expectEqual(@as(u32, 2), terminals);
        try std.testing.expectEqual(@as(u32, 2), rec.terminal_count);
        try std.testing.expect(!rec.after_terminal);
        try std.testing.expect(!agent.lifecycle_run_open);
        // Trace buffer is per-reply (beginReply resets); latest has one terminal.
        try expectRunEnd(&(agent.trace.?), true, "completed");
    }
}

// F-1: no-Trace multi-turn provider failure — public turns must match source turn.
test "harness-events: no-Trace second-turn provider failure reports source turns" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    // Turn 1: complete tool batch (noop). Turn 2: provider hard-fail.
    // Without Trace, failRun must use RunBridge.current_turn (not 0).
    const Noop = struct {
        fn h(ctx: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return ctx.allocator.dupe(u8, "noop-ok") catch return error.OutOfMemory;
        }
    };
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{
                .name = "noop",
                .description = "",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .capabilities = .{
                .risk = .read,
                .workspace = .none,
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = null,
        .handler = Noop.h,
    }};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "t1"),
                    .name = try arena.dupe(u8, "noop"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{
                    .content = try arena.dupe(u8, "first-turn"),
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            // Second provider call fails after turn_start=2 has been emitted.
            return error.AuthenticationFailed;
        }
    };
    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .chat_retries = 0,
        .lifecycle = rec.observer(),
        // Explicitly no Trace (default null) — the F-1 regression surface.
        .trace_path = null,
    });
    defer agent.deinit();
    try std.testing.expect(agent.trace == null);
    agent.test_tools = &tools;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try std.testing.expectError(error.ProviderFailed, agent.reply(&session, "go"));
    try std.testing.expectEqual(@as(u32, 2), mock.calls);

    // Sequence: start → assistant(t1 tools) → tool_start/end → terminal (no second assistant).
    try expectKindSequence(&rec, &.{
        .run_start,
        .assistant_message,
        .tool_start,
        .tool_end,
        .run_terminal,
    });
    try std.testing.expect(rec.events.items[1].has_tools);
    try std.testing.expectEqualStrings("first-turn", rec.events.items[1].text.?);
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[1].turn);
    try std.testing.expectEqualStrings("t1", rec.events.items[2].id.?);
    try std.testing.expectEqualStrings("t1", rec.events.items[3].id.?);
    try std.testing.expectEqualStrings("noop-ok", rec.events.items[3].body.?);

    const term = rec.firstTerminal().?;
    try std.testing.expect(!term.ok);
    try std.testing.expectEqual(loop.StopReason.provider_error, term.stop_reason);
    // Source truth: turn 2 started before provider fail (bridge.current_turn=2).
    try std.testing.expectEqual(@as(u32, 2), term.turns);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);
    try std.testing.expect(!agent.lifecycle_run_open);
}

// F-3a: hard failure after tool_start must not fabricate tool_end.
test "harness-events: hard mid-tool OOM has tool_start without tool_end" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    const Boom = struct {
        fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            // Hard failure after Core already emitted tool_start; no soft body.
            return error.OutOfMemory;
        }
    };
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{
                .name = "boom",
                .description = "",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .capabilities = .{
                .risk = .read,
                .workspace = .none,
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = null,
        .handler = Boom.h,
    }};

    const Mock = struct {
        fn chat(
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const tc = try arena.alloc(message.ToolCall, 1);
            tc[0] = .{
                .id = try arena.dupe(u8, "boom-1"),
                .name = try arena.dupe(u8, "boom"),
                .arguments = try arena.dupe(u8, "{}"),
            };
            return .{
                .content = try arena.dupe(u8, "calling-boom"),
                .tool_calls = tc,
                .finish_reason = "tool_calls",
            };
        }
    };
    var mock_state: u8 = 0;
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock_state,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .lifecycle = rec.observer(),
        .trace_path = null,
    });
    defer agent.deinit();
    agent.test_tools = &tools;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try std.testing.expectError(error.OutOfMemory, agent.reply(&session, "boom"));
    try expectKindSequence(&rec, &.{
        .run_start,
        .assistant_message,
        .tool_start,
        .run_terminal,
    });
    try std.testing.expectEqual(@as(u32, 1), rec.countKind(.tool_start));
    try std.testing.expectEqual(@as(u32, 0), rec.countKind(.tool_end));
    try std.testing.expectEqualStrings("boom-1", rec.events.items[2].id.?);
    try std.testing.expectEqualStrings("boom", rec.events.items[2].name.?);
    const term = rec.firstTerminal().?;
    try std.testing.expect(!term.ok);
    try std.testing.expectEqual(loop.StopReason.out_of_memory, term.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), term.turns);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);
}

// F-3b: soft-result correlation matrix (unknown/invalid/jail/shell/handler) via one
// multi-tool turn + lifecycle recorder — reuses default product gates where possible.
test "harness-events: soft-result correlation unknown invalid jail shell handler" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    const HandlerFail = struct {
        fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            return error.ToolFailed;
        }
    };
    // Only the intentional handler-fail tool is registered; "unknown_x" is absent.
    // read_file is the product built-in for jail; run_shell is the product built-in
    // for shell deny under default protect. We use a tiny custom set so path/jail
    // and shell tools exist alongside the handler-fail tool.
    const tools = [_]tool.Tool{
        .{
            .descriptor = .{
                .definition = .{
                    .name = "read_file",
                    .description = "jail target",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .{ .path_field = "path" },
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = null,
            .handler = struct {
                fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                    return error.ToolFailed; // must not run (jail denies first)
                }
            }.h,
        },
        .{
            .descriptor = .{
                .definition = .{
                    .name = "run_shell",
                    .description = "shell target",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .execute,
                    .workspace = .none,
                    .cancellation = .none,
                    .shell = .command_argument,
                },
            },
            .instance = null,
            .handler = struct {
                fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                    return error.ToolFailed; // must not run (shell denies first)
                }
            }.h,
        },
        .{
            .descriptor = .{
                .definition = .{
                    .name = "fail_tool",
                    .description = "handler soft-fail",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .none,
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = null,
            .handler = HandlerFail.h,
        },
        .{
            .descriptor = .{
                .definition = .{
                    .name = "path_tool",
                    .description = "invalid-args target",
                    .parameters_json = "{\"type\":\"object\"}",
                },
                .capabilities = .{
                    .risk = .read,
                    .workspace = .{ .path_field = "path" },
                    .cancellation = .none,
                    .shell = .none,
                },
            },
            .instance = null,
            .handler = struct {
                fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                    return error.ToolFailed;
                }
            }.h,
        },
    };

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 5);
                // unknown tool (not in toolset)
                tc[0] = .{
                    .id = try arena.dupe(u8, "soft-unknown"),
                    .name = try arena.dupe(u8, "unknown_x"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                // invalid arguments (path_field tool, missing path)
                tc[1] = .{
                    .id = try arena.dupe(u8, "soft-invalid"),
                    .name = try arena.dupe(u8, "path_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                // jail deny (absolute path outside workspace)
                tc[2] = .{
                    .id = try arena.dupe(u8, "soft-jail"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"/tmp/outside-jail\"}"),
                };
                // shell deny under default protect
                tc[3] = .{
                    .id = try arena.dupe(u8, "soft-shell"),
                    .name = try arena.dupe(u8, "run_shell"),
                    .arguments = try arena.dupe(u8, "{\"command\":\"rm -rf /\"}"),
                };
                // handler soft-fail
                tc[4] = .{
                    .id = try arena.dupe(u8, "soft-handler"),
                    .name = try arena.dupe(u8, "fail_tool"),
                    .arguments = try arena.dupe(u8, "{}"),
                };
                return .{
                    .content = try arena.dupe(u8, "soft-batch"),
                    .tool_calls = tc,
                    .finish_reason = "tool_calls",
                };
            }
            return .{
                .content = try arena.dupe(u8, "soft-done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        // yolo for permission; jail + shell protect still apply (product defaults).
        .permission_mode = .yolo,
        .shell_policy = .protect,
        .verbose = false,
        .lifecycle = rec.observer(),
        .trace_path = null,
    });
    defer agent.deinit();
    agent.test_tools = &tools;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const result = try agent.reply(&session, "soft matrix");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), mock.calls);

    // 5 soft tools: each has start→end at program-order indices 0..4.
    try std.testing.expectEqual(@as(u32, 5), rec.countKind(.tool_start));
    try std.testing.expectEqual(@as(u32, 5), rec.countKind(.tool_end));
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expect(!rec.after_terminal);

    const pairs = [_]struct {
        id: []const u8,
        name: []const u8,
        index: u32,
        code: core.tool_error.Code,
    }{
        .{ .id = "soft-unknown", .name = "unknown_x", .index = 0, .code = .unknown_tool },
        .{ .id = "soft-invalid", .name = "path_tool", .index = 1, .code = .invalid_arguments },
        .{ .id = "soft-jail", .name = "read_file", .index = 2, .code = .jail_deny },
        .{ .id = "soft-shell", .name = "run_shell", .index = 3, .code = .shell_deny },
        .{ .id = "soft-handler", .name = "fail_tool", .index = 4, .code = .tool_failed },
    };
    for (pairs) |p| {
        const start = rec.toolStartById(p.id) orelse return error.TestUnexpectedResult;
        const end = rec.toolEndById(p.id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(p.index, start.call_index);
        try std.testing.expectEqual(p.index, end.call_index);
        try std.testing.expectEqualStrings(p.name, start.name.?);
        try std.testing.expectEqualStrings(p.name, end.name.?);
        try std.testing.expectEqualStrings(p.id, end.id.?);
        try std.testing.expect(core.tool_error.hasCode(end.body.?, p.code));
    }

    const term = rec.firstTerminal().?;
    try std.testing.expect(term.ok);
    try std.testing.expectEqual(loop.StopReason.completed, term.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), term.turns);
}

// ── harness-steering-001 product fixtures ───────────────────────────────────

test "harness-steering: Session A queue not consumed by Session B" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session_a = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session_a.deinit();
    var session_b = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session_b.deinit();

    try session_a.enqueueSteering("only-a");
    try std.testing.expectEqual(@as(usize, 1), session_a.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), session_b.steeringPending());

    // reply on B must not consume A's queue.
    _ = try agent.reply(&session_b, "hi-b");
    try std.testing.expectEqual(@as(usize, 1), session_a.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), session_b.steeringPending());

    _ = try agent.reply(&session_a, "hi-a");
    try std.testing.expectEqual(@as(usize, 0), session_a.steeringPending());
}

test "harness-steering: follow-up continues same run one terminal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try session.enqueueFollowUp("more-please");
    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u32, 1), rec.terminal_count);
    try std.testing.expectEqual(@as(u32, 1), rec.countKind(.control_applied));
    try std.testing.expectEqual(@as(usize, 0), session.followUpPending());
    // Ordering: run_start, control_applied (would-complete after turn1? actually
    // follow-up only at would-complete after turn 1), so: start, assistant, control, assistant, terminal.
    try expectKindSequence(&rec, &.{
        .run_start,
        .assistant_message,
        .control_applied,
        .assistant_message,
        .run_terminal,
    });
    try std.testing.expectEqual(lifecycle_mod.ControlKind.follow_up, rec.events.items[2].control_kind.?);
    try std.testing.expectEqual(@as(u32, 2), rec.events.items[2].next_turn);
}

test "harness-steering: pre-turn steering after explicit user before turn 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try session.enqueueSteering("steer-now");
    const result = try agent.reply(&session, "explicit-user");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    // Pre-turn applies before turn 1; would-complete empty after text → completed in 1 turn.
    try std.testing.expectEqual(@as(u32, 1), result.turns);
    try std.testing.expectEqual(@as(u32, 1), rec.countKind(.control_applied));
    try std.testing.expectEqual(@as(u32, 1), rec.events.items[1].next_turn);
    // Transcript order: system, explicit user, steering user, assistant.
    var saw_explicit = false;
    var saw_steer = false;
    for (session.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, "explicit-user")) saw_explicit = true;
        if (m.role == .user and std.mem.eql(u8, m.content, "steer-now")) {
            try std.testing.expect(saw_explicit);
            saw_steer = true;
        }
    }
    try std.testing.expect(saw_steer);
}

test "harness-steering: cancel retains unapplied; later reply consumes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try session.enqueueSteering("retained");
    agent.cancel.request();
    const cancelled = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.cancelled, cancelled.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());

    // Next reply clears cancel via defer and applies retained steering.
    const done = try agent.reply(&session, "again");
    try std.testing.expectEqual(loop.StopReason.completed, done.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), session.steeringPending());
}

test "harness-steering: clearControlQueues idle drop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try session.enqueueSteering("a");
    try session.enqueueFollowUp("b");
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), session.followUpPending());
    session.clearControlQueues();
    try std.testing.expectEqual(@as(usize, 0), session.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), session.followUpPending());
}

test "harness-steering: applied user saves; pending not serialized" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-steer-session";
    const path = ".zag-test-steer-session/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    var calls: u32 = 0;
    var mock: MockChat = .{ .calls = &calls, .mode = .text };
    var agent = try Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();

        try session.enqueueSteering("applied-row");
        try session.enqueueFollowUp("still-pending");
        // max_turns=1 would retain follow-up at would-complete; use 1 turn then leave follow-up.
        // With default max_turns, both would drain. Cap at 1 so follow-up stays pending.
        agent.options.max_turns = 1;
        const result = try agent.reply(&session, "explicit");
        // Pre-turn applied steering; turn 1 text; would-complete peeks follow-up but no room.
        try std.testing.expectEqual(loop.StopReason.max_turns, result.stop_reason);
        try std.testing.expectEqual(@as(usize, 0), session.steeringPending());
        try std.testing.expectEqual(@as(usize, 1), session.followUpPending());
    }

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "applied-row") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "still-pending") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "steeringPending") == null);

    // Resume starts with empty queues; applied row present in transcript.
    var resumed = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .resume_existing,
        .load_project_instructions = false,
    });
    defer resumed.deinit();
    try std.testing.expectEqual(@as(usize, 0), resumed.steeringPending());
    try std.testing.expectEqual(@as(usize, 0), resumed.followUpPending());
    var found = false;
    for (resumed.transcript.items()) |m| {
        if (m.role == .user and std.mem.eql(u8, m.content, "applied-row")) found = true;
    }
    try std.testing.expect(found);
}

test "harness-steering: foreign-thread enqueue during reply is observed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const Barrier = struct {
        in_chat: std.atomic.Value(bool) = .init(false),
        enqueued: std.atomic.Value(bool) = .init(false),

        fn waitTrue(flag: *std.atomic.Value(bool)) void {
            while (!flag.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    };

    const Mock = struct {
        barrier: *Barrier,
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                self.barrier.in_chat.store(true, .release);
                Barrier.waitTrue(&self.barrier.enqueued);
                return .{
                    .content = try arena.dupe(u8, "first"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            return .{
                .content = try arena.dupe(u8, "after-follow"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var barrier: Barrier = .{};
    var mock: Mock = .{ .barrier = &barrier };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var agent = try Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    const Worker = struct {
        session: *Session,
        barrier: *Barrier,
        fn run(self: *@This()) void {
            Barrier.waitTrue(&self.barrier.in_chat);
            self.session.enqueueFollowUp("from-thread") catch {};
            _ = self.session.followUpPending();
            self.barrier.enqueued.store(true, .release);
        }
    };
    var worker: Worker = .{ .session = &session, .barrier = &barrier };
    const thr = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer thr.join();

    const result = try agent.reply(&session, "hi");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(usize, 0), session.followUpPending());
}

test "harness-steering: Session start preallocation OOM before create file" {
    const io = std.testing.io;
    const dir_name = ".zag-test-steer-oom";
    const path = ".zag-test-steer-oom/s.jsonl";
    Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    // Fail on first allocation of queue backing.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const err = Session.start(failing.allocator(), io, .{
        .base_system = "sys",
        .path = path,
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    try std.testing.expectError(error.OutOfMemory, err);

    // File must not exist (no create/lease).
    const access = Io.Dir.cwd().access(io, path, .{});
    try std.testing.expectError(error.FileNotFound, access);
}

test "harness-steering: mid-batch product path steered body + lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rec = LifecycleRecorder.init(gpa);
    defer rec.deinit();

    const State = struct { n: u32 = 0 };
    const Stub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{ .name = "read_file", .description = "", .parameters_json = "{\"type\":\"object\"}" },
            .capabilities = .{
                .risk = .read,
                .workspace = .{ .path_field = "path" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = &state,
        .handler = Stub.h,
    }};

    const Mock = struct {
        calls: u32 = 0,
        session: *Session,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                // Enqueue during provider so pre-turn cannot consume; first between_tools
                // still peeks before Tool 1 — so both tools would be steered. Push after
                // first tool by using a delayed approach: enqueue only steering that
                // appears after tool1 if we enqueue mid-handler... simpler: accept both
                // steered if queued before tools, OR enqueue in tool handler after n=1.
                const tc = try arena.alloc(message.ToolCall, 2);
                tc[0] = .{
                    .id = try arena.dupe(u8, "c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"a.txt\"}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "c2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"b.txt\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    // Enqueue from tool handler after first execution to hit mid-batch before tool 2.
    const EnqueueStub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *struct { n: u32, session: *Session } = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            if (s.n == 1) {
                s.session.enqueueSteering("mid-product") catch {};
            }
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };
    var enq_state: struct { n: u32, session: *Session } = .{ .n = 0, .session = undefined };
    const enq_tools = [_]tool.Tool{.{
        .descriptor = tools[0].descriptor,
        .instance = &enq_state,
        .handler = EnqueueStub.h,
    }};

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    enq_state.session = &session;

    var mock: Mock = .{ .session = &session };
    const provider = provider_mod.Provider{ .ptr = &mock, .vtable = &.{ .chat = Mock.chat } };
    var agent = try Agent.init(gpa, io, provider, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .toolset = &enq_tools,
        .lifecycle = rec.observer(),
    });
    defer agent.deinit();

    const result = try agent.reply(&session, "go");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), enq_state.n);
    try std.testing.expectEqual(@as(u32, 1), rec.countKind(.control_applied));

    const te2 = rec.toolEndById("c2").?;
    try std.testing.expectEqualStrings(core.tool_error.steered_body, te2.body.?);
    try std.testing.expect(rec.toolStartById("c2") == null);
    try std.testing.expect(rec.toolStartById("c1") != null);
    // Correlation: tool_end c2 has call_index 1.
    try std.testing.expectEqual(@as(u32, 1), te2.call_index);
}

test "harness-steering: Session idle value-move preserves queue then deinit" {
    // Idle Session may be value-moved; address must remain stable only while
    // reply/enqueue are in flight (unsupported active move is not claimed).
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    try session.enqueueSteering("moved-steer");
    try session.enqueueFollowUp("moved-follow");
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());

    var moved = session;
    session = undefined;

    try std.testing.expectEqual(@as(usize, 1), moved.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), moved.followUpPending());
    const item = moved.control_queues.peek(.would_complete).?;
    try std.testing.expectEqual(control_queue_mod.Kind.steering, item.kind);
    try std.testing.expectEqualStrings("moved-steer", item.text);
    moved.control_queues.commit(.steering);
    try std.testing.expectEqual(@as(usize, 0), moved.steeringPending());
    const follow = moved.control_queues.peek(.would_complete).?;
    try std.testing.expectEqual(control_queue_mod.Kind.follow_up, follow.kind);
    moved.control_queues.commit(.follow_up);
    try std.testing.expectEqual(@as(usize, 0), moved.followUpPending());
    moved.deinit();
}

test "harness-steering: Trace records steered tool_result; no control EventKind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // EventKind remains the Trace v1 twelve-kind set (no control_applied kind).
    try std.testing.expectEqual(@as(usize, 12), @typeInfo(trace_mod.EventKind).@"enum".fields.len);
    inline for (@typeInfo(trace_mod.EventKind).@"enum".fields) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "control_applied"));
        try std.testing.expect(!std.mem.eql(u8, f.name, "control"));
        try std.testing.expect(!std.mem.eql(u8, f.name, "steering"));
    }

    const EnqueueStub = struct {
        fn h(ctx: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *struct { n: u32, session: *Session } = @ptrCast(@alignCast(instance.?));
            s.n += 1;
            if (s.n == 1) {
                s.session.enqueueSteering("trace-mid-steer") catch {};
            }
            return ctx.allocator.dupe(u8, "ran") catch return error.OutOfMemory;
        }
    };
    var enq_state: struct { n: u32, session: *Session } = .{ .n = 0, .session = undefined };
    const enq_tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{ .name = "read_file", .description = "", .parameters_json = "{\"type\":\"object\"}" },
            .capabilities = .{
                .risk = .read,
                .workspace = .{ .path_field = "path" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = &enq_state,
        .handler = EnqueueStub.h,
    }};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                const tc = try arena.alloc(message.ToolCall, 2);
                tc[0] = .{
                    .id = try arena.dupe(u8, "tr-c1"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"a.txt\"}"),
                };
                tc[1] = .{
                    .id = try arena.dupe(u8, "tr-c2"),
                    .name = try arena.dupe(u8, "read_file"),
                    .arguments = try arena.dupe(u8, "{\"path\":\"b.txt\"}"),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "trace-done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    enq_state.session = &session;

    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .verbose = false,
        .max_turns = 4,
        .toolset = &enq_tools,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    const result = try agent.reply(&session, "go");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);

    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), tr.countKind("tool_result"));
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call")); // only executed c1
    // Parsed Trace bytes carry steered body; no new control kind lines.
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "code=steered") != null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"control_applied\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"control\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"steering\"") == null);
    try std.testing.expectEqual(@as(u32, 0), tr.countKind("control_applied"));
}

test "harness-steering: injected steering still hits ask-deny write gate" {
    // Injected control is ordinary user input; model-requested write still passes
    // product ToolPolicy (ask + deny gate) and never runs the handler.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const dir_name = ".zag-test-steer-ask-deny";
    const target = ".zag-test-steer-ask-deny/must-not-write.txt";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const State = struct { ran: bool = false };
    const WriteStub = struct {
        fn h(_: tool.Context, instance: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
            const s: *State = @ptrCast(@alignCast(instance.?));
            s.ran = true;
            return error.ToolFailed;
        }
    };
    var state: State = .{};
    const tools = [_]tool.Tool{.{
        .descriptor = .{
            .definition = .{
                .name = "write_file",
                .description = "",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .capabilities = .{
                .risk = .write,
                .workspace = .{ .path_field = "path" },
                .cancellation = .none,
                .shell = .none,
            },
        },
        .instance = &state,
        .handler = WriteStub.h,
    }};

    const Mock = struct {
        calls: u32 = 0,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            // After pre-turn steering, transcript must include injected user text.
            if (self.calls == 1) {
                var saw_steer = false;
                for (messages) |m| {
                    if (m.role == .user and std.mem.eql(u8, m.content, "please write")) saw_steer = true;
                }
                if (!saw_steer) return error.InvalidResponse;
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "steer-write-1"),
                    .name = try arena.dupe(u8, "write_file"),
                    .arguments = try arena.dupe(
                        u8,
                        "{\"path\":\".zag-test-steer-ask-deny/must-not-write.txt\",\"content\":\"NO\"}",
                    ),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "denied-ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };

    var mock: Mock = .{};
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .ask,
        .permission_gate = permissions.Gate.denyAllDangerous(),
        .verbose = false,
        .max_turns = 4,
        .toolset = &tools,
        .shell_policy = .protect,
    });
    defer agent.deinit();

    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();

    try session.enqueueSteering("please write");
    const result = try agent.reply(&session, "explicit");
    try std.testing.expectEqual(loop.StopReason.completed, result.stop_reason);
    try std.testing.expect(!state.ran);
    var denied = false;
    for (session.transcript.items()) |m| {
        if (m.role == .tool and tool_error.hasCode(m.content, .permission_denied)) denied = true;
    }
    try std.testing.expect(denied);
    try expectPathAbsent(io, target);
}

// ── edit-sharpness-001 Agent Options / lifetime (B7, §10.13) ────────────────

test "edit-sharp §10.13 Options ports root surface and custom toolset no auto-splice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Root re-exports exist (compile-time + runtime type check via usage).
    const auto = edit_tools.autoAcceptHunkReviewer();
    try std.testing.expect(auto.reviewFn(null, .{
        .path = "p",
        .expected_sha256 = "0" ** 64,
        .old_len = 0,
        .new_len = 0,
        .preview_text = "",
    }) == .accept);

    var verify_calls: u32 = 0;
    const Ver = struct {
        calls: *u32,
        fn verify(ptr: ?*anyopaque, path: []const u8) edit_tools.PostEditVerifyResult {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.calls.* += 1;
            _ = path;
            return .ok;
        }
    };
    var ver_state: Ver = .{ .calls = &verify_calls };
    const verifier: edit_tools.PostEditVerifier = .{
        .ptr = &ver_state,
        .verifyFn = Ver.verify,
    };

    // Default toolset: ports land in ApplyHunkState
    {
        var agent = try Agent.init(gpa, io, .{
            .ptr = undefined,
            .vtable = &.{ .chat = struct {
                fn c(_: *anyopaque, _: std.mem.Allocator, _: []const message.Message, _: []const tool.Definition, _: provider_mod.RequestControl, _: ?*?u64) provider_mod.ChatError!message.AssistantTurn {
                    return error.InvalidResponse;
                }
            }.c },
        }, .{
            .permission_mode = .yolo,
            .hunk_reviewer = auto,
            .post_edit_verifier = verifier,
            .max_turns = 1,
        });
        defer agent.deinit();
        try std.testing.expect(agent.apply_hunk_state.reviewer != null);
        try std.testing.expect(agent.apply_hunk_state.verifier != null);
        // Tool instance points at Agent-owned state
        var found_apply = false;
        for (agent.tools_storage.tools) |t| {
            if (std.mem.eql(u8, t.name(), "apply_hunk")) {
                found_apply = true;
                try std.testing.expect(t.instance == @as(?*anyopaque, @ptrCast(agent.apply_hunk_state)));
            }
        }
        try std.testing.expect(found_apply);
    }

    // Custom toolset: Options ports NOT auto-spliced into custom tools
    {
        const custom = [_]tool.Tool{tool.stateless(.{
            .definition = .{
                .name = "custom_ro",
                .description = "x",
                .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
            },
            .capabilities = .{
                .risk = .read,
                .workspace = .none,
                .cancellation = .none,
                .shell = .none,
            },
        }, struct {
            fn h(ctx: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                return ctx.allocator.dupe(u8, "ok") catch return error.OutOfMemory;
            }
        }.h)};
        var agent = try Agent.init(gpa, io, .{
            .ptr = undefined,
            .vtable = &.{ .chat = struct {
                fn c(_: *anyopaque, _: std.mem.Allocator, _: []const message.Message, _: []const tool.Definition, _: provider_mod.RequestControl, _: ?*?u64) provider_mod.ChatError!message.AssistantTurn {
                    return error.InvalidResponse;
                }
            }.c },
        }, .{
            .permission_mode = .yolo,
            .toolset = &custom,
            .hunk_reviewer = auto,
            .post_edit_verifier = verifier,
            .max_turns = 1,
        });
        defer agent.deinit();
        // effective toolset is custom only
        const ts = agent.effectiveToolset();
        try std.testing.expectEqual(@as(usize, 1), ts.tools.len);
        try std.testing.expectEqualStrings("custom_ro", ts.tools[0].name());
        try std.testing.expect(ts.tools[0].instance == null);
        // Options ports stored on ApplyHunkState but not spliced into custom tools
        try std.testing.expect(agent.apply_hunk_state.reviewer != null);
        try std.testing.expect(agent.apply_hunk_state.verifier != null);
    }
}

/// Build apply_hunk JSON args for Agent fixtures (cwd-relative path).
fn editSharpApplyArgs(
    gpa: std.mem.Allocator,
    path: []const u8,
    file_bytes: []const u8,
    old_s: []const u8,
    new_s: []const u8,
) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file_bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    const hexchars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hexchars[byte >> 4];
        hex[i * 2 + 1] = hexchars[byte & 0xf];
    }
    return std.fmt.allocPrint(
        gpa,
        "{{\"path\":{f},\"expected_sha256\":{f},\"old_string\":{f},\"new_string\":{f}}}",
        .{
            std.json.fmt(path, .{}),
            std.json.fmt(hex[0..], .{}),
            std.json.fmt(old_s, .{}),
            std.json.fmt(new_s, .{}),
        },
    );
}

const EditSharpReviewer = struct {
    decision: edit_tools.HunkReviewDecision,
    calls: u32 = 0,
    last_preview_had_marker: bool = false,

    fn asReviewer(self: *EditSharpReviewer) edit_tools.HunkReviewer {
        return .{ .ptr = self, .reviewFn = reviewFn };
    }

    fn reviewFn(ptr: ?*anyopaque, preview: edit_tools.HunkReviewPreview) edit_tools.HunkReviewDecision {
        const self: *EditSharpReviewer = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (std.mem.indexOf(u8, preview.preview_text, "...[preview_truncated]") != null or
            std.mem.indexOf(u8, preview.preview_text, "apply_hunk review") != null)
        {
            self.last_preview_had_marker = true;
        }
        return self.decision;
    }
};

const EditSharpVerifier = struct {
    result: edit_tools.PostEditVerifyResult = .ok,
    calls: u32 = 0,

    fn asVerifier(self: *EditSharpVerifier) edit_tools.PostEditVerifier {
        return .{ .ptr = self, .verifyFn = verifyFn };
    }

    fn verifyFn(ptr: ?*anyopaque, path: []const u8) edit_tools.PostEditVerifyResult {
        const self: *EditSharpVerifier = @ptrCast(@alignCast(ptr.?));
        _ = path;
        self.calls += 1;
        return self.result;
    }
};

test "edit-sharp §10.4 remember does not skip review; plan deny" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-edit-sharp-remember";
    const sess_path = ".zag-test-edit-sharp-remember/s.jsonl";
    const target = ".zag-test-edit-sharp-remember/t.txt";
    const original = "alpha OLD omega\n";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = original });

    const args = try editSharpApplyArgs(gpa, target, original, "OLD", "NEW");
    defer gpa.free(args);

    // A) remember allows write permission but reject reviewer still runs
    {
        var reviewer: EditSharpReviewer = .{ .decision = .reject };
        var verifier: EditSharpVerifier = .{};
        const Mock = struct {
            step: u32 = 0,
            args_json: []const u8,
            fn chat(
                ptr: *anyopaque,
                arena: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
                _: ?*?u64,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.step += 1;
                if (self.step == 1) {
                    const tc = try arena.alloc(message.ToolCall, 1);
                    tc[0] = .{
                        .id = try arena.dupe(u8, "edit-sharp-remember-1"),
                        .name = try arena.dupe(u8, "apply_hunk"),
                        .arguments = try arena.dupe(u8, self.args_json),
                    };
                    return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
                }
                return .{
                    .content = try arena.dupe(u8, "recovered-after-reject"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
        };
        var mock: Mock = .{ .args_json = args };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        }, .{
            .permission_mode = .ask,
            .permission_gate = permissions.Gate.denyAllDangerous(),
            .hunk_reviewer = reviewer.asReviewer(),
            .post_edit_verifier = verifier.asVerifier(),
            .max_turns = 4,
        });
        defer agent.deinit();
        // Lexical remember of write path: Gate allows without ask, but review must still run.
        agent.remember_store.rememberPath(target);

        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();
        const result = try agent.reply(&session, "apply remembered path");
        try std.testing.expectEqualStrings("recovered-after-reject", result.final_text);
        try std.testing.expect(reviewer.calls >= 1);
        try std.testing.expectEqual(@as(u32, 0), verifier.calls);
        const body = try expectPairedToolId(session.transcript.items(), "edit-sharp-remember-1");
        try std.testing.expect(std.mem.indexOf(u8, body, "code=rejected") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "format=edit-sharp-v1") != null);
        const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(original, after);
        try std.testing.expectEqual(@as(u32, 2), mock.step);
    }

    // B) plan session denies non-plan write path before handler (no review)
    {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = original });
        var reviewer: EditSharpReviewer = .{ .decision = .accept };
        const Mock = struct {
            step: u32 = 0,
            args_json: []const u8,
            fn chat(
                ptr: *anyopaque,
                arena: std.mem.Allocator,
                _: []const message.Message,
                _: []const tool.Definition,
                _: provider_mod.RequestControl,
                _: ?*?u64,
            ) provider_mod.ChatError!message.AssistantTurn {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.step += 1;
                if (self.step == 1) {
                    const tc = try arena.alloc(message.ToolCall, 1);
                    tc[0] = .{
                        .id = try arena.dupe(u8, "edit-sharp-plan-1"),
                        .name = try arena.dupe(u8, "apply_hunk"),
                        .arguments = try arena.dupe(u8, self.args_json),
                    };
                    return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
                }
                return .{
                    .content = try arena.dupe(u8, "plan-denied-recovered"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
        };
        var mock: Mock = .{ .args_json = args };
        var agent = try Agent.init(gpa, io, .{
            .ptr = &mock,
            .vtable = &.{ .chat = Mock.chat },
        }, .{
            .permission_mode = .yolo,
            .session_kind = .plan,
            .hunk_reviewer = reviewer.asReviewer(),
            .max_turns = 4,
        });
        defer agent.deinit();
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = ".zag-test-edit-sharp-remember/plan.jsonl",
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();
        _ = try agent.reply(&session, "plan apply");
        try std.testing.expectEqual(@as(u32, 0), reviewer.calls);
        const body = try expectPairedToolId(session.transcript.items(), "edit-sharp-plan-1");
        try std.testing.expect(tool_error.hasCode(body, .permission_denied));
        const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(original, after);
    }
}

test "edit-sharp §10.7 local soft failure exactly two provider calls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-edit-sharp-provider";
    const target = ".zag-test-edit-sharp-provider/t.txt";
    const original = "alpha OLD omega\n";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = original });
    const args = try editSharpApplyArgs(gpa, target, original, "OLD", "NEW");
    defer gpa.free(args);

    const Mock = struct {
        step: u32 = 0,
        args_json: []const u8,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "edit-sharp-provider-1"),
                    .name = try arena.dupe(u8, "apply_hunk"),
                    .arguments = try arena.dupe(u8, self.args_json),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            if (self.step == 2) {
                return .{
                    .content = try arena.dupe(u8, "final-stop"),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            }
            return error.InvalidResponse; // third call must not happen
        }
    };
    var mock: Mock = .{ .args_json = args };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .hunk_reviewer = null, // soft review_unavailable
        .max_turns = 4,
    });
    defer agent.deinit();
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
    });
    defer session.deinit();
    const result = try agent.reply(&session, "apply");
    try std.testing.expectEqualStrings("final-stop", result.final_text);
    try std.testing.expectEqual(@as(u32, 2), mock.step);
    const body = try expectPairedToolId(session.transcript.items(), "edit-sharp-provider-1");
    try std.testing.expect(std.mem.indexOf(u8, body, "review_unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "format=edit-sharp-v1") != null);
    const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "edit-sharp §10.11 resume fork schema v1 no durable preview proposal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-edit-sharp-session";
    const sess_path = ".zag-test-edit-sharp-session/parent.jsonl";
    const child_path = ".zag-test-edit-sharp-session/child.jsonl";
    const target = ".zag-test-edit-sharp-session/t.txt";
    // Large old_string forces preview truncation marker in review callback only.
    const pad = "PAD_EDIT_SHARP_PREVIEW_ONLY_SENTINEL_";
    var old_buf: [4500]u8 = undefined;
    @memset(&old_buf, 'A');
    @memcpy(old_buf[0..pad.len], pad);
    const old_s = old_buf[0..];
    const original_prefix = "HEAD ";
    const original_suffix = " TAIL\n";
    const original = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ original_prefix, old_s, original_suffix });
    defer gpa.free(original);

    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = original });

    const args = try editSharpApplyArgs(gpa, target, original, old_s, "NEW");
    defer gpa.free(args);

    var reviewer: EditSharpReviewer = .{ .decision = .reject };
    var verifier: EditSharpVerifier = .{};
    const Mock = struct {
        step: u32 = 0,
        args_json: []const u8,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "edit-sharp-fork-1"),
                    .name = try arena.dupe(u8, "apply_hunk"),
                    .arguments = try arena.dupe(u8, self.args_json),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "done-after-reject"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{ .args_json = args };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .hunk_reviewer = reviewer.asReviewer(),
        .post_edit_verifier = verifier.asVerifier(),
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());

    {
        var session = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .create_new,
            .load_project_instructions = false,
        });
        defer session.deinit();
        const result = try agent.reply(&session, "apply large hunk");
        try std.testing.expectEqualStrings("done-after-reject", result.final_text);
        try std.testing.expect(reviewer.calls >= 1);
        try std.testing.expect(reviewer.last_preview_had_marker);
        try std.testing.expectEqual(@as(u32, 0), verifier.calls);

        // Idle fork while session not in reply
        var child = try session.fork(child_path);
        defer child.deinit();

        // Live ports remain on Agent (non-persistent)
        try std.testing.expect(agent.apply_hunk_state.reviewer != null);
        try std.testing.expect(agent.apply_hunk_state.verifier != null);

        // No durable preview-only markers in parent session file or child
        try expectSessionBytesForbidNeedle(gpa, io, sess_path, "...[preview_truncated]");
        try expectSessionBytesForbidNeedle(gpa, io, sess_path, "apply_hunk review");
        try expectSessionBytesForbidNeedle(gpa, io, child_path, "...[preview_truncated]");
        try expectSessionBytesForbidNeedle(gpa, io, child_path, "apply_hunk review");

        // schema_version remains 1
        const parent_raw = try Io.Dir.cwd().readFileAlloc(io, sess_path, gpa, .limited(256 * 1024));
        defer gpa.free(parent_raw);
        try std.testing.expect(std.mem.indexOf(u8, parent_raw, "\"schema_version\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, parent_raw, "\"schema_version\":2") == null);
        const child_raw = try Io.Dir.cwd().readFileAlloc(io, child_path, gpa, .limited(256 * 1024));
        defer gpa.free(child_raw);
        try std.testing.expect(std.mem.indexOf(u8, child_raw, "\"schema_version\":1") != null);

        // Trace must not durable-persist preview construction
        const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "...[preview_truncated]") == null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "apply_hunk review") == null);
        // No new Trace kinds
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"hunk_review\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"proposal\"") == null);
    }

    // Resume parent + child
    {
        var resumed = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = sess_path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        defer resumed.deinit();
        const body = try expectPairedToolId(resumed.transcript.items(), "edit-sharp-fork-1");
        try std.testing.expect(std.mem.indexOf(u8, body, "rejected") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "...[preview_truncated]") == null);
        try std.testing.expectEqual(session_store.current_schema_version, @as(u32, 1));
    }
    {
        var resumed_child = try Session.start(gpa, io, .{
            .base_system = "sys",
            .path = child_path,
            .open_mode = .resume_existing,
            .load_project_instructions = false,
        });
        defer resumed_child.deinit();
        const body = try expectPairedToolId(resumed_child.transcript.items(), "edit-sharp-fork-1");
        try std.testing.expect(std.mem.indexOf(u8, body, "rejected") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "...[preview_truncated]") == null);
    }

    // Target unchanged
    const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(original.len + 8));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);
    // Ports still live on Agent after resume
    try std.testing.expect(agent.apply_hunk_state.reviewer != null);
}

test "edit-sharp §10.12 trace caps no raw preview marker" {
    // Covered jointly with §10.11 (trace buffer asserts). Keep a focused short-path fixture.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir_name = ".zag-test-edit-sharp-trace";
    const target = ".zag-test-edit-sharp-trace/t.txt";
    const original = "alpha OLD omega\n";
    Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_name);
    defer Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = original });
    const args = try editSharpApplyArgs(gpa, target, original, "OLD", "NEW");
    defer gpa.free(args);

    var reviewer: EditSharpReviewer = .{ .decision = .reject };
    const Mock = struct {
        step: u32 = 0,
        args_json: []const u8,
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const message.Message,
            _: []const tool.Definition,
            _: provider_mod.RequestControl,
            _: ?*?u64,
        ) provider_mod.ChatError!message.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step += 1;
            if (self.step == 1) {
                const tc = try arena.alloc(message.ToolCall, 1);
                tc[0] = .{
                    .id = try arena.dupe(u8, "edit-sharp-trace-1"),
                    .name = try arena.dupe(u8, "apply_hunk"),
                    .arguments = try arena.dupe(u8, self.args_json),
                };
                return .{ .content = "", .tool_calls = tc, .finish_reason = "tool_calls" };
            }
            return .{
                .content = try arena.dupe(u8, "ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
    };
    var mock: Mock = .{ .args_json = args };
    var agent = try Agent.init(gpa, io, .{
        .ptr = &mock,
        .vtable = &.{ .chat = Mock.chat },
    }, .{
        .permission_mode = .yolo,
        .hunk_reviewer = reviewer.asReviewer(),
        .max_turns = 4,
    });
    defer agent.deinit();
    agent.trace = trace_mod.Trace.init(gpa, io, null, Io.Dir.cwd());
    var session = try Session.start(gpa, io, .{
        .base_system = "sys",
        .path = ".zag-test-edit-sharp-trace/s.jsonl",
        .open_mode = .create_new,
        .load_project_instructions = false,
    });
    defer session.deinit();
    _ = try agent.reply(&session, "trace reject");
    const tr = if (agent.trace) |*t| t else return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "...[preview_truncated]") == null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "apply_hunk review") == null);
    try std.testing.expect(std.mem.indexOf(u8, tr.buf.items, "\"kind\":\"hunk_review\"") == null);
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_call"));
    try std.testing.expectEqual(@as(u32, 1), tr.countKind("tool_result"));
    try expectSessionBytesForbidNeedle(gpa, io, ".zag-test-edit-sharp-trace/s.jsonl", "...[preview_truncated]");
    try expectSessionBytesForbidNeedle(gpa, io, ".zag-test-edit-sharp-trace/s.jsonl", "apply_hunk review");
}
