//! zag-types — L0 canonical messages, tool defs, and neutral ChatError.
//!
//! No IO. Both `zag-ai` and `zag-agent-core` depend on this package.
//! Wire adapters map vendor failures onto `ChatError`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Neutral chat / provider failures (Agent Core + all WireAdapters).
pub const ChatError = error{
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
    /// End-to-end or transport deadline fired (not retried at loop layer).
    Timeout,
    /// Cooperative cancel observed mid-request (not retried).
    Cancelled,
    ServerError,
    BadRequest,
    /// Capability not available on this wire (e.g. embeddings on Anthropic).
    NotSupported,
};

/// Cooperative cancel flag. Thread- and signal-safe via seq_cst atomics.
///
/// Ownership: the host (Agent / test) owns the flag for the run lifetime.
/// In-flight requests borrow `*CancelFlag` via `RequestControl` and must not
/// outlive the flag. Signal handlers may only call `request`.
pub const CancelFlag = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *CancelFlag) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isSet(self: *const CancelFlag) bool {
        return self.cancelled.load(.seq_cst);
    }

    pub fn clear(self: *CancelFlag) void {
        self.cancelled.store(false, .seq_cst);
    }
};

/// Monotonic nanoseconds for deadline math (process-local).
///
/// Uses OS monotonic clocks when available; never wall-clock. Values are only
/// comparable within the same process (and preferably the same clock domain).
/// Aligns with `Io.Clock.awake` (macOS `UPTIME_RAW`, Linux `MONOTONIC`).
pub fn monoNowNs() u64 {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .dragonfly, .openbsd => {
            const clock_id: posix.clockid_t = switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
                else => posix.CLOCK.MONOTONIC,
            };
            var ts: posix.timespec = undefined;
            switch (posix.errno(posix.system.clock_gettime(clock_id, &ts))) {
                .SUCCESS => {
                    const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch
                        return std.math.maxInt(u64);
                    return sec_ns +| @as(u64, @intCast(ts.nsec));
                },
                else => return 0,
            }
        },
        else => {
            // Fallback: Timer is monotonic on supported targets.
            const Static = struct {
                var timer: ?std.time.Timer = null;
                var mu: std.Thread.Mutex = .{};
            };
            Static.mu.lock();
            defer Static.mu.unlock();
            if (Static.timer == null) {
                Static.timer = std.time.Timer.start() catch return 0;
            }
            return Static.timer.?.read();
        },
    }
}

