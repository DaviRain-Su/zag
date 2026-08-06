//! rpc-v1 dual-thread server host (zag-cli, rpc-v1 §8).
//!
//! Assembles the existing public coding-agent surfaces exactly as the TUI
//! host assembles them: Agent.reply on a worker thread, Session control
//! queues, LifecycleObserver + Observer projected onto wire notifications,
//! `permissions.Gate.ask` bridged over a condvar, `sigint.Guard` for signal
//! shutdown. The terminal UI is replaced by the pipe protocol.
//!
//! Concurrency model (rpc-v1 §8.1):
//!   main thread:  poll stdin + guard self-pipe → read frames → dispatch
//!                 → responses (writer mutex); owns shutdown.
//!   worker thread: Agent.reply(session, prompt), one at a time.
//!   lifecycle/observer callbacks fire ON the worker thread and serialize
//!   each notification under the writer mutex immediately (program order);
//!   the `prompt` response is always the last frame of its run.
//!   permission gate: worker blocks on a condvar; the main thread delivers
//!   `permission_decision` / cancel / shutdown as deny-or-allow.
//!
//! Shutdown (rpc-v1 §8.3): `exit` request · stdin EOF · first SIGINT all
//! share one graceful sequence — stop reading stdin, resolve the pending gate
//! as DENY, requestCancel, bounded join (30 s), save best effort, exit 0.
//! Join-bound expiry → 70. Second SIGINT → 130 (Guard's pending state is
//! intentionally never acknowledged while shutting down). No idle timeout.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const coding = @import("zag-coding-agent");
const sigint = @import("../sigint.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const redact_mod = coding.redact;

/// Bounded join bound for graceful shutdown (rpc-v1 §10).
pub const shutdown_join_bound_ms: u64 = 30_000;
/// Main-loop poll timeout (also paces worker reaping).
const poll_timeout_ms: i32 = 250;

/// Host options reused for every session the process opens (rpc-v1 §7).
pub const HostOptions = struct {
    load_project_instructions: bool = true,
    skills_enabled: bool = true,
    project_skills_trust: coding.ProjectSkillsTrust = .untrusted,
    user_skills_root: ?[]const u8 = null,
    templates_enabled: bool = true,
    project_templates_trust: coding.ProjectTemplatesTrust = .untrusted,
    user_templates_root: ?[]const u8 = null,
    base_system: []const u8 = "",
    /// Permission mode label for `ready` ("ask" | "yolo").
    permission: []const u8 = "ask",
    /// Shell policy label for `ready` ("protect" | "off").
    shell_policy: []const u8 = "protect",
    /// Whether the STARTUP session was resumed (-c) — surfaced in `ready`.
    session_resumed: bool = false,
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

    // Threading (rpc-v1 §8.1).
    writer_mu: Io.Mutex = .init,
    worker: ?std.Thread = null,
    worker_active: std.atomic.Value(bool) = .init(false),
    worker_finished: std.atomic.Value(bool) = .init(false),
    /// Owned prompt text for the in-flight run (freed at join).
    worker_prompt: []u8 = &.{},
    /// Request id of the in-flight prompt (echoed in the run's response).
    current_prompt_id: i64 = 0,
    /// `stream` param of the in-flight prompt (suppresses delta/thinking).
    run_stream: std.atomic.Value(bool) = .init(true),

    // Permission gate bridge (rpc-v1 §8.4).
    gate_mu: Io.Mutex = .init,
    gate_cond: Io.Condition = .init,
    gate_pending: bool = false,
    gate_request_id: u64 = 0,
    gate_decision: ?coding.permissions.Decision = null,

    // Event group subscriptions (rpc-v1 §6.2; default all ON). Atomics so the
    // main thread can re-subscribe while a worker is emitting.
    sub_delta: std.atomic.Value(bool) = .init(true),
    sub_thinking: std.atomic.Value(bool) = .init(true),
    sub_tools: std.atomic.Value(bool) = .init(true),
    sub_permission: std.atomic.Value(bool) = .init(true),
    sub_usage: std.atomic.Value(bool) = .init(true),
    sub_lifecycle: std.atomic.Value(bool) = .init(true),
    sub_session: std.atomic.Value(bool) = .init(true),

    // Shutdown (rpc-v1 §8.3). `shutting_down` is set BEFORE the gate/join
    // sequence so a gate ask racing shutdown always resolves deny.
    shutting_down: std.atomic.Value(bool) = .init(false),
    /// Set when stdout writes fail (client gone); worker emits become no-ops.
    pipe_broken: std.atomic.Value(bool) = .init(false),
    /// Exit code decided by the shutdown sequence.
    exit_code: u8 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, host: HostOptions) Server {
        return .{ .gpa = gpa, .io = io, .out = out, .host = host };
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

    /// AskFn context binding for `permissions.Gate.ask`.
    pub fn gate(self: *Server) coding.permissions.Gate {
        return coding.permissions.Gate.ask(askFn, self);
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

    // ── Gate bridge (rpc-v1 §8.4) ──────────────────────────────────────────

    /// Runs ON THE WORKER THREAD inside `Agent.reply` (ask mode only).
    /// Emits `permission_request` (unconditional) and blocks on the condvar
    /// until `permission_decision` / cancel / shutdown resolves it.
    /// Cancel and shutdown resolve DENY — never allow.
    fn gateAsk(
        self: *Server,
        descriptor: coding.tool.ToolDescriptor,
        arguments_json: []const u8,
    ) coding.permissions.Decision {
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
        const decision = self.gate_decision orelse .deny;
        self.gate_pending = false;
        self.gate_decision = null;
        self.gate_mu.unlock(self.io);
        return decision;
    }

    /// Resolve a pending gate from a wire `permission_decision` (main thread).
    fn resolveGate(self: *Server, request_id: i64, allowed: bool) bool {
        self.gate_mu.lock(self.io) catch return false;
        defer self.gate_mu.unlock(self.io);
        if (!self.gate_pending or self.gate_request_id != @as(u64, @intCast(request_id))) {
            return false;
        }
        self.gate_decision = if (allowed) .allow else .deny;
        self.gate_cond.signal(self.io);
        return true;
    }

    /// Resolve a pending gate as DENY (cancel request / shutdown; main thread).
    fn denyPendingGate(self: *Server) void {
        self.gate_mu.lock(self.io) catch return;
        defer self.gate_mu.unlock(self.io);
        if (!self.gate_pending) return;
        self.gate_decision = .deny;
        self.gate_cond.signal(self.io);
    }

    // ── Main loop (rpc-v1 §8.1) ────────────────────────────────────────────

    pub fn run(self: *Server) u8 {
        // First frame: `ready` (rpc-v1 §6.1), after Agent.init + Session.start.
        self.emitReady();

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
                    std.log.err("rpc: stdin read failed: {s}", .{@errorName(err)});
                    self.beginShutdown();
                    break;
                };
                while (true) {
                    const maybe_next = fr.takeFrame() catch |err| {
                        std.log.err("rpc: frame read failed: {s}", .{@errorName(err)});
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
                            // Client disconnect (rpc-v1 §8.3).
                            self.beginShutdown();
                            break;
                        },
                        .too_long => {
                            self.respondError(null, .invalid_arguments, "frame exceeds the 4 MiB cap");
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
        // Close the join race: the worker writes the run's response and exits;
        // worker_active must be cleared BEFORE the next frame is dispatched so
        // a prompt/resume arriving right after the response sees the idle
        // state (the join itself is microseconds once worker_finished is set).
        if (self.worker_active.load(.acquire) and self.worker_finished.load(.acquire)) {
            self.joinWorker();
        }
        var frame = protocol.parseFrame(self.gpa, line) catch {
            self.respondError(null, .out_of_memory, "out of memory");
            self.fatalExit(40);
            return;
        };
        defer switch (frame) {
            .request => |*r| r.params.deinit(self.gpa),
            else => {},
        };
        switch (frame) {
            .reject => |r| self.respondError(r.id, r.code, r.message),
            .request => |req| switch (req.method) {
                .prompt => self.handlePrompt(&req),
                .cancel => self.handleCancel(req.id),
                .steer => self.handleControl(req.id, .steer, req.params.steer.text),
                .follow_up => self.handleControl(req.id, .follow_up, req.params.follow_up.text),
                .subscribe => self.handleSubscribe(req.id, req.params.subscribe.events),
                .permission_decision => self.handlePermissionDecision(req.id, req.params.permission_decision),
                .@"resume" => self.handleResume(req.id, req.params.@"resume".path),
                .exit => self.handleExit(req.id),
            },
        }
    }

    fn handlePrompt(self: *Server, req: *const protocol.Request) void {
        if (self.session == null) {
            return self.respondError(req.id, .session_not_configured, "no session bound");
        }
        if (self.worker_active.load(.acquire)) {
            return self.respondError(req.id, .session_busy, "a run is already in flight");
        }
        const params = req.params.prompt;
        const owned = self.gpa.dupe(u8, params.text) catch {
            self.respondError(req.id, .out_of_memory, "out of memory");
            self.fatalExit(40);
            return;
        };
        self.current_prompt_id = req.id;
        self.run_stream.store(params.stream, .release);
        self.worker_prompt = owned;
        self.worker_finished.store(false, .release);
        self.worker_active.store(true, .release);
        const th = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            self.worker_active.store(false, .release);
            self.gpa.free(owned);
            self.worker_prompt = &.{};
            self.respondError(req.id, .out_of_memory, "worker thread spawn failed");
            self.fatalExit(40);
            return;
        };
        self.worker = th;
    }

    fn handleCancel(self: *Server, id: i64) void {
        // Cancel while a gate is pending resolves it as DENY (never allow).
        if (self.gate_pending) self.denyPendingGate();
        if (self.worker_active.load(.acquire)) {
            if (self.agent) |a| a.requestCancel();
        }
        // Idle cancel is a no-op: the flag is NOT set when idle (rpc-v1 §5),
        // so the next prompt starts clean.
        self.respondOk(id, protocol.OkResult{ .ok = true });
    }

    fn handleControl(self: *Server, id: i64, kind: protocol.Method, text: []const u8) void {
        const session = self.session orelse {
            return self.respondError(id, .session_not_configured, "no session bound");
        };
        const result = switch (kind) {
            .steer => session.enqueueSteering(text),
            .follow_up => session.enqueueFollowUp(text),
            else => unreachable,
        };
        result catch |err| switch (err) {
            error.QueueFull => return self.respondError(id, .queue_full, "control queue full (cap 4)"),
            error.MessageTooLong => return self.respondError(id, .message_too_long, "control text exceeds the 4096 B cap"),
            error.EmptyMessage => return self.respondError(id, .invalid_arguments, "text must be non-empty"),
            error.InvalidUtf8 => return self.respondError(id, .invalid_arguments, "text is not valid UTF-8"),
        };
        self.respondOk(id, protocol.OkResult{ .ok = true });
    }

    fn handleSubscribe(self: *Server, id: i64, events: []const []const u8) void {
        // Strict: unknown groups were already rejected at parse time.
        self.sub_delta.store(false, .release);
        self.sub_thinking.store(false, .release);
        self.sub_tools.store(false, .release);
        self.sub_permission.store(false, .release);
        self.sub_usage.store(false, .release);
        self.sub_lifecycle.store(false, .release);
        self.sub_session.store(false, .release);
        for (events) |name| {
            switch (protocol.EventGroup.parse(name) orelse continue) {
                .delta => self.sub_delta.store(true, .release),
                .thinking => self.sub_thinking.store(true, .release),
                .tools => self.sub_tools.store(true, .release),
                .permission => self.sub_permission.store(true, .release),
                .usage => self.sub_usage.store(true, .release),
                .lifecycle => self.sub_lifecycle.store(true, .release),
                .session => self.sub_session.store(true, .release),
            }
        }
        self.respondOk(id, protocol.SubscribeResult{ .ok = true, .subscribed = events });
    }

    fn handlePermissionDecision(self: *Server, id: i64, params: protocol.PermissionDecisionParams) void {
        // remember: true → the Gate records the write path via the existing
        // remember store (it records on allow automatically); the wire flag is
        // accepted for forward compatibility.
        if (!self.resolveGate(params.request_id, params.allowed)) {
            return self.respondError(id, .permission_unknown, "no pending gate with that request_id");
        }
        self.respondOk(id, protocol.OkResult{ .ok = true });
    }

    fn handleResume(self: *Server, id: i64, path: ?[]const u8) void {
        if (self.worker_active.load(.acquire)) {
            return self.respondError(id, .session_busy, "a run is already in flight");
        }
        const target = path orelse blk: {
            const session = self.session orelse {
                return self.respondError(id, .session_not_configured, "no session path configured");
            };
            break :blk session.path orelse {
                return self.respondError(id, .session_not_configured, "no session path configured");
            };
        };
        coding.session_store.validateSessionPath(target) catch {
            return self.respondError(id, .session_invalid, "session path must be a relative workspace path");
        };

        const old = self.session orelse return self.respondError(id, .internal_error, "no session bound");
        const gpa = self.gpa;

        // rpc-v1 §7: save the current session if durable → rebind the target
        // with open_or_create semantics → release the old session. The order
        // differs by path:
        //   * same path — the old writer lease MUST be released before the new
        //     Session.start can take it (exclusive per-path lock), so the old
        //     session is destroyed first (save best-effort already done);
        //   * different path — TUI swap discipline: start the new session
        //     FIRST (fail-closed, old untouched), then release the old lease.
        const same_path = if (old.path) |op| std.mem.eql(u8, op, target) else false;
        old.save() catch {
            return self.respondError(id, .session_io_failed, "saving the current session failed");
        };
        if (same_path) {
            old.deinit();
            gpa.destroy(old);
            self.session = null;
            self.redactor = null;
        }

        // `resumed` = the target already existed before open_or_create.
        const existed = fileExists(self.io, target);

        const new = gpa.create(coding.Session) catch {
            if (!same_path) {} // old still bound and untouched
            self.respondError(id, .out_of_memory, "out of memory");
            self.fatalExit(40);
            return;
        };
        errdefer gpa.destroy(new);
        const started = coding.Session.start(gpa, self.io, .{
            .base_system = self.host.base_system,
            .path = target,
            .open_mode = .open_or_create, // resume if present, create on SessionNotFound
            .load_project_instructions = self.host.load_project_instructions,
            .redactor = self.agent.?.activeRedactor(),
            .skills_enabled = self.host.skills_enabled,
            .project_skills_trust = self.host.project_skills_trust,
            .user_skills_root = self.host.user_skills_root,
            .templates_enabled = self.host.templates_enabled,
            .project_templates_trust = self.host.project_templates_trust,
            .user_templates_root = self.host.user_templates_root,
        }) catch |err| {
            return self.respondError(id, sessionStartError(err), sessionStartMessage(err));
        };
        new.* = started;

        if (!same_path) {
            // Release the old lease + free the old Session exactly once.
            old.deinit();
            gpa.destroy(old);
        }
        self.session = new;
        self.redactor = new.activeRedactor();

        const turns = countUserTurns(new);
        self.emitSessionNotif(target, turns, existed);
        self.respondOk(id, protocol.ResumeResult{
            .ok = true,
            .resumed = existed,
            .path = target,
            .turns = turns,
        });
    }

    fn handleExit(self: *Server, id: i64) void {
        self.respondOk(id, protocol.OkResult{ .ok = true });
        self.beginShutdown();
    }

    // ── Reply worker (rpc-v1 §8.2) ─────────────────────────────────────────

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
        const gpa = self.gpa;
        const red = redact_mod.redactOptional(self.redactor, gpa, result.final_text) catch {
            self.fatalExit(40);
            return;
        };
        defer gpa.free(red);
        const capped = protocol.capText(gpa, red, protocol.final_text_max_bytes) catch {
            self.fatalExit(40);
            return;
        };
        defer gpa.free(capped);
        self.respond(self.current_prompt_id, protocol.PromptResult{
            .ok = hwResultOk(result.stop_reason),
            .stop_reason = result.stop_reason.name(),
            .turns = result.turns,
            .final_text = capped,
            .usage = .{
                .prompt_tokens = result.usage.prompt_tokens,
                .completion_tokens = result.usage.completion_tokens,
                .total_tokens = result.usage.total_tokens,
            },
        });
    }

    fn respondPromptFailure(self: *Server, err: coding.agent.ReplyError) void {
        const stop: coding.loop.StopReason = switch (err) {
            error.ProviderFailed => .provider_error,
            error.TraceFailed => .trace_error,
            error.OutOfMemory => .out_of_memory,
            error.InvalidToolset => .invalid_toolset,
            error.InvalidContext => .invalid_context,
            error.MaxTurnsExceeded => .max_turns,
            // Session store failures surface as session_error (rpc-v1 §9.2).
            else => .session_error,
        };
        const turns: u32 = if (self.agent) |a| a.ledger.turns else 0;
        self.respond(self.current_prompt_id, protocol.PromptResult{
            .ok = hwResultOk(stop),
            .stop_reason = stop.name(),
            .turns = turns,
            .final_text = "",
            .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
        });
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

    // ── Shutdown (rpc-v1 §8.3) ─────────────────────────────────────────────

    /// Exactly one graceful sequence for exit request / EOF / first SIGINT.
    /// Idempotent; safe to call from the main thread only (it joins the
    /// worker, which the worker itself must never join).
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
                std.log.err("rpc: session save failed: {s}", .{@errorName(err)});
            };
        }
        // Truthful terminal: join-bound expiry is an internal failure (70).
        self.exit_code = if (joined) 0 else 70;
    }

    fn fatalExit(self: *Server, code: u8) noreturn {
        self.emitFatal(.out_of_memory, "out of memory");
        std.process.exit(code);
    }

    // ── Frame writers (one writer mutex) ───────────────────────────────────

    fn respond(self: *Server, id: i64, result: anytype) void {
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.Response(@TypeOf(result)){
            .protocol_version = protocol.protocol_version,
            .id = .{ .int = id },
            .result = result,
        }, &body) catch {
            self.respondError(id, .out_of_memory, "out of memory");
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
    }

    fn respondOk(self: *Server, id: i64, result: anytype) void {
        self.respond(id, result);
    }

    fn respondError(self: *Server, id: ?i64, code: protocol.ErrorCode, message: []const u8) void {
        var body: Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        protocol.stringify(protocol.Response(protocol.OkResult){
            .protocol_version = protocol.protocol_version,
            .id = if (id) |v| .{ .int = v } else .null_val,
            .@"error" = protocol.ErrorObj.of(code, message),
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
        protocol.stringify(protocol.Notification(@TypeOf(params)){
            .protocol_version = protocol.protocol_version,
            .method = method,
            .params = params,
        }, &body) catch {
            self.fatalExit(40);
            return;
        };
        self.writeFrame(body.written());
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

    // ── Notifications ──────────────────────────────────────────────────────

    /// First frame: `ready` (rpc-v1 §6.1). Fatal on write failure.
    fn emitReady(self: *Server) void {
        const session = self.session orelse {
            self.emitFatal(.internal_error, "no session bound");
            std.process.exit(70);
        };
        const red_path = self.redactOwned(if (session.path) |p| p else "") catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(red_path);
        const turns = countUserTurns(session);
        self.emit("ready", protocol.ReadyParams{
            .protocol_version = protocol.protocol_version,
            .zag_version = coding.version,
            .permission = self.host.permission,
            .shell_policy = self.host.shell_policy,
            .session = .{
                .configured = session.path != null,
                .path = if (session.path != null) red_path else null,
                .turns = turns,
                .resumed = self.host.session_resumed,
            },
        });
    }

    /// Fatal `error` notification (startup failure / unrecoverable internal),
    /// followed by process exit with the mapped code (rpc-v1 §6.1).
    pub fn emitFatal(self: *Server, code: protocol.ErrorCode, message: []const u8) void {
        const red = self.redactOwned(message) catch return;
        defer self.gpa.free(red);
        self.emit("error", protocol.FatalErrorParams{ .@"error" = protocol.ErrorObj.of(code, red) });
    }

    fn emitPermissionRequest(
        self: *Server,
        request_id: u64,
        descriptor: coding.tool.ToolDescriptor,
        arguments_json: []const u8,
    ) void {
        const name = self.redactOwned(descriptor.definition.name) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(name);
        const raw_args = self.redactOwned(arguments_json) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(raw_args);
        const args = protocol.capText(self.gpa, raw_args, protocol.permission_args_max_bytes) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(args);
        self.emit("permission_request", protocol.PermissionRequestParams{
            .request_id = @intCast(request_id),
            .tool_name = name,
            .risk = descriptor.capabilities.risk.label(),
            .arguments_json = args,
        });
    }

    fn emitSessionNotif(self: *Server, path: []const u8, turns: u32, resumed: bool) void {
        if (!self.sub_session.load(.acquire)) return;
        const red = self.redactOwned(path) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(red);
        self.emit("session", protocol.SessionNotifParams{
            .path = red,
            .turns = turns,
            .resumed = resumed,
        });
    }

    /// Redact one string with the bound session redactor (gpa-owned result).
    fn redactOwned(self: *Server, text: []const u8) std.mem.Allocator.Error![]u8 {
        return redact_mod.redactOptional(self.redactor, self.gpa, text);
    }

    // ── Event projection (worker thread; program order) ────────────────────

    fn onLifecycle(ptr: ?*anyopaque, event: coding.LifecycleEvent) void {
        const self: *Server = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .run_start => |rs| {
                if (!self.sub_lifecycle.load(.acquire)) return;
                self.emit("run_start", protocol.RunStartParams{ .session_configured = rs.session_configured });
            },
            .assistant_message => |m| {
                if (!self.sub_lifecycle.load(.acquire)) return;
                const red = self.redactOwned(m.text) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                const reasoning = if (m.reasoning) |r| blk: {
                    const rr = self.redactOwned(r) catch {
                        self.fatalExit(40);
                        return;
                    };
                    break :blk rr;
                } else null;
                defer if (reasoning) |r| self.gpa.free(r);
                self.emit("assistant_message", protocol.AssistantMessageParams{
                    .turn = m.turn,
                    .text = red,
                    .has_tools = m.has_tools,
                    .reasoning = reasoning,
                });
            },
            .assistant_delta => |delta| {
                if (!self.sub_delta.load(.acquire)) return;
                if (!self.run_stream.load(.acquire)) return; // stream: false suppresses
                const red = self.redactOwned(delta) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                self.emit("assistant_delta", protocol.AssistantDeltaParams{ .text = red });
            },
            .thinking_delta => |delta| {
                if (!self.sub_thinking.load(.acquire)) return;
                if (!self.run_stream.load(.acquire)) return; // stream: false suppresses
                const red = self.redactOwned(delta) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                self.emit("thinking_delta", protocol.AssistantDeltaParams{ .text = red });
            },
            .assistant_delta_clear => {
                if (!self.sub_delta.load(.acquire)) return;
                if (!self.run_stream.load(.acquire)) return;
                self.emit("assistant_delta_clear", protocol.EmptyParams{});
            },
            .tool_start => |t| {
                if (!self.sub_tools.load(.acquire)) return;
                self.emitToolStart(t);
            },
            .tool_end => |t| {
                if (!self.sub_tools.load(.acquire)) return;
                self.emitToolEnd(t);
            },
            .control_applied => |c| {
                if (!self.sub_lifecycle.load(.acquire)) return;
                const red = self.redactOwned(c.text) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(red);
                self.emit("control_applied", protocol.ControlAppliedParams{
                    .kind = switch (c.kind) {
                        .steering => "steering",
                        .follow_up => "follow_up",
                    },
                    .next_turn = c.next_turn,
                    .text = red,
                });
            },
            // run_terminal is NOT a wire event: the prompt response is the
            // terminal result of its run (rpc-v1 §6.2).
            .run_terminal => {},
        }
    }

    fn onObserver(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *Server = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .usage => |u| {
                if (!self.sub_usage.load(.acquire)) return;
                self.emit("usage", protocol.UsageNotifParams{
                    .prompt_tokens = u.prompt_tokens,
                    .completion_tokens = u.completion_tokens,
                    .total_tokens = u.total_tokens,
                });
            },
            .permission => |p| {
                if (!self.sub_permission.load(.acquire)) return;
                const name = self.redactOwned(p.tool_name) catch {
                    self.fatalExit(40);
                    return;
                };
                defer self.gpa.free(name);
                self.emit("permission", protocol.PermissionNotifParams{
                    .tool_name = name,
                    .allowed = p.allowed,
                    .remembered = p.remembered,
                    .risk = p.risk orelse "?",
                });
            },
            // Tools are single-sourced on the lifecycle tool_start/tool_end
            // pair (turn context is strictly richer) — the observer pair is
            // not duplicated on the wire (rpc-v1 §6.2).
            .tool_call, .tool_result => {},
            // Deltas and complete text flow through the lifecycle observer.
            .assistant_text, .assistant_delta, .assistant_delta_clear => {},
        }
    }

    fn emitToolStart(self: *Server, t: anytype) void {
        const name = self.redactOwned(t.name) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(name);
        const args = self.redactOwned(t.arguments) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(args);
        const id = self.redactOwned(t.id) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(id);
        self.emit("tool_start", protocol.ToolStartParams{
            .turn = t.turn,
            .call_index = t.call_index,
            .id = id,
            .name = name,
            .arguments = args,
        });
    }

    fn emitToolEnd(self: *Server, t: anytype) void {
        const name = self.redactOwned(t.name) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(name);
        const body = self.redactOwned(t.body) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(body);
        const id = self.redactOwned(t.id) catch {
            self.fatalExit(40);
            return;
        };
        defer self.gpa.free(id);
        self.emit("tool_end", protocol.ToolEndParams{
            .turn = t.turn,
            .call_index = t.call_index,
            .id = id,
            .name = name,
            .body = body,
        });
    }
};

