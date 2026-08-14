//! Host-injected ports (§6 of the contract) and the shipped reference
//! jailed `fs.read` ToolPort (H3).
//!
//! Ports are synchronous; the image blocks on the reply. Boundedness is a
//! host duty: port implementations must bound their own runtime and reply
//! size (the frame cap applies on the wire); zag-live has no enforcement
//! point inside a port call. Port absence = the image's primitive raises a
//! nack carrying the atom `PortAbsent`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");

pub const PortError = error{
    PortAbsent,
    UnknownTool,
    JailEscape,
    FileNotFound,
    IsSymlink,
    NotRegularFile,
    OutOfMemory,
    Unexpected,
};

pub const ProviderPort = struct {
    ctx: *anyopaque,
    /// Bounded by the host. Returns an allocated reply (host frees with the
    /// allocator the port documents; zag-live frees with the gpa it was
    /// given at init — ports must allocate replies with that allocator).
    call: *const fn (ctx: *anyopaque, request_sexp: []const u8) anyerror![]const u8,
};

pub const ToolPort = struct {
    ctx: *anyopaque,
    invoke: *const fn (ctx: *anyopaque, name: []const u8, args_sexp: []const u8) anyerror![]const u8,
};

// ---------- shipped reference helper: jailed fs.read (H3) ----------

pub const max_read_bytes: usize = 16 * 1024;

/// A jailed `fs.read` ToolPort. Containment is resolved by dirfd-relative
/// openat walk with O_NOFOLLOW on every component — no realpath-then-open
/// TOCTOU, symlink-safe by construction. Output bounded to 16 KiB.
pub const FsReadPort = struct {
    gpa: Allocator,
    io: std.Io,
    jail_fd: std.posix.fd_t,

    pub fn deinit(self: *FsReadPort) void {
        closeFd(self.io, self.jail_fd);
    }

    fn closeFd(io: std.Io, fd: std.posix.fd_t) void {
        var f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        f.close(io);
    }

    pub fn port(self: *FsReadPort) ToolPort {
        return .{ .ctx = self, .invoke = invokeImpl };
    }

    fn invokeImpl(ctx: *anyopaque, name: []const u8, args_sexp: []const u8) anyerror![]const u8 {
        const self: *FsReadPort = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, "fs.read")) return error.UnknownTool;
        // args_sexp = ("<path>")
        var i = frame.skipSpaces(args_sexp, 0);
        if (i >= args_sexp.len or args_sexp[i] != '(') return error.Unexpected;
        i = frame.skipSpaces(args_sexp, i + 1);
        const ps = try frame.parseString(self.gpa, args_sexp, i);
        defer self.gpa.free(ps.value);
        return self.readJailed(ps.value);
    }

    fn readJailed(self: *FsReadPort, rel: []const u8) ![]u8 {
        if (rel.len == 0 or rel[0] == '/') return error.JailEscape;
        var fd = self.jail_fd;
        var opened: bool = false;
        defer if (opened) closeFd(self.io, fd);

        var it = std.mem.splitScalar(u8, rel, '/');
        var comp_buf: [4096]u8 = undefined;
        while (it.next()) |c| {
            if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
            if (std.mem.eql(u8, c, "..")) return error.JailEscape;
            if (c.len >= comp_buf.len) return error.JailEscape;
            @memcpy(comp_buf[0..c.len], c);
            comp_buf[c.len] = 0;
            const comp_z: [:0]const u8 = comp_buf[0..c.len :0];
            const is_last = it.peek() == null;
            if (is_last) {
                // Final component: plain read-only, no symlink follow.
                const ffd = std.posix.openatZ(fd, comp_z, .{
                    .ACCMODE = .RDONLY,
                    .NOFOLLOW = true,
                }, 0) catch |e| switch (e) {
                    error.FileNotFound => return error.FileNotFound,
                    error.SymLinkLoop => return error.IsSymlink,
                    else => return error.Unexpected,
                };
                return self.readBounded(ffd);
            }
            // Intermediate component: must be a real directory, no follow.
            const dfd = std.posix.openatZ(fd, comp_z, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .NOFOLLOW = true,
            }, 0) catch |e| switch (e) {
                error.FileNotFound => return error.FileNotFound,
                error.SymLinkLoop => return error.IsSymlink,
                error.NotDir => {
                    // macOS reports NOFOLLOW|DIRECTORY on a symlink as
                    // ENOTDIR; disambiguate with a no-DIRECTORY nofollow
                    // probe (ELOOP => symlink).
                    const probe = std.posix.openatZ(fd, comp_z, .{
                        .ACCMODE = .RDONLY,
                        .NOFOLLOW = true,
                    }, 0);
                    if (probe) |pfd| {
                        closeFd(self.io, pfd);
                        return error.FileNotFound; // regular file as directory
                    } else |e2| {
                        if (e2 == error.SymLinkLoop) return error.IsSymlink;
                        return error.FileNotFound;
                    }
                },
                else => return error.Unexpected,
            };
            if (opened) closeFd(self.io, fd);
            fd = dfd;
            opened = true;
        }
        return error.FileNotFound;
    }

    fn readBounded(self: *FsReadPort, fd: std.posix.fd_t) ![]u8 {
        defer closeFd(self.io, fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var buf: [4096]u8 = undefined;
        var truncated = false;
        while (true) {
            const n = std.posix.read(fd, &buf) catch return error.Unexpected;
            if (n == 0) break;
            const room = max_read_bytes -| out.items.len;
            if (room == 0) {
                truncated = true;
                break;
            }
            try out.appendSlice(self.gpa, buf[0..@min(n, room)]);
            if (n > room) {
                truncated = true;
                break;
            }
        }
        if (truncated) try out.appendSlice(self.gpa, "\n[truncated at 16384 bytes]");
        return out.toOwnedSlice(self.gpa);
    }
};

