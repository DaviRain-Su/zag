//! Quarantined terminal backend (tui-vaxis-001): vaxis `Tty`/`Vaxis`/`Loop`
//! wrapper + bridge thread. Raw termios / alt-screen / size / key parsing
//! are owned by vaxis; this module keeps the outward shape app.zig +
//! tui_entry.zig depend on (open/enterRawAlt/restore/size/wake-pipe family)
//! and adds the event ring the app drains on its wake pipe.
//!
//! ISIG shim: vaxis `makeRaw` clears ISIG (tty.zig), but zag-tui keeps ISIG
//! ON so the Guard Ctrl+C → SIGINT → host wake fd two-phase escape path
//! stays byte-identical (tui-minimal contract). Re-enabled after `Tty.init`;
//! `Tty.deinit` restores the exact original termios (fixture asserts ISIG
//! restored equal).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const vaxis = @import("vaxis");
const c = @import("constants.zig");

pub const Size = struct {
    cols: u16,
    rows: u16,

    pub fn isBelowMinimum(self: Size) bool {
        return self.cols < c.min_cols or self.rows < c.min_rows;
    }

    pub fn isConstrained(self: Size) bool {
        return self.cols < c.constrained_cols or self.rows < c.constrained_rows;
    }
};

/// Bridge-ring event vocabulary. `key_press`/`winsize` come from vaxis's
/// input thread via `loop.nextEvent()`; `quit` is posted by `restore()` to
/// unblock a bridge blocked in `nextEvent`.
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    quit,
};

/// Fixed ring capacity between the bridge thread and the app (drop-on-full
/// push, mirroring the wake-pipe drop-on-full idiom).
pub const ring_capacity = 256;

const tty_buffer_size = 4096;

const O_NONBLOCK_LINUX: u32 = 0o4000;
const O_NONBLOCK_MAC: c_int = 0x0004;

/// Per-frame line store: draw functions format lines here so the vaxis
/// screen's cell graphemes (borrowed slices into the store) stay valid from
/// `drawFrame` through `vx.render()` (and, for test fixtures, until the next
/// paint). The Terminal owns one; renderFrame resets it each frame.
pub const LineStore = struct {
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,

    /// Append one formatted line; returns a slice valid until the next
    /// `len = 0` reset. Null when the store is full (line skipped).
    pub fn format(self: *LineStore, comptime fmt: []const u8, args: anytype) ?[]const u8 {
        if (self.len >= self.buf.len) return null;
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return null;
        self.len += s.len;
        return s;
    }
};

