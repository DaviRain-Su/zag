//! `task` tool handler — model-facing subagent dispatch (subagents-001).
//!
//! The handler borrows a `TaskToolState` (instance pointer) that carries
//! the parent Agent's resources needed to spawn a child. The state is
//! Agent-owned and heap-stable (like `ApplyHunkState`).
//!
//! When the model calls `task`, the handler:
//! 1. parses prompt + description + subagent_type + max_turns
//! 2. checks depth (MAX_SUBAGENT_DEPTH=1)
//! 3. calls `subagent.spawn()` which creates a child Agent + Session,
//!    runs reply, and returns the result
//! 4. formats the result as a tool result body
//! 5. records the subagent in the registry for TUI display
//!
//! The spawn is synchronous and foreground — the parent loop blocks until
//! the child completes. This is the grok-build `await_to_completion=true`
//! foreground path, adapted to zag's synchronous architecture.

const std = @import("std");
const core = @import("zag-agent-core");
const tool = core.tool;
const subagent_mod = @import("../subagent.zig");
const agent_mod = @import("../agent.zig");
const permissions = @import("../permissions.zig");
const redact_mod = @import("../redact.zig");
const shell_policy_mod = @import("../shell_policy.zig");
const edit_tools = @import("edit_tools.zig");

/// Agent-owned heap-stable state for the `task` tool.
/// Borrowed by the handler via the `instance` pointer.
/// Lifetime: same as the parent Agent (created at Agent.init, freed at deinit).
pub const TaskToolState = struct {
    /// Parent's GPA (borrowed — same as Agent.gpa).
    gpa: std.mem.Allocator,
    /// Parent's IO handle (borrowed).
    io: std.Io,
    /// Parent's provider port (borrowed — shared for child calls).
    provider: core.provider.Provider,
    /// Parent's redactor (borrowed — cloned into child).
    redactor: *const redact_mod.Redactor,
    /// Parent's permission mode.
    permission_mode: permissions.Mode = .ask,
    /// Parent's shell policy mode.
    shell_policy_mode: shell_policy_mod.Mode = .protect,
    /// Parent's nesting depth (0 = top-level). Set by Agent.reply when
    /// composing the toolset; the task tool reads this to enforce
    /// MAX_SUBAGENT_DEPTH.
    parent_depth: u32 = 0,
    /// Parent's apply_hunk_state (borrowed for child's toolset when
    /// the child is a `task` type with full toolset).
    apply_hunk_state: *edit_tools.ApplyHunkState,
    /// Subagent registry (borrowed from Agent). The handler records each
    /// spawn in the registry for TUI display.
    registry: ?*subagent_mod.Registry = null,
};

/// Tool definition re-exported for convenience.
pub const task_def = subagent_mod.task_def;
pub const task_descriptor = subagent_mod.task_descriptor;

/// Model-facing `task` tool value. Instance must point to a `TaskToolState`.
pub fn makeTaskTool(state: *TaskToolState) tool.Tool {
    return .{
        .descriptor = subagent_mod.task_descriptor,
        .instance = state,
        .handler = handleTask,
    };
}

