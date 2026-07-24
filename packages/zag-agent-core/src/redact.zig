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
//!   borrowed secret pointer is retained after construction.
//! - **Patterns:** conservative shapes for common API keys/tokens:
//!   OpenAI `sk-…`, Anthropic `sk-ant-…`, xAI `xai-…`, GitHub PATs, AWS
//!   `AKIA`+exactly-16 `[A-Z0-9]` (reject if a 17th body char is allowed),
//!   `Bearer …`. Minimum lengths + restricted alphabets; ordinary identifiers
//!   and code-like near-misses stay intact.
//! - **Matching:** at each byte offset, choose the **global longest** candidate
//!   among all exact secrets and all patterns. Tie-break: prefer exact over
//!   pattern; if still tied, prefer lower secret index / earlier pattern id
//!   (stable). Linear scan — no regex, no backtracking.
//! - **Pattern boundaries:** a pattern match may only start at a token
//!   boundary (start of input or previous byte is not an identifier char).
//!   Token bodies consume the **maximal** run of allowed alphabet chars.
//! - **Complexity:** O(input_len × (sum of configured secret lengths + pattern
//!   prefix checks)); no index structure. Documented honestly.
//! - **Bytes / UTF-8:** matching is **byte-oriented**. Invalid UTF-8 input is
//!   still scanned; callers that require valid UTF-8 (trace) validate as needed.
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
//! - `clone` produces an independent owned copy (for Session ownership).
//! - Concurrent **reads** (`redactAlloc`) are safe when no concurrent mutate.
//! - Freeing secrets does **not** claim cryptographic zeroization.
//! - Test-only seams live under `testing` and compile out of production.
//!
//! ## Low-level bypass
//!
//! Raw `session_store` / `Trace` APIs with a null redactor intentionally skip
//! product redaction. The normal Agent / CLI / session / trace product path
//! always attaches policy and cannot silently bypass it.
//!
//! ## Limits
//!
//! Redaction reduces known-key and shape leakage. It does **not** prove
//! arbitrary tool/file output secret-free. Treat `.zag/` as sensitive local
//! state. Not a DLP product; no zeroization claim.

const std = @import("std");
const builtin = @import("builtin");

/// Deterministic replacement for matched secret material.
pub const marker: []const u8 = "[REDACTED]";

/// Configured secrets shorter than this are ignored (over-redaction guard).
pub const min_configured_secret_len: usize = 8;

/// Pattern minimum body lengths (after prefix; conservative false-positive guard).
pub const min_sk_token_len: usize = 20;
pub const min_ant_token_len: usize = 20;
pub const min_xai_token_len: usize = 20;
pub const min_github_pat_len: usize = 36;
pub const min_github_fine_len: usize = 40;
pub const min_bearer_token_len: usize = 20;
/// AWS access key id: `AKIA` + exactly 16 `[A-Z0-9]`.
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
    /// Owned secret copies (order preserved for stable tie-break).
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

    /// Independent owned copy of secrets + pattern flag (for Session ownership).
    pub fn clone(self: *const Redactor, gpa: std.mem.Allocator) Error!Redactor {
        var out: Redactor = .{
            .gpa = gpa,
            .patterns = self.patterns,
        };
        errdefer out.deinit();
        for (self.secrets.items) |s| {
            // Bypass min-length filter: already filtered on original.
            const owned = gpa.dupe(u8, s) catch return error.OutOfMemory;
            errdefer gpa.free(owned);
            try out.secrets.append(gpa, owned);
        }
        return out;
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
    }

    /// Allocate a redacted copy of `input`. On no match, returns a dupe of input.
    /// Fail-closed: OOM returns `error.OutOfMemory` (never a raw borrow).
    pub fn redactAlloc(self: *const Redactor, gpa: std.mem.Allocator, input: []const u8) Error![]u8 {
        if (input.len == 0) {
            return gpa.dupe(u8, input) catch return error.OutOfMemory;
        }

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
    pub fn containsSecret(self: *const Redactor, hay: []const u8) bool {
        var i: usize = 0;
        while (i < hay.len) : (i += 1) {
            if (self.matchAt(hay, i) != null) return true;
        }
        return false;
    }

    /// Global longest match at `pos` across all exact secrets and patterns.
    /// Tie: prefer exact over pattern; among exact, lower index; among patterns,
    /// lower pattern id. Returns match length or null.
    fn matchAt(self: *const Redactor, input: []const u8, pos: usize) ?usize {
        const rest = input[pos..];
        var best_len: usize = 0;
        var best_is_exact: bool = false;
        var best_idx: usize = std.math.maxInt(usize);

        // Exact secrets (match anywhere — no token boundary).
        for (self.secrets.items, 0..) |sec, idx| {
            if (sec.len == 0 or sec.len > rest.len) continue;
            if (!std.mem.eql(u8, rest[0..sec.len], sec)) continue;
            if (sec.len > best_len or (sec.len == best_len and (!best_is_exact or idx < best_idx))) {
                best_len = sec.len;
                best_is_exact = true;
                best_idx = idx;
            }
        }

        // Patterns only at token boundaries.
        if (self.patterns and isPatternBoundary(input, pos)) {
            if (matchPatternBest(rest)) |cand| {
                if (cand.len > best_len or (cand.len == best_len and !best_is_exact and cand.id < best_idx)) {
                    best_len = cand.len;
                    best_is_exact = false;
                    best_idx = cand.id;
                }
            }
        }

        if (best_len == 0) return null;
        return best_len;
    }
};

