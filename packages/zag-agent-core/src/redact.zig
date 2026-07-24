//! Shared secret redaction boundary (h-redact-001).
//!
//! # Contract
//!
//! Apply **before** outward surfaces: verbose/observer logs, trace JSONL
//! serialization, and session atomic persistence. In-memory authoritative
//! transcript and provider request bytes may remain raw; persistence and logs
//! must not mutate those buffers in place.
//!
//! ## Policy
//!
//! - **Exact secrets:** configured values (at minimum the resolved provider API
//!   key). Empty and too-short secrets (`min_configured_secret_len`) are ignored
//!   to prevent catastrophic over-redaction. Multiple secrets may be borrowed
//!   at `addSecret`/`init` time; the redactor **copies** them immediately so no
//!   borrowed secret pointer is retained.
//! - **Patterns:** conservative, documented shapes for common API keys/tokens
//!   (xAI/OpenAI `sk-…`, Anthropic `sk-ant-…`, GitHub PATs, AWS `AKIA…`,
//!   `Bearer …`). Minimum lengths + restricted alphabets; ordinary identifiers
//!   and code-like near-misses stay intact.
//! - **Marker:** deterministic `marker` (`[REDACTED]`). Longest-match /
//!   overlap-safe (exact secrets sorted by length descending; at each byte
//!   offset try exact then patterns). Linear scan — no regex, no backtracking.
//! - **Bytes / UTF-8:** matching is **byte-oriented** (secrets are opaque
//!   byte strings, typically ASCII). Invalid UTF-8 input is still scanned;
//!   callers that require valid UTF-8 (trace) validate before/after as needed.
//! - **Diagnostics:** never log secret values or lengths.
//!
//! ## Failure
//!
//! Allocation failure is typed (`error.OutOfMemory`) and **fail-closed**:
//! callers must not `catch {}` then emit raw. Verbose logs may omit the line;
//! session/trace must preserve prior durable bytes and surface the error.
//!
//! ## Ownership / lifetime
//!
//! - `Redactor` is instance-aware: no global mutable secret state.
//! - Concurrent **reads** (`redactAlloc`) are safe when no concurrent mutate
//!   (`addSecret` / `deinit`).
//! - Freeing secrets does **not** claim cryptographic zeroization (honest
//!   limit; OS heap reuse is out of scope).
//! - Test-only seams live under `testing` and compile out of production.
//!
//! ## Low-level bypass
//!
//! Raw `session_store` / `Trace` APIs without an attached redactor intentionally
//! skip product redaction — they are clearly optional-policy surfaces. The
//! normal Agent / CLI / session / trace product path always attaches policy and
//! cannot silently bypass it.
//!
//! ## Limits
//!
//! Redaction reduces known-key and shape leakage. It does **not** prove
//! arbitrary tool/file output secret-free. Treat `.zag/` as sensitive local
//! state. Not a DLP product.

const std = @import("std");
const builtin = @import("builtin");

/// Deterministic replacement for matched secret material.
pub const marker: []const u8 = "[REDACTED]";

/// Configured secrets shorter than this are ignored (over-redaction guard).
pub const min_configured_secret_len: usize = 8;

/// Pattern minimums (conservative false-positive guard).
pub const min_sk_token_len: usize = 20;
pub const min_ant_token_len: usize = 20;
pub const min_github_pat_len: usize = 36;
pub const min_github_fine_len: usize = 40;
pub const min_bearer_token_len: usize = 20;
/// AWS access key id: `AKIA` + 16 uppercase alnum.
pub const aws_akia_body_len: usize = 16;

pub const Error = error{OutOfMemory};

/// Policy snapshot for construction. Borrowed slices are copied by `init`.
pub const Policy = struct {
    /// Exact secrets (API keys, tokens). Empty/short entries are skipped.
    secrets: []const []const u8 = &.{},
    /// When true, apply the documented common-key pattern set.
    patterns: bool = true,
};

