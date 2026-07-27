//! Agent Skills (E1 passive) — discovery, catalog, read_skill, activation.
//!
//! Binding: docs/modules/skills.md. Coding-agent only; no Core Skill types.
//! Loader never executes skill bodies; File Tools stay workspace-jailed.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const tool = core.tool;
const tool_args = core.tool_args;
const tool_error = core.tool_error;
const workspace = @import("workspace.zig");

// ── Bind constants (skills.md §3.3) ─────────────────────────────────────────

pub const max_name_len: usize = 64;
pub const max_description_len: usize = 1024;
pub const max_file_bytes: usize = 24 * 1024;
pub const max_entries_per_root: usize = 64;
pub const max_summary_bytes: usize = 4096;
pub const max_body_aggregate: usize = 256 * 1024;

pub const ProjectSkillsTrust = enum { untrusted, trusted };
pub const SkillOrigin = enum { user, project };

/// Path-free, body-free discovery diagnostics (skills.md §9).
pub const DiagCode = enum {
    root_missing,
    root_escape,
    entry_limit,
    candidate_io,
    candidate_escape,
    invalid_utf8,
    invalid_frontmatter,
    name_mismatch,
    name_invalid,
    description_empty,
    description_too_long,
    body_empty,
    file_too_large,
    summary_budget,
    body_budget,
    project_override,

    pub fn name(self: DiagCode) []const u8 {
        return @tagName(self);
    }
};

pub const SkillEntry = struct {
    name: []const u8,
    description: []const u8,
    disable_model_invocation: bool,
    body: []const u8,
    origin: SkillOrigin,
};

pub const Catalog = struct {
    entries: []const SkillEntry = &.{},
    /// Model-invocable name+description block (empty when none).
    summary: []const u8 = "",
    diags: []const DiagCode = &.{},

    pub fn find(self: Catalog, name: []const u8) ?*const SkillEntry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn invocableCount(self: Catalog) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (!e.disable_model_invocation) n += 1;
        }
        return n;
    }

    pub fn hasInvocable(self: Catalog) bool {
        return self.invocableCount() > 0;
    }
};

pub const DiscoverOptions = struct {
    skills_enabled: bool = true,
    project_skills_trust: ProjectSkillsTrust = .untrusted,
    /// Host-owned user skills root (`…/.agents/skills`). Never getenv in SDK path.
    user_skills_root: ?[]const u8 = null,
    /// Workspace cwd used for project root and project containment.
    workspace_cwd: Io.Dir,
};

// ── Discovery ───────────────────────────────────────────────────────────────

/// Discover skills into `arena`-owned catalog. Soft-skips invalid candidates;
/// OOM is hard-fail (`error.OutOfMemory`).
pub fn discover(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    opts: DiscoverOptions,
) error{OutOfMemory}!Catalog {
    if (!opts.skills_enabled) {
        return .{};
    }

    var diags: std.ArrayListUnmanaged(DiagCode) = .empty;
    defer diags.deinit(gpa);

    // Scratch list of accepted entries (gpa-owned pointers into arena strings).
    var accepted: std.ArrayListUnmanaged(SkillEntry) = .empty;
    defer accepted.deinit(gpa);

    var body_total: usize = 0;
    // Tracks only per-entry invocable summary costs (excludes fixed header/footer).
    // Budget checks add summary_fixed_overhead so the rendered summary never exceeds
    // max_summary_bytes (skills.md §3.3 / §4.3 whole-candidate exclusion).
    var summary_entry_total: usize = 0;

    // Resolve workspace realpath once for project containment.
    // OOM is hard-fail (skills.md §3.3–3.4 / §4.1); other resolve errors soft-null
    // so project containment falls through to root_escape when trust is on.
    const workspace_real: ?[]u8 = workspace.resolveCwdReal(gpa, io, opts.workspace_cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (workspace_real) |w| gpa.free(w);

    // 1) User root
    if (opts.user_skills_root) |user_root| {
        try discoverRoot(
            gpa,
            io,
            arena,
            user_root,
            .user,
            null, // no extra workspace containment for user root
            &accepted,
            &diags,
            &body_total,
            &summary_entry_total,
        );
    }

    // 2) Project root (only when trusted)
    if (opts.project_skills_trust == .trusted) {
        // Project skills live at <cwd>/.agents/skills
        const project_root_rel = ".agents/skills";
        // Resolve absolute real path for containment + open.
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
                &body_total,
                &summary_entry_total,
            );
        } else |_| {
            // Missing or unreadable project root is soft-skip.
            try diags.append(gpa, .root_missing);
        }
    }

    // Finalize arena-owned entry slice + summary.
    const entries_out = if (accepted.items.len == 0)
        @as([]const SkillEntry, &.{})
    else blk: {
        const out = try arena.alloc(SkillEntry, accepted.items.len);
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

    const summary = try buildSummary(arena, entries_out);

    return .{
        .entries = entries_out,
        .summary = summary,
        .diags = diags_out,
    };
}

