//! Acceptance tests — the 11 classes of docs/modules/zag-live.md §10.
//! Self-contained: fixture provider/tool ports, temp state dirs, no network.

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

const Cfg = struct {
    extra_env: []const live_mod.EnvPair = &.{},
    provider: ?ports.ProviderPort = null,
    tool: ?ports.ToolPort = null,
    watchdog: live_mod.WatchdogConfig = fast_watchdog,
};

fn makeLive(l: *Live, tmp: *std.testing.TmpDir, cfg: Cfg) !void {
    l.* = try Live.init(gpa, io, .{
        .state_dir = tmp.dir,
        .extra_env = cfg.extra_env,
        .provider_port = cfg.provider,
        .tool_port = cfg.tool,
        .watchdog = cfg.watchdog,
    });
    errdefer l.deinit();
    try l.start();
}

/// Wait until a killed image is back (watchdog or inline restart).
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

/// The eval must fail with want, and the recorded image error must contain
/// the given atom.
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

// ---------- class 1: boot + boot probe + version floor + ChezUnavailable

test "accept 1: boot + boot probe + version floor + ChezUnavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
    defer l.deinit();
    const v = try l.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("hello, live image", v);

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var bad = try Live.init(gpa, io, .{
        .state_dir = tmp2.dir,
        .chez_path = "/nonexistent/chez-bin",
        .watchdog = fast_watchdog,
    });
    defer bad.deinit();
    try std.testing.expectError(error.ChezUnavailable, bad.start());
    // version floor: unit coverage lives in live.zig ("version floor")
}

// ---------- class 2: child env scrub (spike env-check parity)

test "accept 2: child env scrub (allowlist + extra_env only)" {
    _ = setenv("ZAGLIVE_TEST_SECRET_KEY", "sk-not-real", 1);
    _ = setenv("ZAGLIVE_TEST_TOKEN", "tok-not-real", 1);
    defer {
        _ = unsetenv("ZAGLIVE_TEST_SECRET_KEY");
        _ = unsetenv("ZAGLIVE_TEST_TOKEN");
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{ .extra_env = &.{.{ .name = "ZAGLIVE_EXTRA", .value = "extra-value" }} });
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

// ---------- class 3: echo 10k frames, zero framing errors

test "accept 3: echo 10k frames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
    defer l.deinit();
    for (0..10_000) |i| {
        const payload = try std.fmt.allocPrint(gpa, "msg-{d}-{d}", .{ i, i *% 7919 });
        defer gpa.free(payload);
        const v = try l.echo(payload);
        defer gpa.free(v);
        try std.testing.expectEqualStrings(payload, v);
    }
}

// ---------- class 4: escaping fuzz, >=1000 adversarial byte-identical

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

test "accept 4: escaping fuzz 1500 adversarial strings byte-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
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
}

// ---------- class 5: frame cap both sides

test "accept 5: frame cap enforced both directions, image survives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    // idle watchdog: the raw-frame read below is deliberately unsynchronized
    try makeLive(&l, &tmp, .{ .watchdog = idle_watchdog });
    defer l.deinit();

    const big = try gpa.alloc(u8, frame.max_frame_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'a');

    // host -> image: local rejection before send; image untouched
    try expectErr(error.FrameTooLarge, l.echo(big));

    // host -> image: image-side rejection via the uncapped test seam
    try l.sendRawFrameUnchecked(big);
    const reply = (try frame.readFrame(gpa, io, l.child.?.stdout.?)).?;
    defer gpa.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "frame-too-large") != null);

    // image still alive after both rejections
    const v = try l.eval("(+ 1 1)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("2", v);

    // image -> host: oversize reply rejected; host kills + respawns and
    // keeps working
    try expectErr(error.FrameTooLarge, l.eval("(make-string 5000000 #\\a)"));
    const v2 = try l.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("hello, live image", v2);
}

// ---------- class 6: redefine -> SIGKILL -> replay, identical source/value

test "accept 6: redefine -> SIGKILL -> replay restores identical source/value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
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

// ---------- class 7: discard / nack

test "accept 7: discard restores committed; unknown name nacked, image alive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
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

// ---------- class 8: commit paths (staged flip, failure dispositions, G4)

