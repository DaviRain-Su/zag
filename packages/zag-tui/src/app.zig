//! Address-stable heap App: preallocation, dual-thread host, lifecycle publish.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const posix = std.posix;
const coding = @import("zag-coding-agent");
const zt = @import("zag-types");
const c = @import("constants.zig");
const cards_mod = @import("cards.zig");
const editor_mod = @import("editor.zig");
const keys_mod = @import("keys.zig");
const present = @import("present.zig");
const permission_mod = @import("permission.zig");
const render = @import("render.zig");
const layout_mod = @import("layout.zig");
const signal_host = @import("signal_host.zig");
const terminal_mod = @import("terminal.zig");
const theme_mod = @import("theme.zig");
const overlay_mod = @import("overlay.zig");
const slash_route = @import("slash_route.zig");
const scrollback_mod = @import("scrollback.zig");

pub const SignalHost = signal_host.SignalHost;
pub const UiState = render.UiState;

pub const OpenDisplay = enum {
    create_new,
    resume_existing,
    n_a,

    pub fn label(self: OpenDisplay) []const u8 {
        return switch (self) {
            .create_new => "create_new",
            .resume_existing => "resume_existing",
            .n_a => "n/a",
        };
    }
};

pub const BindError = error{ MissingRedactor, MissingSignalHost, MissingAgent, MissingSession };

/// session-swap-001: session start knobs captured at bind time and forwarded
/// verbatim to every later `Session.start` (the swap's new session must match
/// the initial one — base_system / redactor / skills flags parity).
pub const BindSessionOpts = struct {
    base_system: []const u8 = "",
    load_project_instructions: bool = true,
    /// Agent.activeRedactor() at bind time (cloned into each started session).
    redactor: ?*const coding.redact.Redactor = null,
    skills_enabled: bool = true,
    project_skills_trust: coding.ProjectSkillsTrust = .untrusted,
    user_skills_root: ?[]const u8 = null,
    templates_enabled: bool = true,
    project_templates_trust: coding.ProjectTemplatesTrust = .untrusted,
    user_templates_root: ?[]const u8 = null,
};

/// Card-title identity constants (tui-streaming-001): delta replaces match
/// `TITLE_PROGRESSIVE` ONLY so a finalized "assistant turn=N" card is never
/// clobbered by partial text; lifecycle uses the turn format. Kept in one
/// place so the prefix rules stay in lockstep with `cards.zig:124`.
/// Thinking progressive (tui-thinking-streaming-001) uses its own prefix:
/// it keeps the "thinking" prefix for render body painting (render.zig
/// paints cards whose title starts with "thinking"), yet is distinct from
/// the final "thinking" title so turn N+1 deltas never retitle turn N's
/// finalized card ("thinking" does not start with "thinking progressive").
pub const TITLE_PROGRESSIVE = "assistant progressive";
pub const TITLE_TURN_FMT = "assistant turn={d}";
pub const TITLE_THINKING_PROGRESSIVE = "thinking progressive";

