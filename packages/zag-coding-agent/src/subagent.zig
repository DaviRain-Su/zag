//! Subagent system — in-process synchronous delegation (subagents-001).
//!
//! Design adapted from hyper-grok-build's `SubagentCoordinator` actor model,
//! simplified to zag's synchronous single-threaded loop architecture.
//!
//! The model-facing tool is `task` (grok-build renames to `spawn_subagent`).
//! When the model calls `task`, the handler:
//! 1. validates depth (MAX_SUBAGENT_DEPTH=1, matching grok-build)
//! 2. resolves the subagent type → system prompt + tool filter
//! 3. creates a child Agent + ephemeral Session (no durable path)
//! 4. runs `child_agent.reply(&child_session, prompt)`
//! 5. returns the child's final text as the tool result
//!
//! The child inherits the parent's provider, workspace, redactor, and
//! permission mode. The child gets a **filtered toolset** based on its type
//! (e.g. scout = read-only; reviewer = read-only; task = full).
//!
//! No inter-agent messaging (IrcBus), no background spawning, no dashboard —
//! those are deferred to a process-supervisor-backed design. This first slice
//! delivers foreground synchronous subagent delegation, which is the 80% use
//! case and the foundation for all later subagent features.
//!
//! ## Lifecycle states
//!
//! ```text
//! pending → running → completed (success | failed | cancelled)
//! ```
//!
//! The registry tracks all subagents spawned by one parent Agent for TUI
//! display and inspection. State transitions are synchronous: the parent
//! blocks during `running` and the child result is available immediately.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zag-agent-core");
const ai = @import("zag-ai");
const tool = core.tool;
const message = core.message;
const agent_mod = @import("agent.zig");
const toolset_mod = @import("toolset.zig");
const permissions = @import("permissions.zig");
const redact_mod = @import("redact.zig");
const workspace = @import("workspace.zig");
const edit_tools = @import("runtime/edit_tools.zig");
const fs_tools = @import("runtime/fs_tools.zig");
const shell_policy = @import("shell_policy.zig");

// ── Subagent types (adapted from grok-build SubagentType + oh-my-pi agent roles) ─

/// Built-in subagent specialization. Each type maps to a system prompt
/// profile and a tool capability filter (mirrors grok-build's
/// general-purpose/explore/plan and oh-my-pi's scout/reviewer/task).
pub const SubagentType = enum {
    /// Full-capability general-purpose worker (grok-build `general-purpose`,
    /// oh-my-pi `task`). Inherits the complete parent toolset.
    task,
    /// Read-only codebase explorer (grok-build `explore`, oh-my-pi `scout`).
    /// Fast recon; returns compressed context for handoff.
    scout,
    /// Read-only code reviewer (oh-my-pi `reviewer`). Analyzes code for
    /// quality, security, correctness; returns findings.
    reviewer,

    pub fn name(self: SubagentType) []const u8 {
        return switch (self) {
            .task => "task",
            .scout => "scout",
            .reviewer => "reviewer",
        };
    }

    pub fn fromString(s: []const u8) ?SubagentType {
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "scout")) return .scout;
        if (std.mem.eql(u8, s, "reviewer")) return .reviewer;
        return null;
    }

    /// System prompt for this subagent type (adapted from grok-build
    /// `subagent_prompt.md` templates and oh-my-pi agent .md files).
    pub fn systemPrompt(self: SubagentType) []const u8 {
        return switch (self) {
            .task => task_system_prompt,
            .scout => scout_system_prompt,
            .reviewer => reviewer_system_prompt,
        };
    }

    /// Whether this type is allowed to use write/execute tools.
    pub fn isReadOnly(self: SubagentType) bool {
        return self == .scout or self == .reviewer;
    }

    pub fn description(self: SubagentType) []const u8 {
        return switch (self) {
            .task => "General-purpose executor with full tool access. Use for multi-step work that requires editing files or running commands.",
            .scout => "Read-only codebase explorer. Fast recon for understanding structure, finding code, and returning compressed context. Cannot edit files or run shell commands.",
            .reviewer => "Read-only code reviewer. Analyzes code for quality, security, and correctness. Returns findings and recommendations. Cannot edit files or run shell commands.",
        };
    }
};

