//! Provider-independent readiness report (h-doctor-001).
//!
//! Typed, path-free control status for the current run selection. Doctor:
//! - does not resolve a provider, touch network, or require an API key;
//! - probes project-instruction / test-entry candidates for **presence only**
//!   (never reads file bodies);
//! - reports fixed enum labels only (no cwd/realpath/argv/env/secrets);
//! - never mutates permission, shell policy, or other controls.
//!
//! CLI `--doctor` is a thin text adapter over this report. Stable JSON/event/
//! exit protocol is owned by headless-001 — not this module.

const std = @import("std");
const Io = std.Io;
const core = @import("zag-agent-core");
const project = @import("project.zig");

/// Project-instruction candidate presence (not a load-success claim).
pub const ProjectInstructionStatus = enum {
    /// Project load enabled and at least one candidate path exists.
    enabled_present,
    /// Project load enabled but no candidate file is present.
    enabled_missing,
    /// Project load explicitly disabled (`--no-project`).
    disabled,

    pub fn name(self: ProjectInstructionStatus) []const u8 {
        return switch (self) {
            .enabled_present => "enabled_present",
            .enabled_missing => "enabled_missing",
            .disabled => "disabled",
        };
    }
};

/// First-match test-entry candidate. Presence is not proof a test command exists.
pub const TestEntry = enum {
    zig_build,
    node_manifest,
    cargo_manifest,
    go_module,
    python_project,
    makefile,
    justfile,
    none,

    pub fn name(self: TestEntry) []const u8 {
        return switch (self) {
            .zig_build => "zig_build",
            .node_manifest => "node_manifest",
            .cargo_manifest => "cargo_manifest",
            .go_module => "go_module",
            .python_project => "python_project",
            .makefile => "makefile",
            .justfile => "justfile",
            .none => "none",
        };
    }
};

/// Real/symlink-aware file containment after workspace-root resolve.
pub const RealContainment = enum {
    /// Root resolved; file-tool Guard is applicable for this cwd.
    ready,
    /// Root could not be resolved — fail closed (never claim ready).
    unavailable_fail_closed,

    pub fn name(self: RealContainment) []const u8 {
        return switch (self) {
            .ready => "ready",
            .unavailable_fail_closed => "unavailable_fail_closed",
        };
    }
};

/// Inputs selected by CLI flags (or host). Doctor reports them; it does not change them.
pub const Options = struct {
    permission: core.permissions.Mode = .ask,
    shell_policy: core.shell_policy.Mode = .protect,
    /// When false (`--no-project`), project instructions report `disabled`.
    load_project_instructions: bool = true,
};

/// Fixed-field readiness report. All labels are path-free enums / constants.
pub const Report = struct {
    project_instructions: ProjectInstructionStatus,
    test_entry: TestEntry,
    permission: core.permissions.Mode,
    shell_policy: core.shell_policy.Mode,
    real_file_containment: RealContainment,
};

/// Fixed order: first existing file wins (task contract).
const test_entry_candidates = [_]struct { file: []const u8, kind: TestEntry }{
    .{ .file = "build.zig", .kind = .zig_build },
    .{ .file = "package.json", .kind = .node_manifest },
    .{ .file = "Cargo.toml", .kind = .cargo_manifest },
    .{ .file = "go.mod", .kind = .go_module },
    .{ .file = "pyproject.toml", .kind = .python_project },
    .{ .file = "Makefile", .kind = .makefile },
    .{ .file = "justfile", .kind = .justfile },
};

/// Presence probe only — never reads the body.
pub fn probeProjectInstructions(
    io: Io,
    cwd: Io.Dir,
    load_project_instructions: bool,
) ProjectInstructionStatus {
    if (!load_project_instructions) return .disabled;
    if (project.anyCandidatePresent(io, cwd)) return .enabled_present;
    return .enabled_missing;
}

/// Presence probe only — fixed precedence; never reads bodies.
pub fn probeTestEntry(io: Io, cwd: Io.Dir) TestEntry {
    for (test_entry_candidates) |c| {
        cwd.access(io, c.file, .{}) catch continue;
        return c.kind;
    }
    return .none;
}

/// Map a workspace Root resolve attempt to a fixed containment status.
/// Success with a non-empty path → `ready`; any failure / empty → fail closed.
pub fn realContainmentFromRootAttempt(attempt: core.workspace.ContainError!core.workspace.Root) RealContainment {
    const root = attempt catch return .unavailable_fail_closed;
    if (root.path.len == 0) return .unavailable_fail_closed;
    return .ready;
}

