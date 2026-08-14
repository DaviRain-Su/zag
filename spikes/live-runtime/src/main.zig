//! live-probe — Zig supervisor spike: drive a Chez Scheme subprocess through
//! a full live-self-modification cycle (redefine -> journal -> SIGKILL ->
//! replay -> discard/commit), plus boot/echo measurements, a watchdog path,
//! and env-scrub verification. See README.md for the framing format.
//!
//! Must be run from the spike directory (uses relative paths: runtime.ss,
//! .work/). Keep it stupidly simple: this is a measurement probe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const runtime_path = "runtime.ss";
const journal_path = ".work/journal.sexp";
const current_path = ".work/current";
const current_tmp_path = ".work/current.tmp";
const gens_path = ".work/generations";
/// Max frame payload, BOTH directions. Must match max-frame-bytes in
/// runtime.ss. Oversize inbound frames are rejected: probes treat them as
/// image misbehavior (kill + respawn).
pub const max_frame_bytes: u32 = 4 * 1024 * 1024;
const max_file: usize = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return usage(init.io);
    var p: Probe = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
    };
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "boot")) {
        try cmdBoot(&p);
    } else if (std.mem.eql(u8, cmd, "echo")) {
        const n: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 10000;
        try cmdEcho(&p, n);
    } else if (std.mem.eql(u8, cmd, "redefine-cycle")) {
        try cmdRedefineCycle(&p);
    } else if (std.mem.eql(u8, cmd, "discard")) {
        try cmdDiscard(&p);
    } else if (std.mem.eql(u8, cmd, "commit")) {
        try cmdCommit(&p);
    } else if (std.mem.eql(u8, cmd, "watchdog")) {
        try cmdWatchdog(&p);
    } else if (std.mem.eql(u8, cmd, "env-check")) {
        try cmdEnvCheck(&p);
    } else if (std.mem.eql(u8, cmd, "fuzz")) {
        try cmdFuzz(&p);
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        try cmdInspect(&p);
    } else if (std.mem.eql(u8, cmd, "agent")) {
        try cmdAgent(&p);
    } else if (std.mem.eql(u8, cmd, "interactive") or std.mem.eql(u8, cmd, "demo")) {
        try cmdInteractive(&p);
    } else if (std.mem.eql(u8, cmd, "reset")) {
        try cmdReset(&p);
    } else {
        return usage(init.io);
    }
}

fn usage(io: Io) !void {
    std.Io.File.stderr().writeStreamingAll(io, "usage: live-probe <boot|echo [n]|redefine-cycle|discard|commit|watchdog|env-check|fuzz|inspect|agent|interactive|demo|reset>\n") catch {};
    return error.Usage;
}

// ---------- probe context / output ----------

const Probe = struct {
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
};

fn say(p: *const Probe, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(p.gpa, fmt, args) catch return;
    defer p.gpa.free(s);
    std.Io.File.stdout().writeStreamingAll(p.io, s) catch {};
    std.Io.File.stdout().writeStreamingAll(p.io, "\n") catch {};
}

fn nowAwake(p: *const Probe) i96 {
    return Io.Clock.now(.awake, p.io).nanoseconds;
}

fn nowReal(p: *const Probe) i96 {
    return Io.Clock.now(.real, p.io).nanoseconds;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1.0e6;
}

// ---------- framing ----------
//
// 4-byte little-endian u32 length + UTF-8 payload. Payload is one
// s-expression, single line. Strings are Scheme-`write` escaped.

fn sendFrame(p: *Probe, sc: *Scheme, payload: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .little);
    try sc.child.stdin.?.writeStreamingAll(p.io, &hdr);
    try sc.child.stdin.?.writeStreamingAll(p.io, payload);
}

fn readExact(io: Io, file: Io.File, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = file.readStreaming(io, &.{buf[off..]}) catch |e| switch (e) {
            error.EndOfStream => return error.Eof,
            else => return e,
        };
        if (n == 0) return error.Eof;
        off += n;
    }
}

/// Returns null on clean EOF at a frame boundary.
fn readFrame(gpa: Allocator, io: Io, file: Io.File) !?[]u8 {
    var hdr: [4]u8 = undefined;
    readExact(io, file, &hdr) catch |e| switch (e) {
        error.Eof => return null,
        else => return e,
    };
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > max_frame_bytes) return error.FrameTooLarge;
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    try readExact(io, file, buf);
    return buf;
}

/// Returns null when the deadline expires before any frame byte arrives.
fn readFrameTimeout(gpa: Allocator, io: Io, file: Io.File, timeout_ms: i32) !?[]u8 {
    var fds = [_]std.posix.pollfd{
        .{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const n = try std.posix.poll(&fds, timeout_ms);
    if (n == 0) return null;
    return try readFrame(gpa, io, file);
}

// ---------- scheme string escaping ----------
//
// ONE discipline both ways: canonical Chez `write` escapes.
//   \" \\ \n \r \t \a \b \v \f   named escapes
//   \xHH;                       any other byte < 0x20 or 0x7F, uppercase
//                               minimal hex, semicolon-terminated
//   bytes >= 0x80               raw (payloads must be valid UTF-8)
// Decoding is strict: an unknown escape is an error, never silently
// mangled. This makes arbitrary control bytes (incl. NUL), quotes,
// backslashes, literal `\x..;` text, and UTF-8 round-trip byte-identically.

fn escapeSchemeString(gpa: Allocator, s: []const u8) ![]u8 {
    const hexdig = "0123456789ABCDEF";
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '"' => try list.appendSlice(gpa, "\\\""),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            0x07 => try list.appendSlice(gpa, "\\a"),
            0x08 => try list.appendSlice(gpa, "\\b"),
            0x0b => try list.appendSlice(gpa, "\\v"),
            0x0c => try list.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try list.appendSlice(gpa, "\\x");
                    if (c >= 0x10) try list.append(gpa, hexdig[c >> 4]);
                    try list.append(gpa, hexdig[c & 0xf]);
                    try list.append(gpa, ';');
                } else {
                    try list.append(gpa, c);
                }
            },
        }
    }
    return list.toOwnedSlice(gpa);
}

const ParsedString = struct { value: []u8, end: usize };

