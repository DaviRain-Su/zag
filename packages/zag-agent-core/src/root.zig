//! zag-agent-core — thin loop kernel (D-011).
//!
//! Generic single-agent loop, transcript, pure Provider port, mandatory Tool
//! descriptor validation, one-time argument/path extraction, required
//! ToolPolicy/Jail/ShellPolicy ports, fixed gate order, and canonical
//! LoopEvent facts. Product policy (permissions/HITL/remember, workspace
//! containment, shell protection), context layers, persistence, redaction,
//! and concrete Tools live in `zag-coding-agent`.
//! No CLI, no default coding toolset, no wire-protocol clients.

const std = @import("std");

pub const message = @import("message.zig");
pub const tool = @import("tool.zig");
pub const tool_args = @import("tool_args.zig");
pub const transcript = @import("transcript.zig");
pub const provider = @import("provider.zig");
pub const protocol_history = @import("protocol_history.zig");
pub const tool_error = @import("tool_error.zig");
pub const cancel = @import("cancel.zig");

// D-011 thin kernel seams (required ports + canonical event sink).
pub const tool_policy = @import("tool_policy.zig");
pub const jail = @import("jail.zig");
pub const shell_policy = @import("shell_policy.zig");
pub const context_view = @import("context_view.zig");
pub const loop_event = @import("loop_event.zig");

pub const loop = @import("loop.zig");

pub const Message = message.Message;
pub const Role = message.Role;
pub const ToolCall = message.ToolCall;
pub const AssistantTurn = message.AssistantTurn;
pub const Provider = provider.Provider;
pub const ChatError = provider.ChatError;
pub const Tool = tool.Tool;
pub const ToolDefinition = tool.Definition;
pub const ToolDescriptor = tool.ToolDescriptor;
pub const ToolCapabilities = tool.ToolCapabilities;
pub const ToolRisk = tool.ToolRisk;
pub const Registration = tool.Registration;
pub const RegistrationError = tool.RegistrationError;

// D-011 seam ports (re-exported for module-name consumers).
pub const ToolPolicy = tool_policy.ToolPolicy;
pub const Jail = jail.Jail;
// Canonical seam port name is `ShellPolicy`; `ShellPolicyPort` is kept as an
// alias for compatibility with already-submitted consumers.
pub const ShellPolicy = shell_policy.ShellPolicy;
pub const ShellPolicyPort = ShellPolicy;
pub const ContextView = context_view.ContextView;
pub const LoopEventSink = loop_event.LoopEventSink;
pub const LoopEvent = loop_event.LoopEvent;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}