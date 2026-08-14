//! Acceptance tests — the 14 classes of docs/modules/zag-live.md §10
//! (D-015 revision). Image-touching classes run on BOTH spawn forms
//! (interpreted gxi / compiled gsc-exe), skip-gated when the toolchain is
//! absent. Self-contained: fixture ports, temp state dirs, no network.

const std = @import("std");
const Io = std.Io;
const live_mod = @import("live.zig");
const Live = live_mod.Live;
const ports = @import("ports.zig");
const journal = @import("journal.zig");
const frame = @import("frame.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const fast_watchdog: live_mod.WatchdogConfig = .{ .probe_interval_ms = 50, .deadline_ms = 800 };
const idle_watchdog: live_mod.WatchdogConfig = .{ .probe_interval_ms = 60_000, .deadline_ms = 800 };

const SpawnForm = enum { interpreted, compiled };

// ---------- shared compiled test image (built once per test run) ----------

var shared_image_mutex: Io.Mutex = .init;
var shared_image_state: enum { untried, ok, unavailable } = .untried;
var shared_image_path: ?[]u8 = null;

fn compiledImageAvailable() bool {
    shared_image_mutex.lockUncancelable(io);
    defer shared_image_mutex.unlock(io);
    if (shared_image_state == .untried) {
        shared_image_state = .unavailable;
        const dir_path = ".zig-cache/zag-live-test-image";
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch return false;
        const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
        var l = Live.init(gpa, io, .{ .state_dir = dir }) catch return false;
        defer l.deinit();
        l.buildImage() catch return false;
        const abs = std.process.currentPathAlloc(io, gpa) catch return false;
        defer gpa.free(abs);
        // process-lifetime by design (shared across tests); c_allocator is
        // outside testing.allocator's leak checker
        shared_image_path = std.fmt.allocPrint(std.heap.c_allocator, "{s}/{s}/image-bin", .{ abs, dir_path }) catch return false;
        shared_image_state = .ok;
    }
    return shared_image_state == .ok;
}

fn interpretedAvailable() bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "gxi", "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn formAvailable(form: SpawnForm) bool {
    return switch (form) {
        .interpreted => interpretedAvailable(),
        .compiled => compiledImageAvailable(),
    };
}

const Cfg = struct {
    extra_env: []const live_mod.EnvPair = &.{},
    provider: ?ports.ProviderPort = null,
    tool: ?ports.ToolPort = null,
    watchdog: live_mod.WatchdogConfig = fast_watchdog,
};

fn makeLive(l: *Live, tmp: *std.testing.TmpDir, cfg: Cfg, form: SpawnForm) !void {
    const image: live_mod.ImageSource = switch (form) {
        .interpreted => .{ .interpreted = .{} },
        .compiled => .{ .compiled = shared_image_path.? },
    };
    l.* = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = image,
        .extra_env = cfg.extra_env,
        .provider_port = cfg.provider,
        .tool_port = cfg.tool,
        .watchdog = cfg.watchdog,
    });
    errdefer l.deinit();
    try l.start();
}

fn waitAlive(l: *Live) !void {
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        const v = l.eval("(+ 1 1)") catch {
            Io.sleep(io, Io.Duration.fromMilliseconds(100), .awake) catch {};
            continue;
        };
        gpa.free(v);
        return;
    }
    return error.ImageNeverRestarted;
}

fn redefine(l: *Live, name: []const u8, source: []const u8) !void {
    const esc = try frame.escape(gpa, source);
    defer gpa.free(esc);
    const call = try std.fmt.allocPrint(gpa, "(kernel.redefine '{s} \"{s}\")", .{ name, esc });
    defer gpa.free(call);
    const v = try l.eval(call);
    gpa.free(v);
}

fn expectImageError(l: *Live, source: []const u8, want: anyerror, needle: []const u8) !void {
    const res = l.eval(source);
    if (res) |x| {
        gpa.free(x);
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expectEqual(want, e);
        const msg = l.lastImageError() orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, msg, needle) != null);
    }
}

fn expectErr(want: anyerror, res: anyerror![]u8) !void {
    if (res) |x| {
        gpa.free(x);
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expectEqual(want, e);
    }
}

fn readCurrentFile(tmp: *std.testing.TmpDir) !u32 {
    const c = try tmp.dir.readFileAlloc(io, "current", gpa, .limited(64));
    defer gpa.free(c);
    return std.fmt.parseInt(u32, std.mem.trim(u8, c, " \n"), 10);
}