/// Parse a `"..."` Scheme string literal starting at s[start]; returns the
/// unescaped value and the index just past the closing quote. Strict:
/// unknown escapes and malformed \x..; are errors.
fn parseSchemeString(gpa: Allocator, s: []const u8, start: usize) !ParsedString {
    if (start >= s.len or s[start] != '"') return error.ExpectedString;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var i = start + 1;
    while (true) {
        if (i >= s.len) return error.UnterminatedString;
        const c = s[i];
        if (c == '"') return .{ .value = try list.toOwnedSlice(gpa), .end = i + 1 };
        if (c != '\\') {
            try list.append(gpa, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) return error.UnterminatedString;
        switch (s[i]) {
            'n' => try list.append(gpa, '\n'),
            't' => try list.append(gpa, '\t'),
            'r' => try list.append(gpa, '\r'),
            'a' => try list.append(gpa, 0x07),
            'b' => try list.append(gpa, 0x08),
            'v' => try list.append(gpa, 0x0b),
            'f' => try list.append(gpa, 0x0c),
            '\\' => try list.append(gpa, '\\'),
            '"' => try list.append(gpa, '"'),
            'x' => {
                // \xHH; — hex codepoint, semicolon-terminated.
                i += 1;
                var cp: u21 = 0;
                var digits: usize = 0;
                while (i < s.len and s[i] != ';') : (i += 1) {
                    const d = std.fmt.charToDigit(s[i], 16) catch
                        return error.BadHexEscape;
                    cp = std.math.mul(u21, cp, 16) catch return error.BadHexEscape;
                    cp = std.math.add(u21, cp, d) catch return error.BadHexEscape;
                    digits += 1;
                }
                if (i >= s.len or digits == 0) return error.BadHexEscape;
                var ubuf: [4]u8 = undefined;
                const ulen = std.unicode.utf8Encode(cp, &ubuf) catch
                    return error.BadHexEscape;
                try list.appendSlice(gpa, ubuf[0..ulen]);
            },
            else => return error.UnknownEscape,
        }
        i += 1;
    }
}

fn skipSpaces(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

fn readToken(s: []const u8, start: usize) struct { tok: []const u8, end: usize } {
    var i = start;
    while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != ')' and s[i] != '(') i += 1;
    return .{ .tok = s[start..i], .end = i };
}

/// Extract the datum from `(ok <datum>)` / `(err <datum>)`: a string literal
/// (unescaped) or the raw text up to (but excluding) the frame's own final
/// `)`. The trim strips exactly ONE closing paren — the datum itself may be
/// a list whose parens must survive.
fn parseDatum(gpa: Allocator, frame: []const u8, start: usize) ![]u8 {
    const i = skipSpaces(frame, start);
    if (i < frame.len and frame[i] == '"') {
        const ps = try parseSchemeString(gpa, frame, i);
        return ps.value;
    }
    var end = frame.len;
    while (end > i and frame[end - 1] == ' ') end -= 1;
    if (end > i and frame[end - 1] == ')') end -= 1;
    while (end > i and frame[end - 1] == ' ') end -= 1;
    return try gpa.dupe(u8, frame[i..end]);
}

// ---------- replies and kernel requests ----------

const Reply = union(enum) { ok: []u8, err: []u8 };

fn parseReply(gpa: Allocator, frame: []const u8) !?Reply {
    if (std.mem.startsWith(u8, frame, "(ok ") or std.mem.eql(u8, frame, "(ok)")) {
        if (frame.len <= 3) return Reply{ .ok = try gpa.dupe(u8, "") };
        return Reply{ .ok = try parseDatum(gpa, frame, 3) };
    }
    if (std.mem.startsWith(u8, frame, "(err ")) {
        return Reply{ .err = try parseDatum(gpa, frame, 4) };
    }
    return null;
}

const KernelReq = union(enum) {
    redefine: struct { name: []u8, source: []u8 },
    discard: []u8,
    commit: struct { check: []u8, expected: []u8 },
    inspect: []u8,
    provider_call: struct { sp: []u8, history: []u8 },
    tool_invoke: struct { tool: []u8, path: []u8 },
    conv_append: struct { kind: []u8, rest: []u8 },
    conv_history,
};

fn parseKernelReq(gpa: Allocator, frame: []const u8) !?KernelReq {
    if (std.mem.eql(u8, frame, "(conv.history)")) return KernelReq.conv_history;
    if (std.mem.startsWith(u8, frame, "(provider.call ")) {
        var i: usize = "(provider.call ".len;
        const sp = try parseSchemeString(gpa, frame, i);
        errdefer gpa.free(sp.value);
        i = skipSpaces(frame, sp.end);
        const hist = try parseSchemeString(gpa, frame, i);
        return KernelReq{ .provider_call = .{ .sp = sp.value, .history = hist.value } };
    }
    if (std.mem.startsWith(u8, frame, "(tool.invoke ")) {
        var i: usize = "(tool.invoke ".len;
        const t = readToken(frame, i);
        i = skipSpaces(frame, t.end);
        const path = try parseSchemeString(gpa, frame, i);
        return KernelReq{ .tool_invoke = .{ .tool = try gpa.dupe(u8, t.tok), .path = path.value } };
    }
    if (std.mem.startsWith(u8, frame, "(conv.append ")) {
        var i: usize = "(conv.append ".len;
        const t = readToken(frame, i);
        i = skipSpaces(frame, t.end);
        var end = frame.len;
        while (end > i and (frame[end - 1] == ')' or frame[end - 1] == ' ')) end -= 1;
        return KernelReq{ .conv_append = .{
            .kind = try gpa.dupe(u8, t.tok),
            .rest = try gpa.dupe(u8, frame[i..end]),
        } };
    }
    if (std.mem.startsWith(u8, frame, "(kernel.inspect ")) {
        const i: usize = "(kernel.inspect ".len;
        const t = readToken(frame, i);
        return KernelReq{ .inspect = try gpa.dupe(u8, t.tok) };
    }
    if (std.mem.startsWith(u8, frame, "(kernel.redefine ")) {
        var i: usize = "(kernel.redefine ".len;
        const t = readToken(frame, i);
        i = skipSpaces(frame, t.end);
        const ps = try parseSchemeString(gpa, frame, i);
        return KernelReq{ .redefine = .{
            .name = try gpa.dupe(u8, t.tok),
            .source = ps.value,
        } };
    }
    if (std.mem.startsWith(u8, frame, "(kernel.discard ")) {
        const i: usize = "(kernel.discard ".len;
        const t = readToken(frame, i);
        return KernelReq{ .discard = try gpa.dupe(u8, t.tok) };
    }
    if (std.mem.startsWith(u8, frame, "(kernel.commit ")) {
        var i: usize = "(kernel.commit ".len;
        const c = try parseSchemeString(gpa, frame, i);
        i = skipSpaces(frame, c.end);
        const e = try parseSchemeString(gpa, frame, i);
        return KernelReq{ .commit = .{ .check = c.value, .expected = e.value } };
    }
    return null;
}

// ---------- scheme child ----------

const Scheme = struct {
    child: std.process.Child,

    /// Spawn chez with a scrubbed, allowlist-only environment. Secrets in the
    /// supervisor's own environment never reach the child.
    fn spawn(p: *Probe) !Scheme {
        var env = std.process.Environ.Map.init(p.gpa);
        defer env.deinit();
        for ([_][]const u8{ "PATH", "HOME", "TERM" }) |k| {
            if (p.environ.get(k)) |v| try env.put(k, v);
        }
        const child = try std.process.spawn(p.io, .{
            .argv = &.{ "chez", "--script", runtime_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .environ_map = &env,
        });
        return .{ .child = child };
    }

    fn kill(sc: *Scheme, p: *Probe) void {
        sc.child.kill(p.io);
    }

    /// Polite shutdown: close stdin; the script's main loop hits EOF and exits.
    fn shutdown(sc: *Scheme, p: *Probe) void {
        if (sc.child.stdin) |f| {
            f.close(p.io);
            sc.child.stdin = null;
        }
        _ = sc.child.wait(p.io) catch {};
    }
};

/// Send (kernel.eval "<source>") and return the raw reply, servicing any
/// nested kernel.* requests the image raises while evaluating.
fn requestEvalReply(p: *Probe, sc: *Scheme, source: []const u8) !Reply {
    const esc = try escapeSchemeString(p.gpa, source);
    defer p.gpa.free(esc);
    const frame = try std.fmt.allocPrint(p.gpa, "(kernel.eval \"{s}\")", .{esc});
    defer p.gpa.free(frame);
    try sendFrame(p, sc, frame);
    return waitReply(p, sc);
}

/// Send (kernel.eval "<source>") and wait for the ok datum.
fn requestEval(p: *Probe, sc: *Scheme, source: []const u8) ![]u8 {
    const r = try requestEvalReply(p, sc, source);
    switch (r) {
        .ok => |v| return v,
        .err => |msg| {
            say(p, "scheme error: {s}", .{msg});
            p.gpa.free(msg);
            return error.SchemeError;
        },
    }
}

/// Send (kernel.apply "<source>") and require (ok applied).
fn requestApply(p: *Probe, sc: *Scheme, source: []const u8) !void {
    const esc = try escapeSchemeString(p.gpa, source);
    defer p.gpa.free(esc);
    const frame = try std.fmt.allocPrint(p.gpa, "(kernel.apply \"{s}\")", .{esc});
    defer p.gpa.free(frame);
    try sendFrame(p, sc, frame);
    const r = try waitReply(p, sc);
    switch (r) {
        .ok => |v| p.gpa.free(v),
        .err => |msg| {
            say(p, "scheme error: {s}", .{msg});
            p.gpa.free(msg);
            return error.SchemeError;
        },
    }
}

fn waitReply(p: *Probe, sc: *Scheme) anyerror!Reply {
    const raw = try waitReplyRaw(p, sc);
    defer p.gpa.free(raw);
    return (try parseReply(p.gpa, raw)).?;
}

/// Read frames until a reply ((ok ...) / (err ...)) arrives, servicing any
/// nested kernel.* requests in between. Returns the raw reply frame.
fn waitReplyRaw(p: *Probe, sc: *Scheme) anyerror![]u8 {
    while (true) {
        const raw = (try readFrame(p.gpa, p.io, sc.child.stdout.?)) orelse
            return error.ChildClosedPipe;
        errdefer p.gpa.free(raw);
        if (isReplyFrame(raw)) return raw;
        if (try parseKernelReq(p.gpa, raw)) |req| {
            p.gpa.free(raw);
            try handleKernelReq(p, sc, req);
            continue;
        }
        say(p, "bad frame from child: {s}", .{raw});
        return error.BadFrame;
    }
}

fn isReplyFrame(frame: []const u8) bool {
    return std.mem.startsWith(u8, frame, "(ok ") or
        std.mem.startsWith(u8, frame, "(err ") or
        std.mem.eql(u8, frame, "(ok)");
}

// ---------- eval with captured output (interactive mode) ----------

const EvalC = struct { datum: []u8, output: []u8 };
const EvalCResult = union(enum) { ok: EvalC, err: []u8 };

/// Send (kernel.evalc "<source>"): like requestEvalReply but the ok reply is
/// (ok "<datum-as-written>" "<captured-output>") — both string literals.
fn requestEvalC(p: *Probe, sc: *Scheme, source: []const u8) !EvalCResult {
    const esc = try escapeSchemeString(p.gpa, source);
    defer p.gpa.free(esc);
    const frame = try std.fmt.allocPrint(p.gpa, "(kernel.evalc \"{s}\")", .{esc});
    defer p.gpa.free(frame);
    try sendFrame(p, sc, frame);
    const raw = try waitReplyRaw(p, sc);
    defer p.gpa.free(raw);
    if (std.mem.startsWith(u8, raw, "(err ")) {
        return EvalCResult{ .err = try parseDatum(p.gpa, raw, 4) };
    }
    if (!std.mem.startsWith(u8, raw, "(ok ")) return error.BadFrame;
    const d = try parseSchemeString(p.gpa, raw, 4);
    errdefer p.gpa.free(d.value);
    const o = try parseSchemeString(p.gpa, raw, skipSpaces(raw, d.end));
    return EvalCResult{ .ok = .{ .datum = d.value, .output = o.value } };
}

/// Shared discard mechanics: if NAME has a committed definition, journal
/// the discard and re-apply the committed source in the image; returns
/// false (nothing journaled) when NAME was never committed.
fn applyCommittedDiscard(p: *Probe, sc: *Scheme, name: []const u8) !bool {
    const src = (try committedSource(p, name)) orelse return false;
    defer p.gpa.free(src);
    try journalDiscard(p, name);
    try requestApply(p, sc, src);
    return true;
}

fn handleKernelReq(p: *Probe, sc: *Scheme, req: KernelReq) !void {
    switch (req) {
        .redefine => |rd| {
            defer p.gpa.free(rd.name);
            defer p.gpa.free(rd.source);
            // Journal + fsync BEFORE the change is applied inside Scheme.
            try journalRedefine(p, rd.name, rd.source);
            // Now tell the image to actually eval the new definition.
            try requestApply(p, sc, rd.source);
            const ack = try std.fmt.allocPrint(p.gpa, "(kernel.ack {s})", .{rd.name});
            defer p.gpa.free(ack);
            try sendFrame(p, sc, ack);
        },
        .discard => |name| {
            defer p.gpa.free(name);
            // Unknown/uncommitted name gets a nack (no journal entry,
            // nothing to reverse) so the image raises a readable condition
            // instead of hanging in kernel-wait.
            if (!try applyCommittedDiscard(p, sc, name)) {
                say(p, "discard: '{s}' has no committed definition; nacking", .{name});
                const nack = try std.fmt.allocPrint(p.gpa, "(kernel.nack {s} \"not-committed\")", .{name});
                defer p.gpa.free(nack);
                try sendFrame(p, sc, nack);
                return;
            }
            const ack = try std.fmt.allocPrint(p.gpa, "(kernel.ack {s})", .{name});
            defer p.gpa.free(ack);
            try sendFrame(p, sc, ack);
        },
        .commit => |c| {
            defer p.gpa.free(c.check);
            defer p.gpa.free(c.expected);
            doCommit(p, c.check, c.expected) catch |e| {
                say(p, "commit rejected, keeping old generation; exploratory change is suspect: {s}", .{@errorName(e)});
                try sendFrame(p, sc, "(kernel.err \"commit-rejected\")");
                return;
            };
            try sendFrame(p, sc, "(kernel.ack committed)");
        },
        .inspect => |name| {
            defer p.gpa.free(name);
            const reply = try composeInspect(p, name);
            defer p.gpa.free(reply);
            try sendFrame(p, sc, reply);
        },
        .conv_append => |ca| {
            defer p.gpa.free(ca.kind);
            defer p.gpa.free(ca.rest);
            try convHandleAppend(p, ca.kind, ca.rest);
            try sendFrame(p, sc, "(kernel.ack conv)");
        },
        .conv_history => {
            const reply = try convHistoryFrame(p);
            defer p.gpa.free(reply);
            try sendFrame(p, sc, reply);
        },
        .provider_call => |pc| {
            defer p.gpa.free(pc.sp);
            defer p.gpa.free(pc.history);
            const reply = try providerReply(p, pc.sp);
            defer p.gpa.free(reply);
            try sendFrame(p, sc, reply);
        },
        .tool_invoke => |ti| {
            defer p.gpa.free(ti.tool);
            defer p.gpa.free(ti.path);
            const reply = try toolInvoke(p, ti.tool, ti.path);
            defer p.gpa.free(reply);
            try sendFrame(p, sc, reply);
        },
    }
}

// ---------- journal (append-only, fsync before apply) ----------
//
// Typed schema (one file, replay = fold over typed entries):
//   (redefine <name> <seq> "<source>" <ts>)   pending change
//   (discard  <name> <seq> <ts>)              removes matching pending redefine
//   (suspect  <name> <seq> <ts>)              quarantined by failed commit
//   (commit   <gen> "<hash>" <ts>)            generation flip recorded
// <seq> is the entry's 0-based line number; <ts> is realtime nanoseconds.

fn journalAppend(p: *Probe, entry: []const u8) !void {
    // O_APPEND semantics + fsync before returning; 0.16 has no posix.open,
    // so wrap the raw fd in an Io.File for writes/sync.
    const fd = try std.posix.openat(std.posix.AT.FDCWD, journal_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);
    var f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer f.close(p.io);
    try f.writeStreamingAll(p.io, entry);
    try f.writeStreamingAll(p.io, "\n");
    try f.sync(p.io);
}

fn journalSeq(p: *Probe) !usize {
    return countJournalLines(p);
}

fn journalRedefine(p: *Probe, name: []const u8, source: []const u8) !void {
    const esc = try escapeSchemeString(p.gpa, source);
    defer p.gpa.free(esc);
    const entry = try std.fmt.allocPrint(p.gpa, "(redefine {s} {d} \"{s}\" {d})", .{ name, try journalSeq(p), esc, nowReal(p) });
    defer p.gpa.free(entry);
    try journalAppend(p, entry);
}

fn journalDiscard(p: *Probe, name: []const u8) !void {
    const entry = try std.fmt.allocPrint(p.gpa, "(discard {s} {d} {d})", .{ name, try journalSeq(p), nowReal(p) });
    defer p.gpa.free(entry);
    try journalAppend(p, entry);
}

/// Quarantine the pending redefines of a failed commit: journal a
/// `(suspect <name> <seq> <ts>)` marker per entry so replay skips them.
fn journalSuspect(p: *Probe, pend: []const Redef) !void {
    for (pend) |r| {
        const entry = try std.fmt.allocPrint(p.gpa, "(suspect {s} {d} {d})", .{ r.name, try journalSeq(p), nowReal(p) });
        defer p.gpa.free(entry);
        try journalAppend(p, entry);
        say(p, "journaled (suspect {s} ...)", .{r.name});
    }
}

const Redef = struct { name: []u8, source: []u8 };

/// Journal redefines since the last commit, dropping any canceled by a later
/// discard or quarantined by a `(suspect ...)` marker (failed commit probe).
/// This is the pending (uncommitted) mutation set.
fn journalPendingRedefs(p: *Probe) ![]Redef {
    var list: std.ArrayList(Redef) = .empty;
    errdefer {
        for (list.items) |r| {
            p.gpa.free(r.name);
            p.gpa.free(r.source);
        }
        list.deinit(p.gpa);
    }
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, journal_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return list.toOwnedSlice(p.gpa),
        else => return e,
    };
    defer p.gpa.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "(redefine ")) {
            // (redefine <name> <seq> "<source>" <ts>)
            var i: usize = "(redefine ".len;
            const t = readToken(line, i);
            i = skipSpaces(line, t.end);
            i = skipSpaces(line, readToken(line, i).end); // seq
            const ps = try parseSchemeString(p.gpa, line, i);
            try list.append(p.gpa, .{
                .name = try p.gpa.dupe(u8, t.tok),
                .source = ps.value,
            });
        } else if (std.mem.startsWith(u8, line, "(discard ") or
            std.mem.startsWith(u8, line, "(suspect "))
        {
            // (<kind> <name> <seq> <ts>) — both prefixes are 9 bytes.
            const t = readToken(line, "(discard ".len);
            var j = list.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, list.items[j].name, t.tok)) {
                    const r = list.orderedRemove(j);
                    p.gpa.free(r.name);
                    p.gpa.free(r.source);
                }
            }
        } else if (std.mem.startsWith(u8, line, "(commit ")) {
            for (list.items) |r| {
                p.gpa.free(r.name);
                p.gpa.free(r.source);
            }
            list.clearRetainingCapacity();
        } else {
            return error.JournalCorrupt;
        }
    }
    return list.toOwnedSlice(p.gpa);
}