/// Test-only teardown observer (no product effect when null).
pub const TeardownProbe = struct {
    steps: []u8,
    len: usize = 0,

    pub fn note(self: *TeardownProbe, tag: u8) void {
        if (self.len < self.steps.len) {
            self.steps[self.len] = tag;
            self.len += 1;
        }
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,

    editor_storage: []u8,
    history_entries: [][c.history_entry_max_bytes]u8,
    history_lens: []usize,
    card_ring: cards_mod.CardRing,
    permission: permission_mod.PermissionSlot,
    editor: editor_mod.Editor,
    history: editor_mod.History,

    wake_r: posix.fd_t = -1,
    wake_w: posix.fd_t = -1,

    agent: ?*coding.Agent = null,
    session: ?*coding.Session = null,
    redactor: ?*const coding.redact.Redactor = null,
    /// Borrowed subagent registry pointer (from coding-agent Agent). Null when no agent bound.
    subagent_registry: ?*const @import("zag-coding-agent").subagent.Registry = null,
    host: ?SignalHost = null,
    /// session-swap-001: session start knobs captured at bind (see
    /// BindSessionOpts) — the swap reuses them for the new Session.start.
    bind_session_opts: BindSessionOpts = .{},

    id_display: [c.card_title_max_bytes]u8 = undefined,
    id_display_len: usize = 0,
    open_display: OpenDisplay = .n_a,
    perm_label: []const u8 = "ask",
    shell_label: []const u8 = "protect",
    /// Cross-thread run_start fact — atomic (worker publish, UI read).
    session_configured_ui: std.atomic.Value(bool) = .init(false),

    state: UiState = .idle,
    status_note: [128]u8 = undefined,
    status_note_len: usize = 0,
    quiesced: bool = false,
    raw_entered: bool = false,
    /// Sticky host fatal: subsequent worker success must not yield exit 0.
    host_fatal: bool = false,
    sticky_exit: u8 = 0,

    worker: ?std.Thread = null,
    worker_prompt: []u8 = &[_]u8{},
    worker_active: bool = false,
    worker_finished: std.atomic.Value(bool) = .init(false),
    worker_had_error: std.atomic.Value(bool) = .init(false),

    snap_buf: [c.card_slots]cards_mod.CardSlot = undefined,
    last_run_started: bool = false,
    /// Streaming delta accumulator (tui-streaming-001): grows per
    /// `assistant_delta` up to `card_body_max_bytes` (4096); reset on
    /// `assistant_delta_clear` and on complete `assistant_message` (turn
    /// boundary). App-owned, worker-thread written, UI-thread read via the
    /// card ring snapshot (fixed copy under the ring lock).
    delta_buf: [c.card_body_max_bytes]u8 = undefined,
    delta_len: usize = 0,
    /// Reasoning delta accumulator (tui-thinking-streaming-001): grows per
    /// `thinking_delta` up to `card_body_max_bytes`; reset on
    /// `assistant_delta_clear` (clears BOTH content and thinking — single
    /// clear event) and on complete `assistant_message` (turn boundary).
    thinking_buf: [c.card_body_max_bytes]u8 = undefined,
    thinking_len: usize = 0,

    /// Optional teardown probe (tests).
    teardown_probe: ?*TeardownProbe = null,

    /// Dirty-flag presenter (tui-layout-001): set by every mutation block
    /// (key action, worker join, host wake drain, interrupt, permission
    /// modal change, note update); `paint()` early-returns when `!dirty` and
    /// the terminal size is unchanged since the last paint.
    dirty: bool = false,
    /// Terminal size at the last successful paint; null → first paint always
    /// runs. Any size difference (idle-terminal resize included) forces a
    /// repaint because `paint()` re-reads `term.size()` on every call.
    last_painted_size: ?terminal_mod.Size = null,

    /// theme-001 active palette (fail-closed builtin when load fails).
    palette: theme_mod.Palette = theme_mod.builtinDefault(),
    owned_theme_id: ?[]u8 = null,
    themes_root: ?[]const u8 = null,
    /// Chosen theme id. Points at host-provided memory (CLI arena), a
    /// builtin literal, an owned user-theme id, or — after an overlay
    /// selection — the persistent copy below (overlay lines are scratch
    /// buffers that get rewritten every paint).
    theme_selected: []const u8 = theme_mod.builtin_id,
    theme_sel_buf: [64]u8 = undefined,
    theme_sel_len: usize = 0,

    /// Ctrl+O cycles the permission mode — see handleKey.
    /// Thinking visibility toggle (Ctrl+T): when on, the model's reasoning
    /// text publishes as a `· thinking` card ahead of the assistant turn.
    show_thinking: bool = false,
    /// Grok-style thinking body fold (Ctrl+E when editor empty).
    thinking_expanded: bool = false,
    /// Subagent tasks pane (Ctrl+K). Collapsed/hidden when the registry is
    /// empty — only auto-opens while a subagent is running, and never steals
    /// Enter from the editor unless the pane is focused.
    tasks_visible: bool = false,
    /// Selected row in the tasks pane (0 = top / running-first).
    tasks_cursor: usize = 0,
    /// Expanded detail under the selected tasks row.
    tasks_expanded: bool = false,
    /// Keyboard focus is on the tasks pane (j/k/Space). When false the
    /// editor keeps Enter / arrows / history — fixes "can't send message".
    tasks_focused: bool = false,
    /// Auto-opened because a subagent is running (auto-closes when idle).
    tasks_auto: bool = false,
    overlay: overlay_mod.Overlay = .{},
    /// Row-level transcript scrollback (tui-scrollback-001): geometry
    /// cache + virtual_y + follow mode. Survives frames.
    sb: scrollback_mod.Scrollback = undefined,
    /// Transcript interior viewport height at the last paint — PgUp/PgDn
    /// page by this many rows.
    last_viewport_h: usize = 0,

    model_label: []const u8 = "—",
    /// Owned copy of the selected model id (stable across overlay rebuilds).
    model_sel_buf: [96]u8 = undefined,
    model_sel_len: usize = 0,
    /// Borrowed live/catalog model ids from host (CLI arena / static). Cap used at paint.
    model_ids: []const []const u8 = &.{},
    /// Scratch lines for overlay paint (rebuilt each paint).
    overlay_line_bufs: [24][96]u8 = undefined,
    overlay_line_lens: [24]usize = [_]usize{0} ** 24,
    overlay_line_ptrs: [24][]const u8 = undefined,
    overlay_line_count: usize = 0,
    /// Io handle for Theme FS discovery (set by applyHostPresentation).
    host_io: ?Io = null,
    /// Resume overlay FS base: `resume_cwd` + the PINNED sessions root
    /// (session-tree-001: the default `resume_root` when the active session
    /// path sits inside it, else the active path's dirname) are scanned for
    /// `*.jsonl` sessions. Tests may point both at a tmp dir; the cwd handle
    /// is borrowed (never closed here).
    resume_cwd: Io.Dir = undefined,
    resume_root: []const u8 = ".zag/sessions",
    /// Raw (unredacted) session rel paths backing the resume overlay rows —
    /// parallel to overlay_line_bufs so a selection maps back to the real
    /// file (`{pinned_root}/{rel}.jsonl`) even though the displayed label
    /// went through the redaction pipeline (filenames can embed secrets).
    resume_stem_bufs: [24][96]u8 = undefined,
    resume_stem_lens: [24]usize = [_]usize{0} ** 24,
    /// Per-row kind for the resume overlay (parallel to overlay_line_bufs):
    /// `.muted` = group header — renders muted, Enter is a no-op; `.normal`
    /// = selectable session row (or the "(no sessions)" placeholder).
    resume_row_kinds: [24]render.RowKind = [_]render.RowKind{.normal} ** 24,

    pub fn create(gpa: std.mem.Allocator) error{ OutOfMemory, PipeFailed }!*App {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);

        const editor_storage = try gpa.alloc(u8, c.editor_max_bytes);
        errdefer gpa.free(editor_storage);

        const history_entries = try gpa.alloc([c.history_entry_max_bytes]u8, c.history_capacity);
        errdefer gpa.free(history_entries);

        const history_lens = try gpa.alloc(usize, c.history_capacity);
        errdefer gpa.free(history_lens);
        @memset(history_lens, 0);

        const pipe = terminal_mod.makeWakePipe() catch {
            gpa.free(history_lens);
            gpa.free(history_entries);
            gpa.free(editor_storage);
            gpa.destroy(app);
            return error.PipeFailed;
        };

        app.* = .{
            .gpa = gpa,
            .editor_storage = editor_storage,
            .history_entries = history_entries,
            .history_lens = history_lens,
            .card_ring = cards_mod.CardRing.init(),
            .permission = .{},
            .editor = editor_mod.Editor.init(editor_storage),
            .history = editor_mod.History.init(history_entries, history_lens),
            .wake_r = pipe[0],
            .wake_w = pipe[1],
            .sb = scrollback_mod.Scrollback.init(gpa),
            .resume_cwd = Io.Dir.cwd(),
        };
        return app;
    }

    pub fn destroy(self: *App) void {
        // session-swap-001: App owns the CURRENT session (bind hands it
        // over; swaps replace it). Deinit + destroy exactly once when
        // non-null. Callers order Agent.deinit BEFORE App.destroy — session
        // state is session-owned (its redactor is a clone).
        if (self.session) |s| {
            if (self.teardown_probe) |p| p.note('S');
            s.deinit();
            self.gpa.destroy(s);
            self.session = null;
        }
        if (self.teardown_probe) |p| p.note('A'); // App free last marker
        if (self.wake_r >= 0) {
            terminal_mod.closeFd(self.wake_r);
            self.wake_r = -1;
        }
        if (self.wake_w >= 0) {
            terminal_mod.closeFd(self.wake_w);
            self.wake_w = -1;
        }
        if (self.worker_prompt.len != 0) {
            self.gpa.free(self.worker_prompt);
            self.worker_prompt = &[_]u8{};
        }
        if (self.owned_theme_id) |id| {
            self.gpa.free(id);
            self.owned_theme_id = null;
        }
        self.gpa.free(self.history_lens);
        self.gpa.free(self.history_entries);
        self.gpa.free(self.editor_storage);
        self.sb.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn quiesce(self: *App) void {
        if (self.teardown_probe) |p| p.note('Q');
        self.quiesced = true;
        self.host = null;
    }

    /// Display path identity — **must** run after Session redactor bind.
    /// Pipeline: redactAlloc → UTF-8 → truncate → fixed copy. Never raw path.
    pub fn setIdentity(
        self: *App,
        gpa: std.mem.Allocator,
        redactor: ?*const coding.redact.Redactor,
        id: []const u8,
        open: OpenDisplay,
        perm: []const u8,
        shell: []const u8,
    ) void {
        self.id_display_len = present.presentInto(gpa, redactor, &self.id_display, id);
        self.open_display = open;
        self.perm_label = perm;
        self.shell_label = shell;
    }

    /// Host presentation options (theme + model catalog labels). Fail-closed theme.
    pub fn applyHostPresentation(
        self: *App,
        io: Io,
        theme_opts: theme_mod.ThemeHostOptions,
        model_label: []const u8,
        model_ids: []const []const u8,
    ) void {
        self.host_io = io;
        self.themes_root = theme_opts.themes_root;
        if (theme_opts.selected_id) |sel| self.theme_selected = sel;
        self.reloadTheme();
        // Own a stable copy of the model label (caller may pass a temporary).
        const n = @min(model_label.len, self.model_sel_buf.len);
        @memcpy(self.model_sel_buf[0..n], model_label[0..n]);
        self.model_sel_len = n;
        self.model_label = self.model_sel_buf[0..n];
        self.model_ids = model_ids;
        self.dirty = true;
    }

    fn reloadTheme(self: *App) void {
        if (self.owned_theme_id) |id| {
            self.gpa.free(id);
            self.owned_theme_id = null;
        }
        const io = self.host_io orelse {
            self.palette = theme_mod.builtinDefault();
            self.theme_selected = self.palette.id;
            return;
        };
        const resolved = theme_mod.resolveActive(self.gpa, io, .{
            .themes_root = self.themes_root,
            .selected_id = self.theme_selected,
        });
        self.palette = resolved;
        // resolveActive returns an OWNED id only for user themes (gpa dupe
        // inside parseThemeJson); builtin ids are compile-time literals —
        // registering one in owned_theme_id would free static memory on the
        // next reload (crash). Own only non-builtin ids.
        var is_builtin = false;
        for (theme_mod.builtin_ids) |bid| {
            if (std.mem.eql(u8, resolved.id, bid)) {
                is_builtin = true;
                break;
            }
        }
        if (!is_builtin) {
            self.owned_theme_id = @constCast(resolved.id);
        }
        self.theme_selected = self.palette.id;
    }

    pub fn idDisplay(self: *const App) []const u8 {
        if (self.id_display_len == 0) return "ephemeral";
        return self.id_display[0..self.id_display_len];
    }

    /// Binds the heap-allocated CURRENT session; App owns it from here on
    /// (App.destroy deinits + destroys it exactly once). `opts` captures the
    /// session start knobs for later swaps (session-swap-001).
    pub fn bind(
        self: *App,
        agent: *coding.Agent,
        session: *coding.Session,
        redactor: *const coding.redact.Redactor,
        host: SignalHost,
        opts: BindSessionOpts,
    ) BindError!void {
        if (self.quiesced) return error.MissingAgent;
        self.agent = agent;
        self.session = session;
        self.redactor = redactor;
        self.host = host;
        self.bind_session_opts = opts;
        // subagents-001: bind the Agent's subagent registry for TUI display.
        self.subagent_registry = agent.subagent_registry;
        // P1 async: wake the UI when a background subagent finishes so the
        // tasks pane repaints without waiting for the next key/poll tick.
        agent.task_tool_state.wake_fn = wakeThunkOpaque;
        agent.task_tool_state.wake_ctx = self;
    }

    pub fn lifecycleObserver(self: *App) coding.LifecycleObserver {
        return .{ .ptr = self, .on_event = onLifecycle };
    }

    pub fn observer(self: *App) coding.Observer {
        return .{ .ptr = self, .on_event = onObserver };
    }

    pub fn askFn(
        ptr: ?*anyopaque,
        descriptor: zt.ToolDescriptor,
        arguments_json: []const u8,
    ) coding.permissions.Decision {
        if (ptr == null) return .deny;
        const self: *App = @ptrCast(@alignCast(ptr.?));
        if (self.quiesced) return .deny;
        return self.permission.ask(
            self.gpa,
            self.redactor,
            true,
            descriptor,
            arguments_json,
            wakeThunk,
            self,
        );
    }

    fn wakeThunk(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.wake();
    }

    /// Matches task_tool.WakeFn (?*anyopaque).
    fn wakeThunkOpaque(ctx: ?*anyopaque) void {
        if (ctx) |ptr| wakeThunk(ptr);
    }

    pub fn wake(self: *App) void {
        if (self.wake_w >= 0) terminal_mod.wakeWrite(self.wake_w);
    }

    pub fn setNote(self: *App, note: []const u8) void {
        self.dirty = true;
        self.status_note_len = present.copyTruncated(&self.status_note, note);
    }

    pub fn noteSlice(self: *const App) []const u8 {
        return self.status_note[0..self.status_note_len];
    }

    fn onLifecycle(ptr: ?*anyopaque, event: coding.LifecycleEvent) void {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        const red = self.redactor;
        switch (event) {
            .run_start => |rs| {
                self.last_run_started = true;
                self.session_configured_ui.store(rs.session_configured, .release);
                // The run_terminal reserve card stays a .terminal-kind card
                // (drawCards skips it). Demoting it to ordinary put it into
                // the transcript as "· run_terminal" — user-visible noise
                // (user feedback).
                // No card (tui-polish-001 compaction): run start is already
                // surfaced by the header cfg flag + state:busy.
            },
            .assistant_message => |m| {
                // Turn boundary: the complete message arrived; next turn's
                // deltas start clean.
                self.delta_len = 0;
                self.thinking_len = 0;
                // Thinking final-replace rule (tui-thinking-streaming-001):
                // - progressive thinking card exists → replace + retitle to
                //   "thinking" (its partial text becomes this turn's reasoning);
                // - else reasoning non-empty → publish fresh (non-stream
                //   fallback path — no deltas were streamed);
                // - reasoning null/empty → drop the progressive card if present
                //   (the turn completed without thinking).
                // Toggle off → thinking cards never exist; a stale progressive
                // (toggled off mid-turn) is dropped at the turn boundary.
                const wants_thinking = self.show_thinking and
                    (if (m.reasoning) |r| r.len > 0 else false);
                if (wants_thinking) {
                    // Replace-or-publish: the progressive prefix is a strict
                    // refinement of "thinking", so a finalized prior-turn
                    // card ("thinking") is never retitled here.
                    self.card_ring.replaceNewestOrdinaryTitlePrefix(
                        self.gpa,
                        self.redactor,
                        TITLE_THINKING_PROGRESSIVE,
                        "thinking",
                        m.reasoning.?,
                    );
                } else {
                    _ = self.card_ring.removeNewestOrdinaryTitlePrefix(TITLE_THINKING_PROGRESSIVE);
                }
                // Lifecycle is card identity for assistant (turn/has_tools).
                var title_buf: [64]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, TITLE_TURN_FMT, .{m.turn}) catch "assistant";
                // Replace ONLY an open progressive card (its partial text
                // becomes this complete turn); with no progressive card this
                // publishes a fresh turn card — a finalized "assistant
                // turn=N" card is never clobbered by a later turn.
                self.card_ring.replaceNewestOrdinaryTitlePrefix(self.gpa, red, TITLE_PROGRESSIVE, title, m.text);
            },
            .tool_start => |t| {
                // Full redact pipeline for name/id/args (arbitrary bytes).
                var name_buf: [c.card_title_max_bytes]u8 = undefined;
                const name_n = present.presentInto(self.gpa, red, &name_buf, t.name);
                var title_buf: [c.card_title_max_bytes]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "tool start {s}", .{name_buf[0..name_n]}) catch "tool start";
                var id_buf: [64]u8 = undefined;
                var args_buf: [c.card_body_max_bytes]u8 = undefined;
                const id_n = present.presentInto(self.gpa, red, &id_buf, t.id);
                const args_n = present.presentInto(self.gpa, red, &args_buf, t.arguments);
                var body_buf: [c.card_body_max_bytes]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "id={s} args={s}", .{
                    id_buf[0..id_n],
                    args_buf[0..args_n],
                }) catch "tool";
                // Already redacted — fixed publish (no second redact).
                self.card_ring.publishOrdinaryPrepared(cards_mod.PreparedCard.fromFixed(title, body));
            },
            .tool_end => |t| {
                // Merge tool_start + tool_end into ONE `tool {name}` row: the
                // live "tool start {name}" card (published by tool_start) is
                // replaced by its final title + summary body. End-only emits
                // (loop-driven) publish fresh via the replace fallback.
                var name_buf: [c.card_title_max_bytes]u8 = undefined;
                const name_n = present.presentInto(self.gpa, red, &name_buf, t.name);
                var title_buf: [c.card_title_max_bytes]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "tool {s}", .{name_buf[0..name_n]}) catch "tool";
                self.card_ring.replaceNewestOrdinaryTitlePrefix(self.gpa, red, "tool start", title, t.body);
            },
            .control_applied => {
                // No card (tui-polish-001 compaction): steering/follow-up are
                // already surfaced by the header S:/F: counters.
            },
            // Content deltas are UI-visible only and handled by onObserver;
            // the lifecycle path does not paint per-chunk text. Thinking
            // deltas arrive ONLY via lifecycle (tui-thinking-streaming-001:
            // the observer is unchanged — headless/CLI stdout byte-identity),
            // so the progressive thinking card is painted here.
            .thinking_delta => |delta| {
                if (self.show_thinking) {
                    // Replace the newest "thinking progressive" card only — a
                    // finalized "thinking" card from a prior turn is never
                    // clobbered (distinct prefix keeps turn N+1 deltas off
                    // turn N's final card). Publish if none. Redaction runs
                    // per replace through the existing whole-body path.
                    self.appendThinking(delta);
                    self.card_ring.replaceNewestOrdinaryTitlePrefix(
                        self.gpa,
                        self.redactor,
                        TITLE_THINKING_PROGRESSIVE,
                        TITLE_THINKING_PROGRESSIVE,
                        self.thinking_buf[0..self.thinking_len],
                    );
                }
            },
            .assistant_delta, .assistant_delta_clear => {},
            .run_terminal => |term| {
                // Belt-and-braces: a sink-failure edge can terminate the run
                // with the accumulator holding partial text (the clear event
                // itself failed); reset here so the next reply starts clean.
                self.delta_len = 0;
                self.thinking_len = 0;
                var body_buf: [128]u8 = undefined;
                const stop = @tagName(term.stop_reason);
                const body = std.fmt.bufPrint(&body_buf, "ok={any} stop={s} turns={d} p={d} c={d} t={d}", .{
                    term.ok,
                    stop,
                    term.turns,
                    term.usage.prompt_tokens,
                    term.usage.completion_tokens,
                    term.usage.total_tokens,
                }) catch "run_terminal";
                self.card_ring.publishTerminalFixed("run_terminal", body);
            },
        }
        self.wake();
    }

    fn onObserver(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .assistant_text => |text| {
                // Turn boundary: the complete message arrived; next turn's
                // deltas start clean.
                self.delta_len = 0;
                // Progressive full-body snapshot: replace open assistant card only.
                // Do NOT create a second lifecycle identity card — lifecycle
                // `assistant_message` owns turn identity; this updates body only.
                self.card_ring.replaceNewestOrdinaryTitlePrefix(
                    self.gpa,
                    self.redactor,
                    "assistant",
                    TITLE_PROGRESSIVE,
                    text,
                );
                self.wake();
            },
            .assistant_delta => |delta| {
                // Accumulate and repaint the progressive card (Grok-Build-style
                // incremental text). Card identity: delta replaces match
                // TITLE_PROGRESSIVE ONLY — a new turn's first delta publishes a
                // fresh progressive card; the finalized "assistant turn=N" card
                // is never clobbered by partial text. Redaction runs per replace
                // through the existing whole-body path (redact outside lock).
                self.appendDelta(delta);
                self.card_ring.replaceNewestOrdinaryTitlePrefix(
                    self.gpa,
                    self.redactor,
                    TITLE_PROGRESSIVE,
                    TITLE_PROGRESSIVE,
                    self.delta_buf[0..self.delta_len],
                );
                self.wake();
            },
            .assistant_delta_clear => {
                // Attempt boundary: a failed attempt's deltas vanish — reset
                // BOTH accumulators (content + thinking; single clear event,
                // tui-thinking-streaming-001) and repaint with empty bodies.
                // Progressive prefixes only (never blanks finalized cards).
                self.delta_len = 0;
                self.thinking_len = 0;
                self.card_ring.replaceNewestOrdinaryTitlePrefix(
                    self.gpa,
                    self.redactor,
                    TITLE_PROGRESSIVE,
                    TITLE_PROGRESSIVE,
                    self.delta_buf[0..0],
                );
                self.card_ring.replaceNewestOrdinaryTitlePrefix(
                    self.gpa,
                    self.redactor,
                    TITLE_THINKING_PROGRESSIVE,
                    TITLE_THINKING_PROGRESSIVE,
                    self.thinking_buf[0..0],
                );
                self.wake();
            },
            else => {},
        }
    }

    /// Append one content delta to the accumulator, truncating at the cap on
    /// a UTF-8 codepoint boundary (cap = `card_body_max_bytes`).
    fn appendDelta(self: *App, delta: []const u8) void {
        if (self.delta_len >= self.delta_buf.len) return;
        const cap = self.delta_buf.len - self.delta_len;
        if (delta.len <= cap) {
            @memcpy(self.delta_buf[self.delta_len..][0..delta.len], delta);
            self.delta_len += delta.len;
            return;
        }
        const prefix = present.utf8Prefix(delta, cap);
        @memcpy(self.delta_buf[self.delta_len..][0..prefix.len], prefix);
        self.delta_len += prefix.len;
    }

    /// Append one thinking delta to the accumulator (same cap discipline as
    /// `appendDelta`, tui-thinking-streaming-001).
    fn appendThinking(self: *App, delta: []const u8) void {
        if (self.thinking_len >= self.thinking_buf.len) return;
        const cap = self.thinking_buf.len - self.thinking_len;
        if (delta.len <= cap) {
            @memcpy(self.thinking_buf[self.thinking_len..][0..delta.len], delta);
            self.thinking_len += delta.len;
            return;
        }
        const prefix = present.utf8Prefix(delta, cap);
        @memcpy(self.thinking_buf[self.thinking_len..][0..prefix.len], prefix);
        self.thinking_len += prefix.len;
    }

    pub fn run(self: *App) u8 {
        if (self.agent == null or self.session == null or self.redactor == null or self.host == null) {
            return 1;
        }
        if (self.quiesced) return 1;

        var term = terminal_mod.Terminal.open(self.gpa, self.wake_w) catch {
            self.fixedStderr("tui: not a tty\n");
            return 2;
        };
        const sz0 = term.size();
        if (sz0.isBelowMinimum()) {
            // Tty.init already applied raw termios; restore before exiting so
            // the terminal is never left raw on the geometry-failure path.
            term.restore() catch {};
            self.fixedStderr("tui: terminal too small (need ≥ 20×5)\n");
            return 1;
        }

        term.enterRawAlt() catch {
            term.restore() catch {};
            self.fixedStderr("tui: raw mode failed\n");
            return 1;
        };
        self.raw_entered = true;

        var exit_code: u8 = 0;
        defer {
            if (self.worker) |*th| {
                th.join();
                self.worker = null;
                self.afterWorkerJoin();
            }
            if (self.raw_entered) {
                term.restore() catch {};
                self.raw_entered = false;
            }
            if (self.host_fatal and exit_code == 0) exit_code = 1;
            if (self.sticky_exit != 0 and exit_code == 0) exit_code = self.sticky_exit;
        }

        self.paint(&term) catch {
            self.markHostFatal(1);
            self.permission.denyAndClose();
            self.fixedStderr("tui: render failed\n");
            exit_code = 1;
            return exit_code;
        };

        while (self.state != .closed) {
            // Poll set (tui-vaxis-001): [wake_r, host]. stdin is gone — the
            // vaxis input thread owns the tty and the bridge thread delivers
            // key/winsize events through the wake pipe + ring.
            var pollfds = [_]posix.pollfd{
                .{ .fd = self.wake_r, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.host.?.wakeFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            if (pollfds[1].fd < 0) {
                pollfds[1].fd = -1;
                pollfds[1].events = 0;
            }

            const nready = posix.poll(&pollfds, c.poll_timeout_ms) catch 0;
            // Animate busy spinner / tasks pane while waiting (grok tick).
            if (nready == 0 and (self.state == .busy or self.state == .closing or self.tasks_visible)) {
                self.dirty = true;
            }

            if (pollfds[0].revents & (posix.POLL.IN | posix.POLL.ERR) != 0) {
                // Worker wakes and bridge events share the pipe: drain it,
                // then process bridge-ring events (keys / winsize) in order.
                terminal_mod.drainPipe(self.wake_r);
                self.dirty = true;
                const action = self.drainBridgeEvents(&term);
                switch (action) {
                    .none => {},
                    .quit_0 => {
                        exit_code = 0;
                        self.state = .closed;
                    },
                    .quit_1 => {
                        exit_code = 1;
                        self.state = .closed;
                    },
                    .closing => self.enterClosing(),
                }
            }
            if (pollfds[1].fd >= 0 and pollfds[1].revents & (posix.POLL.IN | posix.POLL.ERR) != 0) {
                self.dirty = true;
                self.host.?.drainWake();
            }

            if (self.worker_active and self.worker_finished.load(.acquire)) {
                if (self.worker) |*th| {
                    th.join();
                    self.worker = null;
                }
                self.afterWorkerJoin();
            }

            // SIGINT via Guard: idle clean exit; busy deny pending modal + cancel.
            if (self.host.?.pendingInterrupt()) {
                self.dirty = true;
                if (self.state == .idle) {
                    exit_code = 0;
                    self.state = .closed;
                    break;
                }
                if (self.state == .busy) {
                    // Fail-closed: deny any pending AskFn so worker cannot hang.
                    self.permission.denyAndClose();
                    self.enterClosing();
                }
            }

            self.paint(&term) catch {
                self.permission.denyAndClose();
                self.markHostFatal(1);
                if (self.state == .busy) {
                    self.enterClosing();
                    self.fixedStderr("tui: render failed; waiting for cancel\n");
                } else {
                    self.fixedStderr("tui: render failed\n");
                    exit_code = 1;
                    self.state = .closed;
                }
            };

            if (self.state == .closing and !self.worker_active) {
                // Host fatal sticky — never invent success after fatal.
                exit_code = if (self.host_fatal) self.sticky_exit else 0;
                if (exit_code == 0 and self.sticky_exit != 0) exit_code = self.sticky_exit;
                self.state = .closed;
            }
        }

        return exit_code;
    }

    pub fn markHostFatal(self: *App, code: u8) void {
        self.host_fatal = true;
        if (self.sticky_exit == 0) self.sticky_exit = code;
    }

    fn enterClosing(self: *App) void {
        self.state = .closing;
        self.permission.denyAndClose();
        if (self.agent) |a| a.requestCancel();
        self.setNote("closing… (Ctrl+C again may hard-exit 130)");
    }

    /// After every reply worker join: ack Guard pending. **Does not** clear
    /// control queues (steering/follow-up survive cancel/error for next reply).
    pub fn afterWorkerJoin(self: *App) void {
        self.dirty = true;
        self.worker_active = false;
        self.worker_finished.store(false, .release);
        if (self.worker_prompt.len != 0) {
            self.gpa.free(self.worker_prompt);
            self.worker_prompt = &[_]u8{};
        }
        if (self.host) |h| h.acknowledgeCancel();
        const had_err = self.worker_had_error.load(.acquire);
        if (self.state == .closing) {
            // keep closing
        } else if (had_err or self.host_fatal) {
            self.state = .@"error";
            self.setNote("reply error");
        } else {
            self.state = .idle;
            self.setNote("");
        }
        // Intentionally NO clearControlQueues — queues retain for next reply.
        self.worker_had_error.store(false, .release);
        self.permission.resetClosing();
    }

    const KeyAction = enum { none, quit_0, quit_1, closing };

    /// Drain the bridge ring (tui-vaxis-001): map each vaxis key event to an
    /// AppKey and handle it; winsize events resize the vaxis screen and mark
    /// dirty. Non-blocking; returns the first terminal KeyAction (if any).
    fn drainBridgeEvents(self: *App, term: *terminal_mod.Terminal) KeyAction {
        var action: KeyAction = .none;
        while (term.popEvent()) |ev| {
            switch (ev) {
                .key_press => |key| {
                    var utf8_buf: [4]u8 = undefined;
                    const mapped = keys_mod.mapKey(key, &utf8_buf);
                    const a = self.handleKey(mapped);
                    if (a != .none) {
                        action = a;
                        break;
                    }
                },
                .mouse => |m| {
                    // Scroll wheel → row-level transcript scroll (hyper
                    // wheel semantics; 3 rows per notch). The bottom
                    // overscroll re-engages follow — wheel-to-bottom snaps
                    // back to live content. Click/motion are ignored (v1).
                    switch (m.button) {
                        .wheel_up => self.sb.scrollUp(3),
                        .wheel_down => self.sb.scrollDown(3, self.last_viewport_h),
                        else => {},
                    }
                    self.dirty = true;
                },
                .winsize => |ws| {
                    term.resize(ws);
                    self.dirty = true;
                },
                .quit => {},
            }
        }
        return action;
    }

    fn handleKey(self: *App, key: keys_mod.AppKey) KeyAction {
        // Any decoded key is a change worth repainting (no-op keys included —
        // batching is per-iteration, so this costs at most one frame).
        self.dirty = true;
        if (self.permission.isPending()) {
            switch (key) {
                .char => |ch| {
                    if (std.mem.eql(u8, ch, "a") or std.mem.eql(u8, ch, "A")) {
                        self.permission.decide(.allow);
                        return .none;
                    }
                    if (std.mem.eql(u8, ch, "d") or std.mem.eql(u8, ch, "D") or
                        std.mem.eql(u8, ch, "n") or std.mem.eql(u8, ch, "N"))
                    {
                        self.permission.decide(.deny);
                        return .none;
                    }
                    return .none;
                },
                .enter, .escape => {
                    self.permission.decide(.deny);
                    return .none;
                },
                .ctrl_d => {
                    self.permission.decide(.deny);
                    if (self.state == .busy) return .closing;
                    return .none;
                },
                .ctrl_c => return .none,
                .ctrl_o => {
                    // A permission modal is up: switch straight to auto and
                    // approve the waiting request (the user asked to stop
                    // being prompted).
                    self.permission.setMode(.auto);
                    self.permission.decide(.allow);
                    self.perm_label = "auto";
                    return .none;
                },
                else => return .none,
            }
        }

        if (self.overlay.isOpen()) {
            return self.handleOverlayKey(key);
        }

        // Tasks pane keys only when FOCUSED (Ctrl+K). Otherwise every key —
        // especially Enter — belongs to the editor so the user can always send.
        if (self.tasks_visible and self.tasks_focused) {
            switch (key) {
                .up => {
                    if (self.tasks_cursor > 0) self.tasks_cursor -= 1;
                    return .none;
                },
                .down => {
                    self.tasks_cursor +|= 1;
                    return .none;
                },
                .char => |ch| {
                    if (std.mem.eql(u8, ch, "k")) {
                        if (self.tasks_cursor > 0) self.tasks_cursor -= 1;
                        return .none;
                    }
                    if (std.mem.eql(u8, ch, "j")) {
                        self.tasks_cursor +|= 1;
                        return .none;
                    }
                    // Space toggles expand (Enter is reserved for send).
                    if (std.mem.eql(u8, ch, " ")) {
                        self.tasks_expanded = !self.tasks_expanded;
                        return .none;
                    }
                },
                .escape => {
                    if (self.tasks_expanded) {
                        self.tasks_expanded = false;
                    } else {
                        // Unfocus first; second Esc (or Ctrl+K) hides.
                        self.tasks_focused = false;
                    }
                    return .none;
                },
                // Enter falls through → send message.
                else => {},
            }
        }

        switch (key) {
            .ctrl_c => return .none,
            .ctrl_d => {
                if (self.state == .busy) return .closing;
                if (self.editor.len == 0) return .quit_0;
                return .none;
            },
            .enter => {
                if (self.state == .busy or self.state == .closing) {
                    self.setNote("busy_locked");
                    return .none;
                }
                if (self.editor.len == 0) return .none;
                if (!self.editor.submitValidUtf8()) {
                    self.setNote("invalid_utf8");
                    return .none;
                }
                self.dispatchReply() catch {
                    self.setNote("worker_start_failed");
                    return .none;
                };
                return .none;
            },
            .alt_enter, .ctrl_j => {
                _ = self.editor.insert("\n");
                return .none;
            },
            .escape => {
                self.setNote("");
                if (self.overlay.isOpen()) self.overlay.close();
                return .none;
            },
            .backspace => {
                self.editor.backspace();
                self.syncSlashOverlay();
                return .none;
            },
            .delete => {
                self.editor.deleteForward();
                return .none;
            },
            .left => {
                self.editor.moveLeft();
                return .none;
            },
            .right => {
                self.editor.moveRight();
                return .none;
            },
            .home => {
                self.editor.moveHome();
                return .none;
            },
            .end => {
                self.editor.moveEnd();
                return .none;
            },
            .ctrl_a => {
                self.editor.moveHome();
                return .none;
            },
            .ctrl_e => {
                // Grok: Ctrl+E expands thinking. Keep emacs end-of-line when
                // the editor has content; empty buffer toggles the fold.
                if (self.editor.len == 0) {
                    self.thinking_expanded = !self.thinking_expanded;
                    self.setNote(if (self.thinking_expanded) "thinking:expanded" else "thinking:collapsed");
                } else {
                    self.editor.moveEnd();
                }
                return .none;
            },
            .ctrl_w => {
                self.editor.deleteWordBack();
                self.syncSlashOverlay();
                return .none;
            },
            .ctrl_u => {
                self.editor.killToStart();
                self.syncSlashOverlay();
                return .none;
            },
            .ctrl_k => {
                // Collapsible tasks pane (grok Ctrl+G):
                //   empty registry → stay hidden (nothing to show)
                //   hidden → show + focus
                //   shown unfocused → focus
                //   focused → hide
                const live: usize = if (self.subagent_registry) |reg| reg.liveCount() else 0;
                if (live == 0) {
                    self.tasks_visible = false;
                    self.tasks_focused = false;
                    self.tasks_expanded = false;
                    self.tasks_auto = false;
                    self.setNote("no_subagents");
                    return .none;
                }
                if (!self.tasks_visible) {
                    self.tasks_visible = true;
                    self.tasks_focused = true;
                    self.tasks_auto = false;
                } else if (!self.tasks_focused) {
                    self.tasks_focused = true;
                    self.tasks_auto = false;
                } else {
                    self.tasks_visible = false;
                    self.tasks_focused = false;
                    self.tasks_expanded = false;
                    self.tasks_auto = false;
                }
                return .none;
            },
            .page_up => {
                // Page by the transcript viewport height (row-level
                // scrollback, tui-scrollback-001).
                self.sb.scrollUp(scrollback_mod.Scrollback.pageRows(self.last_viewport_h));
                return .none;
            },
            .page_down => {
                self.sb.scrollDown(scrollback_mod.Scrollback.pageRows(self.last_viewport_h), self.last_viewport_h);
                return .none;
            },
            .up => {
                if (self.state == .busy) return .none;
                if (self.history.up()) |e| {
                    self.editor.clear();
                    _ = self.editor.insert(e);
                }
                return .none;
            },
            .down => {
                if (self.state == .busy) return .none;
                if (self.history.down()) |e| {
                    self.editor.clear();
                    _ = self.editor.insert(e);
                } else {
                    self.editor.clear();
                }
                return .none;
            },
            .alt_s => {
                self.enqueueControl(.steering);
                return .none;
            },
            .alt_f => {
                self.enqueueControl(.follow_up);
                return .none;
            },
            .ctrl_o => {
                // Permission mode cycle (hyper Ctrl+O): ask → auto → bypass.
                // Leaving ask mode approves any modal currently waiting, so
                // the worker never hangs on a prompt the user just bypassed.
                const cur = self.permission.mode();
                const next: permission_mod.Mode = switch (cur) {
                    .ask => .auto,
                    .auto => .bypass,
                    .bypass => .ask,
                };
                self.permission.setMode(next);
                if (next != .ask and self.permission.isPending()) {
                    self.permission.decide(.allow);
                }
                self.perm_label = next.label();
                return .none;
            },
            .ctrl_t => {
                // Thinking visibility toggle: reasoning cards appear for
                // turns that carry model thinking (future turns only —
                // already-published cards stay as they are).
                self.show_thinking = !self.show_thinking;
                return .none;
            },
            .char => |ch| {
                _ = self.editor.insert(ch);
                self.syncSlashOverlay();
                return .none;
            },
            .unknown => return .none,
            .f1 => {
                // Toggle the shortcut reference (same as /help).
                if (self.overlay.kind == .help) {
                    self.overlay.close();
                } else {
                    self.overlay.open(.help);
                    _ = self.rebuildOverlayLines();
                }
                return .none;
            },
        }
    }

    /// Reconcile the slash palette with the editor buffer after a buffer edit
    /// (typing, backspace, Ctrl+W/U/K): open when the buffer filters, close
    /// when it no longer does.
    fn syncSlashOverlay(self: *App) void {
        if (slash_route.slashFilter(self.editor.slice()) != null) {
            if (self.overlay.kind != .slash_palette) self.overlay.open(.slash_palette);
        } else if (self.overlay.kind == .slash_palette) {
            self.overlay.close();
        }
    }

    fn handleOverlayKey(self: *App, key: keys_mod.AppKey) KeyAction {
        const count = self.rebuildOverlayLines();
        switch (key) {
            .escape => {
                self.overlay.close();
                return .none;
            },
            .up => {
                self.overlay.moveUp(count);
                return .none;
            },
            .down => {
                self.overlay.moveDown(count);
                return .none;
            },
            .enter => {
                self.activateOverlaySelection();
                return .none;
            },
            .page_up => {
                var i: usize = 0;
                while (i < 5) : (i += 1) self.overlay.moveUp(count);
                return .none;
            },
            .page_down => {
                var i: usize = 0;
                while (i < 5) : (i += 1) self.overlay.moveDown(count);
                return .none;
            },
            .home => {
                self.overlay.cursor = 0;
                return .none;
            },
            .end => {
                if (count > 0) self.overlay.cursor = count - 1;
                return .none;
            },
            .ctrl_d => {
                self.overlay.close();
                if (self.state == .busy) return .closing;
                return .none;
            },
            .char => |ch| {
                // Only the slash palette consumes text (live filter);
                // other overlays are navigation-only.
                if (self.overlay.kind == .slash_palette) {
                    _ = self.editor.insert(ch);
                    self.syncSlashOverlay();
                }
                return .none;
            },
            .backspace => {
                if (self.overlay.kind == .slash_palette) {
                    self.editor.backspace();
                    self.syncSlashOverlay();
                }
                return .none;
            },
            else => return .none,
        }
    }

    fn activateOverlaySelection(self: *App) void {
        const count = self.rebuildOverlayLines();
        if (count == 0) {
            self.overlay.close();
            return;
        }
        self.overlay.clampCursor(count);
        const line = self.overlay_line_ptrs[self.overlay.cursor];
        switch (self.overlay.kind) {
            .none => {},
            .help => {
                // Read-only reference: Enter/Esc close, nothing executes.
                self.overlay.close();
            },
            .slash_palette => {
                if (overlay_mod.Builtin.fromName(line)) |b| {
                    self.overlay.open(b.overlayKind());
                    _ = self.rebuildOverlayLines();
                    return;
                }
                if (std.mem.eql(u8, line, "skill:name")) {
                    self.editor.clear();
                    _ = self.editor.insert("/skill:");
                    self.overlay.close();
                    return;
                }
                if (std.mem.startsWith(u8, line, "(")) {
                    self.overlay.close();
                    return;
                }
                self.editor.clear();
                _ = self.editor.insert("/");
                _ = self.editor.insert(line);
                self.overlay.close();
            },
            .settings => {
                self.overlay.close();
            },
            .model => {
                // Copy selected id into App-owned storage (overlay lines are
                // scratch buffers rewritten every paint).
                const n = @min(line.len, self.theme_sel_buf.len);
                // Reuse a dedicated model buffer so theme_sel is not clobbered.
                // model_label is borrowed; store in overlay-stable buffer.
                @memcpy(self.model_sel_buf[0..n], line[0..n]);
                self.model_sel_len = n;
                self.model_label = self.model_sel_buf[0..n];
                if (self.agent) |agent| {
                    agent.setModel(self.model_label) catch {
                        self.setNote("model_switch_failed");
                        self.overlay.close();
                        return;
                    };
                }
                self.setNote("model_selected");
                self.overlay.close();
            },
            .theme => {
                // The overlay line points at scratch buffers that are
                // rewritten every paint (and user-theme ids are freed when
                // rebuildOverlayLines returns) — copy into App-owned
                // storage before reloading.
                const n = @min(line.len, self.theme_sel_buf.len);
                @memcpy(self.theme_sel_buf[0..n], line[0..n]);
                self.theme_sel_len = n;
                self.theme_selected = self.theme_sel_buf[0..n];
                self.reloadTheme();
                self.setNote("theme_selected");
                self.overlay.close();
            },
            .@"resume" => {
                // Group headers (kind .muted) are non-selectable: Enter is a
                // no-op that keeps the overlay open. (Without the kind flag a
                // header's empty stem would hit the "(no sessions)" close
                // path below.)
                if (self.resume_row_kinds[self.overlay.cursor] == .muted) return;
                // The overlay line is the REDACTED label; the raw rel path
                // backing this row lives in the parallel scratch (stems can
                // embed secrets). An empty stem = the "(no sessions)" row
                // (or a stale row) → close without acting.
                if (self.resume_stem_lens[self.overlay.cursor] == 0) {
                    self.overlay.close();
                    return;
                }
                const rel = self.resume_stem_bufs[self.overlay.cursor][0..self.resume_stem_lens[self.overlay.cursor]];
                const dir = self.pinnedSessionRoot();
                const path = std.fmt.allocPrint(self.gpa, "{s}/{s}.jsonl", .{ dir, rel }) catch {
                    self.setNote("resume_failed");
                    self.overlay.close();
                    return;
                };
                defer self.gpa.free(path);
                // session-swap-001: a NON-active selection becomes the ACTIVE
                // session (swap + replay — real continue, the next turn
                // appends to it); the already-active session replays only
                // (no-op swap — its own lock would fail a re-start anyway).
                if (self.isActivePath(path)) {
                    self.replaySession(path);
                } else {
                    self.swapSession(path);
                }
            },
        }
    }

    /// PINNED sessions root for the resume browser (session-tree-001): the
    /// default `resume_root` when the active session path sits inside it,
    /// else the active path's dirname. Pinning the default root makes
    /// `-s proj/foo.jsonl` sessions (created under the default root) list
    /// their siblings — the old dirname-only resolution made them invisible
    /// (documented instability).
    fn pinnedSessionRoot(self: *const App) []const u8 {
        if (self.session) |s| {
            if (s.path) |p| {
                const def = self.resume_root;
                if (std.mem.startsWith(u8, p, def) and
                    (p.len == def.len or p[def.len] == '/'))
                {
                    return def;
                }
                return std.fs.path.dirname(p) orelse ".";
            }
        }
        return self.resume_root;
    }

    /// Project prefix of a session rel path ("proj/stem" → "proj"), null
    /// for ungrouped (flat) sessions.
    fn groupPrefix(rel: []const u8) ?[]const u8 {
        const i = std.mem.indexOfScalar(u8, rel, '/') orelse return null;
        return rel[0..i];
    }

    /// UTC `MM-DD HH:MM` label for a session row (session-tree-001; no TZif
    /// parsing in v1 — local-timezone display is a documented follow-up).
    fn formatMtimeUtc(buf: []u8, mtime_ns: i96) []const u8 {
        if (mtime_ns < 0) return buf[0..0]; // pre-epoch: no representation
        const secs: u64 = @intCast(@divTrunc(mtime_ns, std.time.ns_per_s));
        const ep = std.time.epoch.EpochSeconds{ .secs = secs };
        const month_day = ep.getEpochDay().calculateYearDay().calculateMonthDay();
        const day_secs = ep.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
        }) catch buf[0..0];
    }

    /// `{n}B` under 1KiB, else `{tenths}KB` (one decimal, e.g. "1.5KB").
    fn formatSizeLabel(buf: []u8, size: u64) []const u8 {
        if (size < 1024) return std.fmt.bufPrint(buf, "{d}B", .{size}) catch buf[0..0];
        const whole = size / 1024;
        const frac = (size % 1024) * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d}KB", .{ whole, frac }) catch buf[0..0];
    }

    /// Does `path` equal the ACTIVE session's path? (Ephemeral sessions
    /// have no path and are never "the same file" as a listed session.)
    fn isActivePath(self: *const App, path: []const u8) bool {
        if (self.session) |s| {
            if (s.path) |p| return std.mem.eql(u8, p, path);
        }
        return false;
    }

    /// Read-only replay of one persisted session into the card ring
    /// (session-resume-tui-001). The active bound Session is never swapped:
    /// a new turn after replay appends to the ACTIVE session as today.
    ///
    /// Selected == active session → replay from the already-loaded live
    /// transcript (no re-load — a second lease would hit SessionBusy).
    /// Otherwise the file is loaded into a fresh arena-owned Transcript
    /// (deinited after replay; no leak). All failures are fail-closed:
    /// note "resume_failed" + close, never crash.
    fn replaySession(self: *App, path: []const u8) void {
        const io = self.host_io orelse {
            self.setNote("resume_failed");
            self.overlay.close();
            return;
        };

        var arena_impl: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();
        var transcript = coding.transcript.Transcript.init(arena);

        var msgs: []const coding.message.Message = undefined;
        const from_active = self.isActivePath(path);
        if (from_active) {
            msgs = self.session.?.transcript.items();
        } else {
            const meta = coding.session_store.loadWithMeta(self.gpa, io, self.resume_cwd, path, &transcript) catch {
                // Missing/corrupt/unsupported → fail closed, never crash.
                self.setNote("resume_failed");
                self.overlay.close();
                return;
            };
            _ = meta;
            msgs = transcript.items();
        }

        if (!self.replayTranscript(msgs)) return; // note set + closed inside

        // Post-replay surface: editor cleared, scrollback reset to follow,
        // state stays idle. The ACTIVE session is untouched (v1 read-only).
        self.editor.clear();
        self.delta_len = 0;
        self.overlay.close();
        self.sb.gotoBottom(self.last_viewport_h);
        self.dirty = true;
        self.setNote(if (from_active) "resume_active" else "resume_browsing");
    }

    /// Shared replay pipeline (session-resume-tui-001 / session-swap-001):
    /// walk `msgs` in transcript order and publish cards — user →
    /// publishUser (redacted); assistant → `assistant turn={n}` renumbered
    /// 1..N with a toggle-gated `thinking` card; tool → `tool {name}` via
    /// the carrier assistant's id→name map. Every card runs the existing
    /// redaction pipeline (never raw). Returns false only on an internal
    /// OOM (note "resume_failed" + overlay closed, fail-closed).
    fn replayTranscript(self: *App, msgs: []const coding.message.Message) bool {
        var arena_impl: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        // Tool rows carry only tool_call_id; the tool NAME lives on the
        // carrier assistant's tool_calls (arena-owned for this replay).
        const ToolName = struct { id: []const u8, name: []const u8 };
        var tool_names: std.ArrayListUnmanaged(ToolName) = .empty;

        var turn: usize = 0;
        for (msgs) |m| {
            switch (m.role) {
                .system => {},
                .user => self.card_ring.publishUser(self.gpa, self.redactor, m.content),
                .assistant => {
                    if (m.tool_calls) |calls| {
                        for (calls) |call| {
                            tool_names.append(arena, .{ .id = call.id, .name = call.name }) catch {
                                self.setNote("resume_failed");
                                self.overlay.close();
                                return false;
                            };
                        }
                    }
                    turn += 1;
                    // Thinking visibility toggle gates the reasoning card.
                    if (self.show_thinking) {
                        if (m.reasoning) |r| {
                            if (r.len > 0) {
                                self.card_ring.publishOrdinary(self.gpa, self.redactor, "thinking", r);
                            }
                        }
                    }
                    var title_buf: [64]u8 = undefined;
                    const title = std.fmt.bufPrint(&title_buf, TITLE_TURN_FMT, .{turn}) catch "assistant";
                    self.card_ring.publishOrdinary(self.gpa, self.redactor, title, m.content);
                },
                .tool => {
                    var name: []const u8 = "?";
                    if (m.tool_call_id) |tid| {
                        for (tool_names.items) |tn| {
                            if (std.mem.eql(u8, tn.id, tid)) {
                                name = tn.name;
                                break;
                            }
                        }
                    }
                    var title_buf: [c.card_title_max_bytes]u8 = undefined;
                    const title = std.fmt.bufPrint(&title_buf, "tool {s}", .{name}) catch "tool";
                    self.card_ring.publishOrdinary(self.gpa, self.redactor, title, m.content);
                },
            }
        }
        return true;
    }

    /// session-swap-001: make the session at `path` the ACTIVE session —
    /// real continue (the next turn appends to it). Idle-only: swap while
    /// a worker runs or the UI is not idle → note "resume_busy" + no-op
    /// (never mid-run).
    ///
    /// Fail-closed sequence (old untouched until the new session is ready):
    ///   1. old.save() — a save error aborts, old stays active;
    ///   2. Session.start on the NEW path FIRST (per-path locks: both
    ///      leases briefly coexist) — SessionBusy / missing / OOM aborts
    ///      with old untouched;
    ///   3. heap-allocate + move the new session (later failure deinits +
    ///      destroys it);
    ///   4. old.deinit() + gpa.destroy(old) — old lock released exactly once;
    ///   5. app.session = new; app.redactor = new.activeRedactor();
    ///   6. setIdentity refresh + session_configured_ui reset;
    ///   7. card-ring clear, then replay the new session's live transcript;
    ///   8. swap-specific note (never resume_active).
    ///
    /// Process-memory state is NOT migrated: queued steering/follow-up are
    /// dropped and an ephemeral-source old session (writer == null) loses
    /// its conversation — both surfaced via the note (resume_swapped_ephemeral).
    fn swapSession(self: *App, path: []const u8) void {
        if (self.worker_active or self.state != .idle) {
            self.setNote("resume_busy");
            return;
        }
        const io = self.host_io orelse {
            self.setNote("resume_failed");
            self.overlay.close();
            return;
        };
        const old = self.session orelse {
            self.setNote("resume_failed");
            self.overlay.close();
            return;
        };
        const opts = self.bind_session_opts;

        // (1) Persist the old session first; a save error aborts the swap
        // (fail-closed: old stays active and the next turn works).
        old.save() catch {
            self.setNote("resume_failed");
            self.overlay.close();
            return;
        };

        // (2)+(3) Start the NEW session BEFORE touching the old (per-path
        // locks coexist briefly). Any failure aborts with old untouched.
        const new = self.startSwappedSession(io, path, opts) catch {
            self.setNote("resume_failed");
            self.overlay.close();
            return;
        };

        // Ephemeral-source fact captured BEFORE the old session is freed
        // (post-swap note surfaces the lost conversation).
        const ephemeral_source = old.path == null;

        // (4) Release the old lease + free the old Session exactly once.
        old.deinit();
        self.gpa.destroy(old);

        // (5) Re-point BEFORE any replay publish (redaction pipeline runs
        // through the new session's cloned redactor).
        self.session = new;
        self.redactor = new.activeRedactor() orelse self.redactor;

        // (6) Identity + configured-ui refresh for the new path.
        self.setIdentity(self.gpa, self.redactor, path, .resume_existing, self.perm_label, self.shell_label);
        self.session_configured_ui.store(false, .release);

        // (7) Card-ring reset so the two sessions' cards never concatenate,
        // then replay the new session's live transcript (the from-active
        // branch: the new session IS active, no re-load, no lock conflict).
        self.card_ring.clear();
        if (!self.replayTranscript(new.transcript.items())) return; // note set
        self.editor.clear();
        self.delta_len = 0;
        self.thinking_len = 0;
        self.overlay.close();
        self.sb.gotoBottom(self.last_viewport_h);
        self.dirty = true;
        // (8) Swap-specific note (not resume_active); ephemeral-source
        // swaps surface the lost conversation.
        self.setNote(if (ephemeral_source) "resume_swapped_ephemeral" else "resume_swapped");
    }

    /// Start + heap-move the swapped-in session (swap steps 2–3). Fail-closed:
    /// on ANY error the OLD session is untouched and nothing leaks (the heap
    /// cell is destroyed on the error path; a failed start has no session).
    fn startSwappedSession(
        self: *App,
        io: Io,
        path: []const u8,
        opts: BindSessionOpts,
    ) error{ StartFailed, OutOfMemory }!*coding.Session {
        const gpa = self.gpa;
        const new = try gpa.create(coding.Session);
        errdefer gpa.destroy(new);
        const started = coding.Session.start(gpa, io, .{
            .base_system = opts.base_system,
            .path = path,
            .open_mode = .resume_existing,
            .load_project_instructions = opts.load_project_instructions,
            .redactor = opts.redactor,
            .skills_enabled = opts.skills_enabled,
            .project_skills_trust = opts.project_skills_trust,
            .user_skills_root = opts.user_skills_root,
            .templates_enabled = opts.templates_enabled,
            .project_templates_trust = opts.project_templates_trust,
            .user_templates_root = opts.user_templates_root,
            .cwd = self.resume_cwd,
        }) catch {
            // SessionBusy / SessionNotFound / IoFailed / OOM → flat
            // fail-closed note (the old session is untouched).
            return error.StartFailed;
        };
        new.* = started;
        return new;
    }

    fn rebuildOverlayLines(self: *App) usize {
        var n: usize = 0;
        // Row kinds default to `.normal` for every overlay; the resume
        // branch re-marks group-header rows `.muted` as it pushes them.
        @memset(&self.resume_row_kinds, .normal);
        const push = struct {
            fn go(app: *App, text: []const u8, idx: *usize) void {
                if (idx.* >= app.overlay_line_bufs.len) return;
                const cap = app.overlay_line_bufs[idx.*].len;
                const take = @min(text.len, cap);
                @memcpy(app.overlay_line_bufs[idx.*][0..take], text[0..take]);
                app.overlay_line_lens[idx.*] = take;
                app.overlay_line_ptrs[idx.*] = app.overlay_line_bufs[idx.*][0..take];
                idx.* += 1;
            }
        }.go;

        switch (self.overlay.kind) {
            .none => {},
            .help => {
                // Shortcut reference (read-only; Enter/Esc close). Lines
                // are display-only — never routed into the editor.
                push(self, "Enter          发送消息", &n);
                push(self, "/              命令面板", &n);
                push(self, "F1 / /help     本帮助", &n);
                push(self, "── 权限 / 显示 ──", &n);
                push(self, "Ctrl+O         权限模式 ask/auto/bypass", &n);
                push(self, "Ctrl+T         thinking 显示开关", &n);
                push(self, "Ctrl+K         tasks 面板（可收缩，无任务时隐藏）", &n);
                push(self, "  j/k · ↑/↓    选择任务（聚焦后）", &n);
                push(self, "  Space        展开/折叠输出", &n);
                push(self, "  Esc          取消聚焦", &n);
                push(self, "── 滚动 ──", &n);
                push(self, "PgUp/PgDn      滚动 transcript（行）", &n);
                push(self, "鼠标滚轮        滚动 transcript", &n);
                push(self, "── 编辑器 ──", &n);
                push(self, "↑/↓            输入历史", &n);
                push(self, "Home/End       光标 行首/行尾", &n);
                push(self, "Ctrl+A/E       光标 行首/行尾", &n);
                push(self, "Ctrl+W         删除前一个词", &n);
                push(self, "Ctrl+U         删除至行首", &n);
                push(self, "── 会话 ──", &n);
                push(self, "Alt+S          打断（steering）", &n);
                push(self, "Alt+F          追问（follow-up）", &n);
                push(self, "Ctrl+C         取消运行 / 再按退出", &n);
                push(self, "Ctrl+D         退出", &n);
                push(self, "Esc            关闭面板", &n);
            },
            .slash_palette => {
                const filter = slash_route.slashFilter(self.editor.slice()) orelse "";
                var matches: [overlay_mod.builtin_names.len][]const u8 = undefined;
                const m = overlay_mod.matchBuiltins(filter, &matches);
                var i: usize = 0;
                while (i < m) : (i += 1) push(self, matches[i], &n);
                if (n == 0) push(self, "(no builtin match — Enter submits)", &n);
            },
            .settings => {
                push(self, self.perm_label, &n);
                push(self, self.shell_label, &n);
                push(self, self.model_label, &n);
                push(self, self.palette.id, &n);
            },
            .model => {
                if (self.model_ids.len == 0) {
                    push(self, self.model_label, &n);
                } else {
                    for (self.model_ids) |id| {
                        if (n >= self.overlay_line_bufs.len) break;
                        push(self, id, &n);
                    }
                }
            },
            .theme => {
                // Built-ins first, then lazily-discovered user themes.
                for (theme_mod.builtin_ids) |bid| {
                    if (n >= self.overlay_line_bufs.len) break;
                    push(self, bid, &n);
                }
                if (self.themes_root) |root| {
                    var list: std.ArrayList([]const u8) = .empty;
                    defer {
                        // Builtin ids (compile-time literals) must never be
                        // freed; only owned user-theme dups are. The old
                        // single-id check freed the newer builtins
                        // (ocean/mint/light) as if they were user themes →
                        // free of static memory (crash).
                        theme_mod.freeThemeList(self.gpa, list.items);
                        list.deinit(self.gpa);
                    }
                    if (self.host_io) |io| {
                        theme_mod.listThemeIds(self.gpa, io, root, &list) catch {};
                    }
                    for (list.items) |id| {
                        if (std.mem.eql(u8, id, theme_mod.builtin_id)) continue;
                        if (n >= self.overlay_line_bufs.len) break;
                        push(self, id, &n);
                    }
                }
            },
            .@"resume" => {
                // Session browser (session-tree-001): rows are
                // `{rel} {mtime} {size}` for sessions (`rel` = "stem" or
                // "proj/stem") plus muted `{project}/` group headers that
                // are non-selectable. Labels (stems + group names) go
                // through the SAME redaction pipeline as setIdentity
                // (filenames can embed secrets); the raw rel path is kept
                // in parallel scratch so selection maps back to the real
                // file. Cap 24 rows incl. headers (overlay_line_bufs
                // capacity).
                @memset(&self.resume_stem_lens, 0);
                var list: std.ArrayList(coding.session_store.SessionEntry) = .empty;
                defer {
                    for (list.items) |item| self.gpa.free(item.rel_path);
                    list.deinit(self.gpa);
                }
                if (self.host_io) |io| {
                    coding.session_store.listSessionEntries(self.gpa, io, self.resume_cwd, self.pinnedSessionRoot(), &list) catch {
                        // Fail closed: a listing I/O error is an empty list.
                        list.clearRetainingCapacity();
                    };
                }
                if (list.items.len == 0) {
                    push(self, "(no sessions)", &n);
                } else {
                    var prev_group: ?[]const u8 = null;
                    var i: usize = 0;
                    while (i < list.items.len and n < self.overlay_line_bufs.len) : (i += 1) {
                        const entry = list.items[i];
                        const group = groupPrefix(entry.rel_path);
                        if (group) |proj| {
                            if (prev_group == null or !std.mem.eql(u8, prev_group.?, proj)) {
                                // Group header `{project}/`: muted +
                                // non-selectable (kind flag); emitted only
                                // when at least one session row can follow.
                                if (n + 1 >= self.overlay_line_bufs.len) break;
                                var proj_buf: [96]u8 = undefined;
                                const redacted = present.presentInto(self.gpa, self.redactor, &proj_buf, proj);
                                const take: usize = if (redacted < proj_buf.len) blk: {
                                    proj_buf[redacted] = '/';
                                    break :blk redacted + 1;
                                } else redacted;
                                self.resume_row_kinds[n] = .muted;
                                push(self, proj_buf[0..take], &n);
                                prev_group = proj;
                            }
                        } else {
                            prev_group = null;
                        }
                        if (n >= self.overlay_line_bufs.len) break;
                        // Session row: `{rel} {mtime} {size}` — the raw rel
                        // path backs the row (parallel scratch) while the
                        // displayed label is redacted; mtime+size sit at the
                        // right of the row within the 96-byte cap (the stem
                        // truncates first, so metadata stays visible).
                        var meta_buf: [24]u8 = undefined;
                        const mtime_str = formatMtimeUtc(&meta_buf, entry.mtime_ns);
                        var size_buf: [16]u8 = undefined;
                        const size_str = formatSizeLabel(&size_buf, entry.size_bytes);
                        const meta_len = mtime_str.len + 1 + size_str.len;
                        var stem_buf: [96]u8 = undefined;
                        const stem_budget = self.overlay_line_bufs[n].len -| (meta_len + 1);
                        const rel_redacted = present.presentInto(self.gpa, self.redactor, stem_buf[0..stem_budget], entry.rel_path);
                        const take = @min(entry.rel_path.len, self.resume_stem_bufs[n].len);
                        @memcpy(self.resume_stem_bufs[n][0..take], entry.rel_path[0..take]);
                        self.resume_stem_lens[n] = take;
                        stem_buf[rel_redacted] = ' ';
                        const m_off = rel_redacted + 1;
                        @memcpy(stem_buf[m_off..][0..mtime_str.len], mtime_str);
                        const s_off = m_off + mtime_str.len;
                        stem_buf[s_off] = ' ';
                        @memcpy(stem_buf[s_off + 1 ..][0..size_str.len], size_str);
                        push(self, stem_buf[0 .. s_off + 1 + size_str.len], &n);
                    }
                }
            },
        }
        self.overlay_line_count = n;
        self.overlay.clampCursor(n);
        return n;
    }

    fn enqueueControl(self: *App, kind: enum { steering, follow_up }) void {
        const session = self.session orelse {
            self.setNote("control_error");
            return;
        };
        const text = self.editor.slice();
        if (text.len == 0) {
            self.setNote("control_empty");
            return;
        }
        if (!present.isValidUtf8(text)) {
            self.setNote("invalid_utf8");
            return;
        }
        const res = switch (kind) {
            .steering => session.enqueueSteering(text),
            .follow_up => session.enqueueFollowUp(text),
        };
        res catch |err| {
            const note: []const u8 = switch (err) {
                error.EmptyMessage => "control_empty",
                error.MessageTooLong => "control_too_long",
                error.QueueFull => "control_queue_full",
                error.InvalidUtf8 => "invalid_utf8",
            };
            self.setNote(note);
            return;
        };
        self.setNote(if (kind == .steering) "steering_queued" else "followup_queued");
    }

    pub fn dispatchReply(self: *App) error{ Busy, StartFailed }!void {
        if (self.worker_active) {
            self.setNote("busy_locked");
            return error.Busy;
        }
        const agent = self.agent orelse return error.StartFailed;
        const session = self.session orelse return error.StartFailed;
        const text = self.editor.slice();
        const routed = slash_route.routeSubmit(self.gpa, session, text) catch |err| {
            const note: []const u8 = switch (err) {
                error.UnknownSkill => "unknown_skill",
                error.UnknownTemplate => "unknown_template",
                error.ArgumentsTooLarge => "template_args_too_large",
                error.ExpansionTooLarge => "template_expansion_too_large",
                error.OutOfMemory => "slash_oom",
            };
            self.setNote(note);
            return;
        };
        switch (routed) {
            .open_overlay => |kind| {
                self.history.pushAccepted(text);
                self.editor.clear();
                self.overlay.open(kind);
                _ = self.rebuildOverlayLines();
                return;
            },
            .note => |n| {
                self.setNote(n);
                return;
            },
            .prompt => |p| {
                self.history.pushAccepted(text);
                // The submitted input enters the transcript as a user card,
                // paired with the assistant reply that follows (Grok-style
                // input/output correspondence). Redaction handled inside.
                // Guard: an empty/whitespace-only line never publishes a
                // phantom user card.
                if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
                    self.card_ring.publishUser(self.gpa, self.redactor, text);
                }
                const owned: []u8 = if (p.owned)
                    @constCast(p.text)
                else
                    (self.gpa.dupe(u8, p.text) catch return error.StartFailed);
                self.worker_prompt = owned;
                self.editor.clear();
                self.overlay.close();
                // New turn → re-engage bottom-follow (hyper goto_bottom
                // semantics); prepare re-pins the offset next paint.
                self.sb.gotoBottom(self.last_viewport_h);
                self.state = .busy;
                self.setNote("(starting…)");
                // New turn: clear sticky host_error from a previous failure so
                // the transcript does not keep a red card while retrying.
                self.card_ring.clearHostError();
                self.worker_finished.store(false, .release);
                self.worker_had_error.store(false, .release);
                self.worker_active = true;

                const thread = std.Thread.spawn(.{}, workerMain, .{ self, agent, session }) catch {
                    self.worker_active = false;
                    self.state = .idle;
                    self.gpa.free(self.worker_prompt);
                    self.worker_prompt = &[_]u8{};
                    return error.StartFailed;
                };
                self.worker = thread;
            },
        }
    }

    fn workerMain(self: *App, agent: *coding.Agent, session: *coding.Session) void {
        defer {
            self.worker_finished.store(true, .release);
            self.wake();
        }
        const prompt = self.worker_prompt;
        _ = agent.reply(session, prompt) catch |err| {
            self.worker_had_error.store(true, .release);
            // Surface the typed stop category so the sticky host_error card is
            // actionable (provider_error / max_turns / …), not opaque "reply_error".
            // Covers ReplyError = loop.RunError || session_store.Error || trace.Error.
            const body: []const u8 = switch (err) {
                error.ProviderFailed => "provider_error",
                error.MaxTurnsExceeded => "max_turns",
                error.OutOfMemory => "out_of_memory",
                error.InvalidToolset => "invalid_toolset",
                error.InvalidContext => "invalid_context",
                error.TraceFailed, error.TraceIoFailed, error.TraceSerializationFailed => "trace_error",
                error.InvalidPath => "invalid_path",
                error.SessionNotFound, error.SessionAlreadyExists, error.SessionBusy, error.InvalidSession, error.UnsupportedSchema, error.IoFailed => "session_error",
            };
            self.card_ring.publishHostErrorFixed("host_error", body);
            return;
        };
        // Successful reply: drop sticky prior host_error so a recovered session
        // does not keep showing a red card.
        self.card_ring.clearHostError();
    }

    fn paint(self: *App, term: *terminal_mod.Terminal) error{WriteFailed}!void {
        const sz = term.size();
        // Skip when nothing changed since the last paint. The size check
        // always runs (idle-terminal resizes still repaint), and a skipped
        // paint cannot fail — callers keep the error surface unchanged.
        if (!self.dirty and self.last_painted_size != null) {
            const last = self.last_painted_size.?;
            if (last.cols == sz.cols and last.rows == sz.rows) return;
        }
        const n = self.card_ring.snapshot(&self.snap_buf);
        const session = self.session;
        var steer: u32 = 0;
        var follow: u32 = 0;
        if (session) |s| {
            steer = @intCast(s.steeringPending());
            follow = @intCast(s.followUpPending());
        }
        const modal = self.permission.snapshot();
        if (self.overlay.isOpen()) _ = self.rebuildOverlayLines();
        var running_tasks: u32 = 0;
        if (self.subagent_registry) |reg| {
            running_tasks = @intCast(reg.countByStatus(.running) + reg.countByStatus(.pending));
        }
        const tick_ms: u64 = @import("zag-types").monoNowNs() / std.time.ns_per_ms;
        const facts = render.StatusFacts{
            .id_display = self.idDisplay(),
            .open_display = self.open_display.label(),
            .session_configured = self.session_configured_ui.load(.acquire),
            .perm = self.perm_label,
            .shell = self.shell_label,
            .state = self.state,
            .status_note = self.noteSlice(),
            .steering_pending = steer,
            .followup_pending = follow,
            .model = self.model_label,
            .theme_id = self.palette.id,
            .show_thinking = self.show_thinking,
            .scroll = self.sb.scroll_offset,
            .running_tasks = running_tasks,
            .tick_ms = tick_ms,
        };
        const ov = render.OverlayPaint{
            .kind = self.overlay.kind,
            .cursor = self.overlay.cursor,
            .lines = self.overlay_line_ptrs[0..self.overlay_line_count],
            .row_kinds = self.resume_row_kinds[0..self.overlay_line_count],
        };
        // Collapsible tasks pane (grok-style):
        //   - empty registry → always hidden (no empty box)
        //   - running/pending → auto-open (unfocused so Enter still sends)
        //   - idle after auto-open → auto-close
        if (self.subagent_registry) |reg| {
            const live = reg.liveCount();
            const running = reg.countByStatus(.running) + reg.countByStatus(.pending);
            if (live == 0) {
                self.tasks_visible = false;
                self.tasks_focused = false;
                self.tasks_expanded = false;
                self.tasks_auto = false;
            } else if (running > 0) {
                if (!self.tasks_visible) {
                    self.tasks_visible = true;
                    self.tasks_auto = true;
                    self.tasks_focused = false; // never steal Enter while running
                }
            } else if (self.tasks_auto) {
                self.tasks_visible = false;
                self.tasks_focused = false;
                self.tasks_expanded = false;
                self.tasks_auto = false;
            }
            if (live > 0 and self.tasks_cursor >= live) self.tasks_cursor = live - 1;
        } else {
            self.tasks_visible = false;
            self.tasks_focused = false;
            self.tasks_expanded = false;
            self.tasks_auto = false;
        }

        // Compute the layout once here: renderFrame draws it. Cards region is
        // borderless; reserve 1 col for the scrollbar track and 1 row for the
        // scrollback paint window math (viewport_h = h-1 keeps prior paging
        // contracts).
        const turn_vis = self.state == .busy or self.state == .closing or self.state == .@"error";
        const layout = layout_mod.compute(sz, n, modal.pending, facts.status_note.len > 0, 0, self.editor.lineCount(), self.tasks_visible, turn_vis);
        const viewport_h: usize = @max(layout.cards.h -| 1, 1);
        const content_w: u16 = @max(layout.cards.w -| 1, 1);
        self.last_viewport_h = viewport_h;
        // Settle geometry + re-pin follow before painting (review #7 order).
        // Card fold/truncate opts must be set BEFORE measure (prepare) and draw.
        render.setCardPaintOpts(.{
            .thinking_expanded = self.thinking_expanded,
            .tool_body_max_lines = 6,
        });
        _ = self.sb.prepare(
            self.snap_buf[0..n],
            content_w,
            viewport_h,
            render.measureCardHeight,
            scrollback_mod.estimateCard,
        );
        const tasks_opts = render.TasksPaneOpts{
            .cursor = self.tasks_cursor,
            .expanded = self.tasks_expanded,
            .tick_ms = tick_ms,
            .focused = self.tasks_focused,
        };
        try render.renderFrame(term, sz, layout, facts, self.snap_buf[0..n], &self.editor, modal, &self.palette, ov, &self.sb, self.subagent_registry, tasks_opts);
        self.dirty = false;
        self.last_painted_size = sz;
    }

    fn fixedStderr(self: *App, msg: []const u8) void {
        _ = self;
        if (builtin.os.tag == .linux and !builtin.link_libc) {
            _ = std.os.linux.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        } else {
            _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        }
    }
};

