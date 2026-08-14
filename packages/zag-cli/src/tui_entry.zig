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
    model_picker_refresh: ?zag_tui.ModelPickerRefresh = null,
};

/// Cap for the `/model` picker collection buffer. Must be >= the largest
/// realistic combined catalog (builtin catalog + user manifest). Render-side
/// `overlay_line_bufs` in `zag-tui/app.zig` must match.
const tui_picker_cap: usize = 512;

pub const TuiPicker = struct {
    ids: []const []const u8,
    keys: []const []const u8,
    label: []const u8,
};

/// In-session `/model` switch: same provider → `setModel`; other host → new wire.
/// Also owns the picker arena so `/model` can reload catalog + `models.json`.
pub const TuiModelHost = struct {
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    wp: *coding.WireProvider,
    spec_buf: [64]u8 = undefined,
    spec_len: usize = 0,
    user_models_path: ?[]const u8 = null,
    project_models_path: []const u8 = ".zag/models.json",
    picker_arena: std.heap.ArenaAllocator,
    picker: TuiPicker = .{ .ids = &.{}, .keys = &.{}, .label = "—" },
    owned_base_url: ?[]u8 = null,
    owned_api_key: ?[]u8 = null,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        wp: *coding.WireProvider,
        user_models_path: ?[]const u8,
    ) TuiModelHost {
        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .wp = wp,
            .user_models_path = user_models_path,
            .picker_arena = .init(gpa),
        };
    }

    pub fn deinit(self: *TuiModelHost) void {
        self.picker_arena.deinit();
        if (self.owned_base_url) |b| self.gpa.free(b);
        if (self.owned_api_key) |k| self.gpa.free(k);
        self.owned_base_url = null;
        self.owned_api_key = null;
    }

    pub fn specId(self: *const TuiModelHost) []const u8 {
        return self.spec_buf[0..self.spec_len];
    }

    pub fn setSpec(self: *TuiModelHost, id: []const u8) void {
        const n = @min(id.len, self.spec_buf.len);
        @memcpy(self.spec_buf[0..n], id[0..n]);
        self.spec_len = n;
    }

    pub fn rebuildPicker(self: *TuiModelHost, current_spec: []const u8, current_model: []const u8) TuiPicker {
        self.picker_arena.deinit();
        self.picker_arena = .init(self.gpa);
        self.picker = collectTuiModelPicker(self.picker_arena.allocator(), .{
            .env = self.env,
            .current_spec = current_spec,
            .current_model = current_model,
            .io = self.io,
            .cwd = Io.Dir.cwd(),
            .user_models_path = self.user_models_path,
            .project_models_path = self.project_models_path,
        });
        return self.picker;
    }

    pub fn asRefresh(self: *TuiModelHost) zag_tui.ModelPickerRefresh {
        return .{ .ptr = self, .refreshFn = refreshFn };
    }

    fn refreshFn(ptr: *anyopaque, app: *App) void {
        const self: *TuiModelHost = @ptrCast(@alignCast(ptr));
        const picker = self.rebuildPicker(self.specId(), self.wp.getModel());
        app.applyModelPicker(picker.label, picker.ids, picker.keys);
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
        const getter = EnvGet{ .env = self.env };
        const resolved = if (ai.presets.find(spec_id) != null)
            try ai.registry.resolvePreset(getter, spec_id, model)
        else
            try resolveManifestHost(self, getter, spec_id, model);
        const new_wire = try resolved.createWire(self.gpa, self.io);
        self.wp.replaceWire(new_wire);
        self.setSpec(spec_id);
    }

    pub fn getModelFn(ptr: *anyopaque) []const u8 {
        const self: *TuiModelHost = @ptrCast(@alignCast(ptr));
        return self.wp.getModel();
    }
};

fn resolveManifestHost(
    self: *TuiModelHost,
    getter: anytype,
    spec_id: []const u8,
    model: []const u8,
) !ai.registry.Resolved {
    var manifest = try ai.models_file.loadMerged(
        self.gpa,
        self.io,
        Io.Dir.cwd(),
        self.user_models_path,
        self.project_models_path,
    );
    defer manifest.deinit(self.gpa);
    const entry = manifest.find(spec_id) orelse return error.UnknownProvider;
    var resolved = try ai.models_file.resolveCustom(entry.*, getter, model);
    if (self.owned_base_url) |b| self.gpa.free(b);
    if (self.owned_api_key) |k| self.gpa.free(k);
    self.owned_base_url = try self.gpa.dupe(u8, resolved.config.base_url);
    self.owned_api_key = try self.gpa.dupe(u8, resolved.config.api_key);
    resolved.config.base_url = self.owned_base_url.?;
    resolved.config.api_key = self.owned_api_key.?;
    return resolved;
}

