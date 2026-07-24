//! zag-ai — multi-wire LLM client for Zag (canonical messages + adapters).
//!
//! - Shared: `config`, `wire`, `http` (std.http or zig-curl via `-Dhttp_backend`), `factory`, `stream` (event types only)
//! - Adapters: `openai_compat` (openai-zig resources), `anthropic_messages` (http facade)
//! - Independent of agent harness (packages/zag-agent-core).

const std = @import("std");

/// Optional full OpenAPI SDK (for OpenAI adapter / advanced callers).
pub const openai_zig = @import("openai_zig");

pub const types = @import("types.zig");
pub const presets = @import("presets.zig");
pub const auth_env = @import("auth_env.zig");
pub const registry = @import("registry.zig");
pub const openai_compat = @import("openai_compat.zig");
pub const anthropic_messages = @import("anthropic_messages.zig");
pub const stream = @import("stream.zig");
pub const catalog = @import("catalog.zig");
pub const catalog_serde = @import("catalog_serde.zig");
pub const cost = @import("cost.zig");
pub const config_file = @import("config_file.zig");
pub const wire = @import("wire.zig");
pub const config = @import("config.zig");
pub const http = @import("http.zig");
pub const request_control = @import("request_control.zig");
pub const factory = @import("factory.zig");
/// Shared redaction helpers for model-plane diagnostics (h-redact-001).
/// Never log Authorization / API keys; scrub bodies/URLs before stderr.
pub const redact_log = @import("redact_log.zig");

pub const Message = types.Message;
pub const ContentPart = types.ContentPart;
pub const ToolCall = types.ToolCall;
pub const AssistantTurn = types.AssistantTurn;
pub const ToolDefinition = types.ToolDefinition;
pub const StreamEvent = types.StreamEvent;
pub const StreamHandler = types.StreamHandler;
pub const Usage = types.Usage;
pub const ChatOptions = types.ChatOptions;
pub const ToolChoice = types.ToolChoice;
pub const Config = config.Config;
pub const ProviderSpec = presets.ProviderSpec;
pub const ModelInfo = catalog.ModelInfo;
pub const CostRates = catalog.CostRates;
pub const CostBreakdown = cost.CostBreakdown;
pub const CostLedger = cost.Ledger;
pub const FileConfig = config_file.FileConfig;
pub const WireAdapter = wire.WireAdapter;
pub const ApiStyle = wire.ApiStyle;
pub const WireError = wire.Error;

/// OpenAI Chat Completions client (adapter-specific). Prefer `createWire` for multi-style code.
pub const OpenAiClient = openai_compat.Client;
/// @deprecated Use `OpenAiClient` or `createWire(..., .openai_compat)`.
pub const Client = OpenAiClient;

pub const EmbedOptions = types.EmbedOptions;
pub const EmbeddingResult = types.EmbeddingResult;

pub const isRetryableError = types.isRetryableError;
pub const RequestControl = types.RequestControl;
pub const CancelFlag = types.CancelFlag;
pub const monoNowNs = types.monoNowNs;
pub const createWire = factory.createWire;
pub const openAiCompatFromClient = openai_compat.openAiCompatFromClient;

pub const version = "0.5.4";

/// Resolved endpoint + file/env chat knobs for the agent harness.
pub const ResolveResult = struct {
    resolved: registry.Resolved,
    stream: bool = false,
    chat_options: ChatOptions = .{},
    model_info: ?ModelInfo = null,
    chat_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    max_turns: ?u32 = null,
    context_max_chars: ?usize = null,
    context_max_tail_messages: ?usize = null,
    owned_model: ?[]u8 = null,
    owned_base_url: ?[]u8 = null,
    owned_user: ?[]u8 = null,

    pub fn deinit(self: *ResolveResult, gpa: std.mem.Allocator) void {
        if (self.owned_model) |m| gpa.free(m);
        if (self.owned_base_url) |b| gpa.free(b);
        if (self.owned_user) |u| gpa.free(u);
        self.* = .{ .resolved = self.resolved };
    }

    pub fn contextCharBudget(self: ResolveResult, default_max_chars: usize) usize {
        if (self.context_max_chars) |n| return n;
        return catalog.contextBudgetChars(self.model_info, default_max_chars);
    }
};

/// Resolve endpoint from environment, overlaid with optional JSON config file.
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

    if (file_cfg.provider) |pid| {
        if (env.get("ZAG_PROVIDER") == null) {
            if (presets.find(pid)) |spec| {
                if (auth_env.resolveApiKeySource(EnvMap{ .env = env }, spec.env_keys)) |ks| {
                    const style = if (env.get("ZAG_API_STYLE")) |s|
                        wire.ApiStyle.parse(s) orelse spec.api_style
                    else
                        spec.api_style;
                    result.resolved = .{
                        .spec_id = spec.id,
                        .display_name = spec.name,
                        .api_key_source = ks.source,
                        .api_style = style,
                        .config = .{
                            .api_key = ks.key,
                            .base_url = env.get("ZAG_BASE_URL") orelse spec.base_url,
                            .model = env.get("ZAG_MODEL") orelse spec.default_model,
                            .api_style = style,
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

    if (file_cfg.max_retries) |n| result.resolved.config.max_retries = n;
    if (file_cfg.retry_base_delay_ms) |n| {
        result.resolved.config.retry_base_delay_ms = n;
        result.retry_base_delay_ms = n;
    }
    if (file_cfg.timeout_ms) |n| result.resolved.config.timeout_ms = n;

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
    if (env.get("ZAG_API_STYLE")) |s| {
        if (wire.ApiStyle.parse(s)) |style| {
            result.resolved.api_style = style;
            result.resolved.config.api_style = style;
        }
    }
}

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