fn countJournalLines(p: *Probe) !usize {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, journal_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer p.gpa.free(content);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len > 0) {
            // Typed schema: every line must be a known entry kind. Catches
            // torn tails and foreign writes, not just missing '('.
            if (!std.mem.startsWith(u8, line, "(redefine ") and
                !std.mem.startsWith(u8, line, "(discard ") and
                !std.mem.startsWith(u8, line, "(suspect ") and
                !std.mem.startsWith(u8, line, "(commit "))
                return error.JournalCorrupt;
            n += 1;
        }
    }
    return n;
}

// ---------- conversation store (spike-003) ----------
//
// Zig-owned append-only typed entries, fsync per append, same discipline
// as the journal. Torn-tail tolerance on read: a non-conforming FINAL
// line is dropped (crash mid-append); any other bad line is corruption.

const conv_path = ".work/conversation.sexp";
const provider_script_path = ".work/provider-script.sexp";
const workspace_path = ".work/workspace";
const max_tool_output: usize = 16 * 1024;

const conv_prefixes = [_][]const u8{ "(user ", "(assistant ", "(tool-call ", "(tool-result " };

fn convAppendRaw(p: *Probe, entry: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, conv_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);
    var f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer f.close(p.io);
    try f.writeStreamingAll(p.io, entry);
    try f.writeStreamingAll(p.io, "\n");
    try f.sync(p.io);
}

fn convLineValid(line: []const u8) bool {
    for (conv_prefixes) |pre| if (std.mem.startsWith(u8, line, pre)) return true;
    return false;
}

/// Valid entry lines count; a torn final line is tolerated (dropped).
fn convCount(p: *Probe) !usize {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer p.gpa.free(content);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!convLineValid(line)) {
            if (it.peek() == null) break; // torn tail: tolerate
            return error.ConvCorrupt;
        }
        n += 1;
    }
    return n;
}

/// Assert no torn/invalid lines (probe hygiene check).
fn convAssertClean(p: *Probe) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file)) catch return;
    defer p.gpa.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and !convLineValid(line)) return error.ConvCorrupt;
    }
}

fn convCountPrefix(p: *Probe, prefix: []const u8) !usize {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer p.gpa.free(content);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) n += 1;
    }
    return n;
}

const ConvKind = enum { user, assistant, tool_call, tool_result, empty };

fn convLastKind(p: *Probe) !ConvKind {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return .empty,
        else => return e,
    };
    defer p.gpa.free(content);
    var last: ConvKind = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "(user ")) {
            last = .user;
        } else if (std.mem.startsWith(u8, line, "(assistant ")) {
            last = .assistant;
        } else if (std.mem.startsWith(u8, line, "(tool-call ")) {
            last = .tool_call;
        } else if (std.mem.startsWith(u8, line, "(tool-result ")) {
            last = .tool_result;
        } else if (it.peek() != null) {
            return error.ConvCorrupt;
        } // else torn tail: ignore
    }
    return last;
}

/// User entries are appended by the SUPERVISOR, fsynced before any
/// provider work.
fn convAppendUser(p: *Probe, text: []const u8) !void {
    const esc = try escapeSchemeString(p.gpa, text);
    defer p.gpa.free(esc);
    const entry = try std.fmt.allocPrint(p.gpa, "(user {d} \"{s}\" {d})", .{ try convCount(p), esc, nowReal(p) });
    defer p.gpa.free(entry);
    try convAppendRaw(p, entry);
}

/// Validate + append an image-requested entry. Field shapes are fixed per
/// kind; strings are parsed and re-escaped through the one discipline.
fn convHandleAppend(p: *Probe, kind: []const u8, rest: []const u8) !void {
    const seq = try convCount(p);
    var entry: []u8 = undefined;
    if (std.mem.eql(u8, kind, "assistant")) {
        const text = try parseSchemeString(p.gpa, rest, 0);
        defer p.gpa.free(text.value);
        const echo = try parseSchemeString(p.gpa, rest, skipSpaces(rest, text.end));
        defer p.gpa.free(echo.value);
        const e1 = try escapeSchemeString(p.gpa, text.value);
        defer p.gpa.free(e1);
        const e2 = try escapeSchemeString(p.gpa, echo.value);
        defer p.gpa.free(e2);
        entry = try std.fmt.allocPrint(p.gpa, "(assistant {d} \"{s}\" \"{s}\" {d})", .{ seq, e1, e2, nowReal(p) });
    } else if (std.mem.eql(u8, kind, "tool-call")) {
        const t = readToken(rest, 0);
        const path = try parseSchemeString(p.gpa, rest, skipSpaces(rest, t.end));
        defer p.gpa.free(path.value);
        const echo = try parseSchemeString(p.gpa, rest, skipSpaces(rest, path.end));
        defer p.gpa.free(echo.value);
        const e1 = try escapeSchemeString(p.gpa, path.value);
        defer p.gpa.free(e1);
        const e2 = try escapeSchemeString(p.gpa, echo.value);
        defer p.gpa.free(e2);
        entry = try std.fmt.allocPrint(p.gpa, "(tool-call {d} {s} \"{s}\" \"{s}\" {d})", .{ seq, t.tok, e1, e2, nowReal(p) });
    } else if (std.mem.eql(u8, kind, "tool-result")) {
        const t = readToken(rest, 0);
        const result = try parseSchemeString(p.gpa, rest, skipSpaces(rest, t.end));
        defer p.gpa.free(result.value);
        const e1 = try escapeSchemeString(p.gpa, result.value);
        defer p.gpa.free(e1);
        entry = try std.fmt.allocPrint(p.gpa, "(tool-result {d} {s} \"{s}\" {d})", .{ seq, t.tok, e1, nowReal(p) });
    } else {
        return error.BadConvAppend;
    }
    defer p.gpa.free(entry);
    try convAppendRaw(p, entry);
}

fn convHistoryFrame(p: *Probe) ![]u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return try p.gpa.dupe(u8, "(kernel.history)"),
        else => return e,
    };
    defer p.gpa.free(content);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(p.gpa);
    try out.appendSlice(p.gpa, "(kernel.history");
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (!convLineValid(line)) {
            if (it.peek() == null) break; // torn tail
            return error.ConvCorrupt;
        }
        try out.append(p.gpa, ' ');
        try out.appendSlice(p.gpa, line);
    }
    try out.append(p.gpa, ')');
    return out.toOwnedSlice(p.gpa);
}

// ---------- fake provider (scripted, deterministic) ----------

/// Script position = count of completed provider replies, derived from the
/// durable store: assistant entries + tool-call entries. A mid-turn kill
/// before the entry lands leaves the position unchanged, so the retried
/// turn gets the same scripted response — no supervisor memory involved.
fn providerPosition(p: *Probe) !usize {
    return (try convCountPrefix(p, "(assistant ")) + (try convCountPrefix(p, "(tool-call "));
}

fn providerReply(p: *Probe, sp: []const u8) ![]u8 {
    const pos = try providerPosition(p);
    const script = std.Io.Dir.cwd().readFileAlloc(p.io, provider_script_path, p.gpa, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => return providerSay(p, "[no provider script]", sp),
        else => return e,
    };
    defer p.gpa.free(script);
    var it = std.mem.splitScalar(u8, script, '\n');
    var idx: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (idx == pos) return providerRender(p, line, sp);
        idx += 1;
    }
    return providerSay(p, "[provider script exhausted]", sp);
}

fn providerSay(p: *Probe, text: []const u8, sp: []const u8) ![]u8 {
    const e1 = try escapeSchemeString(p.gpa, text);
    defer p.gpa.free(e1);
    const e2 = try escapeSchemeString(p.gpa, sp);
    defer p.gpa.free(e2);
    return std.fmt.allocPrint(p.gpa, "(provider.reply (say \"{s}\" \"{s}\"))", .{ e1, e2 });
}

fn providerRender(p: *Probe, line: []const u8, sp: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, line, "(say ")) {
        const s = try parseSchemeString(p.gpa, line, "(say ".len);
        defer p.gpa.free(s.value);
        return providerSay(p, s.value, sp);
    }
    if (std.mem.startsWith(u8, line, "(call ")) {
        // (call <tool> ("<path>"))
        var i: usize = "(call ".len;
        const t = readToken(line, i);
        i = skipSpaces(line, t.end);
        if (i >= line.len or line[i] != '(') return error.BadProviderScript;
        i = skipSpaces(line, i + 1);
        const s = try parseSchemeString(p.gpa, line, i);
        defer p.gpa.free(s.value);
        const e1 = try escapeSchemeString(p.gpa, s.value);
        defer p.gpa.free(e1);
        const e2 = try escapeSchemeString(p.gpa, sp);
        defer p.gpa.free(e2);
        return std.fmt.allocPrint(p.gpa, "(provider.reply (call {s} \"{s}\" \"{s}\"))", .{ t.tok, e1, e2 });
    }
    return error.BadProviderScript;
}

// ---------- tool shim: fs.read jailed to .work/workspace/ ----------

fn toolInvoke(p: *Probe, tool: []const u8, path: []const u8) ![]u8 {
    if (!std.mem.eql(u8, tool, "fs.read")) {
        const e = try escapeSchemeString(p.gpa, "unknown-tool");
        defer p.gpa.free(e);
        return std.fmt.allocPrint(p.gpa, "(tool.error \"{s}\")", .{e});
    }
    const content = jailedRead(p, path) catch |e| {
        const msg = try std.fmt.allocPrint(p.gpa, "fs.read rejected: {s}", .{@errorName(e)});
        defer p.gpa.free(msg);
        const esc = try escapeSchemeString(p.gpa, msg);
        defer p.gpa.free(esc);
        return std.fmt.allocPrint(p.gpa, "(tool.error \"{s}\")", .{esc});
    };
    defer p.gpa.free(content);
    const esc = try escapeSchemeString(p.gpa, content);
    defer p.gpa.free(esc);
    return std.fmt.allocPrint(p.gpa, "(tool.result \"{s}\")", .{esc});
}

