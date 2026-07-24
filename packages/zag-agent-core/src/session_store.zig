//! Session durability — JSONL transcript on disk.
//!
//! Format (one JSON object per line):
//! ```
//! {"schema_version":1,"v":1,"type":"zag_session","compaction_gen":0}
//! {"role":"system","content":"..."}
//! {"role":"user","content":"..."}
//! {"role":"assistant","content":"...","tool_calls":[...]}
//! {"role":"tool","tool_call_id":"...","content":"..."}
//! ```
//!
//! `schema_version` (or legacy `v`) must be integer 1. Unknown versions → `UnsupportedSchema`.
//! Header-less legacy files still load (implied v1).
//!
//! D-006 contract:
//! - Create, resume, and open_or_create are distinct operations.
//! - Invalid/unsupported/general I/O failures never seed a fresh transcript on the same path.
//! - Save writes a temporary file and atomically replaces the target; failure preserves the prior file.
//! - At most one active writer per persisted session (advisory lock on `{path}.lock`).
//! - Software-crash preservation only; power-loss/fsync durability is not claimed.
//! - Session path is lexical relative-workspace only (not symlink containment).
//! - **Redaction (h-redact-001):** when a `redactor` is attached, every arbitrary
//!   string field (message content, tool args/ids, compaction summary, content
//!   parts/URLs) is redacted into a temporary buffer **before** atomic serialize.
//!   In-memory transcript is not mutated. Redaction OOM → `OutOfMemory` (fail
//!   closed; prior file bytes preserved). Null redactor is a documented low-level
//!   bypass; product Session/Agent always attaches policy.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const message = @import("message.zig");
const transcript_mod = @import("transcript.zig");
const workspace = @import("workspace.zig");
const redact_mod = @import("redact.zig");

pub const Error = error{
    OutOfMemory,
    IoFailed,
    InvalidSession,
    UnsupportedSchema,
    SessionNotFound,
    SessionAlreadyExists,
    SessionBusy,
    InvalidPath,
};

pub const header_type = "zag_session";
pub const current_schema_version: u32 = 1;

/// Metadata written on the session header line (H4).
pub const SessionMeta = struct {
    schema_version: u32 = current_schema_version,
    /// Optional package version string at write time (not owned here).
    zag_version: ?[]const u8 = null,
    compaction_gen: u32 = 0,
    /// Optional heuristic compaction summary (not owned here).
    compaction_summary: ?[]const u8 = null,
};

/// Owned writer lease for one persisted session.
///
/// **Ownership (move-only by convention):** obtain only via `createNew` /
/// `resumeExisting` / `openOrCreate`. The lease owns the lock FD, path strings,
/// and must be `deinit`ed exactly once. Zig resource types cannot prevent a
/// hostile by-value copy of this struct; callers must not copy/forge a Writer.
/// That is not part of the multi-process lock contract.
///
/// Holds an exclusive advisory lock on `{path}.lock` for its lifetime.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    /// Owned copy of session path.
    path: []const u8,
    /// Owned copy of lock file path.
    lock_path: []const u8,
    /// Held open for the lifetime of the writer.
    lock_file: Io.File,
    /// Borrowed redaction policy (product path sets; null = low-level bypass).
    redactor: ?*const redact_mod.Redactor = null,
    /// Test builds only: fail after temp write, before atomic replace/link.
    fail_before_replace: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},
    /// Test-only: next save redaction returns OOM once.
    fail_next_redact: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    pub fn deinit(self: *Writer) void {
        self.lock_file.close(self.io);
        self.gpa.free(self.lock_path);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    pub fn setRedactor(self: *Writer, r: ?*const redact_mod.Redactor) void {
        self.redactor = r;
    }

    /// Persist transcript atomically, preserving the prior file on failure.
    /// Redacts into temporary buffers only; does not mutate `messages`.
    pub fn save(self: *Writer, messages: []const message.Message, meta: SessionMeta) Error!void {
        const fault = if (builtin.is_test) self.fail_before_replace else false;
        const redact_fault = if (builtin.is_test) self.fail_next_redact else false;
        if (builtin.is_test and self.fail_next_redact) self.fail_next_redact = false;
        try saveWithMetaAtomic(self.gpa, self.io, self.cwd, self.path, messages, meta, fault, self.redactor, redact_fault);
    }

    /// Load the current session file into `transcript` and return header meta.
    pub fn load(self: *Writer, transcript: *transcript_mod.Transcript) Error!SessionMeta {
        return loadWithMeta(self.gpa, self.io, self.cwd, self.path, transcript);
    }
};

