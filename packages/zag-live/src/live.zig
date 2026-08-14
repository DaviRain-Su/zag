//! Live — the supervised live Scheme image (Gambit binding, D-015).
//! See docs/modules/zag-live.md.
//!
//! Trust-critical pieces live here in Zig: frame protocol, journal (fsync
//! before apply), generations (staged, probe-gated, atomic flip), kernel
//! primitives, watchdog, env-scrubbed spawn, host ports.
//!
//! Threading model: one outstanding host request per direction (all host
//! requests and the watchdog serialize on `mutex`); the watchdog thread owns
//! idle-image liveness probes; whichever path first detects death performs
//! the restart while holding the mutex. An in-flight host request that
//! detects death fails once with error.ImageRestarted after the restart —
//! zag-live never retries host requests transparently.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const types = @import("zag-types");

const frame = @import("frame.zig");
const journal = @import("journal.zig");
const gens = @import("generations.zig");
const ports = @import("ports.zig");

pub const ProviderPort = ports.ProviderPort;
pub const ToolPort = ports.ToolPort;

pub const Error = error{
    /// Allocator escape hatch; not a domain error (the §8 vocabulary is the
    /// domain subset below).
    OutOfMemory,
    ImageUnavailable,
    BootProbeFailed,
    ImageDied,
    ImageRestarted,
    FrameTooLarge,
    ProtocolError,
    JournalCorrupt,
    CommitRejected,
    CommitUnavailable,
    NotCommitted,
    NothingToCommit,
    PortAbsent,
    DeadlineExceeded,
};

pub const EnvPair = struct { name: []const u8, value: []const u8 };

pub const WatchdogConfig = struct {
    probe_interval_ms: u32 = 1000,
    deadline_ms: u32 = 2000,
};

/// The image source ships embedded in the package; the host picks the
/// spawn form (D-015). gxc is NOT used: its module namespacing hides the
/// image's own kernel primitives from interaction-eval.
pub const ImageSource = union(enum) {
    /// Host-supplied path to a gsc -exe binary built from the embedded
    /// source (see buildImage). Verified by self-id handshake at start().
    compiled: []const u8,
    /// Embedded source via gxi (PATH or explicit). Version floor:
    /// Gerbil >= 0.18, checked at start().
    interpreted: Interpreted,
};

pub const Interpreted = struct {
    gxi_path: ?[]const u8 = null,
};

pub const Config = struct {
    /// Journal + generations root. The package never writes outside it.
    state_dir: Io.Dir,
    image: ImageSource = .{ .interpreted = .{} },
    provider_port: ?ProviderPort = null,
    tool_port: ?ToolPort = null,
    /// Host-controlled additions to the fixed allowlist env ONLY.
    extra_env: []const EnvPair = &.{},
    watchdog: WatchdogConfig = .{},
    /// Genesis base definitions for generation 0; null = embedded genesis.
    /// (live-policy-layer rides this field.)
    base_source: ?[]const u8 = null,
};

/// Written once into generation 0 when the state dir is first initialized.
pub const embedded_genesis: []const u8 = "(define (greeting) \"hello, live image\")\n";
/// Protocol/source identity answered by the self-id handshake.
pub const image_identity: []const u8 = "(ok (zag-live 1 gambit))";

const image_script = @embedFile("runtime.ss");
const image_path_in_state = "image.ss";
const max_file: usize = 64 * 1024 * 1024;