/// Read REL under .work/workspace/ with containment verification:
/// no absolute paths, no `..` components, realpath must stay inside the
/// jail's realpath. Output bounded to max_tool_output.
fn jailedRead(p: *Probe, rel: []const u8) ![]u8 {
    if (rel.len == 0 or rel[0] == '/') return error.JailEscape;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return error.JailEscape;
    }
    const full = try std.fmt.allocPrint(p.gpa, workspace_path ++ "/{s}", .{rel});
    defer p.gpa.free(full);
    var jail_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const jail_len = try std.Io.Dir.cwd().realPathFile(p.io, workspace_path, &jail_buf);
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = std.Io.Dir.cwd().realPathFile(p.io, full, &real_buf) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return e,
    };
    const jail = jail_buf[0..jail_len];
    const real = real_buf[0..real_len];
    if (real.len <= jail.len or !std.mem.startsWith(u8, real, jail) or real[jail.len] != '/')
        return error.JailEscape;
    const content = try std.Io.Dir.cwd().readFileAlloc(p.io, full, p.gpa, .limited(max_tool_output + 1));
    errdefer p.gpa.free(content);
    if (content.len > max_tool_output) {
        return try std.fmt.allocPrint(p.gpa, "{s}\n[truncated at {d} bytes]", .{ content[0..max_tool_output], max_tool_output });
    }
    return content;
}

// ---------- generations ----------

fn readCurrentGen(p: *Probe) !u32 {
    const content = try std.Io.Dir.cwd().readFileAlloc(p.io, current_path, p.gpa, .limited(64));
    defer p.gpa.free(content);
    return try std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n"), 10);
}

fn genPath(p: *Probe, gen: u32, comptime file: []const u8) ![]u8 {
    return std.fmt.allocPrint(p.gpa, gens_path ++ "/{d}/" ++ file, .{gen});
}

fn writeSmallFile(p: *Probe, path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(p.io, path, .{});
    defer f.close(p.io);
    try f.writeStreamingAll(p.io, contents);
    try f.sync(p.io);
}

fn fileExists(p: *Probe, path: []const u8) bool {
    std.Io.Dir.cwd().access(p.io, path, .{}) catch return false;
    return true;
}

fn ensureWork(p: *Probe) !void {
    try std.Io.Dir.cwd().createDirPath(p.io, gens_path ++ "/0");
    const base = try genPath(p, 0, "base.ss");
    defer p.gpa.free(base);
    if (!fileExists(p, base)) {
        try writeSmallFile(p, base,
            \\(define (greeting) "hello, live image")
            \\(define (base-version) 1)
            \\;; agent policy: ordinary kernel-tracked bindings, redefinable
            \\;; via kernel.redefine (spike-003)
            \\(define (system-prompt) "POLICY-V1: you are friendly and verbose.")
            \\(define tool-registry '((fs.read . "read a workspace file")))
            \\
        );
    }
    const replay = try genPath(p, 0, "replay.ss");
    defer p.gpa.free(replay);
    if (!fileExists(p, replay)) try writeSmallFile(p, replay, "");
    const meta = try genPath(p, 0, "meta.sexp");
    defer p.gpa.free(meta);
    if (!fileExists(p, meta)) try writeSmallFile(p, meta, "(gen 0 parent -1 hash \"\" ts 0)\n");
    if (!fileExists(p, journal_path)) try writeSmallFile(p, journal_path, "");
    if (!fileExists(p, current_path)) try writeSmallFile(p, current_path, "0\n");
    // spike-003: conversation store, default provider script, workspace jail
    if (!fileExists(p, conv_path)) try writeSmallFile(p, conv_path, "");
    if (!fileExists(p, provider_script_path)) {
        try writeSmallFile(p, provider_script_path,
            \\(say "demo provider: ask me anything")
            \\(say "demo provider: still here")
            \\
        );
    }
    try std.Io.Dir.cwd().createDirPath(p.io, workspace_path);
    if (!fileExists(p, workspace_path ++ "/hello.txt")) {
        try writeSmallFile(p, workspace_path ++ "/hello.txt", "hello from the workspace jail\n");
    }
}

/// Replay the authoritative state into a fresh image: base definitions,
/// current generation's replay script, then pending journal redefines.
fn replayCurrent(p: *Probe, sc: *Scheme) !void {
    const cur = try readCurrentGen(p);
    const base = try genPath(p, cur, "base.ss");
    defer p.gpa.free(base);
    const base_src = try std.Io.Dir.cwd().readFileAlloc(p.io, base, p.gpa, .limited(max_file));
    defer p.gpa.free(base_src);
    try requestApply(p, sc, base_src);
    const replay = try genPath(p, cur, "replay.ss");
    defer p.gpa.free(replay);
    const replay_src = try std.Io.Dir.cwd().readFileAlloc(p.io, replay, p.gpa, .limited(max_file));
    defer p.gpa.free(replay_src);
    if (std.mem.trim(u8, replay_src, " \n").len > 0) try requestApply(p, sc, replay_src);
    const pend = try journalPendingRedefs(p);
    defer {
        for (pend) |r| {
            p.gpa.free(r.name);
            p.gpa.free(r.source);
        }
        p.gpa.free(pend);
    }
    for (pend) |r| try requestApply(p, sc, r.source);
}

// ---------- define scanning (committed source lookup) ----------

const Define = struct { name: []const u8, text: []const u8 };

/// Find the end (index past the matching close paren) of the form starting
/// at s[start] == '('. String- and comment-aware.
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

/// Extract top-level (define ...) forms from source text.
fn scanDefines(p: *Probe, text: []const u8) ![]Define {
    var defs: std.ArrayList(Define) = .empty;
    errdefer defs.deinit(p.gpa);
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
            j = skipSpaces(form, j);
            if (j < form.len and form[j] == '(') {
                j = skipSpaces(form, j + 1);
                const t = readToken(form, j);
                try defs.append(p.gpa, .{ .name = t.tok, .text = form });
            } else {
                const t = readToken(form, j);
                try defs.append(p.gpa, .{ .name = t.tok, .text = form });
            }
        }
        i = end;
    }
    return defs.toOwnedSlice(p.gpa);
}

/// The committed source for NAME in the current generation (base + replay).
fn committedSource(p: *Probe, name: []const u8) !?[]u8 {
    const cur = try readCurrentGen(p);
    for ([_][]const u8{ "base.ss", "replay.ss" }) |file| {
        const path = try std.fmt.allocPrint(p.gpa, gens_path ++ "/{d}/{s}", .{ cur, file });
        defer p.gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(p.io, path, p.gpa, .limited(max_file)) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer p.gpa.free(text);
        const defs = try scanDefines(p, text);
        defer p.gpa.free(defs);
        for (defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return try p.gpa.dupe(u8, d.text);
        }
    }
    return null;
}

// ---------- kernel.inspect ----------

/// The generation at which NAME was committed: 0 if it is in base.ss (base
/// is copied verbatim into every generation), else the earliest generation
/// whose replay.ss defines it (replay scripts accumulate).
fn definedGeneration(p: *Probe, name: []const u8) !?u32 {
    const cur = try readCurrentGen(p);
    const base = try genPath(p, cur, "base.ss");
    defer p.gpa.free(base);
    const base_src = try std.Io.Dir.cwd().readFileAlloc(p.io, base, p.gpa, .limited(max_file));
    defer p.gpa.free(base_src);
    {
        const defs = try scanDefines(p, base_src);
        defer p.gpa.free(defs);
        for (defs) |d| if (std.mem.eql(u8, d.name, name)) return 0;
    }
    var g: u32 = 0;
    while (g <= cur) : (g += 1) {
        const path = try genPath(p, g, "replay.ss");
        defer p.gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(p.io, path, p.gpa, .limited(max_file)) catch continue;
        defer p.gpa.free(text);
        const defs = try scanDefines(p, text);
        defer p.gpa.free(defs);
        for (defs) |d| if (std.mem.eql(u8, d.name, name)) return g;
    }
    return null;
}

fn isSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or
        std.mem.indexOfScalar(u8, "!$%&*+-./:<=>?@^_~", c) != null;
}

/// Shallow dependency check: does TEXT mention NAME as a delimited symbol?
/// Lexical scan only — no macro expansion, no closure analysis.
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

