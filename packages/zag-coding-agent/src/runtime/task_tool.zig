//! `task` tool handler — model-facing subagent dispatch (subagents-001 + P1 async).
//!
//! Default path is **background**: the handler records a running registry
//! entry, spawns a detached OS thread that runs `subagent.spawn`, and returns
//! immediately with `status: started`. The parent agent loop is no longer
//! blocked for the child's entire lifetime — the TUI stays interactive.
//!
//! Optional `"await": true` keeps the old synchronous path for tests and
//! callers that need the full child output in the same tool result.
//!
//! When the model calls `task`, the handler:
//! 1. parses prompt + description + subagent_type + max_turns [+ await]
//! 2. checks depth (MAX_SUBAGENT_DEPTH=1)
//! 3. records the subagent in the registry (running)
//! 4a. await=false (default): start background thread → return "started"
//! 4b. await=true: spawn() synchronously → return full result body
//! 5. background path finishes via Registry.finishEntry + optional wake

const std = @import("std");
const builtin = @import("builtin");

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

const core = @import("zag-agent-core");
const tool = core.tool;
const subagent_mod = @import("../subagent.zig");
const permissions = @import("../permissions.zig");
const redact_mod = @import("../redact.zig");
const shell_policy_mod = @import("../shell_policy.zig");
const edit_tools = @import("edit_tools.zig");

/// Optional UI wake callback (TUI sets this so paint runs when a child finishes).
pub const WakeFn = *const fn (?*anyopaque) void;

/// Agent-owned heap-stable state for the `task` tool.
pub const TaskToolState = struct {
    gpa: std.mem.Allocator,
    /// Used only for the await=true path; background workers own Io.Threaded.
    io: std.Io,
    provider: core.provider.Provider,
    redactor: *const redact_mod.Redactor,
    permission_mode: permissions.Mode = .ask,
    shell_policy_mode: shell_policy_mod.Mode = .protect,
    parent_depth: u32 = 0,
    apply_hunk_state: *edit_tools.ApplyHunkState,
    registry: ?*subagent_mod.Registry = null,
    wake_fn: ?WakeFn = null,
    wake_ctx: ?*anyopaque = null,
    bg_mutex: std.atomic.Mutex = .unlocked,
    bg_jobs: std.ArrayList(*BgJob) = .empty,
};

/// Heap job for one background subagent. Worker owns and frees it.
pub const BgJob = struct {
    gpa: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    prompt: []u8,
    description: []u8,
    id: []u8,
    subagent_type: subagent_mod.SubagentType,
    max_turns: u32,
    parent_depth: u32,
    permission_mode: permissions.Mode,
    shell_policy_mode: shell_policy_mod.Mode,
    provider: core.provider.Provider,
    redactor: *const redact_mod.Redactor,
    apply_hunk_state: edit_tools.ApplyHunkState = .{},
    registry: ?*subagent_mod.Registry,
    reg_idx: ?usize,
    wake_fn: ?WakeFn,
    wake_ctx: ?*anyopaque,
    owner: *TaskToolState,
};

pub const task_def = subagent_mod.task_def;
pub const task_descriptor = subagent_mod.task_descriptor;

pub fn makeTaskTool(state: *TaskToolState) tool.Tool {
    return .{
        .descriptor = subagent_mod.task_descriptor,
        .instance = state,
        .handler = handleTask,
    };
}

/// Wait until all detached background jobs have unregistered (Agent.deinit).
pub fn joinBackground(state: *TaskToolState) void {
    // Detached workers unregister themselves; wait until none remain.
    var spins: u64 = 0;
    while (true) {
        spinLock(&state.bg_mutex);
        const n = state.bg_jobs.items.len;
        state.bg_mutex.unlock();
        if (n == 0) break;
        std.atomic.spinLoopHint();
        spins +|= 1;
        // Safety: never hang deinit forever in tests if a worker stuck.
        if (spins > 10_000_000) break;
    }
    spinLock(&state.bg_mutex);
    // Free any straggler pointers without joining (detached); drop list storage.
    state.bg_jobs.clearRetainingCapacity();
    state.bg_jobs.deinit(state.gpa);
    state.bg_jobs = .empty;
    state.bg_mutex.unlock();
}