/// `task` tool handler. See module docs for the full flow.
pub fn handleTask(
    ctx: tool.Context,
    instance: ?*anyopaque,
    arguments_json: []const u8,
) tool.HandlerError![]u8 {
    const state: *TaskToolState = @ptrCast(@alignCast(instance.?));

    // Parse arguments.
    const prompt = tool.requireStringField(ctx.allocator, arguments_json, "prompt") catch
        return softError(ctx.allocator, "invalid_arguments", "missing or invalid 'prompt' field");
    defer ctx.allocator.free(prompt);

    const description = tool.requireStringField(ctx.allocator, arguments_json, "description") catch
        return softError(ctx.allocator, "invalid_arguments", "missing or invalid 'description' field");
    defer ctx.allocator.free(description);

    // Optional subagent_type (default "task").
    const type_str = tool.optionalStringField(ctx.allocator, arguments_json, "subagent_type") catch
        return softError(ctx.allocator, "invalid_arguments", "invalid 'subagent_type' field");
    defer if (type_str) |s| ctx.allocator.free(s);

    const subagent_type: subagent_mod.SubagentType = if (type_str) |s|
        subagent_mod.SubagentType.fromString(s) orelse .task
    else
        .task;

    // Optional max_turns (default 20, matching SubagentRequest default).
    const max_turns: u32 = parseMaxTurns(ctx.allocator, arguments_json) catch default_max_turns;

    if (prompt.len == 0) return softError(ctx.allocator, "invalid_arguments", "prompt must not be empty");
    if (description.len == 0) return softError(ctx.allocator, "invalid_arguments", "description must not be empty");

    // Depth check: a subagent at parent_depth cannot spawn if parent_depth >= MAX_SUBAGENT_DEPTH.
    if (!subagent_mod.depthAllowed(state.parent_depth)) {
        return softError(ctx.allocator, "depth_exceeded", "max subagent nesting depth (1) exceeded; a subagent cannot spawn further subagents");
    }

    // Record in registry (if available). Own id + description so the TUI can
    // still display them after this handler returns (args are freed below).
    var reg_idx: ?usize = null;
    if (state.registry) |reg| {
        reg_idx = reg.allocSlot();
        const entry = reg.get(reg_idx.?);
        reg.setIdentity(reg_idx.?, description) catch {
            // Fall back to empty identity; slot stays free-looking if id empty.
        };
        entry.subagent_type = subagent_type;
        entry.status = .running;
        entry.started_ms = nowMs();
        reg.depth = state.parent_depth + 1;
        reg.active_count += 1;
    }

    // Spawn the subagent. Prefer the registry-owned id when available.
    const spawn_id: []const u8 = blk: {
        if (reg_idx) |idx| {
            if (state.registry) |reg| {
                const id = reg.get(idx).id;
                if (id.len > 0) break :blk id;
            }
        }
        break :blk "task_call";
    };
    const request: subagent_mod.SubagentRequest = .{
        .id = spawn_id,
        .prompt = prompt,
        .description = description,
        .subagent_type = subagent_type,
        .max_turns = max_turns,
        .parent_depth = state.parent_depth,
    };

    const spawn_ctx: subagent_mod.SpawnContext = .{
        .gpa = state.gpa,
        .io = state.io,
        .provider = state.provider,
        .parent_redactor = state.redactor,
        .permission_mode = state.permission_mode,
        .shell_policy_mode = state.shell_policy_mode,
        .parent_depth = state.parent_depth,
        .apply_hunk_state = state.apply_hunk_state,
        .request = request,
    };

    const result = subagent_mod.spawn(spawn_ctx) catch |err| {
        // Record failure in registry.
        if (reg_idx) |idx| {
            if (state.registry) |reg| {
                const entry = reg.get(idx);
                entry.status = .failed;
                entry.error_message = std.fmt.allocPrint(state.gpa, "{s}", .{@errorName(err)}) catch null;
                entry.finished_ms = nowMs();
                reg.active_count = if (reg.active_count > 0) reg.active_count - 1 else 0;
                reg.depth = 0;
            }
        }
        return softError(ctx.allocator, "spawn_failed", @errorName(err));
    };

    // NOTE: result.output is gpa-allocated by spawn() for every non-empty
    // body — including the budget-exhausted diagnostic that carries
    // success=false (subagent.zig finalizeChildOutput). It must remain valid
    // until both registry recording and formatResult are done. Free it after
    // formatResult returns. Literal "" error outputs have len 0 and are never
    // freed, so the gate is len > 0, not success.

    // Record result in registry.
    if (reg_idx) |idx| {
        if (state.registry) |reg| {
            const entry = reg.get(idx);
            entry.status = if (result.success) .completed else
                (if (std.mem.eql(u8, result.stop_reason, "cancelled")) .cancelled else .failed);
            entry.turns = result.turns;
            entry.output = state.gpa.dupe(u8, result.output) catch &[_]u8{};
            if (result.error_message) |em| {
                entry.error_message = state.gpa.dupe(u8, em) catch null;
            }
            entry.finished_ms = nowMs();
            reg.active_count = if (reg.active_count > 0) reg.active_count - 1 else 0;
            reg.depth = 0;
        }
    }

    // Format the tool result body (uses result.output before free).
    const body = formatResult(ctx.allocator, result);
    // Free spawn-allocated output after all uses (registry + format).
    // success=false may still own a diagnostic body (len > 0); the only
    // non-owned outputs are literal "" (len 0).
    if (result.output.len > 0) state.gpa.free(result.output);
    return body;
}