// ── System prompts (adapted from grok-build templates + oh-my-pi agent .md) ──

const task_system_prompt =
    \\You are a task subagent — a focused, general-purpose worker.
    \\
    \\You operate with the full toolset: read, search, edit, and shell.
    \\You inherit the parent agent's workspace and permission policy.
    \\
    \\Rules:
    \\- Execute the assigned task completely. Do not ask for clarification unless the task is truly ambiguous.
    \\- Work autonomously: read files, make edits, run builds/tests as needed.
    \\- Return a concise summary of what you did, key decisions, and any issues.
    \\- Do not spawn further subagents (max nesting depth is 1).
    \\- Follow the project's AGENTS.md conventions.
;

const scout_system_prompt =
    \\You are a scout subagent — a read-only codebase explorer.
    \\
    \\You have read-only tools: list_dir, read_file, grep, glob.
    \\You cannot edit files or run shell commands.
    \\
    \\Rules:
    \\- Explore the codebase efficiently to answer the assigned question.
    \\- Return compressed, structured findings: file paths, key types, relevant code snippets.
    \\- Do not speculate about code you have not read. Cite exact file paths and line numbers.
    \\- Prioritize the most relevant files; skip boilerplate.
    \\- Your output is consumed by the parent agent for handoff — be precise and complete.
;

const reviewer_system_prompt =
    \\You are a reviewer subagent — a read-only code quality analyst.
    \\
    \\You have read-only tools: list_dir, read_file, grep, glob.
    \\You cannot edit files or run shell commands.
    \\
    \\Rules:
    \\- Review the specified code for correctness, security, and maintainability.
    \\- Focus on load-bearing logic, error handling, edge cases, and invariant violations.
    \\- Report findings as a structured list: severity (critical/warning/note), file:line, description.
    \\- Do not suggest stylistic changes unless they mask a bug.
    \\- Be evidence-based: quote the exact code that has the issue.
;

// ── Subagent status (adapted from grok-build SubagentSnapshotStatus) ──────────

pub const Status = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }

    pub fn isTerminal(self: Status) bool {
        return self == .completed or self == .failed or self == .cancelled;
    }
};

// ── Subagent request (adapted from grok-build SubagentRequest) ───────────────

pub const SubagentRequest = struct {
    /// Caller-assigned id (typically the tool call id).
    id: []const u8,
    /// The task prompt for the subagent.
    prompt: []const u8,
    /// Short human-readable description of the task.
    description: []const u8,
    /// Subagent specialization.
    subagent_type: SubagentType = .task,
    /// Maximum turns for the child agent (default 20, matching the parent
    /// loop's `default_max_turns`; grok-build uses SubagentExecutionBudget
    /// max_turns). Read-only recon (scout/reviewer) burns turns on tool
    /// calls, so 10 was too tight and often ended on a tool-call-only
    /// message with an empty final text.
    max_turns: u32 = 20,
    /// Parent session depth (0 = top-level). Child depth = parent + 1.
    /// MAX_SUBAGENT_DEPTH = 1 means a child at depth 1 cannot spawn further
    /// subagents.
    parent_depth: u32 = 0,
};

// ── Subagent result (adapted from grok-build SubagentResult) ─────────────────

pub const SubagentResult = struct {
    success: bool,
    output: []const u8,
    subagent_type: SubagentType,
    turns: u32 = 0,
    stop_reason: []const u8 = "completed",
    error_message: ?[]const u8 = null,

    pub fn statusString(self: SubagentResult) []const u8 {
        if (!self.success) {
            if (std.mem.eql(u8, self.stop_reason, "cancelled")) return "cancelled";
            return "failed";
        }
        return "completed";
    }
};

// ── Output finalization (budget-exhausted-empty) ────────────────────────────

/// Finalized child output: success flag plus the gpa-owned output body.
const Finalized = struct {
    success: bool,
    output: []u8,
};