pub fn handleTask(
    ctx: tool.Context,
    instance: ?*anyopaque,
    arguments_json: []const u8,
) tool.HandlerError![]u8 {
    const state: *TaskToolState = @ptrCast(@alignCast(instance.?));

    const prompt = tool.requireStringField(ctx.allocator, arguments_json, "prompt") catch
        return softError(ctx.allocator, "invalid_arguments", "missing or invalid 'prompt' field");
    defer ctx.allocator.free(prompt);

    const description = tool.requireStringField(ctx.allocator, arguments_json, "description") catch
        return softError(ctx.allocator, "invalid_arguments", "missing or invalid 'description' field");
    defer ctx.allocator.free(description);

    const type_str = tool.optionalStringField(ctx.allocator, arguments_json, "subagent_type") catch
        return softError(ctx.allocator, "invalid_arguments", "invalid 'subagent_type' field");
    defer if (type_str) |s| ctx.allocator.free(s);

    const subagent_type: subagent_mod.SubagentType = if (type_str) |s|
        subagent_mod.SubagentType.fromString(s) orelse .task
    else
        .task;

    const max_turns: u32 = parseMaxTurns(ctx.allocator, arguments_json) catch default_max_turns;
    const await_completion = parseAwait(ctx.allocator, arguments_json);

    if (prompt.len == 0) return softError(ctx.allocator, "invalid_arguments", "prompt must not be empty");
    if (description.len == 0) return softError(ctx.allocator, "invalid_arguments", "description must not be empty");

    if (!subagent_mod.depthAllowed(state.parent_depth)) {
        return softError(ctx.allocator, "depth_exceeded", "max subagent nesting depth (1) exceeded; a subagent cannot spawn further subagents");
    }

    var reg_idx: ?usize = null;
    if (state.registry) |reg| {
        reg_idx = reg.allocSlot();
        const entry = reg.get(reg_idx.?);
        reg.setIdentity(reg_idx.?, description) catch {};
        entry.subagent_type = subagent_type;
        entry.status = .running;
        entry.started_ms = nowMs();
        spinLock(&reg.mutex);
        reg.depth = state.parent_depth + 1;
        reg.active_count += 1;
        reg.mutex.unlock();
    }

    const spawn_id: []const u8 = blk: {
        if (reg_idx) |idx| {
            if (state.registry) |reg| {
                const id = reg.get(idx).id;
                if (id.len > 0) break :blk id;
            }
        }
        break :blk "task_call";
    };

    if (await_completion) {
        return spawnAwait(ctx.allocator, state, prompt, description, spawn_id, subagent_type, max_turns, reg_idx);
    }

    // Background path.
    const job = state.gpa.create(BgJob) catch {
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };

    const threaded = state.gpa.create(std.Io.Threaded) catch {
        state.gpa.destroy(job);
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };
    threaded.* = std.Io.Threaded.init(state.gpa, .{});

    const prompt_owned = state.gpa.dupe(u8, prompt) catch {
        threaded.deinit();
        state.gpa.destroy(threaded);
        state.gpa.destroy(job);
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };
    const desc_owned = state.gpa.dupe(u8, description) catch {
        state.gpa.free(prompt_owned);
        threaded.deinit();
        state.gpa.destroy(threaded);
        state.gpa.destroy(job);
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };
    const id_owned = state.gpa.dupe(u8, spawn_id) catch {
        state.gpa.free(desc_owned);
        state.gpa.free(prompt_owned);
        threaded.deinit();
        state.gpa.destroy(threaded);
        state.gpa.destroy(job);
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };

    job.* = .{
        .gpa = state.gpa,
        .threaded = threaded,
        .prompt = prompt_owned,
        .description = desc_owned,
        .id = id_owned,
        .subagent_type = subagent_type,
        .max_turns = max_turns,
        .parent_depth = state.parent_depth,
        .permission_mode = state.permission_mode,
        .shell_policy_mode = state.shell_policy_mode,
        .provider = state.provider,
        .redactor = state.redactor,
        .apply_hunk_state = .{},
        .registry = state.registry,
        .reg_idx = reg_idx,
        .wake_fn = state.wake_fn,
        .wake_ctx = state.wake_ctx,
        .owner = state,
    };

    spinLock(&state.bg_mutex);
    const append_ok = state.bg_jobs.append(state.gpa, job);
    state.bg_mutex.unlock();
    append_ok catch {
        destroyJob(job);
        failReg(state, reg_idx, "out_of_memory");
        return softError(ctx.allocator, "spawn_failed", "OutOfMemory");
    };

    const th = std.Thread.spawn(.{}, bgWorkerMain, .{job}) catch {
        unregisterJob(state, job);
        destroyJob(job);
        failReg(state, reg_idx, "thread_spawn_failed");
        return softError(ctx.allocator, "spawn_failed", "ThreadSpawnFailed");
    };
    th.detach();

    return std.fmt.allocPrint(
        ctx.allocator,
        \\status: started
        \\id: {s}
        \\subagent_type: {s}
        \\description: {s}
        \\max_turns: {d}
        \\
        \\The subagent is running in the background. Continue helping the user.
        \\Do not claim the subagent finished until a later status update appears.
        \\
    ,
        .{ spawn_id, subagent_type.name(), description, max_turns },
    ) catch return error.OutOfMemory;
}

