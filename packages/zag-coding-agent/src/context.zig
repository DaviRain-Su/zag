//! Context window policy — product-owned prompt layers, budget, and
//! fixed-point compaction (H4 / h-context-001 / D-011 core-context-ownership-001).
//!
//! **Transcript is authoritative.** Compaction never deletes transcript rows;
//! it only shapes the model **view** and may return a `CompactionEvent` for
//! session metadata / trace.
//!
//! Protocol-history validation (Tool-call/result bundle legality) is owned by
//! Core (`protocol_history.zig`); this module calls it and adds product-owned
//! prompt layers, token/character budget, fixed-point compaction, and
//! summary/lineage.
//!
//! `CompactionEvent` and `View` are the single authoritative definitions in
//! Core `context_view.zig`; this module aliases them and never redefines them.
//!
//! Four prompt layers (assembled into leading `system` messages in the view):
//! system → project → session → ephemeral, then the selected history tail.
//! Leading `system` rows already in the transcript are skipped to avoid
//! duplicating product-layer prompts.
//!
//! ## Final-view accounting (L2)
//!
//! `viewForModel` uses a **deterministic fixed-point** over the absolute body
//! start index:
//! 1. Tolerant drop-only repair + duplicate-result dedup (combined pre-gate)
//!    on the scratch view — `validateBodyHistory` stays authoritative.
//! 2. Fail-closed validate body tool-call bundles (exact IDs, call order).
//! 3. Token-budget truncate from the front (`session_item.truncateForPrompt`,
//!    budget from `effectiveTokenBudget`), then the historical count cap
//!    (`max_tail_messages`) and legal Tool-bundle alignment.
//! 4. Soft char-trim under current layer cost, advancing by atomic units
//!    (assistant+all results, or a single non-bundle message).
//! 5. Build a summary for the omitted body prefix (with prior-session lineage).
//! 6. Re-cost layers with that summary as the session layer.
//! 7. If over budget, advance by another legal unit and rebuild; repeat until
//!    stable.
//! 8. Emit one final `CompactionEvent` whose `dropped` equals the final
//!    omitted body prefix length and whose summary describes that set.
//!
//! Soft budget / min-tail: when further trim would drop below
//! `min_tail_messages` or no legal unit advance exists, the loop
//! **terminates honestly** even if still over `max_chars`.
//!
//! ## Complexity
//!
//! Iteration is bounded by `body.len + 1` (each progress step advances the
//! absolute start by ≥1 message). Each iteration may rescan the remaining
//! tail for char estimates and rebuild a summary over the omitted prefix, so
//! worst-case work is **O(n²)** in body length — bounded, not unbounded
//! restart. Callers must not assume linear cost for pathological long bodies.
//!
//! ## Generation / lineage
//!
//! `Session.compaction_gen` increments once per **successfully accepted**
//! final event (`noteCompaction` success). A new summary always accounts for
//! the prior session summary: exact prior bytes when they fit under the shared
//! cap residual; otherwise an explicit truncated lineage record (original
//! length, kept length, wyhash64 digest, `LINEAGE_TRUNCATED` marker).
//!
//! ## Session vs trace equality
//!
//! On the **success path** (session note + trace emit both succeed), session
//! meta and the trace compaction event carry the same final `dropped` and
//! summary bytes (≤ `summary_cap`). Session note runs first; sink OOM aborts
//! before any compaction line. If note succeeds and a later mid-run **trace
//! emit** fails, the in-memory session may already hold the new gen/summary
//! while the durable/trace compaction line is absent — that path is a run
//! failure (`TraceFailed`/`OutOfMemory`), not a silent success. Equality is
//! not claimed as transactional across that failure.

const std = @import("std");
const core = @import("zag-agent-core");
const ztypes = @import("zag-types");
const message = core.message;
const context_view = core.context_view;
const protocol_history = core.protocol_history;
const session_item = core.session_item;

/// Shared hard cap for heuristic compaction summaries (session + trace + view).
/// Built events never exceed this after clamp.
pub const summary_cap: usize = 800;

/// Default / alias for `Options.summary_max_chars` and trace field cap.
pub const default_summary_max_chars: usize = summary_cap;

/// Explicit truncation marker embedded in lineage records (never silent).
pub const lineage_truncated_marker = "[LINEAGE_TRUNCATED]";

/// Single authoritative compaction fact type (Core `context_view.zig`).
pub const CompactionEvent = context_view.CompactionEvent;

/// Single authoritative context view type (Core `context_view.zig`).
pub const View = context_view.View;

// compaction-llm-001: the summarizer seam types are authored in L0
// (`zag-types`) so Core's `session_item.summarizeWithRetry` and this product
// module can both reference them without a Core → product import (D-011).
// The concrete provider impl lives in `agent.zig`.
pub const SummaryErrorKind = ztypes.SummaryErrorKind;
pub const SummaryRequest = ztypes.SummaryRequest;
pub const SummaryResult = ztypes.SummaryResult;
pub const CompactionSummarizerVTable = ztypes.CompactionSummarizerVTable;
pub const CompactionSummarizer = ztypes.CompactionSummarizer;

pub const Error = error{
    OutOfMemory,
    /// Malformed tool-call/result history or other fail-closed context policy.
    InvalidContext,
};

pub const Options = struct {
    /// Max non-system history messages kept from the tail (0 = unlimited count).
    max_tail_messages: usize = 48,
    /// Soft char budget across the whole view (0 = unlimited).
    max_chars: usize = 120_000,
    /// Token budget for the Stage-A truncate (0 = derive from `max_chars / 4`,
    /// consistent with the `len / 4` estimator; when `max_chars` is also 0 the
    /// budget is unlimited). Internal knob only — no user-facing config
    /// option in v1 (the CLI derives it from the char budget automatically).
    max_tokens: usize = 0,
    /// Never drop below this many history messages from the end.
    min_tail_messages: usize = 6,
    /// Requested max chars for the heuristic summary. Clamped to `summary_cap`.
    /// `0` means use `summary_cap`. Tiny values raise to a floor that always
    /// holds the dropped-count header and, when a prior session summary exists,
    /// a minimal truncated lineage record (prior_bytes/kept_bytes=0/digest/marker).
    summary_max_chars: usize = default_summary_max_chars,

    /// Optional LLM compaction summarizer (compaction-llm-001). Null → the
    /// pure heuristic `buildSummary` path, byte-identical to pre-LLM
    /// behavior. When set, the LLM summary (subject to the same budget /
    /// UTF-8 clamps as heuristic summaries) replaces the heuristic text in
    /// the compaction event + session layer; any failure falls back.
    summarizer: ?CompactionSummarizer = null,

    /// Effective summary budget after clamp to the shared cap and content floor.
    /// Floor uses **sanitized** prior UTF-8 byte length (same as `prior_bytes` /
    /// digest input in lineage), not raw prior length.
    pub fn effectiveSummaryMax(self: Options, dropped_count: usize, prior_session: []const u8) usize {
        return clampSummaryBudget(self.summary_max_chars, dropped_count, prior_session);
    }

    /// Effective token budget for the Stage-A truncate: explicit `max_tokens`
    /// wins; else derived from the char budget (`max_chars / 4`); `0` (both
    /// unset) = unlimited. The budget covers the non-system history body only
    /// (layer/summary costs keep their own char accounting).
    pub fn effectiveTokenBudget(self: Options) usize {
        if (self.max_tokens > 0) return self.max_tokens;
        if (self.max_chars > 0) return self.max_chars / 4;
        return std.math.maxInt(usize);
    }
};

/// Four prompt layers (H4). Empty slices are omitted from the view.
pub const Layers = struct {
    system: []const u8 = "",
    project: []const u8 = "",
    session: []const u8 = "",
    ephemeral: []const u8 = "",
};

/// Build context options from a char budget + optional file overrides.
pub fn optionsFromBudget(
    budget_chars: ?usize,
    overrides: struct {
        max_chars: ?usize = null,
        max_tail_messages: ?usize = null,
        min_tail_messages: ?usize = null,
        max_tokens: ?usize = null,
    },
) Options {
    const defaults = Options{};
    return .{
        .max_chars = overrides.max_chars orelse (budget_chars orelse defaults.max_chars),
        .max_tail_messages = overrides.max_tail_messages orelse defaults.max_tail_messages,
        .min_tail_messages = overrides.min_tail_messages orelse defaults.min_tail_messages,
        .max_tokens = overrides.max_tokens orelse defaults.max_tokens,
    };
}

/// Clamp requested summary budget: 0 → full cap; always ≤ `summary_cap`; at least
/// `summaryFloor` so the dropped header (and minimal lineage when prior exists)
/// cannot be lost to a tiny request. No reliance on debug asserts for cap.
pub fn clampSummaryBudget(requested: usize, dropped_count: usize, prior_session: []const u8) usize {
    const floor = summaryFloor(dropped_count, prior_session);
    const base: usize = if (requested == 0) summary_cap else requested;
    const capped = @min(base, summary_cap);
    if (capped >= floor) return capped;
    return floor; // floor is already ≤ summary_cap
}

/// Minimum summary bytes for a complete dropped header and, when prior is
/// non-empty, a minimal truncated lineage record whose `prior_bytes` field width
/// matches **sanitized** UTF-8 length (U+FFFD expansion). Always ≤ `summary_cap`.
pub fn summaryFloor(dropped_count: usize, prior_session: []const u8) usize {
    const hdr = droppedHeaderLen(dropped_count);
    if (prior_session.len == 0) return @min(hdr, summary_cap);
    const san_len = utf8SanitizedByteLen(prior_session);
    const lin = minimalTruncatedLineageLen(san_len);
    const floor = hdr +| lin;
    return @min(floor, summary_cap);
}