// ── Pattern scanners (linear, prefix-gated, alphabet-bounded) ───────────────

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Pattern may start only at start-of-input or after a non-identifier byte.
fn isPatternBoundary(input: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    return !isIdentChar(input[pos - 1]);
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isGithubPatChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isAwsKeyChar(c: u8) bool {
    // Documented grammar: [A-Z0-9]
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

fn isBearerChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '+' or c == '/' or c == '=';
}

const PatternCand = struct { len: usize, id: usize };

/// Consume maximal run of `pred` after `prefix`; require `min_body` body chars.
fn takePrefixedToken(
    rest: []const u8,
    prefix: []const u8,
    min_body: usize,
    comptime pred: *const fn (u8) bool,
    id: usize,
) ?PatternCand {
    if (rest.len < prefix.len + min_body) return null;
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    var n: usize = prefix.len;
    while (n < rest.len and pred(rest[n])) : (n += 1) {}
    const body = n - prefix.len;
    if (body < min_body) return null;
    return .{ .len = n, .id = id };
}

/// Best pattern match at rest[0] (caller already checked left boundary).
fn matchPatternBest(rest: []const u8) ?PatternCand {
    var best: ?PatternCand = null;

    const consider = struct {
        fn call(b: *?PatternCand, c: ?PatternCand) void {
            const cand = c orelse return;
            if (b.*) |cur| {
                if (cand.len > cur.len or (cand.len == cur.len and cand.id < cur.id)) {
                    b.* = cand;
                }
            } else {
                b.* = cand;
            }
        }
    }.call;

    // ids are stable priorities for equal-length ties.
    // Anthropic before generic sk- (more specific prefix; also longer when both match).
    consider(&best, takePrefixedToken(rest, "sk-ant-", min_ant_token_len, isTokenChar, 0));
    consider(&best, takePrefixedToken(rest, "sk-", min_sk_token_len, isTokenChar, 1));
    consider(&best, takePrefixedToken(rest, "xai-", min_xai_token_len, isTokenChar, 2));
    consider(&best, takePrefixedToken(rest, "github_pat_", min_github_fine_len, isGithubPatChar, 3));
    inline for (.{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_" }, 0..) |pfx, i| {
        consider(&best, takePrefixedToken(rest, pfx, min_github_pat_len, isGithubPatChar, 4 + i));
    }

    // AWS: AKIA + exactly 16 [A-Z0-9]; reject if a 17th body char is allowed.
    if (rest.len >= 4 + aws_akia_body_len and std.mem.startsWith(u8, rest, "AKIA")) {
        var ok = true;
        var n: usize = 4;
        while (n < 4 + aws_akia_body_len) : (n += 1) {
            if (!isAwsKeyChar(rest[n])) {
                ok = false;
                break;
            }
        }
        if (ok) {
            // Overlong: next char still in alphabet → not a fixed key id.
            if (rest.len > 4 + aws_akia_body_len and isAwsKeyChar(rest[4 + aws_akia_body_len])) {
                ok = false;
            }
        }
        if (ok) {
            consider(&best, .{ .len = 4 + aws_akia_body_len, .id = 20 });
        }
    }

    // Bearer <token>
    if (rest.len >= 7 + min_bearer_token_len and std.mem.startsWith(u8, rest, "Bearer ")) {
        var n: usize = 7;
        while (n < rest.len and isBearerChar(rest[n])) : (n += 1) {}
        const body = n - 7;
        if (body >= min_bearer_token_len) {
            consider(&best, .{ .len = n, .id = 21 });
        }
    }

    return best;
}

/// Redact using an optional redactor. When `r` is null, dupes input unchanged.
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
    pub const fake_api_key = "sk-test-fake-secret-key-NOT-REAL-aabbccddee112233";
    pub const fake_short = "short";
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

test "longest secret wins on exact overlap" {
    const gpa = std.testing.allocator;
    const long = "secret-long-overlap-value-zzzz";
    const short = "secret-long";
    var r = try Redactor.init(gpa, .{ .secrets = &.{ short, long }, .patterns = false });
    defer r.deinit();
    const out = try r.redactAlloc(gpa, "X" ++ long ++ "Y");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("X" ++ marker ++ "Y", out);
}

test "exact vs longer pattern: global longest wins" {
    const gpa = std.testing.allocator;
    // Exact secret is a short prefix of a longer sk- pattern token.
    const exact = "sk-shortx"; // 9 chars, >= min configured
    // Full pattern token is longer.
    const full = "sk-" ++ "b" ** 24;
    try std.testing.expect(std.mem.startsWith(u8, full, "sk-"));
    var r = try Redactor.init(gpa, .{ .secrets = &.{exact}, .patterns = true });
    defer r.deinit();
    // When full pattern present, pattern is longer than exact "sk-shortx" which isn't a prefix of full.
    const out_full = try r.redactAlloc(gpa, full);
    defer gpa.free(out_full);
    try std.testing.expectEqualStrings(marker, out_full);

    // Construct a string where exact is a proper prefix of a longer pattern match:
    // exact secret = first 9 of a long sk- body that also matches pattern.
    const long_body = "sk-shortx" ++ "yyyyyyyyyyyyyyy"; // sk- + 24 body → pattern length 27
    try std.testing.expect(long_body.len > exact.len);
    const out = try r.redactAlloc(gpa, long_body);
    defer gpa.free(out);
    // Global longest is the full pattern, not the short exact.
    try std.testing.expectEqualStrings(marker, out);
    try std.testing.expect(std.mem.indexOf(u8, out, "yyyy") == null);
}

test "pattern left boundary: embedded in identifier unchanged" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();
    // Pattern prefix starts mid-identifier → no match.
    const embedded = "my" ++ ("sk-" ++ "a" ** 24);
    const out = try r.redactAlloc(gpa, embedded);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(embedded, out);

    // After non-ident boundary → match.
    const ok = "x " ++ ("sk-" ++ "a" ** 24);
    const out2 = try r.redactAlloc(gpa, ok);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("x " ++ marker, out2);
}

test "pattern min-1 / min / min+1 body lengths" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();
    const min1 = "sk-" ++ "a" ** (min_sk_token_len - 1);
    const min0 = "sk-" ++ "a" ** min_sk_token_len;
    const minp = "sk-" ++ "a" ** (min_sk_token_len + 1);
    const o1 = try r.redactAlloc(gpa, min1);
    defer gpa.free(o1);
    try std.testing.expectEqualStrings(min1, o1);
    const o0 = try r.redactAlloc(gpa, min0);
    defer gpa.free(o0);
    try std.testing.expectEqualStrings(marker, o0);
    const op = try r.redactAlloc(gpa, minp);
    defer gpa.free(op);
    try std.testing.expectEqualStrings(marker, op);
}

