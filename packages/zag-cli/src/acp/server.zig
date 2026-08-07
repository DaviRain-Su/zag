//! ACP (Agent Client Protocol) v1 dual-thread server host (zag-cli, acp.md
//! §10). The third long-lived host assembly (after TUI and rpc-v1): the same
//! Agent + Session surfaces, with the terminal/pipe UI replaced by JSON-RPC
//! 2.0 over stdio. Imports `rpc/framing.zig` READ-ONLY (acp.md §2 — the line
//! discipline is identical; the envelope/vocabulary is this module's own).
//!
//! Concurrency model (acp.md §10.1, rpc-v1 §8.1 pattern):
//!   main thread:  poll stdin + guard self-pipe → read frames → dispatch
//!                 → responses (writer mutex); owns shutdown.
//!   worker thread: Agent.reply(session, flattened_prompt), one at a time.
//!   lifecycle/observer callbacks fire ON the worker thread and serialize
//!   each `session/update` notification under the writer mutex immediately
//!   (program order); the `session/prompt` response is always the last frame
//!   of its run.
//!   permission gate: worker blocks on a condvar; the main thread delivers
//!   the client's `session/request_permission` response / cancel / shutdown
//!   as allow-or-deny (acp.md §9).
//!
//! Shutdown (acp.md §10.3): stdin EOF · first SIGINT/SIGTERM — one graceful
//! sequence: stop reading stdin, resolve the pending gate as DENY,
//! requestCancel, bounded join (30 s), save best effort, exit 0. Join-bound
//! expiry → 70. Second SIGINT → 130 (the Guard's pending state is never
//! acknowledged while shutting down). No `exit` request (ACP has none — the
//! client owns process lifetime), no idle timeout.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const coding = @import("zag-coding-agent");
const sigint = @import("../sigint.zig");
const framing = @import("../rpc/framing.zig");
const protocol = @import("protocol.zig");
const redact_mod = coding.redact;

/// Bounded join bound for graceful shutdown (acp.md §10.3).
pub const shutdown_join_bound_ms: u64 = 30_000;
/// Main-loop poll timeout (also paces worker reaping).
const poll_timeout_ms: i32 = 250;

/// Host options reused for the single session the process opens (acp.md §7).
pub const HostOptions = struct {
    load_project_instructions: bool = true,
    skills_enabled: bool = true,
    project_skills_trust: coding.ProjectSkillsTrust = .untrusted,
    user_skills_root: ?[]const u8 = null,
    templates_enabled: bool = true,
    project_templates_trust: coding.ProjectTemplatesTrust = .untrusted,
    user_templates_root: ?[]const u8 = null,
    base_system: []const u8 = "",
    permission_mode: coding.permissions.Mode = .ask,
    shell_policy: coding.shell_policy.Mode = .protect,
    /// `--no-remember`: approved write paths are never remembered.
    remember_writes: bool = true,
};