fn discoverRoot(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    root_path: []const u8,
    origin: SkillOrigin,
    workspace_real: ?[]const u8,
    accepted: *std.ArrayListUnmanaged(SkillEntry),
    diags: *std.ArrayListUnmanaged(DiagCode),
    body_total: *usize,
    summary_entry_total: *usize,
) error{OutOfMemory}!void {
    // Resolve root realpath.
    var root_real_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_real_n = realPathAny(io, root_path, &root_real_buf) catch {
        try diags.append(gpa, .root_missing);
        return;
    };
    const root_real = root_real_buf[0..root_real_n];

    // Project root must also remain inside workspace.
    if (origin == .project) {
        if (workspace_real) |ws| {
            if (!workspace.pathIsWithinRoot(ws, root_real)) {
                try diags.append(gpa, .root_escape);
                return;
            }
        } else {
            // Cannot prove workspace containment → soft-skip project root.
            try diags.append(gpa, .root_escape);
            return;
        }
    }

    var dir = openRootDir(io, root_path) catch {
        try diags.append(gpa, .root_missing);
        return;
    };
    defer dir.close(io);

    // Collect *all* direct child directory names, then byte-sort and cap at 64.
    // Non-directory files must not count toward the cap or starve skill dirs
    // (skills.md §3.1: list dirs → sort → cap; readdir-order independent).
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch {
            try diags.append(gpa, .candidate_io);
            break;
        } orelse break;
        // Direct child directories only (skills.md §3.1). Symlinks count only
        // when the follow-once target is a directory — non-directory symlink
        // noise must not starve legitimate skill dirs under the 64 cap.
        if (!isDirectChildDirectory(dir, io, entry.name, entry.kind)) continue;
        // Direct children only — store name for later SKILL.md check.
        const owned = gpa.dupe(u8, entry.name) catch return error.OutOfMemory;
        names.append(gpa, owned) catch {
            gpa.free(owned);
            return error.OutOfMemory;
        };
    }

    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    // Process first 64 in sorted order; extra directory entries soft-skip.
    if (names.items.len > max_entries_per_root) {
        try diags.append(gpa, .entry_limit);
    }
    const limit = @min(names.items.len, max_entries_per_root);

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const child_name = names.items[i];
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
            body_total,
            summary_entry_total,
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
    origin: SkillOrigin,
    workspace_real: ?[]const u8,
    accepted: *std.ArrayListUnmanaged(SkillEntry),
    diags: *std.ArrayListUnmanaged(DiagCode),
    body_total: *usize,
    summary_entry_total: *usize,
) error{OutOfMemory}!void {
    // Build candidate path: root/child/SKILL.md
    const skill_rel = try std.fmt.allocPrint(gpa, "{s}{c}SKILL.md", .{ child_name, std.fs.path.sep });
    defer gpa.free(skill_rel);
    const skill_path = try joinPath(gpa, root_path, skill_rel);
    defer gpa.free(skill_path);

    // Containment: realpath of candidate under root authority.
    var cand_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cand_n = realPathAny(io, skill_path, &cand_buf) catch {
        // Try directory-level containment for escape detection when file missing.
        const child_path = try joinPath(gpa, root_path, child_name);
        defer gpa.free(child_path);
        var child_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        if (realPathAny(io, child_path, &child_buf)) |cn| {
            const child_real = child_buf[0..cn];
            if (!workspace.pathIsWithinRoot(root_real, child_real)) {
                try diags.append(gpa, .candidate_escape);
                return;
            }
            if (origin == .project) {
                if (workspace_real) |ws| {
                    if (!workspace.pathIsWithinRoot(ws, child_real)) {
                        try diags.append(gpa, .candidate_escape);
                        return;
                    }
                }
            }
        } else |_| {}
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

    // Read file with hard size limit.
    const raw = readFileLimited(gpa, io, skill_path, max_file_bytes) catch |err| switch (err) {
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

    const parsed = parseSkillMd(raw, child_name) catch |err| {
        try diags.append(gpa, mapParseDiag(err));
        return;
    };

    // Project overrides user by exact name: find superseded entry *before* budgets
    // so a net-fitting project skill can replace the user skill (skills.md §3.1).
    var replace_idx: ?usize = null;
    if (origin == .project) {
        for (accepted.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, parsed.name)) {
                replace_idx = i;
                break;
            }
        }
    } else {
        // User root: skip if name already present (should not happen within one root).
        for (accepted.items) |e| {
            if (std.mem.eql(u8, e.name, parsed.name)) {
                try diags.append(gpa, .invalid_frontmatter);
                return;
            }
        }
    }

    // Net aggregates after dropping the same-name user entry (if any).
    var body_base = body_total.*;
    var summary_base = summary_entry_total.*;
    if (replace_idx) |i| {
        const old = accepted.items[i];
        body_base -|= old.body.len;
        if (!old.disable_model_invocation) {
            summary_base -|= summaryEntryCost(old.name, old.description);
        }
    }

    // Body aggregate budget: exclude later candidates (net of same-name supersede).
    if (body_base +| parsed.body.len > max_body_aggregate) {
        try diags.append(gpa, .body_budget);
        return;
    }

    // Summary budget for model-invocable entries includes fixed header/footer so
    // discovery never accepts a set that renders > max_summary_bytes.
    const new_entry_summary: usize = if (!parsed.disable_model_invocation)
        summaryEntryCost(parsed.name, parsed.description)
    else
        0;
    if (new_entry_summary > 0 or summary_base > 0) {
        // When any invocable remains after this accept, rendered size includes overhead.
        const next_entry_total = summary_base +| new_entry_summary;
        if (next_entry_total > 0) {
            if (summary_fixed_overhead +| next_entry_total > max_summary_bytes) {
                try diags.append(gpa, .summary_budget);
                return;
            }
        }
    }

    // Commit: replace or append.
    if (replace_idx) |i| {
        const old = accepted.items[i];
        body_total.* -|= old.body.len;
        if (!old.disable_model_invocation) {
            summary_entry_total.* -|= summaryEntryCost(old.name, old.description);
        }
        try diags.append(gpa, .project_override);
        const name_a = try arena.dupe(u8, parsed.name);
        const desc_a = try arena.dupe(u8, parsed.description);
        const body_a = try arena.dupe(u8, parsed.body);
        accepted.items[i] = .{
            .name = name_a,
            .description = desc_a,
            .disable_model_invocation = parsed.disable_model_invocation,
            .body = body_a,
            .origin = .project,
        };
        body_total.* += body_a.len;
        if (!parsed.disable_model_invocation) {
            summary_entry_total.* += new_entry_summary;
        }
        return;
    }

    const name_a = try arena.dupe(u8, parsed.name);
    const desc_a = try arena.dupe(u8, parsed.description);
    const body_a = try arena.dupe(u8, parsed.body);
    try accepted.append(gpa, .{
        .name = name_a,
        .description = desc_a,
        .disable_model_invocation = parsed.disable_model_invocation,
        .body = body_a,
        .origin = origin,
    });
    body_total.* += body_a.len;
    if (!parsed.disable_model_invocation) {
        summary_entry_total.* += new_entry_summary;
    }
}