test "AWS fixed form: digits 0/1/8/9 allowed; overlong rejected" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();
    // Valid with 0,1,8,9
    const valid = "AKIA" ++ "A0B1C8D9E2F3G4H5";
    try std.testing.expectEqual(@as(usize, 20), valid.len);
    const ov = try r.redactAlloc(gpa, valid);
    defer gpa.free(ov);
    try std.testing.expectEqualStrings(marker, ov);

    // Overlong 21st body char → no match (do not redact first 20).
    const over = valid ++ "Z";
    const oo = try r.redactAlloc(gpa, over);
    defer gpa.free(oo);
    try std.testing.expectEqualStrings(over, oo);

    // Adjacent non-body char OK after fixed key.
    const adj = valid ++ "-tail";
    const oa = try r.redactAlloc(gpa, adj);
    defer gpa.free(oa);
    try std.testing.expectEqualStrings(marker ++ "-tail", oa);
}

test "xai- pattern and all common shapes" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();
    const samples = [_][]const u8{
        "sk-" ++ "a" ** 24,
        testing.fake_anthropic,
        testing.fake_xai,
        testing.fake_github,
        "github_pat_" ++ "A" ** 40,
        "gho_" ++ "B" ** 36,
        testing.fake_aws,
        "Bearer " ++ testing.fake_bearer_token,
    };
    for (samples) |s| {
        const out = try r.redactAlloc(gpa, s);
        defer gpa.free(out);
        if (std.mem.startsWith(u8, s, "Bearer ")) {
            try std.testing.expect(std.mem.indexOf(u8, out, testing.fake_bearer_token) == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, out, s) == null);
            try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
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
        "xai-short",
    };
    for (near) |s| {
        const out = try r.redactAlloc(gpa, s);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(s, out);
    }
}

