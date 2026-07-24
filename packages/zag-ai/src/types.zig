//! Canonical types — re-export from `zag-types` (L0).
//! Prefer `@import("zag-types")` in new code; this file keeps existing `ai.types` paths.

const zt = @import("zag-types");

pub const ChatError = zt.ChatError;
pub const Role = zt.Role;
pub const ToolCall = zt.ToolCall;
pub const ContentPart = zt.ContentPart;
pub const Message = zt.Message;
pub const EmbedOptions = zt.EmbedOptions;
pub const EmbeddingResult = zt.EmbeddingResult;
pub const Usage = zt.Usage;
pub const AssistantTurn = zt.AssistantTurn;
pub const ToolDefinition = zt.ToolDefinition;
pub const ToolChoice = zt.ToolChoice;
pub const ChatOptions = zt.ChatOptions;
pub const StreamEvent = zt.StreamEvent;
pub const StreamHandler = zt.StreamHandler;
pub const isRetryableError = zt.isRetryableError;
