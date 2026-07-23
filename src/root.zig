//! Zag library root — coding agent harness building blocks.
//!
//! Phase 0 exports the message protocol, tool registry, loop, provider, and
//! read-only filesystem tools. Prefer importing submodules by path as the
//! package grows.

const std = @import("std");

pub const message = @import("agent/message.zig");
pub const tool = @import("agent/tool.zig");
pub const loop = @import("agent/loop.zig");
pub const openai = @import("provider/openai.zig");
pub const provider_config = @import("provider/config.zig");
pub const fs_tools = @import("runtime/fs_tools.zig");

pub const version = "0.0.1-phase0";

test {
    // Pull in all module tests.
    std.testing.refAllDecls(@This());
    _ = message;
    _ = tool;
    _ = loop;
    _ = openai;
    _ = provider_config;
    _ = fs_tools;
}