test "app create preallocates and destroy frees" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    try std.testing.expect(app.editor_storage.len == c.editor_max_bytes);
    try std.testing.expect(app.wake_r >= 0);
    app.destroy();
}

// ── tui-streaming-001 fixtures: delta accumulation / clear / cap / redaction /
// turn boundary on the progressive assistant card ────────────────────────────

fn newTestApp(gpa: std.mem.Allocator, redactor: *const coding.redact.Redactor) !*App {
    const app = try App.create(gpa);
    app.redactor = redactor;
    return app;
}

/// Newest ordinary card whose title starts with "assistant" (the progressive /
/// turn card), or null.
fn newestAssistantCard(app: *App) ?cards_mod.CardSlot {
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const slot = &snap[i];
        if (slot.occupied and std.mem.startsWith(u8, slot.titleSlice(), "assistant")) {
            return slot.*;
        }
    }
    return null;
}

test "tui-streaming: deltas accumulate in order into the progressive card" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    App.onObserver(app, .{ .assistant_delta = "Hel" });
    App.onObserver(app, .{ .assistant_delta = "lo " });
    App.onObserver(app, .{ .assistant_delta = "world" });

    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant progressive", card.titleSlice());
    try std.testing.expectEqualStrings("Hello world", card.bodySlice());
    try std.testing.expectEqual(@as(usize, 11), app.delta_len);
}