/// Compose the (kernel.inspect.result ...) reply for NAME.
/// status: pending (journal), committed (current generation), unknown.
/// dependents (v0, shallow): tracked definitions — current-generation
/// committed defines plus pending redefines — whose source mentions NAME
/// as a delimited symbol, excluding NAME itself.
fn composeInspect(p: *Probe, name: []const u8) ![]u8 {
    const pend = try journalPendingRedefs(p);
    defer {
        for (pend) |r| {
            p.gpa.free(r.name);
            p.gpa.free(r.source);
        }
        p.gpa.free(pend);
    }

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
    defer if (committed_src) |s| p.gpa.free(s);
    if (source == null) {
        committed_src = try committedSource(p, name);
        if (committed_src) |s| {
            status = "committed";
            source = s;
            gen = try definedGeneration(p, name);
        }
    }

    // Dependents: scan committed defines + pending sources. Names are
    // duped: scan buffers are freed at each loop iteration.
    var deps: std.ArrayList([]u8) = .empty;
    defer {
        for (deps.items) |d| p.gpa.free(d);
        deps.deinit(p.gpa);
    }
    const cur = try readCurrentGen(p);
    for ([_][]const u8{ "base.ss", "replay.ss" }) |file| {
        const path = try std.fmt.allocPrint(p.gpa, gens_path ++ "/{d}/{s}", .{ cur, file });
        defer p.gpa.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(p.io, path, p.gpa, .limited(max_file)) catch continue;
        defer p.gpa.free(text);
        const defs = try scanDefines(p, text);
        defer p.gpa.free(defs);
        for (defs) |d| {
            if (!std.mem.eql(u8, d.name, name) and containsSymbol(d.text, name)) {
                try deps.append(p.gpa, try p.gpa.dupe(u8, d.name));
            }
        }
    }
    for (pend) |r| {
        if (!std.mem.eql(u8, r.name, name) and containsSymbol(r.source, name)) {
            try deps.append(p.gpa, try p.gpa.dupe(u8, r.name));
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(p.gpa);
    try out.appendSlice(p.gpa, "(kernel.inspect.result (source ");
    if (source) |s| {
        const esc = try escapeSchemeString(p.gpa, s);
        defer p.gpa.free(esc);
        try out.appendSlice(p.gpa, "\"");
        try out.appendSlice(p.gpa, esc);
        try out.appendSlice(p.gpa, "\")");
    } else {
        try out.appendSlice(p.gpa, "#f)");
    }
    try out.appendSlice(p.gpa, " (status ");
    try out.appendSlice(p.gpa, status);
    try out.appendSlice(p.gpa, ") (generation ");
    if (gen) |g| {
        const gs = try std.fmt.allocPrint(p.gpa, "{d}", .{g});
        defer p.gpa.free(gs);
        try out.appendSlice(p.gpa, gs);
    } else {
        try out.appendSlice(p.gpa, "#f");
    }
    try out.appendSlice(p.gpa, ") (dependents (");
    for (deps.items, 0..) |d, idx| {
        if (idx > 0) try out.append(p.gpa, ' ');
        try out.appendSlice(p.gpa, d);
    }
    try out.appendSlice(p.gpa, ")))");
    return out.toOwnedSlice(p.gpa);
}

// ---------- commit ----------

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// kernel.commit: build generation n+1 from the journal's pending redefines,
/// replay-probe it in a CLEAN second Scheme process, run the recorded check,
/// and only then atomically flip the current pointer.
/// F8: generation files are staged in generations/.staging-<n+1>/ and only
/// renamed into place after the probe passes; failure removes the staging
/// dir — no orphan generation dirs.
/// F9: EVERY failure exit after the pending set is known quarantines it
/// (journalSuspect), not only the value-mismatch branch.
fn doCommit(p: *Probe, check: []const u8, expected: []const u8) !void {
    const cur = try readCurrentGen(p);
    const pend = try journalPendingRedefs(p);
    defer {
        for (pend) |r| {
            p.gpa.free(r.name);
            p.gpa.free(r.source);
        }
        p.gpa.free(pend);
    }
    if (pend.len == 0) return error.NothingToCommit;

    var success = false;
    defer if (!success) journalSuspect(p, pend) catch |e| {
        say(p, "WARNING: suspect quarantine failed: {s}", .{@errorName(e)});
    };

    // New replay script = old replay + pending definitions (declarative,
    // ordered).
    const old_replay_path = try genPath(p, cur, "replay.ss");
    defer p.gpa.free(old_replay_path);
    const old_replay = try std.Io.Dir.cwd().readFileAlloc(p.io, old_replay_path, p.gpa, .limited(max_file));
    defer p.gpa.free(old_replay);
    var new_replay: std.ArrayList(u8) = .empty;
    defer new_replay.deinit(p.gpa);
    try new_replay.appendSlice(p.gpa, old_replay);
    for (pend) |r| {
        try new_replay.appendSlice(p.gpa, r.source);
        try new_replay.append(p.gpa, '\n');
    }

    // Stage into a hidden dir; renamed into generations/<n+1> only on success.
    const staging_dir = try std.fmt.allocPrint(p.gpa, gens_path ++ "/.staging-{d}", .{cur + 1});
    defer p.gpa.free(staging_dir);
    var staged = false;
    defer if (staged) std.Io.Dir.cwd().deleteTree(p.io, staging_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(p.io, staging_dir);
    staged = true;
    const old_base = try genPath(p, cur, "base.ss");
    defer p.gpa.free(old_base);
    const base_src = try std.Io.Dir.cwd().readFileAlloc(p.io, old_base, p.gpa, .limited(max_file));
    defer p.gpa.free(base_src);
    const staging_base = try std.fmt.allocPrint(p.gpa, "{s}/base.ss", .{staging_dir});
    defer p.gpa.free(staging_base);
    try writeSmallFile(p, staging_base, base_src);
    const staging_replay = try std.fmt.allocPrint(p.gpa, "{s}/replay.ss", .{staging_dir});
    defer p.gpa.free(staging_replay);
    try writeSmallFile(p, staging_replay, new_replay.items);
    const hex = sha256Hex(new_replay.items);
    const meta = try std.fmt.allocPrint(p.gpa, "(gen {d} parent {d} hash \"{s}\" ts {d})\n", .{ cur + 1, cur, hex, nowReal(p) });
    defer p.gpa.free(meta);
    const staging_meta = try std.fmt.allocPrint(p.gpa, "{s}/meta.sexp", .{staging_dir});
    defer p.gpa.free(staging_meta);
    try writeSmallFile(p, staging_meta, meta);

    // Replay-probe in a CLEAN second Scheme process. Errors here (apply or
    // check eval) propagate; the defer above quarantines the pending set.
    var clean = try Scheme.spawn(p);
    defer clean.kill(p);
    try requestApply(p, &clean, base_src);
    try requestApply(p, &clean, new_replay.items);
    const got = try requestEval(p, &clean, check);
    defer p.gpa.free(got);
    if (!std.mem.eql(u8, got, expected)) {
        say(p, "replay check failed in clean process: got '{s}', want '{s}'", .{ got, expected });
        return error.ReplayCheckFailed;
    }

    // Probe passed: move the staged generation into place.
    const new_dir = try std.fmt.allocPrint(p.gpa, gens_path ++ "/{d}", .{cur + 1});
    defer p.gpa.free(new_dir);
    std.Io.Dir.cwd().deleteTree(p.io, new_dir) catch {}; // stale orphan, if any
    try std.Io.Dir.rename(.cwd(), staging_dir, .cwd(), new_dir, p.io);
    staged = false;

    // Atomic flip: write tmp, fsync, rename over the pointer.
    const ptr = try std.fmt.allocPrint(p.gpa, "{d}\n", .{cur + 1});
    defer p.gpa.free(ptr);
    try writeSmallFile(p, current_tmp_path, ptr);
    try std.Io.Dir.rename(.cwd(), current_tmp_path, .cwd(), current_path, p.io);
    const entry = try std.fmt.allocPrint(p.gpa, "(commit {d} \"{s}\" {d})", .{ cur + 1, hex, nowReal(p) });
    defer p.gpa.free(entry);
    try journalAppend(p, entry);
    success = true;
    say(p, "commit: generation {d} selected (replay probe passed)", .{cur + 1});
}

// ---------- subcommands ----------

fn cmdReset(p: *Probe) !void {
    std.Io.Dir.cwd().deleteTree(p.io, ".work") catch {};
    say(p, "reset: .work removed", .{});
}

fn cmdBoot(p: *Probe) !void {
    const n = 10;
    var times: [n]i96 = undefined;
    for (0..n) |i| {
        const t0 = nowAwake(p);
        var sc = try Scheme.spawn(p);
        const v = try requestEval(p, &sc, "(+ 1 1)");
        p.gpa.free(v);
        const t1 = nowAwake(p);
        sc.kill(p);
        times[i] = t1 - t0;
        say(p, "boot[{d}]: {d:.2} ms (spawn -> first eval reply)", .{ i, ms(t1 - t0) });
    }
    var sorted = times;
    std.mem.sort(i96, &sorted, {}, std.sort.asc(i96));
    const med = sorted[n / 2];
    say(p, "boot: min={d:.2} ms median={d:.2} ms max={d:.2} ms", .{ ms(sorted[0]), ms(med), ms(sorted[n - 1]) });
    if (med < 100 * std.time.ns_per_ms) {
        say(p, "PASS: median boot < 100 ms", .{});
    } else {
        say(p, "FAIL: median boot >= 100 ms", .{});
        return error.BootTooSlow;
    }
}

fn cmdEcho(p: *Probe, n: u32) !void {
    var sc = try Scheme.spawn(p);
    defer sc.kill(p);
    const t0 = nowAwake(p);
    for (0..n) |i| {
        const payload = try std.fmt.allocPrint(p.gpa, "msg-{d}-{d}", .{ i, i *% 7919 });
        defer p.gpa.free(payload);
        const frame = try std.fmt.allocPrint(p.gpa, "(kernel.echo \"{s}\")", .{payload});
        defer p.gpa.free(frame);
        try sendFrame(p, &sc, frame);
        const r = try waitReply(p, &sc);
        const v = switch (r) {
            .ok => |v| v,
            .err => |msg| {
                say(p, "scheme error during echo: {s}", .{msg});
                p.gpa.free(msg);
                return error.SchemeError;
            },
        };
        defer p.gpa.free(v);
        if (!std.mem.eql(u8, v, payload)) {
            say(p, "echo mismatch at {d}: sent '{s}' got '{s}'", .{ i, payload, v });
            return error.EchoMismatch;
        }
    }
    const dt = nowAwake(p) - t0;
    const per_sec = @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(dt)) / 1.0e9);
    say(p, "echo: {d} round-trips in {d:.2} ms -> {d:.0} msgs/sec", .{ n, ms(dt), per_sec });
    say(p, "PASS: all echoes matched, no framing errors", .{});
}

fn cmdRedefineCycle(p: *Probe) !void {
    try ensureWork(p);
    const new_src = "(define (greeting) \"hacked\")";
    var sc = try Scheme.spawn(p);
    try replayCurrent(p, &sc);

    // Exploratory redefine: Scheme asks the supervisor; supervisor journals +
    // fsyncs, then applies inside the image.
    const esc = try escapeSchemeString(p.gpa, new_src);
    defer p.gpa.free(esc);
    const call = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'greeting \"{s}\")", .{esc});
    defer p.gpa.free(call);
    const rv = try requestEval(p, &sc, call);
    p.gpa.free(rv);
    const v1 = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(v1);
    if (!std.mem.eql(u8, v1, "hacked")) return error.RedefineNotLive;
    say(p, "redefine applied live: (greeting) => {s}", .{v1});

    // SIGKILL the image; respawn; replay base + journal into the fresh one.
    const pid = sc.child.id.?;
    try std.posix.kill(pid, .KILL);
    _ = try sc.child.wait(p.io);
    say(p, "sent SIGKILL to pid {d}; respawning and replaying journal", .{pid});
    var sc2 = try Scheme.spawn(p);
    defer sc2.kill(p);
    try replayCurrent(p, &sc2);

    const v2 = try requestEval(p, &sc2, "(greeting)");
    defer p.gpa.free(v2);
    if (!std.mem.eql(u8, v2, "hacked")) {
        say(p, "restored value mismatch: {s}", .{v2});
        return error.RestoreValueMismatch;
    }
    const s2 = try requestEval(p, &sc2, "(kernel.source-of 'greeting)");
    defer p.gpa.free(s2);
    if (!std.mem.eql(u8, s2, new_src)) {
        say(p, "restored source mismatch: {s}", .{s2});
        return error.RestoreSourceMismatch;
    }
    say(p, "PASS: after SIGKILL + replay, greeting == \"hacked\" with identical source", .{});
}

fn cmdDiscard(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    defer sc.kill(p);
    try replayCurrent(p, &sc);
    const v0 = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(v0);
    say(p, "committed state: (greeting) => {s}", .{v0});

    const new_src = "(define (greeting) \"hacked\")";
    const esc = try escapeSchemeString(p.gpa, new_src);
    defer p.gpa.free(esc);
    const call = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'greeting \"{s}\")", .{esc});
    defer p.gpa.free(call);
    const rv = try requestEval(p, &sc, call);
    p.gpa.free(rv);
    const v1 = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(v1);
    if (!std.mem.eql(u8, v1, "hacked")) return error.RedefineNotLive;
    say(p, "exploratory: (greeting) => {s} (not committed)", .{v1});

    const dv = try requestEval(p, &sc, "(kernel.discard 'greeting)");
    p.gpa.free(dv);
    const v2 = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(v2);
    if (!std.mem.eql(u8, v2, v0)) {
        say(p, "after discard: (greeting) => {s}, want {s}", .{ v2, v0 });
        return error.DiscardFailed;
    }
    say(p, "kernel.discard restored greeting to last committed value '{s}'", .{v2});

    // F4: discard of an unknown/uncommitted name must nack (readable Scheme
    // condition), not hang the image in kernel-wait.
    const r = try requestEvalReply(p, &sc, "(kernel.discard 'never-defined)");
    switch (r) {
        .ok => |v| {
            p.gpa.free(v);
            say(p, "discard of unknown name unexpectedly succeeded", .{});
            return error.DiscardUnknownNotNacked;
        },
        .err => |msg| {
            defer p.gpa.free(msg);
            if (std.mem.indexOf(u8, msg, "not-committed") == null) {
                say(p, "unexpected nack reason: {s}", .{msg});
                return error.DiscardNackReasonMismatch;
            }
            say(p, "discard of unknown name nacked as Scheme error: {s}", .{msg});
        },
    }
    // The image must still be alive and functional after the nack.
    const v3 = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(v3);
    if (!std.mem.eql(u8, v3, v0)) return error.ImageDeadAfterNack;
    say(p, "PASS: kernel.discard restores committed value; unknown name nacked without hanging", .{});
}

fn cmdCommit(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    defer sc.kill(p);
    try replayCurrent(p, &sc);

    const new_src = "(define (greeting) \"hacked\")";
    const esc = try escapeSchemeString(p.gpa, new_src);
    defer p.gpa.free(esc);
    const call = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'greeting \"{s}\")", .{esc});
    defer p.gpa.free(call);
    const rv = try requestEval(p, &sc, call);
    p.gpa.free(rv);

    const ok = try requestEval(p, &sc, "(kernel.commit \"(greeting)\" \"hacked\")");
    defer p.gpa.free(ok);
    if (!std.mem.eql(u8, ok, "#t")) return error.CommitNotAcked;
    const cur = try readCurrentGen(p);
    if (cur != 1) return error.PointerNotFlipped;
    say(p, "commit accepted; current generation = {d}", .{cur});

    // Fresh image must boot into the committed state.
    var sc2 = try Scheme.spawn(p);
    defer sc2.kill(p);
    try replayCurrent(p, &sc2);
    const v = try requestEval(p, &sc2, "(greeting)");
    defer p.gpa.free(v);
    if (!std.mem.eql(u8, v, "hacked")) return error.GenerationReplayMismatch;
    say(p, "fresh image on generation {d}: (greeting) => {s}", .{ cur, v });

    // Failure path: a commit whose replay check fails must keep the old
    // pointer and mark the exploratory change suspect.
    const bad_src = "(define (greeting) \"broken\")";
    const esc2 = try escapeSchemeString(p.gpa, bad_src);
    defer p.gpa.free(esc2);
    const call2 = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'greeting \"{s}\")", .{esc2});
    defer p.gpa.free(call2);
    const rv2 = try requestEval(p, &sc, call2);
    p.gpa.free(rv2);
    const ok2 = try requestEval(p, &sc, "(kernel.commit \"(greeting)\" \"this-will-never-match\")");
    defer p.gpa.free(ok2);
    if (!std.mem.eql(u8, ok2, "#f")) return error.BadCommitNotRejected;
    const cur2 = try readCurrentGen(p);
    if (cur2 != 1) return error.PointerMovedOnFailedCommit;
    say(p, "failed commit kept old pointer (generation {d}); change reported suspect", .{cur2});

    // F2: commit-fail -> watchdog-style reload must boot the last COMMITTED
    // value, not the rejected one (suspect entries are skipped on replay).
    var sc3 = try Scheme.spawn(p);
    defer sc3.kill(p);
    try replayCurrent(p, &sc3);
    const v3 = try requestEval(p, &sc3, "(greeting)");
    defer p.gpa.free(v3);
    if (std.mem.eql(u8, v3, "broken")) {
        say(p, "reload after failed commit booted the REJECTED value 'broken'", .{});
        return error.SuspectPoisonedReplay;
    }
    if (!std.mem.eql(u8, v3, "hacked")) {
        say(p, "reload after failed commit: (greeting) => {s}, want committed 'hacked'", .{v3});
        return error.ReloadNotCommittedValue;
    }
    say(p, "reload after failed commit boots committed value '{s}' (suspect skipped)", .{v3});

    // F8: the failed commit left no orphan generation dir (staging removed).
    if (fileExists(p, gens_path ++ "/2")) return error.OrphanGenerationDir;
    if (fileExists(p, gens_path ++ "/.staging-2")) return error.OrphanStagingDir;
    say(p, "no orphan generations/2 dir after failed commit", .{});

    // F9: a pending entry whose source ERRORS on clean-process apply must
    // still be quarantined. Written journal-side to simulate a torn state
    // (journal fsynced, live apply crashed before the ack).
    try journalRedefine(p, "broken-mal", "(define (broken-mal");
    const ok3 = try requestEval(p, &sc, "(kernel.commit \"#t\" \"#t\")");
    defer p.gpa.free(ok3);
    if (!std.mem.eql(u8, ok3, "#f")) return error.ErrorCommitNotRejected;
    if (try readCurrentGen(p) != 1) return error.PointerMovedOnFailedCommit;
    const journal = try std.Io.Dir.cwd().readFileAlloc(p.io, journal_path, p.gpa, .limited(max_file));
    defer p.gpa.free(journal);
    if (std.mem.indexOf(u8, journal, "(suspect broken-mal ") == null)
        return error.SuspectNotJournaled;
    if (fileExists(p, gens_path ++ "/2") or fileExists(p, gens_path ++ "/.staging-2"))
        return error.OrphanGenerationDir;
    // Replay must skip the quarantined malformed entry: fresh boot works.
    var sc4 = try Scheme.spawn(p);
    defer sc4.kill(p);
    try replayCurrent(p, &sc4);
    const v4 = try requestEval(p, &sc4, "(greeting)");
    defer p.gpa.free(v4);
    if (!std.mem.eql(u8, v4, "hacked")) return error.ReloadNotCommittedValue;
    say(p, "clean-process apply ERROR quarantined too: (suspect broken-mal ...) journaled, pointer kept, no orphan, replay clean", .{});
    say(p, "PASS: commit flips pointer only after clean-process replay probe passes; suspect change quarantined", .{});
}

fn cmdWatchdog(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    try replayCurrent(p, &sc);
    const committed = try requestEval(p, &sc, "(greeting)");
    defer p.gpa.free(committed);
    const journal_lines = try countJournalLines(p);
    say(p, "committed state: (greeting) => {s}; journal lines = {d}", .{ committed, journal_lines });

    // Hang the image, then probe liveness with a 2s deadline.
    const hang_esc = try escapeSchemeString(p.gpa, "(kernel.hang)");
    defer p.gpa.free(hang_esc);
    const hang_frame = try std.fmt.allocPrint(p.gpa, "(kernel.eval \"{s}\")", .{hang_esc});
    defer p.gpa.free(hang_frame);
    try sendFrame(p, &sc, hang_frame);
    say(p, "image hung via (kernel.hang); starting liveness probe (2 s deadline)", .{});
    const probe_esc = try escapeSchemeString(p.gpa, "(+ 1 1)");
    defer p.gpa.free(probe_esc);
    const probe_frame = try std.fmt.allocPrint(p.gpa, "(kernel.eval \"{s}\")", .{probe_esc});
    defer p.gpa.free(probe_frame);
    try sendFrame(p, &sc, probe_frame);
    const t0 = nowAwake(p);
    const resp = try readFrameTimeout(p.gpa, p.io, sc.child.stdout.?, 2000);
    if (resp) |r| {
        p.gpa.free(r);
        say(p, "unexpected reply from hung image", .{});
        return error.WatchdogProbeAnswered;
    }
    say(p, "liveness deadline expired after {d:.0} ms; killing image", .{ms(nowAwake(p) - t0)});
    sc.kill(p);

    // Reload the last committed generation; journal must be intact.
    var sc2 = try Scheme.spawn(p);
    defer sc2.kill(p);
    try replayCurrent(p, &sc2);
    const v = try requestEval(p, &sc2, "(greeting)");
    defer p.gpa.free(v);
    if (!std.mem.eql(u8, v, committed)) {
        say(p, "reloaded state mismatch: {s} != {s}", .{ v, committed });
        return error.WatchdogReloadMismatch;
    }
    const journal_lines2 = try countJournalLines(p);
    if (journal_lines2 != journal_lines) return error.JournalChanged;
    say(p, "PASS: watchdog killed hung image, reloaded committed state '{s}', journal intact ({d} lines)", .{ v, journal_lines2 });
}

fn isSensitiveName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "KEY") != null or
        std.mem.indexOf(u8, name, "TOKEN") != null or
        std.mem.indexOf(u8, name, "SECRET") != null;
}

