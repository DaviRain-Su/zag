//! Live policy layer (docs/modules/live-policy-layer.md, zag-live-002).
//!
//! System-prompt delegation to a supervised live image, default-off,
//! degrade-always: any image failure falls back to the static base prompt
//! with a bounded notice. Host-driven redefinition only (`zag live`).
//!
//! Comptime-gated: with `-Dlive` off the zag-live import is absent and every
//! entry point is a safe no-op / clean error.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

pub const enabled: bool = build_options.live_enabled;

const zag_live = if (enabled) @import("zag-live") else struct {};

pub const Error = error{ LiveUnavailable, LiveLocked };

/// Genesis policy (identity): delivered to the image as Config.base_source;
/// the frozen package's image script is not edited (contract §5).
pub const genesis_source: []const u8 =
    ";; zag live policy genesis (identity)\n" ++
    "(define (policy.system-prompt base project) base)\n";

/// Contract §5: a successful policy reply above this falls back.
pub const max_prompt_bytes: usize = 64 * 1024;

const lock_name = "lock";

/// Agent-owned live handle. Always safe to hold when --live is on; `inner`
/// is null whenever degraded (start failure, lock contention, ...).
pub const Handle = struct {
    inner: if (enabled) ?Inner else void = if (enabled) null else {},
    /// Degradation notices emitted (test observability; S6 transition rule).
    notices: u32 = 0,

    const Inner = if (enabled)
        struct {
            live: zag_live.Live,
            dir: Io.Dir,
            /// view-time health latch (degradation notices on transition)
            degraded: bool,
        }
    else
        struct {};

    pub fn isHealthy(self: *const Handle) bool {
        if (!enabled) return false;
        const inner = self.inner orelse return false;
        return !inner.degraded;
    }

    pub fn deinit(self: *Handle, io: Io) void {
        if (!enabled) return;
        if (self.inner) |*inner| {
            inner.live.deinit();
            // lock lifecycle: deleted in clean deinit (contract §6)
            inner.dir.deleteFile(io, lock_name) catch {};
            inner.dir.close(io);
            self.inner = null;
        }
    }
};

fn notice(io: Io, h: *Handle, comptime fmt: []const u8, args: anytype) void {
    _ = io;
    h.notices += 1;
    std.log.warn(fmt, args);
}

/// Agent-side bring-up (contract §4): lock + Live start; ANY failure
/// degrades to inner=null with a bounded notice — never an error.
pub fn agentInit(gpa: std.mem.Allocator, io: Io, live_dir: ?Io.Dir) Handle {
    if (!enabled) return .{};
    const dir = live_dir orelse return .{};
    const live = zag_live.Live.init(gpa, io, .{
        .state_dir = dir,
        .base_source = genesis_source,
    }) catch {
        var h: Handle = .{};
        notice(io, &h, "live: init failed; running with static policy", .{});
        return h;
    };
    return agentInitWithLive(gpa, io, dir, live);
}

/// Test seam / injectable bring-up: caller-built (unstarted) Live. Lock +
/// start + degrade logic lives here (startup failure matrix, class 5).
pub fn agentInitWithLive(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, live_in: zag_live.Live) Handle {
    if (!enabled) return .{};
    var h: Handle = .{};
    var live = live_in;

    // Single-writer lock (.zag/live/lock, O_EXCL). A second agent degrades
    // per §4 posture (runs without live, one notice).
    const lock = dir.createFile(io, lock_name, .{ .exclusive = true }) catch |e| {
        if (e == error.PathAlreadyExists) {
            notice(io, &h, "live: state dir locked by another process; running with static policy", .{});
        } else {
            notice(io, &h, "live: lock create failed; running with static policy", .{});
        }
        return h;
    };
    lock.close(io);

    live.start() catch {
        const needs_recover = live.needsRecovery();
        live.deinit();
        if (needs_recover) {
            notice(io, &h, "live: image start failed; state needs recovery (zag live recover)", .{});
        } else {
            notice(io, &h, "live: image start failed; running with static policy", .{});
        }
        return h;
    };

    // S5: one-time startup notice when the effective policy is not genesis.
    const cur = zag_live.generations.readCurrent(gpa, io, dir) catch 0;
    const pend = zag_live.journal.pendingRedefs(gpa, io, dir) catch null;
    const pend_len = if (pend) |p| p.len else 0;
    if (pend) |p| zag_live.journal.freeRedefs(gpa, p);
    if (cur != 0 or pend_len > 0) {
        notice(io, &h, "live: non-genesis policy active (generation {d}, {d} pending)", .{ cur, pend_len });
    }

    h.inner = .{ .live = live, .dir = dir, .degraded = false };
    return h;
}