test "tui-streaming: delta_clear resets the accumulated body" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    App.onObserver(app, .{ .assistant_delta = "attempt one" });
    App.onObserver(app, .{ .assistant_delta_clear = {} });
    try std.testing.expectEqual(@as(usize, 0), app.delta_len);
    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", card.bodySlice());
    // Accumulation continues cleanly after the clear.
    App.onObserver(app, .{ .assistant_delta = "attempt two" });
    const card2 = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("attempt two", card2.bodySlice());
}

test "tui-streaming: cap 4096 truncates the accumulator" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    const big = "a" ** (c.card_body_max_bytes + 1000);
    App.onObserver(app, .{ .assistant_delta = big });
    try std.testing.expectEqual(c.card_body_max_bytes, app.delta_len);
    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(c.card_body_max_bytes, card.bodySlice().len);
    // Further deltas are dropped at the cap (no overflow).
    App.onObserver(app, .{ .assistant_delta = "more" });
    try std.testing.expectEqual(c.card_body_max_bytes, app.delta_len);
}

test "tui-streaming: cap cut lands on a UTF-8 codepoint boundary" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    App.onObserver(app, .{ .assistant_delta = "a" ** (c.card_body_max_bytes - 1) });
    // "é" is 2 bytes; only 1 byte remains at the cap → the whole codepoint is
    // dropped, the buffer stays valid UTF-8.
    App.onObserver(app, .{ .assistant_delta = "\xc3\xa9" });
    try std.testing.expectEqual(c.card_body_max_bytes - 1, app.delta_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(app.delta_buf[0..app.delta_len]));
    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(c.card_body_max_bytes - 1, card.bodySlice().len);
    try std.testing.expectEqual(@as(u8, 'a'), card.bodySlice()[card.bodySlice().len - 1]);
}