/// Post-process the child's final text into the parent-visible output.
///
/// A child that exhausts its turn budget (`max_turns`) with an **empty** final
/// text — the last assistant message was tool-call-only, so the loop's
/// `final_text` is "" — previously returned a silent empty body that the
/// parent read as "the scout did nothing". Replace that with a diagnostic and
/// mark the delegation failed so the parent re-dispatches with a larger
/// budget or a narrower task. `max_turns` with real text keeps partial
/// results (success=true, unchanged), as does every `completed` path.
fn finalizeChildOutput(
    gpa: std.mem.Allocator,
    success: bool,
    stop_reason: []const u8,
    final_text: []const u8,
    max_turns: u32,
) error{OutOfMemory}!Finalized {
    if (std.mem.eql(u8, stop_reason, "max_turns") and final_text.len == 0) {
        const diag = std.fmt.allocPrint(
            gpa,
            "child exhausted its {d}-turn budget before producing a final text response (last assistant message was tool-call-only); re-dispatch with a larger max_turns or a narrower task",
            .{max_turns},
        ) catch return error.OutOfMemory;
        return .{ .success = false, .output = diag };
    }
    const owned = gpa.dupe(u8, final_text) catch return error.OutOfMemory;
    return .{ .success = success, .output = owned };
}

// ── Registry (adapted from oh-my-pi AgentRegistry + grok-build coordinator state) ─

/// Maximum subagent entries tracked in the registry (ring buffer).
pub const max_registry_entries: usize = 64;

/// One tracked subagent entry.
pub const Entry = struct {
    /// Owned id (gpa); empty means the slot is free.
    id: []u8 = &[_]u8{},
    /// Owned short description (gpa).
    description: []u8 = &[_]u8{},
    subagent_type: SubagentType = .task,
    status: Status = .pending,
    /// Owned output text (gpa-allocated on completion).
    output: []u8 = &[_]u8{},
    turns: u32 = 0,
    error_message: ?[]u8 = null,
    /// Monotonic timestamp (ms) when the subagent was created.
    started_ms: u64 = 0,
    /// Monotonic timestamp (ms) when the subagent reached a terminal state.
    finished_ms: u64 = 0,

    pub fn freeOwned(self: *Entry, gpa: std.mem.Allocator) void {
        if (self.id.len > 0) {
            gpa.free(self.id);
            self.id = &[_]u8{};
        }
        if (self.description.len > 0) {
            gpa.free(self.description);
            self.description = &[_]u8{};
        }
        if (self.output.len > 0) {
            gpa.free(self.output);
            self.output = &[_]u8{};
        }
        if (self.error_message) |em| {
            gpa.free(em);
            self.error_message = null;
        }
    }
};