/// Test-only helpers. Production code has no entry that enables save faults.
pub const testing = if (builtin.is_test) struct {
    pub fn setFailBeforeReplace(writer: *Writer, enabled: bool) void {
        writer.fail_before_replace = enabled;
    }
    pub fn setFailNextRedact(writer: *Writer, enabled: bool) void {
        writer.fail_next_redact = enabled;
    }
} else struct {};

/// Lexical relative-workspace check for session paths (no symlink resolution).
pub fn validateSessionPath(path: []const u8) Error!void {
    workspace.checkToolPath(path) catch return error.InvalidPath;
}

fn lockPathFor(gpa: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.lock", .{path});
}

fn ensureParentDir(cwd: Io.Dir, io: Io, path: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) {
            cwd.createDirPath(io, dir_path) catch return error.IoFailed;
        }
    }
}

fn mapAllocErr(err: std.mem.Allocator.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Open/create the lock sidecar and take a non-blocking exclusive advisory lock.
/// Stale sidecars (file present, no holder) are reusable. An active holder → `SessionBusy`.
fn acquireLockFile(cwd: Io.Dir, io: Io, lock_path: []const u8) Error!Io.File {
    return cwd.createFile(io, lock_path, .{
        .read = true,
        .exclusive = false,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => error.SessionBusy,
        else => error.IoFailed,
    };
}

fn sessionFileExists(cwd: Io.Dir, io: Io, path: []const u8) Error!bool {
    cwd.access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.IoFailed,
    };
    return true;
}

const Acquired = struct {
    path_owned: []u8,
    lock_path: []u8,
    lock_file: Io.File,

    fn release(self: *Acquired, gpa: std.mem.Allocator, io: Io) void {
        self.lock_file.close(io);
        gpa.free(self.lock_path);
        gpa.free(self.path_owned);
        self.* = undefined;
    }
};

fn acquireWriterLease(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
) Error!Acquired {
    try validateSessionPath(path);

    const path_owned = gpa.dupe(u8, path) catch return error.OutOfMemory;
    errdefer gpa.free(path_owned);

    const lock_path = lockPathFor(gpa, path) catch |err| return mapAllocErr(err);
    errdefer gpa.free(lock_path);

    try ensureParentDir(cwd, io, path);

    const lock_file = try acquireLockFile(cwd, io, lock_path);
    errdefer lock_file.close(io);

    return .{
        .path_owned = path_owned,
        .lock_path = lock_path,
        .lock_file = lock_file,
    };
}

/// Create a new persisted session. Fails if the session file already exists.
/// `redactor` is stored on the Writer for subsequent saves and applied to the
/// initial create write (null = low-level bypass).
pub fn createNew(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
) Error!Writer {
    return createNewWithRedactor(gpa, io, cwd, path, messages, meta, null);
}

pub fn createNewWithRedactor(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
    redactor: ?*const redact_mod.Redactor,
) Error!Writer {
    try validateSessionPath(path);
    // Fast path: existing bytes must not be touched and need not take the lock.
    if (try sessionFileExists(cwd, io, path)) return error.SessionAlreadyExists;

    var lease = try acquireWriterLease(gpa, io, cwd, path);
    errdefer lease.release(gpa, io);

    // Race: another writer may have materialized the file between access and lock.
    if (try sessionFileExists(cwd, io, path)) return error.SessionAlreadyExists;

    try saveWithMetaAtomicCreate(gpa, io, cwd, path, messages, meta, false, redactor, false);

    return .{
        .gpa = gpa,
        .io = io,
        .cwd = cwd,
        .path = lease.path_owned,
        .lock_path = lease.lock_path,
        .lock_file = lease.lock_file,
        .redactor = redactor,
    };
}

/// Resume an existing persisted session. Fails if missing, invalid, unsupported,
/// or already locked by another active writer.
pub fn resumeExisting(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    transcript: *transcript_mod.Transcript,
    out_meta: ?*SessionMeta,
) Error!Writer {
    try validateSessionPath(path);

    if (!try sessionFileExists(cwd, io, path)) return error.SessionNotFound;

    var lease = try acquireWriterLease(gpa, io, cwd, path);
    errdefer lease.release(gpa, io);

    // Race: file may have been deleted after access but before lock.
    if (!try sessionFileExists(cwd, io, path)) return error.SessionNotFound;

    const meta = try loadWithMeta(gpa, io, cwd, path, transcript);
    if (out_meta) |m| m.* = meta;

    return .{
        .gpa = gpa,
        .io = io,
        .cwd = cwd,
        .path = lease.path_owned,
        .lock_path = lease.lock_path,
        .lock_file = lease.lock_file,
    };
}

/// Convenience: resume if present, otherwise create a new session.
/// Only `SessionNotFound` triggers creation; every other error propagates.
/// Prefer explicit create/resume at CLI boundaries; this is an SDK helper.
pub fn openOrCreate(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
    transcript: *transcript_mod.Transcript,
    out_meta: ?*SessionMeta,
) Error!Writer {
    return resumeExisting(gpa, io, cwd, path, transcript, out_meta) catch |err| switch (err) {
        error.SessionNotFound => return createNew(gpa, io, cwd, path, messages, meta),
        else => |e| return e,
    };
}

/// Brief exclusive lease used by public save helpers so they cannot bypass single-writer.
const BriefLock = struct {
    gpa: std.mem.Allocator,
    io: Io,
    lock_path: []u8,
    lock_file: Io.File,

    fn deinit(self: *BriefLock) void {
        self.lock_file.close(self.io);
        self.gpa.free(self.lock_path);
        self.* = undefined;
    }
};

fn acquireBriefLock(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
) Error!BriefLock {
    try validateSessionPath(path);
    const lock_path = lockPathFor(gpa, path) catch |err| return mapAllocErr(err);
    errdefer gpa.free(lock_path);
    try ensureParentDir(cwd, io, path);
    const lock_file = try acquireLockFile(cwd, io, lock_path);
    return .{
        .gpa = gpa,
        .io = io,
        .lock_path = lock_path,
        .lock_file = lock_file,
    };
}

/// State-saving helper: write full bytes to a temporary file and atomically replace.
/// `fail_before_replace` is production-false; only test Writers pass true via testing helper.
fn saveWithMetaAtomic(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
    fail_before_replace: bool,
    redactor: ?*const redact_mod.Redactor,
    fail_redact: bool,
) Error!void {
    if (fail_redact) return error.OutOfMemory;

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    try writeHeaderRedacted(gpa, &body.writer, meta, redactor);
    for (messages) |msg| {
        try writeMessageRedacted(gpa, &body.writer, msg, redactor);
    }

    var atomic = cwd.createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    }) catch |err| return mapCreateAtomicErr(err);
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    const w = &file_writer.interface;
    w.writeAll(body.written()) catch return error.IoFailed;
    file_writer.flush() catch return error.IoFailed;

    if (fail_before_replace) return error.IoFailed;

    atomic.replace(io) catch return error.IoFailed;
}

