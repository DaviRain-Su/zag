//! Declarative generations: base.ss + replay.ss + meta.sexp, a `current`
//! pointer file (tmp + fsync + rename), and `.staging-<n>/` dirs that are
//! renamed into place only after the clean-process probe passes. Stale
//! staging dirs are removed on start (crash-between-staging-and-rename
//! window).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const gens_path = "generations";
pub const current_path = "current";
const current_tmp_path = "current.tmp";
const max_file: usize = 64 * 1024 * 1024;

pub fn genPath(gpa: Allocator, gen: u32, comptime file: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, gens_path ++ "/{d}/" ++ file, .{gen});
}

pub fn stagingPath(gpa: Allocator, gen: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, gens_path ++ "/.staging-{d}", .{gen});
}

pub fn readCurrent(gpa: Allocator, io: Io, dir: Io.Dir) !u32 {
    const content = dir.readFileAlloc(io, current_path, gpa, .limited(64)) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer gpa.free(content);
    return std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n"), 10);
}

/// Atomic flip: write tmp, fsync, rename over the pointer.
pub fn flip(gpa: Allocator, io: Io, dir: Io.Dir, gen: u32) !void {
    const ptr = try std.fmt.allocPrint(gpa, "{d}\n", .{gen});
    defer gpa.free(ptr);
    var f = try dir.createFile(io, current_tmp_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, ptr);
    try f.sync(io);
    try Io.Dir.rename(dir, current_tmp_path, dir, current_path, io);
}

pub fn fileExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

pub fn writeSmall(io: Io, dir: Io.Dir, path: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    try f.sync(io);
}

/// Remove stale .staging-<n> dirs left by a supervisor crash between
/// staging and rename. Called on start().
pub fn cleanupStaleStaging(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    var gens = dir.openDir(io, gens_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer gens.close(io);
    var it = gens.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, ".staging-")) {
            const p = try std.fmt.allocPrint(gpa, gens_path ++ "/{s}", .{entry.name});
            defer gpa.free(p);
            dir.deleteTree(io, p) catch {};
        }
    }
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "pointer flip and stale staging cleanup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectEqual(@as(u32, 0), try readCurrent(gpa, io, tmp.dir));
    try flip(gpa, io, tmp.dir, 3);
    try std.testing.expectEqual(@as(u32, 3), try readCurrent(gpa, io, tmp.dir));

    try tmp.dir.createDirPath(io, gens_path ++ "/.staging-4");
    try tmp.dir.createDirPath(io, gens_path ++ "/2");
    try cleanupStaleStaging(gpa, io, tmp.dir);
    try std.testing.expect(!fileExists(io, tmp.dir, gens_path ++ "/.staging-4"));
    try std.testing.expect(fileExists(io, tmp.dir, gens_path ++ "/2"));
}