/// Process-in-memory registry of subagents spawned by one parent Agent.
/// Not durable; not thread-safe (parent Agent is synchronous). The TUI reads
/// a snapshot for display.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: [max_registry_entries]Entry = [_]Entry{.{}} ** max_registry_entries,
    /// Ring buffer write index.
    head: usize = 0,
    /// Number of active (non-terminal) subagents.
    active_count: usize = 0,
    /// Total entries ever recorded (monotonic; ≥ entries in ring).
    total_spawned: u64 = 0,
    /// Current nesting depth (0 = no subagent running).
    depth: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (&self.entries) |*e| e.freeOwned(self.gpa);
        self.* = undefined;
    }

    /// Allocate a slot in the ring buffer for a new subagent.
    /// Returns the index. Does NOT set status (caller sets pending→running).
    pub fn allocSlot(self: *Registry) usize {
        const idx = self.head;
        const slot = &self.entries[idx];
        slot.freeOwned(self.gpa);
        slot.* = .{};
        self.head = (self.head + 1) % max_registry_entries;
        self.total_spawned +|= 1;
        return idx;
    }

    /// Assign a unique owned id (`task-N`) and owned description to a slot.
    /// Does not touch status/timestamps/output.
    pub fn setIdentity(self: *Registry, idx: usize, description: []const u8) error{OutOfMemory}!void {
        const e = self.get(idx);
        if (e.id.len > 0) {
            self.gpa.free(e.id);
            e.id = &[_]u8{};
        }
        if (e.description.len > 0) {
            self.gpa.free(e.description);
            e.description = &[_]u8{};
        }
        var id_buf: [32]u8 = undefined;
        const id_txt = std.fmt.bufPrint(&id_buf, "task-{d}", .{self.total_spawned}) catch "task";
        e.id = try self.gpa.dupe(u8, id_txt);
        errdefer {
            self.gpa.free(e.id);
            e.id = &[_]u8{};
        }
        e.description = try self.gpa.dupe(u8, description);
    }

    /// Get a mutable entry by index.
    pub fn get(self: *Registry, idx: usize) *Entry {
        return &self.entries[idx];
    }

    /// Get a const entry by index.
    pub fn getConst(self: *const Registry, idx: usize) *const Entry {
        return &self.entries[idx];
    }

    /// Count of entries with a specific status.
    pub fn countByStatus(self: *const Registry, want: Status) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.status == want) n += 1;
        }
        return n;
    }

    /// Number of entries with any non-default state (id != "").
    pub fn liveCount(self: *const Registry) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.id.len > 0) n += 1;
        }
        return n;
    }

    /// Snapshot all live entries into a caller-provided slice.
    /// Returns the number of entries copied.
    pub fn snapshotInto(self: *const Registry, out: []Entry) usize {
        var n: usize = 0;
        // Walk in insertion order (oldest first): start from tail.
        const live = self.liveCount();
        if (live == 0) return 0;
        // The ring head points at the next-write slot; the oldest live entry
        // is at (head - live) mod max. Walk forward from there.
        const start = if (live <= max_registry_entries)
            (self.head + max_registry_entries - live) % max_registry_entries
        else
            self.head;
        var i: usize = 0;
        while (i < max_registry_entries and n < out.len) : (i += 1) {
            const idx = (start + i) % max_registry_entries;
            const e = &self.entries[idx];
            if (e.id.len > 0) {
                out[n] = e.*;
                n += 1;
            }
        }
        return n;
    }
};

// ── Depth limiting (adapted from grok-build SubagentDepthCounter) ────────────

/// Maximum nesting depth. 0 = top-level agent; 1 = first subagent.
/// A subagent at depth 1 cannot spawn further subagents (matches
/// grok-build MAX_SUBAGENT_DEPTH=1).
pub const max_depth: u32 = 1;

/// Check whether a spawn at the given parent depth is allowed.
pub fn depthAllowed(parent_depth: u32) bool {
    return parent_depth < max_depth;
}

// ── Tool filtering (adapted from grok-build SubagentCapabilityMode) ──────────

/// Build a read-only tool slice for scout/reviewer subagents.
/// Returns a stack-allocated array of tools (no apply_hunk/apply_transaction/
/// write_file/search_replace/run_shell).
pub fn readOnlyTools(apply_state: *edit_tools.ApplyHunkState) [4]tool.Tool {
    _ = apply_state;
    const ro = fs_tools.phase0Tools();
    const search = fs_tools.searchTools();
    return .{
        ro[0], // list_dir
        ro[1], // read_file
        search[0], // grep
        search[1], // glob
    };
}

/// Build a full-capability tool slice WITHOUT the `task` tool, for task-type
/// subagents. MAX_SUBAGENT_DEPTH=1 means a child cannot spawn further
/// subagents, so the `task` tool is excluded from the child's toolset.
pub fn fullToolsNoTask(apply_state: *edit_tools.ApplyHunkState) [9]tool.Tool {
    const ro = fs_tools.phase0Tools();
    const search = fs_tools.searchTools();
    const rw = edit_tools.phase1ExtraTools();
    return .{
        ro[0], // list_dir
        ro[1], // read_file
        search[0], // grep
        search[1], // glob
        rw[0], // search_replace
        rw[1], // write_file
        edit_tools.makeApplyHunkTool(apply_state),
        edit_tools.makeApplyTransactionTool(apply_state),
        rw[2], // run_shell
    };
}

