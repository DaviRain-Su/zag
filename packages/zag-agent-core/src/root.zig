//! zag-agent-core — Pi-agent-core analogue.
//!
//! Loop, session, permissions, context, pure Provider port.
//! No CLI, no default coding toolset, no wire-protocol clients.

const std = @import("std");

pub const message = @import("message.zig");
pub const tool = @import("tool.zig");
pub const transcript = @import("transcript.zig");
pub const provider = @import("provider.zig");
pub const observer = @import("observer.zig");
pub const permissions = @import("permissions.zig");
pub const context = @import("context.zig");
pub const session_store = @import("session_store.zig");
pub const shell_policy = @import("shell_policy.zig");
pub const workspace = @import("workspace.zig");
pub const tool_error = @import("tool_error.zig");
pub const cancel = @import("cancel.zig");
pub const trace = @import("trace.zig");
pub const loop = @import("loop.zig");

pub const Message = message.Message;
pub const Role = message.Role;
pub const ToolCall = message.ToolCall;
pub const AssistantTurn = message.AssistantTurn;
pub const Provider = provider.Provider;
pub const ChatError = provider.ChatError;
pub const Tool = tool.Tool;
pub const ToolDefinition = tool.Definition;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}
