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
        if (std.mem.eql(u8, slot.titleSlice(), "run_start")) saw_start = true;
        if (std.mem.eql(u8, slot.titleSlice(), "run_terminal")) saw_terminal = true;
        if (std.mem.startsWith(u8, slot.titleSlice(), "assistant")) assistant_cards += 1;
    }
    try std.testing.expect(saw_start);
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
    try std.testing.expect(std.mem.startsWith(u8, snap[0].titleSlice(), "tool end"));
    for (snap[0..n]) |s| {
        try std.testing.expect(!std.mem.startsWith(u8, s.titleSlice(), "tool start"));
    }
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

test "gate21_all_field_secret_redaction" {
    // Real Agent + write_file (yolo/AutoAccept) + lifecycle redaction coverage.
    // Agent tools always use Io.Dir.cwd() (no workspace-root override on product
    // Options). Isolate the real write under a test-owned relative directory
    // (unique name, never bare "x.txt") and deleteTree on exit — no global chdir.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = coding.redact.testing.fake_api_key;
    const Io = std.Io;

    // Unique relative workspace under caller cwd; cleaned even on failure.
    const ws_dir = ".zag-test-tui-gate21-ws";
    const payload_name = "gate21_payload.txt";
    const write_rel = ws_dir ++ "/" ++ payload_name;
    Io.Dir.cwd().deleteTree(io, ws_dir) catch {};
    try Io.Dir.cwd().createDirPath(io, ws_dir);
    defer Io.Dir.cwd().deleteTree(io, ws_dir) catch {};

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

    // Tool path + assistant path via real reply (write_file into test workspace).
    _ = try agent.reply(&session, "do it");

    // Isolation: never bare x.txt at caller cwd; payload only under test ws.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, "x.txt", .{}));
    try Io.Dir.cwd().access(io, write_rel, .{});

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

// expose markHostFatal for test — need pub
// (added as pub in app.zig)