fn journalText(tmp: *std.testing.TmpDir) ![]u8 {
    return tmp.dir.readFileAlloc(io, journal.path, gpa, .limited(64 * 1024 * 1024));
}

fn stateFileExists(tmp: *std.testing.TmpDir, path: []const u8) bool {
    tmp.dir.access(io, path, .{}) catch return false;
    return true;
}

// ---------- class 1: boot + boot probe at start(); ImageUnavailable paths

fn accept1(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    const v = try l.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("hello, live image", v);
}

test "accept 1: boot + boot probe (interpreted)" {
    try accept1(.interpreted);
}
test "accept 1: boot + boot probe (compiled)" {
    try accept1(.compiled);
}

test "accept 1: ImageUnavailable paths (missing gxi / missing binary / wrong identity)" {
    if (!interpretedAvailable()) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // missing gxi
    var bad = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = .{ .interpreted = .{ .gxi_path = "/nonexistent/gxi" } },
        .watchdog = fast_watchdog,
    });
    defer bad.deinit();
    try std.testing.expectError(error.ImageUnavailable, bad.start());
    // missing compiled binary: rejected at init (cheap validation)
    {
        const res = Live.init(gpa, io, .{
            .state_dir = tmp.dir,
            .image = .{ .compiled = "/nonexistent/image-bin" },
            .watchdog = fast_watchdog,
        });
        if (res) |ll| {
            var ll2 = ll;
            ll2.deinit();
            return error.TestUnexpectedResult;
        } else |e| {
            try std.testing.expectEqual(error.ImageUnavailable, e);
        }
    }
    // foreign binary (exits immediately -> no handshake)
    const foreign_abs = try writeForeignBin(&tmp, "foreign-exit", "#!/bin/sh\nexit 0\n");
    defer gpa.free(foreign_abs);
    var fb = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = .{ .compiled = foreign_abs },
        .watchdog = fast_watchdog,
    });
    defer fb.deinit();
    try std.testing.expectError(error.ImageUnavailable, fb.start());
}

/// Write an executable fixture into tmp/.tmp/<name>; returns the ABSOLUTE
/// path (Live init validates compiled paths against cwd).
fn writeForeignBin(tmp: *std.testing.TmpDir, name: []const u8, content: []const u8) ![:0]u8 {
    try tmp.dir.createDirPath(io, ".tmp");
    const path = try std.fmt.allocPrint(gpa, ".tmp/{s}", .{name});
    defer gpa.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = content });
    const f = try tmp.dir.openFile(io, path, .{});
    defer f.close(io);
    try f.setPermissions(io, .executable_file);
    return try tmp.dir.realPathFileAlloc(io, path, gpa); // [:0]u8 — frees cleanly
}

// ---------- class 2: child env scrub

fn accept2(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    _ = setenv("ZAGLIVE_TEST_SECRET_KEY", "sk-not-real", 1);
    _ = setenv("ZAGLIVE_TEST_TOKEN", "tok-not-real", 1);
    defer {
        _ = unsetenv("ZAGLIVE_TEST_SECRET_KEY");
        _ = unsetenv("ZAGLIVE_TEST_TOKEN");
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{ .extra_env = &.{.{ .name = "ZAGLIVE_EXTRA", .value = "extra-value" }} }, form);
    defer l.deinit();

    const secret = try l.eval("(getenv \"ZAGLIVE_TEST_SECRET_KEY\")");
    defer gpa.free(secret);
    try std.testing.expectEqualStrings("#f", secret);
    const token = try l.eval("(getenv \"ZAGLIVE_TEST_TOKEN\")");
    defer gpa.free(token);
    try std.testing.expectEqualStrings("#f", token);
    const extra = try l.eval("(getenv \"ZAGLIVE_EXTRA\")");
    defer gpa.free(extra);
    try std.testing.expectEqualStrings("extra-value", extra);
    const path = try l.eval("(getenv \"PATH\")");
    defer gpa.free(path);
    try std.testing.expect(!std.mem.eql(u8, path, "#f"));
}

test "accept 2: child env scrub (interpreted)" {
    try accept2(.interpreted);
}
test "accept 2: child env scrub (compiled)" {
    try accept2(.compiled);
}

// ---------- class 3: echo 10k