/// Fixed header + footer bytes always present when ≥1 invocable skill is rendered.
pub const summary_header = "# Skills\n";
pub const summary_footer = "Use read_skill with {\"name\":\"<name>\"} to load a skill body when needed.\n";
pub const summary_fixed_overhead: usize = summary_header.len + summary_footer.len;

fn summaryEntryCost(name: []const u8, description: []const u8) usize {
    // Exact per-entry line cost matching buildSummary format:
    // "- name: " (8) + name + "\n" (1) + "  description: " (15) + description + "\n" (1)
    return 8 + name.len + 1 + 15 + description.len + 1;
}

fn buildSummary(arena: std.mem.Allocator, entries: []const SkillEntry) error{OutOfMemory}![]const u8 {
    var invocable: usize = 0;
    for (entries) |e| {
        if (!e.disable_model_invocation) invocable += 1;
    }
    if (invocable == 0) return "";

    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(arena);

    try list.appendSlice(arena, summary_header);
    for (entries) |e| {
        if (e.disable_model_invocation) continue;
        try list.print(arena,
            \\- name: {s}
            \\  description: {s}
            \\
        , .{ e.name, e.description });
    }
    try list.appendSlice(arena, summary_footer);

    // Discovery whole-candidate exclusion guarantees ≤ max_summary_bytes.
    // Never mid-buffer clamp (UTF-8 unsafe); assert contract in tests.
    std.debug.assert(list.items.len <= max_summary_bytes);
    return try list.toOwnedSlice(arena);
}