pub const Terminal = struct {
    gpa: std.mem.Allocator,
    /// Heap-owned vaxis objects: open() returns Terminal by value, and the
    /// Loop's `*Tty`/`*Vaxis` pointers must stay stable across the move.
    tty: *vaxis.Tty,
    vx: *vaxis.Vaxis,
    threaded: *std.Io.Threaded,
    tty_buf: *[tty_buffer_size]u8,
    /// Heap-owned: `vx.env_map` points at it, so it must outlive the value
    /// move in open().
    env_map: *std.process.Environ.Map,
    loop: vaxis.Loop(Event),
    ring: vaxis.Queue(Event, ring_capacity),
    bridge: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    /// App's wake pipe write end: the bridge writes one byte per event so
    /// the app's poll ([wake_r, host]) wakes to drain the ring.
    wake_w: posix.fd_t = -1,
    /// Per-frame line store for renderer cell slices (see LineStore).
    scratch: LineStore = .{},
    /// Persistent markdown parse arena (tui-markdown-001): the vaxis screen
    /// and its diff target (`screen_last`) borrow grapheme slices from the
    /// koino Text nodes, so the arena lives as long as the Terminal and is
    /// reset (retain_capacity — memory stays mapped) at the top of each
    /// renderFrame. Old slices therefore always point at valid memory.
    md_arena: std.heap.ArenaAllocator,
    /// restore() is one-shot teardown.
    closed: bool = false,

    /// Tty.init → vaxis.init → ISIG shim. NO alt screen / queries / bridge
    /// yet: app.zig checks `size()` (and exits on below-minimum) before
    /// `enterRawAlt()`, and the PTY fixture asserts no `\x1b[?1049h` is ever
    /// written on the below-minimum path.
    pub fn open(gpa: std.mem.Allocator, wake_w: posix.fd_t) anyerror!Terminal {
        if (!isFdTty(posix.STDIN_FILENO)) return error.NotATty;
        if (!isFdTty(posix.STDOUT_FILENO)) return error.NotATty;

        const threaded = try gpa.create(std.Io.Threaded);
        errdefer {
            threaded.deinit();
            gpa.destroy(threaded);
        }
        threaded.* = std.Io.Threaded.init(gpa, .{});
        const io = threaded.io();

        const tty_buf = try gpa.create([tty_buffer_size]u8);
        errdefer gpa.destroy(tty_buf);
        const tty = try gpa.create(vaxis.Tty);
        errdefer gpa.destroy(tty);
        tty.* = try vaxis.Tty.init(io, tty_buf);
        errdefer tty.deinit();

        // ISIG shim: makeRaw cleared ISIG; the Guard Ctrl+C path requires it
        // ON. Everything else stays raw (ICANON/ECHO/IXON off etc.).
        const T = @TypeOf(tty.*);
        if (@hasField(T, "fd")) {
            reenableIsig(tty.fd.handle) catch {};
        }

        var env_map = try gpa.create(std.process.Environ.Map);
        errdefer {
            env_map.deinit();
            gpa.destroy(env_map);
        }
        env_map.* = std.process.Environ.Map.init(gpa);

        const vx = try gpa.create(vaxis.Vaxis);
        errdefer gpa.destroy(vx);
        vx.* = try vaxis.init(io, gpa, env_map, .{});

        return .{
            .gpa = gpa,
            .tty = tty,
            .vx = vx,
            .threaded = threaded,
            .tty_buf = tty_buf,
            .env_map = env_map,
            .loop = vaxis.Loop(Event).init(io, tty, vx),
            .ring = vaxis.Queue(Event, ring_capacity).init(io),
            .wake_w = wake_w,
            .md_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Alt screen → SIGWINCH handler → input thread → best-effort queries →
    /// initial resize → bridge thread. Order matters: the loop's input thread
    /// must be running before `queryTerminal` so a DA1 answer can wake its
    /// futex; the bridge must start after so no event is missed.
    pub fn enterRawAlt(self: *Terminal) error{WriteFailed}!void {
        self.vx.enterAltScreen(self.tty.writer()) catch return error.WriteFailed;
        self.loop.installResizeHandler() catch {};
        self.loop.start() catch return error.WriteFailed;
        // Best-effort capability queries; failures degrade to defaults.
        self.vx.queryTerminal(self.tty.writer(), .fromMilliseconds(250)) catch {};
        const ws = self.tty.getWinsize() catch @as(vaxis.Winsize, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
        self.vx.resize(self.gpa, self.tty.writer(), ws) catch {};
        self.bridge = std.Thread.spawn(.{}, bridgeMain, .{self}) catch return error.WriteFailed;
    }

    /// One-shot teardown: stop the bridge → leave the alt screen + restore
    /// the exact original termios. vaxis's own input thread is deliberately
    /// left running: its blocking read can only be interrupted by terminal
    /// data (`loop.stop()` writes a DSR and waits for the answer — the PTY
    /// process fixture has no emulator to answer, so that await would hang
    /// the child forever). The process exits right after restore, so the
    /// thread and the Threaded pool are reclaimed by the OS. tty/vx/threaded
    /// stay heap-live (not freed) so the blocked input thread never touches
    /// freed memory.
    pub fn restore(self: *Terminal) error{WriteFailed}!void {
        if (self.closed) return;
        self.closed = true;

        if (self.bridge) |*th| {
            self.quit.store(true, .release);
            // Unblock a bridge blocked in nextEvent (also flushes any last
            // event the input thread posted).
            self.loop.postEvent(.quit) catch {};
            th.join();
            self.bridge = null;
            // Empty the loop queue so the input thread can never block on a
            // full queue while the process is exiting.
            while (self.loop.tryEvent() catch null) |_| {}
        }
        // resetState: leaves the alt screen (rmcup), shows the cursor.
        self.vx.deinit(self.gpa, self.tty.writer());
        // Restores the exact original termios (ISIG included).
        self.tty.deinit();
        self.env_map.deinit();
        // The markdown parse arena (grapheme source for the screen cells).
        self.md_arena.deinit();
    }

    /// Live terminal geometry (vaxis dims; ioctl re-read every call so the
    /// app's paint size-recheck stays a real belt-and-braces).
    pub fn size(self: *const Terminal) Size {
        const ws = self.tty.getWinsize() catch return .{ .cols = 80, .rows = 24 };
        return .{ .cols = ws.cols, .rows = ws.rows };
    }

    /// Resize the vaxis screen to a winsize event's geometry. Called from the
    /// app's wake_r drain; `renderFrame` re-checks as belt-and-braces.
    pub fn resize(self: *Terminal, winsize: vaxis.Winsize) void {
        self.vx.resize(self.gpa, self.tty.writer(), winsize) catch {};
    }

    /// Keep the vaxis screen sized to `sz` even if a winsize event was
    /// missed (paint's ioctl re-check path).
    pub fn ensureSize(self: *Terminal, sz: Size) void {
        if (self.vx.screen.width != sz.cols or self.vx.screen.height != sz.rows) {
            self.vx.resize(self.gpa, self.tty.writer(), .{
                .rows = sz.rows,
                .cols = sz.cols,
                .x_pixel = 0,
                .y_pixel = 0,
            }) catch {};
        }
    }

    /// Drain one bridge-ring event (non-blocking). The app calls this until
    /// null in its wake_r branch.
    pub fn popEvent(self: *Terminal) ?Event {
        return self.ring.tryPop() catch null;
    }

    /// Render the current vaxis screen via the double-buffered cell diff.
    pub fn render(self: *Terminal) error{WriteFailed}!void {
        self.vx.render(self.tty.writer()) catch return error.WriteFailed;
    }
};

/// Bridge thread: `loop.nextEvent()` (blocking pop from vaxis's input
/// queue) → ring → wake pipe. Quit flag stops it; restore() posts a `.quit`
/// event to unblock `nextEvent`.
fn bridgeMain(self: *Terminal) void {
    while (!self.quit.load(.acquire)) {
        const ev = self.loop.nextEvent() catch break;
        if (self.quit.load(.acquire)) break;
        // Drop-on-full (wake-pipe semantics): never block the input path.
        _ = self.ring.tryPush(ev) catch break;
        wakeWrite(self.wake_w);
    }
}

/// Re-enable ISIG on a tty fd (vaxis makeRaw clears it; Guard Ctrl+C needs
/// SIGINT delivery). Preserves every other raw-mode setting.
fn reenableIsig(fd: posix.fd_t) posix.TermiosSetError!void {
    var t = try posix.tcgetattr(fd);
    t.lflag.ISIG = true;
    try posix.tcsetattr(fd, .FLUSH, t);
}

/// Test-only offscreen backend (RecTerm rework): a real Terminal shell whose
/// vaxis screen is a standalone offscreen canvas and whose tty is the test
/// Tty, so `App.paint` renders without a real terminal and tests assert the
/// resulting cells. Lives here so app.zig (quarantine boundary) never names
/// a vaxis type.
pub const PaintTerminal = struct {
    term: Terminal,
    /// Heap screen mirror for cell assertions. NOTE: stale after a resize
    /// (vx reallocates its own buffer); after resizes read term.vx.screen.
    screen: *vaxis.Screen,

    pub fn init(gpa: std.mem.Allocator) !PaintTerminal {
        const cols: u16 = 80;
        const rows: u16 = 40; // matches TestTty.getWinsize in test builds
        var env_map = try gpa.create(std.process.Environ.Map);
        errdefer {
            env_map.deinit();
            gpa.destroy(env_map);
        }
        env_map.* = std.process.Environ.Map.init(gpa);

        const screen = try gpa.create(vaxis.Screen);
        errdefer gpa.destroy(screen);
        screen.* = try vaxis.Screen.init(gpa, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
        errdefer screen.deinit(gpa);
        var screen_last = try vaxis.AllocatingScreen.init(gpa, cols, rows);
        errdefer screen_last.deinit(gpa);

        const tty_buf = try gpa.create([tty_buffer_size]u8);
        errdefer gpa.destroy(tty_buf);
        const tty = try gpa.create(vaxis.Tty);
        errdefer gpa.destroy(tty);
        tty.* = try vaxis.Tty.init(std.testing.io, tty_buf);

        const vx = try gpa.create(vaxis.Vaxis);
        errdefer gpa.destroy(vx);
        vx.* = .{
            .io = std.testing.io,
            .env_map = env_map,
            .screen = screen.*,
            .screen_last = screen_last,
        };

        const threaded = try gpa.create(std.Io.Threaded);
        errdefer {
            threaded.deinit();
            gpa.destroy(threaded);
        }
        threaded.* = std.Io.Threaded.init(gpa, .{});

        return .{
            .term = .{
                .gpa = gpa,
                .tty = tty,
                .vx = vx,
                .threaded = threaded,
                .tty_buf = tty_buf,
                .env_map = env_map,
                .loop = vaxis.Loop(Event).init(std.testing.io, tty, vx),
                .ring = vaxis.Queue(Event, ring_capacity).init(std.testing.io),
                .md_arena = std.heap.ArenaAllocator.init(gpa),
            },
            .screen = screen,
        };
    }

    pub fn deinit(self: *PaintTerminal, gpa: std.mem.Allocator) void {
        self.term.vx.deinit(gpa, self.term.tty.writer());
        self.term.tty.deinit();
        self.term.env_map.deinit();
        self.term.threaded.deinit();
        self.term.md_arena.deinit();
        gpa.destroy(self.term.tty_buf);
        gpa.destroy(self.term.tty);
        gpa.destroy(self.term.vx);
        gpa.destroy(self.term.env_map);
        gpa.destroy(self.term.threaded);
        gpa.destroy(self.screen);
    }

    pub fn writeCell(self: *PaintTerminal, col: u16, row: u16, grapheme: []const u8) void {
        self.screen.writeCell(col, row, .{ .char = .{ .grapheme = grapheme, .width = 1 } });
    }

    pub fn cellText(self: *const PaintTerminal, col: u16, row: u16, buf: []u8) []const u8 {
        const cell = self.screen.readCell(col, row) orelse return buf[0..0];
        const g = cell.char.grapheme;
        if (g.len > buf.len) return buf[0..0];
        @memcpy(buf[0..g.len], g);
        return buf[0..g.len];
    }
};

pub fn windowSize(fd: posix.fd_t) ?Size {
    var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
    } else {
        const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (posix.errno(rc) != .SUCCESS) return null;
    }
    if (wsz.col == 0 or wsz.row == 0) return null;
    return .{ .cols = wsz.col, .rows = wsz.row };
}

fn isFdTty(fd: posix.fd_t) bool {
    if (builtin.os.tag == .linux) {
        if (builtin.link_libc) {
            return std.c.isatty(fd) != 0;
        }
        var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    return std.c.isatty(fd) != 0;
}

// ── wake-pipe family (unchanged) ────────────────────────────────────────────

pub fn makeWakePipe() error{PipeFailed}![2]posix.fd_t {
    if (builtin.os.tag == .linux) {
        var fds: [2]i32 = .{ -1, -1 };
        var flags: std.os.linux.O = .{};
        flags.NONBLOCK = true;
        flags.CLOEXEC = true;
        const rc = std.os.linux.pipe2(&fds, flags);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.PipeFailed;
        return .{ fds[0], fds[1] };
    }
    var fds: [2]posix.fd_t = .{ -1, -1 };
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    if (setNonblock(fds[0]) or setNonblock(fds[1]) or
        setCloexec(fds[0]) or setCloexec(fds[1]))
    {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return error.PipeFailed;
    }
    return fds;
}

fn setNonblock(fd: posix.fd_t) bool {
    if (builtin.os.tag == .linux) {
        const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
        if (std.os.linux.errno(cur) != .SUCCESS) return true;
        const cur_u: u32 = @intCast(cur);
        const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, cur_u | O_NONBLOCK_LINUX);
        return std.os.linux.errno(rc) != .SUCCESS;
    }
    const cur = std.c.fcntl(fd, std.c.F.GETFL);
    if (cur < 0) return true;
    if (std.c.fcntl(fd, std.c.F.SETFL, cur | O_NONBLOCK_MAC) < 0) return true;
    return false;
}

fn setCloexec(fd: posix.fd_t) bool {
    if (builtin.os.tag == .linux) {
        const cur = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
        if (std.os.linux.errno(cur) != .SUCCESS) return true;
        const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
        return std.os.linux.errno(rc) != .SUCCESS;
    }
    const cur = std.c.fcntl(fd, std.c.F.GETFD);
    if (cur < 0) return true;
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return true;
    return false;
}

fn rawWrite(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!usize {
    if (bytes.len == 0) return 0;
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => 0,
            else => error.WriteFailed,
        };
    }
    const rc = std.c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) {
        const e = posix.errno(rc);
        if (e == .AGAIN) return 0;
        return error.WriteFailed;
    }
    return @intCast(rc);
}

fn rawClose(fd: posix.fd_t) void {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        _ = std.os.linux.close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn drainPipe(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
    }
}

pub fn wakeWrite(fd: posix.fd_t) void {
    const b = [_]u8{1};
    _ = rawWrite(fd, &b) catch {};
}

pub fn closeFd(fd: posix.fd_t) void {
    rawClose(fd);
}

// ── fixtures (tui-vaxis-001) ────────────────────────────────────────────────

test "size minimum constants" {
    const s = Size{ .cols = 19, .rows = 5 };
    try std.testing.expect(s.isBelowMinimum());
    const ok = Size{ .cols = 20, .rows = 5 };
    try std.testing.expect(!ok.isBelowMinimum());
}

test "wake pipe drop-on-full nonblocking" {
    const fds = try makeWakePipe();
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        wakeWrite(fds[1]);
    }
    drainPipe(fds[0]);
}