fn spawnAwait(
    allocator: std.mem.Allocator,
    state: *TaskToolState,
    prompt: []const u8,
    description: []const u8,
    spawn_id: []const u8,
    subagent_type: subagent_mod.SubagentType,
    max_turns: u32,
    reg_idx: ?usize,
) tool.HandlerError![]u8 {
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
        .registry = state.registry,
        .reg_idx = reg_idx,
        .wake_fn = state.wake_fn,
        .wake_ctx = state.wake_ctx,
    };

    const result = subagent_mod.spawn(spawn_ctx) catch |err| {
        failReg(state, reg_idx, @errorName(err));
        return softError(allocator, "spawn_failed", @errorName(err));
    };

    if (reg_idx) |idx| {
        if (state.registry) |reg| {
            const st: subagent_mod.Status = if (result.success)
                .completed
            else if (std.mem.eql(u8, result.stop_reason, "cancelled"))
                .cancelled
            else
                .failed;
            reg.finishEntry(idx, st, result.turns, result.output, result.error_message);
        }
    }

    const body = formatResult(allocator, result);
    if (result.output.len > 0) state.gpa.free(result.output);
    return body;
}

fn bgWorkerMain(job: *BgJob) void {
    defer {
        unregisterJob(job.owner, job);
        destroyJob(job);
    }

    const io = job.threaded.io();
    const request: subagent_mod.SubagentRequest = .{
        .id = job.id,
        .prompt = job.prompt,
        .description = job.description,
        .subagent_type = job.subagent_type,
        .max_turns = job.max_turns,
        .parent_depth = job.parent_depth,
    };
    const spawn_ctx: subagent_mod.SpawnContext = .{
        .gpa = job.gpa,
        .io = io,
        .provider = job.provider,
        .parent_redactor = job.redactor,
        .permission_mode = job.permission_mode,
        .shell_policy_mode = job.shell_policy_mode,
        .parent_depth = job.parent_depth,
        .apply_hunk_state = &job.apply_hunk_state,
        .request = request,
        .registry = job.registry,
        .reg_idx = job.reg_idx,
        .wake_fn = job.wake_fn,
        .wake_ctx = job.wake_ctx,
    };

    const result = subagent_mod.spawn(spawn_ctx) catch |err| {
        if (job.reg_idx) |idx| {
            if (job.registry) |reg| {
                reg.finishEntry(idx, .failed, 0, "", @errorName(err));
            }
        }
        if (job.wake_fn) |wf| wf(job.wake_ctx);
        return;
    };

    if (job.reg_idx) |idx| {
        if (job.registry) |reg| {
            const st: subagent_mod.Status = if (result.success)
                .completed
            else if (std.mem.eql(u8, result.stop_reason, "cancelled"))
                .cancelled
            else
                .failed;
            reg.finishEntry(idx, st, result.turns, result.output, result.error_message);
        }
    }
    if (result.output.len > 0) job.gpa.free(result.output);
    if (job.wake_fn) |wf| wf(job.wake_ctx);
}

fn unregisterJob(state: *TaskToolState, job: *BgJob) void {
    spinLock(&state.bg_mutex);
    defer state.bg_mutex.unlock();
    for (state.bg_jobs.items, 0..) |j, i| {
        if (j == job) {
            _ = state.bg_jobs.orderedRemove(i);
            break;
        }
    }
}

fn destroyJob(job: *BgJob) void {
    const gpa = job.gpa;
    gpa.free(job.prompt);
    gpa.free(job.description);
    gpa.free(job.id);
    job.threaded.deinit();
    gpa.destroy(job.threaded);
    gpa.destroy(job);
}

fn failReg(state: *TaskToolState, reg_idx: ?usize, err_name: []const u8) void {
    if (reg_idx) |idx| {
        if (state.registry) |reg| {
            reg.finishEntry(idx, .failed, 0, "", err_name);
        }
    }
}

const max_output_bytes: usize = 8 * 1024;

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

fn softError(allocator: std.mem.Allocator, code: []const u8, detail: []const u8) tool.HandlerError![]u8 {
    return std.fmt.allocPrint(allocator, "error: {s}\ndetail: {s}", .{ code, detail }) catch return error.OutOfMemory;
}

const default_max_turns: u32 = 20;

fn parseMaxTurns(allocator: std.mem.Allocator, arguments_json: []const u8) !u32 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return default_max_turns;
    defer parsed.deinit();
    if (parsed.value != .object) return default_max_turns;
    const val = parsed.value.object.get("max_turns") orelse return default_max_turns;
    if (val != .integer) return default_max_turns;
    const v: u32 = @intCast(@max(1, @min(50, val.integer)));
    return v;
}

fn parseAwait(allocator: std.mem.Allocator, arguments_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const val = parsed.value.object.get("await") orelse return false;
    return switch (val) {
        .bool => |b| b,
        else => false,
    };
}

fn nowMs() u64 {
    return @import("zag-types").monoNowNs() / std.time.ns_per_ms;
}

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

test "parseAwait defaults false" {
    const gpa = std.testing.allocator;
    try std.testing.expect(!parseAwait(gpa, "{}"));
    try std.testing.expect(parseAwait(gpa, "{\"await\":true}"));
    try std.testing.expect(!parseAwait(gpa, "{\"await\":false}"));
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
