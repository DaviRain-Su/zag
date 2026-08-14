//! Typed append-only journal, one fsynced write per entry (H2).
//!
//! Schema (one entry per line; <seq> = 0-based entry line number; <ts> =
//! realtime nanoseconds):
//!
//!   (redefine <name> <seq> "<source>" <ts>)   pending change
//!   (discard  <name> <seq> <ts>)              removes matching pending redefine
//!   (suspect  <name> <seq> <ts>)              quarantined by failed commit
//!   (commit   <gen> "<hash>" <ts>)            generation flip recorded
//!
//! Replay = fold over typed entries. Durability rule (B3): a non-conforming
//! FINAL line is a torn tail (crash mid-append) and is truncated silently on
//! read; an unknown kind ANYWHERE earlier is JournalCorrupt — fail closed,
//! never silently truncate mid-file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");

pub const path = "journal.sexp";
const max_file: usize = 64 * 1024 * 1024;

pub const Error = error{ JournalCorrupt, OutOfMemory };

pub const Redef = struct { name: []u8, source: []u8 };

pub fn freeRedefs(gpa: Allocator, list: []Redef) void {
    for (list) |r| {
        gpa.free(r.name);
        gpa.free(r.source);
    }
    gpa.free(list);
}

fn lineComplete(line: []const u8) bool {
    return lineValid(line) and line[line.len - 1] == ')';
}

fn entryCount(gpa: Allocator, io: Io, dir: Io.Dir) !usize {
    const content = readAll(gpa, io, dir) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer gpa.free(content);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const is_last = it.peek() == null;
        if (!lineComplete(line)) {
            if (is_last) break; // torn final line: truncate silently
            return error.JournalCorrupt;
        }
        n += 1;
    }
    return n;
}

fn lineValid(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "(redefine ") or
        std.mem.startsWith(u8, line, "(discard ") or
        std.mem.startsWith(u8, line, "(suspect ") or
        std.mem.startsWith(u8, line, "(commit ");
}

fn readAll(gpa: Allocator, io: Io, dir: Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(max_file));
}

/// One fsynced write per entry: entry text and newline go out in a single
/// writeStreamingAll, then fsync, dirfd-relative to the state dir (H2).
fn appendRaw(io: Io, dir: Io.Dir, entry_line: []const u8) !void {
    const fd = try std.posix.openat(dir.handle, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);
    var f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer f.close(io);
    try f.writeStreamingAll(io, entry_line);
    try f.sync(io);
}

pub fn appendRedefine(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8, source: []const u8) !void {
    const esc = try frame.escape(gpa, source);
    defer gpa.free(esc);
    const line = try std.fmt.allocPrint(gpa, "(redefine {s} {d} \"{s}\" {d})\n", .{ name, try entryCount(gpa, io, dir), esc, nowNs(io) });
    defer gpa.free(line);
    try appendRaw(io, dir, line);
}