fn accept3(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    for (0..10_000) |i| {
        const payload = try std.fmt.allocPrint(gpa, "msg-{d}-{d}", .{ i, i *% 7919 });
        defer gpa.free(payload);
        const v = try l.echo(payload);
        defer gpa.free(v);
        try std.testing.expectEqualStrings(payload, v);
    }
}

test "accept 3: echo 10k frames (interpreted)" {
    try accept3(.interpreted);
}
test "accept 3: echo 10k frames (compiled)" {
    try accept3(.compiled);
}

// ---------- class 4: escaping fuzz

const fuzz_unicode = [_][]const u8{ "λ≈∑π", "日本語テスト", "🚀🔥✨", "Ünïcödé", "α β γ δ" };

fn genAdversarial(rand: std.Random, i: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    switch (i % 8) {
        0 => {
            const n = rand.intRangeAtMost(usize, 1, 40);
            for (0..n) |_| try list.append(gpa, if (rand.boolean()) '"' else '\\');
        },
        1 => {
            const pieces = [_][]const u8{ "\\x41;", "\\xZZ;", "\\x", "\\;", "\\\\x0;", "\\x1f600;" };
            const n = rand.intRangeAtMost(usize, 1, 5);
            for (0..n) |_| try list.appendSlice(gpa, pieces[rand.uintLessThan(usize, pieces.len)]);
        },
        2 => {
            const n = rand.intRangeAtMost(usize, 1, 30);
            for (0..n) |_| {
                const c: u8 = if (rand.boolean()) rand.intRangeAtMost(u8, 0x00, 0x1f) else 0x7f;
                try list.append(gpa, c);
            }
        },
        3 => {
            const n = rand.intRangeAtMost(usize, 1, 3);
            for (0..n) |_| try list.appendSlice(gpa, fuzz_unicode[rand.uintLessThan(usize, fuzz_unicode.len)]);
        },
        4 => {
            const n = rand.intRangeAtMost(usize, 1, 120);
            for (0..n) |_| try list.append(gpa, rand.intRangeAtMost(u8, 0x20, 0x7e));
        },
        5 => {
            const pieces = [_][]const u8{ "\n", "\r\n", "\t", "a\nb", "\r", "end\n" };
            const n = rand.intRangeAtMost(usize, 1, 8);
            for (0..n) |_| try list.appendSlice(gpa, pieces[rand.uintLessThan(usize, pieces.len)]);
        },
        6 => {
            const n = rand.intRangeAtMost(usize, 100, 4000);
            for (0..n) |_| {
                const c: u8 = switch (rand.uintLessThan(u8, 10)) {
                    0 => '"',
                    1 => '\\',
                    2 => rand.intRangeAtMost(u8, 0x00, 0x1f),
                    else => rand.intRangeAtMost(u8, 0x20, 0x7e),
                };
                try list.append(gpa, c);
            }
        },
        7 => {
            try list.appendSlice(gpa, "pre\"\\\\\x00\x1f\x7f");
            try list.appendSlice(gpa, fuzz_unicode[rand.uintLessThan(usize, fuzz_unicode.len)]);
            try list.appendSlice(gpa, "\\x41;\"tail\n");
        },
        else => unreachable,
    }
    return list.toOwnedSlice(gpa);
}

fn accept4(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    var rng = std.Random.DefaultPrng.init(0xace9_7004);
    const rand = rng.random();
    for (0..1500) |i| {
        const s = try genAdversarial(rand, i);
        defer gpa.free(s);
        const v = try l.echo(s);
        defer gpa.free(v);
        try std.testing.expectEqualStrings(s, v);
    }
    // invalid escapes are loud (decode-side strictness)
    try std.testing.expectError(error.UnknownEscape, frame.parseString(gpa, "\"\\q\"", 0));
    // canonical encode is Gambit profile (lowercase hex)
    const enc = try frame.escape(gpa, "A\x1f\x7f");
    defer gpa.free(enc);
    try std.testing.expectEqualStrings("A\\x1f;\\x7f;", enc);
}

test "accept 4: escaping fuzz (interpreted)" {
    try accept4(.interpreted);
}
test "accept 4: escaping fuzz (compiled)" {
    try accept4(.compiled);
}

// ---------- class 5: frame cap both sides