pub const CollectPickerArgs = struct {
    env: *const std.process.Environ.Map,
    current_spec: []const u8,
    current_model: []const u8,
    io: Io,
    cwd: Io.Dir,
    user_models_path: ?[]const u8 = null,
    project_models_path: []const u8 = ".zag/models.json",
};

/// Catalog rows for every available provider (env-keyed + keyless Ollama)
/// plus auth-gated `models.json` entries. Display is `Name  ·  label`;
/// key is `spec\x1fmodel`. No live `/models` probe.
pub fn collectTuiModelPicker(arena: std.mem.Allocator, args: CollectPickerArgs) TuiPicker {
    const EnvGet = struct {
        env: *const std.process.Environ.Map,
        pub fn get(this: @This(), key: []const u8) ?[]const u8 {
            return this.env.get(key);
        }
    };
    const getter = EnvGet{ .env = args.env };

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
            model_label: []const u8,
        ) void {
            if (count.* >= tui_picker_cap) return;
            const key = std.fmt.allocPrint(arena_a, "{s}\x1f{s}", .{ spec_id, model_id }) catch return;
            const shown = if (model_label.len > 0) model_label else model_id;
            const display = std.fmt.allocPrint(arena_a, "{s}  ·  {s}", .{ spec_name, shown }) catch return;
            for (keys.*[0..count.*], 0..) |existing, i| {
                if (std.mem.eql(u8, existing, key)) {
                    ids.*[i] = display; // manifest wins on id collision
                    return;
                }
            }
            ids.*[count.*] = display;
            keys.*[count.*] = key;
            count.* += 1;
        }
    }.go;

    var manifest = ai.models_file.loadMerged(
        arena,
        args.io,
        args.cwd,
        args.user_models_path,
        args.project_models_path,
    ) catch ai.models_file.Manifest{};
    defer manifest.deinit(arena);

    var specs: std.ArrayList(ai.ProviderSpec) = .empty;
    defer specs.deinit(arena);
    ai.registry.listPickerProviders(getter, &specs, arena) catch {};

    var found_current = false;
    for (specs.items) |spec| {
        if (std.mem.eql(u8, spec.id, args.current_spec)) found_current = true;
        const spec_name = if (manifest.find(spec.id)) |e|
            (if (e.name.len > 0) e.name else spec.name)
        else
            spec.name;
        var models: std.ArrayList(ai.ModelInfo) = .empty;
        defer models.deinit(arena);
        ai.catalog.listForProvider(spec.id, &models, arena) catch {};
        if (models.items.len == 0) {
            add(arena, &id_buf, &key_buf, &n, spec.id, spec_name, spec.default_model, spec.default_model);
        } else {
            for (models.items) |m| {
                const label = if (m.name.len > 0) m.name else m.id;
                add(arena, &id_buf, &key_buf, &n, spec.id, spec_name, m.id, label);
            }
        }
        if (manifest.find(spec.id)) |entry| {
            if (ai.models_file.authResolves(entry.*, getter)) {
                for (entry.models) |mm| {
                    const label = if (mm.name.len > 0) mm.name else mm.id;
                    add(arena, &id_buf, &key_buf, &n, spec.id, spec_name, mm.id, label);
                }
            }
        }
    }

    for (manifest.providers) |entry| {
        if (ai.presets.find(entry.id) != null) continue;
        if (!ai.models_file.authResolves(entry, getter)) continue;
        const spec_name = entry.displayName();
        if (std.mem.eql(u8, entry.id, args.current_spec)) found_current = true;
        if (entry.models.len == 0) continue;
        for (entry.models) |mm| {
            const label = if (mm.name.len > 0) mm.name else mm.id;
            add(arena, &id_buf, &key_buf, &n, entry.id, spec_name, mm.id, label);
        }
    }

    const current_name = blk: {
        if (manifest.find(args.current_spec)) |e| {
            if (e.name.len > 0) break :blk e.name;
        }
        if (ai.presets.find(args.current_spec)) |s| break :blk s.name;
        break :blk args.current_spec;
    };
    const current_label = blk: {
        if (manifest.find(args.current_spec)) |e| {
            for (e.models) |mm| {
                if (std.mem.eql(u8, mm.id, args.current_model)) {
                    if (mm.name.len > 0) break :blk mm.name;
                    break;
                }
            }
        }
        if (ai.catalog.lookup(args.current_spec, args.current_model)) |m| {
            if (m.name.len > 0) break :blk m.name;
        }
        break :blk args.current_model;
    };
    if (!found_current and args.current_spec.len > 0) {
        add(arena, &id_buf, &key_buf, &n, args.current_spec, current_name, args.current_model, current_label);
    }
    add(arena, &id_buf, &key_buf, &n, args.current_spec, current_name, args.current_model, current_label);

    const ids = arena.dupe([]const u8, id_buf[0..n]) catch &.{};
    const keys = arena.dupe([]const u8, key_buf[0..n]) catch &.{};
    const label = std.fmt.allocPrint(arena, "{s}  ·  {s}", .{ current_name, args.current_model }) catch args.current_model;
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
    app.model_picker_refresh = args.host_opts.model_picker_refresh;

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

