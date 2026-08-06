//! rpc-v1 NDJSON line framing (zag-cli).
//!
//! Bounded line reader with resync-at-newline and a plain line writer. No
//! protocol semantics (rpc-v1 §3): exactly one JSON object per `\n`-terminated
//! line; inbound lines are capped at `frame_cap` (4 MiB); an over-cap line is
//! reported as `.too_long` and the reader drains to the next newline, so the
//! caller can answer with an error frame and continue reading.
//!
//! The reader is fd-based and **non-blocking after `fill`**: the host polls
//! stdin (and the SIGINT self-pipe) with a bounded timeout, calls `fill` only
//! when stdin is readable, then serves complete frames from the accumulated
//! buffer. A client that stalls mid-frame therefore never wedges the host
//! loop — a SIGINT still wakes it via the self-pipe (rpc-v1 §8.3).
//!
//! Raw reads (not `Io.Reader`) keep the host thread independent of the
//! `Io.Threaded` runtime; EINTR loops internally.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Inbound line cap (rpc-v1 §10). The server never buffers past this.
pub const frame_cap: usize = 4 * 1024 * 1024;

pub const ReadError = error{ OutOfMemory, IoFailed };

/// Result of one `takeFrame()` call. `null` means no complete frame is in
/// the buffer yet; call `fill`/`takeFrame` again after more input arrives.
pub const Next = union(enum) {
    /// One complete line without its trailing `\n`. gpa-owned; caller frees.
    line: []u8,
    /// Clean end of stream (no partial frame buffered).
    eof,
    /// A line exceeded `frame_cap`. The reader has already discarded the
    /// buffered prefix; subsequent input up to the next newline is drained.
    /// Caller responds `invalid_arguments` with `id: null` and continues.
    too_long,
};

pub const FrameReader = struct {
    gpa: std.mem.Allocator,
    fd: posix.fd_t,
    /// Bytes read but not yet consumed by frame scanning.
    pending: std.ArrayList(u8) = .empty,
    /// True while discarding an over-cap line up to its terminating newline.
    draining: bool = false,
    eof: bool = false,

    pub fn init(gpa: std.mem.Allocator, fd: posix.fd_t) FrameReader {
        return .{ .gpa = gpa, .fd = fd };
    }

    pub fn deinit(self: *FrameReader) void {
        self.pending.deinit(self.gpa);
        self.* = undefined;
    }

    /// Read whatever is currently available into the buffer. Returns true when
    /// bytes were added or EOF was reached, false when the read would block.
    /// Call only after polling the fd readable; on a blocking fd a readable
    /// poll result guarantees this does not block.
    pub fn fill(self: *FrameReader) ReadError!bool {
        if (self.eof) return true;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(self.fd, &chunk) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return error.IoFailed,
            };
            if (n == 0) {
                self.eof = true;
                return true;
            }
            try self.pending.appendSlice(self.gpa, chunk[0..n]);
            return true;
        }
    }

    /// Serve one complete frame from the buffer, if available. `.too_long` is
    /// reported exactly once per over-cap line (at the moment the cap fires);
    /// the resync drain is internal.
    pub fn takeFrame(self: *FrameReader) ReadError!?Next {
        if (self.draining) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |idx| {
                self.dropPrefix(idx + 1);
                self.draining = false;
            } else {
                self.pending.clearRetainingCapacity();
                if (self.eof) self.draining = false;
            }
        }
        if (!self.eof) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |idx| {
                if (idx > frame_cap) {
                    self.dropPrefix(idx + 1);
                    return .too_long;
                }
                const line = try self.gpa.dupe(u8, self.pending.items[0..idx]);
                self.dropPrefix(idx + 1);
                return .{ .line = line };
            }
            if (self.pending.items.len > frame_cap) {
                // No newline and past the cap: stop buffering; drain the rest.
                self.pending.clearRetainingCapacity();
                self.draining = true;
                return .too_long;
            }
            return null;
        }
        // EOF: deliver a final unterminated line if any bytes remain.
        if (self.pending.items.len > 0) {
            const line = try self.gpa.dupe(u8, self.pending.items);
            self.pending.clearRetainingCapacity();
            return .{ .line = line };
        }
        return .eof;
    }

    fn dropPrefix(self: *FrameReader, n: usize) void {
        const rest = self.pending.items[n..];
        std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
        self.pending.items.len = rest.len;
    }
};