fn droppedHeaderLen(dropped_count: usize) usize {
    // "[compaction] {d} earlier messages omitted from the model view.\n"
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "[compaction] {d} earlier messages omitted from the model view.\n", .{dropped_count}) catch {
        return 80;
    };
    return s.len;
}

fn decimalDigits(n: usize) usize {
    if (n < 10) return 1;
    var d: usize = 0;
    var x = n;
    while (x > 0) : (x /= 10) d += 1;
    return d;
}

/// Length of the minimal truncated lineage record (no kept prefix), with
/// fixed-width 16-digit hex digest. `prior_sanitized_len` is the byte length
/// after UTF-8 sanitization (same value written as `prior_bytes=`).
/// Uses saturating adds so external lengths cannot wrap the total.
pub fn minimalTruncatedLineageLen(prior_sanitized_len: usize) usize {
    // Prior session context (truncated):\n
    // prior_bytes=N kept_bytes=0 digest=wyhash64:HHHHHHHHHHHHHHHH\n
    // [LINEAGE_TRUNCATED]\n
    var n: usize = "Prior session context (truncated):\n".len;
    n +|= "prior_bytes=".len;
    n +|= decimalDigits(prior_sanitized_len);
    n +|= " kept_bytes=0 digest=wyhash64:".len;
    n +|= 16;
    n +|= 1; // '\n'
    n +|= lineage_truncated_marker.len;
    n +|= 1; // '\n'
    return n;
}

/// Byte length of `s` after the same U+FFFD sanitization as `sanitizeUtf8`,
/// without allocating. Uses saturating adds so pathological input cannot wrap.
/// Valid UTF-8 returns `s.len` unchanged.
///
/// Bound checks use `seq_len > s.len - i` (with invariant `i <= s.len`) rather
/// than `i + seq_len > s.len` to avoid overflow on the addition.
pub fn utf8SanitizedByteLen(s: []const u8) usize {
    if (std.unicode.utf8ValidateSlice(s)) return s.len;
    const fffd_len: usize = "\u{FFFD}".len; // 3
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            n +|= fffd_len;
            i += 1;
            continue;
        };
        // Invariant: i <= s.len. Prefer subtractive bound check.
        if (seq_len > s.len - i) {
            n +|= fffd_len;
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
            n +|= fffd_len;
            i += 1;
            continue;
        };
        n +|= seq_len;
        i += seq_len;
    }
    return n;
}

/// True when `room` can hold `prefix || payload || '\n'` without overflowing adds.
fn fitsExactLineage(room: usize, prefix_len: usize, payload_len: usize) bool {
    if (room <= prefix_len) return false;
    const after_prefix = room - prefix_len;
    // Need payload and a trailing newline.
    if (after_prefix <= payload_len) return false;
    return after_prefix - payload_len >= 1;
}

/// Build a model-facing view with four layers + history tail.
/// Allocates synthetic system strings and the message slice on `arena`.
///
/// When all layer strings are empty, falls back to keeping leading transcript
/// `system` rows (compat with tests / callers that only seed the transcript).
///
/// `io` is required for the compaction summarizer's retry ladder sleeps
/// (compaction-llm-001); unused when `opts.summarizer == null`.
///
/// Returns `error.InvalidContext` before any provider-facing view when body
/// tool-call/result bundles are malformed (fail-closed).
pub fn viewForModel(
    io: std.Io,
    arena: std.mem.Allocator,
    full: []const message.Message,
    opts: Options,
    layers: Layers,
) Error!View {
    const use_layers = layers.system.len > 0 or layers.project.len > 0 or
        layers.session.len > 0 or layers.ephemeral.len > 0;

    var hist_start: usize = 0;
    while (hist_start < full.len and full[hist_start].role == .system) : (hist_start += 1) {}
    const transcript_systems = full[0..hist_start];
    const body = full[hist_start..];

    // --- Stage A: tolerant repair + dedup (combined pre-gate, view-only, drop-only) ---
    // Repair drops orphan/empty-carrier tool rows; dedup collapses repeated
    // tool_call_id result rows (keep-last). Both run on the scratch view
    // (never the transcript); the dedup output feeds the authoritative gate.
    const repaired = (try session_item.repairDanglingToolCalls(arena, body)) orelse body;
    const working = (try session_item.dedupDuplicateToolResults(arena, repaired)) orelse repaired;

    // Fail closed on malformed tool bundles after repair+dedup (authoritative
    // gate): incomplete bundles, out-of-order results, duplicate/empty call
    // ids and leading-system-without-tail still reject here.
    protocol_history.validateBodyHistory(working) catch return error.InvalidContext;

    var start: usize = 0;
    const trunc = try session_item.truncateForPrompt(
        arena,
        working,
        opts.effectiveTokenBudget(),
        opts.min_tail_messages,
    );
    start = trunc.dropped;
    // Historical count cap: still a hard row limit on the kept tail.
    if (opts.max_tail_messages > 0 and working.len - start > opts.max_tail_messages) {
        start = working.len - opts.max_tail_messages;
        start = protocol_history.alignToLegalStart(working, start) catch return error.InvalidContext;
    }

    // No separate pruning stage: `truncateForPrompt` already performs
    // whole-bundle head trims under the token budget (chat-state-prune-001:
    // a prune pass would be behaviorally identical under drop-only law).
    const post_cap = working[start..];
    const prefix_dropped = start;

    // Layer cost without a new compaction summary (prior session layer may exist).
    var layer_chars: usize = if (use_layers)
        layerEstimate(layers, null)
    else
        estimateChars(transcript_systems);

    // --- Stage B: soft char trim under current layer cost ---
    var tail_start: usize = 0; // index into `post_cap`
    tail_start = try charTrimStart(post_cap, tail_start, layer_chars, opts);

    // --- Stage C: fixed-point — summary insertion may force further legal trims ---
    var compaction: ?CompactionEvent = null;
    var session_layer = layers.session;

    if (prefix_dropped > 0 or tail_start > 0) {
        const max_iters = post_cap.len + 1;
        var iter: usize = 0;
        while (iter < max_iters) : (iter += 1) {
            const dropped = prefix_dropped + tail_start;
            const budget = opts.effectiveSummaryMax(dropped, layers.session);
            // Omitted set = truncate/cap prefix + char-trim prefix of the
            // post-cap view — contiguous in `working` (post_cap starts at
            // prefix_dropped), so no copy is needed.
            const omitted = working[0 .. prefix_dropped + tail_start];
            const summary = try buildSummary(
                arena,
                omitted,
                budget,
                dropped,
                layers.session,
            );
            std.debug.assert(summary.len <= summary_cap);
            std.debug.assert(summary.len <= budget);

            if (use_layers) {
                layer_chars = layerEstimate(layers, summary);
            } else {
                layer_chars = estimateChars(transcript_systems) + summary.len + 64;
            }

            const before = tail_start;
            tail_start = try charTrimStart(post_cap, tail_start, layer_chars, opts);
            if (tail_start == before) {
                compaction = .{ .dropped = dropped, .summary = summary };
                session_layer = summary;
                break;
            }
        } else {
            const dropped = prefix_dropped + tail_start;
            const budget = opts.effectiveSummaryMax(dropped, layers.session);
            const omitted = working[0 .. prefix_dropped + tail_start];
            const summary = try buildSummary(
                arena,
                omitted,
                budget,
                dropped,
                layers.session,
            );
            compaction = .{ .dropped = dropped, .summary = summary };
            session_layer = summary;
        }
    }

    // compaction-llm-001: with a configured summarizer, run ONE LLM
    // summarization over the final omitted set and replace the heuristic text
    // in the compaction event + session layer (same slot, same shape). The
    // fixed-point already converged on the heuristic summary, so this is a
    // single provider call per view; any failure keeps the heuristic bytes.
    if (compaction) |ev| {
        if (opts.summarizer) |summarizer| {
            const omitted = working[0..ev.dropped];
            // OOM during LLM summarization falls back to the heuristic text
            // (turn continues; noteCompaction OOM atomicity untouched).
            const text = summarizeOmitted(io, arena, summarizer, omitted, layers.session, ev.dropped, opts) catch |err| switch (err) {
                error.OutOfMemory => null,
            };
            if (text) |t| {
                compaction = .{ .dropped = ev.dropped, .summary = t };
                session_layer = t;
            }
        }
    }

    const selected = post_cap[tail_start..];
    // Selected tail starts at a legal boundary when body is valid.
    if (selected.len > 0 and selected[0].role == .tool) return error.InvalidContext;

    if (use_layers) {
        const layer_msgs = try buildLayerMessages(arena, layers, session_layer);
        const out_len = layer_msgs.len + selected.len;
        const out = try arena.alloc(message.Message, out_len);
        @memcpy(out[0..layer_msgs.len], layer_msgs);
        @memcpy(out[layer_msgs.len..], selected);
        return .{ .messages = out, .compaction = compaction };
    }

    const need_note = compaction != null;
    const out_len = transcript_systems.len + selected.len + @as(usize, if (need_note) 1 else 0);
    const out = try arena.alloc(message.Message, out_len);
    var i: usize = 0;
    for (transcript_systems) |m| {
        out[i] = m;
        i += 1;
    }
    if (compaction) |ev| {
        const note = try std.fmt.allocPrint(arena,
            \\# Session context
            \\
            \\{s}
        , .{ev.summary});
        out[i] = message.Message.system(note);
        i += 1;
    }
    for (selected) |m| {
        out[i] = m;
        i += 1;
    }
    return .{ .messages = out, .compaction = compaction };
}

/// Soft char-trim: advance absolute `start` by atomic legal units while over
/// budget, respecting `min_tail_messages`.
fn charTrimStart(
    body: []const message.Message,
    start_in: usize,
    layer_chars: usize,
    opts: Options,
) error{InvalidContext}!usize {
    var start = start_in;
    if (opts.max_chars == 0) return start;
    while (body.len - start > opts.min_tail_messages) {
        const selected = body[start..];
        const total = layer_chars + estimateChars(selected);
        if (total <= opts.max_chars) break;
        const next = protocol_history.unitEnd(body, start);
        if (next <= start or next > body.len) break;
        // Keep min_tail messages; unit may span multiple messages.
        if (body.len - next < opts.min_tail_messages) break;
        start = next;
    }
    return start;
}