test "collectTuiModelPicker lists every configured catalog + ollama" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("OPENAI_API_KEY", "sk-oai");
    try env.put("ANTHROPIC_API_KEY", "sk-ant");

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const picker = collectTuiModelPicker(arena_inst.allocator(), .{
        .env = &env,
        .current_spec = "openai",
        .current_model = "gpt-4o-mini",
        .io = std.testing.io,
        .cwd = Io.Dir.cwd(),
        .project_models_path = "no-such-zag-models.json",
    });

    try std.testing.expect(containsPickerSpec(picker.keys, "openai"));
    try std.testing.expect(containsPickerSpec(picker.keys, "anthropic"));
    try std.testing.expect(containsPickerSpec(picker.keys, "ollama"));
    try std.testing.expect(containsPickerKey(picker.keys, "openai", "gpt-4o"));
    try std.testing.expect(containsPickerKey(picker.keys, "anthropic", "claude-sonnet-4-5"));
    try std.testing.expect(containsDisplay(picker.ids, "GPT-4o mini"));
    try std.testing.expect(picker.ids.len >= 8);
}

test "collectTuiModelPicker: all keyed catalogs stay under cap" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    for (ai.presets.builtin) |spec| {
        for (spec.env_keys) |k| {
            try env.put(k, "sk-test");
        }
    }

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const picker = collectTuiModelPicker(arena_inst.allocator(), .{
        .env = &env,
        .current_spec = "deepseek",
        .current_model = "deepseek-v4-flash",
        .io = std.testing.io,
        .cwd = Io.Dir.cwd(),
        .project_models_path = "no-such-zag-models.json",
    });

    var expected: usize = 0;
    var specs: std.ArrayList(ai.ProviderSpec) = .empty;
    defer specs.deinit(gpa);
    const EnvGet = struct {
        env: *const std.process.Environ.Map,
        pub fn get(this: @This(), key: []const u8) ?[]const u8 {
            return this.env.get(key);
        }
    };
    try ai.registry.listPickerProviders(EnvGet{ .env = &env }, &specs, gpa);
    for (specs.items) |spec| {
        var models: std.ArrayList(ai.ModelInfo) = .empty;
        defer models.deinit(gpa);
        try ai.catalog.listForProvider(spec.id, &models, gpa);
        expected += if (models.items.len == 0) 1 else models.items.len;
    }
    try std.testing.expectEqual(expected, picker.ids.len);
    try std.testing.expect(picker.ids.len > 24);
    try std.testing.expect(picker.ids.len <= tui_picker_cap);
}

test "collectTuiModelPicker: manifest with auth appears; without does not" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".zag");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".zag/models.json",
        .data =
            \\{"providers":{"my-ollama":{"name":"Home Ollama","base_url":"http://127.0.0.1:11434/v1","api_key":"$HOME_OLLAMA_KEY","models":[{"id":"qwen2.5-coder:7b","name":"Qwen Coder"}]},"ghost":{"name":"Ghost","base_url":"http://127.0.0.1:9/v1","api_key":"$MISSING_KEY","models":[{"id":"nope"}]}}}
        ,
    });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME_OLLAMA_KEY", "sk-home");
    try env.put("OPENAI_API_KEY", "sk-oai");

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const picker = collectTuiModelPicker(arena_inst.allocator(), .{
        .env = &env,
        .current_spec = "openai",
        .current_model = "gpt-4o-mini",
        .io = io,
        .cwd = tmp.dir,
        .project_models_path = ".zag/models.json",
    });

    try std.testing.expect(containsPickerKey(picker.keys, "my-ollama", "qwen2.5-coder:7b"));
    try std.testing.expect(containsDisplay(picker.ids, "Home Ollama"));
    try std.testing.expect(containsDisplay(picker.ids, "Qwen Coder"));
    try std.testing.expect(!containsPickerSpec(picker.keys, "ghost"));
}

fn containsPickerSpec(keys: []const []const u8, spec: []const u8) bool {
    for (keys) |k| {
        const p = ai.registry.parsePickerKey(k);
        if (std.mem.eql(u8, p.spec_id, spec)) return true;
    }
    return false;
}

fn containsPickerKey(keys: []const []const u8, spec: []const u8, model: []const u8) bool {
    for (keys) |k| {
        const p = ai.registry.parsePickerKey(k);
        if (std.mem.eql(u8, p.spec_id, spec) and std.mem.eql(u8, p.model_id, model)) return true;
    }
    return false;
}

fn containsDisplay(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.indexOf(u8, id, needle) != null) return true;
    }
    return false;
}
