//! Thin CLI adapter for the ACP v1 server (`zag --acp`). Mirrors
//! `rpc_entry.zig`: Session.start with the resolved host options → server
//! bind → `Server.run` → explicit teardown.
//!
//! Unlike rpc-v1, STARTUP FAILURES EMIT NO STDOUT BYTES (acp.md §10.4 —
//! JSON-RPC has no error channel before the client's first request): every
//! startup failure writes a human diagnostic to stderr and returns the
//! mapped exit code; the editor observes EOF + exit code.

const std = @import("std");
const Io = std.Io;
const coding = @import("zag-coding-agent");
const sigint = @import("sigint.zig");
const acp = @import("acp/server.zig");

pub const RunArgs = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: *acp.Server,
    agent: *coding.Agent,
    guard: *sigint.Guard,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
};

pub const RunResult = struct {
    exit_code: u8,
    /// Guard.deinit already performed — caller must not deinit again.
    guard_deinited: bool = true,
};

/// Full product acp path after Server.init + Agent.init + Guard.install.
/// Explicitly deinitializes Guard and the server-owned Session.
pub fn runAcp(args: RunArgs) RunResult {
    const gpa = args.gpa;
    const io = args.io;

    const session = gpa.create(coding.Session) catch {
        std.log.err("acp: session start failed (out of memory)", .{});
        args.guard.deinit();
        return .{ .exit_code = 40, .guard_deinited = true };
    };
    session.* = coding.Session.start(gpa, io, .{
        .base_system = args.server.host.base_system,
        .path = args.session_path,
        .open_mode = args.open_mode,
        .load_project_instructions = args.load_project,
        .redactor = args.agent.activeRedactor(),
        .skills_enabled = args.server.host.skills_enabled,
        .project_skills_trust = args.server.host.project_skills_trust,
        .user_skills_root = args.server.host.user_skills_root,
        .templates_enabled = args.server.host.templates_enabled,
        .project_templates_trust = args.server.host.project_templates_trust,
        .user_templates_root = args.server.host.user_templates_root,
    }) catch |err| {
        gpa.destroy(session);
        std.log.err("acp: session start failed: {s}", .{@errorName(err)});
        args.guard.deinit();
        return .{ .exit_code = acp.sessionStartExitCode(err), .guard_deinited = true };
    };

    args.server.bind(args.agent, session, args.guard);
    const code = args.server.run();

    // Explicit teardown. The session heap cell is server-owned; tear down
    // the CURRENT session via the server (no resume swap in acp v1, but the
    // server remains the owner).
    if (args.server.session) |sess| {
        sess.deinit();
        gpa.destroy(sess);
    }
    args.guard.deinit();
    return .{ .exit_code = code, .guard_deinited = true };
}

test "acp_entry surface compiles" {
    try std.testing.expect(@TypeOf(runAcp) != void);
    _ = acp.sessionStartExitCode;
    _ = acp.sessionStartMessage;
}