// ── Frontmatter parse (line-oriented subset) ────────────────────────────────

const ParseError = error{
    invalid_frontmatter,
    invalid_utf8,
    name_mismatch,
    name_invalid,
    description_empty,
    description_too_long,
    body_empty,
};

const ParsedSkill = struct {
    name: []const u8,
    description: []const u8,
    disable_model_invocation: bool,
    body: []const u8,
};

fn mapParseDiag(err: ParseError) DiagCode {
    return switch (err) {
        error.invalid_frontmatter => .invalid_frontmatter,
        error.invalid_utf8 => .invalid_utf8,
        error.name_mismatch => .name_mismatch,
        error.name_invalid => .name_invalid,
        error.description_empty => .description_empty,
        error.description_too_long => .description_too_long,
        error.body_empty => .body_empty,
    };
}

/// Parse SKILL.md bytes. `dir_name` is the parent directory name (must match name).
pub fn parseSkillMd(raw: []const u8, dir_name: []const u8) ParseError!ParsedSkill {
    if (!std.unicode.utf8ValidateSlice(raw)) return error.invalid_utf8;
    if (!std.mem.startsWith(u8, raw, "---\n") and !std.mem.startsWith(u8, raw, "---\r\n")) {
        return error.invalid_frontmatter;
    }
    const after_open: usize = if (std.mem.startsWith(u8, raw, "---\r\n")) 5 else 4;
    const rest = raw[after_open..];

    // Find closing ---
    var body_start: ?usize = null;
    var line_start: usize = 0;
    var fm_end: usize = 0;
    while (line_start <= rest.len) {
        const nl = std.mem.indexOfScalarPos(u8, rest, line_start, '\n') orelse rest.len;
        var line = rest[line_start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.eql(u8, line, "---")) {
            fm_end = line_start;
            body_start = if (nl < rest.len) nl + 1 else rest.len;
            break;
        }
        if (nl == rest.len) break;
        line_start = nl + 1;
    }
    const bs = body_start orelse return error.invalid_frontmatter;
    const fm = rest[0..fm_end];
    const body = rest[bs..];

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var disable: ?bool = null;

    var pos: usize = 0;
    while (pos < fm.len) {
        const nl = std.mem.indexOfScalarPos(u8, fm, pos, '\n') orelse fm.len;
        var line = fm[pos..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        pos = if (nl < fm.len) nl + 1 else fm.len;
        if (line.len == 0) continue;
        // Comments: lines starting with # ignored as unknown structure? Contract:
        // unknown well-formed keys ignored; comments may soft-fail if not key:value.
        if (line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.invalid_frontmatter;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        // Reject nested maps/lists/multiline markers.
        if (key.len == 0) return error.invalid_frontmatter;
        if (std.mem.indexOfScalar(u8, key, ' ') != null) return error.invalid_frontmatter;
        if (std.mem.startsWith(u8, value, "|") or std.mem.startsWith(u8, value, ">") or
            std.mem.startsWith(u8, value, "[") or std.mem.startsWith(u8, value, "{") or
            std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">"))
        {
            return error.invalid_frontmatter;
        }
        // Strip optional surrounding quotes.
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        if (std.mem.eql(u8, key, "name")) {
            if (name != null) return error.invalid_frontmatter;
            name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            if (description != null) return error.invalid_frontmatter;
            description = value;
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            if (disable != null) return error.invalid_frontmatter;
            if (std.mem.eql(u8, value, "true")) {
                disable = true;
            } else if (std.mem.eql(u8, value, "false")) {
                disable = false;
            } else {
                return error.invalid_frontmatter;
            }
        } else {
            // Unknown well-formed key: ignore.
        }
    }

    const n = name orelse return error.invalid_frontmatter;
    const d = description orelse return error.invalid_frontmatter;
    if (d.len == 0) return error.description_empty;
    if (d.len > max_description_len) return error.description_too_long;
    if (!isValidSkillName(n)) return error.name_invalid;
    if (!std.mem.eql(u8, n, dir_name)) return error.name_mismatch;

    // Body must be non-empty (at least one non-whitespace byte).
    const body_trim = std.mem.trim(u8, body, " \t\r\n");
    if (body_trim.len == 0) return error.body_empty;

    return .{
        .name = n,
        .description = d,
        .disable_model_invocation = disable orelse false,
        .body = body, // keep original body bytes (including leading newline shape)
    };
}

pub fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    // [a-z0-9]+(-[a-z0-9]+)*
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
    return !expect_alnum; // must not end with '-'
}