test "tui-streaming: delta body is redacted in the card" {
    const gpa = std.testing.allocator;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = true });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    App.onObserver(app, .{ .assistant_delta = "hold " });
    App.onObserver(app, .{ .assistant_delta = secret });
    const card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, card.bodySlice(), secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, card.bodySlice(), coding.redact.marker) != null);
}

test "tui-thinking: reasoning publishes a card only when the toggle is on" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    // Toggle off (default): reasoning is NOT published.
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "answer", .has_tools = false, .reasoning = "hidden chain of thought" } });
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_thinking: usize = 0;
    for (snap[0..n]) |*slot| {
        if (slot.occupied and std.mem.eql(u8, slot.titleSlice(), "thinking")) saw_thinking += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), saw_thinking);

    // Toggle on: reasoning publishes as a `· thinking` card BEFORE the
    // assistant turn card (thinking precedes content).
    _ = app.handleKey(.ctrl_t);
    try std.testing.expect(app.show_thinking);
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 2, .text = "answer two", .has_tools = false, .reasoning = "planning the reply" } });
    const n2 = app.card_ring.snapshot(&snap);
    var thinking_idx: ?usize = null;
    var assistant_idx: ?usize = null;
    for (snap[0..n2], 0..) |*slot, i| {
        if (!slot.occupied) continue;
        if (std.mem.eql(u8, slot.titleSlice(), "thinking")) thinking_idx = i;
        if (std.mem.eql(u8, slot.titleSlice(), "assistant turn=2")) assistant_idx = i;
    }
    try std.testing.expect(thinking_idx != null);
    try std.testing.expect(assistant_idx != null);
    try std.testing.expect(thinking_idx.? < assistant_idx.?);
    try std.testing.expectEqualStrings("planning the reply", snap[thinking_idx.?].bodySlice());

    // Toggle off again: the NEXT reasoning is not published.
    _ = app.handleKey(.ctrl_t);
    try std.testing.expect(!app.show_thinking);
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 3, .text = "answer three", .has_tools = false, .reasoning = "more thinking" } });
    const n3 = app.card_ring.snapshot(&snap);
    var saw_thinking3: usize = 0;
    for (snap[0..n3]) |*slot| {
        if (slot.occupied and std.mem.eql(u8, slot.titleSlice(), "thinking")) saw_thinking3 += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), saw_thinking3); // only turn 2's card
}

test "tui-thinking: meta line shows the toggle state" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40 idle: shortcuts=1, editor_y=36
    var buf: [512]u8 = undefined;
    const off = readRow(&rec, 36, &buf);
    try std.testing.expect(std.mem.indexOf(u8, off, "think:off") != null);
    _ = app.handleKey(.ctrl_t);
    try app.paint(&rec.pt.term);
    const on = readRow(&rec, 36, &buf);
    try std.testing.expect(std.mem.indexOf(u8, on, "think:on") != null);
}

/// Newest card whose title starts with "thinking" (progressive or final), or null.
fn newestThinkingCard(app: *App) ?cards_mod.CardSlot {
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const slot = &snap[i];
        if (slot.occupied and std.mem.startsWith(u8, slot.titleSlice(), "thinking")) {
            return slot.*;
        }
    }
    return null;
}

test "tui-thinking-streaming: thinking_delta builds progressive card gated by toggle" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    // Toggle off (default): thinking deltas are ignored — no card at all.
    App.onLifecycle(app, .{ .thinking_delta = "hidden" });
    try std.testing.expect(newestThinkingCard(app) == null);
    try std.testing.expectEqual(@as(usize, 0), app.thinking_len);

    // Toggle on: deltas accumulate into a "thinking progressive" card.
    _ = app.handleKey(.ctrl_t);
    try std.testing.expect(app.show_thinking);
    App.onLifecycle(app, .{ .thinking_delta = "step " });
    App.onLifecycle(app, .{ .thinking_delta = "one" });
    try std.testing.expectEqual(@as(usize, 8), app.thinking_len);
    const card = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(TITLE_THINKING_PROGRESSIVE, card.titleSlice());
    try std.testing.expectEqualStrings("step one", card.bodySlice());
}

test "tui-thinking-streaming: assistant_message replaces progressive with final card" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    _ = app.handleKey(.ctrl_t);
    App.onLifecycle(app, .{ .thinking_delta = "step " });
    App.onLifecycle(app, .{ .thinking_delta = "one" });
    // Complete turn: progressive is replaced + retitled to "thinking".
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "answer", .has_tools = false, .reasoning = "step one" } });
    try std.testing.expectEqual(@as(usize, 0), app.thinking_len);
    const card = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("thinking", card.titleSlice());
    try std.testing.expectEqualStrings("step one", card.bodySlice());
    // No duplicate: the progressive card was consumed, not re-published.
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var thinking_cards: usize = 0;
    for (snap[0..n]) |*slot| {
        if (!slot.occupied) continue;
        if (std.mem.startsWith(u8, slot.titleSlice(), "thinking")) thinking_cards += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), thinking_cards);
}

test "tui-thinking-streaming: reasoning null drops the progressive card" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    _ = app.handleKey(.ctrl_t);
    App.onLifecycle(app, .{ .thinking_delta = "partial" });
    try std.testing.expect(newestThinkingCard(app) != null);
    // The turn completed without reasoning: the partial card is dropped.
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "answer", .has_tools = false, .reasoning = null } });
    try std.testing.expect(newestThinkingCard(app) == null);
    // Empty (non-null) reasoning drops too.
    App.onLifecycle(app, .{ .thinking_delta = "stale" });
    try std.testing.expect(newestThinkingCard(app) != null);
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 2, .text = "answer two", .has_tools = false, .reasoning = "" } });
    try std.testing.expect(newestThinkingCard(app) == null);
}

test "tui-thinking-streaming: non-stream reasoning publishes a fresh thinking card" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    _ = app.handleKey(.ctrl_t);
    // No deltas streamed (non-stream fallback): the complete turn's reasoning
    // publishes fresh (replace-or-publish fallback).
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "answer", .has_tools = false, .reasoning = "planning the reply" } });
    const card = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("thinking", card.titleSlice());
    try std.testing.expectEqualStrings("planning the reply", card.bodySlice());
}

test "tui-thinking-streaming: multi-turn thinking never clobbers prior turn card" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    _ = app.handleKey(.ctrl_t);
    // Turn 1: streamed thinking finalized as a "thinking" card.
    App.onLifecycle(app, .{ .thinking_delta = "turn one thought" });
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "one", .has_tools = false, .reasoning = "turn one thought" } });
    // Turn 2: new deltas publish a FRESH progressive card (the prefix
    // "thinking progressive" never matches the finalized "thinking" card).
    App.onLifecycle(app, .{ .thinking_delta = "turn two" });
    App.onLifecycle(app, .{ .thinking_delta = " thought" });
    var prog = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(TITLE_THINKING_PROGRESSIVE, prog.titleSlice());
    try std.testing.expectEqualStrings("turn two thought", prog.bodySlice());
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 2, .text = "two", .has_tools = false, .reasoning = "turn two thought" } });

    // Exactly two finalized thinking cards; bodies per turn; no progressive.
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_t1 = false;
    var saw_t2 = false;
    var saw_progressive = false;
    for (snap[0..n]) |*slot| {
        if (!slot.occupied) continue;
        if (std.mem.eql(u8, slot.titleSlice(), "thinking")) {
            if (std.mem.eql(u8, slot.bodySlice(), "turn one thought")) saw_t1 = true;
            if (std.mem.eql(u8, slot.bodySlice(), "turn two thought")) saw_t2 = true;
        }
        if (std.mem.eql(u8, slot.titleSlice(), TITLE_THINKING_PROGRESSIVE)) saw_progressive = true;
    }
    try std.testing.expect(saw_t1);
    try std.testing.expect(saw_t2);
    try std.testing.expect(!saw_progressive);
}

test "tui-thinking-streaming: delta_clear resets both progressive cards" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    _ = app.handleKey(.ctrl_t);
    App.onLifecycle(app, .{ .thinking_delta = "attempt one" });
    App.onObserver(app, .{ .assistant_delta = "partial " });
    App.onObserver(app, .{ .assistant_delta_clear = {} });
    // ONE clear resets BOTH accumulators and repaints both progressive cards
    // with empty bodies.
    try std.testing.expectEqual(@as(usize, 0), app.thinking_len);
    try std.testing.expectEqual(@as(usize, 0), app.delta_len);
    const think = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", think.bodySlice());
    const asst = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", asst.bodySlice());
    // Accumulation continues cleanly after the clear.
    App.onLifecycle(app, .{ .thinking_delta = "attempt two" });
    const think2 = newestThinkingCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("attempt two", think2.bodySlice());
}

