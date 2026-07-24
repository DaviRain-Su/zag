//! Workspace path jail — lexical validation + real filesystem containment.
//!
//! Phase H (h-workspace-001): built-in file tools must not follow workspace
//! symlinks/aliases outside the declared root. This is **software check-time
//! containment** on a trusted host — **not** an OS sandbox. Shell policy is a
//! separate boundary (`run_shell` is not contained by this jail).
//!
//! Threat model: workspace contents (including pre-existing symlinks) are
//! untrusted; the host OS account is trusted. Residual TOCTOU between check and
//! use is documented in SECURITY.md / workspace-sandbox.md.
//!
//! Which tools claim a path is decided by `ToolDescriptor.capabilities.workspace`,
//! not a built-in name list (D-007).
//!
//! When `workspace = path_field`, the named JSON field is **required** and must
//! be a string — missing/non-string/malformed JSON → `error.InvalidArguments`
//! (loop turns this into a soft `invalid_arguments` tool result before the handler).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zt = @import("zag-types");

/// Lexical / containment denial (maps to soft `code=jail_deny`).
pub const Error = error{
    OutsideWorkspace,
    InvalidPath,
};

/// Results of real containment checks used by handlers and the loop.
pub const ContainError = error{
    OutsideWorkspace,
    InvalidPath,
    /// Ordinary missing path (not a jail issue) — handlers map to ToolFailed.
    NotFound,
    /// Security-critical resolve failure (fail closed → jail_deny).
    ResolveFailed,
    OutOfMemory,
};

pub const PathExtractError = error{
    OutOfMemory,
    InvalidArguments,
};

// ── host path separators ─────────────────────────────────────────────
// POSIX/macOS: only `/` is a separator; `\` is a legal filename byte.
// Windows: both `/` and `\` are separators.

fn isPathSep(c: u8) bool {
    if (builtin.os.tag == .windows) return c == '/' or c == '\\';
    return c == '/';
}

/// Tokenize separators for this host (do not treat `\` as sep on POSIX).
fn pathSepChars() []const u8 {
    return if (builtin.os.tag == .windows) "/\\" else "/";
}

fn nativeSep() u8 {
    return std.fs.path.sep;
}

/// Resolved workspace root real path (absolute, canonical).
///
/// `path` is borrowed when obtained from `tool.Context.workspace_root_real`,
/// or owned when lazily resolved. Call `deinit` to free owned paths.
pub const Root = struct {
    path: []const u8,
    owned: bool = false,

    pub fn deinit(self: *Root, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
        self.* = .{ .path = "", .owned = false };
    }

    /// Prefer a pre-resolved borrowed root from Context; otherwise resolve cwd.
    /// Cached root is identity-only for the **same** cwd; it does not expand
    /// containment to a different directory.
    pub fn obtain(
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        cached: ?[]const u8,
    ) ContainError!Root {
        if (cached) |c| {
            if (c.len == 0) return error.ResolveFailed;
            // Verify cached root still matches this cwd (no expanded boundary).
            const live = resolveCwdReal(allocator, io, cwd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ResolveFailed,
            };
            defer allocator.free(live);
            if (!std.mem.eql(u8, c, live)) return error.ResolveFailed;
            return .{ .path = c, .owned = false };
        }
        const resolved = resolveCwdReal(allocator, io, cwd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResolveFailed,
        };
        return .{ .path = resolved, .owned = true };
    }

    /// True when `candidate_abs` is the root or a descendant (component-boundary safe).
    pub fn contains(self: Root, candidate_abs: []const u8) bool {
        return pathIsWithinRoot(self.path, candidate_abs);
    }
};