/// View-time delegation (contract §5): per view computation, no caching.
/// Returns a scratch-allocated prompt on success; null on any failure
/// (fallback to base_system by the caller). Reply must be a string
/// (host-wrapped type check) of at most max_prompt_bytes.
pub fn systemPrompt(
    h: *Handle,
    io: Io,
    scratch: std.mem.Allocator,
    base: []const u8,
    project: ?[]const u8,
) ?[]const u8 {
    if (!enabled) return null;
    const inner = &(h.inner orelse return null);
    if (inner.degraded) return null;

    const gpa = inner.live.gpa;
    const esc_base = zag_live.frame.escape(gpa, base) catch return null;
    defer gpa.free(esc_base);
    var esc_project: ?[]u8 = null;
    defer if (esc_project) |e| gpa.free(e);
    if (project) |pbody| {
        if (pbody.len > 0) esc_project = zag_live.frame.escape(gpa, pbody) catch return null;
    }
    const project_lit = if (esc_project != null)
        std.fmt.allocPrint(gpa, "\"{s}\"", .{esc_project.?}) catch return null
    else
        "#f";
    defer if (esc_project != null) gpa.free(project_lit);

    // Host-wrapped type check (S2/S4): a non-string policy result raises
    // image-side and arrives as a protocol error -> fallback.
    const src = std.fmt.allocPrint(gpa,
        "(let ((r (policy.system-prompt \"{s}\" {s}))) (if (string? r) r (error 'policy \"not-a-string\")))",
        .{ esc_base, project_lit }) catch return null;
    defer gpa.free(src);

    const reply = inner.live.eval(src) catch {
        inner.degraded = true;
        notice(io, h, "live: delegation failed; system prompt falls back to static default", .{});
        return null;
    };
    defer gpa.free(reply);
    if (reply.len > max_prompt_bytes) {
        inner.degraded = true;
        notice(io, h, "live: policy reply exceeds 64 KiB; falling back to static default", .{});
        return null;
    }
    return scratch.dupe(u8, reply) catch null;
}

// ---------- host-driven subcommand ops (zag live …) ----------

/// Open a Live on the state dir with the single-writer lock (fail closed
/// with LiveLocked while a holder has it). Caller deinits.
const CmdLive = if (enabled)
    struct { live: zag_live.Live, dir: Io.Dir }
else
    struct {};

fn cmdOpen(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) Error!CmdLive {
    if (!enabled) return error.LiveUnavailable;
    const lock = dir.createFile(io, lock_name, .{ .exclusive = true }) catch |e| {
        if (e == error.PathAlreadyExists) return error.LiveLocked;
        return error.LiveUnavailable;
    };
    lock.close(io);
    errdefer dir.deleteFile(io, lock_name) catch {};

    var live = zag_live.Live.init(gpa, io, .{
        .state_dir = dir,
        .base_source = genesis_source,
    }) catch return error.LiveUnavailable;
    errdefer live.deinit();
    live.start() catch return error.LiveUnavailable;
    return .{ .live = live, .dir = dir };
}

fn cmdClose(io: Io, cl: *CmdLive) void {
    if (!enabled) return;
    cl.live.deinit();
    cl.dir.deleteFile(io, lock_name) catch {};
}