/// Like saveWithMetaAtomic but fails if the target already exists.
fn saveWithMetaAtomicCreate(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
    fail_before_replace: bool,
    redactor: ?*const redact_mod.Redactor,
    fail_redact: bool,
) Error!void {
    if (fail_redact) return error.OutOfMemory;

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    try writeHeaderRedacted(gpa, &body.writer, meta, redactor);
    for (messages) |msg| {
        try writeMessageRedacted(gpa, &body.writer, msg, redactor);
    }

    var atomic = cwd.createFileAtomic(io, path, .{
        .make_path = true,
        .replace = false,
    }) catch |err| return mapCreateAtomicErr(err);
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    const w = &file_writer.interface;
    w.writeAll(body.written()) catch return error.IoFailed;
    file_writer.flush() catch return error.IoFailed;

    if (fail_before_replace) return error.IoFailed;

    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SessionAlreadyExists,
        else => return error.IoFailed,
    };
}

fn mapCreateAtomicErr(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailed,
    };
}

/// Public save: acquires the writer lock for the call so it cannot bypass single-writer.
/// Low-level: no redactor (product Session.Writer path attaches policy).
pub fn save(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
) Error!void {
    try saveWithMeta(gpa, io, cwd, path, messages, .{});
}

/// Public save with meta: acquires the writer lock for the call so it cannot bypass single-writer.
/// Low-level: no redactor. Prefer `Writer.save` after `setRedactor` on the product path.
pub fn saveWithMeta(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
) Error!void {
    var lock = try acquireBriefLock(gpa, io, cwd, path);
    defer lock.deinit();
    try saveWithMetaAtomic(gpa, io, cwd, path, messages, meta, false, null, false);
}

/// Public save with optional redactor (SDK convenience).
pub fn saveWithMetaRedacted(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    messages: []const message.Message,
    meta: SessionMeta,
    redactor: ?*const redact_mod.Redactor,
) Error!void {
    var lock = try acquireBriefLock(gpa, io, cwd, path);
    defer lock.deinit();
    try saveWithMetaAtomic(gpa, io, cwd, path, messages, meta, false, redactor, false);
}

/// Load jsonl into an empty transcript (messages are arena-owned via transcript).
pub fn load(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    transcript: *transcript_mod.Transcript,
) Error!void {
    _ = try loadWithMeta(gpa, io, cwd, path, transcript);
}