/// Compute the body start after Stage A (token-budget truncate + count cap +
/// legal align) with no char/summary re-cost.
///
/// `session_item.truncateForPrompt` performs no allocation; `page_allocator`
/// is a placeholder for its allocator parameter.
pub fn initialTrimStart(body: []const message.Message, opts: Options) error{InvalidContext}!usize {
    var start: usize = 0;
    const trunc = try session_item.truncateForPrompt(
        std.heap.page_allocator,
        body,
        opts.effectiveTokenBudget(),
        opts.min_tail_messages,
    );
    start = trunc.dropped;
    if (opts.max_tail_messages > 0 and body.len - start > opts.max_tail_messages) {
        start = body.len - opts.max_tail_messages;
        start = protocol_history.alignToLegalStart(body, start) catch return error.InvalidContext;
    }
    return start;
}

/// Stage-A trim + first-pass char trim without summary re-cost (legacy
/// intermediate for fixed-point assertions).
pub fn intermediateDroppedBeforeSummary(
    full: []const message.Message,
    opts: Options,
    layers: Layers,
) error{OutOfMemory, InvalidContext}!usize {
    const use_layers = layers.system.len > 0 or layers.project.len > 0 or
        layers.session.len > 0 or layers.ephemeral.len > 0;
    var hist_start: usize = 0;
    while (hist_start < full.len and full[hist_start].role == .system) : (hist_start += 1) {}
    const body = full[hist_start..];
    // Repair-first (product semantics): orphan/empty-carrier rows are dropped
    // before the authoritative gate; page_allocator is a placeholder.
    const repaired_raw = try session_item.repairDanglingToolCalls(std.heap.page_allocator, body);
    defer if (repaired_raw) |w| std.heap.page_allocator.free(w);
    const working = repaired_raw orelse body;
    protocol_history.validateBodyHistory(working) catch return error.InvalidContext;
    const start = try initialTrimStart(working, opts);
    const layer_chars: usize = if (use_layers)
        layerEstimate(layers, null)
    else
        estimateChars(full[0..hist_start]);
    return try charTrimStart(working, start, layer_chars, opts);
}

fn layerEstimate(layers: Layers, session_override: ?[]const u8) usize {
    var n: usize = 0;
    if (layers.system.len > 0) n += layers.system.len + 16;
    if (layers.project.len > 0) n += layers.project.len + 64;
    const session = session_override orelse layers.session;
    if (session.len > 0) n += session.len + 48;
    if (layers.ephemeral.len > 0) n += layers.ephemeral.len + 32;
    return n;
}

fn buildLayerMessages(
    arena: std.mem.Allocator,
    layers: Layers,
    session_text: []const u8,
) error{OutOfMemory}![]message.Message {
    var count: usize = 0;
    if (layers.system.len > 0) count += 1;
    if (layers.project.len > 0) count += 1;
    if (session_text.len > 0) count += 1;
    if (layers.ephemeral.len > 0) count += 1;
    if (count == 0) return &.{};

    const out = try arena.alloc(message.Message, count);
    var i: usize = 0;
    if (layers.system.len > 0) {
        out[i] = message.Message.system(try arena.dupe(u8, layers.system));
        i += 1;
    }
    if (layers.project.len > 0) {
        const body = try std.fmt.allocPrint(arena,
            \\# Project instructions
            \\
            \\{s}
        , .{layers.project});
        out[i] = message.Message.system(body);
        i += 1;
    }
    if (session_text.len > 0) {
        const body = try std.fmt.allocPrint(arena,
            \\# Session context
            \\
            \\{s}
        , .{session_text});
        out[i] = message.Message.system(body);
        i += 1;
    }
    if (layers.ephemeral.len > 0) {
        const body = try std.fmt.allocPrint(arena,
            \\# Ephemeral
            \\
            \\{s}
        , .{layers.ephemeral});
        out[i] = message.Message.system(body);
        i += 1;
    }
    return out;
}

// ── Summary / lineage / UTF-8 ───────────────────────────────────────────────

/// Build a bounded UTF-8-safe summary for the final omitted set.
/// Prior session bytes are preserved exactly when they fit; otherwise an
/// explicit truncated lineage record is written (never silent truncation).
/// All writes stay within `max_chars` — never construct then generically cut.
fn buildSummary(
    arena: std.mem.Allocator,
    dropped_msgs: []const message.Message,
    max_chars: usize,
    dropped_count: usize,
    prior_session: []const u8,
) error{OutOfMemory}![]const u8 {
    // Callers pass effectiveSummaryMax; still cap hard for ReleaseFast safety.
    const budget = @min(max_chars, summary_cap);

    var body: std.Io.Writer.Allocating = .init(arena);
    errdefer body.deinit();

    // Header is always complete when budget ≥ summaryFloor (clamp guarantees).
    body.writer.print(
        "[compaction] {d} earlier messages omitted from the model view.\n",
        .{dropped_count},
    ) catch return error.OutOfMemory;
    if (body.written().len > budget) {
        // Pathological: header alone exceeds budget — return header truncated is
        // forbidden; clamp always reserves header. Soft-fail to header only if
        // somehow over (should not happen).
        const owned_hdr = body.toOwnedSlice() catch return error.OutOfMemory;
        return truncateUtf8Owned(arena, owned_hdr, budget);
    }

    // Lineage before highlights — constructed fully within remaining room.
    // `prior_bytes` / digest use **sanitized** prior (see writeLineage).
    if (prior_session.len > 0) {
        try writeLineage(&body, arena, prior_session, budget);
    }

    // Highlights only if residual room remains after mandatory sections.
    const hl_tag = "Highlights:\n";
    const used0 = body.written().len;
    if (used0 < budget and budget - used0 >= hl_tag.len) {
        body.writer.print("{s}", .{hl_tag}) catch return error.OutOfMemory;
        for (dropped_msgs) |m| {
            const role = m.role.jsonName();
            const sanitized = try sanitizeUtf8(arena, m.content);
            const snippet = truncateUtf8(sanitized, 120);
            var line_buf: [200]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "- {s}: {s}\n", .{ role, snippet }) catch continue;
            const used = body.written().len;
            if (used >= budget or budget - used < line.len) break;
            body.writer.print("{s}", .{line}) catch return error.OutOfMemory;
        }
    }
    body.writer.flush() catch {};

    const owned = body.toOwnedSlice() catch return error.OutOfMemory;
    if (owned.len > budget) return truncateUtf8Owned(arena, owned, budget);
    if (!std.unicode.utf8ValidateSlice(owned)) {
        return try sanitizeUtf8(arena, owned);
    }
    return owned;
}

// ── compaction-llm-001: LLM summary composition ─────────────────────────────

/// Provider_max default for summary requests: capped at 256 tokens (revised
/// contract — the summary is clamped to summary_cap ≈ 800 chars ≈ 200 tokens;
/// 256 is a generous generation ceiling and keeps u32 arithmetic safe in the
/// unlimited-budget configuration).
pub const summary_provider_max_tokens: u32 = 256;

/// Serialize the dropped prefix, build INITIAL/UPDATE prompts, and run the
/// retry ladder. Returns the composed LLM summary (cleaned, non-degenerate,
/// plus the structured lineage record — same semantics as the heuristic
/// path) routed through the same budget + UTF-8 clamps; `null` on any
/// failure or on the skip guard (heuristic fallback).
fn summarizeOmitted(
    io: std.Io,
    arena: std.mem.Allocator,
    summarizer: CompactionSummarizer,
    omitted: []const message.Message,
    prior: []const u8,
    dropped_count: usize,
    opts: Options,
) error{OutOfMemory}!?[]const u8 {
    // Skip guard: 4 * max_tokens < MIN_SUMMARY_SEED_CHARS can never produce
    // a non-degenerate summary — do not burn attempts/sleeps.
    const max_tokens = summaryMaxTokens(opts);
    if (4 * @as(usize, max_tokens) < session_item.MIN_SUMMARY_SEED_CHARS) return null;

    const serialized = try session_item.serializeConversationForSummary(arena, omitted);
    const prompts = try session_item.buildSummaryPrompts(arena, if (prior.len > 0) prior else null);
    // Single user message, pi shape: <conversation>…</conversation> + prompt.
    const user_content = try std.fmt.allocPrint(
        arena,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ serialized, prompts.prompt },
    );
    const request: SummaryRequest = .{
        .prompt = user_content,
        .system = prompts.system,
        .max_tokens = max_tokens,
    };
    const raw = try session_item.summarizeWithRetry(
        io,
        arena,
        summarizer,
        request,
        session_item.default_summary_max_attempts,
        session_item.default_summary_retry_delay_ms,
    ) orelse return null;

    // Compose: cleaned LLM text + lineage record (writeLineage semantics),
    // fully within the shared budget, then apply the shared clamps.
    const budget = opts.effectiveSummaryMax(dropped_count, prior);
    var body: std.Io.Writer.Allocating = .init(arena);
    errdefer body.deinit();
    // Reserve the minimal truncated-lineage record up front so the lineage
    // chain is never silently dropped when the LLM text is large (mirror of
    // the heuristic path's summaryFloor guarantee).
    const lineage_reserve = if (prior.len > 0)
        minimalTruncatedLineageLen(utf8SanitizedByteLen(prior)) + 1
    else
        0;
    const llm_text = try clampSummaryText(arena, raw, budget -| lineage_reserve);
    body.writer.print("{s}", .{llm_text}) catch return error.OutOfMemory;
    if (prior.len > 0) {
        try writeLineage(&body, arena, prior, budget);
    }
    body.writer.flush() catch {};
    return try clampSummaryText(arena, body.written(), budget);
}

