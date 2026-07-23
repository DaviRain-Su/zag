//! Compatibility re-export of the OpenAI Chat Completions client.
//!
//! Prefer `@import("provider/openai_compat.zig")` in new code. This module
//! remains so existing `zag.openai.Client` call sites keep working.

const openai_compat = @import("openai_compat.zig");

pub const Config = openai_compat.Config;
pub const Error = openai_compat.Error;
pub const Client = openai_compat.Client;