fn accept5(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{ .watchdog = idle_watchdog }, form);
    defer l.deinit();

    const big = try gpa.alloc(u8, frame.max_frame_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'a');

    try expectErr(error.FrameTooLarge, l.echo(big));

    try l.sendRawFrameUnchecked(big);
    const reply = (try frame.readFrame(gpa, io, l.child.?.stdout.?)).?;
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "frame-too-large") != null);

    const v = try l.eval("(+ 1 1)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("2", v);

    try expectErr(error.FrameTooLarge, l.eval("(make-string 5000000 #\\a)"));
    const v2 = try l.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("hello, live image", v2);
}

test "accept 5: frame cap both directions (interpreted)" {
    try accept5(.interpreted);
}
test "accept 5: frame cap both directions (compiled)" {
    try accept5(.compiled);
}

// ---------- class 6: redefine -> SIGKILL -> replay

fn accept6(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    const src = "(define (greeting) \"hacked at runtime\")";
    try redefine(&l, "greeting", src);
    const v1 = try l.eval("(greeting)");
    defer gpa.free(v1);
    try std.testing.expectEqualStrings("hacked at runtime", v1);

    l.forceKillImage();
    try waitAlive(&l);

    const v2 = try l.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("hacked at runtime", v2);
    const insp = try l.eval("(kernel.inspect 'greeting)");
    defer gpa.free(insp);
    try std.testing.expect(std.mem.indexOf(u8, insp, "(status pending)") != null);
    try std.testing.expect(std.mem.indexOf(u8, insp, "hacked at runtime") != null);
}

test "accept 6: redefine -> SIGKILL -> replay (interpreted)" {
    try accept6(.interpreted);
}
test "accept 6: redefine -> SIGKILL -> replay (compiled)" {
    try accept6(.compiled);
}

// ---------- class 7: discard / nack

fn accept7(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    try redefine(&l, "greeting", "(define (greeting) \"hacked\")");
    const dv = try l.eval("(kernel.discard 'greeting)");
    gpa.free(dv);
    const v = try l.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("hello, live image", v);

    try expectImageError(&l, "(kernel.discard 'never-defined)", error.ProtocolError, "NotCommitted");
    const alive = try l.eval("(+ 2 2)");
    defer gpa.free(alive);
    try std.testing.expectEqualStrings("4", alive);
}

test "accept 7: discard / nack (interpreted)" {
    try accept7(.interpreted);
}
test "accept 7: discard / nack (compiled)" {
    try accept7(.compiled);
}

// ---------- class 8: commit paths