test "copy ownership after source mutation" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, testing.fake_api_key);
    defer gpa.free(buf);
    var r = try Redactor.init(gpa, .{ .secrets = &.{buf}, .patterns = false });
    defer r.deinit();
    // Mutate source after init — redactor must keep its copy.
    @memset(buf, 'X');
    const out = try r.redactAlloc(gpa, "pre-" ++ testing.fake_api_key ++ "-post");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("pre-" ++ marker ++ "-post", out);
}

test "clone independent of original" {
    const gpa = std.testing.allocator;
    var a = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = true });
    var b = try a.clone(gpa);
    defer b.deinit();
    a.deinit();
    const out = try b.redactAlloc(gpa, testing.fake_api_key);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(marker, out);
}

test "FailingAllocator init/add/redact no raw fallback" {
    const gpa = std.testing.allocator;
    // init OOM on first secret dupe
    {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, Redactor.init(failing.allocator(), .{
            .secrets = &.{testing.fake_api_key},
            .patterns = false,
        }));
    }
    // redactAlloc OOM
    {
        var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = true });
        defer r.deinit();
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, r.redactAlloc(failing.allocator(), testing.fake_api_key));
    }
    // addSecret OOM
    {
        var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = false });
        defer r.deinit();
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        r.gpa = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, r.addSecret(testing.fake_api_key));
        r.gpa = gpa; // restore for deinit
    }
}

test "repeated adjacent secrets; invalid UTF-8 regions" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    const raw = testing.fake_api_key ++ testing.fake_api_key;
    const out = try r.redactAlloc(gpa, raw);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(marker ++ marker, out);

    var raw_buf: [128]u8 = undefined;
    @memcpy(raw_buf[0..2], &[_]u8{ 0xFF, 0xFE });
    @memcpy(raw_buf[2 .. 2 + testing.fake_api_key.len], testing.fake_api_key);
    raw_buf[2 + testing.fake_api_key.len] = 0x80;
    const inv = raw_buf[0 .. 3 + testing.fake_api_key.len];
    const o2 = try r.redactAlloc(gpa, inv);
    defer gpa.free(o2);
    try std.testing.expect(std.mem.indexOf(u8, o2, testing.fake_api_key) == null);
}

test "containsSecret" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{testing.fake_api_key}, .patterns = false });
    defer r.deinit();
    try std.testing.expect(r.containsSecret("a" ++ testing.fake_api_key ++ "b"));
    try std.testing.expect(!r.containsSecret("no secrets here"));
}

