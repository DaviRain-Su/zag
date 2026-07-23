//! zag-ai — OpenAI-compatible LLM client (monorepo package).
//!
//! Split like Grok Build crates: AI/provider is independent of the agent harness.
//! Transport and full OpenAPI surface: `openai_zig` (packages/openai-zig).

const std = @import("std");

pub const openai_zig = @import("openai_zig");

pub const types = @import("types.zig");
pub const presets = @import("presets.zig");
pub const auth_env = @import("auth_env.zig");
pub const registry = @import("registry.zig");
pub const openai_compat = @import("openai_compat.zig");
pub const stream = @import("stream.zig");
pub const catalog = @import("catalog.zig");
pub const config_file = @import("config_file.zig");
pub const wire = @import("wire.zig");
// Contract tests are pulled into the package test binary via refAllDecls.

pub const Message = types.Message;
pub const ContentPart = types.ContentPart;
pub const ToolCall = types.ToolCall;
pub const AssistantTurn = types.AssistantTurn;
pub const ToolDefinition = types.ToolDefinition;
pub const StreamEvent = types.StreamEvent;
pub const Usage = types.Usage;
pub const ChatOptions = types.ChatOptions;
pub const ToolChoice = types.ToolChoice;
pub const Client = openai_compat.Client;
pub const Config = openai_compat.Config;
pub const ProviderSpec = presets.ProviderSpec;
pub const ModelInfo = catalog.ModelInfo;
pub const FileConfig = config_file.FileConfig;
pub const EmbeddingResult = openai_compat.EmbeddingResult;
pub const WireAdapter = wire.WireAdapter;
pub const ApiStyle = wire.ApiStyle;

pub const isRetryableError = types.isRetryableError;
pub const createWire = openai_compat.createWire;
pub const openAiCompatFromClient = openai_compat.openAiCompatFromClient;

pub const version = "0.4.1";

/// Resolved endpoint + file/env chat knobs for the agent harness.
pub const ResolveResult = struct {
    resolved: registry.Resolved,
    stream: bool = false,
    /// Per-request chat options (from config file / env).
    chat_options: ChatOptions = .{},
    /// Catalog entry when model id is known.
    model_info: ?ModelInfo = null,
    /// Loop-level chat retries on retryable errors.
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    /// Optional harness overrides from config file.
    max_turns: ?u32 = null,
    context_max_chars: ?usize = null,
    context_max_tail_messages: ?usize = null,
    /// Optional owned model/base_url/user overrides from config file (free with deinit).
    owned_model: ?[]u8 = null,
    owned_base_url: ?[]u8 = null,
    owned_user: ?[]u8 = null,

    pub fn deinit(self: *ResolveResult, gpa: std.mem.Allocator) void {
        if (self.owned_model) |m| gpa.free(m);
        if (self.owned_base_url) |b| gpa.free(b);
        if (self.owned_user) |u| gpa.free(u);
        self.* = .{ .resolved = self.resolved };
    }

    /// Soft context char budget: file override > catalog estimate > default.
    pub fn contextCharBudget(self: ResolveResult, default_max_chars: usize) usize {
        if (self.context_max_chars) |n| return n;
        return catalog.contextBudgetChars(self.model_info, default_max_chars);
    }
};

/// Resolve endpoint from environment, overlaid with optional JSON config file.
/// Env secrets always win; file may set provider/model/base_url/stream/chat knobs.
///
/// Env overrides (when set):
/// - `ZAG_TEMPERATURE`, `ZAG_MAX_TOKENS`, `ZAG_MAX_RETRIES`, `ZAG_TIMEOUT_MS`
/// - `ZAG_CHAT_RETRIES`
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
    var file_cfg = try config_file.load(gpa, io, std.Io.Dir.cwd(), path) orelse {
        applyEnvChatOverrides(env, &result);
        result.model_info = catalog.lookup(result.resolved.spec_id, result.resolved.config.model);
        applyCatalogDefaults(&result);
        return result;
    };
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

    // Transport knobs from file
    if (file_cfg.max_retries) |n| result.resolved.config.max_retries = n;
    if (file_cfg.retry_base_delay_ms) |n| {
        result.resolved.config.retry_base_delay_ms = n;
        result.retry_base_delay_ms = n;
    }
    if (file_cfg.timeout_ms) |n| result.resolved.config.timeout_ms = n;

    // Chat options from file (user string owned for lifetime of ResolveResult)
    result.chat_options = file_cfg.chatOptions();
    if (file_cfg.user) |u| {
        result.owned_user = try gpa.dupe(u8, u);
        result.chat_options.user = result.owned_user.?;
    }

    if (file_cfg.chat_retries) |n| result.chat_retries = n;
    result.max_turns = file_cfg.max_turns;
    result.context_max_chars = file_cfg.context_max_chars;
    result.context_max_tail_messages = file_cfg.context_max_tail_messages;

    applyEnvChatOverrides(env, &result);
    result.model_info = catalog.lookup(result.resolved.spec_id, result.resolved.config.model);
    applyCatalogDefaults(&result);

    return result;
}

fn applyEnvChatOverrides(env: *const std.process.Environ.Map, result: *ResolveResult) void {
    if (env.get("ZAG_TEMPERATURE")) |s| {
        if (std.fmt.parseFloat(f64, s)) |t| {
            result.chat_options.temperature = t;
        } else |_| {}
    }
    if (env.get("ZAG_MAX_TOKENS")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| {
            result.chat_options.max_tokens = n;
        } else |_| {}
    }
    if (env.get("ZAG_MAX_COMPLETION_TOKENS")) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |n| {
            result.chat_options.max_completion_tokens = n;
        } else |_| {}
    }
    if (env.get("ZAG_MAX_RETRIES")) |s| {
        if (std.fmt.parseInt(u8, s, 10)) |n| {
            result.resolved.config.max_retries = n;
        } else |_| {}
    }
    if (env.get("ZAG_TIMEOUT_MS")) |s| {
        if (std.fmt.parseInt(u64, s, 10)) |n| {
            result.resolved.config.timeout_ms = n;
        } else |_| {}
    }
    if (env.get("ZAG_CHAT_RETRIES")) |s| {
        if (std.fmt.parseInt(u8, s, 10)) |n| {
            result.chat_retries = n;
        } else |_| {}
    }
    if (env.get("ZAG_STREAM")) |s| {
        if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true")) {
            result.stream = true;
        }
    }
}

/// Fill max_tokens from catalog when neither file nor env set it.
fn applyCatalogDefaults(result: *ResolveResult) void {
    if (result.chat_options.max_tokens == null and result.chat_options.max_completion_tokens == null) {
        if (catalog.suggestedMaxOutputTokens(result.model_info)) |cap| {
            result.chat_options.max_tokens = cap;
        }
    }
}

const EnvMap = struct {
    env: *const std.process.Environ.Map,
    pub fn get(self: EnvMap, key: []const u8) ?[]const u8 {
        return self.env.get(key);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("contract_tests.zig");
}
