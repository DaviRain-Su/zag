//! Small POSIX terminal backend: raw mode on **stdin**, alt-screen/render on **stdout**.
//! Supports distinct stdin/stdout TTYs. No wholesale vaxis.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
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

const O_NONBLOCK_LINUX: u32 = 0o4000;
const O_NONBLOCK_MAC: c_int = 0x0004;

pub const Terminal = struct {
    /// Input TTY (raw termios applied here).
    in_fd: posix.fd_t,
    /// Output TTY (alt-screen + renderer writes).
    out_fd: posix.fd_t,
    orig_in: posix.termios,
    raw: bool = false,
    alt: bool = false,

    pub fn open() error{NotATty, TermiosFailed}!Terminal {
        const in_fd: posix.fd_t = posix.STDIN_FILENO;
        const out_fd: posix.fd_t = posix.STDOUT_FILENO;
        if (!isFdTty(in_fd)) return error.NotATty;
        if (!isFdTty(out_fd)) return error.NotATty;
        // Raw mode is applied to stdin (input); capture its original termios.
        const orig_in = posix.tcgetattr(in_fd) catch return error.TermiosFailed;
        return .{ .in_fd = in_fd, .out_fd = out_fd, .orig_in = orig_in };
    }

    pub fn enterRawAlt(self: *Terminal) error{TermiosFailed, WriteFailed}!void {
        var t = self.orig_in;
        // Keep ISIG so Guard SIGINT handler still fires on Ctrl+C.
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.IEXTEN = false;
        t.lflag.ISIG = true;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.iflag.BRKINT = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        // Input side only — do not require OPOST clear on a different out TTY.
        t.oflag.OPOST = false;
        t.cc[@intFromEnum(posix.V.MIN)] = 0;
        t.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.in_fd, .FLUSH, t) catch return error.TermiosFailed;
        self.raw = true;
        // Alt-screen + hide cursor on stdout (render channel).
        self.writeAll("\x1b[?1049h\x1b[?25l") catch {
            self.restore() catch {};
            return error.WriteFailed;
        };
        self.alt = true;
    }

    pub fn restore(self: *Terminal) error{TermiosFailed, WriteFailed}!void {
        if (self.alt) {
            self.writeAll("\x1b[?25h\x1b[?1049l") catch {};
            self.alt = false;
        }
        if (self.raw) {
            posix.tcsetattr(self.in_fd, .FLUSH, self.orig_in) catch return error.TermiosFailed;
            self.raw = false;
        }
    }

    pub fn size(self: *const Terminal) Size {
        // Prefer output TTY geometry for layout.
        return windowSize(self.out_fd) orelse windowSize(self.in_fd) orelse .{ .cols = 80, .rows = 24 };
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) error{WriteFailed}!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = rawWrite(self.out_fd, bytes[off..]) catch return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            off += n;
        }
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