/// Tool definition for the model-facing `task` tool (adapted from
/// grok-build TaskTool / TaskToolInput).
pub const task_def: tool.Definition = .{
    .name = "task",
    .description =
    \\Dispatch a subagent to work on a task. The subagent runs autonomously with its own
    \\context window and returns a result. Use this to parallelize work, delegate research,
    \\or isolate complex subtasks.
    \\
    \\Subagent types:
    \\- "task": general-purpose worker with full tool access (read, edit, shell). Use for multi-step work.
    \\- "scout": read-only codebase explorer. Fast recon; returns compressed context. Cannot edit or run shell.
    \\- "reviewer": read-only code reviewer. Analyzes code quality, security, correctness. Cannot edit or run shell.
    \\
    \\The subagent inherits the parent's workspace, provider, and permission policy.
    \\Max nesting depth is 1: a subagent cannot spawn further subagents.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "prompt": {
    \\      "type": "string",
    \\      "description": "The task prompt for the subagent. Be specific and self-contained."
    \\    },
    \\    "description": {
    \\      "type": "string",
    \\      "description": "Short one-line description of the task (shown in UI)."
    \\    },
    \\    "subagent_type": {
    \\      "type": "string",
    \\      "description": "Subagent type: \"task\", \"scout\", or \"reviewer\". Default \"task\".",
    \\      "enum": ["task", "scout", "reviewer"]
    \\    },
    \\    "max_turns": {
    \\      "type": "integer",
    \\      "description": "Maximum turns for the subagent (default 20)."
    \\    }
    \\  },
    \\  "required": ["prompt", "description"],
    \\  "additionalProperties": false
    \\}
    ,
};

/// Capabilities for the `task` tool. The task tool is special: it doesn't
/// use workspace paths or shell command arguments directly — it dispatches
/// a child agent. Risk is `execute` because a task subagent can edit files
/// and run commands. The permission gate sees this as an execute-risk tool.
pub const task_capabilities: zt_ToolCapabilities = .{
    .risk = .execute,
    .workspace = .none,
    .cancellation = .cooperative,
    .shell = .none,
};

const zt_ToolCapabilities = @import("zag-types").ToolCapabilities;
const zt_ToolDescriptor = @import("zag-types").ToolDescriptor;

pub const task_descriptor: zt_ToolDescriptor = .{
    .definition = task_def,
    .capabilities = task_capabilities,
};

// ── Spawn context (adapted from grok-build SubagentSpawnContext) ─────────────

/// Borrowed parent resources needed to construct a child Agent.
/// All fields are borrowed from the parent Agent and must outlive the
/// child agent's reply. The child does NOT take ownership.
pub const SpawnContext = struct {
    /// Parent's GPA (child allocates from this).
    gpa: std.mem.Allocator,
    /// Parent's IO handle.
    io: std.Io,
    /// Parent's provider port (shared — the child makes its own provider calls).
    provider: core.provider.Provider,
    /// Parent's redactor (cloned into the child's owned redactor).
    parent_redactor: *const redact_mod.Redactor,
    /// Parent's permission mode.
    permission_mode: permissions.Mode,
    /// Parent's shell policy mode.
    shell_policy_mode: shell_policy.Mode,
    /// Parent's nesting depth (child depth = this + 1).
    parent_depth: u32,
    /// Parent's apply_hunk_state (borrowed for child's toolset).
    apply_hunk_state: *edit_tools.ApplyHunkState,
    /// Subagent request.
    request: SubagentRequest,
};