/// Read one full row into `buf` (RecTerm.cellText is single-cell).
fn readRow(rec: *const RecTerm, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var col: u16 = 0;
    while (col < 80) : (col += 1) {
        var cell: [8]u8 = undefined;
        const g = rec.cellText(col, row, &cell);
        if (g.len == 0) continue;
        if (n + g.len > buf.len) break;
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

test "tui-streaming: complete assistant_message resets at turn boundary" {
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();

    App.onObserver(app, .{ .assistant_delta = "one" });
    App.onObserver(app, .{ .assistant_delta = " two" });
    // Complete message: observer full-text snapshot, then lifecycle turn card.
    App.onObserver(app, .{ .assistant_text = "one two" });
    App.onLifecycle(app, .{ .assistant_message = .{ .turn = 1, .text = "one two", .has_tools = false } });
    try std.testing.expectEqual(@as(usize, 0), app.delta_len);
    const turn_card = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("assistant turn=1", turn_card.titleSlice());
    try std.testing.expectEqualStrings("one two", turn_card.bodySlice());
    // Next turn's deltas start clean (no cross-turn accumulation) AND the
    // finalized turn-1 card survives: the first delta of turn 2 publishes a
    // FRESH progressive card (progressive-only prefix), never clobbering the
    // completed "assistant turn=1" card with partial text.
    App.onObserver(app, .{ .assistant_delta = "next" });
    try std.testing.expectEqual(@as(usize, 4), app.delta_len);
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_turn1: usize = 0;
    var saw_progressive: usize = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const slot = &snap[i];
        if (!slot.occupied) continue;
        if (std.mem.eql(u8, slot.titleSlice(), "assistant turn=1")) {
            saw_turn1 += 1;
            // Finalized body unchanged by the turn-2 delta.
            try std.testing.expectEqualStrings("one two", slot.bodySlice());
        }
        if (std.mem.eql(u8, slot.titleSlice(), TITLE_PROGRESSIVE)) saw_progressive += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), saw_turn1);
    try std.testing.expectEqual(@as(usize, 1), saw_progressive);
    const newest = newestAssistantCard(app) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("next", newest.bodySlice());
}

// ── tui-layout-001 fixtures: dirty-flag presenter (cell-diff assertions) ────

/// Offscreen vaxis-backed recording terminal (tui-vaxis-001 RecTerm rework):
/// `paint()` renders into the standalone offscreen screen; tests assert cells
/// (byte-drain is gone — vaxis's diff owns the byte stream).
const RecTerm = struct {
    pt: terminal_mod.PaintTerminal,

    fn init(gpa: std.mem.Allocator) !RecTerm {
        return .{ .pt = try terminal_mod.PaintTerminal.init(gpa) };
    }

    fn deinit(self: *RecTerm, gpa: std.mem.Allocator) void {
        self.pt.deinit(gpa);
    }

    fn writeCell(self: *RecTerm, col: u16, row: u16, grapheme: []const u8) void {
        self.pt.writeCell(col, row, grapheme);
    }

    fn cellText(self: *const RecTerm, col: u16, row: u16, buf: []u8) []const u8 {
        return self.pt.cellText(col, row, buf);
    }
};

fn expectCellText(rec: *const RecTerm, col: u16, row: u16, expected: []const u8) !void {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(expected, rec.cellText(col, row, &buf));
}

test "tui-layout: first paint always happens" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    app.dirty = false; // explicitly clean — first paint must still run
    try app.paint(&rec.pt.term);
    try std.testing.expect(!app.dirty);
    try std.testing.expect(app.last_painted_size != null);
    // Cell proof: borderless transcript + rounded editor box at the bottom.
    // 80×40 idle: shortcuts=1, editor_y=36 (h=3).
    try expectCellText(&rec, 0, 0, "("); // "(no events yet)"
    try expectCellText(&rec, 0, 36, "╭");
    try expectCellText(&rec, 1, 37, "❯");
    try expectCellText(&rec, 0, 38, "╰");
}

test "tui-layout: no-change poll skips render (canary survives)" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    try app.paint(&rec.pt.term); // first paint
    try std.testing.expect(!app.dirty);
    // Canary: a real paint clears the whole screen (root.clear), so a
    // surviving canary proves the no-change paint early-returned.
    rec.writeCell(79, 39, "X");
    try app.paint(&rec.pt.term);
    try expectCellText(&rec, 79, 39, "X");
}

test "tui-layout: key input paints once" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    _ = app.handleKey(.{ .char = "x" });
    try std.testing.expect(app.dirty);
    // Canary lives in the blank transcript interior — the frame's bottom
    // border owns (79, 39) now (closed-frame geometry).
    rec.writeCell(40, 20, "X");
    try app.paint(&rec.pt.term);
    try std.testing.expect(!app.dirty);
    try expectCellText(&rec, 40, 20, " ");
}

test "tui-layout: worker join paints" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    app.afterWorkerJoin();
    try std.testing.expect(app.dirty);
    rec.writeCell(40, 20, "X");
    try app.paint(&rec.pt.term);
    try std.testing.expect(!app.dirty);
    try expectCellText(&rec, 40, 20, " ");
}

test "tui-layout: idle-terminal resize repaints (size re-read in paint)" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    try app.paint(&rec.pt.term); // first paint; TestTty term.size() == 80×40
    try std.testing.expect(!app.dirty);
    // Simulate a resize between polls: last painted size no longer matches
    // the size paint() re-reads, so the size check fires and repaints.
    app.last_painted_size = .{ .cols = 79, .rows = 23 };
    rec.writeCell(40, 20, "X");
    try app.paint(&rec.pt.term);
    try expectCellText(&rec, 40, 20, " "); // repainted → canary erased
    const last = app.last_painted_size orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 80), last.cols);
    try std.testing.expectEqual(@as(u16, 40), last.rows);
}

test "tui-layout: winsize event resizes vaxis screen and repaints" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);

    try app.paint(&rec.pt.term); // first paint
    try std.testing.expect(!app.dirty);

    // Simulate a bridge-delivered winsize event.
    _ = rec.pt.term.ring.tryPush(.{ .winsize = .{
        .rows = 30,
        .cols = 100,
        .x_pixel = 0,
        .y_pixel = 0,
    } }) catch {};
    _ = app.drainBridgeEvents(&rec.pt.term);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(u16, 100), rec.pt.term.vx.screen.width);
    try std.testing.expectEqual(@as(u16, 30), rec.pt.term.vx.screen.height);

    // Repaint reconciles geometry (dirty cleared; frame drawn at the tty
    // size the paint re-reads).
    try app.paint(&rec.pt.term);
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqual(@as(u16, 80), rec.pt.term.vx.screen.width);
    try std.testing.expectEqual(@as(u16, 40), rec.pt.term.vx.screen.height);
}

test "tui-layout: note update sets dirty" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();

    app.setNote("hello");
    try std.testing.expect(app.dirty);
    try std.testing.expectEqualStrings("hello", app.noteSlice());
}

// ── tui-polish-001 input completeness: line editing + page scroll + overlay
// navigation ────────────────────────────────────────────────────────────────

test "tui-input: home/end/ctrl-a/ctrl-e move the editor cursor" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    _ = app.editor.insert("one\ntwo");
    app.editor.cursor = 5;
    _ = app.handleKey(.home);
    try std.testing.expectEqual(@as(usize, 4), app.editor.cursor);
    _ = app.handleKey(.end);
    try std.testing.expectEqual(@as(usize, 7), app.editor.cursor);
    _ = app.handleKey(.ctrl_a);
    try std.testing.expectEqual(@as(usize, 4), app.editor.cursor);
    _ = app.handleKey(.ctrl_e);
    try std.testing.expectEqual(@as(usize, 7), app.editor.cursor);
}

test "tui-input: ctrl-w/u edit the buffer; ctrl-k collapses empty tasks" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    _ = app.editor.insert("abc def");
    app.editor.cursor = 7;
    _ = app.handleKey(.ctrl_w);
    try std.testing.expectEqualStrings("abc ", app.editor.slice());
    _ = app.handleKey(.ctrl_u);
    try std.testing.expectEqualStrings("", app.editor.slice());
    // Empty registry: Ctrl+K must NOT open an empty pane (collapsible).
    try std.testing.expect(!app.tasks_visible);
    _ = app.handleKey(.ctrl_k);
    try std.testing.expect(!app.tasks_visible);
    try std.testing.expect(!app.tasks_focused);
}


test "tui-input: Enter still sends while tasks pane is visible unfocused" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    app.tasks_visible = true;
    app.tasks_focused = false;
    app.tasks_expanded = false;
    _ = app.editor.insert("hello");
    // Without a bound agent, dispatchReply fails StartFailed — but Enter must
    // still take the editor path (not expand tasks).
    _ = app.handleKey(.enter);
    try std.testing.expect(!app.tasks_expanded);
    try std.testing.expect(app.tasks_visible); // unfocused visible stays
}


test "tui-theme: switching builtins never frees static memory" {
    // Regression: reloadTheme used to register builtin ids (compile-time
    // literals) in owned_theme_id and free them on the next switch — crash.
    const gpa = std.testing.allocator;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    app.host_io = std.testing.io; // reloadTheme resolves through resolveActive

    // Simulate /theme selection of each builtin: persist + reload, twice
    // (the second reload is where the old code freed static memory).
    for (theme_mod.builtin_ids) |bid| {
        const n = @min(bid.len, app.theme_sel_buf.len);
        @memcpy(app.theme_sel_buf[0..n], bid[0..n]);
        app.theme_sel_len = n;
        app.theme_selected = app.theme_sel_buf[0..n];
        app.reloadTheme();
        try std.testing.expectEqualStrings(bid, app.palette.id);
        try std.testing.expect(app.owned_theme_id == null); // builtins never owned
        // Second reload (the free of the stale owned id path).
        app.reloadTheme();
        try std.testing.expectEqualStrings(bid, app.palette.id);
    }
    // Back to default.
    app.theme_selected = theme_mod.builtin_id;
    app.reloadTheme();
    try std.testing.expectEqualStrings(theme_mod.builtin_id, app.palette.id);
}

test "tui-theme: freeThemeList never frees builtin literals" {
    // Regression: the theme overlay freed every non-zag-default id — the
    // newer builtins (ocean/mint/light) are compile-time literals, and a
    // free of static memory aborts. freeThemeList must free ONLY the owned
    // user-theme dups.
    const gpa = std.testing.allocator;
    const user1 = try gpa.dupe(u8, "user-one");
    const user2 = try gpa.dupe(u8, "user-two");
    // No defers: freeThemeList takes ownership of the user-theme dups.
    // Mixed list as listThemeIds returns: builtins first, users after.
    const list = [_][]const u8{
        theme_mod.builtin_ids[0],
        theme_mod.builtin_ids[1],
        theme_mod.builtin_ids[2],
        theme_mod.builtin_ids[3],
        user1,
        user2,
    };
    theme_mod.freeThemeList(gpa, &list);
}
test "tui-input: page keys scroll rows and re-engage follow" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    // Fill the ring so the transcript overflows the 40-row viewport.
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var tbuf: [40]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "assistant turn={d}", .{i}) catch "assistant";
        // fromFixed bypasses redaction (no redactor in this test) — a null
        // redactor would replace the body with the unavailable marker.
        app.card_ring.publishOrdinaryPrepared(cards_mod.PreparedCard.fromFixed(t, "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four"));
    }
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40 → cards 37, viewport 36
    try std.testing.expectEqual(@as(usize, 35), app.last_viewport_h);
    try std.testing.expect(app.sb.total_height > 29); // overflows
    try std.testing.expect(app.sb.follow_mode); // fresh paint follows
    const bottom = app.sb.scroll_offset;
    _ = app.handleKey(.page_up);
    try std.testing.expect(!app.sb.follow_mode); // manual scroll leaves follow
    try std.testing.expect(app.sb.scroll_offset < bottom); // scrolled toward the top
    const up_offset = app.sb.scroll_offset;
    _ = app.handleKey(.page_down);
    try std.testing.expect(app.sb.scroll_offset > up_offset); // scrolled back
    // Overscroll at the bottom re-engages follow.
    _ = app.handleKey(.page_down);
    _ = app.handleKey(.page_down);
    try std.testing.expect(app.sb.follow_mode);
    try std.testing.expectEqual(bottom, app.sb.scroll_offset);
}

test "tui-input: mouse wheel scrolls the transcript rows" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var tbuf: [40]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "assistant turn={d}", .{i}) catch "assistant";
        app.card_ring.publishOrdinaryPrepared(cards_mod.PreparedCard.fromFixed(t, "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four"));
    }
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40 → viewport 29, content overflows
    try std.testing.expect(app.sb.follow_mode);
    const bottom = app.sb.scroll_offset;
    try std.testing.expect(bottom > 0); // content overflows

    const wheel = terminal_mod.Event{ .mouse = .{ .button = .wheel_up, .col = 1, .row = 1, .mods = .{}, .type = .press } };
    // Wheel up: scrolls the transcript back (never touches the editor).
    rec.pt.term.ring.push(wheel) catch unreachable;
    _ = app.drainBridgeEvents(&rec.pt.term);
    try std.testing.expect(!app.sb.follow_mode);
    try std.testing.expect(app.sb.scroll_offset < bottom);
    const up = app.sb.scroll_offset;
    try std.testing.expectEqualStrings("", app.editor.slice()); // editor untouched

    // Wheel down: scrolls forward; overscroll at the bottom re-engages.
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        rec.pt.term.ring.push(terminal_mod.Event{ .mouse = .{ .button = .wheel_down, .col = 1, .row = 1, .mods = .{}, .type = .press } }) catch unreachable;
        _ = app.drainBridgeEvents(&rec.pt.term);
    }
    try std.testing.expect(app.sb.follow_mode);
    try std.testing.expectEqual(bottom, app.sb.scroll_offset);
    try std.testing.expect(up > 0);
}

test "tui-input: ctrl+o cycles permission modes and auto-approves pending" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    // ask → auto → bypass → ask.
    _ = app.handleKey(.ctrl_o);
    try std.testing.expectEqual(permission_mod.Mode.auto, app.permission.mode());
    try std.testing.expectEqualStrings("auto", app.perm_label);
    _ = app.handleKey(.ctrl_o);
    try std.testing.expectEqual(permission_mod.Mode.bypass, app.permission.mode());
    try std.testing.expectEqualStrings("bypass", app.perm_label);
    _ = app.handleKey(.ctrl_o);
    try std.testing.expectEqual(permission_mod.Mode.ask, app.permission.mode());
    try std.testing.expectEqualStrings("ask", app.perm_label);

    // Modal pending + Ctrl+O → auto mode + the waiting request approves.
    app.permission.setPendingForTest(true);
    try std.testing.expect(app.permission.isPending());
    _ = app.handleKey(.ctrl_o);
    try std.testing.expectEqual(permission_mod.Mode.auto, app.permission.mode());
    try std.testing.expect(!app.permission.isPending());
}

test "tui-input: alt+enter multiline grows the editor region" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    _ = app.handleKey(.alt_enter);
    _ = app.handleKey(.alt_enter);
    try std.testing.expectEqual(@as(usize, 3), app.editor.lineCount());
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40: shortcuts=1, editor 2+3=5 → cards 34, viewport 33
    try std.testing.expectEqual(@as(usize, 33), app.last_viewport_h);
    // Prompt glyph is visible in the editor box.
    var buf: [512]u8 = undefined;
    var found_prompt = false;
    var r: u16 = 30;
    while (r <= 39) : (r += 1) {
        const row = readRow(&rec, r, &buf);
        if (std.mem.indexOf(u8, row, "❯") != null) found_prompt = true;
    }
    try std.testing.expect(found_prompt);
}

test "tui-input: paint records the cards viewport height for paging" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40
    try std.testing.expect(app.last_viewport_h > 0);
    // 80×40 idle: shortcuts=1, editor h=3 → cards h=36 → viewport = 35.
    try std.testing.expectEqual(@as(usize, 35), app.last_viewport_h);
}

test "tui-input: overlay home/end/page keys navigate" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    app.overlay.open(.help); // shortcut reference (grew with tasks pane lines)
    _ = app.handleKey(.end);
    try std.testing.expect(app.overlay.cursor >= 20);
    _ = app.handleKey(.home);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.cursor);
    _ = app.handleKey(.page_down);
    try std.testing.expectEqual(@as(usize, 5), app.overlay.cursor); // 5× moveDown
    _ = app.handleKey(.page_up);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.cursor); // 5× moveUp
}


// ── session-resume-tui-001 fixtures: listing / replay / redaction / fail-closed
// ────────────────────────────────────────────────────────────────────────────

const session_header_line = "{\"schema_version\":1,\"v\":1,\"type\":\"zag_session\",\"compaction_gen\":0}\n";

/// Point the app's resume overlay at `tmp.dir/sessions` (product path is
/// Io.Dir.cwd() + dirname of the bound session path; tests use a tmp dir).
fn wireResumeFixture(app: *App, tmp: *std.testing.TmpDir, io: Io) void {
    app.host_io = io;
    app.resume_cwd = tmp.dir;
    app.resume_root = "sessions";
}

/// Assert the next occupied card in `snap` (walking from `idx`) matches.
fn expectCard(
    snap: []const cards_mod.CardSlot,
    idx: *usize,
    n: usize,
    kind: cards_mod.CardKind,
    title: []const u8,
    body: []const u8,
) !void {
    try std.testing.expect(idx.* < n);
    const slot = &snap[idx.*];
    idx.* += 1;
    try std.testing.expect(slot.occupied);
    try std.testing.expectEqual(kind, slot.kind);
    try std.testing.expectEqualStrings(title, slot.titleSlice());
    try std.testing.expectEqualStrings(body, slot.bodySlice());
}

