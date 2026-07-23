//! Agent facade — wires provider, tools, permissions, and loop.
//!
//! ```
//! var agent = Agent.init(gpa, io, provider, .{ .permission_mode = .ask, ... });
//! var session = try Session.start(gpa, system_prompt);
//! defer session.deinit();
//! const result = try agent.reply(&session, user_text);
//! ```

const std = @import("std");
const Io = std.Io;
const message = @import("message.zig");
const tool = @import("tool.zig");
const transcript_mod = @import("transcript.zig");
const provider_mod = @import("provider.zig");
const observer_mod = @import("observer.zig");
const toolset_mod = @import("toolset.zig");
const permissions = @import("permissions.zig");
const loop = @import("loop.zig");

pub const Options = struct {
    max_turns: u32 = loop.default_max_turns,
    verbose: bool = false,
    /// ask (default) or yolo.
    permission_mode: permissions.Mode = .ask,
    /// Optional custom gate; when null, built from `permission_mode` + prompter.
    permission_gate: ?permissions.Gate = null,
};

/// One conversation. Owns the transcript arena (heap-stable so Session is movable).
pub const Session = struct {
    gpa: std.mem.Allocator,
    arena_impl: *std.heap.ArenaAllocator,
    transcript: transcript_mod.Transcript,

    pub fn start(gpa: std.mem.Allocator, system_prompt: []const u8) loop.RunError!Session {
        const arena_impl = gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_impl.* = .init(gpa);
        errdefer {
            arena_impl.deinit();
            gpa.destroy(arena_impl);
        }

        var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
        try transcript.appendSystem(system_prompt);

        return .{
            .gpa = gpa,
            .arena_impl = arena_impl,
            .transcript = transcript,
        };
    }

    pub fn deinit(self: *Session) void {
        self.arena_impl.deinit();
        self.gpa.destroy(self.arena_impl);
        self.* = undefined;
    }
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: provider_mod.Provider,
    tools_storage: toolset_mod.Phase1Storage,
    options: Options,
    /// Owned when mode is ask and no custom gate; must outlive Agent methods.
    stdin_prompter: permissions.StdinPrompter,
    permission_gate: permissions.Gate,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) Agent {
        var self: Agent = .{
            .gpa = gpa,
            .io = io,
            .provider = provider,
            .tools_storage = .init(),
            .options = options,
            .stdin_prompter = .{ .io = io },
            .permission_gate = .yolo(),
        };
        self.permission_gate = self.resolveGate();
        return self;
    }

    /// Back-compat alias used by older call sites / docs.
    pub fn initPhase0(
        gpa: std.mem.Allocator,
        io: Io,
        provider: provider_mod.Provider,
        options: Options,
    ) Agent {
        return init(gpa, io, provider, options);
    }

    fn resolveGate(self: *Agent) permissions.Gate {
        if (self.options.permission_gate) |g| return g;
        return switch (self.options.permission_mode) {
            .yolo => permissions.Gate.yolo(),
            .ask => self.stdin_prompter.gate(),
        };
    }

    fn deps(self: *Agent) loop.Deps {
        // Re-resolve so stdin_prompter pointer stays valid if Agent was moved.
        const gate = self.resolveGate();
        return .{
            .gpa = self.gpa,
            .provider = self.provider,
            .toolset = self.tools_storage.toolset(),
            .tool_ctx = .{
                .allocator = self.gpa,
                .io = self.io,
                .cwd = Io.Dir.cwd(),
            },
            .options = .{
                .max_turns = self.options.max_turns,
                .observer = if (self.options.verbose)
                    observer_mod.Observer.stderrLog()
                else
                    observer_mod.Observer.none(),
                .permission_gate = gate,
            },
        };
    }

    /// Append a user message and run until the model finishes (no more tool calls).
    pub fn reply(self: *Agent, session: *Session, user_text: []const u8) loop.RunError!loop.Result {
        try session.transcript.appendUser(user_text);
        return loop.run(self.deps(), &session.transcript);
    }

    /// One-shot helper: new session → one user message → owned final text.
    pub fn complete(
        self: *Agent,
        system_prompt: []const u8,
        user_prompt: []const u8,
    ) loop.RunError!OwnedResult {
        var session = try Session.start(self.gpa, system_prompt);
        defer session.deinit();

        const result = try self.reply(&session, user_prompt);
        const owned = self.gpa.dupe(u8, result.final_text) catch return error.OutOfMemory;
        return .{ .final_text = owned, .turns = result.turns };
    }
};

pub const OwnedResult = struct {
    final_text: []u8,
    turns: u32,

    pub fn deinit(self: OwnedResult, gpa: std.mem.Allocator) void {
        gpa.free(self.final_text);
    }
};

pub const Result = loop.Result;
pub const RunError = loop.RunError;
pub const Transcript = transcript_mod.Transcript;
pub const Provider = provider_mod.Provider;
pub const Message = message.Message;
pub const Tool = tool.Tool;
pub const Mode = permissions.Mode;