/// Guard reuses one Root for lexical + real containment checks.
pub const Guard = struct {
    root: Root,

    pub fn deinit(self: *Guard, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
    }

    /// Existing read/list/search target must resolve inside the root.
    pub fn checkExisting(
        self: Guard,
        io: Io,
        cwd: Io.Dir,
        rel_path: []const u8,
    ) ContainError!void {
        try checkToolPath(rel_path);
        const sub = if (rel_path.len == 0) "." else rel_path;

        if (std.mem.eql(u8, sub, ".") or isDotSlashOnly(sub)) {
            // cwd itself is the root by construction.
            return;
        }

        const real = realPathRelative(cwd, io, sub) catch |err| switch (err) {
            error.FileNotFound => {
                // Dangling symlink vs ordinary missing.
                if (isSymlinkNoFollow(cwd, io, sub)) return error.OutsideWorkspace;
                return error.NotFound;
            },
            error.SymLinkLoop => return error.OutsideWorkspace,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResolveFailed,
        };

        if (!self.root.contains(real.slice())) return error.OutsideWorkspace;
    }

    /// Write/create: every existing ancestor (and final if present) must resolve
    /// inside the root. Non-existent suffix under a verified ancestor is allowed
    /// only for ordinary child names — `..` after the first missing component is
    /// `InvalidPath` (blocks `new/../escape/...` when `new` does not exist yet).
    /// Dangling / escaping intermediate or final symlinks are denied.
    pub fn checkCreate(
        self: Guard,
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        rel_path: []const u8,
    ) ContainError!void {
        try checkToolPath(rel_path);
        if (rel_path.len == 0) return error.InvalidPath;

        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(allocator);

        var it = std.mem.tokenizeAny(u8, rel_path, pathSepChars());
        var saw_missing = false;
        var any_component = false;

        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            any_component = true;

            if (saw_missing) {
                // After first pure-missing component, reject `..` so an uncreated
                // prefix cannot be skipped to reach a later escaping name.
                if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
                continue;
            }

            if (acc.items.len > 0) {
                try acc.append(allocator, nativeSep());
            }
            try acc.appendSlice(allocator, part);

            const partial = acc.items;
            const real = realPathRelative(cwd, io, partial) catch |err| switch (err) {
                error.FileNotFound => {
                    if (isSymlinkNoFollow(cwd, io, partial)) {
                        return error.OutsideWorkspace;
                    }
                    // If this component is `..` and pure-missing, the parent walk
                    // already failed in a surprising way — fail closed.
                    if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
                    saw_missing = true;
                    continue;
                },
                error.SymLinkLoop => return error.OutsideWorkspace,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ResolveFailed,
            };

            if (!self.root.contains(real.slice())) return error.OutsideWorkspace;
        }

        if (!any_component) return error.InvalidPath;
    }

    /// Resolve `rel_path` to a real absolute path and require containment.
    /// On success returns an owned absolute path (caller frees).
    pub fn resolveContained(
        self: Guard,
        allocator: std.mem.Allocator,
        io: Io,
        cwd: Io.Dir,
        rel_path: []const u8,
    ) ContainError![]u8 {
        try self.checkExisting(io, cwd, rel_path);
        const sub = if (rel_path.len == 0) "." else rel_path;
        if (std.mem.eql(u8, sub, ".") or isDotSlashOnly(sub)) {
            return allocator.dupe(u8, self.root.path) catch return error.OutOfMemory;
        }
        const real = realPathRelative(cwd, io, sub) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => {
                if (isSymlinkNoFollow(cwd, io, sub)) return error.OutsideWorkspace;
                return error.NotFound;
            },
            error.SymLinkLoop => return error.OutsideWorkspace,
            else => return error.ResolveFailed,
        };
        if (!self.root.contains(real.slice())) return error.OutsideWorkspace;
        return allocator.dupe(u8, real.slice()) catch return error.OutOfMemory;
    }
};

fn isDotSlashOnly(sub: []const u8) bool {
    // "./" or ".\\" (windows) only
    if (sub.len == 2 and sub[0] == '.' and isPathSep(sub[1])) return true;
    return false;
}

/// Map containment failure to a soft tool body (`code=jail_deny`) or typed OOM.
/// `NotFound` is not converted — callers handle ordinary missing paths.
pub fn denyBody(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: ContainError,
) error{ OutOfMemory, NotFound }![]u8 {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.OutsideWorkspace, error.InvalidPath, error.ResolveFailed => deniedMessage(allocator, path),
    };
}