test "accept 8: commit probe + staged flip + failure dispositions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
    defer l.deinit();

    // success path, caller-supplied check
    try redefine(&l, "greeting", "(define (greeting) \"committed-v1\")");
    {
        const ok = try l.eval("(kernel.commit \"to-v1\" \"(greeting)\" \"committed-v1\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 1), try readCurrentFile(&tmp));

    // success path, default recorded check (bindings resolve)
    try redefine(&l, "extra", "(define (extra) 99)");
    {
        const ok = try l.eval("(kernel.commit \"add-extra\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));

    // value-mismatch failure: quarantine (suspect), no orphan dir, image
    // keeps the change exploratory-live, next restart shows committed state
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
        try std.testing.expectEqualStrings("broken", live_val); // stays exploratory-live
    }
    l.forceKillImage();
    try waitAlive(&l);
    {
        const restored = try l.eval("(greeting)");
        defer gpa.free(restored);
        try std.testing.expectEqualStrings("committed-v1", restored); // excluded from replay
    }

    // check-eval-ERROR failure (not just mismatch): quarantined too (F9)
    try redefine(&l, "greeting", "(define (greeting) \"broken-again\")");
    try expectImageError(&l, "(kernel.commit \"bad2\" \"(car 1)\" \"#t\")", error.ProtocolError, "CommitRejected");
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));

    // G4: clean-process INFRA failure retries once, then CommitUnavailable,
    // pending set intact (no suspect for it); a later commit may retry.
    // M1a: forge a spawn-stage failure that is NOT FileNotFound.
    try redefine(&l, "greeting", "(define (greeting) \"v3\")");
    l.fail_clean_spawn = error.SystemResources;
    try expectImageError(&l, "(kernel.commit \"v3\")", error.ProtocolError, "CommitUnavailable");
    try std.testing.expectEqual(@as(u32, 2), try readCurrentFile(&tmp));
    {
        const j = try journalText(&tmp);
        defer gpa.free(j);
        // the v3 redefine must NOT be quarantined
        try std.testing.expect(std.mem.indexOf(u8, j, "(define (greeting) \\\"v3\\\")") != null);
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

    // empty pending set
    try expectImageError(&l, "(kernel.commit \"empty\")", error.ProtocolError, "NothingToCommit");
}

// ---------- class 9: watchdog kill -> reload + in-flight disposition

test "accept 9: in-flight hang fails once with ImageRestarted; reload committed; no dup side effect" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
    defer l.deinit();

    try redefine(&l, "greeting", "(define (greeting) \"committed-v1\")");
    {
        const ok = try l.eval("(kernel.commit \"v1\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    const before = try journal.countEntries(gpa, io, tmp.dir);

    // in-flight request against a hung image: fails ONCE with ImageRestarted
    try expectErr(error.ImageRestarted, l.eval("(kernel.hang)"));

    // image killed + reloaded from committed generation; journal intact
    const v = try l.eval("(greeting)");
    defer gpa.free(v);
    try std.testing.expectEqualStrings("committed-v1", v);
    const after = try journal.countEntries(gpa, io, tmp.dir);
    try std.testing.expectEqual(before, after); // no duplicate side effect

    // idle death: watchdog thread detects and reloads on its own
    l.forceKillImage();
    try waitAlive(&l);
    const v2 = try l.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("committed-v1", v2);
}

// ---------- class 10: inspect

test "accept 10: inspect committed / pending / unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
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

test "accept 11: provider/tool ports; absent port nacks; H2 single-write; fsReadPort via Live" {
    // fixture ports
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = FixtureProvider{};
    defer if (provider.last_request) |r| gpa.free(r);
    var tool = FixtureTool{};
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{ .provider = provider.port(), .tool = tool.port() });
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
    try makeLive(&l2, &tmp2, .{});
    defer l2.deinit();
    try expectImageError(&l2, "(provider.call \"x\")", error.ProtocolError, "PortAbsent");
    try expectImageError(&l2, "(tool.invoke 'fs.read \"x\")", error.ProtocolError, "PortAbsent");

    // H2 single-write append property: every journal entry is one complete
    // typed line (no entry/newline split artifacts)
    {
        const j = try journalText(&tmp2);
        defer gpa.free(j);
        var it = std.mem.splitScalar(u8, j, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(line[line.len - 1] == ')');
        }
    }

    // shipped fsReadPort wired through Live as the tool port (containment
    // itself is gated by the ports.zig unit tests: dirfd walk, .., absolute,
    // symlink, 16 KiB bound — H3)
    var tmp3 = std.testing.tmpDir(.{});
    defer tmp3.cleanup();
    try tmp3.dir.createDirPath(io, "jail");
    try tmp3.dir.writeFile(io, .{ .sub_path = "jail/file.txt", .data = "jailed content" });
    const jail_path = try tmp3.dir.realPathFileAlloc(io, "jail", gpa);
    defer gpa.free(jail_path);
    var frp = try ports.fsReadPort(gpa, io, jail_path);
    defer frp.deinit();
    var l3: Live = undefined;
    try makeLive(&l3, &tmp3, .{ .tool = frp.port() });
    defer l3.deinit();

    {
        const fr = try l3.eval("(tool.invoke 'fs.read \"file.txt\")");
        defer gpa.free(fr);
        try std.testing.expectEqualStrings("jailed content", fr);
    }
    try expectImageError(&l3, "(tool.invoke 'fs.read \"../escape.txt\")", error.ProtocolError, "JailEscape");
}

// ---------- M1 edges: spawn-stage vs post-spawn failure classification

test "accept 8 edges (M1): any spawn-stage failure is infra; post-spawn replay death is a defect" {
    // (a) spawn-stage failure, NOT FileNotFound: retry once -> CommitUnavailable,
    //     innocent pending set NOT quarantined.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});
    defer l.deinit();
    try redefine(&l, "greeting", "(define (greeting) \"innocent\")");
    l.fail_clean_spawn = error.SystemResources;
    try expectImageError(&l, "(kernel.commit \"edge-a\")", error.ProtocolError, "CommitUnavailable");
    try std.testing.expectEqual(@as(u32, 0), try readCurrentFile(&tmp));
    {
        const j = try journalText(&tmp);
        defer gpa.free(j);
        try std.testing.expect(std.mem.indexOf(u8, j, "(suspect greeting") == null);
        try std.testing.expect(std.mem.indexOf(u8, j, "(redefine greeting") != null);
    }
    l.fail_clean_spawn = null;
    {
        const ok = try l.eval("(kernel.commit \"edge-a-retry\")");
        defer gpa.free(ok);
        try std.testing.expectEqualStrings("#t", ok);
    }
    try std.testing.expectEqual(@as(u32, 1), try readCurrentFile(&tmp));

    // (b) post-spawn replay death caused by the change itself: a pending
    //     entry that kills the clean probe image during apply. Written
    //     journal-side (simulating a torn state: journaled, live apply
    //     crashed) so the LIVE image stays up.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var l2: Live = undefined;
    try makeLive(&l2, &tmp2, .{});
    defer l2.deinit();
    try journal.appendRedefine(gpa, io, tmp2.dir, "evil", "(exit)");
    try expectImageError(&l2, "(kernel.commit \"doomed\")", error.ProtocolError, "CommitRejected");
    {
        const j = try journalText(&tmp2);
        defer gpa.free(j);
        try std.testing.expect(std.mem.indexOf(u8, j, "(suspect evil ") != null); // quarantined (M1b)
    }
    try std.testing.expectEqual(@as(u32, 0), try readCurrentFile(&tmp2));
    try std.testing.expect(!stateFileExists(&tmp2, "generations/1"));
    try std.testing.expect(!stateFileExists(&tmp2, "generations/.staging-1"));
    // live image unaffected by the probe death
    {
        const alive = try l2.eval("(+ 1 1)");
        defer gpa.free(alive);
        try std.testing.expectEqualStrings("2", alive);
    }
}

// ---------- M2: recover() revives a replay-fatal bricked state dir

test "recover(): quarantine-all + restart revives a bricked state dir (M2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Live = undefined;
    try makeLive(&l, &tmp, .{});

    // Brick it exactly as the verifier demonstrated: the redefine is
    // journaled (fsync first), then the live image dies applying (exit).
    try expectErr(error.ProtocolError, l.eval("(kernel.redefine 'evil \"(exit)\")"));
    try l.stop();
    l.deinit();

    // Plain start on the bricked dir: replay dies -> BootProbeFailed,
    // with the recovery hint latched.
    var l2 = try Live.init(gpa, io, .{ .state_dir = tmp.dir, .watchdog = fast_watchdog });
    try std.testing.expectError(error.BootProbeFailed, l2.start());
    try std.testing.expect(l2.needsRecovery());

    // recover() quarantines the fatal pending entry and revives.
    const summary = try l2.recover();
    try std.testing.expectEqual(@as(usize, 1), summary.quarantined);
    try std.testing.expect(!l2.needsRecovery());
    defer l2.deinit();
    {
        const v = try l2.eval("(greeting)");
        defer gpa.free(v);
        try std.testing.expectEqualStrings("hello, live image", v); // committed genesis
        const j = try journalText(&tmp);
        defer gpa.free(j);
        try std.testing.expect(std.mem.indexOf(u8, j, "(suspect evil ") != null);
    }
    // and the revived instance survives a kill/reload cycle too
    l2.forceKillImage();
    try waitAlive(&l2);
    const v2 = try l2.eval("(greeting)");
    defer gpa.free(v2);
    try std.testing.expectEqualStrings("hello, live image", v2);
}
