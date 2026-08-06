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

/// Card-title identity constants (tui-streaming-001): delta replaces match
/// `TITLE_PROGRESSIVE` ONLY so a finalized "assistant turn=N" card is never
/// clobbered by partial text; lifecycle uses the turn format. Kept in one
/// place so the prefix rules stay in lockstep with `cards.zig:124`.
pub const TITLE_PROGRESSIVE = "assistant progressive";
pub const TITLE_TURN_FMT = "assistant turn={d}";

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
    host: ?SignalHost = null,

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
    theme_selected: []const u8 = theme_mod.builtin_id,

    overlay: overlay_mod.Overlay = .{},
    /// Transcript scroll: 0 = newest window (tui-transcript-001).
    scroll_from_bottom: usize = 0,
    /// Cards region height of the last paint — PgUp/PgDn page by this many
    /// transcript rows (tui-polish-001 input completeness).
    last_cards_h: u16 = 0,

    model_label: []const u8 = "—",
    /// Borrowed catalog ids from host (CLI arena / static). Cap used at paint.
    model_ids: []const []const u8 = &.{},
    /// Scratch lines for overlay paint (rebuilt each paint).
    overlay_line_bufs: [24][96]u8 = undefined,
    overlay_line_lens: [24]usize = [_]usize{0} ** 24,
    overlay_line_ptrs: [24][]const u8 = undefined,
    overlay_line_count: usize = 0,
    /// Io handle for Theme FS discovery (set by applyHostPresentation).
    host_io: ?Io = null,

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
        };
        return app;
    }

    pub fn destroy(self: *App) void {
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
        self.model_label = model_label;
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
        if (!std.mem.eql(u8, resolved.id, theme_mod.builtin_id)) {
            // resolveActive may return owned id inside palette.id
            if (resolved.id.ptr != theme_mod.builtin_id.ptr) {
                self.owned_theme_id = @constCast(resolved.id);
            }
        }
        self.theme_selected = self.palette.id;
    }

    pub fn idDisplay(self: *const App) []const u8 {
        if (self.id_display_len == 0) return "ephemeral";
        return self.id_display[0..self.id_display_len];
    }

    pub fn bind(
        self: *App,
        agent: *coding.Agent,
        session: *coding.Session,
        redactor: *const coding.redact.Redactor,
        host: SignalHost,
    ) BindError!void {
        if (self.quiesced) return error.MissingAgent;
        self.agent = agent;
        self.session = session;
        self.redactor = redactor;
        self.host = host;
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
                self.card_ring.demoteTerminalToOrdinary();
                // No card (tui-polish-001 compaction): run start is already
                // surfaced by the header cfg flag + state:busy.
            },
            .assistant_message => |m| {
                // Turn boundary: the complete message arrived; next turn's
                // deltas start clean.
                self.delta_len = 0;
                // Lifecycle is card identity for assistant (turn/has_tools).
                var title_buf: [64]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, TITLE_TURN_FMT, .{m.turn}) catch "assistant";
                // Replace-style: drop any open progressive "assistant" body card.
                self.card_ring.replaceNewestOrdinaryTitlePrefix(self.gpa, red, "assistant", title, m.text);
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
            // Deltas are UI-visible only and handled by onObserver; the
            // lifecycle path does not paint per-chunk text.
            .assistant_delta, .assistant_delta_clear => {},
            .run_terminal => |term| {
                // Belt-and-braces: a sink-failure edge can terminate the run
                // with the accumulator holding partial text (the clear event
                // itself failed); reset here so the next reply starts clean.
                self.delta_len = 0;
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
                // the accumulator and repaint with an empty body. Progressive
                // prefix only (never blanks a finalized turn card).
                self.delta_len = 0;
                self.card_ring.replaceNewestOrdinaryTitlePrefix(
                    self.gpa,
                    self.redactor,
                    TITLE_PROGRESSIVE,
                    TITLE_PROGRESSIVE,
                    self.delta_buf[0..0],
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

            _ = posix.poll(&pollfds, c.poll_timeout_ms) catch {};

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
                else => return .none,
            }
        }

        if (self.overlay.isOpen()) {
            return self.handleOverlayKey(key);
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
                self.editor.moveEnd();
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
                self.editor.killToEnd();
                self.syncSlashOverlay();
                return .none;
            },
            .page_up => {
                // Page by the transcript window height (not a fixed 3 rows).
                self.scroll_from_bottom +|= @max(self.last_cards_h, 1);
                return .none;
            },
            .page_down => {
                self.scroll_from_bottom -|= @max(self.last_cards_h, 1);
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
            .char => |ch| {
                _ = self.editor.insert(ch);
                self.syncSlashOverlay();
                return .none;
            },
            .unknown => return .none,
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
            .help, .slash_palette => {
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
                self.model_label = line;
                if (self.agent) |agent| {
                    // Host label only — wire model stays at resolve-time unless catalog row found.
                    _ = agent;
                }
                self.setNote("model_selected");
                self.overlay.close();
            },
            .theme => {
                self.theme_selected = line;
                self.reloadTheme();
                self.setNote("theme_selected");
                self.overlay.close();
            },
        }
    }

    fn rebuildOverlayLines(self: *App) usize {
        var n: usize = 0;
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
                push(self, "help", &n);
                push(self, "settings", &n);
                push(self, "model", &n);
                push(self, "theme", &n);
                push(self, "skill:name", &n);
                push(self, "(templates: /name)", &n);
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
                push(self, theme_mod.builtin_id, &n);
                // User themes are discovered lazily at select time; listBuiltin only here.
                if (self.themes_root) |root| {
                    var list: std.ArrayList([]const u8) = .empty;
                    defer {
                        for (list.items) |it| {
                            if (!std.mem.eql(u8, it, theme_mod.builtin_id)) self.gpa.free(it);
                        }
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
                self.scroll_from_bottom = 0;
                self.state = .busy;
                self.setNote("(starting…)");
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
        _ = agent.reply(session, prompt) catch {
            self.worker_had_error.store(true, .release);
            self.card_ring.publishHostErrorFixed("host_error", "reply_error");
            return;
        };
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
        };
        const ov = render.OverlayPaint{
            .kind = self.overlay.kind,
            .cursor = self.overlay.cursor,
            .lines = self.overlay_line_ptrs[0..self.overlay_line_count],
        };
        // Compute the layout once here: renderFrame draws it, and the cards
        // region height is the page unit for PgUp/PgDn transcript scroll.
        const layout = layout_mod.compute(sz, n, modal.pending, facts.status_note.len > 0, self.scroll_from_bottom);
        self.last_cards_h = layout.cards.h;
        try render.renderFrame(term, sz, layout, facts, self.snap_buf[0..n], &self.editor, modal, &self.palette, ov);
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
    // Cell proof: the full frame was drawn into the offscreen screen.
    // Minimal frame: row 0 is the top border, row 1 is the transcript
    // separator (`├─ transcript ─…` with the label starting at col 3).
    try expectCellText(&rec, 0, 0, "┌");
    try expectCellText(&rec, 1, 0, "─");
    try expectCellText(&rec, 0, 1, "├");
    try expectCellText(&rec, 3, 1, "t");
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

test "tui-input: ctrl-w/u/k edit the buffer" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    _ = app.editor.insert("abc def");
    app.editor.cursor = 7;
    _ = app.handleKey(.ctrl_w);
    try std.testing.expectEqualStrings("abc ", app.editor.slice());
    _ = app.handleKey(.ctrl_u);
    try std.testing.expectEqualStrings("", app.editor.slice());
    _ = app.editor.insert("one\ntwo");
    app.editor.cursor = 6;
    _ = app.handleKey(.ctrl_k);
    try std.testing.expectEqualStrings("one\ntw", app.editor.slice());
}

test "tui-input: page up/down scroll by the cards region height" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    app.last_cards_h = 14;
    _ = app.handleKey(.page_up);
    try std.testing.expectEqual(@as(usize, 14), app.scroll_from_bottom);
    _ = app.handleKey(.page_down);
    try std.testing.expectEqual(@as(usize, 0), app.scroll_from_bottom);
    _ = app.handleKey(.page_down); // saturates at 0
    try std.testing.expectEqual(@as(usize, 0), app.scroll_from_bottom);
    _ = app.handleKey(.page_up);
    _ = app.handleKey(.page_up);
    try std.testing.expectEqual(@as(usize, 28), app.scroll_from_bottom);
}

test "tui-input: paint records the cards region height for paging" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    var rec = try RecTerm.init(gpa);
    defer rec.deinit(gpa);
    try app.paint(&rec.pt.term); // 80×40
    try std.testing.expect(app.last_cards_h > 0);
    // 80×40: max_cards = 30, cards_gap = 36-3 = 33 → 30.
    try std.testing.expectEqual(@as(u16, 30), app.last_cards_h);
}

test "tui-input: overlay home/end/page keys navigate" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    defer app.destroy();
    app.overlay.open(.help); // 6 lines
    _ = app.handleKey(.end);
    try std.testing.expectEqual(@as(usize, 5), app.overlay.cursor);
    _ = app.handleKey(.home);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.cursor);
    _ = app.handleKey(.page_down);
    try std.testing.expectEqual(@as(usize, 5), app.overlay.cursor); // 5× moveDown
    _ = app.handleKey(.page_up);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.cursor); // 5× moveUp
}
