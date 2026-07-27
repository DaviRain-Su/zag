//! Prompt Templates (E1 passive) — discovery, catalog, one-pass slash expansion.
//!
//! Binding: docs/modules/prompt-templates.md. Coding-agent only; no Core types.
//! No model summary layer; no catalog/read Tool; expansion never re-reads FS.

const std = @import("std");
const Io = std.Io;
const workspace = @import("workspace.zig");

// ── Bind constants (prompt-templates.md §3.3) ───────────────────────────────

pub const max_name_len: usize = 64;
pub const max_file_bytes: usize = 24 * 1024;
pub const max_entries_per_root: usize = 64;
pub const max_source_aggregate: usize = 256 * 1024;
pub const max_arguments_bytes: usize = 8 * 1024;
pub const max_expansion_bytes: usize = 32 * 1024;

pub const ProjectTemplatesTrust = enum { untrusted, trusted };
pub const TemplateOrigin = enum { user, project };

/// Reserved filename stem — collides with `/skill:` routing.
pub const reserved_name = "skill";

/// Path-free, body-free discovery diagnostics (prompt-templates.md §9).
pub const DiagCode = enum {
    root_missing,
    root_escape,
    entry_limit,
    candidate_io,
    candidate_escape,
    invalid_utf8,
    name_invalid,
    name_reserved,
    body_empty,
    file_too_large,
    source_budget,
    project_override,

    pub fn name(self: DiagCode) []const u8 {
        return @tagName(self);
    }
};

pub const TemplateEntry = struct {
    name: []const u8,
    body: []const u8,
    origin: TemplateOrigin,
};