/// Spawn a subagent: create a child Agent + ephemeral Session, run reply,
/// return the result. The child is fully synchronous — the parent blocks
/// until the child completes.
///
/// This function owns the child Agent and Session lifetimes: both are
/// created on the stack/heap, used for one reply, and deinit'd before
/// return. No durable session path is created (ephemeral only).
pub fn spawn(ctx: SpawnContext) agent_mod.ReplyError!SubagentResult {
    const subagent_type = ctx.request.subagent_type;
    const gpa = ctx.gpa;

    // Build the child's toolset BEFORE creating the Agent so Options.toolset
    // is set at init time (no re-init). Read-only types get a 4-tool slice
    // (list_dir, read_file, grep, glob); task type uses the Agent's default
    // Phase1Storage (toolset = null).
    var child_apply_state: edit_tools.ApplyHunkState = .{
        .reviewer = null,
        .verifier = null,
    };

    // Allocate the tool slice on the heap so it survives the Agent's
    // lifetime. All subagent types get a custom toolset:
    // - Read-only (scout/reviewer): 4 read-only tools.
    // - Task: 9 full tools WITHOUT the `task` tool (depth=1, no nesting).
    // Freed via defer after reply.
    const child_tools: ?[]tool.Tool = blk: {
        const tools_len = if (subagent_type.isReadOnly())
            @as(usize, readOnlyTools(&child_apply_state).len)
        else
            @as(usize, fullToolsNoTask(&child_apply_state).len);
        const slice = gpa.alloc(tool.Tool, tools_len) catch |err| {
            return .{
                .success = false,
                .output = "",
                .subagent_type = subagent_type,
                .error_message = "out of memory",
                .stop_reason = @errorName(err),
            };
        };
        if (subagent_type.isReadOnly()) {
            const ro = readOnlyTools(&child_apply_state);
            @memcpy(slice, &ro);
        } else {
            const ft = fullToolsNoTask(&child_apply_state);
            @memcpy(slice, &ft);
        }
        break :blk slice;
    };
    defer if (child_tools) |s| gpa.free(s);

    // Build child Agent options. The child inherits the parent's policy
    // but gets the subagent type's system prompt as its base system.
    // No trace, no lifecycle observer, no cost catalog — the child is
    // ephemeral and its usage is folded into the parent's ledger by the
    // tool handler (the parent's event_sink sees the task tool result).
    const child_options: agent_mod.Options = .{
        .max_turns = ctx.request.max_turns,
        .permission_mode = ctx.permission_mode,
        .session_kind = .agent,
        .shell_policy = ctx.shell_policy_mode,
        .trace_path = null,
        .version = "0.5.0",
        .chat_retries = 2,
        .retry_base_delay_ms = 500,
        .provider_timeout_ms = null,
        .model_info = null,
        .secrets = &.{},
        .pattern_redaction = true,
        .redactor = ctx.parent_redactor,
        // All subagent types get a custom toolset (no `task` tool —
        // MAX_SUBAGENT_DEPTH=1 prevents nesting).
        .toolset = child_tools,
        .hunk_reviewer = null,
        .post_edit_verifier = null,
        .observer = null,
        .lifecycle = null,
    };

    var child_agent = agent_mod.Agent.init(gpa, ctx.io, ctx.provider, child_options) catch |err| {
        return .{
            .success = false,
            .output = "",
            .subagent_type = subagent_type,
            .error_message = "failed to init child agent",
            .stop_reason = @errorName(err),
        };
    };
    defer child_agent.deinit();

    // Create an ephemeral child session (no durable path).
    var child_session = agent_mod.Session.start(gpa, ctx.io, .{
        .base_system = subagent_type.systemPrompt(),
        .path = null,
        .open_mode = .create_new,
        .load_project_instructions = true,
        .redactor = ctx.parent_redactor,
        .skills_enabled = false,
        .templates_enabled = false,
    }) catch |err| {
        return .{
            .success = false,
            .output = "",
            .subagent_type = subagent_type,
            .error_message = "failed to start child session",
            .stop_reason = @errorName(err),
        };
    };
    defer child_session.deinit();

    // Run the child agent's reply. This blocks until the child completes.
    const result = child_agent.reply(&child_session, ctx.request.prompt) catch |err| {
        return .{
            .success = false,
            .output = "",
            .subagent_type = subagent_type,
            .error_message = @errorName(err),
            .stop_reason = "child_error",
        };
    };

    // Dup the final text BEFORE child_session.deinit() (defer above) frees
    // the transcript arena that owns result.final_text. When the child
    // exhausted its turn budget on tool calls without producing any text
    // (last assistant message was tool-call-only), finalizeChildOutput
    // replaces the silent empty output with a diagnostic and marks the
    // delegation failed (budget-exhausted-empty).
    const finalized = finalizeChildOutput(
        gpa,
        result.stop_reason == .completed or result.stop_reason == .max_turns,
        result.stop_reason.name(),
        result.final_text,
        ctx.request.max_turns,
    ) catch {
        return .{
            .success = false,
            .output = "",
            .subagent_type = subagent_type,
            .error_message = "out of memory finalizing child output",
            .stop_reason = "out_of_memory",
        };
    };

    return .{
        .success = finalized.success,
        .output = finalized.output,
        .subagent_type = subagent_type,
        .turns = result.turns,
        .stop_reason = result.stop_reason.name(),
    };
}