/// Soft error string for the model (caller owns with allocator).
pub fn deniedMessage(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    const tool_error = @import("tool_error.zig");
    const msg = try std.fmt.allocPrint(
        allocator,
        "path outside workspace jail: '{s}'. Use relative paths under the working directory; absolute paths, '..' escapes, and symlink/alias escapes are denied.",
        .{path},
    );
    defer allocator.free(msg);
    return tool_error.format(allocator, .jail_deny, msg);
}

/// Validate a tool path against the workspace jail (string-level, no IO).
pub fn checkToolPath(path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    // Absolute paths leave the relative workspace model.
    if (std.fs.path.isAbsolute(path)) return error.OutsideWorkspace;

    // Windows drive / UNC-ish prefixes even if not absolute on this host.
    if (path.len >= 2 and path[1] == ':') return error.OutsideWorkspace;
    if (std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//"))
        return error.OutsideWorkspace;

    var depth: i32 = 0;
    var it = std.mem.tokenizeAny(u8, path, pathSepChars());
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return error.OutsideWorkspace;
            continue;
        }
        depth += 1;
    }
}

/// Component-boundary containment: `/ws` does not contain `/ws2`.
///
/// Host-correct separators only: on POSIX, `\` is **not** a path separator, so
/// root `/tmp/ws` does **not** contain sibling `/tmp/ws\outside`.
pub fn pathIsWithinRoot(root_abs: []const u8, candidate_abs: []const u8) bool {
    const root = stripTrailingSeps(root_abs);
    const cand = stripTrailingSeps(candidate_abs);
    if (root.len == 0 or cand.len == 0) return false;

    if (std.mem.eql(u8, root, cand)) return true;

    // Filesystem root (`/` on POSIX; `\` or `/` on Windows volume root).
    if (root.len == 1 and isPathSep(root[0])) {
        return cand.len > 0 and isPathSep(cand[0]);
    }

    if (cand.len <= root.len) return false;
    if (!std.mem.startsWith(u8, cand, root)) return false;
    return isPathSep(cand[root.len]);
}

fn stripTrailingSeps(p: []const u8) []const u8 {
    if (p.len == 0) return p;
    var end = p.len;
    while (end > 1 and isPathSep(p[end - 1])) : (end -= 1) {}
    if (end == 0) return p[0..1];
    return p[0..end];
}

/// Resolve the real absolute path of an open directory (workspace cwd).
///
/// Uses `realPathFile(".", …)` rather than `Dir.realPath` so the process
/// `Dir.cwd()` sentinel works under Zig's Io (fd-based realPath fails on cwd).
pub fn resolveCwdReal(allocator: std.mem.Allocator, io: Io, cwd: Io.Dir) (error{OutOfMemory} || Error)![]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = cwd.realPathFile(io, ".", &buf) catch return error.OutsideWorkspace;
    if (n == 0) return error.OutsideWorkspace;
    return allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
}

