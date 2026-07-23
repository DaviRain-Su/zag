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

/// Shared error set for all wire backends (OpenAI, Anthropic, …).
pub const Error = error{
    HttpFailed,
    BadStatus,
    InvalidResponse,
    OutOfMemory,
    WriteFailed,
    Unexpected,
    StreamFailed,
    AuthenticationFailed,
    PermissionDenied,
    RateLimited,
    Timeout,
    ServerError,
    BadRequest,
};

pub const ChatOptions = types.ChatOptions;

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
    ) Error!types.AssistantTurn,
    chat_stream: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
    ) Error!types.AssistantTurn,
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
    ) Error!types.AssistantTurn {
        return self.vtable.chat(self.ptr, arena, messages, tools, opts);
    }

    pub fn chatStream(
        self: WireAdapter,
        arena: std.mem.Allocator,
        messages: []const types.Message,
        tools: []const types.ToolDefinition,
        handler: ?types.StreamHandler,
        handler_ctx: ?*anyopaque,
        opts: ChatOptions,
    ) Error!types.AssistantTurn {
        return self.vtable.chat_stream(self.ptr, arena, messages, tools, handler, handler_ctx, opts);
    }
};

test "api style parse" {
    try std.testing.expect(ApiStyle.parse("openai_compat").? == .openai_compat);
    try std.testing.expect(ApiStyle.parse("openai").? == .openai_compat);
    try std.testing.expect(ApiStyle.parse("anthropic").? == .anthropic_messages);
    try std.testing.expect(ApiStyle.parse("nope") == null);
}