/// One resolved gate decision from the wire (acp.md §9).
const GateDecision = struct {
    decision: coding.permissions.Decision,
    /// allow_always: the write path enters the remember store.
    remember: bool,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    agent: ?*coding.Agent = null,
    session: ?*coding.Session = null,
    guard: ?*sigint.Guard = null,
    /// Session redactor (stable pointer while a session is bound).
    redactor: ?*const redact_mod.Redactor = null,
    host: HostOptions = .{},
    /// Process cwd (canonicalized at startup; acp.md §7 — `session/new` and
    /// `session/list` compare against / surface this).
    cwd_abs: []u8 = &.{},

    // Threading (acp.md §10.1).
    writer_mu: Io.Mutex = .init,
    worker: ?std.Thread = null,
    worker_active: std.atomic.Value(bool) = .init(false),
    worker_finished: std.atomic.Value(bool) = .init(false),
    /// Owned prompt text for the in-flight run (freed at join).
    worker_prompt: []u8 = &.{},
    /// Owned id of the in-flight prompt (echoed in the run's response).
    current_prompt_id: protocol.Id = .null_val,

    // Permission gate bridge (acp.md §9).
    gate_mu: Io.Mutex = .init,
    gate_cond: Io.Condition = .init,
    gate_pending: bool = false,
    gate_request_id: u64 = 0,
    gate_decision: ?GateDecision = null,
    /// Server-owned remember store: `allow_always` records approved write
    /// paths here (the Agent's own store is private; passing this one via
    /// `gate.remember` keeps remember semantics under adapter control).
    remember_store: coding.permissions.Remember,

    // Protocol state.
    initialized: std.atomic.Value(bool) = .init(false),

    // Shutdown (acp.md §10.3). `shutting_down` is set BEFORE the gate/join
    // sequence so a gate ask racing shutdown always resolves deny.
    shutting_down: std.atomic.Value(bool) = .init(false),
    /// Set when stdout writes fail (client gone); worker emits become no-ops.
    pipe_broken: std.atomic.Value(bool) = .init(false),
    /// Exit code decided by the shutdown sequence.
    exit_code: u8 = 0,
    /// Counter for adapter-generated interjection ids (only when the client
    /// omits `interjectionId`).
    steer_counter: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, host: HostOptions) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .host = host,
            .remember_store = coding.permissions.Remember.init(gpa, host.remember_writes),
        };
    }

    pub fn bind(
        self: *Server,
        agent: *coding.Agent,
        session: *coding.Session,
        guard: *sigint.Guard,
    ) void {
        self.agent = agent;
        self.session = session;
        self.guard = guard;
        self.redactor = session.activeRedactor();
    }

    /// AskFn context binding for `permissions.Gate.ask` (acp.md §9). yolo
    /// mode binds no ask fn (no permission frames are ever emitted).
    pub fn gate(self: *Server) coding.permissions.Gate {
        if (self.host.permission_mode == .yolo) return coding.permissions.Gate.yolo();
        var g = coding.permissions.Gate.ask(askFn, self);
        g.remember = &self.remember_store;
        return g;
    }

    fn askFn(
        ptr: ?*anyopaque,
        descriptor: coding.tool.ToolDescriptor,
        arguments_json: []const u8,
    ) coding.permissions.Decision {
        const self: *Server = @ptrCast(@alignCast(ptr.?));
        return self.gateAsk(descriptor, arguments_json);
    }

    pub fn lifecycleObserver(self: *Server) coding.LifecycleObserver {
        return .{ .ptr = self, .on_event = onLifecycle };
    }

    pub fn observer(self: *Server) coding.Observer {
        return .{ .ptr = self, .on_event = onObserver };
    }

    // ── Gate bridge (acp.md §9) ──────────────────────────────────────────

    /// Runs ON THE WORKER THREAD inside `Agent.reply` (ask mode only).
    /// Emits `session/request_permission` as a JSON-RPC request with the
    /// adapter's own id and blocks on the condvar until the client's
    /// response / cancel / shutdown resolves it. Cancel and shutdown resolve
    /// DENY — never allow.
    fn gateAsk(
        self: *Server,
        descriptor: coding.tool.ToolDescriptor,
        arguments_json: []const u8,
    ) coding.permissions.Decision {
        // Every ask starts with remembering enabled: a previous allow_once
        // suppressed the store so the auto-remember after THIS gate's allow
        // is a no-op (acp.md §9 — allow_once never remembers).
        self.remember_store.enabled = true;

        self.gate_mu.lock(self.io) catch return .deny;
        if (self.shutting_down.load(.acquire)) {
            self.gate_mu.unlock(self.io);
            return .deny;
        }
        self.gate_request_id += 1;
        const rid = self.gate_request_id;
        self.gate_pending = true;
        self.gate_decision = null;
        self.gate_mu.unlock(self.io);

        self.emitPermissionRequest(rid, descriptor, arguments_json);

        self.gate_mu.lock(self.io) catch return .deny;
        while (self.gate_decision == null and !self.shutting_down.load(.acquire)) {
            // Unblocks on signal; the predicate re-check under the mutex
            // closes the lost-wakeup race with shutdown/cancel resolution.
            self.gate_cond.wait(self.io, &self.gate_mu) catch break;
        }
        const decision = self.gate_decision orelse GateDecision{ .decision = .deny, .remember = false };
        self.gate_pending = false;
        self.gate_decision = null;
        self.gate_mu.unlock(self.io);

        if (decision.decision == .allow and !decision.remember) {
            // Suppress the Gate's automatic remember for THIS check only
            // (the next ask re-enables at entry above). `Gate.check` records
            // the write path right after askFn returns; a disabled store
            // makes that a no-op.
            self.remember_store.enabled = false;
        }
        return decision.decision;
    }

    /// Resolve a pending gate from a wire response to the adapter's
    /// `session/request_permission` (main thread). Unmatched responses are
    /// ignored (JSON-RPC rule).
    fn resolveGate(self: *Server, id: protocol.Id, outcome: protocol.PermissionOutcome) bool {
        self.gate_mu.lock(self.io) catch return false;
        defer self.gate_mu.unlock(self.io);
        if (!self.gate_pending) return false;
        if (id != .int or id.int != @as(i64, @intCast(self.gate_request_id))) return false;
        self.gate_decision = outcomeToDecision(outcome);
        self.gate_cond.signal(self.io);
        return true;
    }

    /// Resolve a pending gate as DENY (cancel request / shutdown; main thread).
    fn denyPendingGate(self: *Server) void {
        self.gate_mu.lock(self.io) catch return;
        defer self.gate_mu.unlock(self.io);
        if (!self.gate_pending) return;
        self.gate_decision = .{ .decision = .deny, .remember = false };
        self.gate_cond.signal(self.io);
    }

    // ── Main loop (acp.md §10.1) ─────────────────────────────────────────

    pub fn run(self: *Server) u8 {
        var fr = framing.FrameReader.init(self.gpa, posix.STDIN_FILENO);
        defer fr.deinit();

        var pollfds: [2]posix.pollfd = .{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (self.guard) |g| g.read_fd else -1, .events = posix.POLL.IN, .revents = 0 },
        };

        while (!self.shutting_down.load(.acquire)) {
            // Reap a finished worker so worker_active clears between runs.
            if (self.worker_active.load(.acquire) and self.worker_finished.load(.acquire)) {
                self.joinWorker();
            }
            _ = posix.poll(&pollfds, poll_timeout_ms) catch continue; // EINTR auto-restarts
            if (pollfds[1].revents != 0) {
                drainWake(pollfds[1].fd);
                if (self.guard) |g| {
                    if (g.pendingInterrupt()) {
                        self.beginShutdown();
                        break;
                    }
                }
            }
            if (pollfds[0].revents != 0) {
                _ = fr.fill() catch |err| {
                    std.log.err("acp: stdin read failed: {s}", .{@errorName(err)});
                    self.beginShutdown();
                    break;
                };
                while (true) {
                    const maybe_next = fr.takeFrame() catch |err| {
                        std.log.err("acp: frame read failed: {s}", .{@errorName(err)});
                        self.beginShutdown();
                        break;
                    };
                    const nxt = maybe_next orelse break;
                    switch (nxt) {
                        .line => |line| {
                            self.dispatchLine(line);
                            self.gpa.free(line);
                        },
                        .eof => {
                            // Client disconnect (acp.md §10.3 — editor closed
                            // the process / stdin).
                            self.beginShutdown();
                            break;
                        },
                        .too_long => {
                            self.respondError(.null_val, .parse_error, "frame exceeds the 4 MiB cap");
                        },
                    }
                    if (self.shutting_down.load(.acquire)) break;
                }
                if (self.shutting_down.load(.acquire)) break;
            }
            if (pollfds[0].revents & posix.POLL.HUP != 0 and pollfds[0].revents & posix.POLL.IN == 0) {
                // Hangup without readability: drain to detect EOF.
                _ = fr.fill() catch {};
                if (fr.eof) {
                    self.beginShutdown();
                    break;
                }
            }
        }

        self.beginShutdown(); // idempotent
        return self.exit_code;
    }

    fn dispatchLine(self: *Server, line: []const u8) void {
        // Close the join race: the worker writes the run's response and
        // exits; worker_active must be cleared BEFORE the next frame is
        // dispatched so a prompt arriving right after the response sees the
        // idle state.
        if (self.worker_active.load(.acquire) and self.worker_finished.load(.acquire)) {
            self.joinWorker();
        }
        var frame = protocol.parseFrame(self.gpa, line) catch {
            self.respondError(.null_val, .internal_error, "out of memory");
            self.fatalExit(40);
            return;
        };
        defer frame.deinit(self.gpa);
        switch (frame) {
            .reject => |*r| self.respondError(r.id, r.code, r.message),
            .request => |*req| self.handleRequest(req),
            .notification => |*n| self.handleNotification(n),
            .response => |*r| _ = self.resolveGate(r.id, r.outcome),
            .ignore => {},
        }
    }

    fn handleRequest(self: *Server, req: *const protocol.Request) void {
        if (req.method != .initialize and !self.initialized.load(.acquire)) {
            return self.respondError(req.id, .invalid_request, "not initialized");
        }
        switch (req.method) {
            .initialize => self.handleInitialize(req),
            .@"session/new" => self.handleSessionNew(req),
            .@"session/prompt" => self.handlePrompt(req),
            .@"session/list" => self.handleSessionList(req),
            .@"session/steer" => self.handleSteer(req),
            .@"authentication/getUser" => self.respond(req.id, protocol.GetUserResult{}),
            .ping => self.respond(req.id, protocol.EmptyResult{}),
            .@"session/cancel" => unreachable, // notification-only method
        }
    }

    fn handleNotification(self: *Server, n: *const protocol.Notification) void {
        switch (n.method) {
            .@"session/cancel" => self.handleCancel(n.params.@"session/cancel".session_id),
            // `initialized` and every other notification (including unknown
            // methods, which never reach here) are ignored.
            else => {},
        }
    }

    fn handleInitialize(self: *Server, req: *const protocol.Request) void {
        // A second initialize is an invalid request (acp.md §6.1).
        if (self.initialized.swap(true, .acq_rel)) {
            return self.respondError(req.id, .invalid_request, "already initialized");
        }
        self.respond(req.id, protocol.InitializeResult{
            .agentCapabilities = .{ .sessionCapabilities = .{} },
            .agentInfo = .{
                .name = "zag",
                .title = "Zag",
                .version = coding.version,
            },
        });
    }

    fn handleSessionNew(self: *Server, req: *const protocol.Request) void {
        const p = req.params.@"session/new";
        // Fail closed: the agent runs in the workspace the host launched it
        // in. Canonicalized comparison (acp.md §7).
        if (!self.cwdMatches(p.cwd)) {
            return self.respondError(req.id, .invalid_params, "cwd does not match the process working directory");
        }
        if (p.mcp_servers_nonempty) {
            return self.respondError(req.id, .invalid_params, "mcpServers are not supported");
        }
        if (p.additional_dirs_nonempty) {
            return self.respondError(req.id, .invalid_params, "additionalDirectories are not supported");
        }
        if (p.prompt_present) {
            return self.respondError(req.id, .invalid_params, "initial prompt unsupported; use session/prompt");
        }
        // Idempotent: maps onto the startup session (acp.md §7).
        self.respond(req.id, protocol.SessionNewResult{ .sessionId = protocol.session_id });
    }

    fn handlePrompt(self: *Server, req: *const protocol.Request) void {
        const p = req.params.@"session/prompt";
        if (!std.mem.eql(u8, p.session_id, protocol.session_id)) {
            return self.respondError(req.id, .invalid_params, "unknown sessionId");
        }
        if (self.session == null) {
            return self.respondError(req.id, .internal_error, "no session bound");
        }
        if (self.worker_active.load(.acquire)) {
            return self.respondError(req.id, .busy, "a run is already in flight");
        }
        const owned = self.gpa.dupe(u8, p.prompt_text) catch {
            self.respondError(req.id, .internal_error, "out of memory");
            self.fatalExit(40);
            return;
        };
        self.current_prompt_id = req.id.clone(self.gpa) catch {
            self.gpa.free(owned);
            self.respondError(req.id, .internal_error, "out of memory");
            self.fatalExit(40);
            return;
        };
        self.worker_prompt = owned;
        self.worker_finished.store(false, .release);
        self.worker_active.store(true, .release);
        const th = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            self.worker_active.store(false, .release);
            self.gpa.free(owned);
            self.worker_prompt = &.{};
            self.current_prompt_id.deinit(self.gpa);
            self.current_prompt_id = .null_val;
            self.respondError(req.id, .internal_error, "worker thread spawn failed");
            self.fatalExit(40);
            return;
        };
        self.worker = th;
    }

    fn handleCancel(self: *Server, session_id: []const u8) void {
        // Notification: never answered. Unknown sessionId or idle → ignored
        // (acp.md §6.1).
        if (!std.mem.eql(u8, session_id, protocol.session_id)) return;
        // Cancel while a gate is pending resolves it as DENY (never allow).
        if (self.gate_pending) self.denyPendingGate();
        if (self.worker_active.load(.acquire)) {
            if (self.agent) |a| a.requestCancel();
        }
        // Idle cancel is a no-op: the flag is NOT set when idle, so the next
        // prompt starts clean.
    }

    fn handleSessionList(self: *Server, req: *const protocol.Request) void {
        self.respond(req.id, protocol.SessionListResult{
            .sessions = &.{.{ .sessionId = protocol.session_id, .cwd = self.cwd_abs }},
        });
    }

    fn handleSteer(self: *Server, req: *const protocol.Request) void {
        const p = req.params.@"session/steer";
        if (!std.mem.eql(u8, p.session_id, protocol.session_id)) {
            return self.respondError(req.id, .invalid_params, "unknown sessionId");
        }
        const session = self.session orelse {
            return self.respondError(req.id, .internal_error, "no session bound");
        };
        session.enqueueSteering(p.text) catch |err| switch (err) {
            error.QueueFull => return self.respondError(req.id, .queue_full, "control queue full (cap 4)"),
            error.MessageTooLong => return self.respondError(req.id, .message_too_long, "control text exceeds the 4096 B cap"),
            error.EmptyMessage => return self.respondError(req.id, .invalid_params, "text must be non-empty"),
            error.InvalidUtf8 => return self.respondError(req.id, .invalid_params, "text is not valid UTF-8"),
        };
        self.steer_counter += 1;
        const interjection = p.interjection_id orelse std.fmt.allocPrint(self.gpa, "steer_{d}", .{self.steer_counter}) catch {
            self.respondError(req.id, .internal_error, "out of memory");
            self.fatalExit(40);
            return;
        };
        defer if (p.interjection_id == null) self.gpa.free(interjection);
        self.respond(req.id, protocol.SteerResult{ .interjectionId = interjection });
    }

    // ── Reply worker (acp.md §10.1) ──────────────────────────────────────

    fn workerMain(self: *Server) void {
        defer self.worker_finished.store(true, .release);
        const agent = self.agent orelse return;
        const session = self.session orelse return;
        const prompt = self.worker_prompt;
        const result = agent.reply(session, prompt) catch |err| {
            self.respondPromptFailure(err);
            return;
        };
        self.respondPromptResult(result);
    }

    fn respondPromptResult(self: *Server, result: coding.loop.Result) void {
        const id = self.current_prompt_id;
        switch (result.stop_reason) {
            .completed => self.respond(id, protocol.PromptResult{ .stopReason = "end_turn" }),
            .max_turns => self.respond(id, protocol.PromptResult{ .stopReason = "max_turn_requests" }),
            .cancelled => self.respond(id, protocol.PromptResult{ .stopReason = "cancelled" }),
            // Run-level failures are never invented successes (acp.md §11.3).
            else => self.respondError(id, .run_error, runErrorMessage(result.stop_reason)),
        }
    }

    fn respondPromptFailure(self: *Server, err: coding.agent.ReplyError) void {
        const stop: coding.loop.StopReason = switch (err) {
            error.ProviderFailed => .provider_error,
            error.TraceFailed => .trace_error,
            error.OutOfMemory => .out_of_memory,
            error.InvalidToolset => .invalid_toolset,
            error.InvalidContext => .invalid_context,
            error.MaxTurnsExceeded => .max_turns,
            // Session store failures surface as session_error.
            else => .session_error,
        };
        switch (stop) {
            .max_turns => self.respond(self.current_prompt_id, protocol.PromptResult{ .stopReason = "max_turn_requests" }),
            else => self.respondError(self.current_prompt_id, .run_error, runErrorMessage(stop)),
        }
    }

    fn joinWorker(self: *Server) void {
        if (self.worker) |*th| {
            th.join();
            self.worker = null;
        }
        self.worker_active.store(false, .release);
        if (self.worker_prompt.len != 0) {
            self.gpa.free(self.worker_prompt);
            self.worker_prompt = &.{};
        }
        if (self.current_prompt_id != .null_val) {
            self.current_prompt_id.deinit(self.gpa);
            self.current_prompt_id = .null_val;
        }
    }

    /// Bounded join used by shutdown. Returns true when the worker joined
    /// within the bound.
    fn joinWorkerBounded(self: *Server, bound_ms: u64) bool {
        if (!self.worker_active.load(.acquire)) return true;
        var elapsed: u64 = 0;
        const step_ms: u64 = 10;
        while (elapsed < bound_ms) {
            if (self.worker_finished.load(.acquire)) {
                self.joinWorker();
                return true;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(step_ms), .real) catch {};
            elapsed += step_ms;
        }
        return false;
    }

    // ── Shutdown (acp.md §10.3) ──────────────────────────────────────────

    /// Exactly one graceful sequence for EOF / first SIGINT. Idempotent;
    /// safe to call from the main thread only (it joins the worker, which
    /// the worker itself must never join).
    fn beginShutdown(self: *Server) void {
        if (self.shutting_down.swap(true, .acq_rel)) return;
        // Resolve any pending permission gate as DENY (never allow).
        self.denyPendingGate();
        // Cooperative cancel when a run is in flight.
        if (self.worker_active.load(.acquire)) {
            if (self.agent) |a| a.requestCancel();
        }
        const joined = self.joinWorkerBounded(shutdown_join_bound_ms);
        // Save best effort (durable only; errors are stderr-logged).
        if (self.session) |s| {
            s.save() catch |err| {
                std.log.err("acp: session save failed: {s}", .{@errorName(err)});
            };
        }
        // Truthful terminal: join-bound expiry is an internal failure (70).
        self.exit_code = if (joined) 0 else 70;
    }

    /// Internal failure: best-effort `-32603` error frame, then exit with the
    /// mapped code (40 out-of-memory / 70 internal, acp.md §10.4).
    fn fatalExit(self: *Server, code: u8) noreturn {
        self.respondError(.null_val, .internal_error, "internal error");
        std.process.exit(code);
    }

    // ── Frame writers (one writer mutex) ─────────────────────────────────

    fn respond(self: *Server, id: protocol.Id, result: anytype) void {
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.ServerResponse(@TypeOf(result)){
            .id = id,
            .result = result,
        }, &body) catch {
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
    }

    fn respondError(self: *Server, id: protocol.Id, code: protocol.ErrorCode, message: []const u8) void {
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.ServerResponse(protocol.EmptyResult){
            .id = id,
            .@"error" = protocol.errorOf(code, message),
        }, &body) catch {
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
    }

    fn emit(self: *Server, method: []const u8, params: anytype) void {
        if (self.pipe_broken.load(.acquire)) return;
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.ServerNotification(@TypeOf(params)){
            .method = method,
            .params = params,
        }, &body) catch {
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
    }

    fn emitUpdate(self: *Server, update: protocol.Update) void {
        self.emit("session/update", protocol.UpdateParams{
            .sessionId = protocol.session_id,
            .update = update,
        });
    }

    /// Serialize one frame under the writer mutex. Write failures (client
    /// gone) mark the pipe broken; subsequent emits become no-ops.
    fn writeFrame(self: *Server, line: []const u8) void {
        self.writer_mu.lock(self.io) catch return;
        defer self.writer_mu.unlock(self.io);
        self.out.writeAll(line) catch {
            self.pipe_broken.store(true, .release);
            return;
        };
        self.out.writeAll("\n") catch {
            self.pipe_broken.store(true, .release);
            return;
        };
        self.out.flush() catch {
            self.pipe_broken.store(true, .release);
            return;
        };
    }

    /// Redact one string with the bound session redactor (gpa-owned result).
    fn redactOwned(self: *Server, text: []const u8) std.mem.Allocator.Error![]u8 {
        return redact_mod.redactOptional(self.redactor, self.gpa, text);
    }

    // ── Notifications / requests (acp.md §8, §9) ─────────────────────────

    fn emitPermissionRequest(
        self: *Server,
        request_id: u64,
        descriptor: coding.tool.ToolDescriptor,
        arguments_json: []const u8,
    ) void {
        const title = self.redactOwned(descriptor.definition.name) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(title);
        const raw_fields = self.redactOwned(arguments_json) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(raw_fields);
        const fields = protocol.capText(self.gpa, raw_fields, protocol.permission_fields_max_bytes) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(fields);
        const call_id = std.fmt.allocPrint(self.gpa, "gate_{d}", .{request_id}) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(call_id);

        if (self.pipe_broken.load(.acquire)) return;
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.ServerRequest(protocol.PermissionRequestParams){
            .id = .{ .int = @intCast(request_id) },
            .method = "session/request_permission",
            .params = .{
                .sessionId = protocol.session_id,
                .toolCall = .{
                    // The tool's real call id is assigned by the loop only
                    // AFTER the gate allows; the adapter generates its own
                    // correlation id (the tool_call frame carries the real
                    // one, acp.md §8).
                    .toolCallId = call_id,
                    .title = title,
                    .fields = fields,
                },
                .options = .{
                    .{ .id = protocol.permission_options[0].id, .kind = protocol.permission_options[0].kind },
                    .{ .id = protocol.permission_options[1].id, .kind = protocol.permission_options[1].kind },
                    .{ .id = protocol.permission_options[2].id, .kind = protocol.permission_options[2].kind },
                    .{ .id = protocol.permission_options[3].id, .kind = protocol.permission_options[3].kind },
                },
            },
        }, &body) catch {
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
    }

    fn cwdMatches(self: *Server, client_cwd: []const u8) bool {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPathFile(self.io, client_cwd, &buf) catch return false;
        return std.mem.eql(u8, buf[0..n], self.cwd_abs);
    }

    // ── Event projection (worker thread; program order) ──────────────────

    fn onLifecycle(ptr: ?*anyopaque, event: coding.LifecycleEvent) void {
        const self: *Server = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            // No ACP variants for run/assistant-message/clear/control/terminal
            // events (acp.md §8 — the prompt response is the run's terminal).
            .run_start, .assistant_message, .assistant_delta_clear,
            .control_applied, .run_terminal => {},
            .assistant_delta => |delta| {
                const red = self.redactOwned(delta) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                self.emitUpdate(.{ .agent_message_chunk = .{ .text = red } });
            },
            .thinking_delta => |delta| {
                const red = self.redactOwned(delta) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                self.emitUpdate(.{ .agent_thought_chunk = .{ .text = red } });
            },
            .tool_start => |t| {
                const id = self.redactOwned(t.id) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(id);
                const title = self.redactOwned(t.name) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(title);
                self.emitUpdate(.{ .tool_call = .{
                    .toolCallId = id,
                    .title = title,
                } });
            },
            .tool_end => |t| {
                const id = self.redactOwned(t.id) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(id);
                const body = self.redactOwned(t.body) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(body);
                const status: []const u8 = if (toolBodyLooksFailed(body)) "failed" else "completed";
                self.emitUpdate(.{ .tool_call_update = .{
                    .toolCallId = id,
                    .status = status,
                    .content = if (body.len > 0)
                        &.{.{ .content = .{ .text = body } }}
                    else
                        null,
                } });
            },
        }
    }

    fn onObserver(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *Server = @ptrCast(@alignCast(ptr.?));
        // Observer events have no ACP v1 wire variant (acp.md §8): usage is
        // not fabricated, permission decisions surface through the §9 flow,
        // and tools are single-sourced on the lifecycle tool_start/tool_end
        // pair.
        _ = self;
        _ = event;
    }
};