pub const Live = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config,
    image_abs: []u8,

    mutex: Io.Mutex = .init,
    child: ?std.process.Child = null,
    started: bool = false,
    watchdog_stop: types.CancelFlag = .{},
    watchdog_thread: ?std.Thread = null,

    /// Test seam (acceptance class 8, G4): when set, clean-process probe
    /// spawns fail with this error (any spawn-stage failure class).
    fail_clean_spawn: ?anyerror = null,

    /// M2 hint latch: set when a start/restart dies during replay with a
    /// non-empty pending set. Read via needsRecovery().
    needs_recovery: bool = false,

    /// Test seam (classes 13/14): override the image source written for the
    /// interpreted spawn form.
    test_image_source: ?[]const u8 = null,
    /// Test seam (class 14): capture image stderr on a pipe instead of
    /// inheriting it, for frame-purity/diagnostics assertions.
    capture_image_stderr: bool = false,

    /// Last image-side error text (err reply), for diagnostics. Freed on
    /// the next error or deinit. Read with lastImageError().
    last_image_error: ?[]u8 = null,

    pub fn lastImageError(self: *const Live) ?[]const u8 {
        return self.last_image_error;
    }

    /// Cheap validation only (paths exist, spawn form well-formed); the
    /// boot probe runs at start().
    pub fn init(gpa: Allocator, io: Io, cfg: Config) Error!Live {
        if (cfg.image == .compiled) {
            // Host-supplied path may be absolute or cwd-relative; validate
            // against cwd (openat semantics ignore dirfd for absolute paths).
            std.Io.Dir.cwd().access(io, cfg.image.compiled, .{}) catch
                return error.ImageUnavailable;
        }
        var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = cfg.state_dir.realPath(io, &abs_buf) catch return error.ImageUnavailable;
        const image_abs = std.fmt.allocPrint(gpa, "{s}/" ++ image_path_in_state, .{abs_buf[0..n]}) catch
            return error.OutOfMemory;
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .image_abs = image_abs };
    }

    pub fn deinit(self: *Live) void {
        self.stop() catch {};
        if (self.last_image_error) |old| self.gpa.free(old);
        self.gpa.free(self.image_abs);
    }

    // ---------- lifecycle ----------

    /// Spawn + boot probe (version floor) + replay current generation.
    pub fn start(self: *Live) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.startLocked() catch |e| return mapInternal(e);
    }

    fn startLocked(self: *Live) !void {
        if (self.started) return;
        try self.ensureStateLocked();
        try gens.cleanupStaleStaging(self.gpa, self.io, self.cfg.state_dir);
        switch (self.cfg.image) {
            .interpreted => {
                try self.writeImageLocked();
                try self.checkInterpretedFloor(); // Gerbil >= 0.18
            },
            .compiled => {},
        }
        self.spawnLocked() catch return error.ImageUnavailable;
        self.bootProbeLocked() catch |e| {
            // Propagate ImageUnavailable from the self-id handshake
            // (stale/foreign binary); anything else is a boot failure.
            self.killChildLocked();
            return e;
        };
        self.replayLocked() catch |e| switch (e) {
            error.JournalCorrupt => {
                self.killChildLocked();
                return error.JournalCorrupt;
            },
            else => {
                self.killChildLocked();
                // M2 hint: replay died with pending entries present — the
                // caller should look at recover(). Never auto-quarantined.
                self.needs_recovery = self.pendingCountLocked() > 0;
                return error.BootProbeFailed;
            },
        };
        self.needs_recovery = false;
        self.started = true;
        self.watchdog_stop.clear();
        self.watchdog_thread = std.Thread.spawn(.{}, watchdogMain, .{self}) catch null;
    }

    fn pendingCountLocked(self: *Live) usize {
        const pend = journal.pendingRedefs(self.gpa, self.io, self.cfg.state_dir) catch return 0;
        defer journal.freeRedefs(self.gpa, pend);
        return pend.len;
    }

    // ---------- recovery affordance (M2) ----------

    pub const RecoverSummary = struct { quarantined: usize };

    /// True when the last start/restart died during replay with a non-empty
    /// pending set — the replay-fatal-entry brick. The caller decides;
    /// zag-live never auto-quarantines.
    pub fn needsRecovery(self: *Live) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.needs_recovery;
    }

    /// Quarantine ALL pending journal entries (a `(suspect …)` marker per
    /// entry), then restart the image from the committed generation.
    /// Exists for the M2 failure mode: a pending entry that kills replay
    /// (e.g. `(exit)`) otherwise bricks the state dir — start() fails with
    /// BootProbeFailed forever, the watchdog loops, and commit cannot run
    /// without a live image.
    pub fn recover(self: *Live) Error!RecoverSummary {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dir = self.cfg.state_dir;
        const pend = journal.pendingRedefs(self.gpa, self.io, dir) catch |e| return mapInternal(e);
        defer journal.freeRedefs(self.gpa, pend);
        self.quarantine(pend);
        self.killChildLocked();
        self.spawnLocked() catch return error.ImageUnavailable;
        self.bootProbeLocked() catch |e| {
            // Propagate ImageUnavailable from the self-id handshake
            // (stale/foreign binary); anything else is a boot failure.
            self.killChildLocked();
            return e;
        };
        self.replayLocked() catch {
            self.killChildLocked();
            return error.BootProbeFailed;
        };
        self.needs_recovery = false;
        if (!self.started) {
            self.started = true;
            self.watchdog_stop.clear();
            self.watchdog_thread = std.Thread.spawn(.{}, watchdogMain, .{self}) catch null;
        }
        return .{ .quarantined = pend.len };
    }

    /// Stop discipline (R1): send (kernel.quit), close stdin, wait up to
    /// deadline_ms, then SIGKILL. Gambit's EOF unreliability must never
    /// hang deinit(). Idempotent.
    pub fn stop(self: *Live) !void {
        self.watchdog_stop.request();
        if (self.watchdog_thread) |t| {
            t.join();
            self.watchdog_thread = null;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.started = false;
        if (self.child) |*c| {
            if (c.stdin) |f| {
                frame.writeFrame(self.io, f, "(kernel.quit)") catch {};
                f.close(self.io);
                c.stdin = null;
            }
            if (c.id) |pid| {
                var status: c_int = 0;
                var waited_ms: u32 = 0;
                var reaped = false;
                while (waited_ms < self.cfg.watchdog.deadline_ms) : (waited_ms += 25) {
                    const r = std.c.waitpid(pid, &status, 1); // 1 = WNOHANG
                    if (r != 0) {
                        reaped = true;
                        break;
                    }
                    Io.sleep(self.io, Io.Duration.fromMilliseconds(25), .awake) catch {};
                }
                if (!reaped) {
                    std.posix.kill(pid, .KILL) catch {};
                    _ = std.c.waitpid(pid, &status, 0);
                }
                c.id = null;
            }
            self.child = null;
        }
    }

    /// Build the embedded image source into state_dir/image-bin via gsc
    /// (discovered by asking gxi, never PATH — PATH's gsc may be
    /// Ghostscript). gxc is deliberately not used (module namespacing
    /// breaks interaction-eval; D-015).
    pub fn buildImage(self: *Live) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.buildImageLocked() catch |e| return mapInternal(e);
    }

    fn buildImageLocked(self: *Live) !void {
        const dir = self.cfg.state_dir;
        const gxi_path = switch (self.cfg.image) {
            .interpreted => |interp| interp.gxi_path orelse "gxi",
            .compiled => "gxi",
        };
        const gsc = try self.findGambitGsc(gxi_path);
        defer self.gpa.free(gsc);
        const src_tmp = "image-build.tmp.ss";
        try gens.writeSmall(self.io, dir, src_tmp, image_script);
        defer dir.deleteFile(self.io, src_tmp) catch {};
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ gsc, "-exe", "-o", "image-bin", src_tmp },
            .cwd = .{ .dir = dir },
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch return error.ImageUnavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.ImageUnavailable,
            else => return error.ImageUnavailable,
        }
    }

    /// Discover Gambit's gsc by asking gxi: ~~ is the gerbil home, where
    /// the real gsc lives. Never PATH.
    fn findGambitGsc(self: *Live, gxi_path: []const u8) ![]u8 {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ gxi_path, "-e", "(display (path-expand \"~~bin/gsc\"))" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return error.ImageUnavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.ImageUnavailable,
            else => return error.ImageUnavailable,
        }
        const gsc = std.mem.trim(u8, result.stdout, " \n");
        std.Io.Dir.cwd().access(self.io, gsc, .{}) catch return error.ImageUnavailable;
        return try self.gpa.dupe(u8, gsc);
    }

    /// Host-driven eval: bounded result (frame cap) + host deadline
    /// (watchdog.deadline_ms). Image-side errors surface as
    /// error.ProtocolError. In-flight failure due to image death/hang
    /// restarts the image and fails once with error.ImageRestarted — no
    /// transparent retry.
    pub fn eval(self: *Live, source: []const u8) Error![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.child == null) return error.ImageDied;
        return self.requestEvalLocked(self.child.?, source) catch |e| return self.boundaryDisposition(e);
    }

    /// Host liveness/echo request (test + watchdog use).
    pub fn echo(self: *Live, payload: []const u8) Error![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.child == null) return error.ImageDied;
        const esc = frame.escape(self.gpa, payload) catch return error.ProtocolError;
        defer self.gpa.free(esc);
        const fr = std.fmt.allocPrint(self.gpa, "(kernel.echo \"{s}\")", .{esc}) catch return error.ProtocolError;
        defer self.gpa.free(fr);
        return self.requestLocked(self.child.?, fr) catch |e| return self.boundaryDisposition(e);
    }

    /// In-flight failure disposition (A4): image death/hang restarts the
    /// image and fails the request ONCE with ImageRestarted — no
    /// transparent retry. Oversize from the image: same restart, surfaced
    /// as FrameTooLarge. Caller must hold the mutex.
    fn boundaryDisposition(self: *Live, e: anyerror) Error {
        const mapped = mapInternal(e);
        switch (mapped) {
            error.ImageDied, error.DeadlineExceeded => {
                self.restartLocked() catch {};
                return error.ImageRestarted;
            },
            error.FrameTooLarge => {
                self.restartLocked() catch {};
                return error.FrameTooLarge;
            },
            else => return mapped,
        }
    }

    /// Test seam: bypass the host-side cap to exercise the image's own
    /// inbound oversize rejection (acceptance class 5).
    pub fn sendRawFrameUnchecked(self: *Live, payload: []const u8) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.started or self.child == null) return error.ImageDied;
        frame.writeFrameUnchecked(self.io, self.child.?.stdin.?, payload) catch
            return error.ProtocolError;
    }

    /// Map internal errors onto the closed domain vocabulary (§8).
    /// OutOfMemory flows through as the standard allocator escape hatch.
    fn mapInternal(e: anyerror) Error {
        return switch (e) {
            error.ImageUnavailable => error.ImageUnavailable,
            error.BootProbeFailed => error.BootProbeFailed,
            error.ImageDied => error.ImageDied,
            error.ImageRestarted => error.ImageRestarted,
            error.FrameTooLarge => error.FrameTooLarge,
            error.ProtocolError => error.ProtocolError,
            error.JournalCorrupt => error.JournalCorrupt,
            error.CommitRejected => error.CommitRejected,
            error.CommitUnavailable => error.CommitUnavailable,
            error.NotCommitted => error.NotCommitted,
            error.NothingToCommit => error.NothingToCommit,
            error.PortAbsent => error.PortAbsent,
            error.DeadlineExceeded => error.DeadlineExceeded,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProtocolError,
        };
    }

    /// Test seam: SIGKILL the image now (acceptance classes 6/9).
    pub fn forceKillImage(self: *Live) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.killChildLocked();
    }

    // ---------- environment rule (B1/A2) ----------

    fn buildEnvLocked(self: *Live) !std.process.Environ.Map {
        var env = std.process.Environ.Map.init(self.gpa);
        errdefer env.deinit();
        for ([_][*:0]const u8{ "PATH", "HOME", "TERM" }) |k| {
            if (std.c.getenv(k)) |v| {
                try env.put(std.mem.span(k), std.mem.span(v));
            }
        }
        for (self.cfg.extra_env) |pair| try env.put(pair.name, pair.value);
        return env;
    }

    /// Spawn argv for the configured form, built into a caller-frame buffer
    /// (spawn copies it synchronously). The clean commit probe uses the same
    /// spawn form as the live image (contract §5).
    fn spawnArgvLocked(self: *Live, buf: *[2][]const u8) []const []const u8 {
        return switch (self.cfg.image) {
            .compiled => |path| blk: {
                buf[0] = path;
                break :blk buf[0..1];
            },
            .interpreted => |interp| blk: {
                buf[0] = interp.gxi_path orelse "gxi";
                buf[1] = self.image_abs;
                break :blk buf[0..2];
            },
        };
    }

    fn spawnOpts(self: *Live, argv: []const []const u8, env: *const std.process.Environ.Map) std.process.SpawnOptions {
        return .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (self.capture_image_stderr) .pipe else .inherit,
            .environ_map = env,
        };
    }

    fn spawnLocked(self: *Live) !void {
        var env = try self.buildEnvLocked();
        defer env.deinit();
        var argv_buf: [2][]const u8 = undefined;
        self.child = try std.process.spawn(self.io, self.spawnOpts(self.spawnArgvLocked(&argv_buf), &env));
    }

    fn spawnCleanLocked(self: *Live) !std.process.Child {
        if (self.fail_clean_spawn) |e| return e; // test seam
        var env = try self.buildEnvLocked();
        defer env.deinit();
        var argv_buf: [2][]const u8 = undefined;
        return std.process.spawn(self.io, self.spawnOpts(self.spawnArgvLocked(&argv_buf), &env));
    }

    fn killChildLocked(self: *Live) void {
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
    }

    /// Boot probe = self-identification handshake (R3): the image answers
    /// with its protocol/source version; a stale or foreign binary answers
    /// wrong (or not at all) -> ImageUnavailable.
    fn bootProbeLocked(self: *Live) !void {
        const child = &self.child.?;
        frame.writeFrame(self.io, child.stdin.?, "(kernel.self-id)") catch
            return error.ImageUnavailable;
        const raw = frame.readFrameDeadline(self.gpa, self.io, child.stdout.?, self.cfg.watchdog.deadline_ms) catch
            return error.ImageUnavailable;
        const reply = raw orelse return error.ImageUnavailable;
        defer self.gpa.free(reply);
        if (!std.mem.eql(u8, reply, image_identity)) return error.ImageUnavailable;
    }

    /// Interpreted form only: `gxi --version` must report Gerbil >= 0.18.
    fn checkInterpretedFloor(self: *Live) !void {
        const interp = self.cfg.image.interpreted;
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ interp.gxi_path orelse "gxi", "--version" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return error.ImageUnavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.ImageUnavailable,
            else => return error.ImageUnavailable,
        }
        try parseGerbilVersionFloor(result.stdout);
    }

    /// "Gerbil v0.18.1-..." — floor: Gerbil >= 0.18.
    fn parseGerbilVersionFloor(text: []const u8) Error!void {
        const marker = "Gerbil v";
        const idx = std.mem.indexOf(u8, text, marker) orelse
            return error.BootProbeFailed;
        const rest = text[idx + marker.len ..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return error.BootProbeFailed;
        const major = std.fmt.parseInt(u32, rest[0..dot], 10) catch return error.BootProbeFailed;
        var minor_end = dot + 1;
        while (minor_end < rest.len and std.ascii.isDigit(rest[minor_end])) minor_end += 1;
        if (minor_end == dot + 1) return error.BootProbeFailed;
        const minor = std.fmt.parseInt(u32, rest[dot + 1 .. minor_end], 10) catch return error.BootProbeFailed;
        if (major == 0 and minor < 18) return error.BootProbeFailed;
    }

    // ---------- state init + replay ----------

    fn ensureStateLocked(self: *Live) !void {
        const dir = self.cfg.state_dir;
        try dir.createDirPath(self.io, gens.gens_path ++ "/0");
        const base = try gens.genPath(self.gpa, 0, "base.ss");
        defer self.gpa.free(base);
        if (!gens.fileExists(self.io, dir, base))
            try gens.writeSmall(self.io, dir, base, self.cfg.base_source orelse embedded_genesis);
        const replay = try gens.genPath(self.gpa, 0, "replay.ss");
        defer self.gpa.free(replay);
        if (!gens.fileExists(self.io, dir, replay))
            try gens.writeSmall(self.io, dir, replay, "");
        const meta = try gens.genPath(self.gpa, 0, "meta.sexp");
        defer self.gpa.free(meta);
        if (!gens.fileExists(self.io, dir, meta))
            try gens.writeSmall(self.io, dir, meta, "(gen 0 parent -1 hash \"\" ts 0)\n");
        if (!gens.fileExists(self.io, dir, journal.path))
            try gens.writeSmall(self.io, dir, journal.path, "");
        if (!gens.fileExists(self.io, dir, gens.current_path))
            try gens.writeSmall(self.io, dir, gens.current_path, "0\n");
    }

    fn writeImageLocked(self: *Live) !void {
        try gens.writeSmall(self.io, self.cfg.state_dir, image_path_in_state,
            self.test_image_source orelse image_script);
    }

    /// Replay authoritative state: base + current generation's replay.ss +
    /// pending journal redefines.
    fn replayLocked(self: *Live) !void {
        try self.replayIntoLocked(&self.child.?);
    }

    fn replayIntoLocked(self: *Live, child: *std.process.Child) !void {
        const dir = self.cfg.state_dir;
        const cur = try gens.readCurrent(self.gpa, self.io, dir);
        const base = try gens.genPath(self.gpa, cur, "base.ss");
        defer self.gpa.free(base);
        const base_src = try dir.readFileAlloc(self.io, base, self.gpa, .limited(max_file));
        defer self.gpa.free(base_src);
        try self.requestApplyLocked(child.*, base_src);
        const replay = try gens.genPath(self.gpa, cur, "replay.ss");
        defer self.gpa.free(replay);
        const replay_src = try dir.readFileAlloc(self.io, replay, self.gpa, .limited(max_file));
        defer self.gpa.free(replay_src);
        if (std.mem.trim(u8, replay_src, " \n").len > 0)
            try self.requestApplyLocked(child.*, replay_src);
        const pend = try journal.pendingRedefs(self.gpa, self.io, dir);
        defer journal.freeRedefs(self.gpa, pend);
        for (pend) |r| try self.requestApplyLocked(child.*, r.source);
    }

    /// Death recovery: respawn + replay. Caller must hold mutex.
    fn restartLocked(self: *Live) !void {
        self.killChildLocked();
        self.spawnLocked() catch return error.ImageRestarted;
        errdefer self.killChildLocked();
        self.bootProbeLocked() catch return error.ImageRestarted;
        self.replayLocked() catch |e| switch (e) {
            error.JournalCorrupt => return error.JournalCorrupt,
            else => {
                self.needs_recovery = self.pendingCountLocked() > 0;
                return error.ImageRestarted;
            },
        };
    }

    // ---------- watchdog ----------

    fn watchdogMain(self: *Live) void {
        while (!self.watchdog_stop.isSet()) {
            // Chunked sleep so stop() never joins a long slumber.
            var waited_ms: u64 = 0;
            while (waited_ms < self.cfg.watchdog.probe_interval_ms) : (waited_ms += 25) {
                if (self.watchdog_stop.isSet()) return;
                Io.sleep(self.io, Io.Duration.fromMilliseconds(25), .awake) catch {};
            }
            if (self.watchdog_stop.isSet()) break;
            self.mutex.lockUncancelable(self.io);
            if (self.started) {
                if (self.child == null) {
                    self.restartLocked() catch {};
                } else {
                    self.pingLocked() catch {
                        self.restartLocked() catch {};
                    };
                }
            }
            self.mutex.unlock(self.io);
        }
    }

    fn pingLocked(self: *Live) !void {
        const child = &self.child.?;
        frame.writeFrame(self.io, child.stdin.?, "(kernel.ping)") catch return error.ImageDied;
        const raw = try frame.readFrameDeadline(self.gpa, self.io, child.stdout.?, self.cfg.watchdog.deadline_ms);
        if (raw) |r| {
            defer self.gpa.free(r);
            if (std.mem.eql(u8, r, "(ok pong)")) return;
            return error.ProtocolError;
        }
        return error.ImageDied;
    }

    // ---------- request/reply with nested kernel requests ----------

    fn requestEvalLocked(self: *Live, child: std.process.Child, source: []const u8) anyerror![]u8 {
        const esc = frame.escape(self.gpa, source) catch return error.ProtocolError;
        defer self.gpa.free(esc);
        const fr = std.fmt.allocPrint(self.gpa, "(kernel.eval \"{s}\")", .{esc}) catch return error.ProtocolError;
        defer self.gpa.free(fr);
        return self.requestLocked(child, fr);
    }

    fn requestApplyLocked(self: *Live, child: std.process.Child, source: []const u8) anyerror!void {
        const esc = frame.escape(self.gpa, source) catch return error.ProtocolError;
        defer self.gpa.free(esc);
        const fr = std.fmt.allocPrint(self.gpa, "(kernel.apply \"{s}\")", .{esc}) catch return error.ProtocolError;
        defer self.gpa.free(fr);
        const v = try self.requestLocked(child, fr);
        defer self.gpa.free(v);
        if (!std.mem.eql(u8, v, "applied")) return error.ProtocolError;
    }

    /// Send a request frame, wait for the reply, service nested kernel
    /// requests. Pure: NEVER restarts anything (restart policy lives at the
    /// public request boundary and in the watchdog). Read/write failure or
    /// timeout => error.ImageDied; oversize from the image => FrameTooLarge;
    /// image-side err reply => ProtocolError (text in last_image_error).
    fn requestLocked(self: *Live, child: std.process.Child, fr: []const u8) anyerror![]u8 {
        frame.writeFrame(self.io, child.stdin.?, fr) catch |e| switch (e) {
            error.FrameTooLarge => return error.FrameTooLarge,
            else => return error.ImageDied,
        };
        while (true) {
            const raw = frame.readFrameDeadline(self.gpa, self.io, child.stdout.?, self.cfg.watchdog.deadline_ms) catch |e| switch (e) {
                error.FrameTooLarge => return error.FrameTooLarge,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ImageDied,
            };
            const raw_frame = raw orelse return error.ImageDied;
            defer self.gpa.free(raw_frame);
            if (frame.isReplyFrame(raw_frame)) {
                const reply = frame.parseReply(self.gpa, raw_frame) catch return error.ProtocolError;
                switch (reply.?) {
                    .ok => |v| return v,
                    .err => |msg| {
                        if (self.last_image_error) |old| self.gpa.free(old);
                        self.last_image_error = msg;
                        return error.ProtocolError;
                    },
                }
            }
            const req = self.parseKernelReq(raw_frame) catch {
                return error.ProtocolError;
            } orelse return error.ProtocolError;
            self.handleKernelReq(child, req) catch {
                return error.ProtocolError;
            };
        }
    }

    // ---------- kernel requests from the image ----------

    const KernelReq = union(enum) {
        redefine: struct { name: []u8, source: []u8 },
        discard: []u8,
        commit: struct { reason: []u8, check: ?[]u8, expected: ?[]u8 },
        inspect: []u8,
        provider_call: []u8,
        tool_invoke: struct { tool: []u8, args: []u8 },
    };

    fn parseKernelReq(self: *Live, fr: []const u8) !?KernelReq {
        const gpa = self.gpa;
        if (std.mem.startsWith(u8, fr, "(kernel.redefine ")) {
            var i: usize = "(kernel.redefine ".len;
            const t = frame.readToken(fr, i);
            i = frame.skipSpaces(fr, t.end);
            const ps = try frame.parseString(gpa, fr, i);
            return KernelReq{ .redefine = .{ .name = try gpa.dupe(u8, t.tok), .source = ps.value } };
        }
        if (std.mem.startsWith(u8, fr, "(kernel.discard ")) {
            const t = frame.readToken(fr, "(kernel.discard ".len);
            return KernelReq{ .discard = try gpa.dupe(u8, t.tok) };
        }
        if (std.mem.startsWith(u8, fr, "(kernel.commit ")) {
            var i: usize = "(kernel.commit ".len;
            const reason = try frame.parseString(gpa, fr, i);
            i = frame.skipSpaces(fr, reason.end);
            var check: ?[]u8 = null;
            var expected: ?[]u8 = null;
            if (i < fr.len and fr[i] == '"') {
                const c = try frame.parseString(gpa, fr, i);
                check = c.value;
                i = frame.skipSpaces(fr, c.end);
                const e = try frame.parseString(gpa, fr, i);
                expected = e.value;
            }
            return KernelReq{ .commit = .{ .reason = reason.value, .check = check, .expected = expected } };
        }
        if (std.mem.startsWith(u8, fr, "(kernel.inspect ")) {
            const t = frame.readToken(fr, "(kernel.inspect ".len);
            return KernelReq{ .inspect = try gpa.dupe(u8, t.tok) };
        }
        if (std.mem.startsWith(u8, fr, "(provider.call ")) {
            const ps = try frame.parseString(gpa, fr, "(provider.call ".len);
            return KernelReq{ .provider_call = ps.value };
        }
        if (std.mem.startsWith(u8, fr, "(tool.invoke ")) {
            var i: usize = "(tool.invoke ".len;
            const t = frame.readToken(fr, i);
            i = frame.skipSpaces(fr, t.end);
            const ps = try frame.parseString(gpa, fr, i);
            return KernelReq{ .tool_invoke = .{ .tool = try gpa.dupe(u8, t.tok), .args = ps.value } };
        }
        return null;
    }

    fn sendFrame(self: *Live, child: std.process.Child, payload: []const u8) !void {
        try frame.writeFrame(self.io, child.stdin.?, payload);
    }

    fn handleKernelReq(self: *Live, child: std.process.Child, req: KernelReq) anyerror!void {
        switch (req) {
            .redefine => |rd| {
                defer self.gpa.free(rd.name);
                defer self.gpa.free(rd.source);
                // Journal + fsync BEFORE the change is applied inside the image.
                try journal.appendRedefine(self.gpa, self.io, self.cfg.state_dir, rd.name, rd.source);
                try self.requestApplyLocked(child, rd.source);
                const ack = try std.fmt.allocPrint(self.gpa, "(kernel.ack {s})", .{rd.name});
                defer self.gpa.free(ack);
                try self.sendFrame(child, ack);
            },
            .discard => |name| {
                defer self.gpa.free(name);
                const src = try self.committedSource(name);
                if (src == null) {
                    const nack = try std.fmt.allocPrint(self.gpa, "(kernel.nack {s} \"NotCommitted\")", .{name});
                    defer self.gpa.free(nack);
                    try self.sendFrame(child, nack);
                    return;
                }
                defer self.gpa.free(src.?);
                try journal.appendDiscard(self.gpa, self.io, self.cfg.state_dir, name);
                try self.requestApplyLocked(child, src.?);
                const ack = try std.fmt.allocPrint(self.gpa, "(kernel.ack {s})", .{name});
                defer self.gpa.free(ack);
                try self.sendFrame(child, ack);
            },
            .commit => |c| {
                defer self.gpa.free(c.reason);
                defer if (c.check) |v| self.gpa.free(v);
                defer if (c.expected) |v| self.gpa.free(v);
                self.doCommit(c.check, c.expected) catch |e| {
                    const atom = switch (e) {
                        error.CommitRejected => "CommitRejected",
                        error.CommitUnavailable => "CommitUnavailable",
                        error.NothingToCommit => "NothingToCommit",
                        else => "CommitRejected",
                    };
                    const fr = try std.fmt.allocPrint(self.gpa, "(kernel.err \"{s}\")", .{atom});
                    defer self.gpa.free(fr);
                    try self.sendFrame(child, fr);
                    return;
                };
                try self.sendFrame(child, "(kernel.ack committed)");
            },
            .inspect => |name| {
                defer self.gpa.free(name);
                const reply = try self.composeInspect(name);
                defer self.gpa.free(reply);
                try self.sendFrame(child, reply);
            },
            .provider_call => |request| {
                defer self.gpa.free(request);
                if (self.cfg.provider_port) |pp| {
                    const resp = pp.call(pp.ctx, request) catch |e| {
                        const atom = firstLineAtom(@errorName(e));
                        const fr = try std.fmt.allocPrint(self.gpa, "(port.nack provider \"{s}\")", .{atom});
                        defer self.gpa.free(fr);
                        try self.sendFrame(child, fr);
                        return;
                    };
                    defer self.gpa.free(resp);
                    const esc = try frame.escape(self.gpa, resp);
                    defer self.gpa.free(esc);
                    const fr = try std.fmt.allocPrint(self.gpa, "(provider.reply \"{s}\")", .{esc});
                    defer self.gpa.free(fr);
                    try self.sendFrame(child, fr);
                } else {
                    try self.sendFrame(child, "(port.nack provider \"PortAbsent\")");
                }
            },
            .tool_invoke => |ti| {
                defer self.gpa.free(ti.tool);
                defer self.gpa.free(ti.args);
                if (self.cfg.tool_port) |tp| {
                    // args arrive as a bare string; the port contract takes
                    // an args sexp — wrap as ("<args>").
                    const args_sexp = try std.fmt.allocPrint(self.gpa, "(\"{s}\")", .{ti.args});
                    defer self.gpa.free(args_sexp);
                    const resp = tp.invoke(tp.ctx, ti.tool, args_sexp) catch |e| {
                        const atom = firstLineAtom(@errorName(e));
                        const fr = try std.fmt.allocPrint(self.gpa, "(port.nack tool \"{s}\")", .{atom});
                        defer self.gpa.free(fr);
                        try self.sendFrame(child, fr);
                        return;
                    };
                    defer self.gpa.free(resp);
                    const esc = try frame.escape(self.gpa, resp);
                    defer self.gpa.free(esc);
                    const fr = try std.fmt.allocPrint(self.gpa, "(tool.reply \"{s}\")", .{esc});
                    defer self.gpa.free(fr);
                    try self.sendFrame(child, fr);
                } else {
                    try self.sendFrame(child, "(port.nack tool \"PortAbsent\")");
                }
            },
        }
    }

    /// First-line atoms only in error payloads: no paths, errnos, env values.
    fn firstLineAtom(name: []const u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, name, '\n') orelse name.len;
        return name[0..end];
    }

    // ---------- inspect ----------

    fn composeInspect(self: *Live, name: []const u8) ![]u8 {
        const dir = self.cfg.state_dir;
        const pend = try journal.pendingRedefs(self.gpa, self.io, dir);
        defer journal.freeRedefs(self.gpa, pend);

        var status: []const u8 = "unknown";
        var source: ?[]const u8 = null;
        var gen: ?u32 = null;
        for (pend) |r| {
            if (std.mem.eql(u8, r.name, name)) {
                status = "pending";
                source = r.source;
            }
        }
        var committed_src: ?[]u8 = null;
        defer if (committed_src) |s| self.gpa.free(s);
        if (source == null) {
            committed_src = try self.committedSource(name);
            if (committed_src) |s| {
                status = "committed";
                source = s;
                gen = try self.definedGeneration(name);
            }
        }

        var deps: std.ArrayList([]u8) = .empty;
        defer {
            for (deps.items) |d| self.gpa.free(d);
            deps.deinit(self.gpa);
        }
        const cur = try gens.readCurrent(self.gpa, self.io, dir);
        for ([_][]const u8{ "base.ss", "replay.ss" }) |file| {
            const path = try std.fmt.allocPrint(self.gpa, gens.gens_path ++ "/{d}/{s}", .{ cur, file });
            defer self.gpa.free(path);
            const text = dir.readFileAlloc(self.io, path, self.gpa, .limited(max_file)) catch continue;
            defer self.gpa.free(text);
            const defs = try scanDefines(self.gpa, text);
            defer self.gpa.free(defs);
            for (defs) |d| {
                if (!std.mem.eql(u8, d.name, name) and containsSymbol(d.text, name))
                    try deps.append(self.gpa, try self.gpa.dupe(u8, d.name));
            }
        }
        for (pend) |r| {
            if (!std.mem.eql(u8, r.name, name) and containsSymbol(r.source, name))
                try deps.append(self.gpa, try self.gpa.dupe(u8, r.name));
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "(kernel.inspect.result (source ");
        if (source) |s| {
            const esc = try frame.escape(self.gpa, s);
            defer self.gpa.free(esc);
            try out.appendSlice(self.gpa, "\"");
            try out.appendSlice(self.gpa, esc);
            try out.appendSlice(self.gpa, "\")");
        } else {
            try out.appendSlice(self.gpa, "#f)");
        }
        try out.appendSlice(self.gpa, " (status ");
        try out.appendSlice(self.gpa, status);
        try out.appendSlice(self.gpa, ") (generation ");
        if (gen) |g| {
            const gs = try std.fmt.allocPrint(self.gpa, "{d}", .{g});
            defer self.gpa.free(gs);
            try out.appendSlice(self.gpa, gs);
        } else {
            try out.appendSlice(self.gpa, "#f");
        }
        try out.appendSlice(self.gpa, ") (dependents (");
        for (deps.items, 0..) |d, idx| {
            if (idx > 0) try out.append(self.gpa, ' ');
            try out.appendSlice(self.gpa, d);
        }
        try out.appendSlice(self.gpa, ")))");
        return out.toOwnedSlice(self.gpa);
    }

    /// The committed source for NAME in the current generation.
    fn committedSource(self: *Live, name: []const u8) !?[]u8 {
        const dir = self.cfg.state_dir;
        const cur = try gens.readCurrent(self.gpa, self.io, dir);
        for ([_][]const u8{ "base.ss", "replay.ss" }) |file| {
            const path = try std.fmt.allocPrint(self.gpa, gens.gens_path ++ "/{d}/{s}", .{ cur, file });
            defer self.gpa.free(path);
            const text = dir.readFileAlloc(self.io, path, self.gpa, .limited(max_file)) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer self.gpa.free(text);
            const defs = try scanDefines(self.gpa, text);
            defer self.gpa.free(defs);
            for (defs) |d| {
                if (std.mem.eql(u8, d.name, name)) return try self.gpa.dupe(u8, d.text);
            }
        }
        return null;
    }

    /// Generation at which NAME was committed: 0 for base.ss, else the
    /// earliest generation whose replay.ss defines it.
    fn definedGeneration(self: *Live, name: []const u8) !?u32 {
        const dir = self.cfg.state_dir;
        const cur = try gens.readCurrent(self.gpa, self.io, dir);
        const base = try gens.genPath(self.gpa, cur, "base.ss");
        defer self.gpa.free(base);
        const base_src = try dir.readFileAlloc(self.io, base, self.gpa, .limited(max_file));
        defer self.gpa.free(base_src);
        {
            const defs = try scanDefines(self.gpa, base_src);
            defer self.gpa.free(defs);
            for (defs) |d| if (std.mem.eql(u8, d.name, name)) return 0;
        }
        var g: u32 = 0;
        while (g <= cur) : (g += 1) {
            const path = try gens.genPath(self.gpa, g, "replay.ss");
            defer self.gpa.free(path);
            const text = dir.readFileAlloc(self.io, path, self.gpa, .limited(max_file)) catch continue;
            defer self.gpa.free(text);
            const defs = try scanDefines(self.gpa, text);
            defer self.gpa.free(defs);
            for (defs) |d| if (std.mem.eql(u8, d.name, name)) return g;
        }
        return null;
    }

    // ---------- commit (B4 forms + G4 + F8/F9 promotion semantics) ----------

    fn doCommit(self: *Live, check: ?[]const u8, expected: ?[]const u8) anyerror!void {
        const dir = self.cfg.state_dir;
        const cur = try gens.readCurrent(self.gpa, self.io, dir);
        const pend = try journal.pendingRedefs(self.gpa, self.io, dir);
        defer journal.freeRedefs(self.gpa, pend);
        if (pend.len == 0) return error.NothingToCommit;

        // F9: quarantine on every REPLAY/CHECK failure exit. Infra failure
        // (G4) retries once, then CommitUnavailable with the pending set
        // intact — quarantine is reserved for defects of the change itself.
        var replay_failed = false;
        defer if (replay_failed) self.quarantine(pend);

        const old_replay_path = try gens.genPath(self.gpa, cur, "replay.ss");
        defer self.gpa.free(old_replay_path);
        const old_replay = try dir.readFileAlloc(self.io, old_replay_path, self.gpa, .limited(max_file));
        defer self.gpa.free(old_replay);
        var new_replay: std.ArrayList(u8) = .empty;
        defer new_replay.deinit(self.gpa);
        try new_replay.appendSlice(self.gpa, old_replay);
        for (pend) |r| {
            try new_replay.appendSlice(self.gpa, r.source);
            try new_replay.append(self.gpa, '\n');
        }
        const old_base = try gens.genPath(self.gpa, cur, "base.ss");
        defer self.gpa.free(old_base);
        const base_src = try dir.readFileAlloc(self.io, old_base, self.gpa, .limited(max_file));
        defer self.gpa.free(base_src);

        var attempt: u2 = 0;
        while (true) : (attempt += 1) {
            // commitProbe errors are INFRA by construction (staging or
            // spawn-stage, any failure class — M1a); post-spawn failures
            // come back as .reject (M1b). G4: retry infra once, then
            // CommitUnavailable with the pending set intact.
            const outcome = self.commitProbe(cur, base_src, new_replay.items, check, expected) catch |e| {
                if (e == error.OutOfMemory) return e;
                if (attempt == 0) continue;
                return error.CommitUnavailable;
            };
            switch (outcome) {
                .pass => break,
                .reject => {
                    replay_failed = true;
                    return error.CommitRejected;
                },
            }
        }

        // Probe passed: move the staged generation into place, flip pointer,
        // record the commit entry.
        const staging_dir = try gens.stagingPath(self.gpa, cur + 1);
        defer self.gpa.free(staging_dir);
        const new_dir = try std.fmt.allocPrint(self.gpa, gens.gens_path ++ "/{d}", .{cur + 1});
        defer self.gpa.free(new_dir);
        dir.deleteTree(self.io, new_dir) catch {}; // stale orphan, if any
        try Io.Dir.rename(dir, staging_dir, dir, new_dir, self.io);
        try gens.flip(self.gpa, self.io, dir, cur + 1);
        const hex = gens.sha256Hex(new_replay.items);
        try journal.appendCommit(self.gpa, self.io, dir, cur + 1, &hex);
    }

    fn quarantine(self: *Live, pend: []const journal.Redef) void {
        for (pend) |r| {
            journal.appendSuspect(self.gpa, self.io, self.cfg.state_dir, r.name) catch {};
        }
    }

    const ProbeOutcome = enum { pass, reject };

    /// Stage + clean-process replay probe. Returns .pass/.reject for
    /// replay/check defects; infra failures are errors (G4 retried by caller).
    fn commitProbe(
        self: *Live,
        cur: u32,
        base_src: []const u8,
        new_replay: []const u8,
        check: ?[]const u8,
        expected: ?[]const u8,
    ) !ProbeOutcome {
        const dir = self.cfg.state_dir;
        const staging_dir = try gens.stagingPath(self.gpa, cur + 1);
        defer self.gpa.free(staging_dir);
        dir.deleteTree(self.io, staging_dir) catch {};
        var staged = false;
        defer if (staged) dir.deleteTree(self.io, staging_dir) catch {};
        try dir.createDirPath(self.io, staging_dir);
        staged = true;
        {
            const p = try std.fmt.allocPrint(self.gpa, "{s}/base.ss", .{staging_dir});
            defer self.gpa.free(p);
            try gens.writeSmall(self.io, dir, p, base_src);
        }
        {
            const p = try std.fmt.allocPrint(self.gpa, "{s}/replay.ss", .{staging_dir});
            defer self.gpa.free(p);
            try gens.writeSmall(self.io, dir, p, new_replay);
        }
        const hex = gens.sha256Hex(new_replay);
        {
            const meta = try std.fmt.allocPrint(self.gpa, "(gen {d} parent {d} hash \"{s}\" ts {d})\n", .{ cur + 1, cur, hex, Io.Clock.now(.real, self.io).nanoseconds });
            defer self.gpa.free(meta);
            const p = try std.fmt.allocPrint(self.gpa, "{s}/meta.sexp", .{staging_dir});
            defer self.gpa.free(p);
            try gens.writeSmall(self.io, dir, p, meta);
        }
        // M1b: once the clean image exists, ANY replay/apply/check failure —
        // death, oversize, scheme error, mismatch — is a defect of the
        // change: reject and let doCommit quarantine.
        var clean = try self.spawnCleanLocked(); // last infra-capable step
        defer clean.kill(self.io);
        self.requestApplyLocked(clean, base_src) catch |e| {
            if (e == error.OutOfMemory) return e;
            return .reject;
        };
        self.requestApplyLocked(clean, new_replay) catch |e| {
            if (e == error.OutOfMemory) return e;
            return .reject;
        };
        if (check) |c| {
            const got = self.requestEvalLocked(clean, c) catch |e| {
                if (e == error.OutOfMemory) return e;
                return .reject;
            };
            defer self.gpa.free(got);
            if (!std.mem.eql(u8, got, expected.?)) return .reject;
        } else {
            // Default recorded check: replay completed (above) and every
            // tracked binding resolves.
            const names = try self.trackedNames(base_src, new_replay);
            defer {
                for (names) |nm| self.gpa.free(nm);
                self.gpa.free(names);
            }
            for (names) |nm| {
                const v = self.requestEvalLocked(clean, nm) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    return .reject;
                };
                self.gpa.free(v);
            }
        }
        // Probe passed: ownership of the staging dir transfers to doCommit
        // (which renames it into place). Disarm the failure cleanup.
        staged = false;
        return .pass;
    }

    fn trackedNames(self: *Live, base_src: []const u8, replay_src: []const u8) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |nm| self.gpa.free(nm);
            names.deinit(self.gpa);
        }
        for ([_][]const u8{ base_src, replay_src }) |text| {
            const defs = try scanDefines(self.gpa, text);
            defer self.gpa.free(defs);
            for (defs) |d| {
                var dup = false;
                for (names.items) |nm| {
                    if (std.mem.eql(u8, nm, d.name)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try names.append(self.gpa, try self.gpa.dupe(u8, d.name));
            }
        }
        return names.toOwnedSlice(self.gpa);
    }
};