/// Apply the shared summary clamps (UTF-8 sanitize + budget truncate) to an
/// LLM-produced summary, matching `buildSummary`'s final processing exactly.
/// Truncation happens AFTER sanitization (truncateUtf8 requires valid UTF-8).
fn clampSummaryText(
    arena: std.mem.Allocator,
    text: []const u8,
    budget: usize,
) error{OutOfMemory}![]const u8 {
    if (text.len > budget) {
        const clean = try sanitizeUtf8(arena, text);
        const owned = try arena.dupe(u8, clean);
        return truncateUtf8Owned(arena, owned, budget);
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        return try sanitizeUtf8(arena, text);
    }
    return try arena.dupe(u8, text);
}

/// max_tokens = `@max(1, @min(0.8 * effectiveTokenBudget(), 256))` (usize
/// arithmetic, overflow-safe: the min with 256 bounds every cast;
/// unlimited-budget config → 256). No new config key.
fn summaryMaxTokens(opts: Options) u32 {
    const reserve = opts.effectiveTokenBudget();
    const eighty_pct = (reserve *| 8) / 10;
    return @intCast(@max(@as(usize, 1), @min(eighty_pct, @as(usize, summary_provider_max_tokens))));
}

/// Realloc-truncate to `max` on a UTF-8 boundary (last-resort safety only).
fn truncateUtf8Owned(arena: std.mem.Allocator, owned: []u8, max: usize) error{OutOfMemory}![]u8 {
    const cut = truncateUtf8(owned, max);
    if (cut.len == owned.len) return owned;
    return arena.realloc(owned, cut.len) catch return error.OutOfMemory;
}

/// Write exact prior or a truncated lineage record fully within
/// `max_chars - body.written().len`. Never intentionally overruns then cuts.
///
/// Lineage semantics:
/// - `prior_bytes` = byte length of **sanitized** prior (U+FFFD expansion)
/// - digest = wyhash64 over the **same sanitized** bytes
/// - exact form only for **valid** UTF-8 priors that fit (subtractive capacity check)
/// - invalid UTF-8 priors always use truncated form so `prior_bytes`/digest stay auditable
fn writeLineage(
    body: *std.Io.Writer.Allocating,
    arena: std.mem.Allocator,
    prior_session: []const u8,
    max_chars: usize,
) error{OutOfMemory}!void {
    const prior_was_invalid = !std.unicode.utf8ValidateSlice(prior_session);
    const prior_clean = try sanitizeUtf8(arena, prior_session);
    const digest = std.hash.Wyhash.hash(0, prior_clean);
    const used = body.written().len;
    if (used >= max_chars) return;
    const room = max_chars - used;

    // Exact prior only when input was already valid UTF-8 and capacity fits.
    const exact_prefix = "Prior session context:\n";
    if (!prior_was_invalid and fitsExactLineage(room, exact_prefix.len, prior_clean.len)) {
        body.writer.print("{s}{s}\n", .{ exact_prefix, prior_clean }) catch return error.OutOfMemory;
        return;
    }

    // Prefer form with a kept prefix when residual room allows.
    if (try writeTruncatedLineageWithKept(body, prior_clean, digest, room)) return;

    // Floor form: format into stack buffer, write only if it fits (no assert).
    var min_buf: [192]u8 = undefined;
    const min_rec = std.fmt.bufPrint(
        &min_buf,
        "Prior session context (truncated):\nprior_bytes={d} kept_bytes=0 digest=wyhash64:{x:0>16}\n{s}\n",
        .{ prior_clean.len, digest, lineage_truncated_marker },
    ) catch return error.OutOfMemory;
    if (min_rec.len > room) return; // floor mismatch: refuse overrun rather than panic
    body.writer.print("{s}", .{min_rec}) catch return error.OutOfMemory;
}

/// Try to write truncated lineage with a UTF-8-safe kept prefix. Returns true if written.
/// Capacity checks are subtractive / saturating — no unchecked multi-term sums.
fn writeTruncatedLineageWithKept(
    body: *std.Io.Writer.Allocating,
    prior_clean: []const u8,
    digest: u64,
    room: usize,
) error{OutOfMemory}!bool {
    const line1 = "Prior session context (truncated):\n";
    const kept_label = "kept:\n";

    // Shrink kept until form B fits in `room`.
    var k = prior_clean.len;
    while (true) {
        const kept = truncateUtf8(prior_clean, k);
        k = kept.len;
        if (truncatedLineageWithKeptFits(room, prior_clean.len, k, line1.len, kept_label.len)) {
            body.writer.print(
                "{s}prior_bytes={d} kept_bytes={d} digest=wyhash64:{x:0>16}\nkept:\n{s}\n{s}\n",
                .{ line1, prior_clean.len, k, digest, kept, lineage_truncated_marker },
            ) catch return error.OutOfMemory;
            return true;
        }
        if (k == 0) return false;
        // Drop at least one byte (and realign UTF-8 on next iteration).
        k -= 1;
    }
}

/// Subtractive capacity check for truncated lineage form B (with kept section).
fn truncatedLineageWithKeptFits(
    room: usize,
    prior_sanitized_len: usize,
    kept_len: usize,
    line1_len: usize,
    kept_label_len: usize,
) bool {
    var rem = room;
    if (rem < line1_len) return false;
    rem -= line1_len;
    // meta: prior_bytes=N kept_bytes=K digest=wyhash64:HEX\n
    const meta_fixed = "prior_bytes=".len + " kept_bytes=".len + " digest=wyhash64:".len + 16 + 1;
    const meta_need = meta_fixed +| decimalDigits(prior_sanitized_len) +| decimalDigits(kept_len);
    if (rem < meta_need) return false;
    rem -= meta_need;
    if (rem < kept_label_len) return false;
    rem -= kept_label_len;
    if (rem < kept_len) return false;
    rem -= kept_len;
    // newline after kept + marker line
    if (rem < 1) return false;
    rem -= 1;
    const marker_line = lineage_truncated_marker.len +| 1;
    return rem >= marker_line;
}

/// Replace invalid UTF-8 sequences with U+FFFD. Valid input is returned as a
/// borrowed slice (no alloc); invalid input is arena-owned.
fn sanitizeUtf8(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try list.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        };
        // Invariant: i <= s.len. Prefer subtractive bound check.
        if (seq_len > s.len - i) {
            try list.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
            try list.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        };
        try list.appendSlice(arena, s[i..][0..seq_len]);
        i += seq_len;
    }
    return try list.toOwnedSlice(arena);
}

/// Truncate on a UTF-8 codepoint boundary (input must be valid UTF-8).
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn estimateChars(msgs: []const message.Message) usize {
    var n: usize = 0;
    for (msgs) |m| {
        n += m.estimateChars();
    }
    return n;
}

/// True when the first non-system history message in `view` is not an orphan tool.
fn historyStartIsValid(msgs: []const message.Message) bool {
    var i: usize = 0;
    while (i < msgs.len and msgs[i].role == .system) : (i += 1) {}
    if (i >= msgs.len) return true;
    return msgs[i].role != .tool;
}

/// Snapshot roles for transcript-immutability checks.
fn snapshotRoles(msgs: []const message.Message, buf: []u8) usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (n >= buf.len) break;
        buf[n] = switch (m.role) {
            .system => 'S',
            .user => 'U',
            .assistant => 'A',
            .tool => 'T',
        };
        n += 1;
    }
    return n;
}

// ── unit tests ──────────────────────────────────────────────────────────────

test "view layers then history; skips transcript systems" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("old-merged-system"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
    };

    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 10,
        .max_chars = 0,
        .min_tail_messages = 1,
    }, .{
        .system = "base-sys",
        .project = "use tabs",
        .session = "",
        .ephemeral = "hint",
    });

    try std.testing.expect(v.compaction == null);
    try std.testing.expect(v.messages.len >= 5);
    try std.testing.expectEqualStrings("base-sys", v.messages[0].content);
    try std.testing.expect(std.mem.indexOf(u8, v.messages[1].content, "use tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, v.messages[2].content, "hint") != null);
    try std.testing.expectEqualStrings("u1", v.messages[3].content);
    try std.testing.expectEqualStrings("a2", v.messages[v.messages.len - 1].content);
}

test "view trims history and returns compaction without mutating transcript" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
    };
    var role_before: [16]u8 = undefined;
    const n_before = snapshotRoles(&full, &role_before);
    const before_len = full.len;
    const u1_ptr = full[1].content.ptr;

    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 2,
    }, .{ .system = "base" });

    try std.testing.expectEqual(before_len, full.len);
    try std.testing.expectEqual(u1_ptr, full[1].content.ptr);
    var role_after: [16]u8 = undefined;
    const n_after = snapshotRoles(&full, &role_after);
    try std.testing.expectEqual(n_before, n_after);
    try std.testing.expectEqualStrings(role_before[0..n_before], role_after[0..n_after]);

    try std.testing.expect(v.compaction != null);
    try std.testing.expect(v.compaction.?.dropped >= 2);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "compaction") != null);
    try std.testing.expectEqualStrings("a3", v.messages[v.messages.len - 1].content);
    var saw_session = false;
    for (v.messages) |m| {
        if (m.role == .system and std.mem.indexOf(u8, m.content, "Session context") != null) {
            saw_session = true;
        }
    }
    try std.testing.expect(saw_session);
}

test "view does not start on orphan tool message" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const full = [_]message.Message{
        .system("sys"),
        .user("old"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out"),
        .user("new"),
        .assistantText("ok"),
    };

    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 3,
        .max_chars = 0,
        .min_tail_messages = 1,
    }, .{ .system = "base" });

    try std.testing.expect(historyStartIsValid(v.messages));
    var saw_tool = false;
    var saw_assistant_tools = false;
    for (v.messages) |m| {
        if (m.role == .tool) saw_tool = true;
        if (m.role == .assistant and m.tool_calls != null) saw_assistant_tools = true;
    }
    if (saw_tool) try std.testing.expect(saw_assistant_tools);
}