/// Concurrent spawn using Zig 0.16 `io.concurrent` + `Io.Future`.
///
/// Spawns the child agent's reply on a concurrent task, returning a
/// `Future(SubagentResult)` that the caller can `await` or `cancel`.
/// This allows the parent loop to remain responsive (e.g. the TUI worker
/// thread can poll for completion while the UI thread renders).
///
/// The `spawn_ctx` must outlive the future — it is borrowed by the
/// concurrent task until completion. The child Agent + Session are
/// created inside the concurrent task and deinit'd before the result
/// is written to the future.
///
/// Usage:
/// ```zig
/// var future = try spawnConcurrent(io, spawn_ctx);
/// // ... do other work while child runs ...
/// const result = future.await(io);
/// ```
pub fn spawnConcurrent(
    io: std.Io,
    spawn_ctx: SpawnContext,
) std.Io.ConcurrentError!std.Io.Future(SubagentResult) {
    // The concurrent task receives a pointer to the args tuple; we
    // must keep the SpawnContext alive for the duration of the task.
    // The caller owns `spawn_ctx` and must not move/destroy it until
    // `future.await(io)` or `future.cancel(io)` returns.
    return io.concurrent(spawnConcurrentImpl, .{spawn_ctx});
}

/// Inner implementation for `spawnConcurrent`. This is the function
/// that runs on the concurrent task. It creates the child Agent +
/// Session, runs reply, and returns the SubagentResult.
fn spawnConcurrentImpl(ctx: SpawnContext) SubagentResult {
    return spawn(ctx);
}

/// Spawn multiple subagents concurrently and await all results.
/// Uses `io.concurrent` for each child, then `await` in order.
/// Returns results in the same order as the input slice.
///
/// All `SpawnContext` items must outlive the `awaitAll` call.
pub fn spawnAllConcurrent(
    io: std.Io,
    gpa: std.mem.Allocator,
    contexts: []const SpawnContext,
) std.Io.ConcurrentError![]SubagentResult {
    // Allocate futures array.
    const futures = gpa.alloc(std.Io.Future(SubagentResult), contexts.len) catch
        return error.ConcurrencyUnavailable;
    defer gpa.free(futures);

    // Spawn all children concurrently.
    for (contexts, 0..) |ctx, i| {
        futures[i] = try io.concurrent(spawnConcurrentImpl, .{ctx});
    }

    // Allocate results array.
    const results = gpa.alloc(SubagentResult, contexts.len) catch
        return error.ConcurrencyUnavailable;

    // Await all in order.
    for (futures, 0..) |*f, i| {
        results[i] = f.await(io);
    }

    return results;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "SubagentType.fromString resolves all built-in types" {
    try std.testing.expectEqual(SubagentType.task, SubagentType.fromString("task").?);
    try std.testing.expectEqual(SubagentType.scout, SubagentType.fromString("scout").?);
    try std.testing.expectEqual(SubagentType.reviewer, SubagentType.fromString("reviewer").?);
    try std.testing.expect(SubagentType.fromString("unknown") == null);
}

test "SubagentType.isReadOnly" {
    try std.testing.expect(!SubagentType.task.isReadOnly());
    try std.testing.expect(SubagentType.scout.isReadOnly());
    try std.testing.expect(SubagentType.reviewer.isReadOnly());
}

test "SubagentType.systemPrompt is non-empty for all types" {
    try std.testing.expect(SubagentType.task.systemPrompt().len > 0);
    try std.testing.expect(SubagentType.scout.systemPrompt().len > 0);
    try std.testing.expect(SubagentType.reviewer.systemPrompt().len > 0);
}

test "depthAllowed respects max_depth=1" {
    try std.testing.expect(depthAllowed(0)); // top-level can spawn
    try std.testing.expect(!depthAllowed(1)); // depth-1 child cannot spawn
    try std.testing.expect(!depthAllowed(2));
}

test "registry allocSlot and status tracking" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const idx0 = reg.allocSlot();
    try reg.setIdentity(idx0, "first");
    reg.entries[idx0].status = .running;
    reg.active_count += 1;

    const idx1 = reg.allocSlot();
    try reg.setIdentity(idx1, "second");
    reg.entries[idx1].status = .completed;

    try std.testing.expectEqual(@as(usize, 1), reg.countByStatus(.running));
    try std.testing.expectEqual(@as(usize, 1), reg.countByStatus(.completed));
    try std.testing.expectEqual(@as(usize, 2), reg.liveCount());
    try std.testing.expectEqual(@as(u64, 2), reg.total_spawned);
}