// ── Manual activation ───────────────────────────────────────────────────────

pub const SkillActivation = struct {
    /// Expanded ordinary user message text (skill body + optional rest).
    user_text: []const u8,
    /// Skill name that was activated.
    name: []const u8,
};

pub const SkillActivationError = error{
    UnknownSkill,
    OutOfMemory,
};

/// Parse exact `/skill:<name>` with optional rest. Unrelated slash text → null.
pub fn parseSkillCommand(input: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const prefix = "/skill:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const after = trimmed[prefix.len..];
    if (after.len == 0) return null;
    // Name is until first whitespace.
    var name_end: usize = 0;
    while (name_end < after.len) : (name_end += 1) {
        const c = after[name_end];
        if (c == ' ' or c == '\t') break;
    }
    if (name_end == 0) return null;
    const name = after[0..name_end];
    if (!isValidSkillName(name)) return null;
    const rest_raw = after[name_end..];
    const rest = std.mem.trim(u8, rest_raw, " \t");
    return .{ .name = name, .rest = rest };
}

/// Expand catalog skill into one ordinary user message. Manual-only allowed.
/// `user_text` is owned by `gpa` (caller frees). `name` is borrowed from catalog.
pub fn expandSkillActivation(
    gpa: std.mem.Allocator,
    catalog: Catalog,
    name: []const u8,
    rest: []const u8,
) SkillActivationError!SkillActivation {
    const entry = catalog.find(name) orelse return error.UnknownSkill;
    const user_text = if (rest.len == 0)
        try gpa.dupe(u8, entry.body)
    else
        try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ entry.body, rest });
    return .{
        .user_text = user_text,
        .name = entry.name,
    };
}

// ── read_skill Tool ─────────────────────────────────────────────────────────

pub const read_skill_name = "read_skill";

pub const read_skill_def: tool.Definition = .{
    .name = read_skill_name,
    .description =
    \\Load a discovered skill body by name from the session skill catalog.
    \\Use when you need the full instructions for a listed skill.
    ,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "name": {
    \\      "type": "string",
    \\      "description": "Exact skill name from the Skills list."
    \\    }
    \\  },
    \\  "required": ["name"],
    \\  "additionalProperties": false
    \\}
    ,
};

pub const read_skill_descriptor: tool.ToolDescriptor = .{
    .definition = read_skill_def,
    .capabilities = .{
        .risk = .read,
        .workspace = .none,
        .shell = .none,
        .cancellation = .none,
    },
};