// ── h-context-001 fixtures ──────────────────────────────────────────────────

test "h-context: two-stage trim requires final > intermediate" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const pad = "X" ** 80;
    const full = [_]message.Message{
        .system("sys"),
        .user("early-user-1 " ++ pad),
        .assistantText("early-asst-1 " ++ pad),
        .user("early-user-2 " ++ pad),
        .assistantText("early-asst-2 " ++ pad),
        .user("mid-user-1 " ++ pad),
        .assistantText("mid-asst-1 " ++ pad),
        .user("mid-user-2 " ++ pad),
        .assistantText("mid-asst-2 " ++ pad),
        .user("late-user"),
        .assistantText("late-asst"),
    };

    // Deep snapshot: roles + content pointers/bytes.
    var roles_before: [32]u8 = undefined;
    const nrb = snapshotRoles(&full, &roles_before);
    var content_before: [11][]const u8 = undefined;
    for (&content_before, 0..) |*slot, idx| slot.* = full[idx].content;

    const opts = Options{
        .max_tail_messages = 0,
        .max_chars = 420,
        .min_tail_messages = 2,
        .summary_max_chars = 400,
    };
    const layers = Layers{ .system = "base-system-prompt" };

    const intermediate = try intermediateDroppedBeforeSummary(&full, opts, layers);
    try std.testing.expect(intermediate > 0);

    const v = try viewForModel(std.testing.io, arena, &full, opts, layers);
    try std.testing.expect(v.compaction != null);
    const ev = v.compaction.?;

    // Hard requirement: summary growth forces further trim (old bug under-count).
    try std.testing.expect(ev.dropped > intermediate);

    const body = full[1..];
    const kept = body[ev.dropped..];
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const view_hist = v.messages[hist_i..];
    try std.testing.expectEqual(kept.len, view_hist.len);
    for (kept, view_hist) |k, vm| {
        try std.testing.expectEqualStrings(k.content, vm.content);
        try std.testing.expectEqual(k.role, vm.role);
    }

    var count_buf: [32]u8 = undefined;
    const count_needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{ev.dropped});
    try std.testing.expect(std.mem.indexOf(u8, ev.summary, count_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.summary, "early-user-1") != null);

    // Transcript deep-immutability.
    var roles_after: [32]u8 = undefined;
    const nra = snapshotRoles(&full, &roles_after);
    try std.testing.expectEqualStrings(roles_before[0..nrb], roles_after[0..nra]);
    for (content_before, 0..) |c, idx| {
        try std.testing.expectEqualStrings(c, full[idx].content);
    }
}

test "h-context: summary growth multi-iteration fixed-point" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const pad = "Y" ** 40;
    var msgs: [25]message.Message = undefined;
    msgs[0] = .system("sys");
    var i: usize = 1;
    while (i < msgs.len) : (i += 2) {
        msgs[i] = .user(pad);
        if (i + 1 < msgs.len) msgs[i + 1] = .assistantText(pad);
    }

    const opts = Options{
        .max_tail_messages = 0,
        .max_chars = 350,
        .min_tail_messages = 4,
        .summary_max_chars = 300,
    };
    const layers = Layers{ .system = "S" };

    const intermediate = try intermediateDroppedBeforeSummary(&msgs, opts, layers);
    const v = try viewForModel(std.testing.io, arena, &msgs, opts, layers);
    try std.testing.expect(v.compaction != null);
    const final_dropped = v.compaction.?.dropped;
    try std.testing.expect(final_dropped > intermediate);

    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(msgs.len - 1 - final_dropped, v.messages.len - hist_i);
}

test "h-context: multi-tool exact IDs atomic align and advance" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls_a = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{\"path\":\".\"}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{\"path\":\"x\"}" },
    };
    const calls_b = [_]message.ToolCall{
        .{ .id = "b1", .name = "grep", .arguments = "{\"pattern\":\"z\"}" },
    };
    const full = [_]message.Message{
        .system("sys"),
        .user("old-1"),
        .assistantText("old-a"),
        .user("ask-tools"),
        .assistantToolCalls("using tools", &calls_a),
        .toolResult("a1", "dir-out"),
        .toolResult("a2", "file-out"),
        .user("more"),
        .assistantToolCalls("again", &calls_b),
        .toolResult("b1", "grep-out"),
        .user("final"),
        .assistantText("done"),
    };

    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 1,
    }, .{ .system = "base" });
    try std.testing.expect(historyStartIsValid(v.messages));

    // Valid multi-call order preserved when bundle kept.
    var last_ids: ?[]const message.ToolCall = null;
    var result_i: usize = 0;
    for (v.messages) |m| {
        switch (m.role) {
            .assistant => {
                last_ids = m.tool_calls;
                result_i = 0;
            },
            .tool => {
                try std.testing.expect(last_ids != null);
                const calls = last_ids.?;
                try std.testing.expect(result_i < calls.len);
                try std.testing.expectEqualStrings(calls[result_i].id, m.tool_call_id.?);
                result_i += 1;
            },
            else => {
                last_ids = null;
                result_i = 0;
            },
        }
    }
}

test "h-context: malformed tool bundles return InvalidContext" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const dup = [_]message.ToolCall{
        .{ .id = "x", .name = "list_dir", .arguments = "{}" },
        .{ .id = "x", .name = "read_file", .arguments = "{}" },
    };
    const empty_id = [_]message.ToolCall{
        .{ .id = "", .name = "list_dir", .arguments = "{}" },
    };

    // Orphan tool — repair-first product semantics: the orphan row is dropped
    // deterministically (view-only), so the view succeeds WITHOUT the orphan
    // (transcript untouched). The remaining malformed classes below still
    // fail closed: repair never rescues incomplete/out-of-order/duplicate
    // bundles because it only drops rows, never reorders or invents content.
    const orphan = [_]message.Message{
        .user("u"),
        .toolResult("z", "nope"),
    };
    const orphan_v = try viewForModel(std.testing.io, arena, &orphan, .{}, .{ .system = "b" });
    try std.testing.expectEqual(@as(usize, 2), orphan_v.messages.len);
    try std.testing.expect(orphan_v.messages[0].role == .system);
    try std.testing.expect(orphan_v.messages[1].role == .user);
    try std.testing.expect(orphan_v.compaction == null);

    // Unknown / wrong ID.
    const wrong_id = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "ok"),
        .toolResult("WRONG", "bad"),
    };
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &wrong_id, .{}, .{}));

    // Out of order.
    const ooo = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a2", "second-first"),
        .toolResult("a1", "first-second"),
    };
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &ooo, .{}, .{}));

    // Missing result (incomplete).
    const incomplete = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "only-one"),
    };
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &incomplete, .{}, .{}));

    // Duplicate IDs in calls.
    const dups = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &dup),
        .toolResult("x", "1"),
        .toolResult("x", "2"),
    };
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &dups, .{}, .{}));

    // Empty call id.
    const empty = [_]message.Message{
        .user("u"),
        .assistantToolCalls("", &empty_id),
        .toolResult("", "x"),
    };
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &empty, .{}, .{}));
}

test "h-context: min_tail soft budget terminates honestly" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const huge = "H" ** 500;
    const full = [_]message.Message{
        .system("sys"),
        .user(huge),
        .assistantText(huge),
    };
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 100,
        .min_tail_messages = 2,
        .summary_max_chars = 80,
    }, .{ .system = "base" });
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 2), v.messages.len - hist_i);
    try std.testing.expect(v.compaction == null);

    const full2 = [_]message.Message{
        .system("sys"),
        .user(huge),
        .assistantText(huge),
        .user("keep-u"),
        .assistantText("keep-a"),
    };
    const v2 = try viewForModel(std.testing.io, arena, &full2, .{
        .max_tail_messages = 0,
        .max_chars = 50,
        .min_tail_messages = 2,
        .summary_max_chars = 100,
    }, .{ .system = "base" });
    try std.testing.expect(v2.compaction != null);
    hist_i = 0;
    while (hist_i < v2.messages.len and v2.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 2), v2.messages.len - hist_i);
    try std.testing.expectEqual(@as(usize, 2), v2.compaction.?.dropped);
}

test "h-context: lineage exact fit and truncated record with digest" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("first-wave"),
        .assistantText("a1"),
        .user("second-wave"),
        .assistantText("a2"),
        .user("third-wave"),
        .assistantText("a3"),
        .user("now"),
        .assistantText("here"),
    };

    // Exact fit: small prior fully retained.
    const small_prior = "PRIOR_EXACT_BYTES_OK";
    const v_exact = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 800,
    }, .{ .system = "base", .session = small_prior });
    try std.testing.expect(v_exact.compaction != null);
    try std.testing.expect(std.mem.indexOf(u8, v_exact.compaction.?.summary, small_prior) != null);
    try std.testing.expect(std.mem.indexOf(u8, v_exact.compaction.?.summary, lineage_truncated_marker) == null);

    // 790–800 byte prior forces truncation under residual budget.
    var prior_buf: [790]u8 = undefined;
    @memset(&prior_buf, 'P');
    // Make it valid UTF-8 ASCII.
    const prior790 = prior_buf[0..];
    try std.testing.expectEqual(@as(usize, 790), prior790.len);

    const v_trunc = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 800,
    }, .{ .system = "base", .session = prior790 });
    try std.testing.expect(v_trunc.compaction != null);
    const sum = v_trunc.compaction.?.summary;
    try std.testing.expect(sum.len <= summary_cap);
    try std.testing.expect(std.mem.indexOf(u8, sum, lineage_truncated_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=790") != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, "digest=wyhash64:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, "kept_bytes=") != null);
    // Dropped header still complete.
    try std.testing.expect(std.mem.indexOf(u8, sum, "earlier messages omitted") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sum));

    // Digest matches full prior (fixed-width hex).
    const digest = std.hash.Wyhash.hash(0, prior790);
    var dig_buf: [48]u8 = undefined;
    const dig_needle = try std.fmt.bufPrint(&dig_buf, "digest=wyhash64:{x:0>16}", .{digest});
    try std.testing.expect(std.mem.indexOf(u8, sum, dig_needle) != null);
}