test "registry ring wraps and frees" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    var i: usize = 0;
    while (i < max_registry_entries + 2) : (i += 1) {
        const idx = reg.allocSlot();
        try reg.setIdentity(idx, "x");
        reg.entries[idx].status = .completed;
    }
    try std.testing.expectEqual(@as(usize, max_registry_entries), reg.liveCount());
}

test "registry snapshotInto oldest-first" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();

    const idx0 = reg.allocSlot();
    try reg.setIdentity(idx0, "first");
    const idx1 = reg.allocSlot();
    try reg.setIdentity(idx1, "second");

    var buf: [8]Entry = undefined;
    const n = reg.snapshotInto(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("task-1", buf[0].id);
    try std.testing.expectEqualStrings("task-2", buf[1].id);
}

test "finalizeChildOutput: max_turns with empty text yields diagnostic + failed" {
    const gpa = std.testing.allocator;
    const f = try finalizeChildOutput(gpa, true, "max_turns", "", 10);
    defer gpa.free(f.output);
    try std.testing.expect(!f.success);
    try std.testing.expect(std.mem.indexOf(u8, f.output, "10-turn budget") != null);
}

test "finalizeChildOutput: completed with text stays success" {
    const gpa = std.testing.allocator;
    const f = try finalizeChildOutput(gpa, true, "completed", "findings", 10);
    defer gpa.free(f.output);
    try std.testing.expect(f.success);
    try std.testing.expectEqualStrings("findings", f.output);
}

test "finalizeChildOutput: max_turns with text keeps partial success" {
    const gpa = std.testing.allocator;
    const f = try finalizeChildOutput(gpa, true, "max_turns", "partial notes", 10);
    defer gpa.free(f.output);
    try std.testing.expect(f.success);
    try std.testing.expectEqualStrings("partial notes", f.output);
}

test "SubagentResult.statusString" {
    const ok: SubagentResult = .{
        .success = true,
        .output = "done",
        .subagent_type = .task,
        .stop_reason = "completed",
    };
    try std.testing.expectEqualStrings("completed", ok.statusString());

    const fail: SubagentResult = .{
        .success = false,
        .output = "",
        .subagent_type = .task,
        .stop_reason = "provider_error",
    };
    try std.testing.expectEqualStrings("failed", fail.statusString());

    const cancel: SubagentResult = .{
        .success = false,
        .output = "",
        .subagent_type = .task,
        .stop_reason = "cancelled",
    };
    try std.testing.expectEqualStrings("cancelled", cancel.statusString());
}

test "task_def has valid name and schema" {
    try std.testing.expectEqualStrings("task", task_def.name);
    try std.testing.expect(task_def.parameters_json.len > 0);
    try std.testing.expect(task_def.description.len > 0);
}