//! Shared request-control helpers for HTTP backends (std + curl).
//!
//! Translates L0 `RequestControl` into transport-level timeout/abort behavior.
//! Backend-specific enforcement lives in `http_std.zig` / `http_curl.zig`.
//!
//! ## Capability truth (h-provider-001 follow-up)
//!
//! - **curl**: active deadline (`CURLOPT_TIMEOUT_MS`) + active cancel (xferinfo).
//! - **std**: ordinary no-timeout HTTP works; configured deadline or
//!   `require_active_cancel` → `UnsupportedControl` **before** network.
//!   Cooperative cancel alone: preflight + between-chunk checks only (not bounded
//!   active interrupt). Never use cross-thread connection shutdown.

const std = @import("std");
const types = @import("types.zig");
const build_options = @import("build_options");

pub const RequestControl = types.RequestControl;
pub const CancelFlag = types.CancelFlag;
pub const monoNowNs = types.monoNowNs;
pub const Error = types.ChatError;

/// Map control-check failures and Zig Io cancel onto wire errors.
pub fn mapControlErr(err: anyerror) Error {
    return switch (err) {
        error.Cancelled, error.Canceled => error.Cancelled,
        error.Timeout => error.Timeout,
        error.UnsupportedControl => error.UnsupportedControl,
        else => error.HttpFailed,
    };
}

/// Whether this build's HTTP backend can enforce active deadline + active cancel.
pub fn backendSupportsActiveLifecycle() bool {
    return build_options.http_backend == .curl;
}

/// Fail closed before network when control requires capabilities this backend lacks.
///
/// | control | std | curl |
/// |---------|-----|------|
/// | none / ordinary | OK | OK |
/// | deadline | UnsupportedControl | OK |
/// | require_active_cancel | UnsupportedControl | OK |
/// | cooperative cancel only | OK (preflight/chunks) | OK (active) |
pub fn assertBackendSupports(control: RequestControl) Error!void {
    if (!control.needsEnforcedLifecycle()) return;
    if (backendSupportsActiveLifecycle()) return;
    return error.UnsupportedControl;
}

/// Pre-flight: capability gate, then cancel/deadline already tripped.
pub fn preflight(control: RequestControl) Error!void {
    try assertBackendSupports(control);
    control.checkNow() catch |err| return mapControlErr(err);
}

/// Merge configured client timeout into control when no deadline is set yet.
pub fn mergeConfiguredTimeout(control: RequestControl, timeout_ms: ?u64) RequestControl {
    if (control.deadline_mono_ns != null) return control;
    if (timeout_ms == null) return control;
    var c = RequestControl.withTimeoutMs(monoNowNs(), timeout_ms);
    c.cancel = control.cancel;
    c.require_active_cancel = control.require_active_cancel;
    return c;
}

/// Overflow-safe delay for attempt `attempt` with base_ms, saturating at maxInt(u64).
pub fn retryDelayMs(base_ms: u64, attempt: u8) u64 {
    const shift: u6 = @intCast(@min(attempt, 4));
    const factor: u64 = @as(u64, 1) << shift;
    return std.math.mul(u64, base_ms, factor) catch std.math.maxInt(u64);
}

/// Sleep for retry backoff without exceeding remaining deadline, in short slices
/// (≤25ms) so cancel is observed promptly. Rechecks control after every slice.
/// Returns Timeout/Cancelled; never retries those.
pub fn sleepRetryBounded(
    io: std.Io,
    base_ms: u64,
    attempt: u8,
    control: RequestControl,
) Error!void {
    try preflight(control);
    var delay_ms = retryDelayMs(base_ms, attempt);
    if (control.remainingMs(monoNowNs())) |rem| {
        if (rem == 0) return error.Timeout;
        delay_ms = @min(delay_ms, rem);
    }
    const slice_ms: u64 = 25;
    var left = delay_ms;
    while (left > 0) {
        try preflight(control);
        const step = @min(left, slice_ms);
        const ns: i96 = @intCast(@as(u64, step) *% std.time.ns_per_ms);
        const duration: std.Io.Duration = .{ .nanoseconds = ns };
        std.Io.sleep(io, duration, .real) catch |err| {
            if (control.isCancelled()) return error.Cancelled;
            if (err == error.Canceled) return error.Cancelled;
        };
        left -|= step;
    }
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

test "retryDelayMs saturates without overflow" {
    const d = retryDelayMs(std.math.maxInt(u64) / 2, 4);
    try std.testing.expect(d == std.math.maxInt(u64) or d > 0);
}

test "assertBackendSupports deadline on std" {
    if (backendSupportsActiveLifecycle()) return;
    const c = RequestControl.withTimeoutMs(monoNowNs(), 100);
    try std.testing.expectError(error.UnsupportedControl, assertBackendSupports(c));
    // cooperative cancel alone is allowed on std
    var flag: CancelFlag = .{};
    try assertBackendSupports(RequestControl.none().withCancel(&flag));
}

test "assertBackendSupports require_active_cancel on std" {
    if (backendSupportsActiveLifecycle()) return;
    const c = RequestControl.none().withRequireActiveCancel(true);
    try std.testing.expectError(error.UnsupportedControl, assertBackendSupports(c));
}
