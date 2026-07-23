//! zag-ai — OpenAI-compatible LLM client (monorepo package).
//!
//! Split like Grok Build crates: AI/provider is independent of the agent harness.

const std = @import("std");

pub const types = @import("types.zig");
pub const presets = @import("presets.zig");
pub const auth_env = @import("auth_env.zig");
pub const registry = @import("registry.zig");
pub const openai_compat = @import("openai_compat.zig");
pub const stream = @import("stream.zig");
pub const catalog = @import("catalog.zig");
pub const config_file = @import("config_file.zig");

pub const Message = types.Message;
pub const ToolCall = types.ToolCall;
pub const AssistantTurn = types.AssistantTurn;
pub const ToolDefinition = types.ToolDefinition;
pub const StreamEvent = types.StreamEvent;
pub const Client = openai_compat.Client;
pub const Config = openai_compat.Config;
pub const ProviderSpec = presets.ProviderSpec;
pub const ModelInfo = catalog.ModelInfo;
pub const FileConfig = config_file.FileConfig;

pub const version = "0.1.0";

pub const ResolveResult = struct {
    resolved: registry.Resolved,
    stream: bool = false,
    /// Optional owned model/base_url overrides from config file (free with deinit).
    owned_model: ?[]u8 = null,
    owned_base_url: ?[]u8 = null,

    pub fn deinit(self: *ResolveResult, gpa: std.mem.Allocator) void {
        if (self.owned_model) |m| gpa.free(m);
        if (self.owned_base_url) |b| gpa.free(b);
        self.* = .{ .resolved = self.resolved };
    }
};

/// Resolve endpoint from environment, overlaid with optional JSON config file.
/// Env secrets always win; file may set provider/model/base_url/stream.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    config_path: ?[]const u8,
) !ResolveResult {
    var result: ResolveResult = .{
        .resolved = try registry.resolveFromEnv(env),
        .stream = false,
    };

    const path = config_path orelse env.get("ZAG_CONFIG");
    var file_cfg = try config_file.load(gpa, io, std.Io.Dir.cwd(), path) orelse return result;
    defer file_cfg.deinit(gpa);

    result.stream = file_cfg.stream;

    // Provider from file only if env did not set ZAG_PROVIDER and we can get a key.
    if (file_cfg.provider) |pid| {
        if (env.get("ZAG_PROVIDER") == null) {
            if (presets.find(pid)) |spec| {
                if (auth_env.resolveApiKeySource(EnvMap{ .env = env }, spec.env_keys)) |ks| {
                    result.resolved = .{
                        .spec_id = spec.id,
                        .display_name = spec.name,
                        .api_key_source = ks.source,
                        .config = .{
                            .api_key = ks.key,
                            .base_url = env.get("ZAG_BASE_URL") orelse spec.base_url,
                            .model = env.get("ZAG_MODEL") orelse spec.default_model,
                        },
                    };
                }
            }
        }
    }

    if (env.get("ZAG_MODEL") == null) {
        if (file_cfg.model) |m| {
            result.owned_model = try gpa.dupe(u8, m);
            result.resolved.config.model = result.owned_model.?;
        }
    }
    if (env.get("ZAG_BASE_URL") == null) {
        if (file_cfg.base_url) |b| {
            result.owned_base_url = try gpa.dupe(u8, b);
            result.resolved.config.base_url = result.owned_base_url.?;
        }
    }

    return result;
}

const EnvMap = struct {
    env: *const std.process.Environ.Map,
    pub fn get(self: EnvMap, key: []const u8) ?[]const u8 {
        return self.env.get(key);
    }
};

test {
    std.testing.refAllDecls(@This());
}