/// Build `read_skill` with `instance` = `*const Catalog` (must outlive reply).
pub fn readSkillTool(catalog: *const Catalog) tool.Tool {
    return .{
        .descriptor = read_skill_descriptor,
        .instance = @constCast(catalog),
        .handler = readSkillHandler,
    };
}

fn readSkillHandler(
    ctx: tool.Context,
    instance: ?*anyopaque,
    arguments_json: []const u8,
) tool.HandlerError![]u8 {
    const catalog: *const Catalog = @ptrCast(@alignCast(instance.?));
    const name = tool_args.requireStringArgument(ctx.allocator, arguments_json, "name") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => {
            return tool_error.format(ctx.allocator, .invalid_arguments, "read_skill requires string name") catch
                return error.OutOfMemory;
        },
    };
    defer ctx.allocator.free(name);

    const entry = catalog.find(name) orelse {
        return std.fmt.allocPrint(
            ctx.allocator,
            "error: code=skill_not_found message=unknown skill",
            .{},
        ) catch return error.OutOfMemory;
    };
    if (entry.disable_model_invocation) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "error: code=skill_manual_only message=skill requires manual activation",
            .{},
        ) catch return error.OutOfMemory;
    }
    return ctx.allocator.dupe(u8, entry.body) catch return error.OutOfMemory;
}

/// Append `read_skill` to a base toolset when invocable skills exist.
/// Returns a gpa-owned tool slice (caller frees) or null to use base unchanged.
/// Duplicate reserved name in base → `error.InvalidToolset` (fail-closed).
pub fn composeToolsetWithReadSkill(
    gpa: std.mem.Allocator,
    base: []const tool.Tool,
    catalog: *const Catalog,
) error{ OutOfMemory, InvalidToolset }!?[]tool.Tool {
    if (!catalog.hasInvocable()) return null;

    for (base) |t| {
        if (std.mem.eql(u8, t.descriptor.definition.name, read_skill_name)) {
            return error.InvalidToolset;
        }
    }

    const out = try gpa.alloc(tool.Tool, base.len + 1);
    errdefer gpa.free(out);
    @memcpy(out[0..base.len], base);
    out[base.len] = readSkillTool(catalog);
    // validateTools is also run by loop.run; pre-check here for early fail.
    tool.validateTools(gpa, out) catch return error.InvalidToolset;
    return out;
}

// ── Deep copy for fork ──────────────────────────────────────────────────────

/// Deep-copy catalog entries/summary/diags into `arena`. Parent immutability.
pub fn deepCopyCatalog(arena: std.mem.Allocator, src: Catalog) error{OutOfMemory}!Catalog {
    const entries = if (src.entries.len == 0) @as([]const SkillEntry, &.{}) else blk: {
        const out = try arena.alloc(SkillEntry, src.entries.len);
        for (src.entries, 0..) |e, i| {
            out[i] = .{
                .name = try arena.dupe(u8, e.name),
                .description = try arena.dupe(u8, e.description),
                .disable_model_invocation = e.disable_model_invocation,
                .body = try arena.dupe(u8, e.body),
                .origin = e.origin,
            };
        }
        break :blk out;
    };
    const summary = if (src.summary.len == 0) "" else try arena.dupe(u8, src.summary);
    const diags = if (src.diags.len == 0) @as([]const DiagCode, &.{}) else blk: {
        const out = try arena.alloc(DiagCode, src.diags.len);
        @memcpy(out, src.diags);
        break :blk out;
    };
    return .{
        .entries = entries,
        .summary = summary,
        .diags = diags,
    };
}

// ── FS helpers ──────────────────────────────────────────────────────────────

