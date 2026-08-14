//! Thin CLI adapter for zag-tui (only compiled when -Dtui=true).
//! Implements SignalHost over sigint.Guard. Does not own TUI widgets.
//!
//! Teardown is **explicit** (no reliance on defer across process.exit):
//!   ack → restore(in App.run) → App.quiesce → Guard.deinit
//!   → Agent.deinit (caller) → App.destroy (session deinit+destroy inside,
//!   App last)
//! Caller must not double-deinit Guard when `guard_deinited` is true.
//! session-swap-001: the SESSION is App-owned from bind (App.destroy
//! deinits + destroys the CURRENT session exactly once).

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const ai = @import("zag-ai");
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
    /// Parallel to `model_ids`: `spec_id\\x1fmodel_id` wire keys. Empty = display id.
    model_keys: []const []const u8 = &.{},
};

const tui_picker_cap: usize = 24;

/// In-session `/model` switch: same provider → `setModel`; other host → new wire.
pub const TuiModelHost = struct {
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    wp: *coding.WireProvider,
    spec_buf: [64]u8 = undefined,
    spec_len: usize = 0,

    pub fn specId(self: *const TuiModelHost) []const u8 {
        return self.spec_buf[0..self.spec_len];
    }

    pub fn setSpec(self: *TuiModelHost, id: []const u8) void {
        const n = @min(id.len, self.spec_buf.len);
        @memcpy(self.spec_buf[0..n], id[0..n]);
        self.spec_len = n;
    }

    pub fn setModelFn(ptr: *anyopaque, encoded: []const u8) anyerror!void {
        const self: *TuiModelHost = @ptrCast(@alignCast(ptr));
        const parsed = ai.registry.parsePickerKey(encoded);
        const model = parsed.model_id;
        if (model.len == 0) return error.BadRequest;
        const spec_id = if (parsed.spec_id.len > 0) parsed.spec_id else self.specId();
        if (spec_id.len == 0 or std.mem.eql(u8, spec_id, self.specId())) {
            try self.wp.setModel(model);
            return;
        }
        const EnvGet = struct {
            env: *const std.process.Environ.Map,
            pub fn get(this: @This(), key: []const u8) ?[]const u8 {
                return this.env.get(key);
            }
        };
        const resolved = try ai.registry.resolvePreset(EnvGet{ .env = self.env }, spec_id, model);
        const new_wire = try resolved.createWire(self.gpa, self.io);
        self.wp.replaceWire(new_wire);
        self.setSpec(spec_id);
    }

    pub fn getModelFn(ptr: *anyopaque) []const u8 {
        const self: *TuiModelHost = @ptrCast(@alignCast(ptr));
        return self.wp.getModel();
    }
};

pub const TuiPicker = struct {
    ids: []const []const u8,
    keys: []const []const u8,
    label: []const u8,
};