/// Like `load`, but also returns header meta. String fields in the result are
/// duped into `transcript.arena` (live as long as the transcript arena).
pub fn loadWithMeta(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    transcript: *transcript_mod.Transcript,
) Error!SessionMeta {
    try validateSessionPath(path);

    const raw = cwd.readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.SessionNotFound,
        else => return error.IoFailed,
    };
    defer gpa.free(raw);

    return parseSessionBytes(gpa, transcript, raw);
}

/// Parse session file bytes (exported for tests of the strict header contract).
pub fn parseSessionBytes(
    gpa: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    raw: []const u8,
) Error!SessionMeta {
    var meta: SessionMeta = .{};
    var saw_header = false;
    var saw_message = false;
    var line_start: usize = 0;
    while (line_start < raw.len) {
        const rest = raw[line_start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        line_start += nl + 1;
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
            return error.InvalidSession;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSession;
        const obj = parsed.value.object;

        if (objectIsSessionHeader(obj)) {
            // Header only on the first content line; duplicates / mid-stream headers rejected.
            if (saw_header or saw_message) return error.InvalidSession;
            meta = try parseHeaderObject(gpa, transcript.arena, obj);
            saw_header = true;
            continue;
        }

        try appendMessageFromObject(gpa, transcript, obj);
        saw_message = true;
    }

    if (!saw_message) return error.InvalidSession;
    if (!saw_header) {
        // Legacy file without header: implied schema v1.
        meta = .{};
    }
    return meta;
}

fn objectIsSessionHeader(obj: std.json.ObjectMap) bool {
    const t = obj.get("type") orelse return false;
    return t == .string and std.mem.eql(u8, t.string, header_type);
}

fn parseHeaderObject(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
) Error!SessionMeta {
    _ = gpa;
    // Exact type already checked by caller.
    const version = try resolveHeaderVersion(obj);
    if (version != current_schema_version) return error.UnsupportedSchema;

    var meta: SessionMeta = .{
        .schema_version = version,
        .compaction_gen = 0,
    };
    if (obj.get("compaction_gen")) |cg| {
        meta.compaction_gen = try jsonInt(cg);
    }
    if (obj.get("zag_version")) |zv| {
        if (zv == .string) {
            meta.zag_version = arena.dupe(u8, zv.string) catch return error.OutOfMemory;
        } else if (zv != .null) {
            return error.InvalidSession;
        }
    }
    if (obj.get("compaction_summary")) |cs| {
        if (cs == .string) {
            meta.compaction_summary = arena.dupe(u8, cs.string) catch return error.OutOfMemory;
        } else if (cs != .null) {
            return error.InvalidSession;
        }
    }
    return meta;
}

fn resolveHeaderVersion(obj: std.json.ObjectMap) Error!u32 {
    // A typed header (`type=zag_session`) must declare an integer version field.
    // Header-less legacy message files never reach this path (implied v1).
    const sv = obj.get("schema_version");
    const v = obj.get("v");
    if (sv == null and v == null) return error.InvalidSession;

    const sv_int: ?u32 = if (sv) |x| try jsonInt(x) else null;
    const v_int: ?u32 = if (v) |x| try jsonInt(x) else null;

    if (sv_int != null and v_int != null and sv_int.? != v_int.?) return error.InvalidSession;
    return sv_int orelse v_int.?;
}

/// Integer-only version fields; floats/strings rejected.
fn jsonInt(v: std.json.Value) Error!u32 {
    return switch (v) {
        .integer => |i| blk: {
            if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidSession;
            break :blk @intCast(i);
        },
        else => error.InvalidSession,
    };
}

fn redactField(
    gpa: std.mem.Allocator,
    redactor: ?*const redact_mod.Redactor,
    value: []const u8,
) Error![]u8 {
    return redact_mod.redactOptional(redactor, gpa, value);
}

fn writeHeaderRedacted(
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    meta: SessionMeta,
    redactor: ?*const redact_mod.Redactor,
) Error!void {
    var owned_summary: ?[]u8 = null;
    defer if (owned_summary) |s| gpa.free(s);
    var owned_ver: ?[]u8 = null;
    defer if (owned_ver) |s| gpa.free(s);

    const summary_out: ?[]const u8 = if (meta.compaction_summary) |sum| blk: {
        const r = try redactField(gpa, redactor, sum);
        // Always owned when redactor path used; redactOptional always dups.
        owned_summary = r;
        break :blk r;
    } else null;
    const ver_out: ?[]const u8 = if (meta.zag_version) |zv| blk: {
        const r = try redactField(gpa, redactor, zv);
        owned_ver = r;
        break :blk r;
    } else null;

    writeHeaderRaw(w, meta.schema_version, ver_out, meta.compaction_gen, summary_out) catch
        return error.OutOfMemory;
}

fn writeHeaderRaw(
    w: *Io.Writer,
    schema_version: u32,
    zag_version: ?[]const u8,
    compaction_gen: u32,
    compaction_summary: ?[]const u8,
) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("schema_version");
    try s.write(schema_version);
    try s.objectField("v");
    try s.write(schema_version);
    try s.objectField("type");
    try s.write(header_type);
    if (zag_version) |zv| {
        try s.objectField("zag_version");
        try s.write(zv);
    }
    try s.objectField("compaction_gen");
    try s.write(compaction_gen);
    if (compaction_summary) |sum| {
        try s.objectField("compaction_summary");
        try s.write(sum);
    }
    try s.endObject();
    try w.writeAll("\n");
}