// ── helpers ─────────────────────────────────────────────────────────────────

fn outcomeToDecision(outcome: protocol.PermissionOutcome) GateDecision {
    return switch (outcome) {
        .option => |o| {
            if (std.mem.eql(u8, o, "allow_once")) {
                return .{ .decision = .allow, .remember = false };
            }
            if (std.mem.eql(u8, o, "allow_always")) {
                return .{ .decision = .allow, .remember = true };
            }
            // reject_once / reject_always / unknown option ids → deny
            // (zag has no deny-remember store; acp.md §9).
            return .{ .decision = .deny, .remember = false };
        },
        .cancelled, .invalid => .{ .decision = .deny, .remember = false },
    };
}

/// Static redacted labels for run-level failures (acp.md §11.3 — never
/// provider text, never paths).
fn runErrorMessage(stop_reason: coding.loop.StopReason) []const u8 {
    return switch (stop_reason) {
        .completed, .max_turns, .cancelled => "run failed",
        .timeout => "provider timeout",
        .unsupported_control => "unsupported control",
        .provider_error => "provider error",
        .session_error => "session error",
        .trace_error => "trace error",
        .out_of_memory => "out of memory",
        .invalid_toolset => "invalid toolset",
        .invalid_context => "invalid context",
    };
}

/// Soft heuristic shared with the TUI tool card (zag-tui render.zig): the
/// loop/tool_error envelopes mark failure.
fn toolBodyLooksFailed(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "error:") != null) return true;
    if (std.mem.indexOf(u8, body, "permission denied") != null) return true;
    if (std.mem.indexOf(u8, body, "jail_deny") != null) return true;
    if (std.mem.indexOf(u8, body, "\"ok\":false") != null) return true;
    return false;
}