// ── helpers ─────────────────────────────────────────────────────────────────

fn hwResultOk(stop_reason: coding.loop.StopReason) bool {
    return switch (stop_reason) {
        .completed, .max_turns, .cancelled => true,
        .timeout, .unsupported_control, .provider_error, .session_error,
        .trace_error, .out_of_memory, .invalid_toolset, .invalid_context => false,
    };
}

/// Session turn count = number of user rows in the transcript.
fn countUserTurns(session: *const coding.Session) u32 {
    var n: u32 = 0;
    for (session.transcript.items()) |m| {
        if (m.role == .user) n += 1;
    }
    return n;
}

fn fileExists(io: Io, path: []const u8) bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    _ = Io.Dir.cwd().realPathFile(io, path, &buf) catch return false;
    return true;
}

fn drainWake(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
    }
}

/// Map a `Session.start` failure to a wire error code (rpc-v1 §8.5).
pub fn sessionStartError(err: anyerror) protocol.ErrorCode {
    return switch (err) {
        error.SessionNotFound => .session_not_found,
        error.SessionAlreadyExists => .session_already_exists,
        error.InvalidSession, error.InvalidPath => .session_invalid,
        error.UnsupportedSchema => .session_unsupported_schema,
        error.SessionBusy => .session_busy,
        error.IoFailed => .session_io_failed,
        error.OutOfMemory => .out_of_memory,
        else => .internal_error,
    };
}

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

