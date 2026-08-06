//! §11 Implementation Gate matrix — named mapping (tui-minimal.md).
//! Non-vacuous: real workers, real redaction, real Agent where claimed.

const std = @import("std");
const coding = @import("zag-coding-agent");
const core = @import("zag-agent-core");
const zt = @import("zag-types");
const message = core.message;
const tool = core.tool;
const provider_mod = core.provider;
const app_mod = @import("app.zig");
const c = @import("constants.zig");
const present = @import("present.zig");
const cards = @import("cards.zig");
const permission = @import("permission.zig");
const terminal = @import("terminal.zig");
const signal_host = @import("signal_host.zig");

// ── mock provider ───────────────────────────────────────────────────────────

const MockChat = struct {
    calls: u32 = 0,
    mode: enum { text, text_with_secret, tool_write_then_text, fail } = .text,
    secret: []const u8 = "",
    /// Workspace-relative write path for tool_write_then_text (must stay under cwd jail).
    write_path: []const u8 = "gate21_payload.txt",

    fn chat(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        _: []const message.Message,
        _: []const tool.Definition,
        _: provider_mod.RequestControl,
    ) provider_mod.ChatError!message.AssistantTurn {
        const self: *MockChat = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        switch (self.mode) {
            .text => return .{
                .content = try arena.dupe(u8, "done"),
                .tool_calls = &.{},
                .finish_reason = "stop",
                .usage = .{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 15 },
            },
            .text_with_secret => {
                const body = try std.fmt.allocPrint(arena, "hello {s}", .{self.secret});
                return .{
                    .content = body,
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                    .usage = .{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 15 },
                };
            },
            .tool_write_then_text => {
                if (self.calls == 1) {
                    const calls = try arena.alloc(message.ToolCall, 1);
                    const secret = self.secret;
                    const path = self.write_path;
                    const args = if (secret.len > 0)
                        try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ path, secret })
                    else
                        try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"content\":\"y\"}}", .{path});
                    calls[0] = .{
                        .id = try std.fmt.allocPrint(arena, "call-{s}", .{if (secret.len > 0) secret else "c1"}),
                        .name = try arena.dupe(u8, "write_file"),
                        .arguments = args,
                    };
                    return .{
                        .content = try arena.dupe(u8, "working"),
                        .tool_calls = calls,
                        .finish_reason = "tool_calls",
                    };
                }
                return .{
                    .content = try std.fmt.allocPrint(arena, "after-tool {s}", .{self.secret}),
                    .tool_calls = &.{},
                    .finish_reason = "stop",
                };
            },
            .fail => return error.AuthenticationFailed,
        }
    }
};

fn mockProvider(state: *MockChat) provider_mod.Provider {
    return .{ .ptr = state, .vtable = &.{ .chat = MockChat.chat } };
}

const FakeHost = struct {
    ack_count: std.atomic.Value(u32) = .init(0),
    pending: std.atomic.Value(bool) = .init(false),
    wake_fd: std.posix.fd_t = -1,

    fn asHost(self: *FakeHost) signal_host.SignalHost {
        return .{
            .ptr = self,
            .vtable = &.{
                .wake_fd = wakeFd,
                .drain_wake = drainWake,
                .pending_interrupt = pendingInterrupt,
                .acknowledge_cancel = acknowledgeCancel,
            },
        };
    }
    fn wakeFd(ptr: *anyopaque) std.posix.fd_t {
        return @as(*FakeHost, @ptrCast(@alignCast(ptr))).wake_fd;
    }
    fn drainWake(_: *anyopaque) void {}
    fn pendingInterrupt(ptr: *anyopaque) bool {
        return @as(*FakeHost, @ptrCast(@alignCast(ptr))).pending.load(.acquire);
    }
    fn acknowledgeCancel(ptr: *anyopaque) void {
        const self: *FakeHost = @ptrCast(@alignCast(ptr));
        _ = self.ack_count.fetchAdd(1, .acq_rel);
        self.pending.store(false, .release);
    }
};

// ── §11 gates ───────────────────────────────────────────────────────────────

test "gate2_import_scan_no_cli_sigint" {
    const srcs = [_][]const u8{
        @embedFile("root.zig"),
        @embedFile("app.zig"),
        @embedFile("signal_host.zig"),
        @embedFile("present.zig"),
        @embedFile("cards.zig"),
        @embedFile("editor.zig"),
        @embedFile("permission.zig"),
        @embedFile("keys.zig"),
        @embedFile("terminal.zig"),
        @embedFile("render.zig"),
        @embedFile("layout.zig"),
        @embedFile("scrollback.zig"),
        @embedFile("constants.zig"),
    };
    for (srcs) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"zag-cli\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"sigint") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, "packages/zag-cli") == null);
    }
}