/// Open the jail directory and return the reference fs.read ToolPort owner.
pub fn fsReadPort(gpa: Allocator, io: std.Io, jail_path: []const u8) !FsReadPort {
    var buf: [4096]u8 = undefined;
    if (jail_path.len >= buf.len) return error.JailEscape;
    @memcpy(buf[0..jail_path.len], jail_path);
    buf[jail_path.len] = 0;
    const jail_z: [:0]const u8 = buf[0..jail_path.len :0];
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, jail_z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
    }, 0) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Unexpected,
    };
    return .{ .gpa = gpa, .io = io, .jail_fd = fd };
}

test "fsReadPort: jailed reads, .. / absolute / symlink escapes rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "jail/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "jail/ok.txt", .data = "jail content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "jail/sub/deep.txt", .data = "deep" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "SECRET-OUTSIDE" });
    tmp.dir.symLink(io, "../outside.txt", "jail/link-out", .{}) catch {};
    tmp.dir.symLink(io, "sub", "jail/link-dir", .{}) catch {};

    const jail_path = try tmp.dir.realPathFileAlloc(io, "jail", gpa);
    defer gpa.free(jail_path);

    var fp = try fsReadPort(gpa, io, jail_path);
    defer fp.deinit();
    const port = fp.port();

    const ok = try port.invoke(port.ctx, "fs.read", "(\"ok.txt\")");
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("jail content", ok);

    const deep = try port.invoke(port.ctx, "fs.read", "(\"sub/deep.txt\")");
    defer gpa.free(deep);
    try std.testing.expectEqualStrings("deep", deep);

    try std.testing.expectError(error.JailEscape, port.invoke(port.ctx, "fs.read", "(\"../outside.txt\")"));
    try std.testing.expectError(error.JailEscape, port.invoke(port.ctx, "fs.read", "(\"sub/../../outside.txt\")"));
    try std.testing.expectError(error.JailEscape, port.invoke(port.ctx, "fs.read", "(\"/etc/passwd\")"));
    // symlink to outside: rejected by O_NOFOLLOW (or, if the platform allowed
    // the open, containment still must hold — here we require rejection)
    try std.testing.expectError(error.IsSymlink, port.invoke(port.ctx, "fs.read", "(\"link-out\")"));
    try std.testing.expectError(error.IsSymlink, port.invoke(port.ctx, "fs.read", "(\"link-dir/deep.txt\")"));
    try std.testing.expectError(error.UnknownTool, port.invoke(port.ctx, "fs.write", "(\"ok.txt\")"));
}

test "fsReadPort: 16 KiB output bound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try tmp.dir.createDirPath(io, "jail");
    try tmp.dir.writeFile(io, .{ .sub_path = "jail/big.bin", .data = big });

    const jail_path = try tmp.dir.realPathFileAlloc(io, "jail", gpa);
    defer gpa.free(jail_path);
    var fp = try fsReadPort(gpa, io, jail_path);
    defer fp.deinit();
    const port = fp.port();
    const out = try port.invoke(port.ctx, "fs.read", "(\"big.bin\")");
    defer gpa.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "[truncated at 16384 bytes]"));
    try std.testing.expect(out.len < 16 * 1024 + 64);
}