pub const Catalog = struct {
    entries: []const TemplateEntry = &.{},
    diags: []const DiagCode = &.{},

    pub fn find(self: Catalog, name: []const u8) ?*const TemplateEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

pub const DiscoverOptions = struct {
    templates_enabled: bool = true,
    project_templates_trust: ProjectTemplatesTrust = .untrusted,
    /// Host-owned user templates root (`…/.agents/prompts`). Never getenv in SDK path.
    user_templates_root: ?[]const u8 = null,
    /// Workspace cwd used for project root and project containment.
    workspace_cwd: Io.Dir,
};

// ── Discovery ───────────────────────────────────────────────────────────────

/// Discover templates into `arena`-owned catalog. Soft-skips invalid candidates;
/// OOM is hard-fail (`error.OutOfMemory`).
pub fn discover(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    opts: DiscoverOptions,
) error{OutOfMemory}!Catalog {
    if (!opts.templates_enabled) {
        return .{};
    }

    var diags: std.ArrayListUnmanaged(DiagCode) = .empty;
    defer diags.deinit(gpa);

    var accepted: std.ArrayListUnmanaged(TemplateEntry) = .empty;
    defer accepted.deinit(gpa);

    var source_total: usize = 0;

    // OOM is hard-fail; other resolve errors soft-null so project containment
    // falls through to root_escape when trust is on.
    const workspace_real: ?[]u8 = workspace.resolveCwdReal(gpa, io, opts.workspace_cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (workspace_real) |w| gpa.free(w);

    if (opts.user_templates_root) |user_root| {
        try discoverRoot(
            gpa,
            io,
            arena,
            user_root,
            .user,
            null,
            &accepted,
            &diags,
            &source_total,
        );
    }

    if (opts.project_templates_trust == .trusted) {
        const project_root_rel = ".agents/prompts";
        var abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (opts.workspace_cwd.realPathFile(io, project_root_rel, &abs_buf)) |n| {
            const project_abs = abs_buf[0..n];
            try discoverRoot(
                gpa,
                io,
                arena,
                project_abs,
                .project,
                workspace_real,
                &accepted,
                &diags,
                &source_total,
            );
        } else |_| {
            try diags.append(gpa, .root_missing);
        }
    }

    const entries_out = if (accepted.items.len == 0)
        @as([]const TemplateEntry, &.{})
    else blk: {
        const out = try arena.alloc(TemplateEntry, accepted.items.len);
        @memcpy(out, accepted.items);
        break :blk out;
    };

    const diags_out = if (diags.items.len == 0)
        @as([]const DiagCode, &.{})
    else blk: {
        const out = try arena.alloc(DiagCode, diags.items.len);
        @memcpy(out, diags.items);
        break :blk out;
    };

    return .{
        .entries = entries_out,
        .diags = diags_out,
    };
}

fn discoverRoot(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    root_path: []const u8,
    origin: TemplateOrigin,
    workspace_real: ?[]const u8,
    accepted: *std.ArrayListUnmanaged(TemplateEntry),
    diags: *std.ArrayListUnmanaged(DiagCode),
    source_total: *usize,
) error{OutOfMemory}!void {
    var root_real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_real_n = realPathAny(io, root_path, &root_real_buf) catch {
        try diags.append(gpa, .root_missing);
        return;
    };
    const root_real = root_real_buf[0..root_real_n];

    if (origin == .project) {
        if (workspace_real) |ws| {
            if (!workspace.pathIsWithinRoot(ws, root_real)) {
                try diags.append(gpa, .root_escape);
                return;
            }
        } else {
            try diags.append(gpa, .root_escape);
            return;
        }
    }

    var dir = openRootDir(io, root_path) catch {
        try diags.append(gpa, .root_missing);
        return;
    };
    defer dir.close(io);

    // Collect all direct children for the entry budget (prompt-templates.md §3.1),
    // then filter to .md files. Non-.md names are ignored without soft-noise diags
    // when they fall within the cap window; only the >64 cap emits entry_limit.
    var all_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (all_names.items) |n| gpa.free(n);
        all_names.deinit(gpa);
    }

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch {
            try diags.append(gpa, .candidate_io);
            break;
        } orelse break;
        // Direct children only (files + dirs + links count toward the 64 budget).
        const owned = gpa.dupe(u8, entry.name) catch return error.OutOfMemory;
        all_names.append(gpa, owned) catch {
            gpa.free(owned);
            return error.OutOfMemory;
        };
    }

    std.mem.sortUnstable([]const u8, all_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    if (all_names.items.len > max_entries_per_root) {
        try diags.append(gpa, .entry_limit);
    }
    const limit = @min(all_names.items.len, max_entries_per_root);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const child_name = all_names.items[i];
        if (!std.mem.endsWith(u8, child_name, ".md")) continue;
        // Bare ".md" has empty stem — invalid name path via tryAccept.
        try tryAcceptCandidate(
            gpa,
            io,
            arena,
            root_real,
            root_path,
            child_name,
            origin,
            workspace_real,
            accepted,
            diags,
            source_total,
        );
    }
}