test "gate3_init_order_prealloc_before_raw" {
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    try std.testing.expect(!app.raw_entered);
    try std.testing.expect(app.editor_storage.len == c.editor_max_bytes);
}

test "gate4_missing_signal_host_bind_fails" {
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    try std.testing.expectEqual(@as(u8, 1), app.run());
}

test "gate6_real_worker_join_ack_success_and_error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();

    // Success run via real worker thread.
    {
        var mock: MockChat = .{};
        var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .hunk_reviewer = coding.autoAcceptHunkReviewer(),
            .lifecycle = app.lifecycleObserver(),
        });
        defer agent.deinit();
        var session = try coding.Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .redactor = agent.activeRedactor(),
            .skills_enabled = false,
            .templates_enabled = false,
        });
        defer session.deinit();
        try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());
        app.setIdentity(gpa, session.activeRedactor(), "ephemeral", .n_a, "yolo", "protect");

        _ = app.editor.insert("hi");
        try app.dispatchReply();
        // Join real worker.
        while (app.worker_active) {
            if (app.worker_finished.load(.acquire)) {
                if (app.worker) |*th| {
                    th.join();
                    app.worker = null;
                }
                app.afterWorkerJoin();
                break;
            }
            std.Thread.yield() catch {};
        }
        try std.testing.expectEqual(@as(u32, 1), host.ack_count.load(.acquire));
        try std.testing.expect(app.state == .idle);
    }

    // Error run.
    {
        host = FakeHost{};
        var mock: MockChat = .{ .mode = .fail };
        var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
            .permission_mode = .yolo,
            .lifecycle = app.lifecycleObserver(),
        });
        defer agent.deinit();
        var session = try coding.Session.start(gpa, io, .{
            .base_system = "sys",
            .load_project_instructions = false,
            .redactor = agent.activeRedactor(),
            .skills_enabled = false,
            .templates_enabled = false,
        });
        defer session.deinit();
        try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());
        _ = app.editor.insert("boom");
        try app.dispatchReply();
        while (app.worker_active) {
            if (app.worker_finished.load(.acquire)) {
                if (app.worker) |*th| {
                    th.join();
                    app.worker = null;
                }
                app.afterWorkerJoin();
                break;
            }
            std.Thread.yield() catch {};
        }
        try std.testing.expectEqual(@as(u32, 1), host.ack_count.load(.acquire));
        try std.testing.expect(app.state == .@"error");
    }
}

test "gate7_ack_between_two_real_runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var mock: MockChat = .{};
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .lifecycle = app.lifecycleObserver(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());

    var run_i: u32 = 0;
    while (run_i < 2) : (run_i += 1) {
        host.pending.store(true, .release);
        _ = app.editor.insert("x");
        try app.dispatchReply();
        while (app.worker_active) {
            if (app.worker_finished.load(.acquire)) {
                if (app.worker) |*th| {
                    th.join();
                    app.worker = null;
                }
                app.afterWorkerJoin();
                break;
            }
            std.Thread.yield() catch {};
        }
        try std.testing.expect(!host.pending.load(.acquire));
    }
    try std.testing.expectEqual(@as(u32, 2), host.ack_count.load(.acquire));
}

test "gate8a_teardown_probe_order_quiesce_before_app_free" {
    const gpa = std.testing.allocator;
    var steps: [8]u8 = undefined;
    var probe = app_mod.TeardownProbe{ .steps = &steps };
    const app = try app_mod.App.create(gpa);
    app.teardown_probe = &probe;
    app.quiesce();
    app.destroy();
    // Q then A
    try std.testing.expect(probe.len >= 2);
    try std.testing.expectEqual(@as(u8, 'Q'), probe.steps[0]);
    try std.testing.expectEqual(@as(u8, 'A'), probe.steps[probe.len - 1]);
}

test "gate8c_missing_bind_no_raw" {
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    _ = app.run();
    try std.testing.expect(!app.raw_entered);
}