/// `zag live status`: current generation, journal entries, pending set.
pub fn cmdStatus(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, out: *Io.Writer) Error!void {
    if (!enabled) return error.LiveUnavailable;
    const cur = zag_live.generations.readCurrent(gpa, io, dir) catch return error.LiveUnavailable;
    const entries = zag_live.journal.countEntries(gpa, io, dir) catch |e| switch (e) {
        error.JournalCorrupt => {
            try out.print("journal: CORRUPT (needs zag live recover)\n", .{});
            return;
        },
        else => return error.LiveUnavailable,
    };
    const pend = zag_live.journal.pendingRedefs(gpa, io, dir) catch null;
    defer if (pend) |p| zag_live.journal.freeRedefs(gpa, p);
    const pend_len = if (pend) |p| p.len else 0;
    try out.print("generation: {d}\njournal entries: {d}\npending redefines: {d}\n", .{ cur, entries, pend_len });
    if (pend) |p| for (p) |r| try out.print("  pending: {s}\n", .{r.name});
}

/// `zag live eval "<source>"` — print the reply datum.
pub fn cmdEval(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, source: []const u8, out: *Io.Writer) Error!void {
    var cl = try cmdOpen(gpa, io, dir);
    defer cmdClose(io, &cl);
    const reply = cl.live.eval(source) catch return error.LiveUnavailable;
    defer gpa.free(reply);
    try out.print("{s}\n", .{reply});
}

/// `zag live redefine <name> <file>` — journal + apply a new definition.
pub fn cmdRedefine(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, file_path: []const u8, out: *Io.Writer) Error!void {
    const source = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(4 * 1024 * 1024)) catch
        return error.LiveUnavailable;
    defer gpa.free(source);
    var cl = try cmdOpen(gpa, io, dir);
    defer cmdClose(io, &cl);
    const esc = zag_live.frame.escape(gpa, source) catch return error.LiveUnavailable;
    defer gpa.free(esc);
    const call = std.fmt.allocPrint(gpa, "(kernel.redefine '{s} \"{s}\")", .{ name, esc }) catch
        return error.LiveUnavailable;
    defer gpa.free(call);
    const reply = cl.live.eval(call) catch return error.LiveUnavailable;
    defer gpa.free(reply);
    try out.print("redefined {s} (pending; commit with: zag live commit)\n", .{name});
}

/// `zag live commit` — clean-process replay probe + generation flip.
pub fn cmdCommit(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, out: *Io.Writer) Error!void {
    var cl = try cmdOpen(gpa, io, dir);
    defer cmdClose(io, &cl);
    const reply = cl.live.eval("(kernel.commit \"zag live commit\")") catch {
        if (cl.live.lastImageError()) |msg| {
            try out.print("commit failed: {s}\n", .{firstLine(msg)});
            return error.LiveUnavailable;
        }
        return error.LiveUnavailable;
    };
    defer gpa.free(reply);
    try out.print("committed; generation flipped\n", .{});
}

/// `zag live discard <name>` — restore a binding to its committed definition.
pub fn cmdDiscard(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) Error!void {
    var cl = try cmdOpen(gpa, io, dir);
    defer cmdClose(io, &cl);
    const call = std.fmt.allocPrint(gpa, "(kernel.discard '{s})", .{name}) catch return error.LiveUnavailable;
    defer gpa.free(call);
    const reply = cl.live.eval(call) catch return error.LiveUnavailable;
    defer gpa.free(reply);
    try out.print("discarded {s}\n", .{name});
}

/// `zag live recover` — clear a stale lock (holder death is
/// operator-judged), then quarantine-all + restart from the committed
/// generation (package M2 path).
pub fn cmdRecover(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, out: *Io.Writer) Error!void {
    if (!enabled) return error.LiveUnavailable;
    dir.deleteFile(io, lock_name) catch {};
    var live = zag_live.Live.init(gpa, io, .{
        .state_dir = dir,
        .base_source = genesis_source,
    }) catch return error.LiveUnavailable;
    defer live.deinit();
    const summary = live.recover() catch return error.LiveUnavailable;
    try out.print("recovered: {d} pending entr{ies} quarantined\n", .{ summary.quarantined, if (summary.quarantined == 1) @as([]const u8, "y") else "ies" });
}

fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..end];
}