fn tryAcceptCandidate(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    root_real: []const u8,
    root_path: []const u8,
    child_name: []const u8,
    origin: TemplateOrigin,
    workspace_real: ?[]const u8,
    accepted: *std.ArrayListUnmanaged(TemplateEntry),
    diags: *std.ArrayListUnmanaged(DiagCode),
    source_total: *usize,
) error{OutOfMemory}!void {
    // Stem = basename without trailing ".md"
    const stem = child_name[0 .. child_name.len - ".md".len];
    if (!isValidTemplateName(stem)) {
        try diags.append(gpa, .name_invalid);
        return;
    }
    if (std.mem.eql(u8, stem, reserved_name)) {
        try diags.append(gpa, .name_reserved);
        return;
    }

    const file_path = try joinPath(gpa, root_path, child_name);
    defer gpa.free(file_path);

    var cand_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cand_n = realPathAny(io, file_path, &cand_buf) catch {
        try diags.append(gpa, .candidate_io);
        return;
    };
    const cand_real = cand_buf[0..cand_n];
    if (!workspace.pathIsWithinRoot(root_real, cand_real)) {
        try diags.append(gpa, .candidate_escape);
        return;
    }
    if (origin == .project) {
        if (workspace_real) |ws| {
            if (!workspace.pathIsWithinRoot(ws, cand_real)) {
                try diags.append(gpa, .candidate_escape);
                return;
            }
        }
    }

    // Must be a regular file after resolve (not a directory).
    {
        const st = if (std.fs.path.isAbsolute(file_path))
            Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = true }) catch {
                try diags.append(gpa, .candidate_io);
                return;
            }
        else
            Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = true }) catch {
                try diags.append(gpa, .candidate_io);
                return;
            };
        if (st.kind != .file) {
            try diags.append(gpa, .candidate_io);
            return;
        }
    }

    const raw = readFileLimited(gpa, io, file_path, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooLarge => {
            try diags.append(gpa, .file_too_large);
            return;
        },
        else => {
            try diags.append(gpa, .candidate_io);
            return;
        },
    };
    defer gpa.free(raw);

    if (!std.unicode.utf8ValidateSlice(raw)) {
        try diags.append(gpa, .invalid_utf8);
        return;
    }

    // Non-empty body (at least one non-whitespace byte).
    const body_trim = std.mem.trim(u8, raw, " \t\r\n");
    if (body_trim.len == 0) {
        try diags.append(gpa, .body_empty);
        return;
    }

    // Project overrides user by exact name: find superseded before budgets so a
    // net-fitting project body can replace the user body.
    var replace_idx: ?usize = null;
    if (origin == .project) {
        for (accepted.items, 0..) |e, idx| {
            if (std.mem.eql(u8, e.name, stem)) {
                replace_idx = idx;
                break;
            }
        }
    } else {
        // Within a single root: first accepted name wins; later duplicate soft-skip.
        for (accepted.items) |e| {
            if (std.mem.eql(u8, e.name, stem)) {
                try diags.append(gpa, .name_invalid);
                return;
            }
        }
    }

    var source_base = source_total.*;
    if (replace_idx) |idx| {
        source_base -|= accepted.items[idx].body.len;
    }

    if (source_base +| raw.len > max_source_aggregate) {
        try diags.append(gpa, .source_budget);
        return;
    }

    if (replace_idx) |idx| {
        const old = accepted.items[idx];
        source_total.* -|= old.body.len;
        try diags.append(gpa, .project_override);
        const name_a = try arena.dupe(u8, stem);
        const body_a = try arena.dupe(u8, raw);
        accepted.items[idx] = .{
            .name = name_a,
            .body = body_a,
            .origin = .project,
        };
        source_total.* += body_a.len;
        return;
    }

    const name_a = try arena.dupe(u8, stem);
    const body_a = try arena.dupe(u8, raw);
    try accepted.append(gpa, .{
        .name = name_a,
        .body = body_a,
        .origin = origin,
    });
    source_total.* += body_a.len;
}

/// Lower-kebab name: `[a-z0-9]+(-[a-z0-9]+)*`, length ≤ 64.
pub fn isValidTemplateName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    var i: usize = 0;
    var expect_alnum = true;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (expect_alnum) {
            if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
            expect_alnum = false;
        } else {
            if (c == '-') {
                expect_alnum = true;
            } else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
                // continue
            } else return false;
        }
    }
    return !expect_alnum;
}

// ── Public parse / expand ───────────────────────────────────────────────────

pub const TemplateExpansion = struct {
    /// Expanded ordinary user message text (gpa-owned; caller frees).
    user_text: []const u8,
    /// Command name that was expanded (borrowed from catalog).
    name: []const u8,
};

pub const TemplateExpansionError = error{
    UnknownTemplate,
    ArgumentsTooLarge,
    ExpansionTooLarge,
    OutOfMemory,
};

/// If input is exactly `/<name>` or `/<name>` + whitespace + rest, and `<name>`
/// is a valid lower-kebab token, return name + rest. Does **not** consult the
/// catalog. Unrelated shapes → null.
pub fn parseTemplateCommand(input: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '/') return null;
    // `/skill:…` is not a template slash form (skills host handles first).
    // We still only accept `/name` with a pure kebab token (no `:`).
    const after = trimmed[1..];
    if (after.len == 0) return null;
    var name_end: usize = 0;
    while (name_end < after.len) : (name_end += 1) {
        const c = after[name_end];
        if (c == ' ' or c == '\t') break;
    }
    if (name_end == 0) return null;
    const name = after[0..name_end];
    if (!isValidTemplateName(name)) return null;
    // Rest is everything after the first whitespace run following the name.
    var rest_start = name_end;
    while (rest_start < after.len) : (rest_start += 1) {
        const c = after[rest_start];
        if (c != ' ' and c != '\t') break;
    }
    const rest = after[rest_start..];
    return .{ .name = name, .rest = rest };
}