test "gate11_lifecycle_real_agent_ordering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var mock: MockChat = .{};
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .lifecycle = app.lifecycleObserver(),
        .observer = app.observer(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());
    _ = try agent.reply(&session, "hi");
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_start = false;
    var saw_terminal = false;
    var assistant_cards: u32 = 0;
    for (snap[0..n]) |slot| {
        // tui-polish-001 compaction: run_start no longer publishes a card
        // (header cfg + state:busy surface it).
        if (std.mem.eql(u8, slot.titleSlice(), "run_start")) saw_start = true;
        if (std.mem.eql(u8, slot.titleSlice(), "run_terminal")) saw_terminal = true;
        if (std.mem.startsWith(u8, slot.titleSlice(), "assistant")) assistant_cards += 1;
    }
    try std.testing.expect(!saw_start);
    try std.testing.expect(saw_terminal);
    // Observer must not create a second distinct assistant identity card.
    try std.testing.expect(assistant_cards <= 1);
}

test "gate12_end_only_tool_end_via_lifecycle_emit" {
    // Product path for end-only is loop-driven; lifecycle adapter projection is
    // exercised here with the public event shape (no fabricated tool_start).
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    app.redactor = &r;
    app_mod.App.lifecycleObserver(app).emit(.{
        .tool_end = .{
            .turn = 1,
            .call_index = 0,
            .id = "x",
            .name = "write_file",
            .body = "cancelled",
        },
    });
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    try std.testing.expect(n >= 1);
    // tui-polish-001 compaction: end-only emit publishes the merged row title.
    try std.testing.expectEqualStrings("tool write_file", snap[0].titleSlice());
    for (snap[0..n]) |s| {
        try std.testing.expect(!std.mem.startsWith(u8, s.titleSlice(), "tool start"));
    }
}

test "gate13b_tool_pair_merges_to_one_row" {
    // tool_start + tool_end pair → exactly ONE `tool {name}` row; the live
    // "tool start {name}" card is replaced (never a second final card).
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    app.redactor = &r;
    const obs = app_mod.App.lifecycleObserver(app);
    obs.emit(.{ .tool_start = .{
        .turn = 1,
        .call_index = 0,
        .id = "t1",
        .name = "write_file",
        .arguments = "{}",
    } });
    obs.emit(.{ .tool_end = .{
        .turn = 1,
        .call_index = 0,
        .id = "t1",
        .name = "write_file",
        .body = "ok=true",
    } });
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var tool_rows: u32 = 0;
    for (snap[0..n]) |s| {
        if (!s.occupied) continue;
        if (std.mem.startsWith(u8, s.titleSlice(), "tool ")) {
            tool_rows += 1;
            try std.testing.expectEqualStrings("tool write_file", s.titleSlice());
            try std.testing.expectEqualStrings("ok=true", s.bodySlice());
        }
        try std.testing.expect(!std.mem.startsWith(u8, s.titleSlice(), "tool start"));
    }
    try std.testing.expectEqual(@as(u32, 1), tool_rows);
}