/// Request lifecycle control: monotonic deadline + cooperative cancel.
///
/// - `deadline_mono_ns`: absolute mono ns; null = no deadline.
/// - `cancel`: borrowed flag; null = no mid-request cancel signal.
/// - Thread safety: cancel is atomic; deadline is a plain value (immutable after build).
/// - L0 has no IO: transports supply the same mono clock via `monoNowNs` / checks.
pub const RequestControl = struct {
    deadline_mono_ns: ?u64 = null,
    cancel: ?*CancelFlag = null,

    pub fn none() RequestControl {
        return .{};
    }

    /// Build a deadline from relative `timeout_ms` and current mono time.
    /// - `null` timeout → no deadline
    /// - `0` → already expired (immediate Timeout on check)
    /// - overflow saturates at maxInt(u64)
    pub fn withTimeoutMs(now_mono_ns: u64, timeout_ms: ?u64) RequestControl {
        const dl: ?u64 = if (timeout_ms) |ms| blk: {
            const add_ns = std.math.mul(u64, ms, std.time.ns_per_ms) catch
                break :blk std.math.maxInt(u64);
            break :blk now_mono_ns +| add_ns;
        } else null;
        return .{ .deadline_mono_ns = dl };
    }

    pub fn withCancel(self: RequestControl, flag: *CancelFlag) RequestControl {
        var c = self;
        c.cancel = flag;
        return c;
    }

    pub fn isCancelled(self: RequestControl) bool {
        return if (self.cancel) |f| f.isSet() else false;
    }

    pub fn isExpired(self: RequestControl, now_mono_ns: u64) bool {
        return if (self.deadline_mono_ns) |d| now_mono_ns >= d else false;
    }

    /// Prefer cancel over timeout when both trip (stable precedence).
    pub fn check(self: RequestControl, now_mono_ns: u64) error{ Cancelled, Timeout }!void {
        if (self.isCancelled()) return error.Cancelled;
        if (self.isExpired(now_mono_ns)) return error.Timeout;
    }

    pub fn checkNow(self: RequestControl) error{ Cancelled, Timeout }!void {
        return self.check(monoNowNs());
    }

    /// Remaining whole milliseconds until deadline; null if none; 0 if expired.
    pub fn remainingMs(self: RequestControl, now_mono_ns: u64) ?u64 {
        const d = self.deadline_mono_ns orelse return null;
        if (now_mono_ns >= d) return 0;
        return (d - now_mono_ns) / std.time.ns_per_ms;
    }

    /// libcurl-compatible timeout: 0 = no timeout (infinite). When a deadline
    /// is set, returns at least 1 ms while budget remains so curl does not
    /// treat 0 as infinite after partial spend.
    pub fn curlTimeoutMs(self: RequestControl, now_mono_ns: u64, configured_ms: ?u64) u64 {
        const from_deadline = self.remainingMs(now_mono_ns);
        if (from_deadline) |rem| {
            if (rem == 0) return 1; // force immediate fire
            if (configured_ms) |cfg| return @min(cfg, rem);
            return rem;
        }
        return configured_ms orelse 0;
    }
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonName(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Multimodal content part (adapters map to vendor wire shapes).
pub const ContentPart = union(enum) {
    text: []const u8,
    /// Image by URL or data: URL. `detail` is optional (auto|low|high).
    image_url: struct {
        url: []const u8,
        detail: ?[]const u8 = null,
    },
};

pub const Message = struct {
    role: Role,
    /// Plain-text content (legacy / default path).
    content: []const u8 = "",
    /// When set, serialized as a content array (multimodal). Prefer over `content`.
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub fn user(content: []const u8) Message {
        return .{ .role = .user, .content = content };
    }
    pub fn userMultimodal(parts: []const ContentPart) Message {
        return .{ .role = .user, .content_parts = parts };
    }
    pub fn system(content: []const u8) Message {
        return .{ .role = .system, .content = content };
    }
    pub fn assistantText(content: []const u8) Message {
        return .{ .role = .assistant, .content = content };
    }
    pub fn assistantToolCalls(content: []const u8, calls: []const ToolCall) Message {
        return .{ .role = .assistant, .content = content, .tool_calls = calls };
    }
    pub fn toolResult(tool_call_id: []const u8, content: []const u8) Message {
        return .{ .role = .tool, .content = content, .tool_call_id = tool_call_id };
    }

    /// Approximate character weight for context budgeting.
    pub fn estimateChars(self: Message) usize {
        var n: usize = self.content.len;
        if (self.tool_call_id) |id| n += id.len;
        if (self.tool_calls) |calls| {
            for (calls) |c| n += c.id.len + c.name.len + c.arguments.len;
        }
        if (self.content_parts) |parts| {
            for (parts) |p| {
                switch (p) {
                    .text => |t| n += t.len,
                    .image_url => |img| n += img.url.len + 2_000,
                }
            }
        }
        return n;
    }
};

/// Options for embed (vendors ignore unsupported fields).
pub const EmbedOptions = struct {
    model: ?[]const u8 = null,
    dimensions: ?u32 = null,
    encoding_format: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

/// Result of an embedding request (arena-allocated vectors).
pub const EmbeddingResult = struct {
    model: []const u8 = "",
    vectors: []const []const f64 = &.{},
    usage: ?Usage = null,
};

pub const Usage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,

    pub fn fromCounts(prompt: i64, completion: i64, total: i64) Usage {
        return .{
            .prompt_tokens = clampU32(prompt),
            .completion_tokens = clampU32(completion),
            .total_tokens = clampU32(total),
        };
    }

    pub fn add(self: *Usage, other: Usage) void {
        self.prompt_tokens +|= other.prompt_tokens;
        self.completion_tokens +|= other.completion_tokens;
        self.total_tokens +|= other.total_tokens;
        self.reasoning_tokens +|= other.reasoning_tokens;
    }

    fn clampU32(v: i64) u32 {
        if (v <= 0) return 0;
        if (v >= std.math.maxInt(u32)) return std.math.maxInt(u32);
        return @intCast(v);
    }
};

pub const AssistantTurn = struct {
    content: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    finish_reason: []const u8 = "",
    usage: ?Usage = null,

    pub fn wantsTools(self: AssistantTurn) bool {
        return self.tool_calls.len > 0;
    }
};

/// Model-visible tool schema only. Never carries local security metadata.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// Local execution risk class. Required on every registered tool — no default-to-read.
pub const ToolRisk = enum {
    read,
    write,
    execute,

    pub fn needsConfirmation(self: ToolRisk) bool {
        return self != .read;
    }

    /// Human-facing category (shell for execute).
    pub fn label(self: ToolRisk) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .execute => "shell",
        };
    }

    pub fn name(self: ToolRisk) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .execute => "execute",
        };
    }
};

/// Whether the tool claims a workspace path argument for containment.
/// `none` means no path claim — not unrestricted filesystem access.
pub const WorkspaceAccess = union(enum) {
    none,
    /// JSON object field name holding a relative path (typically `"path"`).
    path_field: []const u8,

    pub fn usesPath(self: WorkspaceAccess) bool {
        return self != .none;
    }

    pub fn pathField(self: WorkspaceAccess) ?[]const u8 {
        return switch (self) {
            .none => null,
            .path_field => |f| f,
        };
    }
};

/// Whether the handler observes cooperative cancel / deadline mid-invocation.
pub const CancellationCapability = enum {
    none,
    cooperative,
};

/// Whether shell command policy applies (not inferred from tool name).
pub const ShellPolicyKind = enum {
    none,
    /// Parse JSON field `"command"` and run shell_policy before execute.
    command_argument,
};