/// Expand a catalog template once. Unknown name → UnknownTemplate.
/// Does not call the provider. Does not re-read the filesystem.
/// `user_text` is owned by `gpa` (caller frees). `name` is borrowed from catalog.
pub fn expandTemplate(
    gpa: std.mem.Allocator,
    catalog: Catalog,
    name: []const u8,
    arguments: []const u8,
) TemplateExpansionError!TemplateExpansion {
    if (arguments.len > max_arguments_bytes) return error.ArgumentsTooLarge;
    const entry = catalog.find(name) orelse return error.UnknownTemplate;

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);

    var i: usize = 0;
    var substituted_arguments = false;
    const body = entry.body;
    const arg_token = "$ARGUMENTS";

    while (i < body.len) {
        if (body[i] == '$') {
            // `$$` → one `$`; do not rescan emitted `$`.
            if (i + 1 < body.len and body[i + 1] == '$') {
                try list.append(gpa, '$');
                i += 2;
                continue;
            }
            // exact `$ARGUMENTS`
            if (i + arg_token.len <= body.len and std.mem.eql(u8, body[i .. i + arg_token.len], arg_token)) {
                try list.appendSlice(gpa, arguments);
                substituted_arguments = true;
                i += arg_token.len;
                continue;
            }
            // bare `$` copies through
            try list.append(gpa, '$');
            i += 1;
            continue;
        }
        try list.append(gpa, body[i]);
        i += 1;
    }

    // Non-empty args with no unescaped `$ARGUMENTS` → append `\n\n` + args.
    if (arguments.len > 0 and !substituted_arguments) {
        try list.appendSlice(gpa, "\n\n");
        try list.appendSlice(gpa, arguments);
    }

    if (list.items.len > max_expansion_bytes) {
        // errdefer list.deinit frees the buffer; do not double-free here.
        return error.ExpansionTooLarge;
    }

    const owned = try list.toOwnedSlice(gpa);
    // Ownership transferred; disable errdefer free of the list buffer.
    list = .empty;
    return .{
        .user_text = owned,
        .name = entry.name,
    };
}

// ── Deep copy for fork ──────────────────────────────────────────────────────

/// Deep-copy catalog entries/diags into `arena`. Parent immutability.
pub fn deepCopyCatalog(arena: std.mem.Allocator, src: Catalog) error{OutOfMemory}!Catalog {
    const entries = if (src.entries.len == 0) @as([]const TemplateEntry, &.{}) else blk: {
        const out = try arena.alloc(TemplateEntry, src.entries.len);
        for (src.entries, 0..) |e, idx| {
            out[idx] = .{
                .name = try arena.dupe(u8, e.name),
                .body = try arena.dupe(u8, e.body),
                .origin = e.origin,
            };
        }
        break :blk out;
    };
    const diags = if (src.diags.len == 0) @as([]const DiagCode, &.{}) else blk: {
        const out = try arena.alloc(DiagCode, src.diags.len);
        @memcpy(out, src.diags);
        break :blk out;
    };
    return .{
        .entries = entries,
        .diags = diags,
    };
}

// ── FS helpers ──────────────────────────────────────────────────────────────

fn openRootDir(io: Io, root_path: []const u8) !Io.Dir {
    if (std.fs.path.isAbsolute(root_path)) {
        return Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    }
    return Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
}

fn realPathAny(io: Io, path: []const u8, out_buffer: []u8) !usize {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.realPathFileAbsolute(io, path, out_buffer);
    }
    return Io.Dir.cwd().realPathFile(io, path, out_buffer);
}

