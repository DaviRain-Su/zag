//! Zag library root — coding agent harness.
//!
//! Prefer `zag.agent` for business logic. Provider/runtime are infrastructure.

const std = @import("std");

pub const message = @import("agent/message.zig");
pub const tool = @import("agent/tool.zig");
pub const transcript = @import("agent/transcript.zig");
pub const provider = @import("agent/provider.zig");
pub const observer = @import("agent/observer.zig");
pub const toolset = @import("agent/toolset.zig");
pub const loop = @import("agent/loop.zig");
pub const agent = @import("agent/agent.zig");

pub const openai = @import("provider/openai.zig");
pub const provider_config = @import("provider/config.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");

pub const version = "0.0.2-phase0";

test {
    std.testing.refAllDecls(@This());
}
