//! Shared wire client configuration (all ApiStyles).
//!
//! Kept free of OpenAI/Anthropic specifics so adapters and `registry` share one shape.

const wire = @import("wire.zig");

/// Endpoint + credentials + transport knobs for any WireAdapter.
pub const Config = struct {
    /// e.g. `https://api.openai.com/v1` or `https://api.anthropic.com`
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    /// Transient HTTP retries (underlying transport).
    max_retries: u8 = 2,
    retry_base_delay_ms: u64 = 500,
    timeout_ms: ?u64 = null,
    /// Selected wire family (set by resolve / caller).
    api_style: wire.ApiStyle = .openai_compat,
};
