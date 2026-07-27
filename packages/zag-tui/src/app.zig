//! Address-stable heap App: preallocation, dual-thread host, lifecycle publish.

const std = @import("std");
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
const signal_host = @import("signal_host.zig");
const terminal_mod = @import("terminal.zig");

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

pub const BindError = error{MissingRedactor, MissingSignalHost, MissingAgent, MissingSession};

pub const App = struct {
    gpa: std.mem.Allocator,

    // Preallocated storage (heap, address-stable for App lifetime).
    editor_storage: []u8,
    history_entries: [][c.history_entry_max_bytes]u8,
    history_lens: []usize,
    card_ring: cards_mod.CardRing,
    permission: permission_mod.PermissionSlot,
    editor: editor_mod.Editor,
    history: editor_mod.History,

    // App wake pipe (nonblocking CLOEXEC).
    wake_r: posix.fd_t = -1,
    wake_w: posix.fd_t = -1,

    // Borrowed after bind (must outlive run).
    agent: ?*coding.Agent = null,
    session: ?*coding.Session = null,
    redactor: ?*const coding.redact.Redactor = null,
    host: ?SignalHost = null,

    // Display facts (set by CLI before/at bind).
    id_display: [c.card_title_max_bytes]u8 = undefined,
    id_display_len: usize = 0,
    open_display: OpenDisplay = .n_a,
    perm_label: []const u8 = "ask",
    shell_label: []const u8 = "protect",
    session_configured_ui: bool = false,

    state: UiState = .idle,
    status_note: [128]u8 = undefined,
    status_note_len: usize = 0,
    quiesced: bool = false,
    raw_entered: bool = false,

    // Worker
    worker: ?std.Thread = null,
    worker_prompt: []u8 = &[_]u8{},
    worker_active: bool = false,
    worker_finished: std.atomic.Value(bool) = .init(false),
    worker_had_error: bool = false,

    // Input buffer for key decode.
    in_buf: [512]u8 = undefined,
    in_len: usize = 0,

    // Snapshot scratch (UI thread only).
    snap_buf: [c.card_slots]cards_mod.CardSlot = undefined,

    // Lifecycle identity
    last_run_started: bool = false,

    /// Preallocate everything before Agent.init / Guard / Session / raw.
    pub fn create(gpa: std.mem.Allocator) error{OutOfMemory, PipeFailed}!*App {
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

    /// Final free — only after Agent.deinit (adapter ptrs live until then).
    pub fn destroy(self: *App) void {
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
        self.gpa.free(self.history_lens);
        self.gpa.free(self.history_entries);
        self.gpa.free(self.editor_storage);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Detach for teardown; do not free storage yet.
    pub fn quiesce(self: *App) void {
        self.quiesced = true;
        self.host = null;
        // Keep agent/session/redactor pointers until Agent.deinit returns
        // (Options may still reference lifecycle adapter into App).
    }

    pub fn setIdentity(self: *App, id: []const u8, open: OpenDisplay, perm: []const u8, shell: []const u8) void {
        const n = present.copyTruncated(&self.id_display, id);
        self.id_display_len = n;
        self.open_display = open;
        self.perm_label = perm;
        self.shell_label = shell;
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
        return .{
            .ptr = self,
            .on_event = onLifecycle,
        };
    }

    pub fn observer(self: *App) coding.Observer {
        return .{
            .ptr = self,
            .on_event = onObserver,
        };
    }

    /// Gate.ask callback — runs on reply worker thread.
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
        self.status_note_len = present.copyTruncated(&self.status_note, note);
    }

    pub fn noteSlice(self: *const App) []const u8 {
        return self.status_note[0..self.status_note_len];
    }

    fn onLifecycle(ptr: ?*anyopaque, event: coding.LifecycleEvent) void {
        const self: *App = @ptrCast(@alignCast(ptr.?));
        // Callback rules: no TTY I/O, no render, short lock publish + nonblocking wake.
        const red = self.redactor;
        switch (event) {
            .run_start => |rs| {
                self.last_run_started = true;
                self.session_configured_ui = rs.session_configured;
                // Demote prior terminal into ordinary before new run.
                self.card_ring.demoteTerminalToOrdinary(self.gpa, red);
                self.card_ring.publishOrdinary(self.gpa, red, "run_start", if (rs.session_configured) "session_configured=y" else "session_configured=n");
            },
            .assistant_message => |m| {
                var title_buf: [64]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "assistant turn={d}", .{m.turn}) catch "assistant";
                self.card_ring.publishOrdinary(self.gpa, red, title, m.text);
            },
            .tool_start => |t| {
                var title_buf: [96]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "tool start {s}", .{t.name}) catch "tool start";
                var body_buf: [c.card_body_max_bytes]u8 = undefined;
                // Present id+args via redaction into a temp then publish.
                // Avoid inventing tool_update.
                const id_n = present.presentInto(self.gpa, red, body_buf[0..64], t.id);
                const args_n = present.presentInto(self.gpa, red, body_buf[64..], t.arguments);
                var composed: [c.card_body_max_bytes]u8 = undefined;
                const body = std.fmt.bufPrint(&composed, "id={s} args={s}", .{
                    body_buf[0..id_n],
                    body_buf[64 .. 64 + args_n],
                }) catch "tool";
                // Title already has name — redact name path by publishing title via ordinary pipeline.
                self.card_ring.publishOrdinary(self.gpa, red, title, body);
            },
            .tool_end => |t| {
                // End-only: still show end card; no fabricated start.
                var title_buf: [96]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "tool end {s}", .{t.name}) catch "tool end";
                self.card_ring.publishOrdinary(self.gpa, red, title, t.body);
            },
            .control_applied => |ctrl| {
                const kind = switch (ctrl.kind) {
                    .steering => "steering",
                    .follow_up => "follow_up",
                };
                var title_buf: [64]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "control kind={s} next_turn={d}", .{ kind, ctrl.next_turn }) catch "control";
                self.card_ring.publishOrdinary(self.gpa, red, title, ctrl.text);
            },
            .run_terminal => |term| {
                // Numeric/enum only — terminal reserve, allocation-free.
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
                // Full message body snapshot (not token delta) — replace-style ordinary card.
                self.card_ring.publishOrdinary(self.gpa, self.redactor, "assistant_text", text);
                self.wake();
            },
            else => {},
        }
    }

    /// Interactive loop. Requires bind + geometry check already passed by CLI.
    /// Returns process exit code.
    pub fn run(self: *App) u8 {
        if (self.agent == null or self.session == null or self.redactor == null or self.host == null) {
            return 1;
        }
        if (self.quiesced) return 1;

        var term = terminal_mod.Terminal.open() catch {
            self.fixedStderr("tui: not a tty\n");
            return 2;
        };
        const sz0 = term.size();
        if (sz0.isBelowMinimum()) {
            self.fixedStderr("tui: terminal too small (need ≥ 20×5)\n");
            return 1;
        }

        term.enterRawAlt() catch {
            self.fixedStderr("tui: raw mode failed\n");
            return 1;
        };
        self.raw_entered = true;

        var exit_code: u8 = 0;
        defer {
            // Cooperative restore on normal/closing paths after join.
            if (self.worker) |*th| {
                th.join();
                self.worker = null;
                self.afterWorkerJoin();
            }
            if (self.raw_entered) {
                term.restore() catch {};
                self.raw_entered = false;
            }
        }

        // Initial render.
        self.paint(&term) catch {
            self.permission.denyAndClose();
            self.fixedStderr("tui: render failed\n");
            exit_code = 1;
            return exit_code;
        };

        while (self.state != .closed) {
            // Poll stdin + app wake + SignalHost wake ≤250ms.
            var pollfds = [_]posix.pollfd{
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_r, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.host.?.wakeFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            // If signal wake fd invalid, skip it by setting fd=-1.
            if (pollfds[2].fd < 0) {
                pollfds[2].fd = -1;
                pollfds[2].events = 0;
            }

            _ = posix.poll(&pollfds, c.poll_timeout_ms) catch {};

            // Drain wakes.
            if (pollfds[1].revents & (posix.POLL.IN | posix.POLL.ERR) != 0) {
                terminal_mod.drainPipe(self.wake_r);
            }
            if (pollfds[2].fd >= 0 and pollfds[2].revents & (posix.POLL.IN | posix.POLL.ERR) != 0) {
                self.host.?.drainWake();
            }

            // Join finished worker.
            if (self.worker_active and self.worker_finished.load(.acquire)) {
                if (self.worker) |*th| {
                    th.join();
                    self.worker = null;
                }
                self.afterWorkerJoin();
            }

            // SignalHost pending: idle → clean exit 0; busy handled by Guard cancel.
            if (self.host.?.pendingInterrupt()) {
                if (self.state == .idle) {
                    exit_code = 0;
                    self.state = .closed;
                    break;
                }
                // Busy: cooperative cancel already requested via Guard; show closing if needed.
                if (self.state == .busy) {
                    self.setNote("cancel pending");
                }
            }

            // Stdin readable.
            if (pollfds[0].revents & posix.POLL.IN != 0) {
                const action = self.readAndHandleKeys() catch {
                    self.permission.decide(.deny);
                    self.fixedStderr("tui: read failed\n");
                    if (self.state == .busy) {
                        self.enterClosing();
                    } else {
                        exit_code = 1;
                        self.state = .closed;
                    }
                    continue;
                };
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

            // Timeout path still surfaces permission modal / terminal cards.
            self.paint(&term) catch {
                self.permission.decide(.deny);
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
                // Worker done; exit after join ack.
                exit_code = 0;
                self.state = .closed;
            }
        }

        return exit_code;
    }

    fn enterClosing(self: *App) void {
        self.state = .closing;
        self.permission.denyAndClose();
        if (self.agent) |a| a.requestCancel();
        self.setNote("closing… (Ctrl+C again may hard-exit 130)");
    }

    pub fn afterWorkerJoin(self: *App) void {
        self.worker_active = false;
        self.worker_finished.store(false, .release);
        if (self.worker_prompt.len != 0) {
            self.gpa.free(self.worker_prompt);
            self.worker_prompt = &[_]u8{};
        }
        // §2.5: acknowledge cancel after every join (success or error).
        if (self.host) |h| h.acknowledgeCancel();
        if (self.state == .closing) {
            // stay closing until loop exits
        } else if (self.worker_had_error) {
            self.state = .@"error";
            self.setNote("reply error");
        } else {
            self.state = .idle;
            self.setNote("");
        }
        // Idle-only clear of control queues after join.
        if (self.state == .idle or self.state == .@"error") {
            if (self.session) |s| s.clearControlQueues();
        }
        self.worker_had_error = false;
        self.permission.resetClosing();
    }

    const KeyAction = enum { none, quit_0, quit_1, closing };

    fn readAndHandleKeys(self: *App) error{ReadFailed}!KeyAction {
        var tmp: [256]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &tmp) catch |err| switch (err) {
            error.WouldBlock => return .none,
            else => return error.ReadFailed,
        };
        if (n == 0) {
            // EOF
            if (self.permission.isPending()) {
                self.permission.decide(.deny);
            }
            if (self.state == .busy or self.state == .closing) {
                return .closing;
            }
            if (self.editor.len == 0) return .quit_0;
            return .none;
        }
        if (self.in_len + n > self.in_buf.len) {
            // Drop overflow; fail-closed for modal.
            self.in_len = 0;
            if (self.permission.isPending()) self.permission.decide(.deny);
            return .none;
        }
        @memcpy(self.in_buf[self.in_len..][0..n], tmp[0..n]);
        self.in_len += n;

        var action: KeyAction = .none;
        var off: usize = 0;
        while (off < self.in_len) {
            const rem = self.in_buf[off..self.in_len];
            const dec = keys_mod.decode(rem) orelse break;
            off += dec.n;
            action = self.handleKey(dec.key);
            if (action != .none) break;
        }
        // Compact buffer.
        if (off > 0) {
            const left = self.in_len - off;
            if (left > 0) std.mem.copyForwards(u8, self.in_buf[0..left], self.in_buf[off..][0..left]);
            self.in_len = left;
        }
        return action;
    }

    fn handleKey(self: *App, key: keys_mod.Key) KeyAction {
        // Permission modal steals focus.
        if (self.permission.isPending()) {
            switch (key) {
                .char => |ch| {
                    if (ch == 'a' or ch == 'A') {
                        self.permission.decide(.allow);
                        return .none;
                    }
                    if (ch == 'd' or ch == 'D' or ch == 'n' or ch == 'N') {
                        self.permission.decide(.deny);
                        return .none;
                    }
                    // Ignore other inserts while modal open.
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
                .ctrl_c => {
                    // Signal path via Guard; do not forge.
                    return .none;
                },
                else => return .none,
            }
        }

        switch (key) {
            .ctrl_c => return .none, // Guard owns SIGINT
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
                return .none;
            },
            .backspace => {
                self.editor.backspace();
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
                var b = [_]u8{ch};
                _ = self.editor.insert(&b);
                return .none;
            },
            .unknown => return .none,
        }
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

    pub fn dispatchReply(self: *App) error{Busy, StartFailed}!void {
        if (self.worker_active) {
            self.setNote("busy_locked");
            return error.Busy;
        }
        const agent = self.agent orelse return error.StartFailed;
        const session = self.session orelse return error.StartFailed;
        const text = self.editor.slice();
        // History push only on accepted dispatch.
        self.history.pushAccepted(text);
        const owned = self.gpa.dupe(u8, text) catch return error.StartFailed;
        self.worker_prompt = owned;
        self.editor.clear();
        self.state = .busy;
        self.setNote("(starting…)");
        self.worker_finished.store(false, .release);
        self.worker_had_error = false;
        self.worker_active = true;

        const thread = std.Thread.spawn(.{}, workerMain, .{ self, agent, session }) catch {
            self.worker_active = false;
            self.state = .idle;
            self.gpa.free(self.worker_prompt);
            self.worker_prompt = &[_]u8{};
            return error.StartFailed;
        };
        self.worker = thread;
    }

    fn workerMain(self: *App, agent: *coding.Agent, session: *coding.Session) void {
        defer {
            self.worker_finished.store(true, .release);
            self.wake();
        }
        const prompt = self.worker_prompt;
        _ = agent.reply(session, prompt) catch {
            self.worker_had_error = true;
            self.card_ring.publishHostErrorFixed("host_error", "reply_error");
            return;
        };
    }

    fn paint(self: *App, term: *terminal_mod.Terminal) error{WriteFailed}!void {
        const sz = term.size();
        const n = self.card_ring.snapshot(&self.snap_buf);
        const session = self.session;
        var steer: u32 = 0;
        var follow: u32 = 0;
        if (session) |s| {
            steer = @intCast(s.steeringPending());
            follow = @intCast(s.followUpPending());
        }
        const facts = render.StatusFacts{
            .id_display = self.idDisplay(),
            .open_display = self.open_display.label(),
            .session_configured = self.session_configured_ui,
            .perm = self.perm_label,
            .shell = self.shell_label,
            .state = self.state,
            .status_note = self.noteSlice(),
            .steering_pending = steer,
            .followup_pending = follow,
        };
        try render.renderFrame(
            term,
            sz,
            facts,
            self.snap_buf[0..n],
            &self.editor,
            self.permission.isPending(),
            &self.permission,
        );
    }

    fn fixedStderr(self: *App, msg: []const u8) void {
        _ = self;
        // Fixed diagnostics only — no user/model content.
        if (builtin.os.tag == .linux and !builtin.link_libc) {
            _ = std.os.linux.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        } else {
            _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
        }
    }
};

// ── unit / integration tests (see also tests_gate.zig for §11 map) ──────────

test "app create preallocates and destroy frees" {
    const gpa = std.testing.allocator;
    const app = try App.create(gpa);
    try std.testing.expect(app.editor_storage.len == c.editor_max_bytes);
    try std.testing.expect(app.wake_r >= 0);
    app.destroy();
}