// Event ring: order preserved, one wake byte per event, quit pops through.
test "bridge ring order and wake per event" {
    const fds = try makeWakePipe();
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    var ring: vaxis.Queue(Event, ring_capacity) = .init(std.testing.io);

    const ev_a = Event{ .key_press = .{ .codepoint = 'a' } };
    const ev_b = Event{ .winsize = .{ .rows = 30, .cols = 100, .x_pixel = 0, .y_pixel = 0 } };
    const ev_c = Event{ .key_press = .{ .codepoint = 'b' } };

    // Simulate bridgeMain's per-event wake (wake per event).
    try ring.push(ev_a);
    wakeWrite(fds[1]);
    try ring.push(ev_b);
    wakeWrite(fds[1]);
    try ring.push(ev_c);
    wakeWrite(fds[1]);

    // Order preserved on drain.
    const popped_a = (try ring.tryPop()).?;
    const popped_b = (try ring.tryPop()).?;
    const popped_c = (try ring.tryPop()).?;
    try std.testing.expect(popped_a == .key_press);
    try std.testing.expectEqual(@as(u21, 'a'), popped_a.key_press.codepoint);
    try std.testing.expect(popped_b == .winsize);
    try std.testing.expectEqual(@as(u16, 100), popped_b.winsize.cols);
    try std.testing.expectEqual(@as(u16, 30), popped_b.winsize.rows);
    try std.testing.expect(popped_c == .key_press);
    try std.testing.expectEqual(@as(u21, 'b'), popped_c.key_press.codepoint);
    try std.testing.expect((try ring.tryPop()) == null);

    // One wake byte per event.
    var wake_count: usize = 0;
    var buf: [64]u8 = undefined;
    while (true) {
        const n = posix.read(fds[0], &buf) catch break;
        if (n == 0) break;
        wake_count += n;
    }
    try std.testing.expectEqual(@as(usize, 3), wake_count);
}