test "tui-resume: slash palette routes /resume to the resume overlay" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    _ = app.handleKey(.{ .char = "/" });
    for ("resume") |ch| {
        _ = app.handleKey(.{ .char = &[_]u8{ch} });
    }
    try std.testing.expectEqual(overlay_mod.Kind.slash_palette, app.overlay.kind);
    _ = app.handleKey(.enter);
    try std.testing.expectEqual(overlay_mod.Kind.@"resume", app.overlay.kind);
}

test "tui-resume: listing caps at 24 rows; empty dir shows placeholder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    try tmp.dir.createDirPath(io, "sessions");
    var i: usize = 0;
    while (i < 26) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "sessions/s{d}.jsonl", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x\n" });
    }

    app.overlay.open(.@"resume");
    const n = app.rebuildOverlayLines();
    try std.testing.expectEqual(@as(usize, 24), n); // cap 24 rows
    try std.testing.expectEqual(@as(usize, 24), app.overlay_line_count);
    // Raw stems backing the rows map to real files (selection works).
    try std.testing.expect(app.resume_stem_lens[0] > 0);
    for (app.overlay_line_ptrs[0..n]) |line| {
        try std.testing.expect(line.len > 0);
    }

    // Empty dir → "(no sessions)" + Enter closes without acting.
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    wireResumeFixture(app, &empty, io);
    app.overlay.open(.@"resume");
    try std.testing.expectEqual(@as(usize, 1), app.rebuildOverlayLines());
    try std.testing.expectEqualStrings("(no sessions)", app.overlay_line_ptrs[0]);
    try std.testing.expectEqual(@as(usize, 0), app.resume_stem_lens[0]);
    _ = app.handleKey(.enter);
    try std.testing.expect(!app.overlay.isOpen());
}

test "tui-resume: secret-bearing filenames redact in the listing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    try tmp.dir.createDirPath(io, "sessions");
    var name_buf: [256]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "sessions/{s}.jsonl", .{secret});
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x\n" });

    app.overlay.open(.@"resume");
    try std.testing.expectEqual(@as(usize, 1), app.rebuildOverlayLines());
    const line = app.overlay_line_ptrs[0];
    try std.testing.expect(std.mem.indexOf(u8, line, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, line, coding.redact.marker) != null);
    // Raw stem still resolves to the real filename.
    const raw = app.resume_stem_bufs[0][0..app.resume_stem_lens[0]];
    try std.testing.expect(std.mem.eql(u8, raw, secret));
}

// ── session-tree-001 fixtures: grouped browser / metadata / pinning ────────
//
// Pinned mtimes (UTC, whole seconds) used across the grouped fixtures:
//   1768482840 = 2026-01-15 13:14, 1769907720 = 2026-02-01 01:02,
//   1770030720 = 2026-02-02 11:12, 1772615400 = 2026-03-04 09:10,
//   1772694480 = 2026-03-05 07:08.

test "tui-resume: grouped browser — ordering, headers, mtime+size rows" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    const fixture = [_]struct { path: []const u8, data: []const u8, ts: i96 }{
        .{ .path = "sessions/beta.jsonl", .data = "bb\n", .ts = 1772694480000000000 }, // 03-05 07:08, 3 B
        .{ .path = "sessions/alpha.jsonl", .data = "a\n", .ts = 1772615400000000000 }, // 03-04 09:10, 2 B
        .{ .path = "sessions/proj-a/y.jsonl", .data = "yyyy\n", .ts = 1770030720000000000 }, // 02-02 11:12, 5 B
        .{ .path = "sessions/proj-a/x.jsonl", .data = "x\n", .ts = 1769907720000000000 }, // 02-01 01:02, 2 B
        .{ .path = "sessions/proj-b/z.jsonl", .data = "z\n", .ts = 1768482840000000000 }, // 01-15 13:14, 2 B
    };
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.createDirPath(io, "sessions/proj-a");
    try tmp.dir.createDirPath(io, "sessions/proj-b");
    for (fixture) |f| {
        try tmp.dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
        try tmp.dir.setTimestamps(io, f.path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = f.ts } } });
    }

    app.overlay.open(.@"resume");
    const n = app.rebuildOverlayLines();
    // Flat first (mtime desc), then groups name asc, within group mtime desc;
    // group headers `{project}/`; session rows `{rel} {mtime} {size}`.
    const want = [_][]const u8{
        "beta 03-05 07:08 3B",
        "alpha 03-04 09:10 2B",
        "proj-a/",
        "proj-a/y 02-02 11:12 5B",
        "proj-a/x 02-01 01:02 2B",
        "proj-b/",
        "proj-b/z 01-15 13:14 2B",
    };
    try std.testing.expectEqual(want.len, n);
    for (want, 0..) |w, i| {
        try std.testing.expectEqualStrings(w, app.overlay_line_ptrs[i]);
    }
    // Headers are muted-kind; session rows normal; raw rel paths back rows.
    try std.testing.expectEqual(render.RowKind.muted, app.resume_row_kinds[2]);
    try std.testing.expectEqual(render.RowKind.muted, app.resume_row_kinds[5]);
    try std.testing.expectEqual(render.RowKind.normal, app.resume_row_kinds[0]);
    try std.testing.expectEqualStrings("beta", app.resume_stem_bufs[0][0..app.resume_stem_lens[0]]);
    try std.testing.expectEqualStrings("proj-a/y", app.resume_stem_bufs[3][0..app.resume_stem_lens[3]]);
    // Headers have NO raw stem backing (they are not selectable).
    try std.testing.expectEqual(@as(usize, 0), app.resume_stem_lens[2]);
}

test "tui-resume: Enter on a group header is a no-op (overlay stays open)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.createDirPath(io, "sessions/proj");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/proj/a.jsonl", .data = "x\n" });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    // Row 0 is the group header (the only entry is grouped).
    try std.testing.expectEqual(render.RowKind.muted, app.resume_row_kinds[0]);
    app.overlay.cursor = 0;
    _ = app.handleKey(.enter);
    // No-op: the overlay stays open (a header must never hit the
    // empty-stem "(no sessions)" close path).
    try std.testing.expect(app.overlay.isOpen());
    try std.testing.expectEqual(UiState.idle, app.state);
}

test "tui-resume: 24-row cap includes group headers (headers consume rows)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.createDirPath(io, "sessions/proj");
    var i: usize = 0;
    while (i < 22) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "sessions/f{d:0>2}.jsonl", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x\n" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/proj/s1.jsonl", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/proj/s2.jsonl", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/proj/s3.jsonl", .data = "x\n" });

    app.overlay.open(.@"resume");
    const n = app.rebuildOverlayLines();
    try std.testing.expectEqual(@as(usize, 24), n); // 22 flat + header + 1 session
    // The header consumes a row: exactly ONE group session fits under the
    // cap (which one is mtime order — equal-mtime ties are unordered).
    try std.testing.expectEqual(render.RowKind.muted, app.resume_row_kinds[22]);
    var group_rows: usize = 0;
    var group_session_rows: usize = 0;
    var scan: usize = 0;
    while (scan < n) : (scan += 1) {
        if (app.resume_row_kinds[scan] == .muted) group_rows += 1;
        if (std.mem.startsWith(u8, app.resume_stem_bufs[scan][0..app.resume_stem_lens[scan]], "proj/")) group_session_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), group_rows);
    try std.testing.expectEqual(@as(usize, 1), group_session_rows);
}

test "tui-resume: secret-bearing group names and stems redact; raw rel paths kept" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "sessions/{s}", .{secret});
    try tmp.dir.createDirPath(io, dir);
    var file_buf: [300]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/inner.jsonl", .{dir});
    try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "x\n" });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    // Header row: `{marker}/`; session row: `{marker}/inner {mtime} {size}`.
    try std.testing.expectEqual(render.RowKind.muted, app.resume_row_kinds[0]);
    const header = app.overlay_line_ptrs[0];
    try std.testing.expect(std.mem.indexOf(u8, header, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, header, coding.redact.marker) != null);
    try std.testing.expect(std.mem.endsWith(u8, header, "/"));
    const row = app.overlay_line_ptrs[1];
    try std.testing.expect(std.mem.indexOf(u8, row, secret) == null);
    // Raw rel path still resolves to the real grouped file.
    const raw = app.resume_stem_bufs[1][0..app.resume_stem_lens[1]];
    var want_buf: [300]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{s}/inner", .{secret});
    try std.testing.expect(std.mem.eql(u8, raw, want));
}

test "tui-resume: selection resolves grouped and flat rel paths to root/{rel}.jsonl" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.transcript.appendUser("active-q");
    try active.save();

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    const fixture = session_header_line ++
        \\{"role":"user","content":"grouped q"}
        \\{"role":"assistant","content":"grouped a"}
    ;
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.createDirPath(io, "sessions/proj-a");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/proj-a/y.jsonl", .data = fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/beta.jsonl", .data = fixture });

    // Grouped selection: rel path "proj-a/y" resolves to
    // {pinned_root}/proj-a/y.jsonl (root pinned to "sessions" — the active
    // path sits inside the default root).
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const grouped_row = resumeRowFor(app, "proj-a/y") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = grouped_row;
    _ = app.handleKey(.enter);
    try std.testing.expect(!app.overlay.isOpen());
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/proj-a/y.jsonl", app.session.?.path.?);

    // Flat selection: rel path "beta" resolves to {pinned_root}/beta.jsonl.
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const flat_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = flat_row;
    _ = app.handleKey(.enter);
    try std.testing.expect(!app.overlay.isOpen());
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/beta.jsonl", app.session.?.path.?);
}

test "tui-resume: root pinning — default root wins under it, else dirname" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/under.jsonl", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/out.jsonl", .data = "x\n" });

    // Active path INSIDE the default root → pinned root is the default:
    // only sessions/under.jsonl is listed.
    {
        const active = try startSwapSession(gpa, io, &tmp, "sessions/active.jsonl", .create_new, &r);
        try active.save();
        const app = try App.create(gpa);
        defer app.destroy();
        app.session = active; // App owns it from here (destroy deinits)
        wireResumeFixture(app, &tmp, io);
        app.overlay.open(.@"resume");
        _ = app.rebuildOverlayLines();
        try std.testing.expect(resumeRowFor(app, "under") != null);
        try std.testing.expect(resumeRowFor(app, "out") == null);
    }

    // Active path OUTSIDE the default root → pinned root is its dirname:
    // only elsewhere/out.jsonl is listed.
    {
        const active = try startSwapSession(gpa, io, &tmp, "elsewhere/active.jsonl", .create_new, &r);
        try active.save();
        const app = try App.create(gpa);
        defer app.destroy();
        app.session = active;
        wireResumeFixture(app, &tmp, io);
        app.overlay.open(.@"resume");
        _ = app.rebuildOverlayLines();
        try std.testing.expect(resumeRowFor(app, "out") != null);
        try std.testing.expect(resumeRowFor(app, "under") == null);
    }
}

test "tui-resume: mtime+size stay right-aligned within the 96-byte row cap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    try tmp.dir.createDirPath(io, "sessions");
    // 100-byte stem + KB-size file: the row must truncate the STEM and keep
    // `{mtime} {size}` at the right end of the 96-byte cap.
    const long_stem = "x" ** 100;
    var name_buf: [200]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "sessions/{s}.jsonl", .{long_stem});
    const big = "y" ** 2048;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = big });
    const t: i96 = 1772615400000000000; // 2026-03-04 09:10 UTC
    try tmp.dir.setTimestamps(io, name, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = t } } });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const row = app.overlay_line_ptrs[0];
    try std.testing.expectEqual(@as(usize, 96), row.len); // truncated at the cap
    // The metadata tail survives truncation (right-aligned within the cap).
    try std.testing.expect(std.mem.endsWith(u8, row, "03-04 09:10 2.0KB"));
    // The raw rel path behind the row is capped by the frozen 96-byte
    // selection buffer (documented: rel paths beyond it cannot select).
    try std.testing.expectEqual(@as(usize, 96), app.resume_stem_lens[0]);
}

test "tui-resume: selection swaps to and replays the selected session in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Active session (persisted, heap-owned): a NON-active selection swaps.
    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.transcript.appendUser("active-q");
    try active.save();

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    const fixture =
        session_header_line ++
        \\{"role":"user","content":"first question"}
        \\{"role":"assistant","content":"answer one","reasoning":"think about one"}
        \\{"role":"user","content":"second question"}
        \\{"role":"assistant","content":"answer two"}
        \\{"role":"assistant","content":"calling tool","tool_calls":[{"id":"t1","name":"write_file","arguments":"{}"}]}
        \\{"role":"tool","tool_call_id":"t1","content":"wrote ok"}
        \\{"role":"user","content":"third question"}
        \\{"role":"assistant","content":"final answer"}
    ;
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/alpha.jsonl", .data = fixture });

    // Thinking on: reasoning publishes as a `thinking` card before the turn.
    _ = app.handleKey(.ctrl_t);
    try std.testing.expect(app.show_thinking);
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const alpha_row = resumeRowFor(app, "alpha") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = alpha_row;
    _ = app.handleKey(.enter);

    try std.testing.expect(!app.overlay.isOpen());
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("", app.editor.slice());
    try std.testing.expectEqual(UiState.idle, app.state);

    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var idx: usize = 0;
    try expectCard(&snap, &idx, n, .user, "user", "first question");
    try expectCard(&snap, &idx, n, .ordinary, "thinking", "think about one");
    try expectCard(&snap, &idx, n, .ordinary, "assistant turn=1", "answer one");
    try expectCard(&snap, &idx, n, .user, "user", "second question");
    try expectCard(&snap, &idx, n, .ordinary, "assistant turn=2", "answer two");
    try expectCard(&snap, &idx, n, .ordinary, "assistant turn=3", "calling tool");
    try expectCard(&snap, &idx, n, .ordinary, "tool write_file", "wrote ok");
    try expectCard(&snap, &idx, n, .user, "user", "third question");
    try expectCard(&snap, &idx, n, .ordinary, "assistant turn=4", "final answer");
    try std.testing.expectEqual(idx, n);
}

test "tui-resume: thinking card gated by the toggle (off = no card)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.save();
    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    const fixture =
        session_header_line ++
        \\{"role":"user","content":"ask"}
        \\{"role":"assistant","content":"reply","reasoning":"hidden reasoning"}
    ;
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/gated.jsonl", .data = fixture });

    try std.testing.expect(!app.show_thinking); // default off
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const gated_row = resumeRowFor(app, "gated") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = gated_row;
    _ = app.handleKey(.enter);

    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var idx: usize = 0;
    try expectCard(&snap, &idx, n, .user, "user", "ask");
    try expectCard(&snap, &idx, n, .ordinary, "assistant turn=1", "reply");
    try std.testing.expectEqual(idx, n);
    var saw_thinking: usize = 0;
    for (snap[0..n]) |*slot| {
        if (slot.occupied and std.mem.eql(u8, slot.titleSlice(), "thinking")) saw_thinking += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), saw_thinking);
}

test "tui-resume: replayed bodies and titles run the redaction pipeline" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = coding.redact.testing.fake_api_key;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.save();
    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    const fixture = try std.fmt.allocPrint(gpa,
        \\{{"schema_version":1,"v":1,"type":"zag_session","compaction_gen":0}}
        \\{{"role":"user","content":"key {s}"}}
        \\{{"role":"assistant","content":"answer {s}","reasoning":"think {s}"}}
        \\{{"role":"assistant","content":"","tool_calls":[{{"id":"t1","name":"read_file","arguments":"{{}}"}}]}}
        \\{{"role":"tool","tool_call_id":"t1","content":"result {s}"}}
        ,
        .{ secret, secret, secret, secret },
    );
    defer gpa.free(fixture);
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/red.jsonl", .data = fixture });

    _ = app.handleKey(.ctrl_t); // thinking on — reasoning card must redact too
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const red_row = resumeRowFor(app, "red") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = red_row;
    _ = app.handleKey(.enter);

    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    try std.testing.expect(n >= 4);
    var secret_hits: usize = 0;
    var marker_hits: usize = 0;
    for (snap[0..n]) |*slot| {
        if (!slot.occupied) continue;
        if (std.mem.indexOf(u8, slot.titleSlice(), secret) != null) secret_hits += 1;
        if (std.mem.indexOf(u8, slot.bodySlice(), secret) != null) secret_hits += 1;
        if (std.mem.indexOf(u8, slot.bodySlice(), coding.redact.marker) != null) marker_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), secret_hits);
    // User body, thinking body, assistant body and tool body all redacted.
    try std.testing.expect(marker_hits >= 4);
}

test "tui-resume: corrupt session fails closed with resume_failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.save();
    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/corrupt.jsonl", .data = "not json\n" });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const corrupt_row = resumeRowFor(app, "corrupt") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = corrupt_row;
    _ = app.handleKey(.enter);

    try std.testing.expect(!app.overlay.isOpen());
    try std.testing.expectEqualStrings("resume_failed", app.noteSlice());
    try std.testing.expectEqual(UiState.idle, app.state);
    // Fail-closed: the old session is untouched, nothing published.
    try std.testing.expect(app.session == active);
    try std.testing.expectEqual(@as(usize, 0), app.card_ring.ordinary_count);
}

test "tui-resume: replay respects the ring cap with the existing drop note" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const active = try startSwapSession(gpa, io, &tmp, "sessions/active-src.jsonl", .create_new, &r);
    try active.save();
    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, active, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    try lines.appendSlice(gpa, session_header_line);
    var t: usize = 0;
    while (t < 130) : (t += 1) {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{{\"role\":\"assistant\",\"content\":\"body {d}\"}}\n", .{t});
        try lines.appendSlice(gpa, line);
    }
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/big.jsonl", .data = lines.items });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const big_row = resumeRowFor(app, "big") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = big_row;
    _ = app.handleKey(.enter);

    try std.testing.expectEqual(@as(usize, 125), app.card_ring.ordinary_count);
    try std.testing.expectEqual(@as(u32, 5), app.card_ring.cards_dropped);
    try std.testing.expect(app.card_ring.slots[cards_mod.CardRing.drop_note_idx].occupied);
    try std.testing.expectEqualStrings("cards_dropped=5", app.card_ring.slots[cards_mod.CardRing.drop_note_idx].bodySlice());
}