fn writeMessageRedacted(
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    msg: message.Message,
    redactor: ?*const redact_mod.Redactor,
) Error!void {
    // Collect owned redacted strings; free after write.
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }

    const take = struct {
        fn call(
            alloc: std.mem.Allocator,
            list: *std.ArrayList([]u8),
            r: ?*const redact_mod.Redactor,
            v: []const u8,
        ) Error![]u8 {
            const out = try redactField(alloc, r, v);
            list.append(alloc, out) catch {
                alloc.free(out);
                return error.OutOfMemory;
            };
            return out;
        }
    }.call;

    const content = try take(gpa, &owned, redactor, msg.content);
    const tool_call_id: ?[]const u8 = if (msg.tool_call_id) |id|
        try take(gpa, &owned, redactor, id)
    else
        null;

    // Redact content_parts when present (text + image URLs).
    var parts_owned: ?[]message.ContentPart = null;
    defer if (parts_owned) |p| gpa.free(p);
    const parts_out: ?[]const message.ContentPart = if (msg.content_parts) |parts| blk: {
        const arr = gpa.alloc(message.ContentPart, parts.len) catch return error.OutOfMemory;
        parts_owned = arr;
        for (parts, 0..) |p, i| {
            switch (p) {
                .text => |t| {
                    const rt = try take(gpa, &owned, redactor, t);
                    arr[i] = .{ .text = rt };
                },
                .image_url => |img| {
                    const ru = try take(gpa, &owned, redactor, img.url);
                    const rd: ?[]const u8 = if (img.detail) |d| try take(gpa, &owned, redactor, d) else null;
                    arr[i] = .{ .image_url = .{ .url = ru, .detail = rd } };
                },
            }
        }
        break :blk arr;
    } else null;

    var calls_owned: ?[]message.ToolCall = null;
    defer if (calls_owned) |c| gpa.free(c);
    const calls_out: ?[]const message.ToolCall = if (msg.tool_calls) |calls| blk: {
        const arr = gpa.alloc(message.ToolCall, calls.len) catch return error.OutOfMemory;
        calls_owned = arr;
        for (calls, 0..) |c, i| {
            arr[i] = .{
                .id = try take(gpa, &owned, redactor, c.id),
                .name = try take(gpa, &owned, redactor, c.name),
                .arguments = try take(gpa, &owned, redactor, c.arguments),
            };
        }
        break :blk arr;
    } else null;

    writeMessageRaw(w, msg.role, content, tool_call_id, calls_out, parts_out) catch
        return error.OutOfMemory;
}

fn writeMessageRaw(
    w: *Io.Writer,
    role: message.Role,
    content: []const u8,
    tool_call_id: ?[]const u8,
    tool_calls: ?[]const message.ToolCall,
    content_parts: ?[]const message.ContentPart,
) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("role");
    try s.write(role.jsonName());

    switch (role) {
        .tool => {
            try s.objectField("tool_call_id");
            try s.write(tool_call_id orelse "");
            try s.objectField("content");
            try s.write(content);
        },
        .assistant => {
            try s.objectField("content");
            try s.write(content);
            if (tool_calls) |calls| {
                try s.objectField("tool_calls");
                try s.beginArray();
                for (calls) |c| {
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(c.id);
                    try s.objectField("name");
                    try s.write(c.name);
                    try s.objectField("arguments");
                    try s.write(c.arguments);
                    try s.endObject();
                }
                try s.endArray();
            }
        },
        .system, .user => {
            if (content_parts) |parts| {
                try s.objectField("content_parts");
                try s.beginArray();
                for (parts) |p| {
                    try s.beginObject();
                    switch (p) {
                        .text => |t| {
                            try s.objectField("type");
                            try s.write("text");
                            try s.objectField("text");
                            try s.write(t);
                        },
                        .image_url => |img| {
                            try s.objectField("type");
                            try s.write("image_url");
                            try s.objectField("url");
                            try s.write(img.url);
                            if (img.detail) |d| {
                                try s.objectField("detail");
                                try s.write(d);
                            }
                        },
                    }
                    try s.endObject();
                }
                try s.endArray();
            }
            try s.objectField("content");
            try s.write(content);
        },
    }

    try s.endObject();
    try w.writeAll("\n");
}