test "gate13c_control_applied_publishes_no_card" {
    // Steering/follow-up are surfaced by the header S:/F: counters; the
    // lifecycle event must not add transcript noise.
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    app.redactor = &r;
    app_mod.App.lifecycleObserver(app).emit(.{
        .control_applied = .{
            .kind = .steering,
            .next_turn = 1,
            .text = "go on",
        },
    });
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "gate13_open_tool_plus_terminal_truth" {
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    app.redactor = &r;
    const obs = app_mod.App.lifecycleObserver(app);
    obs.emit(.{ .tool_start = .{
        .turn = 1,
        .call_index = 0,
        .id = "t1",
        .name = "run_shell",
        .arguments = "{}",
    } });
    obs.emit(.{ .run_terminal = .{
        .turns = 1,
        .ok = false,
        .stop_reason = .cancelled,
        .usage = .{},
    } });
    try std.testing.expect(app.card_ring.slots[cards.CardRing.terminal_idx].occupied);
    const body = app.card_ring.slots[cards.CardRing.terminal_idx].bodySlice();
    try std.testing.expect(std.mem.indexOf(u8, body, "ok=false") != null);
}

test "gate15_permission_worker_wait_ui_decide" {
    const gpa = std.testing.allocator;
    var slot = permission.PermissionSlot{};
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    const desc = coding.permissions.testDescriptor("write_file", .write);

    const Ctx = struct {
        slot: *permission.PermissionSlot,
        woke: std.atomic.Value(bool) = .init(false),
        result: coding.permissions.Decision = .deny,
    };
    var ctx = Ctx{ .slot = &slot };
    const Wake = struct {
        fn f(p: *anyopaque) void {
            @as(*Ctx, @ptrCast(@alignCast(p))).woke.store(true, .release);
        }
    };

    const worker = try std.Thread.spawn(.{}, struct {
        fn run(s: *permission.PermissionSlot, red: *const coding.redact.Redactor, wctx: *Ctx, d: zt.ToolDescriptor, alloc: std.mem.Allocator) void {
            wctx.result = s.ask(alloc, red, true, d, "{}", Wake.f, wctx);
        }
    }.run, .{ &slot, &r, &ctx, desc, gpa });

    // UI/main thread waits for wake then decides allow.
    var spins: u32 = 0;
    while (!ctx.woke.load(.acquire)) : (spins += 1) {
        if (spins > 100_000) return error.TestUnexpectedResult;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(slot.snapshot().pending);
    slot.decide(.allow);
    worker.join();
    try std.testing.expectEqual(coding.permissions.Decision.allow, ctx.result);
}

test "gate15b_permission_cancel_deny_wakes_worker" {
    const gpa = std.testing.allocator;
    var slot = permission.PermissionSlot{};
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    const desc = coding.permissions.testDescriptor("write_file", .write);
    const Ctx = struct {
        slot: *permission.PermissionSlot,
        woke: std.atomic.Value(bool) = .init(false),
        result: coding.permissions.Decision = .allow,
    };
    var ctx = Ctx{ .slot = &slot };
    const Wake = struct {
        fn f(p: *anyopaque) void {
            @as(*Ctx, @ptrCast(@alignCast(p))).woke.store(true, .release);
        }
    };
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(s: *permission.PermissionSlot, red: *const coding.redact.Redactor, wctx: *Ctx, d: zt.ToolDescriptor, alloc: std.mem.Allocator) void {
            wctx.result = s.ask(alloc, red, true, d, "{}", Wake.f, wctx);
        }
    }.run, .{ &slot, &r, &ctx, desc, gpa });
    while (!ctx.woke.load(.acquire)) std.Thread.yield() catch {};
    slot.denyAndClose();
    worker.join();
    try std.testing.expectEqual(coding.permissions.Decision.deny, ctx.result);
}

test "gate16_busy_locks_root_submit_single_flight" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var mock: MockChat = .{};
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .lifecycle = app.lifecycleObserver(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());
    app.worker_active = true;
    app.state = .busy;
    _ = app.editor.insert("second");
    try std.testing.expectError(error.Busy, app.dispatchReply());
}

test "gate19_control_queue_retained_after_error_join" {
    // afterWorkerJoin must NOT clearControlQueues (cancel/error retention).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var mock: MockChat = .{ .mode = .fail };
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .lifecycle = app.lifecycleObserver(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());

    // Real error worker join, then enqueue post-join (survives idle).
    _ = app.editor.insert("x");
    try app.dispatchReply();
    while (app.worker_active) {
        if (app.worker_finished.load(.acquire)) {
            if (app.worker) |*th| {
                th.join();
                app.worker = null;
            }
            app.afterWorkerJoin();
            break;
        }
        std.Thread.yield() catch {};
    }
    try session.enqueueSteering("keep-me");
    try session.enqueueFollowUp("also-keep");
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), session.followUpPending());
    // Simulate another join boundary — must not clear.
    app.worker_active = true;
    app.afterWorkerJoin();
    try std.testing.expectEqual(@as(usize, 1), session.steeringPending());
    try std.testing.expectEqual(@as(usize, 1), session.followUpPending());
}

/// Exclusive, run-unique cwd-relative workspace for gate21 (cwd jail; no chdir).
/// Uses single-level `createDir` (fails with PathAlreadyExists) — never pre-deletes.
/// Retries a fresh CSPRNG name on collision so concurrent gate21 processes cannot
/// claim or delete each other's trees.
fn createExclusiveGate21Workspace(io: std.Io, name_buf: *[80]u8) ![]const u8 {
    const Io = std.Io;
    var rng_src = std.Random.IoSource{ .io = io };
    const rng = rng_src.interface();
    var attempt: u8 = 0;
    while (attempt < 32) : (attempt += 1) {
        const token = rng.int(u128);
        const name = try std.fmt.bufPrint(name_buf, ".zag-test-tui-gate21-{x:0>32}", .{token});
        Io.Dir.cwd().createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return name;
    }
    return error.PathAlreadyExists;
}