fn tryInitAddCloneRedact(fa: std.mem.Allocator, secret: []const u8) Error![]u8 {
    var r = try Redactor.init(fa, .{ .secrets = &.{secret}, .patterns = true });
    errdefer r.deinit();
    const extra = try std.fmt.allocPrint(fa, "{s}-extra-suffix-zzzz", .{secret});
    defer fa.free(extra);
    try r.addSecret(extra);
    var c = try r.clone(fa);
    errdefer c.deinit();
    const hay = try std.fmt.allocPrint(fa, "x{s}y", .{secret});
    defer fa.free(hay);
    const out = try c.redactAlloc(fa, hay);
    c.deinit();
    r.deinit();
    return out;
}

test "FailingAllocator per-index helper covers init/add/clone/redact" {
    const gpa = std.testing.allocator;
    const secret = testing.fake_api_key;
    var saw_fail = false;
    var idx: usize = 0;
    while (idx < 96) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = idx });
        const fa = failing.allocator();
        if (tryInitAddCloneRedact(fa, secret)) |out| {
            defer fa.free(out);
            try std.testing.expect(std.mem.indexOf(u8, out, secret) == null);
            if (idx > 0) try std.testing.expect(saw_fail);
            return;
        } else |_| {
            saw_fail = true;
        }
    }
    return error.TestUnexpectedResult;
}

test "pattern matrix: each family min boundary and max-run" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{}, .patterns = true });
    defer r.deinit();

    const Case = struct { raw: []const u8, expect_redact: bool };
    const cases = [_]Case{
        // sk-
        .{ .raw = "sk-" ++ "a" ** (min_sk_token_len - 1), .expect_redact = false },
        .{ .raw = "sk-" ++ "a" ** min_sk_token_len, .expect_redact = true },
        .{ .raw = "pre" ++ ("sk-" ++ "a" ** min_sk_token_len), .expect_redact = false }, // mid-ident
        .{ .raw = " " ++ ("sk-" ++ "a" ** min_sk_token_len), .expect_redact = true },
        // sk-ant- (body short enough that generic sk- also misses)
        .{ .raw = "sk-ant-" ++ "b" ** 12, .expect_redact = false },
        .{ .raw = "sk-ant-" ++ "b" ** min_ant_token_len, .expect_redact = true },
        // xai-
        .{ .raw = "xai-" ++ "c" ** (min_xai_token_len - 1), .expect_redact = false },
        .{ .raw = "xai-" ++ "c" ** min_xai_token_len, .expect_redact = true },
        // ghp_
        .{ .raw = "ghp_" ++ "d" ** (min_github_pat_len - 1), .expect_redact = false },
        .{ .raw = "ghp_" ++ "d" ** min_github_pat_len, .expect_redact = true },
        // github_pat_
        .{ .raw = "github_pat_" ++ "e" ** (min_github_fine_len - 1), .expect_redact = false },
        .{ .raw = "github_pat_" ++ "e" ** min_github_fine_len, .expect_redact = true },
        // Bearer
        .{ .raw = "Bearer " ++ "f" ** (min_bearer_token_len - 1), .expect_redact = false },
        .{ .raw = "Bearer " ++ "f" ** min_bearer_token_len, .expect_redact = true },
        // AWS
        .{ .raw = "AKIA" ++ "A" ** 15, .expect_redact = false },
        .{ .raw = "AKIA" ++ "A" ** 16, .expect_redact = true },
        .{ .raw = "AKIA" ++ "A" ** 17, .expect_redact = false },
    };
    for (cases) |c| {
        const out = try r.redactAlloc(gpa, c.raw);
        defer gpa.free(out);
        if (c.expect_redact) {
            try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
            // Secret body should not remain fully.
            if (c.raw.len > 8) {
                try std.testing.expect(std.mem.indexOf(u8, out, c.raw) == null);
            }
        } else {
            try std.testing.expectEqualStrings(c.raw, out);
        }
    }
}

test "short configured secret never matches" {
    const gpa = std.testing.allocator;
    var r = try Redactor.init(gpa, .{ .secrets = &.{"shorty"}, .patterns = false });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.secrets.items.len);
    const out = try r.redactAlloc(gpa, "shorty shorty");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("shorty shorty", out);
}
