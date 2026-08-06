//! Thin CLI adapter for the rpc-v1 server (`zag --rpc`). Mirrors
//! `tui_entry.zig`: Session.start with the resolved host options → server bind
//! → `Server.run` → explicit teardown (no reliance on defer across
//! `process.exit`). The SESSION is server-owned from bind; Agent + Guard are
//! caller-owned (cli.zig deinits the Agent after this returns).

const std = @import("std");
const Io = std.Io;
const coding = @import("zag-coding-agent");
const sigint = @import("sigint.zig");
const rpc = @import("rpc/server.zig");
const protocol = @import("rpc/protocol.zig");

pub const RunArgs = struct {
    gpa: std.mem.Allocator,
    io: Io,
    server: *rpc.Server,
    agent: *coding.Agent,
    guard: *sigint.Guard,
    session_path: ?[]const u8,
    open_mode: coding.OpenMode,
    load_project: bool,
};

pub const RunResult = struct {
    exit_code: u8,
    /// Guard.deinit already performed — caller must not deinit again.
    guard_deinited: bool = false,
    /// Session NOT deinitialized here on the success path? No — the session
    /// IS server-owned and this entry deinits + destroys it exactly once.
    session_deinited: bool = true,
};

/// Full product rpc path after Server.init + Agent.init + Guard.install.
/// Explicitly deinitializes Guard and the server-owned Session.
pub fn runRpc(args: RunArgs) RunResult {
    const gpa = args.gpa;
    const io = args.io;

    const session = gpa.create(coding.Session) catch {
        std.log.err("rpc: session start failed (out of memory)", .{});
        args.server.emitFatal(.out_of_memory, "out of memory");
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
        const code = rpc.sessionStartExitCode(err);
        const ec = rpc.sessionStartError(err);
        std.log.err("rpc: session start failed: {s}", .{@errorName(err)});
        args.server.emitFatal(ec, rpc.sessionStartMessage(err));
        args.guard.deinit();
        return .{ .exit_code = code, .guard_deinited = true };
    };

    args.server.bind(args.agent, session, args.guard);
    const code = args.server.run();

    // Explicit teardown. The session heap cell is server-owned and may have
    // been REPLACED by a `resume` swap (old cell deinit+destroyed inside),
    // so tear down the CURRENT session via the server, never a stale alias.
    if (args.server.session) |sess| {
        sess.deinit();
        gpa.destroy(sess);
    }
    args.guard.deinit();
    return .{ .exit_code = code, .guard_deinited = true };
}

test "rpc_entry surface compiles" {
    try std.testing.expect(@TypeOf(runRpc) != void);
    _ = protocol.protocol_version;
}