/// Maximum output bytes included in the tool result body (prevents
/// oversized tool results from causing provider 400 errors).
const max_output_bytes: usize = 8 * 1024;

/// Format the subagent result as a tool result body for the model.
/// Output is truncated to `max_output_bytes` to avoid provider rejections.
fn formatResult(allocator: std.mem.Allocator, result: subagent_mod.SubagentResult) tool.HandlerError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    out.writer.print(
        "subagent_type: {s}\nstatus: {s}\nturns: {d}\n",
        .{ result.subagent_type.name(), result.statusString(), result.turns },
    ) catch return error.OutOfMemory;

    if (result.error_message) |em| {
        out.writer.print("error: {s}\n", .{em}) catch return error.OutOfMemory;
    }

    // Truncate output to avoid provider 400 on oversized tool results.
    const output = result.output;
    if (output.len <= max_output_bytes) {
        out.writer.print("\n--- output ---\n{s}\n", .{output}) catch return error.OutOfMemory;
    } else {
        out.writer.print("\n--- output (truncated, {d}/{d} bytes) ---\n{s}\n...[truncated]\n", .{
            max_output_bytes, output.len, output[0..max_output_bytes],
        }) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Soft tool error: format a structured error body.
fn softError(allocator: std.mem.Allocator, code: []const u8, detail: []const u8) tool.HandlerError![]u8 {
    const tool_error = @import("zag-agent-core").tool_error;
    _ = tool_error;
    // Simple format: the loop wraps this as a tool result.
    return std.fmt.allocPrint(allocator, "error: {s}\ndetail: {s}", .{ code, detail }) catch return error.OutOfMemory;
}

/// Default child turn budget for the `task` tool. Kept in sync with
/// `subagent_mod.SubagentRequest.max_turns` (both 20, matching the parent
/// loop's `default_max_turns`). Read-only recon (scout/reviewer) burns turns
/// on tool calls, so the old 10 was too tight and often ended on a
/// tool-call-only message with an empty final text.
const default_max_turns: u32 = 20;

/// Parse optional max_turns from arguments JSON (default 20, clamped 1..50).
fn parseMaxTurns(allocator: std.mem.Allocator, arguments_json: []const u8) !u32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return default_max_turns;
    defer parsed.deinit();
    if (parsed.value != .object) return default_max_turns;
    const val = parsed.value.object.get("max_turns") orelse return default_max_turns;
    if (val != .integer) return default_max_turns;
    const v: u32 = @intCast(@max(1, @min(50, val.integer)));
    return v;
}

/// Monotonic milliseconds for the registry timestamps.
fn nowMs() u64 {
    return @import("zag-types").monoNowNs() / std.time.ns_per_ms;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parseMaxTurns defaults to 20" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 20), try parseMaxTurns(gpa, "{}"));
    try std.testing.expectEqual(@as(u32, 20), try parseMaxTurns(gpa, "not-json"));
}

test "parseMaxTurns clamps to 1..50" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 5), try parseMaxTurns(gpa, "{\"max_turns\":5}"));
    try std.testing.expectEqual(@as(u32, 1), try parseMaxTurns(gpa, "{\"max_turns\":0}"));
    try std.testing.expectEqual(@as(u32, 50), try parseMaxTurns(gpa, "{\"max_turns\":100}"));
}

test "formatResult includes type, status, turns, output" {
    const gpa = std.testing.allocator;
    const result: subagent_mod.SubagentResult = .{
        .success = true,
        .output = "Found 3 files",
        .subagent_type = .scout,
        .turns = 2,
        .stop_reason = "completed",
    };
    const body = try formatResult(gpa, result);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "scout") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Found 3 files") != null);
}

test "makeTaskTool wires state and handler" {
    var apply_state: edit_tools.ApplyHunkState = .{};
    var state: TaskToolState = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .provider = undefined,
        .redactor = undefined,
        .apply_hunk_state = &apply_state,
    };
    const t = makeTaskTool(&state);
    try std.testing.expectEqualStrings("task", t.name());
    try std.testing.expect(t.handler == handleTask);
    try std.testing.expect(t.instance == @as(?*anyopaque, @ptrCast(&state)));
}