pub fn appendDiscard(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !void {
    const line = try std.fmt.allocPrint(gpa, "(discard {s} {d} {d})\n", .{ name, try entryCount(gpa, io, dir), nowNs(io) });
    defer gpa.free(line);
    try appendRaw(io, dir, line);
}

pub fn appendSuspect(gpa: Allocator, io: Io, dir: Io.Dir, name: []const u8) !void {
    const line = try std.fmt.allocPrint(gpa, "(suspect {s} {d} {d})\n", .{ name, try entryCount(gpa, io, dir), nowNs(io) });
    defer gpa.free(line);
    try appendRaw(io, dir, line);
}

pub fn appendCommit(gpa: Allocator, io: Io, dir: Io.Dir, gen: u32, hash: *const [64]u8) !void {
    const line = try std.fmt.allocPrint(gpa, "(commit {d} \"{s}\" {d})\n", .{ gen, hash, nowNs(io) });
    defer gpa.free(line);
    try appendRaw(io, dir, line);
}

/// Public entry-count (strict: torn final line tolerated, mid-file unknown
/// kind = JournalCorrupt).
pub fn countEntries(gpa: Allocator, io: Io, dir: Io.Dir) !usize {
    return entryCount(gpa, io, dir);
}

/// Journal redefines since the last commit, dropping any canceled by a later
/// discard or quarantined by a suspect marker. This is the pending set.
pub fn pendingRedefs(gpa: Allocator, io: Io, dir: Io.Dir) ![]Redef {
    var list: std.ArrayList(Redef) = .empty;
    errdefer {
        // Free entry contents; deinit frees the backing store.
        for (list.items) |r| {
            gpa.free(r.name);
            gpa.free(r.source);
        }
        list.deinit(gpa);
    }
    const content = readAll(gpa, io, dir) catch |e| switch (e) {
        error.FileNotFound => return list.toOwnedSlice(gpa),
        else => return e,
    };
    defer gpa.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const is_last = it.peek() == null;
        if (std.mem.startsWith(u8, line, "(redefine ")) {
            // (redefine <name> <seq> "<source>" <ts>)
            const parsed: ?Redef = blk: {
                var i: usize = "(redefine ".len;
                const t = frame.readToken(line, i);
                i = frame.skipSpaces(line, t.end);
                i = frame.skipSpaces(line, frame.readToken(line, i).end); // seq
                const ps = frame.parseString(gpa, line, i) catch break :blk null;
                break :blk Redef{
                    .name = try gpa.dupe(u8, t.tok),
                    .source = ps.value,
                };
            };
            const r = parsed orelse {
                // A torn final line is truncated silently; mid-file
                // malformation fails closed (B3).
                if (is_last) break;
                return error.JournalCorrupt;
            };
            try list.append(gpa, r);
        } else if (std.mem.startsWith(u8, line, "(discard ") or
            std.mem.startsWith(u8, line, "(suspect "))
        {
            // (<kind> <name> <seq> <ts>) — both prefixes are 9 bytes.
            const t = frame.readToken(line, "(discard ".len);
            var j = list.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, list.items[j].name, t.tok)) {
                    const r = list.orderedRemove(j);
                    gpa.free(r.name);
                    gpa.free(r.source);
                }
            }
        } else if (std.mem.startsWith(u8, line, "(commit ")) {
            for (list.items) |r| {
                gpa.free(r.name);
                gpa.free(r.source);
            }
            list.clearRetainingCapacity();
        } else {
            if (is_last) break; // torn final line
            return error.JournalCorrupt;
        }
    }
    return list.toOwnedSlice(gpa);
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

test "typed entries: fold, discard, suspect, torn tail, mid-file corrupt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try appendRedefine(gpa, io, tmp.dir, "alpha", "(define (alpha) 1)");
    try appendRedefine(gpa, io, tmp.dir, "beta", "(define (beta) 2)");
    try appendDiscard(gpa, io, tmp.dir, "alpha");
    try appendRedefine(gpa, io, tmp.dir, "gamma", "(define (gamma) 3)");
    try appendSuspect(gpa, io, tmp.dir, "gamma");
    try appendCommit(gpa, io, tmp.dir, 1, &@as([64]u8, @splat('0')));
    try appendRedefine(gpa, io, tmp.dir, "delta", "(define (delta) 4)");

    const pend = try pendingRedefs(gpa, io, tmp.dir);
    defer freeRedefs(gpa, pend);
    try std.testing.expectEqual(@as(usize, 1), pend.len);
    try std.testing.expectEqualStrings("delta", pend[0].name);
    try std.testing.expectEqual(@as(usize, 7), try countEntries(gpa, io, tmp.dir));

    // torn final line: truncated silently
    {
        const fd = try std.posix.openat(tmp.dir.handle, path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0o644);
        var f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        defer f.close(io);
        try f.writeStreamingAll(io, "(redefine torn");
    }
    {
        const pend2 = try pendingRedefs(gpa, io, tmp.dir);
        defer freeRedefs(gpa, pend2);
        try std.testing.expectEqual(@as(usize, 1), pend2.len);
    }

    // mid-file corruption: fail closed
    {
        var f = try tmp.dir.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "(redefine a 0 \"(define a 1)\" 1)\nGARBAGE\n(redefine b 2 \"(define b 2)\" 3)\n");
    }
    try std.testing.expectError(error.JournalCorrupt, pendingRedefs(gpa, io, tmp.dir));
    try std.testing.expectError(error.JournalCorrupt, countEntries(gpa, io, tmp.dir));
}