/// Resolve cwd root once; `ready` only when resolve succeeds.
pub fn probeRealContainment(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
) RealContainment {
    var root = core.workspace.Root.obtain(gpa, io, cwd, null) catch {
        return .unavailable_fail_closed;
    };
    defer root.deinit(gpa);
    return realContainmentFromRootAttempt(root);
}

/// Collect the full typed report for `cwd` and selected options.
pub fn collect(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    opts: Options,
) Report {
    return .{
        .project_instructions = probeProjectInstructions(io, cwd, opts.load_project_instructions),
        .test_entry = probeTestEntry(io, cwd),
        .permission = opts.permission,
        .shell_policy = opts.shell_policy,
        .real_file_containment = probeRealContainment(gpa, io, cwd),
    };
}

/// Human-readable fixed-key text. Path-free; no JSON stability claim.
pub fn formatReport(buf: []u8, report: Report) []const u8 {
    return std.fmt.bufPrint(
        buf,
        \\zag doctor
        \\project_instructions={s}
        \\test_entry={s}
        \\permission={s}
        \\shell_policy={s}
        \\lexical_file_jail=enforced
        \\real_file_containment={s}
        \\secret_redaction=enabled_on_agent_run
        \\provider_key_redaction=deferred_until_provider_resolve
        \\os_sandbox=not_implemented
        \\shell_containment=not_path_contained
        \\
    ,
        .{
            report.project_instructions.name(),
            report.test_entry.name(),
            report.permission.name(),
            report.shell_policy.name(),
            report.real_file_containment.name(),
        },
    ) catch "zag doctor\n";
}

// ── tests ──────────────────────────────────────────────────────────────

test "doctor defaults: ask/protect + present project in tmp with AGENTS.md" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    // Body must never appear in doctor output (presence only).
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = secret ++ "\nproject body\n" });

    const report = collect(gpa, io, tmp.dir, .{});
    try std.testing.expectEqual(ProjectInstructionStatus.enabled_present, report.project_instructions);
    try std.testing.expectEqual(TestEntry.none, report.test_entry);
    try std.testing.expectEqual(core.permissions.Mode.ask, report.permission);
    try std.testing.expectEqual(core.shell_policy.Mode.protect, report.shell_policy);
    try std.testing.expectEqual(RealContainment.ready, report.real_file_containment);

    var buf: [512]u8 = undefined;
    const out = formatReport(&buf, report);
    try std.testing.expect(std.mem.indexOf(u8, out, "permission=ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_policy=protect") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "project_instructions=enabled_present") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "test_entry=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lexical_file_jail=enforced") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real_file_containment=ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret_redaction=enabled_on_agent_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider_key_redaction=deferred_until_provider_resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "os_sandbox=not_implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_containment=not_path_contained") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "project body") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AGENTS.md") == null);
}

test "doctor: missing project + disabled via --no-project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing = collect(gpa, io, tmp.dir, .{});
    try std.testing.expectEqual(ProjectInstructionStatus.enabled_missing, missing.project_instructions);

    const disabled = collect(gpa, io, tmp.dir, .{ .load_project_instructions = false });
    try std.testing.expectEqual(ProjectInstructionStatus.disabled, disabled.project_instructions);

    // Even if a candidate exists, --no-project forces disabled without reading.
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = secret });
    const still_disabled = collect(gpa, io, tmp.dir, .{ .load_project_instructions = false });
    try std.testing.expectEqual(ProjectInstructionStatus.disabled, still_disabled.project_instructions);
    var buf: [512]u8 = undefined;
    const out = formatReport(&buf, still_disabled);
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "project_instructions=disabled") != null);
}

