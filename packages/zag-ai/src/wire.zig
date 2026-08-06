//! WireAdapter — pluggable model wire protocols behind canonical messages.
//!
//! Agent Core only sees `types.Message` / `AssistantTurn`. Each `ApiStyle`
//! implementation converts to/from vendor wire formats (Pi-style convertToLlm).
//!
//! Implementations:
//! - `openai_compat` — Chat Completions (`openai_compat.zig`)
//! - `anthropic_messages` — Anthropic Messages API (`anthropic_messages.zig`)
//!
//! This file has **no** dependency on protocol packages (avoids import cycles).
//! Factory: `factory.createWire` / `registry.Resolved.createWire`.

const std = @import("std");
const types = @import("types.zig");

/// Shared error set for all wire backends — alias of L0 `zag-types.ChatError`.
pub const Error = types.ChatError;

pub const ChatOptions = types.ChatOptions;
pub const EmbedOptions = types.EmbedOptions;
pub const EmbeddingResult = types.EmbeddingResult;

/// Vendor wire family. New styles get a new adapter module, not agent branches.
pub const ApiStyle = enum {
    /// OpenAI Chat Completions (`/v1/chat/completions`) and compat hosts.
    openai_compat,
    /// Anthropic Messages API (`POST /v1/messages`).
    anthropic_messages,

    pub fn jsonName(self: ApiStyle) []const u8 {
        return switch (self) {
            .openai_compat => "openai_compat",
            .anthropic_messages => "anthropic_messages",
        };
    }

    pub fn parse(s: []const u8) ?ApiStyle {
        if (std.mem.eql(u8, s, "openai_compat") or std.mem.eql(u8, s, "openai")) return .openai_compat;
        if (std.mem.eql(u8, s, "anthropic_messages") or std.mem.eql(u8, s, "anthropic")) return .anthropic_messages;
        return null;
    }
};

pub const VTable = struct {
    api_style: *const fn (ptr: *anyopaque) ApiStyle,
    name: *const fn (ptr: *anyopaque) []const u8,
    deinit: *const fn (ptr: *anyopaque) void,
    chat: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
        /// Retry-After capture slot (retry-after-wire-001), in ms. Written
        /// only on terminal error returns with a parsed integer header
        /// (429/5xx, Anthropic + OpenAI wires — openai-retry-after-001);
        /// cleared to null otherwise.
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn,
    chat_stream: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
        /// See `chat` — stream variant of the Retry-After capture slot.
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn,
    embed: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        inputs: []const []const u8,
        opts: EmbedOptions,
    ) Error!EmbeddingResult,
    /// Optional: list model ids from the provider (GET /models). Arena-owned.
    /// Null → wire does not support live listing (caller falls back to catalog).
    list_models: ?*const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
    ) Error![]const []const u8 = null,
    /// Optional: switch the active chat model for subsequent requests.
    /// Copies `model` into wire-owned storage. Null → no-op.
    set_model: ?*const fn (ptr: *anyopaque, model: []const u8) Error!void = null,
    /// Optional: current model id (borrowed). Null → empty.
    get_model: ?*const fn (ptr: *anyopaque) []const u8 = null,
};

/// Type-erased wire backend.
pub const WireAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn apiStyle(self: WireAdapter) ApiStyle {
        return self.vtable.api_style(self.ptr);
    }

    pub fn name(self: WireAdapter) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: WireAdapter) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn chat(
        self: WireAdapter,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        opts: ChatOptions,
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        return self.vtable.chat(self.ptr, arena, messages, tools, opts, retry_after_out);
    }

    pub fn chatStream(
        self: WireAdapter,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
        retry_after_out: ?*?u64,
    ) Error!types.AssistantTurn {
        return self.vtable.chat_stream(self.ptr, arena, messages, tools, handler, handler_ctx, opts, retry_after_out);
    }

    /// Embeddings when the wire supports them; otherwise `error.NotSupported`.
    pub fn embed(
        self: WireAdapter,
        arena: std.mem.Allocator,
        inputs: []const []const u8,
        opts: EmbedOptions,
    ) Error!EmbeddingResult {
        return self.vtable.embed(self.ptr, arena, inputs, opts);
    }

    /// Live model ids from the provider (arena-owned). `error.NotSupported` when
    /// the wire has no list_models implementation.
    pub fn listModels(self: WireAdapter, arena: std.mem.Allocator) Error![]const []const u8 {
        const f = self.vtable.list_models orelse return error.NotSupported;
        return f(self.ptr, arena);
    }

    /// Switch the active chat model. Copies into wire-owned storage.
    pub fn setModel(self: WireAdapter, model: []const u8) Error!void {
        const f = self.vtable.set_model orelse return error.NotSupported;
        return f(self.ptr, model);
    }

    /// Current model id (borrowed from wire config). Empty when unavailable.
    pub fn getModel(self: WireAdapter) []const u8 {
        const f = self.vtable.get_model orelse return "";
        return f(self.ptr);
    }

    pub fn supportsEmbed(self: WireAdapter) bool {
        return switch (self.apiStyle()) {
            .openai_compat => true,
            .anthropic_messages => false,
        };
    }
};

test "api style parse" {
    try std.testing.expect(ApiStyle.parse("openai_compat").? == .openai_compat);
    try std.testing.expect(ApiStyle.parse("openai").? == .openai_compat);
    try std.testing.expect(ApiStyle.parse("anthropic").? == .anthropic_messages);
    try std.testing.expect(ApiStyle.parse("nope") == null);
}