fn cmdEnvCheck(p: *Probe) !void {
    // Sensitive names present in the SUPERVISOR's own environment.
    var sens: std.ArrayList([]const u8) = .empty;
    defer sens.deinit(p.gpa);
    for (p.environ.keys()) |k| {
        if (isSensitiveName(k)) try sens.append(p.gpa, k);
    }
    say(p, "supervisor environment contains {d} sensitive-looking names:", .{sens.items.len});
    for (sens.items) |k| say(p, "  {s}", .{k});
    if (sens.items.len == 0) {
        say(p, "note: no *KEY*/*TOKEN*/*SECRET* vars in supervisor env; run with one set (e.g. FAKE_API_KEY=x) for a stronger test", .{});
    }

    var sc = try Scheme.spawn(p);
    defer sc.kill(p);

    // Chez has no env-alist API; probe names directly with getenv. What the
    // child DOES see (allowlist):
    for ([_][]const u8{ "PATH", "HOME", "TERM" }) |k| {
        const call = try std.fmt.allocPrint(p.gpa, "(getenv \"{s}\")", .{k});
        defer p.gpa.free(call);
        const v = try requestEval(p, &sc, call);
        defer p.gpa.free(v);
        say(p, "child sees {s} = {s}", .{ k, v });
    }
    // What it must NOT see:
    for (sens.items) |k| {
        const call = try std.fmt.allocPrint(p.gpa, "(getenv \"{s}\")", .{k});
        defer p.gpa.free(call);
        const v = try requestEval(p, &sc, call);
        defer p.gpa.free(v);
        if (!std.mem.eql(u8, v, "#f")) {
            say(p, "LEAK: child sees supervisor secret {s} = {s}", .{ k, v });
            return error.SecretLeaked;
        }
        say(p, "child does NOT see {s} (getenv => #f)", .{k});
    }
    say(p, "PASS: child spawned with scrubbed allowlist env (PATH/HOME/TERM only); no supervisor secrets visible", .{});
}

// ---------- interactive demo ----------

fn isChildDeath(e: anyerror) bool {
    return e == error.ChildClosedPipe or e == error.BrokenPipe or
        e == error.Eof or e == error.EndOfStream;
}

/// Hard-kill (if still running), reap, respawn, replay authoritative state.
fn killAndRespawn(p: *Probe, sc: *Scheme) !void {
    if (sc.child.id) |pid| {
        std.posix.kill(pid, .KILL) catch {};
        _ = sc.child.wait(p.io) catch {};
    }
    sc.* = try Scheme.spawn(p);
    try replayCurrent(p, sc);
}

/// Show the restored state after a respawn (greeting is the demo binding).
fn printGreeting(p: *Probe, sc: *Scheme) void {
    const r = requestEvalC(p, sc, "(greeting)") catch |e| {
        say(p, "respawned, but state probe failed: {s}", .{@errorName(e)});
        return;
    };
    switch (r) {
        .ok => |res| {
            defer p.gpa.free(res.datum);
            defer p.gpa.free(res.output);
            say(p, "restored state: (greeting) => {s}", .{res.datum});
        },
        .err => |msg| {
            defer p.gpa.free(msg);
            say(p, "respawned; (greeting) is not defined: {s}", .{msg});
        },
    }
}

fn interactiveEval(p: *Probe, sc: *Scheme, alive: *bool, line: []const u8) !void {
    const r = requestEvalC(p, sc, line) catch |e| {
        if (isChildDeath(e)) {
            say(p, "image died ({s}); respawning and replaying last committed state", .{@errorName(e)});
            try killAndRespawn(p, sc);
            alive.* = true;
            printGreeting(p, sc);
            return;
        }
        return e;
    };
    switch (r) {
        .ok => |res| {
            defer p.gpa.free(res.datum);
            defer p.gpa.free(res.output);
            const out = std.mem.trimEnd(u8, res.output, "\n");
            if (out.len > 0) say(p, "{s}", .{out});
            say(p, "=> {s}", .{res.datum});
        },
        .err => |msg| {
            defer p.gpa.free(msg);
            say(p, "scheme error: {s}", .{msg});
        },
    }
}

fn interactiveHelp(p: *Probe) void {
    say(p, "colon commands:", .{});
    say(p, "  :kill            SIGKILL the image, respawn, replay committed state", .{});
    say(p, "  :commit          clean-process replay probe + atomic generation flip", .{});
    say(p, "  :discard <name>  restore <name> to its last committed definition", .{});
    say(p, "  :status          generation, journal size, pending redefines, liveness", .{});
    say(p, "  :reset           wipe .work back to genesis and respawn", .{});
    say(p, "  :quit            clean shutdown (Ctrl-D works too)", .{});
    say(p, "anything else starting with '(' is evaluated in the live image", .{});
}