/// True when a readdir child is a directory for the §3.1 cap.
/// `.directory` is accepted; `.sym_link` only after proving the follow-once
/// target is a directory (broken/non-dir links do not count toward the 64 cap).
fn isDirectChildDirectory(dir: Io.Dir, io: Io, name: []const u8, kind: Io.File.Kind) bool {
    return switch (kind) {
        .directory => true,
        .sym_link => blk: {
            const st = dir.statFile(io, name, .{ .follow_symlinks = true }) catch break :blk false;
            break :blk st.kind == .directory;
        },
        else => false,
    };
}

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
    // readFileAlloc with .limited fails on oversize; map errors.
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Zig 0.16 may use StreamTooLong / FileTooBig depending on backend.
            else => {
                // Distinguish size vs other by probing file size when possible.
                if (isTooLargeError(err)) return error.FileTooLarge;
                return error.IoFailed;
            },
        };
    }
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (isTooLargeError(err)) return error.FileTooLarge;
            return error.IoFailed;
        },
    };
}

fn isTooLargeError(err: anyerror) bool {
    return err == error.StreamTooLong or err == error.FileTooBig or
        std.mem.eql(u8, @errorName(err), "FileTooLarge") or
        std.mem.eql(u8, @errorName(err), "StreamTooLong");
}

// ── Unit tests (parse / activation / name) ──────────────────────────────────

test "isValidSkillName lower-kebab bounds" {
    try std.testing.expect(isValidSkillName("ab"));
    try std.testing.expect(isValidSkillName("a"));
    try std.testing.expect(isValidSkillName("foo-bar-1"));
    try std.testing.expect(!isValidSkillName(""));
    try std.testing.expect(!isValidSkillName("Foo"));
    try std.testing.expect(!isValidSkillName("-foo"));
    try std.testing.expect(!isValidSkillName("foo-"));
    try std.testing.expect(!isValidSkillName("foo_bar"));
    try std.testing.expect(!isValidSkillName("foo bar"));
    var long: [65]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(!isValidSkillName(&long));
}

test "parseSkillMd happy path and manual-only" {
    const raw =
        \\---
        \\name: demo
        \\description: A demo skill
        \\disable-model-invocation: true
        \\---
        \\
        \\# Body
        \\Do the thing.
        \\
    ;
    const p = try parseSkillMd(raw, "demo");
    try std.testing.expectEqualStrings("demo", p.name);
    try std.testing.expectEqualStrings("A demo skill", p.description);
    try std.testing.expect(p.disable_model_invocation);
    try std.testing.expect(std.mem.indexOf(u8, p.body, "Do the thing.") != null);
}

test "parseSkillMd rejects name mismatch and empty body" {
    const bad_name =
        \\---
        \\name: other
        \\description: x
        \\---
        \\body
        \\
    ;
    try std.testing.expectError(error.name_mismatch, parseSkillMd(bad_name, "demo"));

    const empty_body = "---\nname: demo\ndescription: x\n---\n   \n"; // whitespace-only → body_empty
    try std.testing.expectError(error.body_empty, parseSkillMd(empty_body, "demo"));
}

test "parseSkillCommand exact form only" {
    const a = parseSkillCommand("/skill:foo").?;
    try std.testing.expectEqualStrings("foo", a.name);
    try std.testing.expectEqualStrings("", a.rest);

    const b = parseSkillCommand("  /skill:foo bar baz  ").?;
    try std.testing.expectEqualStrings("foo", b.name);
    try std.testing.expectEqualStrings("bar baz", b.rest);

    try std.testing.expect(parseSkillCommand("/skill") == null);
    try std.testing.expect(parseSkillCommand("/skill:") == null);
    try std.testing.expect(parseSkillCommand("/help") == null);
    try std.testing.expect(parseSkillCommand("skill:foo") == null);
    try std.testing.expect(parseSkillCommand("/skill:Foo") == null); // invalid name
}

test "expandSkillActivation manual-only and rest" {
    const gpa = std.testing.allocator;
    const catalog = Catalog{
        .entries = &[_]SkillEntry{.{
            .name = "demo",
            .description = "d",
            .disable_model_invocation = true,
            .body = "BODY",
            .origin = .user,
        }},
    };
    const act = try expandSkillActivation(gpa, catalog, "demo", "rest text");
    defer gpa.free(act.user_text);
    try std.testing.expectEqualStrings("BODY\n\nrest text", act.user_text);
    try std.testing.expectError(error.UnknownSkill, expandSkillActivation(gpa, catalog, "nope", ""));
}