fn appendMessageFromObject(
    gpa: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    obj: std.json.ObjectMap,
) Error!void {
    const role_v = obj.get("role") orelse return error.InvalidSession;
    if (role_v != .string) return error.InvalidSession;
    const role = parseRole(role_v.string) orelse return error.InvalidSession;

    const content = blk: {
        if (obj.get("content")) |c| {
            if (c == .string) break :blk c.string;
            if (c == .null) break :blk "";
            return error.InvalidSession;
        }
        break :blk "";
    };

    switch (role) {
        .system => try transcript.appendSystem(content),
        .user => try transcript.appendUser(content),
        .assistant => {
            if (obj.get("tool_calls")) |tc| {
                if (tc != .array) return error.InvalidSession;
                if (tc.array.items.len == 0) {
                    try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = &.{} });
                    return;
                }
                const calls = gpa.alloc(message.ToolCall, tc.array.items.len) catch
                    return error.OutOfMemory;
                defer gpa.free(calls);
                for (tc.array.items, 0..) |item, i| {
                    if (item != .object) return error.InvalidSession;
                    const id = item.object.get("id") orelse return error.InvalidSession;
                    const name = item.object.get("name") orelse return error.InvalidSession;
                    const args = item.object.get("arguments") orelse return error.InvalidSession;
                    if (id != .string or name != .string or args != .string) return error.InvalidSession;
                    calls[i] = .{
                        .id = id.string,
                        .name = name.string,
                        .arguments = args.string,
                    };
                }
                try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = calls });
            } else {
                try transcript.appendAssistantTurn(.{ .content = content, .tool_calls = &.{} });
            }
        },
        .tool => {
            const id_v = obj.get("tool_call_id") orelse return error.InvalidSession;
            if (id_v != .string) return error.InvalidSession;
            try appendToolWithOwnedId(transcript, id_v.string, content);
        },
    }
}

fn appendToolWithOwnedId(
    transcript: *transcript_mod.Transcript,
    tool_call_id: []const u8,
    content: []const u8,
) transcript_mod.Error!void {
    const id = transcript.arena.dupe(u8, tool_call_id) catch return error.OutOfMemory;
    const body = transcript.arena.dupe(u8, content) catch return error.OutOfMemory;
    transcript.messages.append(transcript.arena, message.Message.toolResult(id, body)) catch
        return error.OutOfMemory;
}

fn parseRole(s: []const u8) ?message.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

// ── D-006 contract tests ────────────────────────────────────────────────────

test "Writer create-existing fails without changing the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"original"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = content });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    try t.appendSystem("sys");

    const err = createNew(gpa, io, tmp.dir, "s.jsonl", t.items(), .{});
    try std.testing.expectError(error.SessionAlreadyExists, err);

    const raw = try tmp.dir.readFileAlloc(io, "s.jsonl", gpa, .limited(1024));
    defer gpa.free(raw);
    try std.testing.expectEqualStrings(content, raw);
}

test "Writer resume missing returns not-found" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());

    const err = resumeExisting(gpa, io, tmp.dir, "missing.jsonl", &t, null);
    try std.testing.expectError(error.SessionNotFound, err);
}

test "Writer resume invalid returns invalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad = "not json\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jsonl", .data = bad });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());

    const err = resumeExisting(gpa, io, tmp.dir, "bad.jsonl", &t, null);
    try std.testing.expectError(error.InvalidSession, err);
}

test "Writer resume unsupported returns unsupported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad =
        \\{"schema_version":99,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jsonl", .data = bad });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());

    const err = resumeExisting(gpa, io, tmp.dir, "bad.jsonl", &t, null);
    try std.testing.expectError(error.UnsupportedSchema, err);
}

test "Writer save failpoint preserves prior bytes and reloads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"keep"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = original });

    var resume_arena: std.heap.ArenaAllocator = .init(gpa);
    defer resume_arena.deinit();
    var resume_t = transcript_mod.Transcript.init(resume_arena.allocator());
    var writer = try resumeExisting(gpa, io, tmp.dir, "s.jsonl", &resume_t, null);
    defer writer.deinit();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    try t.appendSystem("sys");
    try t.appendUser("overwrite");

    testing.setFailBeforeReplace(&writer, true);
    defer testing.setFailBeforeReplace(&writer, false);

    const err = writer.save(t.items(), .{});
    try std.testing.expectError(error.IoFailed, err);

    const raw = try tmp.dir.readFileAlloc(io, "s.jsonl", gpa, .limited(1024));
    defer gpa.free(raw);
    try std.testing.expectEqualStrings(original, raw);

    // Prior bytes remain loadable as a session.
    var load_arena: std.heap.ArenaAllocator = .init(gpa);
    defer load_arena.deinit();
    var loaded = transcript_mod.Transcript.init(load_arena.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "s.jsonl", &loaded);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 1), loaded.items().len);
    try std.testing.expectEqualStrings("keep", loaded.items()[0].content);
}