/// Instance-owned redactor. Reusable; no global secret registry.
pub const Redactor = struct {
    gpa: std.mem.Allocator,
    /// Owned secret copies, sorted longest-first for overlap-safe matching.
    secrets: std.ArrayList([]u8) = .empty,
    patterns: bool = true,

    pub fn init(gpa: std.mem.Allocator, policy: Policy) Error!Redactor {
        var self: Redactor = .{
            .gpa = gpa,
            .patterns = policy.patterns,
        };
        errdefer self.deinit();
        for (policy.secrets) |s| {
            try self.addSecret(s);
        }
        return self;
    }

    /// Empty redactor with patterns enabled (product default when no keys yet).
    pub fn initDefault(gpa: std.mem.Allocator) Redactor {
        return .{ .gpa = gpa, .patterns = true };
    }

    pub fn deinit(self: *Redactor) void {
        for (self.secrets.items) |s| {
            // Honest: free only — no cryptographic zeroization claim.
            self.gpa.free(s);
        }
        self.secrets.deinit(self.gpa);
        self.* = undefined;
    }

    /// Copy `secret` into the instance if it passes the min-length filter.
    /// Empty / too-short values are ignored (not an error).
    pub fn addSecret(self: *Redactor, secret: []const u8) Error!void {
        if (secret.len < min_configured_secret_len) return;
        const owned = self.gpa.dupe(u8, secret) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned);
        try self.secrets.append(self.gpa, owned);
        self.sortSecrets();
    }

    fn sortSecrets(self: *Redactor) void {
        // Longest first so overlapping prefixes prefer the longer secret.
        const items = self.secrets.items;
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and items[j - 1].len < items[j].len) : (j -= 1) {
                const tmp = items[j - 1];
                items[j - 1] = items[j];
                items[j] = tmp;
            }
        }
    }

    /// Allocate a redacted copy of `input`. On no match, returns a dupe of input.
    /// Fail-closed: OOM returns `error.OutOfMemory` (never a raw borrow).
    pub fn redactAlloc(self: *const Redactor, gpa: std.mem.Allocator, input: []const u8) Error![]u8 {
        if (input.len == 0) {
            return gpa.dupe(u8, input) catch return error.OutOfMemory;
        }

        // Fast path: nothing to do.
        if (self.secrets.items.len == 0 and !self.patterns) {
            return gpa.dupe(u8, input) catch return error.OutOfMemory;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        var i: usize = 0;
        while (i < input.len) {
            if (self.matchAt(input, i)) |n| {
                out.appendSlice(gpa, marker) catch return error.OutOfMemory;
                i += n;
            } else {
                out.append(gpa, input[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }

    /// Returns true if `hay` contains any configured secret or pattern match.
    /// Does not allocate; does not expose match lengths to callers beyond bool.
    pub fn containsSecret(self: *const Redactor, hay: []const u8) bool {
        var i: usize = 0;
        while (i < hay.len) : (i += 1) {
            if (self.matchAt(hay, i) != null) return true;
        }
        return false;
    }

    /// Match length at `pos`, or null. Exact secrets first (longest-first list),
    /// then patterns. Linear; no backtracking.
    fn matchAt(self: *const Redactor, input: []const u8, pos: usize) ?usize {
        const rest = input[pos..];
        for (self.secrets.items) |sec| {
            if (sec.len <= rest.len and std.mem.eql(u8, rest[0..sec.len], sec)) {
                return sec.len;
            }
        }
        if (self.patterns) {
            if (matchPattern(rest)) |n| return n;
        }
        return null;
    }
};

// ── Pattern scanners (linear, prefix-gated, alphabet-bounded) ───────────────

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isGithubPatChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isAwsKeyChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '2' and c <= '7');
}

fn isBearerChar(c: u8) bool {
    // JWT / opaque tokens: base64url-ish.
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '+' or c == '/' or c == '=';
}

/// Consume a run of `pred` chars starting at rest[prefix_len]; require min total
/// token body length after prefix. Returns full match length including prefix.
fn takePrefixedToken(
    rest: []const u8,
    prefix: []const u8,
    min_body: usize,
    comptime pred: *const fn (u8) bool,
) ?usize {
    if (rest.len < prefix.len + min_body) return null;
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    var n: usize = prefix.len;
    while (n < rest.len and pred(rest[n])) : (n += 1) {}
    const body = n - prefix.len;
    if (body < min_body) return null;
    return n;
}

fn matchPattern(rest: []const u8) ?usize {
    // Order: longer / more specific prefixes first.
    // Anthropic: sk-ant-…
    if (takePrefixedToken(rest, "sk-ant-", min_ant_token_len, isTokenChar)) |n| return n;

    // OpenAI / xAI / many gateways: sk-… (not sk-ant, already handled)
    if (takePrefixedToken(rest, "sk-", min_sk_token_len, isTokenChar)) |n| return n;

    // GitHub fine-grained: github_pat_…
    if (takePrefixedToken(rest, "github_pat_", min_github_fine_len, isGithubPatChar)) |n| return n;

    // GitHub classic PATs
    inline for (.{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_" }) |pfx| {
        if (takePrefixedToken(rest, pfx, min_github_pat_len, isGithubPatChar)) |n| return n;
    }

    // AWS access key id: AKIA + exactly 16 body chars (common public shape).
    if (rest.len >= 4 + aws_akia_body_len and std.mem.startsWith(u8, rest, "AKIA")) {
        var n: usize = 4;
        while (n < 4 + aws_akia_body_len) : (n += 1) {
            if (!isAwsKeyChar(rest[n])) return null;
        }
        // Do not extend past fixed length (prevents eating adjacent text).
        return 4 + aws_akia_body_len;
    }

    // Bearer <token> — case-sensitive "Bearer " as in HTTP Authorization.
    if (rest.len >= 7 + min_bearer_token_len and std.mem.startsWith(u8, rest, "Bearer ")) {
        var n: usize = 7;
        while (n < rest.len and isBearerChar(rest[n])) : (n += 1) {}
        const body = n - 7;
        if (body >= min_bearer_token_len) return n;
    }

    return null;
}

/// Redact using an optional redactor. When `r` is null, dupes input unchanged.
/// Fail-closed on OOM.
pub fn redactOptional(
    r: ?*const Redactor,
    gpa: std.mem.Allocator,
    input: []const u8,
) Error![]u8 {
    if (r) |red| return red.redactAlloc(gpa, input);
    return gpa.dupe(u8, input) catch return error.OutOfMemory;
}

// ── Test-only seams (compile out of production) ─────────────────────────────

pub const testing = if (builtin.is_test) struct {
    /// Well-known fake secrets for fixtures only — never real credentials.
    pub const fake_api_key = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    pub const fake_short = "short"; // below min — must be ignored if configured
    pub const fake_anthropic = "sk-ant-api03-fake-anthropic-key-for-tests-only-xx";
    pub const fake_github = "ghp_FakeGitHubPatForZagTestsOnly0123456789AB";
    pub const fake_aws = "AKIAIOSFODNN7EXAMPLE";
    pub const fake_bearer_token = "ya29.fake-Bearer-token-value-for-tests-only";
    pub const fake_xai = "xai-fake-key-for-zag-redaction-tests-00112233";

    pub fn redactorWithFakeKey(gpa: std.mem.Allocator) Error!Redactor {
        return Redactor.init(gpa, .{
            .secrets = &.{fake_api_key},
            .patterns = true,
        });
    }
} else struct {};

comptime {
    if (!builtin.is_test and @hasDecl(testing, "fake_api_key")) {
        @compileError("redact.testing must not exist outside unit tests");
    }
}

// ── Unit tests ──────────────────────────────────────────────────────────────

test "exact secret redacted; marker deterministic" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();

    const raw = "header " ++ testing.fake_api_key ++ " trailer";
    const out = try r.redactAlloc(gpa, raw);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_api_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try std.testing.expectEqualStrings("header " ++ marker ++ " trailer", out);
}

test "empty and short configured secrets ignored" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{
        .secrets = &.{ "", "abc", testing.fake_short },
        .patterns = false,
    });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.secrets.items.len);

    const sample = "uses short word abc in code";
    const out = try r.redactAlloc(gpa, sample);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(sample, out);
}

