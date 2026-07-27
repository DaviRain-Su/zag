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
pub const skills = @import("skills.zig");
pub const prompt_templates = @import("prompt_templates.zig");
pub const doctor = @import("doctor.zig");
pub const wire_provider = @import("wire_provider.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");
pub const edit_tools = @import("runtime/edit_tools.zig");
pub const golden_tests = @import("golden_tests.zig");

// skills-001: public activation + options surface
pub const ProjectSkillsTrust = skills.ProjectSkillsTrust;
pub const SkillActivation = skills.SkillActivation;
pub const SkillActivationError = skills.SkillActivationError;
pub const parseSkillCommand = skills.parseSkillCommand;

/// Expand a catalog skill into one ordinary user message (manual-only allowed).
/// `user_text` is gpa-owned (caller frees). Does not call the provider.
pub fn expandSkillActivation(
    gpa: std.mem.Allocator,
    session: *const Session,
    name: []const u8,
    rest: []const u8,
) skills.SkillActivationError!skills.SkillActivation {
    return skills.expandSkillActivation(gpa, session.skills_catalog, name, rest);
}

// prompt-templates-001: public parse/expand + options surface
pub const ProjectTemplatesTrust = prompt_templates.ProjectTemplatesTrust;
pub const TemplateExpansion = prompt_templates.TemplateExpansion;
pub const TemplateExpansionError = prompt_templates.TemplateExpansionError;
pub const parseTemplateCommand = prompt_templates.parseTemplateCommand;

/// Expand a catalog template once. `user_text` is gpa-owned (caller frees).
/// Does not call the provider. Does not re-read the filesystem.
pub fn expandTemplate(
    gpa: std.mem.Allocator,
    session: *const Session,
    name: []const u8,
    arguments: []const u8,
) prompt_templates.TemplateExpansionError!prompt_templates.TemplateExpansion {
    return prompt_templates.expandTemplate(gpa, session.templates_catalog, name, arguments);
}

// harness-events-001: public SDK lifecycle observer (product adapter over Core
// source facts + facade run facts). No Core lifecycle.zig.
pub const lifecycle = @import("lifecycle.zig");
pub const LifecycleObserver = lifecycle.LifecycleObserver;
pub const LifecycleEvent = lifecycle.LifecycleEvent;

// harness-steering-001: Session-owned control queues + product ControlKind.
pub const control_queue = @import("control_queue.zig");
pub const ControlError = control_queue.ControlError;
pub const ControlKind = lifecycle.ControlKind;

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
pub const ForkError = agent.ForkError;

// session-fork-001: Gate fixtures (module §8 items 1–29)
test {
    _ = @import("session_fork_tests.zig");
}

// skills-001: Gate fixtures (module §11 items 1–14)
test {
    _ = @import("skills_tests.zig");
}

// prompt-templates-001: Gate fixtures (module §11 items 1–17)
test {
    _ = @import("prompt_templates_tests.zig");
}

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}