const RealBuf = struct {
    buf: [Io.Dir.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const RealBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn realPathRelative(cwd: Io.Dir, io: Io, sub_path: []const u8) (error{ OutOfMemory, FileNotFound, SymLinkLoop } || anyerror)!RealBuf {
    var out: RealBuf = .{};
    const n = cwd.realPathFile(io, sub_path, &out.buf) catch |err| return err;
    out.len = n;
    return out;
}

fn isSymlinkNoFollow(cwd: Io.Dir, io: Io, sub_path: []const u8) bool {
    const st = cwd.statFile(io, sub_path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

/// Extract a required string field from JSON tool arguments.
pub fn requireStringArgument(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
) PathExtractError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return error.InvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return error.InvalidArguments;
    if (val != .string) return error.InvalidArguments;
    return try allocator.dupe(u8, val.string);
}

/// Extract path using descriptor workspace metadata.
///
/// - `workspace.none` → `null` (no path claim).
/// - `workspace.path_field` → required string field; missing/non-string/bad JSON → `InvalidArguments`.
pub fn pathFromDescriptor(
    allocator: std.mem.Allocator,
    capabilities: zt.ToolCapabilities,
    arguments_json: []const u8,
) PathExtractError!?[]const u8 {
    const field = capabilities.workspace.pathField() orelse return null;
    const path = try requireStringArgument(allocator, arguments_json, field);
    return path;
}

/// Build a Guard from Context-like inputs (cached root optional).
pub fn guardFrom(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    cached_root: ?[]const u8,
) ContainError!Guard {
    return .{ .root = try Root.obtain(allocator, io, cwd, cached_root) };
}

// ── tests ──────────────────────────────────────────────────────────────

test "jail allows relative paths" {
    try checkToolPath(".");
    try checkToolPath("src/main.zig");
    try checkToolPath("a/b/../c");
}

test "jail rejects absolute and escape" {
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("/etc/passwd"));
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("../secret"));
    try std.testing.expectError(error.OutsideWorkspace, checkToolPath("a/../../b"));
    try std.testing.expectError(error.InvalidPath, checkToolPath(""));
}

test "pathIsWithinRoot component boundary" {
    try std.testing.expect(pathIsWithinRoot("/ws", "/ws"));
    try std.testing.expect(pathIsWithinRoot("/ws", "/ws/"));
    try std.testing.expect(pathIsWithinRoot("/ws/", "/ws"));
    try std.testing.expect(pathIsWithinRoot("/ws", "/ws/a"));
    try std.testing.expect(pathIsWithinRoot("/ws", "/ws/a/b"));
    try std.testing.expect(!pathIsWithinRoot("/ws", "/ws2"));
    try std.testing.expect(!pathIsWithinRoot("/ws", "/ws2/a"));
    try std.testing.expect(!pathIsWithinRoot("/ws", "/other"));
    try std.testing.expect(!pathIsWithinRoot("/ws/project", "/ws"));
    try std.testing.expect(pathIsWithinRoot("/", "/etc"));
    try std.testing.expect(pathIsWithinRoot("/", "/"));

    // POSIX: backslash is NOT a separator — root must not swallow sibling with `\` in name.
    if (builtin.os.tag != .windows) {
        try std.testing.expect(!pathIsWithinRoot("/tmp/ws", "/tmp/ws\\outside"));
        try std.testing.expect(!pathIsWithinRoot("/tmp/ws", "/tmp/ws\\outside/x"));
        // Trailing backslash is not a trailing separator on POSIX.
        try std.testing.expect(!pathIsWithinRoot("/tmp/ws", "/tmp/ws\\"));
    }
}

test "pathFromDescriptor respects workspace access" {
    const gpa = std.testing.allocator;
    const none_caps: zt.ToolCapabilities = .{
        .risk = .execute,
        .workspace = .none,
        .cancellation = .none,
        .shell = .command_argument,
    };
    try std.testing.expect(try pathFromDescriptor(gpa, none_caps, "{\"path\":\"x\"}") == null);

    const path_caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field = "path" },
        .cancellation = .none,
        .shell = .none,
    };
    const p = try pathFromDescriptor(gpa, path_caps, "{\"path\":\"src/a.zig\"}");
    defer if (p) |s| gpa.free(s);
    try std.testing.expectEqualStrings("src/a.zig", p.?);
}

test "pathFromDescriptor requires string field when path claimed" {
    const gpa = std.testing.allocator;
    const path_caps: zt.ToolCapabilities = .{
        .risk = .read,
        .workspace = .{ .path_field = "path" },
        .cancellation = .none,
        .shell = .none,
    };
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "{\"path\":1}"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "not-json"));
    try std.testing.expectError(error.InvalidArguments, pathFromDescriptor(gpa, path_caps, "[]"));
}