/// Returns true when the user asked to quit.
fn interactiveColon(p: *Probe, sc: *Scheme, alive: *bool, line: []const u8) !bool {
    if (std.mem.eql(u8, line, ":quit") or std.mem.eql(u8, line, ":q")) return true;
    if (std.mem.eql(u8, line, ":help") or std.mem.eql(u8, line, ":h")) {
        interactiveHelp(p);
        return false;
    }
    if (std.mem.eql(u8, line, ":kill")) {
        if (!alive.*) {
            say(p, "image already dead; respawning", .{});
        } else {
            const pid = sc.child.id.?;
            try std.posix.kill(pid, .KILL);
            _ = try sc.child.wait(p.io);
            say(p, "sent SIGKILL to pid {d}; respawning and replaying", .{pid});
        }
        try killAndRespawn(p, sc);
        alive.* = true;
        printGreeting(p, sc);
        return false;
    }
    if (std.mem.eql(u8, line, ":commit")) {
        // Generic check: replay must load and evaluate cleanly. (The kernel
        // path lets the image pass a recorded check expression; here the
        // supervisor uses a trivially-true one — the probe still validates
        // that base + pending definitions apply without error.)
        doCommit(p, "#t", "#t") catch |e| {
            say(p, "commit rejected: {s} (old generation kept)", .{@errorName(e)});
            return false;
        };
        say(p, "current generation = {d}", .{try readCurrentGen(p)});
        return false;
    }
    if (std.mem.startsWith(u8, line, ":discard")) {
        const arg = std.mem.trim(u8, line[":discard".len..], " ");
        if (arg.len == 0) {
            say(p, "usage: :discard <name>", .{});
            return false;
        }
        if (try applyCommittedDiscard(p, sc, arg)) {
            say(p, "discarded: '{s}' restored to last committed definition", .{arg});
        } else {
            say(p, "'{s}' has no committed definition; nothing to discard", .{arg});
        }
        return false;
    }
    if (std.mem.eql(u8, line, ":status")) {
        const gen = try readCurrentGen(p);
        const lines = try countJournalLines(p);
        const pend = try journalPendingRedefs(p);
        defer {
            for (pend) |r| {
                p.gpa.free(r.name);
                p.gpa.free(r.source);
            }
            p.gpa.free(pend);
        }
        say(p, "generation = {d}, journal entries = {d}, image alive = {}", .{ gen, lines, alive.* });
        if (pend.len == 0) {
            say(p, "pending (uncommitted) redefines: none", .{});
        } else {
            for (pend) |r| say(p, "pending (uncommitted) redefine: {s}", .{r.name});
        }
        return false;
    }
    if (std.mem.eql(u8, line, ":reset")) {
        say(p, "WARNING: wiping .work back to genesis (journal and generations lost)", .{});
        try cmdReset(p);
        try ensureWork(p);
        try killAndRespawn(p, sc);
        alive.* = true;
        printGreeting(p, sc);
        return false;
    }
    say(p, "unknown colon command; try :help", .{});
    return false;
}

fn cmdInteractive(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    try replayCurrent(p, &sc);
    var alive = true;
    const is_tty = std.c.isatty(std.posix.STDIN_FILENO) != 0;

    say(p, "live-runtime interactive demo (Scheme image under Zig supervision)", .{});
    say(p, "type a form starting with '(' to eval it; bare text runs an agent turn; :help for commands", .{});
    say(p, "try: (kernel.redefine 'greeting \"(define (greeting) \\\"hacked at runtime\\\")\")", .{});
    say(p, "then: (greeting)   then: :kill   and watch the state come back", .{});

    const buf = try p.gpa.alloc(u8, 64 * 1024);
    defer p.gpa.free(buf);
    var reader = std.Io.File.stdin().reader(p.io, buf);
    while (true) {
        if (is_tty) std.Io.File.stdout().writeStreamingAll(p.io, "> ") catch {};
        const maybe_line = reader.interface.takeDelimiter('\n') catch |e| {
            say(p, "stdin read error: {s}", .{@errorName(e)});
            break;
        };
        const raw_line = maybe_line orelse break; // EOF (Ctrl-D) = :quit
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == ':') {
            const quit = interactiveColon(p, &sc, &alive, line) catch |e| {
                say(p, "command failed: {s}", .{@errorName(e)});
                continue;
            };
            if (quit) break;
        } else if (line[0] == '(') {
            interactiveEval(p, &sc, &alive, line) catch |e| {
                say(p, "eval failed: {s}", .{@errorName(e)});
            };
        } else {
            // Bare text: an agent turn (user entry fsynced by the
            // supervisor, then the image's agent loop runs).
            const reply = agentTurn(p, &sc, line) catch |e| blk: {
                if (isChildDeath(e)) {
                    say(p, "image died mid-turn ({s}); respawning and resuming", .{@errorName(e)});
                    try killAndRespawn(p, &sc);
                    alive = true;
                    const r2 = agentResume(p, &sc) catch |e2| {
                        say(p, "resume failed: {s}", .{@errorName(e2)});
                        break :blk null;
                    };
                    break :blk r2;
                }
                say(p, "agent turn failed: {s}", .{@errorName(e)});
                break :blk null;
            };
            if (reply) |r| {
                defer p.gpa.free(r);
                say(p, "assistant: {s}", .{r});
            }
        }
    }
    if (alive) sc.shutdown(p);
    say(p, "image shut down; bye", .{});
}

// ---------- protocol hardening probes (spike-002) ----------

const adversarial_unicode = [_][]const u8{
    "λ≈∑π", "日本語テスト", "🚀🔥✨", "Ünïcödé", "α β γ δ", " mixed 混合",
};

/// Deterministic adversarial string generator: quotes, backslashes, literal
/// `\x..;` text, control bytes (incl. NUL, DEL), UTF-8, long mixes.
fn genAdversarial(p: *Probe, rand: std.Random, i: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(p.gpa);
    switch (i % 8) {
        0 => { // quote/backslash soup
            const n = rand.intRangeAtMost(usize, 1, 40);
            for (0..n) |_| try list.append(p.gpa, if (rand.boolean()) '"' else '\\');
        },
        1 => { // literal \x..; sequences as DATA (not escapes)
            const pieces = [_][]const u8{ "\\x41;", "\\xZZ;", "\\x", "\\;", "\\\\x0;", "\\x1f600;" };
            const n = rand.intRangeAtMost(usize, 1, 5);
            for (0..n) |_| try list.appendSlice(p.gpa, pieces[rand.uintLessThan(usize, pieces.len)]);
        },
        2 => { // control bytes incl NUL and DEL
            const n = rand.intRangeAtMost(usize, 1, 30);
            for (0..n) |_| {
                const c: u8 = if (rand.boolean()) rand.intRangeAtMost(u8, 0x00, 0x1f) else 0x7f;
                try list.append(p.gpa, c);
            }
        },
        3 => { // UTF-8 multibyte
            const n = rand.intRangeAtMost(usize, 1, 3);
            for (0..n) |_| try list.appendSlice(p.gpa, adversarial_unicode[rand.uintLessThan(usize, adversarial_unicode.len)]);
        },
        4 => { // printable ASCII
            const n = rand.intRangeAtMost(usize, 1, 120);
            for (0..n) |_| try list.append(p.gpa, rand.intRangeAtMost(u8, 0x20, 0x7e));
        },
        5 => { // whitespace mixes
            const pieces = [_][]const u8{ "\n", "\r\n", "\t", "a\nb", "\r", "end\n" };
            const n = rand.intRangeAtMost(usize, 1, 8);
            for (0..n) |_| try list.appendSlice(p.gpa, pieces[rand.uintLessThan(usize, pieces.len)]);
        },
        6 => { // long mixed (up to ~4 KB)
            const n = rand.intRangeAtMost(usize, 100, 4000);
            for (0..n) |_| {
                const pick = rand.uintLessThan(u8, 10);
                const c: u8 = switch (pick) {
                    0 => '"',
                    1 => '\\',
                    2 => rand.intRangeAtMost(u8, 0x00, 0x1f),
                    else => rand.intRangeAtMost(u8, 0x20, 0x7e),
                };
                try list.append(p.gpa, c);
            }
        },
        7 => { // kitchen sink
            try list.appendSlice(p.gpa, "pre\"\\\\\x00\x1f\x7f");
            try list.appendSlice(p.gpa, adversarial_unicode[rand.uintLessThan(usize, adversarial_unicode.len)]);
            try list.appendSlice(p.gpa, "\\x41;\"tail\n");
        },
        else => unreachable,
    }
    return list.toOwnedSlice(p.gpa);
}

fn cmdFuzz(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    defer sc.kill(p);

    // Part 1: adversarial string round-trip Zig -> Chez -> Zig.
    var rng = std.Random.DefaultPrng.init(0x5eed_0002);
    const rand = rng.random();
    const n = 1500;
    var failures: u32 = 0;
    for (0..n) |i| {
        const s = try genAdversarial(p, rand, i);
        defer p.gpa.free(s);
        const esc = try escapeSchemeString(p.gpa, s);
        defer p.gpa.free(esc);
        const frame = try std.fmt.allocPrint(p.gpa, "(kernel.echo \"{s}\")", .{esc});
        defer p.gpa.free(frame);
        try sendFrame(p, &sc, frame);
        const r = try waitReply(p, &sc);
        switch (r) {
            .ok => |v| {
                defer p.gpa.free(v);
                if (!std.mem.eql(u8, v, s)) {
                    failures += 1;
                    if (failures <= 5) {
                        var diff: usize = 0;
                        while (diff < @min(s.len, v.len) and s[diff] == v[diff]) diff += 1;
                        say(p, "mismatch [{d}]: len {d}->{d}, first diff at byte {d}", .{ i, s.len, v.len, diff });
                    }
                }
            },
            .err => |msg| {
                defer p.gpa.free(msg);
                failures += 1;
                if (failures <= 5) say(p, "scheme error [{d}]: {s}", .{ i, msg });
            },
        }
    }
    if (failures > 0) {
        say(p, "fuzz: {d}/{d} strings FAILED round-trip", .{ failures, n });
        return error.FuzzFailures;
    }
    say(p, "fuzz: {d} adversarial strings round-tripped byte-identically (seed 0x5eed0002)", .{n});

    // Part 2: supervisor -> image oversize frame. The image must discard
    // the payload, reply (err "frame-too-large"), and stay alive.
    const big = try p.gpa.alloc(u8, max_frame_bytes + 64);
    defer p.gpa.free(big);
    @memset(big, 'a');
    try sendFrame(p, &sc, big);
    const r2 = try waitReply(p, &sc);
    switch (r2) {
        .ok => |v| {
            p.gpa.free(v);
            return error.OversizeNotRejected;
        },
        .err => |msg| {
            defer p.gpa.free(msg);
            if (std.mem.indexOf(u8, msg, "frame-too-large") == null)
                return error.OversizeNotRejected;
            say(p, "oversize inbound frame ({d} bytes) rejected by image: {s}", .{ big.len, msg });
        },
    }
    const alive = try requestEval(p, &sc, "(+ 1 1)");
    defer p.gpa.free(alive);
    if (!std.mem.eql(u8, alive, "2")) return error.ImageDeadAfterOversize;
    say(p, "image still alive after rejecting oversize frame", .{});

    // Part 3: image -> supervisor oversize reply. The supervisor must
    // reject the frame, kill + respawn the image, and keep working.
    _ = requestEval(p, &sc, "(make-string 5000000 #\\a)") catch |e| blk: {
        if (e != error.FrameTooLarge) return e;
        say(p, "oversize reply from image rejected; killing and respawning", .{});
        try killAndRespawn(p, &sc);
        break :blk;
    };
    const v3 = try requestEval(p, &sc, "(+ 2 3)");
    defer p.gpa.free(v3);
    if (!std.mem.eql(u8, v3, "5")) return error.SupervisorBrokenAfterOversize;
    say(p, "PASS: {d} round-trips byte-identical; frame caps enforced both sides; supervisor survived oversize image reply", .{n});
}