/// Mandatory local runtime capabilities (never sent to providers).
/// All fields are explicit — no implicit read/default safety.
pub const ToolCapabilities = struct {
    risk: ToolRisk,
    workspace: WorkspaceAccess,
    cancellation: CancellationCapability,
    shell: ShellPolicyKind,
};

/// Local runtime descriptor: model definition + mandatory capabilities.
pub const ToolDescriptor = struct {
    definition: ToolDefinition,
    capabilities: ToolCapabilities,

    pub fn name(self: ToolDescriptor) []const u8 {
        return self.definition.name;
    }

    pub fn risk(self: ToolDescriptor) ToolRisk {
        return self.capabilities.risk;
    }
};

pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    function: []const u8,
};

pub const ChatOptions = struct {
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    tool_choice: ?ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    user: ?[]const u8 = null,
    seed: ?u64 = null,
    extra_body: ?std.json.Value = null,
    /// Lifecycle control (borrowed cancel + monotonic deadline). Not a sampling knob.
    /// Transports must enforce or reject; never accept and ignore.
    control: RequestControl = .{},
};

pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    tool_call_delta: struct {
        index: usize,
        id: []const u8 = "",
        name: []const u8 = "",
        arguments_delta: []const u8 = "",
    },
    finish_reason: []const u8,
    done,
};

pub const StreamHandler = *const fn (ctx: ?*anyopaque, event: StreamEvent) anyerror!void;

/// Loop-layer retry policy. End-to-end **Timeout** and **Cancelled** are never
/// retried (deadline budget is shared across attempts; cancel is terminal).
/// Transient transport/server failures may still retry while budget remains.
pub fn isRetryableError(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.ServerError, error.HttpFailed => true,
        error.Timeout, error.Cancelled, error.NotSupported => false,
        else => false,
    };
}

test "role json names" {
    try std.testing.expectEqualStrings("user", Role.user.jsonName());
}

test "usage clamp" {
    const u = Usage.fromCounts(10, 5, 15);
    try std.testing.expectEqual(@as(u32, 10), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 5), u.completion_tokens);
    try std.testing.expectEqual(@as(u32, 15), u.total_tokens);
}

test "usage add" {
    var total: Usage = .{};
    total.add(.{ .prompt_tokens = 10, .completion_tokens = 3, .total_tokens = 13 });
    total.add(.{ .prompt_tokens = 5, .completion_tokens = 2, .total_tokens = 7, .reasoning_tokens = 1 });
    try std.testing.expectEqual(@as(u32, 15), total.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 5), total.completion_tokens);
    try std.testing.expectEqual(@as(u32, 20), total.total_tokens);
    try std.testing.expectEqual(@as(u32, 1), total.reasoning_tokens);
}

test "isRetryableError" {
    try std.testing.expect(isRetryableError(error.RateLimited));
    try std.testing.expect(!isRetryableError(error.AuthenticationFailed));
}

test "isRetryableError does not treat NotSupported as retryable" {
    try std.testing.expect(!isRetryableError(error.NotSupported));
}

test "isRetryableError does not treat Timeout or Cancelled as retryable" {
    try std.testing.expect(!isRetryableError(error.Timeout));
    try std.testing.expect(!isRetryableError(error.Cancelled));
}

test "RequestControl timeout and cancel precedence" {
    var flag: CancelFlag = .{};
    const now: u64 = 1_000_000;
    var ctrl = RequestControl.withTimeoutMs(now, 100);
    ctrl = ctrl.withCancel(&flag);
    try ctrl.check(now);
    try std.testing.expectEqual(@as(?u64, 100), ctrl.remainingMs(now));
    try std.testing.expectError(error.Timeout, ctrl.check(now + 200 * std.time.ns_per_ms));
    flag.request();
    // Cancel wins when both would trip.
    try std.testing.expectError(error.Cancelled, ctrl.check(now + 200 * std.time.ns_per_ms));
}

test "RequestControl zero timeout is already expired" {
    const now: u64 = 50;
    const ctrl = RequestControl.withTimeoutMs(now, 0);
    try std.testing.expectError(error.Timeout, ctrl.check(now));
    try std.testing.expectEqual(@as(?u64, 0), ctrl.remainingMs(now));
}

test "RequestControl curlTimeoutMs no unexpected default" {
    const now: u64 = 0;
    const none = RequestControl.none();
    try std.testing.expectEqual(@as(u64, 0), none.curlTimeoutMs(now, null));
    try std.testing.expectEqual(@as(u64, 5000), none.curlTimeoutMs(now, 5000));
    const with_dl = RequestControl.withTimeoutMs(now, 100);
    try std.testing.expectEqual(@as(u64, 50), with_dl.curlTimeoutMs(now, 50));
    try std.testing.expectEqual(@as(u64, 100), with_dl.curlTimeoutMs(now, null));
}

test "monoNowNs is nondecreasing" {
    const a = monoNowNs();
    const b = monoNowNs();
    try std.testing.expect(b >= a);
}