test "doctor test-entry candidate matrix first match wins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cases = [_]struct { file: []const u8, want: TestEntry }{
        .{ .file = "build.zig", .want = .zig_build },
        .{ .file = "package.json", .want = .node_manifest },
        .{ .file = "Cargo.toml", .want = .cargo_manifest },
        .{ .file = "go.mod", .want = .go_module },
        .{ .file = "pyproject.toml", .want = .python_project },
        .{ .file = "Makefile", .want = .makefile },
        .{ .file = "justfile", .want = .justfile },
    };

    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
        try tmp.dir.writeFile(io, .{ .sub_path = c.file, .data = secret ++ "\n" });
        const report = collect(gpa, io, tmp.dir, .{});
        try std.testing.expectEqual(c.want, report.test_entry);
        var buf: [512]u8 = undefined;
        const out = formatReport(&buf, report);
        // Body must never appear; file names that coincide with enum labels
        // (e.g. justfile) may appear only as the fixed enum value.
        try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\\") == null);
        var entry_buf: [64]u8 = undefined;
        const entry_line = try std.fmt.bufPrint(&entry_buf, "test_entry={s}", .{c.want.name()});
        try std.testing.expect(std.mem.indexOf(u8, out, entry_line) != null);
    }

    // Precedence: build.zig wins over later candidates when both present.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "x" });
        try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "y" });
        try tmp.dir.writeFile(io, .{ .sub_path = "justfile", .data = "z" });
        try std.testing.expectEqual(TestEntry.zig_build, probeTestEntry(io, tmp.dir));
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{}" });
        try tmp.dir.writeFile(io, .{ .sub_path = "Makefile", .data = "all:" });
        try std.testing.expectEqual(TestEntry.node_manifest, probeTestEntry(io, tmp.dir));
    }
}

test "doctor explicit yolo/off selections reported without mutation semantics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const report = collect(gpa, io, tmp.dir, .{
        .permission = .yolo,
        .shell_policy = .off,
        .load_project_instructions = false,
    });
    try std.testing.expectEqual(core.permissions.Mode.yolo, report.permission);
    try std.testing.expectEqual(core.shell_policy.Mode.off, report.shell_policy);
    try std.testing.expectEqual(ProjectInstructionStatus.disabled, report.project_instructions);

    var buf: [512]u8 = undefined;
    const out = formatReport(&buf, report);
    try std.testing.expect(std.mem.indexOf(u8, out, "permission=yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_policy=off") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "project_instructions=disabled") != null);
    // Still no OS sandbox claim and shell is not path-contained.
    try std.testing.expect(std.mem.indexOf(u8, out, "os_sandbox=not_implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shell_containment=not_path_contained") != null);
}

test "unresolvable workspace root maps to unavailable_fail_closed" {
    // Fixture: any failed/empty Root resolve is fail-closed, never ready, never a raw path.
    // (Closed-fd Dir is not used — Zig 0.16 debug Io panics on BADF as programmer bug.)
    try std.testing.expectEqual(
        RealContainment.unavailable_fail_closed,
        realContainmentFromRootAttempt(error.ResolveFailed),
    );
    try std.testing.expectEqual(
        RealContainment.unavailable_fail_closed,
        realContainmentFromRootAttempt(error.OutsideWorkspace),
    );
    try std.testing.expectEqual(
        RealContainment.unavailable_fail_closed,
        realContainmentFromRootAttempt(error.OutOfMemory),
    );
    try std.testing.expectEqual(
        RealContainment.unavailable_fail_closed,
        realContainmentFromRootAttempt(.{ .path = "", .owned = false }),
    );
    try std.testing.expectEqual(
        RealContainment.ready,
        realContainmentFromRootAttempt(.{ .path = "/ws", .owned = false }),
    );

    // Ordinary resolvable tmp cwd must be ready (positive control).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(RealContainment.ready, probeRealContainment(gpa, io, tmp.dir));

    var buf: [512]u8 = undefined;
    const out = formatReport(&buf, .{
        .project_instructions = .enabled_missing,
        .test_entry = .none,
        .permission = .ask,
        .shell_policy = .protect,
        .real_file_containment = .unavailable_fail_closed,
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "real_file_containment=unavailable_fail_closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real_file_containment=ready") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/ws") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var/") == null);
}

test "doctor format never echoes secret-shaped path or env-like fixtures" {
    const secret = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    const env_like = "ZAG_API_KEY=" ++ secret;
    const path_like = "/Users/me/.zag/" ++ secret ++ "/ws";
    _ = env_like;
    _ = path_like;
    var buf: [512]u8 = undefined;
    const out = formatReport(&buf, .{
        .project_instructions = .enabled_present,
        .test_entry = .zig_build,
        .permission = .ask,
        .shell_policy = .protect,
        .real_file_containment = .ready,
    });
    try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ZAG_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "argv") == null);
}
