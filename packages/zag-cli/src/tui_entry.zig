//! Thin CLI adapter for zag-tui (only compiled when -Dtui=true).
//! Implements SignalHost over sigint.Guard. Does not own TUI widgets.
//!
//! Teardown is **explicit** (no reliance on defer across process.exit):
//!   ack → restore(in App.run) → App.quiesce → Guard.deinit → Session.deinit
//!   → Agent.deinit → App.destroy (App last)
//! Caller must not double-deinit Guard when `guard_deinited` is true.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const coding = @import("zag-coding-agent");
const zag_tui = @import("zag-tui");
const sigint = @import("sigint.zig");

pub const App = zag_tui.App;
pub const SignalHost = zag_tui.SignalHost;
pub const OpenDisplay = zag_tui.OpenDisplay;
pub const TeardownProbe = zag_tui.TeardownProbe;

pub const GuardSignalHost = struct {
    guard: *sigint.Guard,

    pub fn asHost(self: *GuardSignalHost) SignalHost {
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

    fn wakeFd(ptr: *anyopaque) posix.fd_t {
        const self: *GuardSignalHost = @ptrCast(@alignCast(ptr));
        return self.guard.read_fd;
    }

    fn drainWake(ptr: *anyopaque) void {
        const self: *GuardSignalHost = @ptrCast(@alignCast(ptr));
        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.guard.read_fd, &buf) catch break;
            if (n == 0) break;
        }
    }

    fn pendingInterrupt(ptr: *anyopaque) bool {
        const self: *GuardSignalHost = @ptrCast(@alignCast(ptr));
        return self.guard.pendingInterrupt();
    }

    fn acknowledgeCancel(ptr: *anyopaque) void {
        const self: *GuardSignalHost = @ptrCast(@alignCast(ptr));
        self.guard.acknowledgeCancel();
    }
};

pub const HostResourceOptions = struct {
    skills_enabled: bool = true,
    project_skills_trust: coding.ProjectSkillsTrust = .untrusted,
    user_skills_root: ?[]const u8 = null,
    templates_enabled: bool = true,
    project_templates_trust: coding.ProjectTemplatesTrust = .untrusted,
    user_templates_root: ?[]const u8 = null,
    theme: zag_tui.ThemeHostOptions = .{},
    model_label: []const u8 = "—",
    model_ids: []const []const u8 = &.{},
};

pub const RunArgs = struct {
    gpa: std.mem.Allocator,
    io: Io,
    app: *App,
    agent: *coding.Agent,
    guard: *sigint.Guard,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
    host_opts: HostResourceOptions,
    base_system: []const u8,
    permission_label: []const u8,
    shell_label: []const u8,
    /// Optional test probe; product null.
    teardown_probe: ?*TeardownProbe = null,
};

pub const RunResult = struct {
    exit_code: u8,
    /// Guard.deinit already performed — caller must not deinit again.
    guard_deinited: bool = false,
    /// Session already deinitialized inside runTui.
    session_deinited: bool = true,
};

/// Full product TUI path after App prealloc + Agent.init + Guard.install.
/// Explicitly deinitializes Guard and Session; leaves Agent + App to caller.
pub fn runTui(args: RunArgs) RunResult {
    const gpa = args.gpa;
    const io = args.io;
    const app = args.app;
    if (args.teardown_probe) |p| app.teardown_probe = p;

    if (terminalBelowMinimum()) {
        fixedStderr("tui: terminal too small (need ≥ 20×5)\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        return .{ .exit_code = 1, .guard_deinited = true };
    }

    var session = coding.Session.start(gpa, io, .{
        .base_system = args.base_system,
        .path = args.session_path,
        .open_mode = args.open_mode,
        .load_project_instructions = args.load_project,
        .redactor = args.agent.activeRedactor(),
        .skills_enabled = args.host_opts.skills_enabled,
        .project_skills_trust = args.host_opts.project_skills_trust,
        .user_skills_root = args.host_opts.user_skills_root,
        .templates_enabled = args.host_opts.templates_enabled,
        .project_templates_trust = args.host_opts.project_templates_trust,
        .user_templates_root = args.host_opts.user_templates_root,
    }) catch {
        fixedStderr("tui: session start failed\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        return .{ .exit_code = 1, .guard_deinited = true };
    };

    const redactor = session.activeRedactor() orelse {
        fixedStderr("tui: missing session redactor\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        if (args.teardown_probe) |p| p.note('S');
        session.deinit();
        return .{ .exit_code = 1, .guard_deinited = true };
    };

    var gsh = GuardSignalHost{ .guard = args.guard };
    const host = gsh.asHost();

    const open_disp: OpenDisplay = switch (args.open_mode) {
        .create_new => if (args.session_path == null) .n_a else .create_new,
        .resume_existing => .resume_existing,
        .open_or_create => .n_a,
    };
    const id = args.session_path orelse "ephemeral";
    // Path chrome: full redact pipeline with Session-owned redactor.
    app.setIdentity(gpa, redactor, id, open_disp, args.permission_label, args.shell_label);
    app.applyHostPresentation(io, args.host_opts.theme, args.host_opts.model_label, args.host_opts.model_ids);

    app.bind(args.agent, &session, redactor, host) catch {
        fixedStderr("tui: bind failed\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        if (args.teardown_probe) |p| p.note('S');
        session.deinit();
        return .{ .exit_code = 1, .guard_deinited = true };
    };

    const code = app.run();

    // §2.6.1 final — explicit order (App storage still live).
    host.acknowledgeCancel();
    app.quiesce();
    if (args.teardown_probe) |p| p.note('G');
    args.guard.deinit();
    if (args.teardown_probe) |p| p.note('S');
    session.deinit();
    return .{ .exit_code = code, .guard_deinited = true, .session_deinited = true };
}

fn terminalBelowMinimum() bool {
    const sz = zag_tui.terminal.windowSize(posix.STDOUT_FILENO) orelse return false;
    return sz.isBelowMinimum();
}

fn fixedStderr(msg: []const u8) void {
    _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
}

test "tui_entry GuardSignalHost vtable maps Guard" {
    try std.testing.expect(@TypeOf(GuardSignalHost.asHost) != void);
}