// Quit semantics: the flag stops the bridge loop; a `.quit` event is what
// unblocks a bridge blocked in `nextEvent` (the PTY fixture covers the full
// thread e2e; here we pin the ring contract).
test "bridge ring quit event and flag" {
    var ring: vaxis.Queue(Event, ring_capacity) = .init(std.testing.io);
    try ring.push(.quit);
    const popped = (try ring.tryPop()).?;
    try std.testing.expect(popped == .quit);

    var quit = std.atomic.Value(bool).init(false);
    quit.store(true, .release);
    try std.testing.expect(quit.load(.acquire));
}

// ISIG shim unit: after a raw-style clear, `reenableIsig` restores ISIG and
// leaves the other raw settings intact. Needs a real controlling tty
// (/dev/tty); skipped otherwise (the PTY process fixture covers e2e).
test "ISIG re-enabled after vaxis raw (skip without tty)" {
    var tty_file = std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/tty", .{ .mode = .read_write }) catch return error.SkipZigTest;
    defer tty_file.close(std.testing.io);
    const fd = tty_file.handle;

    const orig = posix.tcgetattr(fd) catch return error.SkipZigTest;
    // Mimic vaxis makeRaw's ISIG clearing on a copy.
    var raw = orig;
    raw.lflag.ISIG = false;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    posix.tcsetattr(fd, .FLUSH, raw) catch return error.SkipZigTest;
    defer posix.tcsetattr(fd, .FLUSH, orig) catch {};

    const after_raw = posix.tcgetattr(fd) catch return error.SkipZigTest;
    try std.testing.expect(!after_raw.lflag.ISIG);

    try reenableIsig(fd);

    const after_shim = posix.tcgetattr(fd) catch return error.SkipZigTest;
    try std.testing.expect(after_shim.lflag.ISIG);
    // Raw settings preserved by the shim.
    try std.testing.expect(!after_shim.lflag.ICANON);
    try std.testing.expect(!after_shim.lflag.ECHO);
}