test "longest secret wins on overlap" {
    const gpa = std.testing.allocator;
    const long = "secret-long-overlap-value-zzzz";
    const short = "secret-long";
    var r = try Redactor.init(gpa, .{ .secrets = &.{ short, long }, .patterns = false });
    defer r.deinit();

    const out = try r.redactAlloc(gpa, "X" ++ long ++ "Y");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("X" ++ marker ++ "Y", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "overlap") == null);
}

test "repeated secrets all redacted" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    const raw = testing.fake_api_key ++ "|" ++ testing.fake_api_key;
    const out = try r.redactAlloc(gpa, raw);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_api_key) == null);
    try std.testing.expectEqualStrings(marker ++ "|" ++ marker, out);
}

test "secret at start and end" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    const a = try r.redactAlloc(gpa, testing.fake_api_key ++ "-tail");
    defer gpa.free(a);
    try std.testing.expectEqualStrings(marker ++ "-tail", a);
    const b = try r.redactAlloc(gpa, "head-" ++ testing.fake_api_key);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("head-" ++ marker, b);
}

test "UTF-8 around secret preserved" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    // "密钥" (key) around secret
    const raw = "密钥" ++ testing.fake_api_key ++ "结束";
    const out = try r.redactAlloc(gpa, raw);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_api_key) == null);
    try std.testing.expect(std.mem.startsWith(u8, out, "密钥"));
    try std.testing.expect(std.mem.endsWith(u8, out, "结束"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "invalid bytes pass through non-secret regions" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    var raw_buf: [128]u8 = undefined;
    const prefix = [_]u8{ 0xFF, 0xFE };
    @memcpy(raw_buf[0..2], &prefix);
    @memcpy(raw_buf[2 .. 2 + testing.fake_api_key.len], testing.fake_api_key);
    raw_buf[2 + testing.fake_api_key.len] = 0x80;
    const raw = raw_buf[0 .. 3 + testing.fake_api_key.len];
    const out = try r.redactAlloc(gpa, raw);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_api_key) == null);
    try std.testing.expectEqual(@as(u8, 0xFF), out[0]);
}

