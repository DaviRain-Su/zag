//! zag-coding-agent — Pi-coding-agent analogue (product harness).
//!
//! Default coding toolset, Agent/Session facade, AGENTS.md project load,
//! WireAdapter → Provider bridge. Depends on zag-agent-core + zag-ai.
//!
//! Product-owned policy modules (moved from Core by core-policy-ownership-001):
//! `permissions.zig` (HITL Gate/remember/prompt), `shell_policy.zig` (concrete
//! denylist + fromMode adapter), and `workspace.zig` (Guard/Root/realpath/
//! symlink containment). Core retains only the required ports and pure
//! lexical validation.

const std = @import("std");
const core = @import("zag-agent-core");

pub const agent_core = core;

// Re-export core surface for convenience
pub const message = core.message;
pub const tool = core.tool;
pub const tool_args = core.tool_args;
pub const transcript = core.transcript;
pub const provider = core.provider;
pub const context = @import("context.zig");
pub const loop = core.loop;

// D-011 product-owned persistence surface (moved from Core by core-session-ownership-001).
pub const session_store = @import("session_store.zig");

// D-011 product-owned observation surface (moved from Core by core-observation-ownership-001).
pub const redact = @import("redact.zig");
pub const trace = @import("trace.zig");
pub const observer = @import("observer.zig");

// D-011 product-owned policy surface (moved from Core by core-policy-ownership-001).
pub const permissions = @import("permissions.zig");
pub const shell_policy = @import("shell_policy.zig");
pub const workspace = @import("workspace.zig");

// Product layer
pub const agent = @import("agent.zig");
pub const toolset = @import("toolset.zig");
pub const project = @import("project.zig");
pub const doctor = @import("doctor.zig");
pub const wire_provider = @import("wire_provider.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");
pub const edit_tools = @import("runtime/edit_tools.zig");
pub const golden_tests = @import("golden_tests.zig");

// harness-events-001: public SDK lifecycle observer (product adapter over Core
// source facts + facade run facts). No Core lifecycle.zig.
pub const lifecycle = @import("lifecycle.zig");
pub const LifecycleObserver = lifecycle.LifecycleObserver;
pub const LifecycleEvent = lifecycle.LifecycleEvent;

/// WireAdapter → Provider bridge (not in core).
pub const WireProvider = wire_provider.WireProvider;
pub const Adapter = wire_provider.Adapter;

pub const Toolset = tool.Toolset;
pub const Observer = observer.Observer;
pub const ToolRegistry = tool.Registry;
pub const Tool = tool.Tool;

pub const Agent = agent.Agent;
pub const Session = agent.Session;
pub const Options = agent.Options;
pub const OpenMode = agent.OpenMode;
pub const ReplyError = agent.ReplyError;
pub const OwnedResult = agent.OwnedResult;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}