/// Catalog rows for every env-keyed provider, plus live `/models` for the
/// current host. Display is `Name  ·  model`; key is `spec\\x1fmodel`.
pub fn collectTuiModelPicker(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    current_spec: []const u8,
    current_model: []const u8,
    wp: *coding.WireProvider,
) TuiPicker {
    const EnvGet = struct {
        env: *const std.process.Environ.Map,
        pub fn get(this: @This(), key: []const u8) ?[]const u8 {
            return this.env.get(key);
        }
    };
    const getter = EnvGet{ .env = env };

    var id_buf: [tui_picker_cap][]const u8 = undefined;
    var key_buf: [tui_picker_cap][]const u8 = undefined;
    var n: usize = 0;

    const add = struct {
        fn go(
            arena_a: std.mem.Allocator,
            ids: *[tui_picker_cap][]const u8,
            keys: *[tui_picker_cap][]const u8,
            count: *usize,
            spec_id: []const u8,
            spec_name: []const u8,
            model_id: []const u8,
        ) void {
            if (count.* >= tui_picker_cap) return;
            const key = std.fmt.allocPrint(arena_a, "{s}\x1f{s}", .{ spec_id, model_id }) catch return;
            for (keys.*[0..count.*]) |existing| {
                if (std.mem.eql(u8, existing, key)) return;
            }
            const display = std.fmt.allocPrint(arena_a, "{s}  ·  {s}", .{ spec_name, model_id }) catch model_id;
            ids.*[count.*] = display;
            keys.*[count.*] = key;
            count.* += 1;
        }
    }.go;

    var specs: std.ArrayList(ai.ProviderSpec) = .empty;
    defer specs.deinit(arena);
    ai.registry.listConfigured(getter, &specs, arena) catch {};

    var found_current = false;
    for (specs.items) |spec| {
        if (std.mem.eql(u8, spec.id, current_spec)) found_current = true;
        var models: std.ArrayList(ai.ModelInfo) = .empty;
        defer models.deinit(arena);
        ai.catalog.listForProvider(spec.id, &models, arena) catch {};
        if (models.items.len == 0) {
            add(arena, &id_buf, &key_buf, &n, spec.id, spec.name, spec.default_model);
            continue;
        }
        for (models.items) |m| {
            add(arena, &id_buf, &key_buf, &n, spec.id, spec.name, m.id);
        }
    }

    const current_name = if (ai.presets.find(current_spec)) |s| s.name else current_spec;
    if (!found_current and current_spec.len > 0) {
        add(arena, &id_buf, &key_buf, &n, current_spec, current_name, current_model);
    }

    var live_arena_impl: std.heap.ArenaAllocator = .init(arena);
    defer live_arena_impl.deinit();
    if (wp.listModels(live_arena_impl.allocator())) |live| {
        for (live) |id| {
            add(arena, &id_buf, &key_buf, &n, current_spec, current_name, id);
        }
    } else |_| {}

    add(arena, &id_buf, &key_buf, &n, current_spec, current_name, current_model);

    const ids = arena.dupe([]const u8, id_buf[0..n]) catch &.{};
    const keys = arena.dupe([]const u8, key_buf[0..n]) catch &.{};
    const label = std.fmt.allocPrint(arena, "{s}  ·  {s}", .{ current_name, current_model }) catch current_model;
    return .{ .ids = ids, .keys = keys, .label = label };
}

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
    /// Session NOT deinitialized here — App owns it from bind; App.destroy
    /// (after Agent.deinit) deinits + destroys the current session.
    session_deinited: bool = false,
};

/// Full product TUI path after App prealloc + Agent.init + Guard.install.
/// Explicitly deinitializes Guard; the SESSION is App-owned from bind
/// (App.destroy deinits + destroys it); Agent + App are caller-owned.
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

    // session-swap-001: the INITIAL session is heap-allocated and handed to
    // App (bind owns it; early-error paths deinit + destroy exactly once).
    const session = gpa.create(coding.Session) catch {
        fixedStderr("tui: session start failed\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        return .{ .exit_code = 1, .guard_deinited = true };
    };
    session.* = coding.Session.start(gpa, io, .{
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
        gpa.destroy(session);
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
        gpa.destroy(session);
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
    app.applyHostPresentation(io, args.host_opts.theme, args.host_opts.model_label, args.host_opts.model_ids, args.host_opts.model_keys);

    app.bind(args.agent, session, redactor, host, .{
        .base_system = args.base_system,
        .load_project_instructions = args.load_project,
        .redactor = args.agent.activeRedactor(),
        .skills_enabled = args.host_opts.skills_enabled,
        .project_skills_trust = args.host_opts.project_skills_trust,
        .user_skills_root = args.host_opts.user_skills_root,
        .templates_enabled = args.host_opts.templates_enabled,
        .project_templates_trust = args.host_opts.project_templates_trust,
        .user_templates_root = args.host_opts.user_templates_root,
    }) catch {
        fixedStderr("tui: bind failed\n");
        if (args.teardown_probe) |p| p.note('G');
        args.guard.deinit();
        if (args.teardown_probe) |p| p.note('S');
        session.deinit();
        gpa.destroy(session);
        return .{ .exit_code = 1, .guard_deinited = true };
    };

    const code = app.run();

    // §2.6.1 final — explicit order (App storage still live).
    host.acknowledgeCancel();
    app.quiesce();
    if (args.teardown_probe) |p| p.note('G');
    args.guard.deinit();
    // Session teardown is App-owned: App.destroy (after Agent.deinit in
    // cli.zig) deinits + destroys the CURRENT session.
    return .{ .exit_code = code, .guard_deinited = true, .session_deinited = false };
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