// ---------- source scanning (committed source / dependents) ----------

const Define = struct { name: []const u8, text: []const u8 };

fn formEnd(s: []const u8, start: usize) !usize {
    var depth: usize = 0;
    var i = start;
    var in_str = false;
    var esc = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            ';' => {
                while (i < s.len and s[i] != '\n') i += 1;
            },
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return error.UnbalancedForm;
}

fn scanDefines(gpa: Allocator, text: []const u8) ![]Define {
    var defs: std.ArrayList(Define) = .empty;
    errdefer defs.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == ';') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (c != '(') return error.TopLevelJunk;
        const end = try formEnd(text, i);
        const form = text[i..end];
        if (std.mem.startsWith(u8, form, "(define")) {
            var j: usize = "(define".len;
            j = frame.skipSpaces(form, j);
            if (j < form.len and form[j] == '(') j = frame.skipSpaces(form, j + 1);
            const t = frame.readToken(form, j);
            try defs.append(gpa, .{ .name = t.tok, .text = form });
        }
        i = end;
    }
    return defs.toOwnedSlice(gpa);
}

fn isSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or
        std.mem.indexOfScalar(u8, "!$%&*+-./:<=>?@^_~", c) != null;
}

/// Shallow dependency check: does TEXT mention NAME as a delimited symbol?
fn containsSymbol(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |pos| {
        const left_ok = pos == 0 or !isSymbolChar(text[pos - 1]);
        const right = pos + name.len;
        const right_ok = right >= text.len or !isSymbolChar(text[right]);
        if (left_ok and right_ok) return true;
        i = pos + 1;
    }
    return false;
}

test "gerbil version floor: >= 0.18 enforced" {
    try Live.parseGerbilVersionFloor("Gerbil v0.18.1-78-gc5546da0 on Gambit v4.9.5\n");
    try Live.parseGerbilVersionFloor("Gerbil v1.0\n");
    try std.testing.expectError(error.BootProbeFailed, Live.parseGerbilVersionFloor("Gerbil v0.17.0\n"));
    try std.testing.expectError(error.BootProbeFailed, Live.parseGerbilVersionFloor("garbage"));
}

test "scanDefines + containsSymbol" {
    const gpa = std.testing.allocator;
    const defs = try scanDefines(gpa,
        \\(define (greeting) "hello (not a paren")
        \\; a comment (define fake 1)
        \\(define answer 42)
    );
    defer gpa.free(defs);
    try std.testing.expectEqual(@as(usize, 2), defs.len);
    try std.testing.expectEqualStrings("greeting", defs[0].name);
    try std.testing.expectEqualStrings("answer", defs[1].name);
    try std.testing.expect(containsSymbol(defs[0].text, "greeting"));
    try std.testing.expect(!containsSymbol(defs[0].text, "greet"));
    try std.testing.expect(!containsSymbol(defs[1].text, "greeting"));
}


