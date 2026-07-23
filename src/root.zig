//! Zag library root — coding agent harness.
//!
//! AI/LLM client lives in monorepo package `zag-ai` (`@import("zag-ai")`).

const std = @import("std");
const ai = @import("zag-ai");

pub const message = @import("agent/message.zig");
pub const tool = @import("agent/tool.zig");
pub const transcript = @import("agent/transcript.zig");
pub const provider = @import("agent/provider.zig");
pub const observer = @import("agent/observer.zig");
pub const toolset = @import("agent/toolset.zig");
pub const permissions = @import("agent/permissions.zig");
pub const context = @import("agent/context.zig");
pub const project = @import("agent/project.zig");
pub const session_store = @import("agent/session_store.zig");
pub const workspace = @import("agent/workspace.zig");
pub const shell_policy = @import("agent/shell_policy.zig");
pub const trace = @import("agent/trace.zig");
pub const loop = @import("agent/loop.zig");
pub const agent = @import("agent/agent.zig");

pub const fs_tools = @import("runtime/fs_tools.zig");
pub const edit_tools = @import("runtime/edit_tools.zig");

// Re-export AI package surface for convenience
pub const zag_ai = ai;
pub const openai_compat = ai.openai_compat;
pub const provider_registry = ai.registry;
pub const provider_presets = ai.presets;
pub const provider_auth_env = ai.auth_env;
pub const provider_catalog = ai.catalog;
pub const provider_config_file = ai.config_file;

/// Back-compat alias used by older code / docs.
pub const openai = struct {
    pub const Client = ai.Client;
    pub const Config = ai.Config;
    pub const Error = ai.openai_compat.Error;
};

pub const provider_config = struct {
    pub const Error = ai.registry.Error;
    pub const Resolved = struct {
        config: ai.Config,
        preset: struct {
            id: []const u8,
            pub fn name(self: @This()) []const u8 {
                return self.id;
            }
        },
        api_key_source: []const u8 = "",
        display_name: []const u8 = "",
    };

    pub fn resolve(env: *const std.process.Environ.Map) Error!Resolved {
        const r = try ai.registry.resolveFromEnv(env);
        return .{
            .config = r.config,
            .preset = .{ .id = r.spec_id },
            .api_key_source = r.api_key_source,
            .display_name = r.display_name,
        };
    }
};

pub const version = "0.4.0";

test {
    std.testing.refAllDecls(@This());
}
