//! zag-coding-agent — Pi-coding-agent analogue (product harness).
//!
//! Default coding toolset, Agent/Session facade, AGENTS.md project load,
//! WireAdapter → Provider bridge. Depends on zag-agent-core + zag-ai.

const std = @import("std");
const core = @import("zag-agent-core");

pub const agent_core = core;

// Re-export core surface for convenience
pub const message = core.message;
pub const tool = core.tool;
pub const transcript = core.transcript;
pub const provider = core.provider;
pub const observer = core.observer;
pub const permissions = core.permissions;
pub const context = core.context;
pub const session_store = core.session_store;
pub const shell_policy = core.shell_policy;
pub const workspace = core.workspace;
pub const redact = core.redact;
pub const trace = core.trace;
pub const loop = core.loop;

// Product layer
pub const agent = @import("agent.zig");
pub const toolset = @import("toolset.zig");
pub const project = @import("project.zig");
pub const wire_provider = @import("wire_provider.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");
pub const edit_tools = @import("runtime/edit_tools.zig");
pub const golden_tests = @import("golden_tests.zig");

/// WireAdapter → Provider bridge (not in core).
pub const WireProvider = wire_provider.WireProvider;
pub const Adapter = wire_provider.Adapter;

pub const Agent = agent.Agent;
pub const Session = agent.Session;
pub const Options = agent.Options;
pub const OpenMode = agent.OpenMode;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}
