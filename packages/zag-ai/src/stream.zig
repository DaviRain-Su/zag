//! Shared **stream surface** for all wire adapters (not OpenAI-specific).
//!
//! Streaming is implemented **per adapter**:
//! - `openai_compat.Client.chatStreamWithOptions` — OpenAI Chat Completions SSE
//! - `anthropic_messages.Client.chatStreamWithOptions` — Anthropic Messages SSE
//! - Preferred call site: `WireAdapter.chatStream` (vtable)
//!
//! This module only re-exports neutral event/handler types. Do not put vendor
//! SDK stream parsing here.

const types = @import("types.zig");
const wire = @import("wire.zig");

pub const Error = wire.Error;
pub const Handler = types.StreamHandler;
pub const Event = types.StreamEvent;