fn cmdInspect(p: *Probe) !void {
    try ensureWork(p);
    var sc = try Scheme.spawn(p);
    defer sc.kill(p);
    try replayCurrent(p, &sc);

    // committed name (genesis binding lives in base.ss => generation 0)
    const c = try requestEval(p, &sc, "(kernel.inspect 'greeting)");
    defer p.gpa.free(c);
    say(p, "inspect greeting: {s}", .{c});
    if (std.mem.indexOf(u8, c, "(status committed)") == null) return error.InspectStatusWrong;
    if (std.mem.indexOf(u8, c, "(generation 0)") == null) return error.InspectGenWrong;
    if (std.mem.indexOf(u8, c, "hello, live image") == null) return error.InspectSourceMissing;
    if (std.mem.indexOf(u8, c, "(dependents ())") == null) return error.InspectDepsWrong;

    // pending name whose source mentions greeting => greeting gains a dependent
    const src = "(define (shout) (string-upcase (greeting)))";
    const esc = try escapeSchemeString(p.gpa, src);
    defer p.gpa.free(esc);
    const call = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'shout \"{s}\")", .{esc});
    defer p.gpa.free(call);
    const rv = try requestEval(p, &sc, call);
    p.gpa.free(rv);

    const pd = try requestEval(p, &sc, "(kernel.inspect 'shout)");
    defer p.gpa.free(pd);
    say(p, "inspect shout: {s}", .{pd});
    if (std.mem.indexOf(u8, pd, "(status pending)") == null) return error.InspectStatusWrong;
    if (std.mem.indexOf(u8, pd, "(generation #f)") == null) return error.InspectGenWrong;
    if (std.mem.indexOf(u8, pd, "string-upcase") == null) return error.InspectSourceMissing;

    const c2 = try requestEval(p, &sc, "(kernel.inspect 'greeting)");
    defer p.gpa.free(c2);
    say(p, "inspect greeting (after pending shout): {s}", .{c2});
    if (std.mem.indexOf(u8, c2, "(dependents (shout))") == null) return error.InspectDepsWrong;

    // unknown name
    const u = try requestEval(p, &sc, "(kernel.inspect 'no-such-binding)");
    defer p.gpa.free(u);
    say(p, "inspect no-such-binding: {s}", .{u});
    if (std.mem.indexOf(u8, u, "(status unknown)") == null) return error.InspectStatusWrong;
    if (std.mem.indexOf(u8, u, "(source #f)") == null) return error.InspectSourceMissing;
    if (std.mem.indexOf(u8, u, "(generation #f)") == null) return error.InspectGenWrong;
    if (std.mem.indexOf(u8, u, "(dependents ())") == null) return error.InspectDepsWrong;

    say(p, "PASS: kernel.inspect returns source + status + generation + dependents for committed/pending/unknown", .{});
}

// ---------- agent driver + probe (spike-003) ----------

/// Drive one agent turn: the SUPERVISOR appends the user entry (fsync)
/// before any provider work, then the image runs its loop.
fn agentTurn(p: *Probe, sc: *Scheme, user_text: []const u8) ![]u8 {
    try convAppendUser(p, user_text);
    return requestEval(p, sc, "(agent-continue)");
}

/// Resume an incomplete turn after respawn (retry from last durable entry).
fn agentResume(p: *Probe, sc: *Scheme) ![]u8 {
    const kind = try convLastKind(p);
    switch (kind) {
        .user, .tool_call, .tool_result => return requestEval(p, sc, "(agent-continue)"),
        .assistant => return error.TurnAlreadyComplete,
        .empty => return error.EmptyConversation,
    }
}

fn convReadAlloc(p: *Probe) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(p.io, conv_path, p.gpa, .limited(max_file));
}

/// Background killer for the mid-turn SIGKILL scenario: fires the instant
/// the Nth tool-call entry is durable in the conversation store — i.e.
/// after the tool-call append but (almost certainly) before the turn
/// completes. Outcome assertions are timing-independent.
const KillCtx = struct {
    p: *Probe,
    pid: std.process.Child.Id,
    target_tool_calls: usize,
    fired: bool = false,
};

fn killOnToolCall(ctx: *KillCtx) void {
    var waited_us: i64 = 0;
    while (waited_us < 10_000_000) : (waited_us += 200) {
        const n = convCountPrefix(ctx.p, "(tool-call ") catch 0;
        if (n >= ctx.target_tool_calls) {
            std.posix.kill(ctx.pid, .KILL) catch {};
            ctx.fired = true;
            return;
        }
        Io.sleep(ctx.p.io, Io.Duration.fromMicroseconds(200), .awake) catch return;
    }
}

fn cmdAgent(p: *Probe) !void {
    // Self-contained deterministic scenario: rebuild .work from scratch.
    std.Io.Dir.cwd().deleteTree(p.io, ".work") catch {};
    try ensureWork(p);
    try writeSmallFile(p, workspace_path ++ "/notes.txt", "the answer is 42\n");
    try writeSmallFile(p, provider_script_path,
        \\(say "hello, policy v1 speaking")
        \\(call fs.read ("notes.txt"))
        \\(say "the file says 42")
        \\(call fs.read ("../journal.sexp"))
        \\(say "escape was rejected, good")
        \\(say "policy v2 now answering")
        \\(say "v2 survived the kill")
        \\(call fs.read ("notes.txt"))
        \\(say "mid-turn recovery complete")
        \\
    );

    var sc = try Scheme.spawn(p);
    try replayCurrent(p, &sc);

    // --- 1. plain turn: user entry durable BEFORE provider work; echo proves policy
    const r1 = try agentTurn(p, &sc, "hi there");
    defer p.gpa.free(r1);
    if (!std.mem.eql(u8, r1, "hello, policy v1 speaking")) return error.Turn1Wrong;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (!std.mem.startsWith(u8, conv, "(user 0 ")) return error.UserEntryNotFirst;
        if (std.mem.indexOf(u8, conv, "POLICY-V1") == null) return error.EchoMissing;
    }
    say(p, "turn 1 (plain): \"{s}\" — user entry fsynced first, echo proves POLICY-V1", .{r1});

    // --- 2. tool round: jailed fs.read executed, result appended
    const r2 = try agentTurn(p, &sc, "read notes.txt");
    defer p.gpa.free(r2);
    if (!std.mem.eql(u8, r2, "the file says 42")) return error.Turn2Wrong;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (std.mem.indexOf(u8, conv, "(tool-call ") == null or
            std.mem.indexOf(u8, conv, "fs.read \"notes.txt\"") == null) return error.ToolCallMissing;
        if (std.mem.indexOf(u8, conv, "(tool-result ") == null or
            std.mem.indexOf(u8, conv, "the answer is 42") == null) return error.ToolResultMissing;
    }
    say(p, "turn 2 (tool round): fs.read notes.txt -> \"the answer is 42\" -> \"{s}\"", .{r2});

    // --- 3. jail escape attempt rejected, provider continues
    const r3 = try agentTurn(p, &sc, "read ../journal.sexp please");
    defer p.gpa.free(r3);
    if (!std.mem.eql(u8, r3, "escape was rejected, good")) return error.Turn3Wrong;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (std.mem.indexOf(u8, conv, "JailEscape") == null) return error.EscapeNotRejected;
    }
    say(p, "turn 3 (jail): fs.read ../journal.sexp rejected (JailEscape), turn completed", .{});

    // --- 4. policy redefine mid-conversation (pending, uncommitted)
    const v2src = "(define (system-prompt) \"POLICY-V2: answer tersely.\")";
    const v2esc = try escapeSchemeString(p.gpa, v2src);
    defer p.gpa.free(v2esc);
    const v2call = try std.fmt.allocPrint(p.gpa, "(kernel.redefine 'system-prompt \"{s}\")", .{v2esc});
    defer p.gpa.free(v2call);
    const rv = try requestEval(p, &sc, v2call);
    p.gpa.free(rv);
    const r4 = try agentTurn(p, &sc, "keep going");
    defer p.gpa.free(r4);
    if (!std.mem.eql(u8, r4, "policy v2 now answering")) return error.Turn4Wrong;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (std.mem.indexOf(u8, conv, "POLICY-V2: answer tersely.") == null) return error.EchoMissing;
    }
    say(p, "turn 4 (policy redefine): provider echo proves redefined system-prompt (POLICY-V2)", .{});

    // --- 5. SIGKILL between turns: history rebuilt from store AND pending
    //        policy redefine still active after replay
    {
        const pid = sc.child.id.?;
        try std.posix.kill(pid, .KILL);
        _ = try sc.child.wait(p.io);
        say(p, "SIGKILL between turns (pid {d}); respawning", .{pid});
    }
    sc = try Scheme.spawn(p);
    try replayCurrent(p, &sc);
    const hlen = try requestEval(p, &sc, "(length (conv-history))");
    defer p.gpa.free(hlen);
    if (!std.mem.eql(u8, hlen, "12")) return error.HistoryNotRebuilt;
    say(p, "image rebuilt context: (length (conv-history)) = {s} entries", .{hlen});
    const r5 = try agentTurn(p, &sc, "still there?");
    defer p.gpa.free(r5);
    if (!std.mem.eql(u8, r5, "v2 survived the kill")) return error.Turn5Wrong;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (std.mem.indexOf(u8, conv, "\"v2 survived the kill\" \"POLICY-V2") == null)
            return error.PolicyNotSurvived;
    }
    say(p, "turn 5 (post-kill): pending POLICY-V2 still active, conversation continues", .{});

    // --- 6. SIGKILL mid-turn: background killer fires when the 3rd
    //        tool-call lands durable; recovery retries from last entry.
    const turn6_tool_calls = 3; // turns 2 and 3 already consumed two
    var ctx: KillCtx = .{ .p = p, .pid = sc.child.id.?, .target_tool_calls = turn6_tool_calls };
    const killer = try std.Thread.spawn(.{}, killOnToolCall, .{&ctx});
    const r6: ?[]u8 = agentTurn(p, &sc, "read it again, then die") catch |e| blk: {
        if (!isChildDeath(e)) {
            killer.join();
            return e;
        }
        break :blk null;
    };
    killer.join();
    if (!ctx.fired) return error.MidTurnKillDidNotFire;
    if (r6) |v| p.gpa.free(v);
    // Reap the (almost certainly dead) child and respawn; killAndRespawn
    // is idempotent if the kill somehow raced to completion.
    try killAndRespawn(p, &sc);
    say(p, "mid-turn SIGKILL fired (tool-call durable, turn in flight); respawned", .{});
    const final_say: []u8 = agentResume(p, &sc) catch |e| blk: {
        if (e == error.TurnAlreadyComplete) {
            say(p, "turn had already completed before the kill landed; verifying store", .{});
            break :blk try p.gpa.dupe(u8, "");
        }
        return e;
    };
    defer p.gpa.free(final_say);
    if (final_say.len > 0 and !std.mem.eql(u8, final_say, "mid-turn recovery complete"))
        return error.Turn6Wrong;

    // Invariants, timing-independent: no duplicates, no half entries,
    // final assistant echo still POLICY-V2.
    try convAssertClean(p);
    const users = try convCountPrefix(p, "(user ");
    const assistants = try convCountPrefix(p, "(assistant ");
    const calls = try convCountPrefix(p, "(tool-call ");
    const results = try convCountPrefix(p, "(tool-result ");
    if (users != 6) return error.DuplicateUserEntry;
    if (assistants != 6 or calls != 3 or results != 3) return error.HalfEntryDetected;
    {
        const conv = try convReadAlloc(p);
        defer p.gpa.free(conv);
        if (std.mem.indexOf(u8, conv, "\"mid-turn recovery complete\" \"POLICY-V2") == null)
            return error.Turn6Wrong;
    }
    say(p, "recovery: user={d} assistant={d} tool-call={d} tool-result={d}; no dups, no half entries, clean tail", .{ users, assistants, calls, results });
    say(p, "PASS: agent loop in the image; policy redefine -> kill -> recovery all proven by transcript", .{});
}