fn panicGate21Cleanup(path: []const u8, err: anyerror) noreturn {
    std.debug.panic("gate21: failed to remove owned workspace '{s}': {s}", .{ path, @errorName(err) });
}

test "gate21_all_field_secret_redaction" {
    // Real Agent + write_file (yolo/AutoAccept) + lifecycle redaction coverage.
    // Agent tools always use Io.Dir.cwd() (no workspace-root override on product
    // Options). Isolate the real write under a run-unique exclusive relative dir
    // owned only after createDir succeeds — no pre-delete, no global chdir.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = coding.redact.testing.fake_api_key;
    const Io = std.Io;

    var ws_name_buf: [80]u8 = undefined;
    var write_rel_buf: [112]u8 = undefined;
    // Ownership only after exclusive create; defer cleans this path only.
    var owned_ws: ?[]const u8 = null;
    defer {
        if (owned_ws) |path| {
            Io.Dir.cwd().deleteTree(io, path) catch |err| panicGate21Cleanup(path, err);
            if (Io.Dir.cwd().access(io, path, .{})) |_| {
                std.debug.panic("gate21: owned workspace still present after cleanup: {s}", .{path});
            } else |_| {}
        }
    }

    const ws_dir = try createExclusiveGate21Workspace(io, &ws_name_buf);
    owned_ws = ws_dir;
    const write_rel = try std.fmt.bufPrint(&write_rel_buf, "{s}/gate21_payload.txt", .{ws_dir});

    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    var mock: MockChat = .{
        .mode = .tool_write_then_text,
        .secret = secret,
        .write_path = write_rel,
    };
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .secrets = &.{secret},
        .lifecycle = app.lifecycleObserver(),
        .hunk_reviewer = coding.autoAcceptHunkReviewer(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());
    app.setIdentity(gpa, session.activeRedactor(), "path-" ++ secret, .create_new, "yolo", "protect");
    try std.testing.expect(std.mem.indexOf(u8, app.idDisplay(), secret) == null);

    // Tool path + assistant path via real reply (write_file into owned workspace).
    _ = try agent.reply(&session, "do it");

    // Isolation proof: tool args target this run's unique relative workspace,
    // and the real write landed only there (no bare-cwd x.txt probe — user may
    // already have that name; uniqueness of owned path is the evidence).
    try std.testing.expect(std.mem.eql(u8, mock.write_path, write_rel));
    try std.testing.expect(std.mem.startsWith(u8, write_rel, ws_dir));
    try std.testing.expect(std.mem.indexOf(u8, write_rel, "/") != null);
    try Io.Dir.cwd().access(io, write_rel, .{});
    try Io.Dir.cwd().access(io, ws_dir, .{});

    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    try std.testing.expect(n > 0);
    var saw_tool = false;
    var saw_assistant = false;
    for (snap[0..n]) |slot| {
        try std.testing.expect(std.mem.indexOf(u8, slot.titleSlice(), secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, slot.bodySlice(), secret) == null);
        if (std.mem.startsWith(u8, slot.titleSlice(), "tool ")) saw_tool = true;
        if (std.mem.startsWith(u8, slot.titleSlice(), "assistant")) saw_assistant = true;
    }
    try std.testing.expect(saw_tool);
    try std.testing.expect(saw_assistant);

    // Success-path cleanup: remove owned tree, assert gone, drop ownership so
    // defer is a no-op. Fail the test if residual secret-bearing files remain.
    try Io.Dir.cwd().deleteTree(io, ws_dir);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, write_rel, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, ws_dir, .{}));
    owned_ws = null;
}

test "gate26_ask_hunk_reviewer_null_option" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mock: MockChat = .{};
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .ask,
        .permission_gate = coding.permissions.Gate.denyAllDangerous(),
        .hunk_reviewer = null,
    });
    defer agent.deinit();
    try std.testing.expect(agent.options.hunk_reviewer == null);
}

test "gate27_yolo_autoaccept_bind" {
    const auto = coding.autoAcceptHunkReviewer();
    const d = auto.reviewFn(null, .{
        .path = "p",
        .old_len = 0,
        .new_len = 0,
        .expected_sha256 = "0" ** 64,
        .preview_text = "",
    });
    try std.testing.expectEqual(coding.HunkReviewDecision.accept, d);
}

