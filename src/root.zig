//! Zag umbrella — re-exports monorepo packages for library consumers.
//!
//! ```
//! packages/openai-zig         wire transport + OpenAPI
//! packages/zag-ai             model plane (WireAdapter)
//! packages/zag-agent-core     loop / pure Provider
//! packages/zag-coding-agent   coding tools + Agent facade + wire bridge
//! packages/zag-cli            product shell (args / REPL / one-shot)
//! src/main.zig                thin executable entry → zag-cli.run
//! ```

const std = @import("std");
const ai = @import("zag-ai");
const core = @import("zag-agent-core");
const coding = @import("zag-coding-agent");
const cli = @import("zag-cli");

// --- Agent Core ---
pub const message = core.message;
pub const tool = core.tool;
pub const transcript = core.transcript;
pub const provider = coding.wire_provider; // product: WireProvider + re-export Provider port
pub const provider_port = core.provider; // pure port only
pub const observer = core.observer;
pub const permissions = core.permissions;
pub const context = core.context;
pub const session_store = core.session_store;
pub const shell_policy = core.shell_policy;
pub const workspace = core.workspace;
pub const trace = core.trace;
pub const loop = core.loop;

// --- Coding product ---
pub const agent = coding.agent;
pub const toolset = coding.toolset;
pub const project = coding.project;
pub const fs_tools = coding.fs_tools;
pub const edit_tools = coding.edit_tools;
pub const wire_provider = coding.wire_provider;

// --- Model plane ---
pub const zag_ai = ai;
pub const openai_zig = ai.openai_zig;
pub const openai_compat = ai.openai_compat;
pub const provider_registry = ai.registry;
pub const provider_presets = ai.presets;
pub const provider_auth_env = ai.auth_env;
pub const provider_catalog = ai.catalog;
pub const provider_config_file = ai.config_file;

/// Back-compat alias.
pub const openai = struct {
    pub const Client = ai.Client;
    pub const Config = ai.Config;
    pub const Error = ai.wire.Error;
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

pub const agent_core = core;
pub const coding_agent = coding;
pub const zag_cli = cli;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}