test "h-context: shared summary_cap clamp and tiny budget keeps header" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
    };

    // > summary_cap request clamps.
    try std.testing.expectEqual(@as(usize, summary_cap), clampSummaryBudget(5000, 3, ""));
    try std.testing.expectEqual(@as(usize, summary_cap), clampSummaryBudget(0, 3, ""));
    // Floor with prior raises above tiny request and stays ≤ cap.
    var prior790: [790]u8 = undefined;
    @memset(&prior790, 'P');
    const floor_prior = summaryFloor(4, &prior790);
    try std.testing.expect(floor_prior > droppedHeaderLen(4));
    try std.testing.expect(floor_prior <= summary_cap);
    try std.testing.expectEqual(floor_prior, clampSummaryBudget(1, 4, &prior790));
    try std.testing.expectEqual(floor_prior, clampSummaryBudget(8, 4, &prior790));

    const v_over = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
        .summary_max_chars = 50_000,
    }, .{ .system = "base" });
    try std.testing.expect(v_over.compaction != null);
    try std.testing.expect(v_over.compaction.?.summary.len <= summary_cap);

    // Tiny budget still has complete dropped header.
    const v_tiny = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
        .summary_max_chars = 8,
    }, .{ .system = "base" });
    try std.testing.expect(v_tiny.compaction != null);
    const s = v_tiny.compaction.?.summary;
    try std.testing.expect(std.mem.indexOf(u8, s, "earlier messages omitted") != null);
    var count_buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{v_tiny.compaction.?.dropped});
    try std.testing.expect(std.mem.indexOf(u8, s, needle) != null);
    try std.testing.expect(s.len <= summary_cap);
}

test "h-context: tiny budget with 790-byte prior keeps full lineage metadata" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Force two-stage char growth so summary is rebuilt under pressure.
    const pad = "X" ** 80;
    const full = [_]message.Message{
        .system("sys"),
        .user("early-1 " ++ pad),
        .assistantText("early-a1 " ++ pad),
        .user("early-2 " ++ pad),
        .assistantText("early-a2 " ++ pad),
        .user("mid-1 " ++ pad),
        .assistantText("mid-a1 " ++ pad),
        .user("late-u"),
        .assistantText("late-a"),
    };

    var prior: [790]u8 = undefined;
    @memset(&prior, 'R');
    const prior790 = prior[0..];
    const digest = std.hash.Wyhash.hash(0, prior790);
    var dig_buf: [48]u8 = undefined;
    const dig_needle = try std.fmt.bufPrint(&dig_buf, "digest=wyhash64:{x:0>16}", .{digest});

    for ([_]usize{ 1, 8 }) |tiny| {
        const floor = summaryFloor(6, prior790); // lower bound; actual dropped may differ
        try std.testing.expect(floor <= summary_cap);

        const v = try viewForModel(std.testing.io, arena, &full, .{
            .max_tail_messages = 0,
            .max_chars = 420, // two-stage pressure
            .min_tail_messages = 2,
            .summary_max_chars = tiny,
        }, .{ .system = "base-system", .session = prior790 });

        try std.testing.expect(v.compaction != null);
        const sum = v.compaction.?.summary;
        try std.testing.expect(sum.len <= summary_cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(sum));

        // Complete dropped header.
        try std.testing.expect(std.mem.indexOf(u8, sum, "earlier messages omitted") != null);
        var count_buf: [32]u8 = undefined;
        const count_needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{v.compaction.?.dropped});
        try std.testing.expect(std.mem.indexOf(u8, sum, count_needle) != null);

        // Full lineage metadata (kept_bytes may be 0 under tiny floor).
        try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=790") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, dig_needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, lineage_truncated_marker) != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, "kept_bytes=") != null);

        // Floor for this actual dropped count holds.
        const f2 = summaryFloor(v.compaction.?.dropped, prior790);
        try std.testing.expect(sum.len >= f2);
        try std.testing.expect(f2 <= summary_cap);
    }
}

test "h-context: utf8SanitizedByteLen matches sanitizeUtf8 length (table)" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const Case = struct { name: []const u8, bytes: []const u8 };
    // UTF-8 samples: 2-byte U+00A9 © = C2 A9; 3-byte U+20AC € = E2 82 AC;
    // 4-byte U+1F600 😀 = F0 9F 98 80.
    const cases = [_]Case{
        .{ .name = "ascii", .bytes = "hello world" },
        .{ .name = "empty", .bytes = "" },
        .{ .name = "valid-2byte", .bytes = &[_]u8{ 0xC2, 0xA9 } },
        .{ .name = "valid-3byte", .bytes = &[_]u8{ 0xE2, 0x82, 0xAC } },
        .{ .name = "valid-4byte", .bytes = &[_]u8{ 0xF0, 0x9F, 0x98, 0x80 } },
        .{ .name = "isolated-continuation", .bytes = &[_]u8{0x80} },
        .{ .name = "invalid-lead-ff", .bytes = &[_]u8{0xFF} },
        .{ .name = "invalid-lead-fe", .bytes = &[_]u8{0xFE} },
        .{ .name = "truncated-2byte", .bytes = &[_]u8{0xC2} },
        .{ .name = "truncated-3byte", .bytes = &[_]u8{ 0xE2, 0x82 } },
        .{ .name = "truncated-4byte", .bytes = &[_]u8{ 0xF0, 0x9F, 0x98 } },
        .{ .name = "bad-cont-2byte", .bytes = &[_]u8{ 0xC2, 0x20 } },
        .{ .name = "bad-cont-3byte-mid", .bytes = &[_]u8{ 0xE2, 0x20, 0xAC } },
        .{ .name = "bad-cont-3byte-end", .bytes = &[_]u8{ 0xE2, 0x82, 0x20 } },
        .{ .name = "mixed-ascii-invalid", .bytes = &[_]u8{ 'a', 0xFF, 'b', 0x80, 'c' } },
        .{ .name = "nine-invalid", .bytes = &[_]u8{ 0xFF, 0xFE, 0xFD, 0xFF, 0xFE, 0xFD, 0xFF, 0xFE, 0xFD } },
        .{ .name = "repeated-ff", .bytes = &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } },
        .{ .name = "overlong-ish-c0", .bytes = &[_]u8{ 0xC0, 0x80 } },
    };

    for (cases) |c| {
        const len_est = utf8SanitizedByteLen(c.bytes);
        const cleaned = try sanitizeUtf8(arena, c.bytes);
        try std.testing.expectEqual(len_est, cleaned.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(cleaned));
    }
}

test "h-context: raw-nine invalid prior end-to-end tiny compaction prior_bytes=27" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // 9 invalid bytes → 27 sanitized: decimal width 1→2 (floor must not use raw len).
    const raw9 = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFF, 0xFE, 0xFD, 0xFF, 0xFE, 0xFD };
    try std.testing.expectEqual(@as(usize, 9), raw9.len);
    try std.testing.expectEqual(@as(usize, 27), utf8SanitizedByteLen(&raw9));
    try std.testing.expect(decimalDigits(9) < decimalDigits(27));

    const floor9_san = summaryFloor(2, &raw9);
    const naive_raw = droppedHeaderLen(2) +| minimalTruncatedLineageLen(9);
    try std.testing.expect(floor9_san > naive_raw);
    try std.testing.expect(floor9_san <= summary_cap);
    try std.testing.expectEqual(floor9_san, clampSummaryBudget(1, 2, &raw9));

    const prior_clean = try sanitizeUtf8(arena, &raw9);
    try std.testing.expectEqual(@as(usize, 27), prior_clean.len);
    const digest = std.hash.Wyhash.hash(0, prior_clean);
    var dig_buf: [48]u8 = undefined;
    const dig_needle = try std.fmt.bufPrint(&dig_buf, "digest=wyhash64:{x:0>16}", .{digest});
    try std.testing.expectEqual(@as(usize, 16), dig_needle.len - "digest=wyhash64:".len);

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
    };

    // Invalid priors always take truncated form → prior_bytes/digest auditable.
    for ([_]usize{ 1, 8 }) |tiny| {
        const v = try viewForModel(std.testing.io, arena, &full, .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 1,
            .summary_max_chars = tiny,
        }, .{ .system = "base", .session = &raw9 });

        try std.testing.expect(v.compaction != null);
        const sum = v.compaction.?.summary;
        try std.testing.expect(sum.len <= summary_cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(sum));
        try std.testing.expect(std.mem.indexOf(u8, sum, "earlier messages omitted") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=27") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, "kept_bytes=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, dig_needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, sum, lineage_truncated_marker) != null);
        const dig_at = std.mem.indexOf(u8, sum, "digest=wyhash64:").?;
        const hex = sum[dig_at + "digest=wyhash64:".len ..][0..16];
        for (hex) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            try std.testing.expect(ok);
        }
    }
}