test "gate30_geometry_below_minimum" {
    try std.testing.expect((terminal.Size{ .cols = 19, .rows = 4 }).isBelowMinimum());
}

test "gate31_signal_host_ack_vtable" {
    var host = FakeHost{ .pending = .init(true) };
    const sh = host.asHost();
    try std.testing.expect(sh.pendingInterrupt());
    sh.acknowledgeCancel();
    try std.testing.expect(!sh.pendingInterrupt());
}

test "gate_host_fatal_sticky_not_cleared_by_success_state" {
    const gpa = std.testing.allocator;
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    app.markHostFatal(1);
    try std.testing.expect(app.host_fatal);
    try std.testing.expectEqual(@as(u8, 1), app.sticky_exit);
    // Worker success path must not clear sticky_exit.
    app.state = .idle;
    try std.testing.expectEqual(@as(u8, 1), app.sticky_exit);
}

test "gate_constants_frozen" {
    try std.testing.expectEqual(@as(usize, 128), c.card_slots);
    try std.testing.expectEqualStrings("...[truncated]", c.truncation_marker);
}

test "gate_submit_publishes_user_card_in_transcript" {
    // tui-polish follow-up: the submitted input appears as a user card in
    // the transcript, paired with the assistant reply that follows
    // (Grok-style input/output correspondence).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var host = FakeHost{};
    const app = try app_mod.App.create(gpa);
    defer app.destroy();

    var mock: MockChat = .{};
    var agent = try coding.Agent.init(gpa, io, mockProvider(&mock), .{
        .permission_mode = .yolo,
        .hunk_reviewer = coding.autoAcceptHunkReviewer(),
        .lifecycle = app.lifecycleObserver(),
    });
    defer agent.deinit();
    var session = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = agent.activeRedactor(),
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer session.deinit();
    try app.bind(&agent, &session, session.activeRedactor().?, host.asHost());

    _ = app.editor.insert("hello user card");
    try app.dispatchReply();
    // Join real worker.
    while (app.worker_active) {
        if (app.worker_finished.load(.acquire)) {
            if (app.worker) |*th| {
                th.join();
                app.worker = null;
            }
            app.afterWorkerJoin();
            break;
        }
        std.Thread.yield() catch {};
    }

    // The transcript ring carries the user card with the raw submitted text.
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_user = false;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const slot = &snap[i];
        if (slot.occupied and slot.kind == .user) {
            saw_user = true;
            try std.testing.expectEqualStrings("user", slot.titleSlice());
            try std.testing.expectEqualStrings("hello user card", slot.bodySlice());
        }
    }
    try std.testing.expect(saw_user);
}

// expose markHostFatal for test — need pub
// (added as pub in app.zig)

// ── tui-markdown-001 fixtures: streaming equivalence + redaction ──────────

const md_parse = @import("md_parse.zig");
const md_render = @import("md_render.zig");
const theme = @import("theme.zig");
const vaxis = @import("vaxis");

/// Newest occupied assistant-progressive card (tui-streaming identity).
fn newestAssistantCard(app: *app_mod.App) ?cards.CardSlot {
    var snap: [c.card_slots]cards.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const slot = &snap[i];
        if (slot.occupied and std.mem.startsWith(u8, slot.titleSlice(), "assistant")) return slot.*;
    }
    return null;
}

/// Offscreen render context mirroring the app's paint path: parse through
/// md_parse (fallback → raw), render into a vaxis.Screen-backed window. The
/// arena must outlive the assertions (cell graphemes borrow koino Text
/// slices), exactly like Terminal.md_arena.
const RenderCtx = struct {
    screen: vaxis.Screen,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !RenderCtx {
        return .{
            .screen = try vaxis.Screen.init(gpa, .{
                .rows = rows,
                .cols = cols,
                .x_pixel = 0,
                .y_pixel = 0,
            }),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *RenderCtx, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        self.screen.deinit(gpa);
    }

    fn render(self: *RenderCtx, body: []const u8) void {
        _ = self.arena.reset(.retain_capacity);
        const win: vaxis.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = self.screen.width,
            .height = self.screen.height,
            .screen = &self.screen,
        };
        self.screen.clear();
        const palette = theme.builtinDefault();
        if (md_parse.parseMarkdown(self.arena.allocator(), body)) |doc| {
            _ = md_render.renderMarkdownInto(self.arena.allocator(), win, doc, &palette);
        } else {
            _ = md_render.renderRawIntoStyled(self.arena.allocator(), win, body, md_render.MdStyle.fromPalette(&palette));
        }
    }
};