test "pattern: openai/xai sk-, anthropic, github, aws, bearer" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();

    const samples = [_][]const u8{
        "sk-" ++ "a" ** 24,
        testing.fake_anthropic,
        testing.fake_github,
        testing.fake_aws,
        "Bearer " ++ testing.fake_bearer_token,
    };
    for (samples) |s| {
        const out = try r.redactAlloc(gpa, s);
        defer gpa.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, s) == null or std.mem.eql(u8, out, marker) or std.mem.indexOf(u8, out, marker) != null);
        // Full token material must not remain for prefix-shaped secrets.
        if (std.mem.startsWith(u8, s, "Bearer ")) {
            try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_bearer_token) == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, out, s) == null);
        }
    }
}

test "near-miss and code-like strings unchanged" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();

    const near = [_][]const u8{
        "sk-short",
        "sk-notquite",
        "my_api_key",
        "OPENAI_API_KEY",
        "const sk_key = 1",
        "ghp_tooshort",
        "AKIA_SHORT",
        "Bearer short",
        "ask-question",
        "task-ant-hero",
    };
    for (near) |s| {
        const out = try r.redactAlloc(gpa, s);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(s, out);
    }
}

test "redactAlloc OOM is typed" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = true });
    defer r.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const fail_gpa = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, r.redactAlloc(fail_gpa, "x" ++ testing.fake_api_key));
}

test "containsSecret" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    try std.testing.expect(r.containsSecret("a" ++ testing.fake_api_key ++ "b"));
    try std.testing.expect(!r.containsSecret("no secrets here"));
}