/// Plain `\n`-terminated line writer over the shared stdout writer.
/// The server serializes every frame under one writer mutex before calling
/// this; the writer itself is not internally synchronized.
pub const FrameWriter = struct {
    out: *std.Io.Writer,

    pub fn init(out: *std.Io.Writer) FrameWriter {
        return .{ .out = out };
    }

    /// Write `line` + `\n`. `line` must not contain a literal `\n` (a literal
    /// newline inside a value would split the frame — the JSON writer escapes
    /// string values, so this invariant holds for all protocol frames).
    pub fn writeLine(self: *FrameWriter, line: []const u8) error{ IoFailed, OutOfMemory, WriteFailed }!void {
        try self.out.writeAll(line);
        try self.out.writeAll("\n");
    }

    pub fn flush(self: *FrameWriter) error{IoFailed}!void {
        try self.out.flush();
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Portable nonblocking pipe for framing tests (mirrors sigint.sys.pipe:
/// raw Linux syscalls, libc elsewhere — no link_libc needed on Linux).
fn pipeNonblocking() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = .{ -1, -1 };
    if (builtin.os.tag == .linux) {
        var flags: std.os.linux.O = .{};
        flags.NONBLOCK = true;
        flags.CLOEXEC = true;
        const rc = std.os.linux.pipe2(&fds, flags);
        if (std.os.linux.errno(rc) == .SUCCESS) return fds;
        return error.PipeFailed;
    }
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    const fl = std.c.fcntl(fds[0], std.c.F.GETFL);
    if (fl < 0) return error.PipeFailed;
    if (std.c.fcntl(fds[0], std.c.F.SETFL, fl | 0x0004) < 0) return error.PipeFailed; // O_NONBLOCK
    return fds;
}

/// In-memory reader seam: a pipe pair with a writer thread is overkill for
/// framing unit tests; instead drive `FrameReader` via a raw pipe we write
/// into directly (fork-free, deterministic).
const PipeFeed = struct {
    gpa: std.mem.Allocator,
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    fn open(gpa: std.mem.Allocator) !PipeFeed {
        const fds = try pipeNonblocking();
        return .{ .gpa = gpa, .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn close(self: *PipeFeed) void {
        rawClose(self.read_fd);
        rawClose(self.write_fd);
        self.* = undefined;
    }

    fn feed(self: *PipeFeed, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try rawWrite(self.write_fd, bytes[off..]);
            off += n;
        }
    }
};

/// Portable raw fd close (Linux syscall / libc elsewhere), for tests only.
fn rawClose(fd: posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

/// Portable raw fd write (Linux syscall / libc elsewhere), for tests only.
fn rawWrite(fd: posix.fd_t, bytes: []const u8) !usize {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        return rc;
    }
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return error.WriteFailed;
    return @intCast(rc);
}

test "FrameReader single line" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    try feed.feed("hello\n");
    try testing.expect(try fr.fill());
    switch ((try fr.takeFrame()).?) {
        .line => |l| {
            defer gpa.free(l);
            try testing.expectEqualStrings("hello", l);
        },
        else => return error.TestUnexpectedResult,
    }
    // Nothing left: poll-style null.
    try testing.expect(!try fr.fill());
    try testing.expect((try fr.takeFrame()) == null);
}

test "FrameReader pipelined frames across fills" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    try feed.feed("first\nsecond\nthird\n");
    const expect = [_][]const u8{ "first", "second", "third" };
    var i: usize = 0;
    while (true) {
        _ = try fr.fill();
        const maybe = try fr.takeFrame();
        const nxt = maybe orelse break;
        switch (nxt) {
            .line => |l| {
                defer gpa.free(l);
                try testing.expectEqualStrings(expect[i], l);
                i += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(expect.len, i);
}

test "FrameReader partial frame returns none then completes" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    try feed.feed("{\"a\":");
    try testing.expect(try fr.fill());
    try testing.expect((try fr.takeFrame()) == null); // no newline yet
    try feed.feed("1}\n");
    try testing.expect(try fr.fill());
    switch ((try fr.takeFrame()).?) {
        .line => |l| {
            defer gpa.free(l);
            try testing.expectEqualStrings("{\"a\":1}", l);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "FrameReader empty line and unterminated final line" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    try feed.feed("\nfinal");
    try testing.expect(try fr.fill());
    switch ((try fr.takeFrame()).?) {
        .line => |l| {
            defer gpa.free(l);
            try testing.expectEqual(@as(usize, 0), l.len);
        },
        else => return error.TestUnexpectedResult,
    }
    // EOF after the last partial line: delivered as a line.
    rawClose(feed.write_fd);
    feed.write_fd = -1;
    try testing.expect(try fr.fill());
    switch ((try fr.takeFrame()).?) {
        .line => |l| {
            defer gpa.free(l);
            try testing.expectEqualStrings("final", l);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Next.eof, (try fr.takeFrame()).?);
}

/// Feed `bytes` in ≤ 8 KiB steps, draining the reader after each step so a
/// multi-MiB payload never blocks on the pipe buffer.
fn feedChunked(feed: *PipeFeed, fr: *FrameReader, bytes: []const u8) !void {
    var off: usize = 0;
    const step: usize = 8192;
    while (off < bytes.len) {
        const n = @min(step, bytes.len - off);
        try feed.feed(bytes[off..][0..n]);
        off += n;
        _ = try fr.fill();
    }
}

test "FrameReader over-cap line reports too_long and resyncs" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    const big = "x" ** (frame_cap + 1);
    try feedChunked(&feed, &fr, big ++ "\nnext\n");
    var reported: u32 = 0;
    var loop: u32 = 0;
    while (loop < 1000) : (loop += 1) {
        _ = try fr.fill();
        const maybe = try fr.takeFrame();
        const nxt = maybe orelse break;
        switch (nxt) {
            .too_long => reported += 1,
            .line => |l| {
                defer gpa.free(l);
                try testing.expectEqualStrings("next", l);
                break;
            },
            else => break,
        }
    }
    try testing.expectEqual(@as(u32, 1), reported);
}

test "FrameReader exact-cap line is accepted" {
    const gpa = testing.allocator;
    var feed = try PipeFeed.open(gpa);
    defer feed.close();
    var fr = FrameReader.init(gpa, feed.read_fd);
    defer fr.deinit();
    const exact = "y" ** frame_cap;
    try feedChunked(&feed, &fr, exact ++ "\n");
    var loop: u32 = 0;
    while (loop < 1000) : (loop += 1) {
        _ = try fr.fill();
        const maybe = try fr.takeFrame();
        const nxt = maybe orelse break;
        switch (nxt) {
            .line => |l| {
                defer gpa.free(l);
                try testing.expectEqual(exact.len, l.len);
                break;
            },
            else => break,
        }
    }
}

test "FrameWriter writes line plus newline" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var fw = FrameWriter.init(&out.writer);
    try fw.writeLine("{\"a\":1}");
    try fw.writeLine("{}");
    try testing.expectEqualStrings("{\"a\":1}\n{}\n", out.written());
}