fn expectScreensEqual(a: *const vaxis.Screen, b: *const vaxis.Screen) !void {
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    var row: u16 = 0;
    while (row < a.height) : (row += 1) {
        var col: u16 = 0;
        while (col < a.width) : (col += 1) {
            const ca = a.readCell(col, row) orelse return error.TestUnexpectedResult;
            const cb = b.readCell(col, row) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(ca.char.grapheme, cb.char.grapheme);
            try std.testing.expect(ca.style.eql(cb.style));
            try std.testing.expectEqualStrings(ca.link.uri, cb.link.uri);
        }
    }
}

test "tui-markdown: delta-accumulated card renders identically to one-shot" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .patterns = false });
    defer r.deinit();
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    app.redactor = &r;
    const obs = app.observer();

    // Deltas accumulate through the App.onObserver path (card identity rules:
    // progressive prefix, replace-newest-only, no finalized-card clobber).
    const chunks = [_][]const u8{
        "# Title\n\n",
        "Some **bold** text with `code` and [link](/u).\n\n",
        "- one\n- two\n\n",
        "> quoted\n",
    };
    for (chunks) |ch| obs.emit(.{ .assistant_delta = ch });

    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant progressive", card.titleSlice());
    // Accumulation is lossless: the card body equals the concatenated stream.
    var expect_buf: [512]u8 = undefined;
    var n: usize = 0;
    for (chunks) |ch| {
        @memcpy(expect_buf[n..][0..ch.len], ch);
        n += ch.len;
    }
    try std.testing.expectEqualStrings(expect_buf[0..n], card.bodySlice());

    // Final render (paint path on the accumulated card body) == one-shot
    // render of the same text — cell text, styles, and link URIs all match.
    var a = try RenderCtx.init(gpa, 80, 24);
    defer a.deinit(gpa);
    var b = try RenderCtx.init(gpa, 80, 24);
    defer b.deinit(gpa);
    a.render(card.bodySlice());
    b.render(expect_buf[0..n]);
    try expectScreensEqual(&a.screen, &b.screen);

    // The progressive card is FORMATTED markdown (heading accent+bold), not
    // raw "# Title" source.
    const h = a.screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("T", h.char.grapheme);
    try std.testing.expect(h.style.bold);
    switch (h.style.fg) {
        .index => |i| try std.testing.expectEqual(@as(u8, 3), i),
        else => return error.TestUnexpectedResult,
    }
}

test "tui-markdown: secret inside code block redacted before render" {
    const gpa = std.testing.allocator;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    const app = try app_mod.App.create(gpa);
    defer app.destroy();
    app.redactor = &r;
    const obs = app.observer();

    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "```\nconst key = \"{s}\";\n```\n", .{secret}) catch
        return error.TestUnexpectedResult;
    obs.emit(.{ .assistant_delta = body });
    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    // The card buffer — the renderer's input — is redacted before render.
    try std.testing.expect(std.mem.indexOf(u8, card.bodySlice(), secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, card.bodySlice(), coding.redact.marker) != null);

    var rc = try RenderCtx.init(gpa, 80, 24);
    defer rc.deinit(gpa);
    rc.render(card.bodySlice());

    // No raw secret leaks into any rendered row (render-from-redacted proves
    // the renderer never re-materializes the secret).
    var all_buf: [4096]u8 = undefined;
    var all_n: usize = 0;
    var row: u16 = 0;
    while (row < rc.screen.height) : (row += 1) {
        var row_buf: [256]u8 = undefined;
        var rn: usize = 0;
        var col: u16 = 0;
        while (col < rc.screen.width) : (col += 1) {
            const cell = rc.screen.readCell(col, row) orelse break;
            const g = cell.char.grapheme;
            if (rn + g.len <= row_buf.len) {
                @memcpy(row_buf[rn..][0..g.len], g);
                rn += g.len;
            }
        }
        try std.testing.expect(std.mem.indexOf(u8, row_buf[0..rn], secret) == null);
        if (all_n + rn <= all_buf.len) {
            @memcpy(all_buf[all_n..][0..rn], row_buf[0..rn]);
            all_n += rn;
        }
    }
    // The redaction marker is what the transcript shows instead.
    try std.testing.expect(std.mem.indexOf(u8, all_buf[0..all_n], coding.redact.marker) != null);
}