fn drainWake(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
    }
}

/// Startup process exit code for a `Session.start` failure (acp.md §10.4 —
/// the headless numeric matrix, no stdout bytes at startup).
pub fn sessionStartExitCode(err: anyerror) u8 {
    return switch (err) {
        error.SessionNotFound => 50,
        error.SessionAlreadyExists => 51,
        error.InvalidSession, error.InvalidPath => 52,
        error.UnsupportedSchema => 53,
        error.SessionBusy => 54,
        error.IoFailed => 55,
        error.OutOfMemory => 40,
        else => 70,
    };
}

/// Startup stderr diagnostic for a `Session.start` failure.
pub fn sessionStartMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionNotFound => "session not found",
        error.SessionAlreadyExists => "session already exists",
        error.InvalidSession, error.InvalidPath => "session invalid",
        error.UnsupportedSchema => "session schema unsupported",
        error.SessionBusy => "session busy",
        error.IoFailed => "session I/O failed",
        error.OutOfMemory => "out of memory",
        else => "session start failed",
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "outcomeToDecision maps frozen option ids" {
    try testing.expectEqual(GateDecision{ .decision = .allow, .remember = false }, outcomeToDecision(.{ .option = "allow_once" }));
    try testing.expectEqual(GateDecision{ .decision = .allow, .remember = true }, outcomeToDecision(.{ .option = "allow_always" }));
    try testing.expectEqual(GateDecision{ .decision = .deny, .remember = false }, outcomeToDecision(.{ .option = "reject_once" }));
    try testing.expectEqual(GateDecision{ .decision = .deny, .remember = false }, outcomeToDecision(.{ .option = "reject_always" }));
    try testing.expectEqual(GateDecision{ .decision = .deny, .remember = false }, outcomeToDecision(.{ .option = "frobnicate" }));
    try testing.expectEqual(GateDecision{ .decision = .deny, .remember = false }, outcomeToDecision(.cancelled));
    try testing.expectEqual(GateDecision{ .decision = .deny, .remember = false }, outcomeToDecision(.invalid));
}