test "Writer conflict prevents second active writer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"locked"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = content });

    // Cross-process holder: same-process flock may not conflict on all hosts.
    // Child is bounded (SIGALRM) so a parent read cannot hang forever if the child dies.
    const script =
        \\import fcntl, signal, sys, time
        \\signal.alarm(8)
        \\f = open("s.jsonl.lock", "a+")
        \\fcntl.flock(f, fcntl.LOCK_EX)
        \\sys.stdout.write("ready\n")
        \\sys.stdout.flush()
        \\# Hold until parent kills us or alarm fires.
        \\time.sleep(30)
    ;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", script },
        .cwd = .{ .dir = tmp.dir },
        .stdout = .pipe,
    });
    defer {
        // Close our end of the pipe before kill (kill asserts pipes are cleaned).
        if (child.stdout) |f| {
            f.close(io);
            child.stdout = null;
        }
        child.kill(io);
    }

    // Wait for the child to report the lock is held (EOF if child dies → fail, not hang).
    var stdout_buf: [64]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const line = stdout_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.TestUnexpectedResult,
        else => return err,
    };
    try std.testing.expectEqualStrings("ready", line);

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    const err = resumeExisting(gpa, io, tmp.dir, "s.jsonl", &t2, null);
    try std.testing.expectError(error.SessionBusy, err);

    // Public save must also respect the active writer.
    const save_err = save(gpa, io, tmp.dir, "s.jsonl", t2.items());
    try std.testing.expectError(error.SessionBusy, save_err);
}

test "Writer resume general I/O is distinct from not-found; openOrCreate does not create" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Session path is a directory: access may succeed, but reading as a file → IoFailed
    // (not SessionNotFound). openOrCreate must propagate, not create-over.
    try tmp.dir.createDirPath(io, "as_dir.jsonl");

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    try t.appendUser("seed");

    const resume_err = resumeExisting(gpa, io, tmp.dir, "as_dir.jsonl", &t, null);
    try std.testing.expectError(error.IoFailed, resume_err);

    var t2 = transcript_mod.Transcript.init(arena_impl.allocator());
    const ooc_err = openOrCreate(gpa, io, tmp.dir, "as_dir.jsonl", t.items(), .{}, &t2, null);
    try std.testing.expectError(error.IoFailed, ooc_err);

    // Path remains a directory (not overwritten by a session file).
    var dir = try tmp.dir.openDir(io, "as_dir.jsonl", .{});
    dir.close(io);
}

test "stale lock sidecar is reusable after release" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pre-create a stale sidecar with no holder.
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl.lock", .data = "stale" });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hello");

    var writer = try createNew(gpa, io, tmp.dir, "s.jsonl", t1.items(), .{});
    writer.deinit();

    // Re-open after release (持锁重开 after unlock).
    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    var writer2 = try resumeExisting(gpa, io, tmp.dir, "s.jsonl", &t2, null);
    defer writer2.deinit();
    try std.testing.expectEqual(@as(usize, 2), t2.items().len);
}

test "Writer create/resume/save roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hello");

    var writer = try createNew(gpa, io, tmp.dir, "s.jsonl", t1.items(), .{
        .zag_version = "0.5.0",
        .compaction_gen = 1,
    });

    try t1.appendAssistantTurn(.{ .content = "hi", .tool_calls = &.{} });
    try writer.save(t1.items(), .{
        .zag_version = "0.5.0",
        .compaction_gen = 1,
    });
    writer.deinit();

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    var writer2 = try resumeExisting(gpa, io, tmp.dir, "s.jsonl", &t2, null);
    defer writer2.deinit();

    try std.testing.expectEqual(@as(usize, 3), t2.items().len);
}

test "session path rejects absolute and escape" {
    try std.testing.expectError(error.InvalidPath, validateSessionPath("/etc/passwd"));
    try std.testing.expectError(error.InvalidPath, validateSessionPath("../secret.jsonl"));
    try std.testing.expectError(error.InvalidPath, validateSessionPath(""));
    try validateSessionPath(".zag/sessions/default.jsonl");
}

test "load FileNotFound maps to SessionNotFound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const err = loadWithMeta(gpa, io, tmp.dir, "gone.jsonl", &t);
    try std.testing.expectError(error.SessionNotFound, err);
}

