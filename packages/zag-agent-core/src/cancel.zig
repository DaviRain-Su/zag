//! Cooperative cancel flag for the harness loop (H1 + h-provider-001).
//!
//! This module owns only the L0 cancel flag. A flag is flipped by the host
//! (CLI signal handler, tests, or any caller) and checked between turns /
//! tool calls; the same flag is borrowed via `RequestControl` so in-flight
//! HTTP can observe it. Open tool_call pairs finish with `code=cancelled` so
//! the transcript stays resume-safe.
//!
//! cli-sigint-001: the process SIGINT handler is owned by `zag-cli`
//! (`packages/zag-cli/src/sigint.zig`); this module does NOT install any signal
//! handler. Constructing/using the Agent (SDK) never installs a handler.

const std = @import("std");
const zt = @import("zag-types");

/// L0 cancel flag (thread-/signal-safe). Re-exported for Agent/loop/CLI.
pub const Flag = zt.CancelFlag;

test "flag request and clear" {
    // Goal: cooperative cancel is sticky until cleared.
    var flag: Flag = .{};
    try std.testing.expect(!flag.isSet());
    flag.request();
    try std.testing.expect(flag.isSet());
    flag.clear();
    try std.testing.expect(!flag.isSet());
}