fn joinPath(gpa: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}![]u8 {
    if (a.len == 0) return gpa.dupe(u8, b);
    if (b.len == 0) return gpa.dupe(u8, a);
    const sep = std.fs.path.sep;
    if (a[a.len - 1] == sep) {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ a, b });
    }
    return std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ a, sep, b });
}

const ReadLimitedError = error{ OutOfMemory, FileTooLarge, IoFailed };

fn readFileLimited(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    limit: usize,
) ReadLimitedError![]u8 {
    // Zig 0.16 readFileAlloc(.limited(N)) returns StreamTooLong when size *reaches*
    // N (effective max N-1). Contract §3.3/§11.9 allows ≤ max_file_bytes and only
    // soft-skips > max. Request limit+1, then reject any successful read longer
    // than limit (covers backends that accept exactly limit+1 before erroring).
    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (isTooLargeError(err)) return error.FileTooLarge;
            return error.IoFailed;
        },
    };
    if (raw.len > limit) {
        gpa.free(raw);
        return error.FileTooLarge;
    }
    return raw;
}

fn isTooLargeError(err: anyerror) bool {
    return err == error.StreamTooLong or err == error.FileTooBig or
        std.mem.eql(u8, @errorName(err), "FileTooLarge") or
        std.mem.eql(u8, @errorName(err), "StreamTooLong");
}

// ── Unit tests (parse / expand / name) ──────────────────────────────────────

test "isValidTemplateName lower-kebab bounds" {
    try std.testing.expect(isValidTemplateName("ab"));
    try std.testing.expect(isValidTemplateName("a"));
    try std.testing.expect(isValidTemplateName("foo-bar-1"));
    try std.testing.expect(!isValidTemplateName(""));
    try std.testing.expect(!isValidTemplateName("Foo"));
    try std.testing.expect(!isValidTemplateName("-foo"));
    try std.testing.expect(!isValidTemplateName("foo-"));
    try std.testing.expect(!isValidTemplateName("foo_bar"));
    try std.testing.expect(!isValidTemplateName("foo bar"));
    var long: [65]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(!isValidTemplateName(&long));
}

test "parseTemplateCommand name + rest" {
    const a = parseTemplateCommand("/review").?;
    try std.testing.expectEqualStrings("review", a.name);
    try std.testing.expectEqualStrings("", a.rest);

    const b = parseTemplateCommand("  /review   fix the bug  ").?;
    try std.testing.expectEqualStrings("review", b.name);
    try std.testing.expectEqualStrings("fix the bug", b.rest);

    try std.testing.expect(parseTemplateCommand("review") == null);
    try std.testing.expect(parseTemplateCommand("/") == null);
    try std.testing.expect(parseTemplateCommand("/skill:foo") == null); // colon invalid kebab
    try std.testing.expect(parseTemplateCommand("/Foo") == null);
    try std.testing.expect(parseTemplateCommand("/help-me") != null);
}

test "expandTemplate $ARGUMENTS $$ no rescan append" {
    const gpa = std.testing.allocator;
    const catalog = Catalog{
        .entries = &[_]TemplateEntry{.{
            .name = "t",
            .body = "Hello $ARGUMENTS end $$ and $",
            .origin = .user,
        }},
    };
    const exp = try expandTemplate(gpa, catalog, "t", "ARGS$ARGUMENTS$$");
    defer gpa.free(exp.user_text);
    try std.testing.expectEqualStrings("Hello ARGS$ARGUMENTS$$ end $ and $", exp.user_text);

    const catalog2 = Catalog{
        .entries = &[_]TemplateEntry{.{
            .name = "u",
            .body = "static body",
            .origin = .user,
        }},
    };
    const exp2 = try expandTemplate(gpa, catalog2, "u", "tail");
    defer gpa.free(exp2.user_text);
    try std.testing.expectEqualStrings("static body\n\ntail", exp2.user_text);

    const exp3 = try expandTemplate(gpa, catalog2, "u", "");
    defer gpa.free(exp3.user_text);
    try std.testing.expectEqualStrings("static body", exp3.user_text);

    try std.testing.expectError(error.UnknownTemplate, expandTemplate(gpa, catalog, "nope", ""));
}