test "strict header: float version rejected" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"schema_version":1.5,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "strict header: type without version fields is InvalidSession" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "strict header: conflicting schema_version and v rejected" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"schema_version":1,"v":2,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "strict header: mid-stream header rejected" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"role":"user","content":"first"}
        \\{"schema_version":1,"type":"zag_session"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "strict header: duplicate header rejected" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"schema_version":1,"type":"zag_session"}
        \\{"schema_version":1,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "strict header: ordinary content mentioning zag_session is not a header" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const raw =
        \\{"role":"user","content":"type zag_session is cool"}
        \\
    ;
    const meta = try parseSessionBytes(gpa, &t, raw);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 1), t.items().len);
    try std.testing.expectEqualStrings("type zag_session is cool", t.items()[0].content);
}

test "strict header: wrong type value is not a session header" {
    const gpa = std.testing.allocator;
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    // type present but not zag_session → must not parse as header; lacks role → invalid message.
    const raw =
        \\{"type":"other","schema_version":1}
        \\{"role":"user","content":"x"}
        \\
    ;
    const err = parseSessionBytes(gpa, &t, raw);
    try std.testing.expectError(error.InvalidSession, err);
}

test "openOrCreate creates only on not-found" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    try t.appendUser("seed");

    var w = try openOrCreate(gpa, io, tmp.dir, "o.jsonl", t.items(), .{}, &t, null);
    w.deinit();

    // Invalid existing file must not be replaced by openOrCreate.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jsonl", .data = "not-json\n" });
    var t2 = transcript_mod.Transcript.init(arena_impl.allocator());
    const err = openOrCreate(gpa, io, tmp.dir, "bad.jsonl", t.items(), .{}, &t2, null);
    try std.testing.expectError(error.InvalidSession, err);
}

test "save and load roundtrip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hello");
    try t1.appendAssistantTurn(.{ .content = "hi", .tool_calls = &.{} });

    try save(gpa, io, tmp.dir, "s.jsonl", t1.items());

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "s.jsonl", &t2);

    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 3), t2.items().len);
    try std.testing.expectEqualStrings("sys", t2.items()[0].content);
    try std.testing.expectEqualStrings("hello", t2.items()[1].content);
    try std.testing.expectEqualStrings("hi", t2.items()[2].content);
}

test "save load with tool_calls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("ls");
    const calls = [_]message.ToolCall{.{
        .id = "call1",
        .name = "list_dir",
        .arguments = "{\"path\":\".\"}",
    }};
    try t1.appendAssistantTurn(.{ .content = "", .tool_calls = &calls });
    try t1.appendToolResult("call1", "file\tfile\n");

    try save(gpa, io, tmp.dir, "t.jsonl", t1.items());

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    try load(gpa, io, tmp.dir, "t.jsonl", &t2);

    try std.testing.expectEqual(@as(usize, 4), t2.items().len);
    try std.testing.expect(t2.items()[2].tool_calls != null);
    try std.testing.expectEqualStrings("list_dir", t2.items()[2].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call1", t2.items()[3].tool_call_id.?);
}

test "saveWithMeta persists compaction fields" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t1 = transcript_mod.Transcript.init(arena_impl.allocator());
    try t1.appendSystem("sys");
    try t1.appendUser("hi");

    try saveWithMeta(gpa, io, tmp.dir, "m.jsonl", t1.items(), .{
        .zag_version = "0.5.0",
        .compaction_gen = 2,
        .compaction_summary = "earlier: user asked about files",
    });

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    var t2 = transcript_mod.Transcript.init(arena2.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "m.jsonl", &t2);
    try std.testing.expectEqual(@as(u32, 2), meta.compaction_gen);
    try std.testing.expectEqualStrings("0.5.0", meta.zag_version.?);
    try std.testing.expectEqualStrings("earlier: user asked about files", meta.compaction_summary.?);
}

test "unsupported schema_version is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad =
        \\{"schema_version":99,"type":"zag_session"}
        \\{"role":"user","content":"x"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.jsonl", .data = bad });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const err = load(gpa, io, tmp.dir, "bad.jsonl", &t);
    try std.testing.expectError(error.UnsupportedSchema, err);
}

test "legacy header with only v loads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy =
        \\{"v":1,"type":"zag_session"}
        \\{"role":"system","content":"sys"}
        \\{"role":"user","content":"hi"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.jsonl", .data = legacy });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "legacy.jsonl", &t);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 2), t.items().len);
}

test "headerless file still loads as v1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bare =
        \\{"role":"user","content":"only"}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bare.jsonl", .data = bare });

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var t = transcript_mod.Transcript.init(arena_impl.allocator());
    const meta = try loadWithMeta(gpa, io, tmp.dir, "bare.jsonl", &t);
    try std.testing.expectEqual(current_schema_version, meta.schema_version);
    try std.testing.expectEqual(@as(usize, 1), t.items().len);
}