test "tui-resume: same-session replay uses the live transcript (no re-load)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var app = try newTestApp(gpa, &r);
    defer app.destroy();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    wireResumeFixture(app, &tmp, io);

    // Active session: heap-allocated Session whose path matches the fixture
    // stem (ownership handed to the App — app.destroy deinits + destroys it).
    // The live transcript holds a message the on-disk file does NOT contain —
    // a disk re-load would replay "on-disk" instead of "live-only-message".
    const session = try gpa.create(coding.Session);
    session.* = try coding.Session.start(gpa, io, .{
        .base_system = "",
        .path = null,
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    session.path = try gpa.dupe(u8, "sessions/active.jsonl");
    try session.transcript.appendUser("live-only-message");
    app.session = session;

    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/active.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"on-disk\"}\n",
    });

    app.overlay.open(.@"resume");
    try std.testing.expectEqual(@as(usize, 1), app.rebuildOverlayLines());
    _ = app.handleKey(.enter);

    try std.testing.expectEqualStrings("resume_active", app.noteSlice());
    try std.testing.expect(!app.overlay.isOpen());
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const n = app.card_ring.snapshot(&snap);
    var saw_live = false;
    var saw_disk = false;
    for (snap[0..n]) |*slot| {
        if (!slot.occupied) continue;
        if (std.mem.eql(u8, slot.bodySlice(), "live-only-message")) saw_live = true;
        if (std.mem.eql(u8, slot.bodySlice(), "on-disk")) saw_disk = true;
    }
    try std.testing.expect(saw_live);
    try std.testing.expect(!saw_disk);
}

test "tui-swap: the swap replays without writing the target file (bytes preserved until a turn saves)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture =
        session_header_line ++
        \\{"role":"user","content":"before"}
        \\{"role":"assistant","content":"after"}
    ;
    try tmp.dir.createDirPath(io, "sessions");

    // Active session: persisted, heap-owned (handed to the App).
    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("initial-q");
    try initial.save();

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    // Target session on disk; the swap resumes + replays it but must not
    // write it (the file is only rewritten by a later turn's save).
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/keep.jsonl", .data = fixture });

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const keep_row = resumeRowFor(app, "keep") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = keep_row;
    _ = app.handleKey(.enter);

    // Swap happened; the target file is byte-identical afterwards.
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/keep.jsonl", app.session.?.path.?);
    const after = try tmp.dir.readFileAlloc(io, "sessions/keep.jsonl", gpa, .limited(1024 * 1024));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(fixture, after);
    // Surface reset: editor cleared, state stays idle.
    try std.testing.expectEqualStrings("", app.editor.slice());
    try std.testing.expectEqual(UiState.idle, app.state);
}

// ── session-swap-001 fixtures: swap / guard / lock / ownership / redaction /
// fail-closed / config-parity ────────────────────────────────────────────────

/// Minimal chat provider for swap fixtures (a real Agent is required for the
/// real bind path; the provider is never invoked by swapSession).
const SwapMockChat = struct {
    fn chat(
        _: *anyopaque,
        arena: std.mem.Allocator,
        _: []const coding.message.Message,
        _: []const coding.tool.Definition,
        _: coding.provider.RequestControl,
        _: ?*?u64,
    ) coding.provider.ChatError!coding.message.AssistantTurn {
        return .{
            .content = try arena.dupe(u8, "done"),
            .tool_calls = &.{},
            .finish_reason = "stop",
            .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        };
    }
};

fn swapMockProvider(state: *SwapMockChat) coding.provider.Provider {
    return .{ .ptr = state, .vtable = &.{ .chat = SwapMockChat.chat } };
}

/// Minimal SignalHost for swap fixtures (swapSession never touches the host).
const SwapFakeHost = struct {
    fn asHost(self: *SwapFakeHost) SignalHost {
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
    fn wakeFd(_: *anyopaque) posix.fd_t {
        return -1;
    }
    fn drainWake(_: *anyopaque) void {}
    fn pendingInterrupt(_: *anyopaque) bool {
        return false;
    }
    fn acknowledgeCancel(_: *anyopaque) void {}
};

/// Heap-allocate + start a session rooted at the fixture tmp dir (the same
/// root the resume overlay scans via resume_cwd). Caller owns until bound.
fn startSwapSession(
    gpa: std.mem.Allocator,
    io: Io,
    tmp: *std.testing.TmpDir,
    rel_path: ?[]const u8,
    mode: coding.OpenMode,
    redactor: *const coding.redact.Redactor,
) !*coding.Session {
    const s = try gpa.create(coding.Session);
    errdefer gpa.destroy(s);
    s.* = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .path = rel_path,
        .open_mode = mode,
        .load_project_instructions = false,
        .redactor = redactor,
        .skills_enabled = false,
        .templates_enabled = false,
        .cwd = tmp.dir,
    });
    return s;
}

/// Bind `session` (heap-owned, handed to the App) through the REAL bind path
/// with a fresh mock Agent + stub host, capturing `opts`. The returned Agent
/// must outlive the App and be deinited after App.destroy (product order).
fn bindSwapFixture(
    app: *App,
    gpa: std.mem.Allocator,
    io: Io,
    session: *coding.Session,
    opts: BindSessionOpts,
) !*coding.Agent {
    var mock: SwapMockChat = .{};
    const agent = try gpa.create(coding.Agent);
    errdefer gpa.destroy(agent);
    agent.* = try coding.Agent.init(gpa, io, swapMockProvider(&mock), .{
        .permission_mode = .yolo,
        .hunk_reviewer = coding.autoAcceptHunkReviewer(),
        .lifecycle = app.lifecycleObserver(),
    });
    errdefer agent.deinit();
    var host = SwapFakeHost{};
    try app.bind(agent, session, session.activeRedactor().?, host.asHost(), opts);
    return agent;
}

/// Row index of the listed stem in the resume overlay (FS iteration order is
/// unspecified — locate by raw stem, not by position).
fn resumeRowFor(app: *App, stem: []const u8) ?usize {
    var i: usize = 0;
    while (i < app.overlay_line_count) : (i += 1) {
        const raw = app.resume_stem_bufs[i][0..app.resume_stem_lens[i]];
        if (std.mem.eql(u8, raw, stem)) return i;
    }
    return null;
}

test "tui-swap: selection swaps to the selected session; old lock released, new held; new turn appends" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Active session (persisted; later the "old" path).
    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("initial-q");
    try initial.save();

    // Target session on disk (the swap resumes it).
    try tmp.dir.createDirPath(io, "sessions");
    const beta_fixture =
        session_header_line ++
        \\{"role":"user","content":"beta-q"}
        \\{"role":"assistant","content":"beta-a"}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/beta.jsonl", .data = beta_fixture });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    // /resume → select the beta row (raw-stem lookup; FS order unspecified).
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);

    // Swap-specific note (never resume_active), overlay closed, new active.
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expect(!app.overlay.isOpen());
    const cur = app.session orelse return error.TestUnexpectedResult;
    try std.testing.expect(cur != initial);
    try std.testing.expectEqualStrings("sessions/beta.jsonl", cur.path.?);
    try std.testing.expectEqualStrings("sessions/beta.jsonl", app.idDisplay());

    // Old lock released: a fresh resume of the OLD path now succeeds.
    var probe = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .path = "sessions/initial.jsonl",
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
        .cwd = tmp.dir,
    });
    probe.deinit();

    // New lock held: a second resume of the NEW path fails closed.
    try std.testing.expectError(error.SessionBusy, coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .path = "sessions/beta.jsonl",
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
        .cwd = tmp.dir,
    }));

    // Replay is the NEW session's transcript ONLY (the ring was cleared —
    // two sessions' cards never concatenate).
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const m = app.card_ring.snapshot(&snap);
    var idx: usize = 0;
    try expectCard(&snap, &idx, m, .user, "user", "beta-q");
    try expectCard(&snap, &idx, m, .ordinary, "assistant turn=1", "beta-a");
    try std.testing.expectEqual(idx, m);
    for (snap[0..m]) |*slot| {
        try std.testing.expect(std.mem.indexOf(u8, slot.bodySlice(), "initial-q") == null);
    }

    // The selected path is now writable: a new turn appends to it and the
    // round-trip load preserves both halves.
    try cur.transcript.appendUser("continued");
    try cur.save();
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = coding.transcript.Transcript.init(load_arena.allocator());
    _ = try coding.session_store.loadWithMeta(gpa, io, tmp.dir, "sessions/beta.jsonl", &loaded);
    const items = loaded.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("beta-q", items[0].content);
    try std.testing.expectEqualStrings("beta-a", items[1].content);
    try std.testing.expectEqualStrings("continued", items[2].content);
}

test "tui-swap: busy guard rejects the swap (resume_busy); idle allows it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    // Worker active + busy → swap rejected, no-op (never mid-run).
    app.worker_active = true;
    app.state = .busy;
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);
    try std.testing.expectEqualStrings("resume_busy", app.noteSlice());
    try std.testing.expect(app.overlay.isOpen()); // no-op: overlay stays for the user
    try std.testing.expect(app.session == initial); // unchanged
    try std.testing.expectEqualStrings("sessions/initial.jsonl", app.session.?.path.?);

    // Idle again → the same selection swaps.
    app.worker_active = false;
    app.state = .idle;
    _ = app.handleKey(.enter);
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/beta.jsonl", app.session.?.path.?);
}

test "tui-swap: start failure (external lock) is fail-closed — old stays active and usable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("initial-q");
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    // Externally lock the target path (a second process's lease).
    var blocker = try coding.Session.start(gpa, io, .{
        .base_system = "sys",
        .path = "sessions/beta.jsonl",
        .open_mode = .resume_existing,
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
        .cwd = tmp.dir,
    });
    defer blocker.deinit();

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);

    // Fail-closed: note surfaced, overlay closed, OLD session untouched —
    // its lease is still held and the next turn appends to it.
    try std.testing.expectEqualStrings("resume_failed", app.noteSlice());
    try std.testing.expect(!app.overlay.isOpen());
    try std.testing.expect(app.session == initial);
    try std.testing.expectEqualStrings("sessions/initial.jsonl", app.session.?.path.?);

    try initial.transcript.appendUser("next-turn");
    try initial.save();
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = coding.transcript.Transcript.init(load_arena.allocator());
    _ = try coding.session_store.loadWithMeta(gpa, io, tmp.dir, "sessions/initial.jsonl", &loaded);
    const items = loaded.items();
    try std.testing.expectEqualStrings("initial-q", items[items.len - 2].content);
    try std.testing.expectEqualStrings("next-turn", items[items.len - 1].content);
}

test "tui-swap: save failure aborts before the old session is touched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    // Arm the old writer's test failpoint: the swap's step-1 save fails.
    // (No defer here — the disarm below runs while the session is alive;
    // a defer would fire after app.destroy freed it.)
    coding.session_store.testing.setFailBeforeReplace(&initial.writer.?, true);

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);

    // Abort BEFORE the swap: old session untouched, note surfaced.
    try std.testing.expectEqualStrings("resume_failed", app.noteSlice());
    try std.testing.expect(app.session == initial);
    try std.testing.expectEqualStrings("sessions/initial.jsonl", app.session.?.path.?);

    // Old still usable after the failpoint is disarmed.
    coding.session_store.testing.setFailBeforeReplace(&initial.writer.?, false);
    try initial.transcript.appendUser("after-abort");
    try initial.save();
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = coding.transcript.Transcript.init(load_arena.allocator());
    _ = try coding.session_store.loadWithMeta(gpa, io, tmp.dir, "sessions/initial.jsonl", &loaded);
    const items = loaded.items();
    try std.testing.expectEqualStrings("after-abort", items[items.len - 1].content);
}

test "tui-swap: swap-back works; teardown deinits the current session exactly once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("initial-q");
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    // Swap to beta.
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);
    const beta = app.session.?;
    try std.testing.expectEqualStrings("sessions/beta.jsonl", beta.path.?);

    // Swap BACK to the original path (its lock was released by the swap).
    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const initial_row = resumeRowFor(app, "initial") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = initial_row;
    _ = app.handleKey(.enter);
    const back = app.session orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/initial.jsonl", back.path.?);
    try std.testing.expect(back != initial); // a fresh session object
    try std.testing.expect(back != beta);

    // The replayed transcript is the initial session's.
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const m = app.card_ring.snapshot(&snap);
    var idx: usize = 0;
    try expectCard(&snap, &idx, m, .user, "user", "initial-q");
    try std.testing.expectEqual(idx, m);

    // defer app.destroy() deinits + destroys the CURRENT session exactly
    // once — testing.allocator proves no double-free and no leak of any of
    // the three session objects.
}

test "tui-swap: the new session's redactor applies to the replay cards" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const secret = "swapped-secret-42";
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{secret}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("alpha-only-token");
    try initial.save();
    const initial_redactor = initial.activeRedactor().?;
    try tmp.dir.createDirPath(io, "sessions");
    const beta_fixture = try std.fmt.allocPrint(gpa,
        \\{{"schema_version":1,"v":1,"type":"zag_session","compaction_gen":0}}
        \\{{"role":"user","content":"the secret is {s}"}}
        \\{{"role":"assistant","content":"all good"}}
        ,
        .{secret},
    );
    defer gpa.free(beta_fixture);
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/beta.jsonl", .data = beta_fixture });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);
    try std.testing.expectEqualStrings("resume_swapped", app.noteSlice());

    // The redactor instance is the NEW session's clone (not the old one's),
    // and the replay cards redact the secret present in the new session.
    const cur = app.session.?;
    try std.testing.expect(app.redactor == cur.activeRedactor().?);
    try std.testing.expect(app.redactor != initial_redactor);
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const m = app.card_ring.snapshot(&snap);
    var secret_hits: usize = 0;
    var marker_hits: usize = 0;
    for (snap[0..m]) |*slot| {
        if (!slot.occupied) continue;
        if (std.mem.indexOf(u8, slot.titleSlice(), secret) != null) secret_hits += 1;
        if (std.mem.indexOf(u8, slot.bodySlice(), secret) != null) secret_hits += 1;
        if (std.mem.indexOf(u8, slot.bodySlice(), coding.redact.marker) != null) marker_hits += 1;
        // "a secret pattern present in one session, absent in the other":
        // the initial session's content is gone (ring cleared by the swap).
        try std.testing.expect(std.mem.indexOf(u8, slot.bodySlice(), "alpha-only-token") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), secret_hits);
    try std.testing.expect(marker_hits >= 1);
}

test "tui-swap: base_system / redactor / skills flags captured at bind reach the new session" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "CUSTOM-BASE",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);

    // Config parity: the swapped-in session carries the bind-time knobs.
    const cur = app.session.?;
    try std.testing.expectEqualStrings("CUSTOM-BASE", cur.base_system);
    try std.testing.expect(!cur.skills_enabled);
    try std.testing.expect(!cur.templates_enabled);
    try std.testing.expect(cur.activeRedactor() != null);
    try std.testing.expect(app.redactor == cur.activeRedactor().?);
}

test "tui-swap: selecting the ACTIVE session replays only (no-op swap)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const initial = try startSwapSession(gpa, io, &tmp, "sessions/initial.jsonl", .create_new, &r);
    try initial.transcript.appendUser("initial-q");
    try initial.save();
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, initial, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const initial_row = resumeRowFor(app, "initial") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = initial_row;
    _ = app.handleKey(.enter);

    // Replay only: same session pointer, no swap, live-transcript replay
    // (the session still holds its own lock — a swap would hit SessionBusy).
    try std.testing.expectEqualStrings("resume_active", app.noteSlice());
    try std.testing.expect(app.session == initial);
    var snap: [c.card_slots]cards_mod.CardSlot = undefined;
    const m = app.card_ring.snapshot(&snap);
    var idx: usize = 0;
    try expectCard(&snap, &idx, m, .user, "user", "initial-q");
    try std.testing.expectEqual(idx, m);
}

test "tui-swap: ephemeral-source swap surfaces the lost conversation note" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r = try coding.redact.Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
    defer r.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Active session is EPHEMERAL (no path — nothing to save on swap).
    const ephemeral = try startSwapSession(gpa, io, &tmp, null, .create_new, &r);
    try tmp.dir.createDirPath(io, "sessions");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sessions/beta.jsonl",
        .data = session_header_line ++ "{\"role\":\"user\",\"content\":\"beta-q\"}\n",
    });

    const app = try App.create(gpa);
    defer app.destroy();
    wireResumeFixture(app, &tmp, io);
    const agent = try bindSwapFixture(app, gpa, io, ephemeral, .{
        .base_system = "sys",
        .load_project_instructions = false,
        .redactor = &r,
        .skills_enabled = false,
        .templates_enabled = false,
    });
    // Heap-owned mock Agent: deinit AND destroy (bindSwapFixture allocated).
    defer {
        agent.deinit();
        gpa.destroy(agent);
    }

    app.overlay.open(.@"resume");
    _ = app.rebuildOverlayLines();
    const beta_row = resumeRowFor(app, "beta") orelse return error.TestUnexpectedResult;
    app.overlay.cursor = beta_row;
    _ = app.handleKey(.enter);

    // The swap succeeds; the note surfaces the ephemeral-source loss.
    try std.testing.expectEqualStrings("resume_swapped_ephemeral", app.noteSlice());
    try std.testing.expectEqualStrings("sessions/beta.jsonl", app.session.?.path.?);
}