test "runErrorMessage is static and redacted" {
    try testing.expectEqualStrings("provider error", runErrorMessage(.provider_error));
    try testing.expectEqualStrings("out of memory", runErrorMessage(.out_of_memory));
    try testing.expectEqualStrings("session error", runErrorMessage(.session_error));
    try testing.expectEqualStrings("trace error", runErrorMessage(.trace_error));
    try testing.expectEqualStrings("invalid toolset", runErrorMessage(.invalid_toolset));
    try testing.expectEqualStrings("invalid context", runErrorMessage(.invalid_context));
    try testing.expectEqualStrings("provider timeout", runErrorMessage(.timeout));
}

test "toolBodyLooksFailed detects error envelopes" {
    try testing.expect(toolBodyLooksFailed("tool error: permission denied"));
    try testing.expect(toolBodyLooksFailed("permission denied for tool 'write_file'"));
    try testing.expect(toolBodyLooksFailed("jail_deny"));
    try testing.expect(!toolBodyLooksFailed("ok: code=shell_success"));
}

test "sessionStartExitCode maps store failures" {
    try testing.expectEqual(@as(u8, 50), sessionStartExitCode(error.SessionNotFound));
    try testing.expectEqual(@as(u8, 51), sessionStartExitCode(error.SessionAlreadyExists));
    try testing.expectEqual(@as(u8, 52), sessionStartExitCode(error.InvalidSession));
    try testing.expectEqual(@as(u8, 53), sessionStartExitCode(error.UnsupportedSchema));
    try testing.expectEqual(@as(u8, 54), sessionStartExitCode(error.SessionBusy));
    try testing.expectEqual(@as(u8, 55), sessionStartExitCode(error.IoFailed));
    try testing.expectEqual(@as(u8, 40), sessionStartExitCode(error.OutOfMemory));
    try testing.expectEqual(@as(u8, 70), sessionStartExitCode(error.TraceFailed));
}