test "Root and Guard contain ordinary paths; escape symlink denied" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (builtinSymlinkUnsupported()) return error.SkipZigTest;

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();

    try parent.dir.createDirPath(io, "outside");
    try parent.dir.createDirPath(io, "ws");
    try parent.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "OUTSIDE_SECRET\n" });
    try parent.dir.writeFile(io, .{ .sub_path = "ws/inside.txt", .data = "inside-ok\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);

    try ws.symLink(io, "../outside/secret.txt", "link_out", .{});
    try ws.symLink(io, "inside.txt", "link_in", .{});
    try ws.createDirPath(io, "nest");
    try ws.symLink(io, "../../outside/secret.txt", "nest/link_out", .{});
    try ws.symLink(io, "../nope-missing", "dangling", .{});
    try ws.symLink(io, "../outside", "escape_dir", .{ .is_directory = true });

    var guard = try guardFrom(gpa, io, ws, null);
    defer guard.deinit(gpa);

    try guard.checkExisting(io, ws, "inside.txt");
    try guard.checkExisting(io, ws, "link_in");
    try guard.checkExisting(io, ws, ".");

    try std.testing.expectError(error.OutsideWorkspace, guard.checkExisting(io, ws, "link_out"));
    try std.testing.expectError(error.OutsideWorkspace, guard.checkExisting(io, ws, "nest/link_out"));
    try std.testing.expectError(error.OutsideWorkspace, guard.checkExisting(io, ws, "dangling"));
    try std.testing.expectError(error.NotFound, guard.checkExisting(io, ws, "missing.txt"));

    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "link_out"));
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "link_out/more"));
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "dangling/x"));
    try guard.checkCreate(gpa, io, ws, "new_file.txt");
    try guard.checkCreate(gpa, io, ws, "subdir/nested.txt");
    try guard.checkCreate(gpa, io, ws, "link_in");

    // Exploit: missing prefix + `..` must not skip to escaping dir.
    try std.testing.expectError(error.InvalidPath, guard.checkCreate(gpa, io, ws, "new/../escape_dir/pwned.txt"));
    try std.testing.expectError(error.InvalidPath, guard.checkCreate(gpa, io, ws, "missing/../dangling/x"));
    // Normal missing child still OK.
    try guard.checkCreate(gpa, io, ws, "missing/child.txt");
    // Existing balanced `..` that still resolves inside stays allowed by checkCreate
    // only if every resolved prefix is inside (escape_dir component fails).
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "nest/../escape_dir/x"));
    try guard.checkCreate(gpa, io, ws, "nest/../inside.txt");

    var outside_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const outside_n = try parent.dir.realPathFile(io, "outside", &outside_buf);
    try std.testing.expect(!guard.root.contains(outside_buf[0..outside_n]));
}

test "POSIX backslash sibling name is outside root" {
    // parent/ws  and  parent/ws\outside  (literal backslash in filename)
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (builtinSymlinkUnsupported()) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var parent = std.testing.tmpDir(.{ .iterate = true });
    defer parent.cleanup();

    try parent.dir.createDirPath(io, "ws");
    // Literal sibling name containing backslash.
    const sibling_name = "ws\\outside";
    try parent.dir.writeFile(io, .{ .sub_path = sibling_name, .data = "BACKSLASH_OUTSIDE\n" });

    var ws = try parent.dir.openDir(io, "ws", .{ .iterate = true, .access_sub_paths = true });
    defer ws.close(io);

    try ws.symLink(io, "../ws\\outside", "to_bs_sibling", .{});

    var guard = try guardFrom(gpa, io, ws, null);
    defer guard.deinit(gpa);

    // Real paths must not treat `\` as separator.
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_n = try ws.realPathFile(io, ".", &root_buf);
    var sib_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const sib_n = try parent.dir.realPathFile(io, sibling_name, &sib_buf);
    try std.testing.expect(!pathIsWithinRoot(root_buf[0..root_n], sib_buf[0..sib_n]));
    try std.testing.expect(!guard.root.contains(sib_buf[0..sib_n]));

    try std.testing.expectError(error.OutsideWorkspace, guard.checkExisting(io, ws, "to_bs_sibling"));
    try std.testing.expectError(error.OutsideWorkspace, guard.checkCreate(gpa, io, ws, "to_bs_sibling"));
}

test "cached Root.obtain reuses borrowed path; rejects mismatched cwd" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();

    const owned = try resolveCwdReal(gpa, io, tmp.dir);
    defer gpa.free(owned);

    var root = try Root.obtain(gpa, io, tmp.dir, owned);
    defer root.deinit(gpa);
    try std.testing.expect(!root.owned);
    try std.testing.expectEqualStrings(owned, root.path);
    try std.testing.expect(root.contains(owned));

    // Cached path from a different cwd must not expand the boundary.
    try std.testing.expectError(error.ResolveFailed, Root.obtain(gpa, io, other.dir, owned));
}

fn builtinSymlinkUnsupported() bool {
    return builtin.os.tag == .windows;
}