fn accept8(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();

    try redefine(&l, "greeting", "(define (greeting) \"committed-v1\")");
    {
        const ok = try l.eval("(kernel.commit \"to-v1\" \"(greeting)\" \"committed-v1\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 1), try readCurrentFile(&tmp));

    try redefine(&l, "extra", "(define (extra) 99)");
    {
        const ok = try l.eval("(kernel.commit \"add-extra\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));

    try redefine(&l, "greeting", "(define (greeting) \"broken\")");
    try expectImageError(&l, "(kernel.commit \"bad\" \"(greeting)\" \"never\")", error.ProtocolError, "CommitRejected");
    {
        const j = try journalText(&tmp);
        defer gpa.free(j);
        try std.testing.expect(std.mem.indexOf(u8, j, "(suspect greeting ") != null);
    }
    try std.testing.expect(!stateFileExists(&tmp, "generations/3"));
    try std.testing.expect(!stateFileExists(&tmp, "generations/.staging-3"));
    {
        const live_val = try l.eval("(greeting)");
        defer gpa.free(live_val);
        try std.testing.expectEqualStrings("broken", live_val);
    }
    l.forceKillImage();
    try waitAlive(&l);
    {
        const restored = try l.eval("(greeting)");
        defer gpa.free(restored);
        try std.testing.expectEqualStrings("committed-v1", restored);
    }

    // check-eval-ERROR failure: quarantined too
    try redefine(&l, "greeting", "(define (greeting) \"broken-again\")");
    try expectImageError(&l, "(kernel.commit \"bad2\" \"(car 1)\" \"#t\")", error.ProtocolError, "CommitRejected");
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));

    // G4: spawn-stage INFRA failure (not FileNotFound) retries once, then
    // CommitUnavailable; pending set intact; later commit succeeds.
    try redefine(&l, "greeting", "(define (greeting) \"v3\")");
    l.fail_clean_spawn = error.SystemResources;
    try expectImageError(&l, "(kernel.commit \"v3\")", error.ProtocolError, "CommitUnavailable");
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));
    {
        const j = try journalText(&tmp);
        defer gpa.free(j);
        const v3_pos = std.mem.indexOf(u8, j, "\\\"v3\\\"").?;
        try std.testing.expect(std.mem.indexOfPos(u8, j, v3_pos, "(suspect greeting") == null);
    }
    l.fail_clean_spawn = null;
    {
        const ok = try l.eval("(kernel.commit \"v3-retry\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 3), try readCurrentFile(&tmp));

    try expectImageError(&l, "(kernel.commit \"empty\")", error.ProtocolError, "NothingToCommit");
}

test "accept 8: commit paths (interpreted)" {
    try accept8(.interpreted);
}
test "accept 8: commit paths (compiled)" {
    try accept8(.compiled);
}

// M1b edge: post-spawn replay death caused by the change = defect
fn accept8b(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();
    try journal.appendRedefine(gpa, io, tmp.dir, "evil", "(exit)");
    try expectImageError(&l, "(kernel.commit \"doomed\")", error.ProtocolError, "CommitRejected");
    {
        const j = try journalText(&tmp);
        defer gpa.free(j);
        try std.testing.expect(std.mem.indexOf(u8, j, "(suspect evil ") != null);
    }
    try std.testing.expectEqual(@as(u32, 0), try readCurrentFile(&tmp));
    try std.testing.expect(!stateFileExists(&tmp, "generations/1"));
    const alive = try l.eval("(+ 1 1)");
    defer gpa.free(alive);
    try std.testing.expectEqualStrings("2", alive);
}

test "accept 8 edge (M1b): post-spawn replay death quarantined (interpreted)" {
    try accept8b(.interpreted);
}
test "accept 8 edge (M1b): post-spawn replay death quarantined (compiled)" {
    try accept8b(.compiled);
}

// ---------- class 9: watchdog + in-flight disposition

fn accept9(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();

    try redefine(&l, "greeting", "(define (greeting) \"committed-v1\")");
    {
        const ok = try l.eval("(kernel.commit \"v1\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    const before = try journal.countEntries(gpa, io, tmp.dir);

    try expectErr(error.ImageRestarted, l.eval("(kernel.hang)"));

    const v = try l.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("committed-v1", v);
    const after = try journal.countEntries(gpa, io, tmp.dir);
    try std.testing.expectEqual(before, after);

    l.forceKillImage();
    try waitAlive(&l);
    const v2 = try l.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("committed-v1", v2);
}

test "accept 9: watchdog + in-flight disposition (interpreted)" {
    try accept9(.interpreted);
}
test "accept 9: watchdog + in-flight disposition (compiled)" {
    try accept9(.compiled);
}

// ---------- class 10: inspect

fn accept10(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);
    defer l.deinit();

    {
        const c = try l.eval("(kernel.inspect 'greeting)");
        defer gpa.free(c);
        try std.testing.expect(std.mem.indexOf(u8, c, "(status committed)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "(generation 0)") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "hello, live image") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "(dependents ())") != null);
    }

    try redefine(&l, "shout", "(define (shout) (string-upcase (greeting)))");
    {
        const pd = try l.eval("(kernel.inspect 'shout)");
        defer gpa.free(pd);
        try std.testing.expect(std.mem.indexOf(u8, pd, "(status pending)") != null);
        try std.testing.expect(std.mem.indexOf(u8, pd, "(generation #f)") != null);
        const c2 = try l.eval("(kernel.inspect 'greeting)");
        defer gpa.free(c2);
        try std.testing.expect(std.mem.indexOf(u8, c2, "(dependents (shout))") != null);
    }

    {
        const u = try l.eval("(kernel.inspect 'no-such-binding)");
        defer gpa.free(u);
        try std.testing.expect(std.mem.indexOf(u8, u, "(status unknown)") != null);
        try std.testing.expect(std.mem.indexOf(u8, u, "(source #f)") != null);
        try std.testing.expect(std.mem.indexOf(u8, u, "(generation #f)") != null);
    }
}

test "accept 10: inspect (interpreted)" {
    try accept10(.interpreted);
}
test "accept 10: inspect (compiled)" {
    try accept10(.compiled);
}

// ---------- class 11: ports

const FixtureProvider = struct {
    last_request: ?[]u8 = null,

    fn call(ctx: *anyopaque, request_sexp: []const u8) anyerror![]const u8 {
        const self: *FixtureProvider = @ptrCast(@alignCast(ctx));
        if (self.last_request) |old| gpa.free(old);
        self.last_request = try gpa.dupe(u8, request_sexp);
        return try gpa.dupe(u8, "canned-response");
    }

    fn port(self: *FixtureProvider) ports.ProviderPort {
        return .{ .ctx = self, .call = call };
    }
};

const FixtureTool = struct {
    fn invoke(ctx: *anyopaque, name: []const u8, args_sexp: []const u8) anyerror![]const u8 {
        _ = ctx;
        _ = name;
        _ = args_sexp;
        return try gpa.dupe(u8, "fixture-tool-result");
    }

    fn port(self: *FixtureTool) ports.ToolPort {
        return .{ .ctx = self, .invoke = invoke };
    }
};

fn accept11(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = FixtureProvider{};
    defer if (provider.last_request) |r| gpa.free(r);
    var tool = FixtureTool{};
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{ .provider = provider.port(), .tool = tool.port() }, form);
    defer l.deinit();

    {
        const r = try l.eval("(provider.call \"request-1\")");
        defer gpa.free(r);
        try std.testing.expectEqualStrings("canned-response", r);
        try std.testing.expectEqualStrings("request-1", provider.last_request.?);
    }
    {
        const t = try l.eval("(tool.invoke 'anything \"args\")");
        defer gpa.free(t);
        try std.testing.expectEqualStrings("fixture-tool-result", t);
    }

    // absent ports nack
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var l2: Live = undefined;
    try makeLive(&l2, &tmp2, .{}, form);
    defer l2.deinit();
    try expectImageError(&l2, "(provider.call \"x\")", error.ProtocolError, "PortAbsent");
    try expectImageError(&l2, "(tool.invoke 'fs.read \"x\")", error.ProtocolError, "PortAbsent");

    // H2 single-write append property
    {
        const j = try journalText(&tmp2);
        defer gpa.free(j);
        var it = std.mem.splitScalar(u8, j, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(line[line.len - 1] == ')');
        }
    }

    // shipped fsReadPort wired through Live (containment gated by the
    // ports.zig unit tests)
    var tmp3 = std.testing.tmpDir(.{});
    defer tmp3.cleanup();
    try tmp3.dir.createDirPath(io, "jail");
    try tmp3.dir.writeFile(io, .{ .sub_path = "jail/file.txt", .data = "jailed content" });
    const jail_path = try tmp3.dir.realPathFileAlloc(io, "jail", gpa);
    defer gpa.free(jail_path);
    var frp = try ports.fsReadPort(gpa, io, jail_path);
    defer frp.deinit();
    var l3: Live = undefined;
    try makeLive(&l3, &tmp3, .{ .tool = frp.port() }, form);
    defer l3.deinit();

    {
        const fr = try l3.eval("(tool.invoke 'fs.read \"file.txt\")");
        defer gpa.free(fr);
        try std.testing.expectEqualStrings("jailed content", fr);
    }
    try expectImageError(&l3, "(tool.invoke 'fs.read \"../escape.txt\")", error.ProtocolError, "JailEscape");
}

test "accept 11: ports (interpreted)" {
    try accept11(.interpreted);
}
test "accept 11: ports (compiled)" {
    try accept11(.compiled);
}

// ---------- class 12: build route + identity

test "accept 12: buildImage discovers gsc via gxi; binary boots with self-id; stale/foreign rejected; rebuild byte-size identical" {
    if (!interpretedAvailable()) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l = try Live.init(gpa, io, .{ .state_dir = tmp.dir, .watchdog = fast_watchdog });
    defer l.deinit();
    try l.buildImage();
    try std.testing.expect(stateFileExists(&tmp, "image-bin"));
    const bin_abs = try tmp.dir.realPathFileAlloc(io, "image-bin", gpa);
    defer gpa.free(bin_abs);
    const size1 = (try tmp.dir.statFile(io, "image-bin", .{})).size;

    // built binary boots and answers the handshake
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var l2 = try Live.init(gpa, io, .{
        .state_dir = tmp2.dir,
        .image = .{ .compiled = bin_abs },
        .watchdog = fast_watchdog,
    });
    defer l2.deinit();
    try l2.start();
    const v = try l2.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("hello, live image", v);

    // stale/foreign binary answering the WRONG identity -> ImageUnavailable
    var tmp3 = std.testing.tmpDir(.{});
    defer tmp3.cleanup();
    const wrong_id_abs = try writeForeignBin(&tmp3, "wrong-id", "#!/bin/sh\nprintf '\\016\\000\\000\\000(ok (wrong 0))'\nsleep 5\n");
    defer gpa.free(wrong_id_abs);
    var l3 = try Live.init(gpa, io, .{
        .state_dir = tmp3.dir,
        .image = .{ .compiled = wrong_id_abs },
        .watchdog = fast_watchdog,
    });
    defer l3.deinit();
    try std.testing.expectError(error.ImageUnavailable, l3.start());

    // rebuild: byte-SIZE identical (sha256 reproducibility is a recorded
    // on-host observation, not a gate)
    try l.buildImage();
    const size2 = (try tmp.dir.statFile(io, "image-bin", .{})).size;
    try std.testing.expectEqual(size1, size2);
}

// ---------- class 13: stop discipline

/// Doctored image: answers the self-id handshake once, then ignores
/// everything forever (no quit handling, EOF-immune).
const doctored_stubborn_image: []const u8 =
    \\(define in-port (current-input-port))
    \\(define out-port (current-output-port))
    \\(define (frame-write payload)
    \\  (let* ((bv (string->utf8 payload)) (n (u8vector-length bv)))
    \\    (write-u8 (bitwise-and n #xff) out-port)
    \\    (write-u8 (bitwise-and (arithmetic-shift n -8) #xff) out-port)
    \\    (write-u8 (bitwise-and (arithmetic-shift n -16) #xff) out-port)
    \\    (write-u8 (bitwise-and (arithmetic-shift n -24) #xff) out-port)
    \\    (write-subu8vector bv 0 n out-port)
    \\    (force-output out-port)))
    \\(define (frame-read)
    \\  (let ((b0 (read-u8 in-port)))
    \\    (if (eof-object? b0)
    \\        b0
    \\        (let* ((b1 (read-u8 in-port)) (b2 (read-u8 in-port)) (b3 (read-u8 in-port))
    \\               (len (+ b0 (* b1 256) (* b2 65536) (* b3 16777216)))
    \\               (bv (make-u8vector len)))
    \\          (read-subu8vector bv 0 len in-port)
    \\          (utf8->string bv)))))
    \\;; doctored: answers self-id and apply (so start() passes), then
    \\;; ignores kernel.quit / eval / EOF forever
    \\(let loop ()
    \\  (let ((raw (frame-read)))
    \\    (when (string? raw)
    \\      (cond
    \\        ((equal? raw "(kernel.self-id)") (frame-write "(ok (zag-live 1 gambit))"))
    \\        ((and (> (string-length raw) 13)
    \\              (equal? (substring raw 0 13) "(kernel.apply")) (frame-write "(ok applied)"))
    \\        (else #f))))
    \\  (thread-sleep! 0.05)
    \\  (loop))
    \\
;

fn accept13interpreted() !void {
    if (!interpretedAvailable()) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .watchdog = .{ .probe_interval_ms = 50, .deadline_ms = 300 },
    });
    l.test_image_source = doctored_stubborn_image;
    defer l.deinit();
    try l.start();
    const t0 = Io.Clock.now(.awake, io).nanoseconds;
    try l.stop(); // must SIGKILL after ~300 ms, never hang
    const dt_ms = @divTrunc(Io.Clock.now(.awake, io).nanoseconds - t0, 1_000_000);
    try std.testing.expect(dt_ms >= 250); // the quit frame was given its budget
    try std.testing.expect(dt_ms < 5000); // and then it was killed, bounded
}

fn accept13compiled() !void {
    if (!compiledImageAvailable()) return;
    // build a doctored stubborn binary with gsc directly
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "stubborn.ss", .data = doctored_stubborn_image });
    const gsc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "gxi", "-e", "(display (path-expand \"~~bin/gsc\"))" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(gsc_result.stdout);
    defer gpa.free(gsc_result.stderr);
    const gsc = std.mem.trim(u8, gsc_result.stdout, " \n");
    const build = try std.process.run(gpa, io, .{
        .argv = &.{ gsc, "-exe", "-o", "stubborn-bin", "stubborn.ss" },
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
    });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    try std.testing.expect(build.term == .exited and build.term.exited == 0);

    const stubborn_abs = try tmp.dir.realPathFileAlloc(io, "stubborn-bin", gpa);
    defer gpa.free(stubborn_abs);
    // larger budget: the doctored binary's first spawn is cold-cache slow
    var l = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = .{ .compiled = stubborn_abs },
        .watchdog = .{ .probe_interval_ms = 50, .deadline_ms = 2000 },
    });
    defer l.deinit();
    try l.start();
    const t0 = Io.Clock.now(.awake, io).nanoseconds;
    try l.stop();
    const dt_ms = @divTrunc(Io.Clock.now(.awake, io).nanoseconds - t0, 1_000_000);
    try std.testing.expect(dt_ms >= 1500); // full quit budget elapsed
    try std.testing.expect(dt_ms < 5000); // then SIGKILL, bounded
}

test "accept 13: stop discipline — quit/EOF-ignoring image SIGKILLed after deadline (interpreted)" {
    try accept13interpreted();
}
test "accept 13: stop discipline (compiled)" {
    try accept13compiled();
}

// ---------- class 14: crash discipline

fn accept14(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image: live_mod.ImageSource = switch (form) {
        .interpreted => .{ .interpreted = .{} },
        .compiled => .{ .compiled = shared_image_path.? },
    };
    var l = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = image,
        .watchdog = idle_watchdog,
    });
    l.capture_image_stderr = true;
    defer l.deinit();
    try l.start();

    // sanity
    const v = try l.eval("(+ 1 1)");
    gpa.free(v);

    // Corrupt the stream: huge length header + partial payload + EOF.
    // The image's frame-reader raises; the top-level catcher must report
    // to stderr (bounded) and exit nonzero, with stdout unpolluted.
    const pid = l.child.?.id.?;
    {
        const hdr = [_]u8{ 0xff, 0xff, 0xff, 0x00 }; // ~16 MiB claimed
        try l.child.?.stdin.?.writeStreamingAll(io, &hdr);
        try l.child.?.stdin.?.writeStreamingAll(io, "partial");
        l.child.?.stdin.?.close(io);
        l.child.?.stdin = null;
    }
    // wait for the image to exit (bounded)
    var status: c_int = 0;
    var tries: u32 = 0;
    var reaped = false;
    while (tries < 100) : (tries += 1) {
        const r = std.c.waitpid(pid, &status, 1);
        if (r != 0) {
            reaped = true;
            break;
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
    try std.testing.expect(reaped);
    try std.testing.expect(status & 0x7f == 0); // exited, not signaled
    try std.testing.expect((status >> 8) & 0xff != 0); // nonzero exit code

    // stdout frame stream unpolluted: first post-crash read is clean EOF
    const post = try frame.readFrame(gpa, io, l.child.?.stdout.?);
    try std.testing.expect(post == null);

    // stderr captured, bounded (<= 4 KiB per contract)
    var buf: [8192]u8 = undefined;
    var reader = l.child.?.stderr.?.reader(io, &buf);
    const stderr_text = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
    defer gpa.free(stderr_text);
    try std.testing.expect(stderr_text.len <= 4096);
    try std.testing.expect(stderr_text.len > 0);
}

test "accept 14: crash discipline (interpreted)" {
    try accept14(.interpreted);
}
test "accept 14: crash discipline (compiled)" {
    try accept14(.compiled);
}

// ---------- M2 recovery (carried from zag-live-001 round) ----------

fn acceptRecover(form: SpawnForm) !void {
    if (!formAvailable(form)) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{}, form);

    try expectErr(error.ProtocolError, l.eval("(kernel.redefine 'evil \"(exit)\")"));
    try l.stop();
    l.deinit();

    var l2 = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .image = switch (form) {
            .interpreted => live_mod.ImageSource{ .interpreted = .{} },
            .compiled => live_mod.ImageSource{ .compiled = shared_image_path.? },
        },
        .watchdog = fast_watchdog,
    });
    try std.testing.expectError(error.BootProbeFailed, l2.start());
    try std.testing.expect(l2.needsRecovery());
    const summary = try l2.recover();
    try std.testing.expectEqual(@as(usize, 1), summary.quarantined);
    try std.testing.expect(!l2.needsRecovery());
    defer l2.deinit();
    const v = try l2.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("hello, live image", v);
}

test "recover() revives a bricked state dir (interpreted)" {
    try acceptRecover(.interpreted);
}
test "recover() revives a bricked state dir (compiled)" {
    try acceptRecover(.compiled);
}