test "h-context: larger invalid prior still truncated with sanitized prior_bytes" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // 34 × 0xFF → 102 sanitized (raw digits 2, sanitized digits 3).
    var raw34: [34]u8 = undefined;
    @memset(&raw34, 0xFF);
    try std.testing.expectEqual(@as(usize, 102), utf8SanitizedByteLen(&raw34));
    try std.testing.expect(decimalDigits(34) < decimalDigits(102));

    const prior_clean = try sanitizeUtf8(arena, &raw34);
    const digest = std.hash.Wyhash.hash(0, prior_clean);
    var dig_buf: [48]u8 = undefined;
    const dig_needle = try std.fmt.bufPrint(&dig_buf, "digest=wyhash64:{x:0>16}", .{digest});

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
    };
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
        .summary_max_chars = 1,
    }, .{ .system = "base", .session = &raw34 });
    try std.testing.expect(v.compaction != null);
    const sum = v.compaction.?.summary;
    try std.testing.expect(sum.len <= summary_cap);
    try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=102") != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, dig_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, lineage_truncated_marker) != null);
}

test "h-context: invalid UTF-8 sanitized to U+FFFD not OOM" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Invalid bytes mid-string and at potential truncate boundary.
    const bad = [_]u8{ 'h', 'i', 0xFF, 0xFE, 'x' };
    const full = [_]message.Message{
        .system("sys"),
        .user(&bad),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("tail"),
        .assistantText("ok"),
    };
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
        .summary_max_chars = 120,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(v.compaction.?.summary));
    // Replacement character present (UTF-8 EF BF BD).
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "\u{FFFD}") != null);
}

test "h-context: identical inputs are deterministic" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
        .user("u4"),
        .assistantText("a4"),
    };
    const opts = Options{
        .max_tail_messages = 3,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 400,
    };
    const layers = Layers{ .system = "base", .session = "prior-session-layer" };

    const v1 = try viewForModel(std.testing.io, arena, &full, opts, layers);
    const v2 = try viewForModel(std.testing.io, arena, &full, opts, layers);
    try std.testing.expect(v1.compaction != null and v2.compaction != null);
    try std.testing.expectEqual(v1.compaction.?.dropped, v2.compaction.?.dropped);
    try std.testing.expectEqualStrings(v1.compaction.?.summary, v2.compaction.?.summary);
    try std.testing.expectEqual(v1.messages.len, v2.messages.len);
}

test "h-context: deep transcript snapshot tool ids unchanged after view" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{
        .{ .id = "keep-1", .name = "list_dir", .arguments = "{\"path\":\".\"}" },
        .{ .id = "keep-2", .name = "read_file", .arguments = "{\"path\":\"a\"}" },
    };
    const full = [_]message.Message{
        .system("sys"),
        .user("before"),
        .assistantToolCalls("run", &calls),
        .toolResult("keep-1", "out1"),
        .toolResult("keep-2", "out2"),
        .user("after"),
        .assistantText("done"),
    };

    const id0 = full[2].tool_calls.?[0].id;
    const name1 = full[2].tool_calls.?[1].name;
    const args0 = full[2].tool_calls.?[0].arguments;
    const rid0 = full[3].tool_call_id.?;
    const rid1 = full[4].tool_call_id.?;

    _ = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
    }, .{ .system = "base" });

    try std.testing.expectEqualStrings("keep-1", full[2].tool_calls.?[0].id);
    try std.testing.expectEqualStrings(id0, full[2].tool_calls.?[0].id);
    try std.testing.expectEqualStrings(name1, full[2].tool_calls.?[1].name);
    try std.testing.expectEqualStrings(args0, full[2].tool_calls.?[0].arguments);
    try std.testing.expectEqualStrings(rid0, full[3].tool_call_id.?);
    try std.testing.expectEqualStrings(rid1, full[4].tool_call_id.?);
    try std.testing.expectEqualStrings("out1", full[3].content);
    try std.testing.expectEqualStrings("out2", full[4].content);
}

// ── session-item-001: token-budget Stage A fixtures ─────────────────────────

test "session-item: effectiveTokenBudget derives from max_chars / 4" {
    const default_budget = Options{ .max_chars = 120_000 };
    try std.testing.expectEqual(@as(usize, 30_000), default_budget.effectiveTokenBudget());
    const unlimited = Options{ .max_tokens = 0, .max_chars = 0 };
    try std.testing.expectEqual(std.math.maxInt(usize), unlimited.effectiveTokenBudget());
    // Explicit max_tokens wins over the derivation.
    const explicit = Options{ .max_chars = 120_000, .max_tokens = 77 };
    try std.testing.expectEqual(@as(usize, 77), explicit.effectiveTokenBudget());
}

test "session-item: token-budget truncate replaces count-trim in viewForModel" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // 8 rows × 40 bytes = 10 tokens each; a 30-token budget keeps ~3 rows
    // (count cap disabled, min_tail 0). The view must fit the token budget.
    const pad = "X" ** 40;
    var full: [9]message.Message = undefined;
    full[0] = .system("sys");
    var i: usize = 1;
    while (i < full.len) : (i += 2) {
        full[i] = .user(pad);
        if (i + 1 < full.len) full[i + 1] = .assistantText(pad);
    }

    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 0,
        .max_tokens = 30,
        .min_tail_messages = 0,
        .summary_max_chars = 400,
    }, .{ .system = "base" });

    try std.testing.expect(v.compaction != null);
    try std.testing.expect(v.compaction.?.dropped >= 5);
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const kept = v.messages[hist_i..];
    var tokens: usize = 0;
    for (kept) |m| tokens += m.estimateTokens();
    try std.testing.expect(tokens <= 30);
    try std.testing.expectEqual(full.len - 1 - v.compaction.?.dropped, kept.len);
}

test "session-item: viewForModel max_tokens 0 with max_chars 0 is unlimited" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
    };
    // Backward-compatible default: no token budget, no char budget → no trim.
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 10,
        .max_chars = 0,
        .min_tail_messages = 1,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction == null);
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 4), v.messages.len - hist_i);
}

test "session-item: tiny token budget with min_tail 0 empties history + compaction" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("user-message"),
        .assistantText("assistant-message"),
    };
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 0,
        .max_tokens = 1,
        .min_tail_messages = 0,
        .summary_max_chars = 400,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expectEqual(@as(usize, 2), v.compaction.?.dropped);
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 0), v.messages.len - hist_i);
}

test "session-item: max_tail_messages count cap still applies on top of token truncate" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
    };
    // Unlimited token budget, count cap 2 → exactly the tail 2 rows kept.
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 400,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expectEqual(@as(usize, 4), v.compaction.?.dropped);
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 2), v.messages.len - hist_i);
    try std.testing.expectEqualStrings("u3", v.messages[v.messages.len - 2].content);
}

test "session-item: viewForModel keeps token-truncated tool bundles atomic" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const full = [_]message.Message{
        .system("sys"),
        .user("early"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "dir-out"),
        .toolResult("a2", "file-out"),
        .user("late"),
        .assistantText("done"),
    };
    // Budget 5 tokens: the first user (1 token) + the whole 4-row bundle
    // (7 tokens) must drop as one unit, keeping exactly the last 2 rows.
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 0,
        .max_tokens = 5,
        .min_tail_messages = 0,
        .summary_max_chars = 400,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expectEqual(@as(usize, 4), v.compaction.?.dropped);
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const kept = v.messages[hist_i..];
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("late", kept[0].content);
    try std.testing.expectEqualStrings("done", kept[1].content);
    // View validates: bundle dropped as a unit, no stray tool rows.
    try protocol_history.validateViewBody(v.messages);
}

// ── chat-state-prune-001: dedup + rewind integration ────────────────────────

test "chat-state-prune: dedup rescues a duplicate-result view deterministically" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const full = [_]message.Message{
        .system("sys"),
        .user("ask"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out-1"),
        .toolResult("c1", "out-2"), // duplicate result row
        .user("done"),
    };
    // Pre-dedup this view fails closed at validateBodyHistory (top-level tool
    // row after the bundle); the combined repair+dedup pre-gate rescues it
    // deterministically (keep-last, view-only).
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 0,
        .min_tail_messages = 0,
    }, .{ .system = "base" });
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const hist = v.messages[hist_i..];
    try std.testing.expectEqual(@as(usize, 4), hist.len);
    try std.testing.expect(hist[2].role == .tool);
    try std.testing.expectEqualStrings("out-2", hist[2].content);
    try protocol_history.validateViewBody(v.messages);
}

test "chat-state-prune: incomplete bundles still InvalidContext after dedup" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const full = [_]message.Message{
        .system("sys"),
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("a1", "only-one"),
    };
    // Dedup never invents content: a missing result stays fail-closed.
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &full, .{}, .{}));
}

test "chat-state-prune: cross-carrier tool_call_id reuse is legal end-to-end" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const full = [_]message.Message{
        .system("sys"),
        .user("u0"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out-1"),
        .user("u1"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "out-2"), // carrier 2 reuses c1 from carrier 1
        .user("u2"),
    };
    // Dedup is carrier-scoped: a global seen-set would have collapsed the
    // second c1; both bundles must survive and validate.
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 0,
        .min_tail_messages = 0,
    }, .{ .system = "base" });
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const hist = v.messages[hist_i..];
    try std.testing.expectEqual(@as(usize, 7), hist.len);
    try std.testing.expectEqualStrings("out-1", hist[2].content);
    try std.testing.expectEqualStrings("out-2", hist[5].content);
    try protocol_history.validateViewBody(v.messages);
}

test "chat-state-prune: interleaved within-run repeats still InvalidContext" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls = [_]message.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const full = [_]message.Message{
        .system("sys"),
        .user("u"),
        .assistantToolCalls("", &calls),
        .toolResult("c1", "a"),
        .toolResult("c2", "b"),
        .toolResult("c1", "c"), // interleaved repeat: keep-last leaves r(c2), r(c1)
        .user("done"),
    };
    // Dedup does NOT rescue interleaved repeats: after keep-last the result
    // order no longer matches the call list, so the gate still fails closed.
    try std.testing.expectError(error.InvalidContext, viewForModel(std.testing.io, arena, &full, .{}, .{}));
}

// ── compaction-llm-001: summarizer seam fixtures ────────────────────────────