/// Startup process exit code for a `Session.start` failure (rpc-v1 §8.5).
pub fn sessionStartExitCode(err: anyerror) u8 {
    return switch (sessionStartError(err)) {
        .session_not_found => 50,
        .session_already_exists => 51,
        .session_invalid => 52,
        .session_unsupported_schema => 53,
        .session_busy => 54,
        .session_io_failed => 55,
        .out_of_memory => 40,
        .internal_error => 70,
        else => 70,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

test "hwResultOk matches headless ok semantics" {
    try std.testing.expect(hwResultOk(.completed));
    try std.testing.expect(hwResultOk(.max_turns));
    try std.testing.expect(hwResultOk(.cancelled));
    try std.testing.expect(!hwResultOk(.provider_error));
    try std.testing.expect(!hwResultOk(.session_error));
    try std.testing.expect(!hwResultOk(.trace_error));
    try std.testing.expect(!hwResultOk(.out_of_memory));
}

test "sessionStartError maps store errors to frozen codes" {
    try std.testing.expectEqual(protocol.ErrorCode.session_not_found, sessionStartError(error.SessionNotFound));
    try std.testing.expectEqual(protocol.ErrorCode.session_already_exists, sessionStartError(error.SessionAlreadyExists));
    try std.testing.expectEqual(protocol.ErrorCode.session_invalid, sessionStartError(error.InvalidSession));
    try std.testing.expectEqual(protocol.ErrorCode.session_unsupported_schema, sessionStartError(error.UnsupportedSchema));
    try std.testing.expectEqual(protocol.ErrorCode.session_busy, sessionStartError(error.SessionBusy));
    try std.testing.expectEqual(protocol.ErrorCode.session_io_failed, sessionStartError(error.IoFailed));
    try std.testing.expectEqual(protocol.ErrorCode.out_of_memory, sessionStartError(error.OutOfMemory));
    try std.testing.expectEqual(protocol.ErrorCode.internal_error, sessionStartError(error.TraceFailed));
}

test "countUserTurns counts user rows only" {
    const gpa = std.testing.allocator;
    var session = try coding.Session.start(gpa, std.testing.io, .{
        .base_system = "sys",
        .path = null,
        .open_mode = .create_new,
        .load_project_instructions = false,
        .redactor = null,
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(u32, 0), countUserTurns(&session));
    try session.transcript.appendUser("one");
    try session.transcript.appendSystem("sys2");
    try session.transcript.appendUser("two");
    try std.testing.expectEqual(@as(u32, 2), countUserTurns(&session));
}
