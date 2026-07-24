//! Shared request-control helpers for HTTP backends (std + curl).
//!
//! Translates L0 `RequestControl` into transport-level timeout/abort behavior.
//! Backend-specific enforcement lives in `http_std.zig` / `http_curl.zig`.

const std = @import("std");
const types = @import("types.zig");

pub const RequestControl = types.RequestControl;
pub const CancelFlag = types.CancelFlag;
pub const monoNowNs = types.monoNowNs;
pub const Error = types.ChatError;

/// Map control-check failures and Zig Io cancel onto wire errors.
pub fn mapControlErr(err: anyerror) Error {
    return switch (err) {
        error.Cancelled, error.Canceled => error.Cancelled,
        error.Timeout => error.Timeout,
        else => error.HttpFailed,
    };
}

/// Pre-flight: fail before network work when control already tripped.
pub fn preflight(control: RequestControl) Error!void {
    control.checkNow() catch |err| return mapControlErr(err);
}

/// Merge configured client timeout into control when no deadline is set yet.
pub fn mergeConfiguredTimeout(control: RequestControl, timeout_ms: ?u64) RequestControl {
    if (control.deadline_mono_ns != null) return control;
    if (timeout_ms == null) return control;
    var c = RequestControl.withTimeoutMs(monoNowNs(), timeout_ms);
    c.cancel = control.cancel;
    return c;
}

/// Sleep for retry backoff without exceeding remaining deadline.
/// Returns error.Timeout if budget is exhausted.
pub fn sleepRetryBounded(
    io: std.Io,
    base_ms: u64,
    attempt: u8,
    control: RequestControl,
) Error!void {
    try preflight(control);
    var delay_ms = base_ms * (@as(u64, 1) << @intCast(@min(attempt, 4)));
    if (control.remainingMs(monoNowNs())) |rem| {
        if (rem == 0) return error.Timeout;
        delay_ms = @min(delay_ms, rem);
    }
    const duration: std.Io.Duration = .{ .nanoseconds = @intCast(delay_ms * std.time.ns_per_ms) };
    std.Io.sleep(io, duration, .real) catch |err| {
        if (control.isCancelled()) return error.Cancelled;
        if (err == error.Canceled) return error.Cancelled;
    };
    try preflight(control);
}

test "mergeConfiguredTimeout preserves existing deadline" {
    const now = monoNowNs();
    const c = RequestControl.withTimeoutMs(now, 1000);
    const merged = mergeConfiguredTimeout(c, 50);
    try std.testing.expectEqual(c.deadline_mono_ns, merged.deadline_mono_ns);
}

test "mergeConfiguredTimeout applies client timeout when none" {
    const c = RequestControl.none();
    const merged = mergeConfiguredTimeout(c, 0);
    try std.testing.expectError(error.Timeout, merged.checkNow());
}