const LlmFake = struct {
    calls: u32 = 0,
    results: []const SummaryResult,
    last_request: ?SummaryRequest = null,

    fn summarize(ptr: *anyopaque, request: SummaryRequest) SummaryResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_request = request;
        const idx = @min(self.calls - 1, self.results.len - 1);
        return self.results[idx];
    }
};

const llm_fake_vtable = CompactionSummarizerVTable{ .summarize = LlmFake.summarize };

fn llmSeam(fake: *LlmFake) CompactionSummarizer {
    return .{ .ptr = fake, .vtable = &llm_fake_vtable };
}

/// 719 bytes / 660 visible chars — non-degenerate and under the 800 cap, so it
/// passes through cleaning, degenerate checks, and budget clamps unchanged.
const llm_healthy = ("hello world\n" ** 59) ++ "hello world";

fn llmFixture() struct { full: [9]message.Message } {
    return .{ .full = [_]message.Message{
        .system("sys"),
        .user("u1"),
        .assistantText("a1"),
        .user("u2"),
        .assistantText("a2"),
        .user("u3"),
        .assistantText("a3"),
        .user("now"),
        .assistantText("here"),
    } };
}

test "compaction-llm: success path uses LLM text in event + session layer" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });

    try std.testing.expect(v.compaction != null);
    try std.testing.expectEqualStrings(llm_healthy, v.compaction.?.summary);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    // The session layer in the final view carries the LLM text.
    var saw_session = false;
    for (v.messages) |m| {
        if (m.role == .system and std.mem.indexOf(u8, m.content, llm_healthy) != null) saw_session = true;
    }
    try std.testing.expect(saw_session);
}

test "compaction-llm: deterministic error aborts to heuristic byte-identical" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{.{ .err = .{ .kind = .deterministic, .message = "auth" } }} };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });

    // Immediate abort (no retries), heuristic summary used.
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "compaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, llm_healthy) == null);

    // Fallback identity: byte-identical to the no-summarizer run.
    const v0 = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
    }, .{ .system = "base" });
    try std.testing.expectEqual(v0.compaction.?.dropped, v.compaction.?.dropped);
    try std.testing.expectEqualStrings(v0.compaction.?.summary, v.compaction.?.summary);
}

test "compaction-llm: context_overflow aborts to heuristic immediately" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{.{ .err = .{ .kind = .context_overflow, .message = "ctx" } }} };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "compaction") != null);
}

test "compaction-llm: transient x3 falls back to heuristic" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
    } };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "compaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, llm_healthy) == null);
}

test "compaction-llm: degenerate x3 falls back to heuristic" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{
        .{ .ok = .{ .text = "tiny" } },
        .{ .ok = .{ .text = "tiny" } },
        .{ .ok = .{ .text = "tiny" } },
    } };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "compaction") != null);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, llm_healthy) == null);
}

test "compaction-llm: success after 2 transient retries uses LLM text" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .ok = .{ .text = llm_healthy } },
    } };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
    try std.testing.expectEqualStrings(llm_healthy, v.compaction.?.summary);
}

test "compaction-llm: INITIAL prompt without prior; UPDATE with layers.session prior" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    const opts = Options{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
    };

    // INITIAL: no prior session layer.
    var fake0 = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    _ = try viewForModel(std.testing.io, arena, &f.full, .{ .summarizer = llmSeam(&fake0), .max_tail_messages = opts.max_tail_messages, .max_chars = opts.max_chars, .min_tail_messages = opts.min_tail_messages }, .{ .system = "base" });
    const req0 = fake0.last_request.?;
    try std.testing.expect(std.mem.indexOf(u8, req0.prompt, "<conversation>\n[User]: u1") != null);
    try std.testing.expect(std.mem.indexOf(u8, req0.prompt, "## Goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, req0.prompt, "<previous-summary>") == null);
    try std.testing.expectEqualStrings(session_item.summarization_system_prompt, req0.system);
    // max_tokens = min(0.8 * reserve, provider_max): unlimited budget (max_chars
    // 0, max_tokens 0) → capped at provider_max 256.
    try std.testing.expectEqual(@as(u32, 256), req0.max_tokens);

    // UPDATE: prior summary from layers.session is embedded in tags.
    var fake1 = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    _ = try viewForModel(std.testing.io, arena, &f.full, .{ .summarizer = llmSeam(&fake1), .max_tail_messages = opts.max_tail_messages, .max_chars = opts.max_chars, .min_tail_messages = opts.min_tail_messages }, .{ .system = "base", .session = "PRIOR-LLM-SUMMARY" });
    const req1 = fake1.last_request.?;
    try std.testing.expect(std.mem.indexOf(u8, req1.prompt, "<previous-summary>\nPRIOR-LLM-SUMMARY\n</previous-summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, req1.prompt, "PRESERVE all existing information from the previous summary") != null);
    try std.testing.expectEqualStrings(session_item.summarization_system_prompt, req1.system);

    // max_tokens respects an explicit small token budget: 0.8 * 315 = 252
    // (below the 256 cap; 4 * 252 = 1008 >= 500 so the skip guard passes).
    var fake2 = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    _ = try viewForModel(std.testing.io, arena, &f.full, .{ .summarizer = llmSeam(&fake2), .max_tail_messages = opts.max_tail_messages, .max_chars = 0, .max_tokens = 315, .min_tail_messages = opts.min_tail_messages }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 252), fake2.last_request.?.max_tokens);
}

test "compaction-llm: single LLM call after fixed-point convergence" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Char pressure forces the fixed-point loop past the first iteration; the
    // LLM is consulted exactly once, over the final omitted set.
    const pad = "X" ** 80;
    const full = [_]message.Message{
        .system("sys"),
        .user("early-1 " ++ pad),
        .assistantText("early-a1 " ++ pad),
        .user("early-2 " ++ pad),
        .assistantText("early-a2 " ++ pad),
        .user("mid-1 " ++ pad),
        .assistantText("mid-a1 " ++ pad),
        .user("late-u"),
        .assistantText("late-a"),
    };
    var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    // max_tokens 1000 keeps the skip guard away (4 * min(0.8*1000, 256) =
    // 1024 >= 500); max_chars 420 still forces the fixed-point loop.
    const v = try viewForModel(std.testing.io, arena, &full, .{
        .max_tail_messages = 0,
        .max_chars = 420,
        .max_tokens = 1000,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base-system" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
    try std.testing.expectEqualStrings(llm_healthy, v.compaction.?.summary);
    // Final omitted set = the event's dropped prefix (heuristic convergence).
    try std.testing.expect(v.compaction.?.dropped > 2);
}

test "compaction-llm: LLM text routed through budget clamp and UTF-8 sanitize" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    // 5000-char text with an invalid trailing byte; 100-char summary budget.
    var raw: [5000]u8 = undefined;
    @memset(&raw, 'a');
    raw[4999] = 0xFF;
    var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = &raw } }} };
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 100,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    const sum = v.compaction.?.summary;
    try std.testing.expect(sum.len <= 100);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sum));
    // Clamped to exactly the 100-byte ASCII prefix (before the invalid byte).
    try std.testing.expectEqual(@as(usize, 100), sum.len);
    try std.testing.expect(std.mem.eql(u8, sum, "a" ** 100));
}

test "compaction-llm: skip guard avoids summarizer on tiny token budget" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    // max_tokens 40 → request max_tokens = min(0.8*40, 256) = 32 →
    // 4 * 32 = 128 < 500 → skip guard fires: summarizer never called.
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .max_tokens = 40,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base" });
    try std.testing.expectEqual(@as(u32, 0), fake.calls);
    // Compaction still happened; heuristic summary stands (dropped header).
    try std.testing.expect(v.compaction != null);
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, "[compaction]") != null);
}

test "compaction-llm: LLM-path allocation failure is absorbed (heuristic stands)" {
    const gpa = std.testing.allocator;
    const f = llmFixture();
    var saw_llm_called: u32 = 0;
    var saw_main_oom: u32 = 0;
    var idx: usize = 0;
    while (idx < 96) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = idx });
        var arena_impl = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();
        var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
        const result = viewForModel(std.testing.io, arena, &f.full, .{
            .max_tail_messages = 2,
            .max_chars = 0,
            .min_tail_messages = 2,
            .summarizer = llmSeam(&fake),
        }, .{ .system = "base" });
        if (result) |v| {
            // Success: the view must always be complete (heuristic summary
            // stands even when the LLM replacement point absorbed an OOM).
            try std.testing.expect(v.compaction != null);
            if (fake.calls > 0) saw_llm_called += 1;
        } else |err| {
            // Main-path OOM must be induced, never masked.
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expect(failing.has_induced_failure);
            saw_main_oom += 1;
        }
    }
    // The injection was effective (main-path OOMs observed) and the LLM
    // path was actually exercised on successful runs (catch not dead code).
    try std.testing.expect(saw_main_oom > 0);
    try std.testing.expect(saw_llm_called > 0);
}

test "compaction-llm: lineage record survives composition at realistic sizes" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const f = llmFixture();
    var prior: [700]u8 = undefined;
    @memset(&prior, 'p');
    var fake = LlmFake{ .results = &.{.{ .ok = .{ .text = llm_healthy } }} };
    // Large LLM text (719B) + 700B prior under the 800B cap: the lineage
    // reservation must keep the truncated lineage record present.
    const v = try viewForModel(std.testing.io, arena, &f.full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summarizer = llmSeam(&fake),
    }, .{ .system = "base", .session = &prior });
    try std.testing.expect(v.compaction != null);
    const sum = v.compaction.?.summary;
    try std.testing.expect(sum.len <= summary_cap);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sum));
    // Lineage chain preserved (truncated record with digest).
    try std.testing.expect(std.mem.indexOf(u8, sum, "prior_bytes=700") != null);
    try std.testing.expect(std.mem.indexOf(u8, sum, lineage_truncated_marker) != null);
}
