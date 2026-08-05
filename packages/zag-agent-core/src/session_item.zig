//! Session-item semantics — Core-owned conversation-model helpers
//! (session-item-001).
//!
//! D-011: Core is the single authoritative source for bundle-legality logic,
//! so this module lives next to `protocol_history.zig` and reuses its
//! `alignToLegalStart`/`unitEnd` (no mirrored copies). Pure functions only;
//! token-estimation arithmetic (IMAGE_TOKENS / estimateTokens /
//! estimateMessageTokens) lives in `zag-types` (L0).
//!
//! Scope (per docs/modules/session-item.md + docs/modules/chat-state-prune.md
//! + docs/modules/compaction-llm.md):
//! - monotone `prompt_index` turn accounting;
//! - tolerant dangling-tool-call repair (drop-only, pre-gate);
//! - duplicate tool-result dedup (drop-only, carrier-scoped keep-last, pre-gate);
//! - token-budget truncate-for-prompt with bundle legality + min_tail;
//! - prompt-index rewind cut (legacy / marker / mixed modes);
//! - LLM compaction-summary helpers: role-tagged serialization, INITIAL/UPDATE
//!   prompts, Rust-style cleaning + degenerate detection, retry ladder over
//!   the `CompactionSummarizer` seam (types in `zag-types`; no provider IO).
//!
//! Deliberate divergence from the historical Rust port: no BackendToolCall,
//! no Compaction/Codex encrypted item, no ReasoningModelIdentity replay
//! gating, no Kimi dialect, no doom-loop, no cache breakpoints
//! (grok/xAI-specific; zag has no such route).

const std = @import("std");
const ztypes = @import("zag-types");
const protocol_history = @import("protocol_history.zig");

const Message = ztypes.Message;

/// Sum token estimate over a slice (uses zag-types arithmetic).
fn estimateMessageTokensSlice(items: []const Message) usize {
    var n: usize = 0;
    for (items) |*m| n += ztypes.estimateMessageTokens(m);
    return n;
}

/// Character weight (estimateChars sum) over a slice — used for
/// `TruncateResult.dropped_chars` accounting.
fn estimateChars(items: []const Message) usize {
    var n: usize = 0;
    for (items) |m| n += m.estimateChars();
    return n;
}

/// Assign `prompt_index` to rows lacking one (monotone prompt-turn accounting).
///
/// Pinned algorithm (contract):
/// - the turn counter increments ONLY at rows that start a turn — `.user`
///   rows, and synthetic rows with `prompt_index == null` — and only when a
///   stamp is applied;
/// - every stamped row receives the new/current turn index, so
///   assistant/tool rows and already-stamped synthetic rows share their
///   turn's index;
/// - rows that already carry an index are left untouched and do not advance
///   the counter (idempotent re-runs);
/// - resume: pass the persisted max as `next` — the first new `.user` row
///   lands on `max + 1`; the returned value is then persisted as the new max.
pub fn assignPromptIndices(items: []Message, next: u32) u32 {
    var counter = next;
    for (items) |*m| {
        if (m.prompt_index != null) continue;
        if (m.role == .user or m.synthetic) counter +%= 1;
        m.prompt_index = counter;
    }
    return counter;
}

/// Tolerant pre-gate repair pass (drop-only; never creates or reorders).
///
/// - drops `tool` rows whose `tool_call_id` has no preceding assistant
///   `tool_calls` entry with the same id;
/// - drops `tool` rows with empty content AND empty tool_call_id
///   (null or empty id both count as empty);
/// - leaves every legal bundle byte-identical;
/// - never creates or reorders content.
///
/// Returns `null` when nothing was dropped (caller reuses the input slice);
/// an owned slice otherwise. The caller MUST still run
/// `protocol_history.validateBodyHistory` — repair is not a substitute for
/// the fail-closed gate.
pub fn repairDanglingToolCalls(
    allocator: std.mem.Allocator,
    items: []const Message,
) error{OutOfMemory}!?[]const Message {
    const keep = try allocator.alloc(bool, items.len);
    defer allocator.free(keep);

    var call_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer call_ids.deinit(allocator);

    var dropped: usize = 0;
    for (items, 0..) |m, i| {
        if (m.role == .tool) {
            const id = m.tool_call_id orelse "";
            const empty_carrier = m.content.len == 0 and id.len == 0;
            const known = id.len > 0 and call_ids.contains(id);
            if (empty_carrier or !known) {
                keep[i] = false;
                dropped += 1;
                continue;
            }
            keep[i] = true;
        } else {
            keep[i] = true;
            if (m.role == .assistant) {
                if (m.tool_calls) |calls| {
                    for (calls) |c| {
                        if (c.id.len > 0) {
                            try call_ids.put(allocator, c.id, {});
                        }
                    }
                }
            }
        }
    }

    if (dropped == 0) return null;
    const out = try allocator.alloc(Message, items.len - dropped);
    var o: usize = 0;
    for (items, 0..) |m, i| {
        if (keep[i]) {
            out[o] = m;
            o += 1;
        }
    }
    return out;
}

/// Tolerant pre-gate duplicate-result pass (drop-only; never creates or
/// reorders). Runs AFTER `repairDanglingToolCalls` in the combined pre-gate
/// (chat-state-prune-001 binding §2): repair first drops unknown/empty rows,
/// then dedup collapses repeats.
///
/// **Carrier-scoped** (binding §2): tool-result ids are only meaningful within
/// the carrier bundle that declared them.
/// - the seen-set resets at each assistant-with-tool-calls row;
/// - within one carrier's CONTIGUOUS result run (the tool rows immediately
///   following the carrier), a repeated non-empty `tool_call_id` keeps the
///   LAST occurrence and drops earlier ones (deterministic keep-last);
/// - cross-carrier id reuse is legal and untouched (validateCallIds enforces
///   uniqueness only within one bundle);
/// - interleaved within-run repeats (`r(c1), r(c2), r(c1)`) are NOT rescued:
///   keep-last leaves `r(c2), r(c1)`, whose order no longer matches the call
///   list, so `validateBodyHistory` still rejects them;
/// - tool rows OUTSIDE any carrier run are left for the gate; empty-id rows
///   follow the existing repair rule for empty carriers (empty content AND
///   empty id → dropped);
/// - a single-occurrence legal view is left byte-identical (`null`).
///
/// Returns `null` when nothing was dropped (caller reuses the input slice);
/// an owned slice otherwise. The caller MUST still run
/// `protocol_history.validateBodyHistory` — dedup is not a substitute for the
/// fail-closed gate (incomplete / out-of-order / dup-call-id / empty-call-id
/// bundles still reject).
pub fn dedupDuplicateToolResults(
    allocator: std.mem.Allocator,
    items: []const Message,
) error{OutOfMemory}!?[]const Message {
    const keep = try allocator.alloc(bool, items.len);
    defer allocator.free(keep);

    var last_result: std.StringHashMapUnmanaged(usize) = .empty;
    defer last_result.deinit(allocator);

    var dropped: usize = 0;
    var i: usize = 0;
    while (i < items.len) {
        const m = items[i];
        if (m.role == .assistant) {
            keep[i] = true;
            const has_calls = m.tool_calls != null and m.tool_calls.?.len > 0;
            if (has_calls) {
                // New carrier: the seen-set resets here. Its contiguous result
                // run is the following block of tool rows.
                var run_end = i + 1;
                while (run_end < items.len and items[run_end].role == .tool) : (run_end += 1) {}

                // Pass 1: remember the LAST index of each non-empty id in the run.
                last_result.clearRetainingCapacity();
                for (items[i + 1 .. run_end], i + 1..) |t, idx| {
                    const rid = t.tool_call_id orelse "";
                    if (rid.len == 0) continue;
                    try last_result.put(allocator, rid, idx);
                }
                // Pass 2: only the last occurrence per id survives; empty-id
                // rows follow the empty-carrier repair rule.
                for (i + 1..run_end) |idx| {
                    const t = items[idx];
                    const rid = t.tool_call_id orelse "";
                    if (rid.len == 0) {
                        if (t.content.len == 0) {
                            keep[idx] = false;
                            dropped += 1;
                        } else {
                            keep[idx] = true;
                        }
                        continue;
                    }
                    const last = last_result.get(rid) orelse {
                        // Unreachable: pass 1 stored every non-empty id.
                        keep[idx] = true;
                        continue;
                    };
                    if (last != idx) {
                        keep[idx] = false; // earlier duplicate — the LAST survives
                        dropped += 1;
                    } else {
                        keep[idx] = true;
                    }
                }
                i = run_end;
                continue;
            }
            i += 1;
            continue;
        }
        if (m.role != .tool) {
            keep[i] = true;
            i += 1;
            continue;
        }
        // Tool row outside any carrier run: only the empty-carrier repair rule
        // applies; dedup only collapses repeats within a carrier's run.
        const id = m.tool_call_id orelse "";
        if (id.len == 0) {
            if (m.content.len == 0) {
                keep[i] = false;
                dropped += 1;
            } else {
                keep[i] = true;
            }
        } else {
            keep[i] = true;
        }
        i += 1;
    }

    if (dropped == 0) return null;
    const out = try allocator.alloc(Message, items.len - dropped);
    var o: usize = 0;
    for (items, 0..) |m, idx| {
        if (keep[idx]) {
            out[o] = m;
            o += 1;
        }
    }
    return out;
}

/// Result of a token-budget truncate: the kept tail (always a subslice of the
/// input — no copy is made), plus the dropped row count and dropped character
/// weight for compaction accounting.
pub const TruncateResult = struct {
    kept: []const Message,
    dropped: usize,
    dropped_chars: usize,
};

/// Token-budget truncate from the front, preserving bundle legality
/// (assistant-with-tool-calls + its contiguous tool results stay together)
/// and `min_tail` recent rows (soft budget: a unit may span multiple rows, so
/// the kept tail can exceed `min_tail`; the loop terminates honestly even
/// when still over budget).
///
/// - `budget_tokens == 0` → nothing fits: keep only the `min_tail` tail
///   (empty when `min_tail == 0` — the caller sees `dropped == items.len` and
///   emits a compaction event).
/// - input rows are assumed bundle-legal (e.g. after `repairDanglingToolCalls`
///   + `validateBodyHistory`); a `min_tail` boundary landing inside tool
///   results walks back to the carrier assistant via
///   `protocol_history.alignToLegalStart`.
///
/// The allocator is accepted for signature parity with the other helpers; the
/// kept slice aliases `items` and no copy is made.
pub fn truncateForPrompt(
    allocator: std.mem.Allocator,
    items: []const Message,
    budget_tokens: usize,
    min_tail: usize,
) !TruncateResult {
    _ = allocator;

    var start: usize = 0;
    if (budget_tokens == 0) {
        const boundary = if (min_tail >= items.len) 0 else items.len - min_tail;
        start = protocol_history.alignToLegalStart(items, boundary) catch items.len;
        return finish(items, start);
    }

    var total = estimateMessageTokensSlice(items);
    while (items.len - start > min_tail) {
        if (total <= budget_tokens) break;
        const next = protocol_history.unitEnd(items, start);
        if (next <= start or next > items.len) break;
        // Keep min_tail messages; a unit may span multiple messages.
        if (items.len - next < min_tail) break;
        total -= estimateMessageTokensSlice(items[start..next]);
        start = next;
    }
    return finish(items, start);
}

fn finish(items: []const Message, start: usize) TruncateResult {
    return .{
        .kept = items[start..],
        .dropped = start,
        .dropped_chars = estimateChars(items[0..start]),
    };
}

/// Result of a prompt-index rewind cut: everything at/after the row that
/// starts turn `target_prompt_index` is dropped; `kept` is a subslice of the
/// input (no copy is made).
pub const TruncateToPromptResult = struct {
    kept: []const Message,
    dropped: usize,
};

/// Prompt-index rewind cut (chat-state-prune-001; v1 API + fixtures only, not
/// wired into the loop).
///
/// The cut lands on the row that STARTS turn `target_prompt_index`: a `.user`
/// row or a null-index synthetic row (the assignPromptIndices rule) whose
/// assigned index equals the target. Everything at/after the cut row is
/// dropped; `kept` ends at the last row before the cut.
///
/// Two modes (binding §2):
/// - **legacy** (no `prompt_index` marker anywhere): turn-start rows are
///   counted in transcript order — the first user is turn 1 (NO preamble
///   concept in zag); null-index synthetic rows count as turn starts. The
///   counter starts at `next_counter` (resume seed, same coordinate space as
///   `assignPromptIndices`), so the first turn-start row is
///   `next_counter + 1`.
/// - **marker** (markers exist): rows before the first marker are
///   legacy-counted; from the first marker onward only MARKED rows open cuts
///   (unmarked mid-turn phantoms never open a cut). Marked rows carry their
///   index from `assignPromptIndices` stamping, where only `.user` and
///   null-index synthetic rows receive post-increment (turn-start) indices.
///   Mixed mode: stamped rows by stamp, unstamped rows by legacy order.
///
/// Target beyond the last turn → keep everything (`dropped = 0`). The cut row
/// is always a `.user`/synthetic row — never a tool result — so the kept
/// prefix never splits a tool-call/result bundle (asserted in debug builds).
pub fn truncateToPromptIndex(
    items: []const Message,
    target_prompt_index: u32,
    next_counter: u32,
) TruncateToPromptResult {
    const first_marker = firstMarkedIndex(items);
    if (first_marker) |fm| {
        return cutWithMarkers(items, target_prompt_index, next_counter, fm);
    }
    return cutLegacy(items, target_prompt_index, next_counter);
}

fn firstMarkedIndex(items: []const Message) ?usize {
    for (items, 0..) |m, i| {
        if (m.prompt_index != null) return i;
    }
    return null;
}

fn cutLegacy(
    items: []const Message,
    target: u32,
    next_counter: u32,
) TruncateToPromptResult {
    var counter: u32 = next_counter;
    for (items, 0..) |m, i| {
        // Turn-start rows: .user rows and null-index synthetic rows. The
        // first user is turn 1 (no preamble concept in zag).
        const starts_turn = m.role == .user or m.synthetic;
        if (!starts_turn) continue;
        counter +%= 1;
        if (counter == target) return finishCut(items, i);
    }
    return .{ .kept = items, .dropped = 0 };
}

fn cutWithMarkers(
    items: []const Message,
    target: u32,
    next_counter: u32,
    first_marker: usize,
) TruncateToPromptResult {
    var counter: u32 = next_counter;
    for (items, 0..) |m, i| {
        if (i < first_marker) {
            // Pre-marker prefix: legacy counting (first user = turn 1).
            const starts_turn = m.role == .user or m.synthetic;
            if (!starts_turn) continue;
            counter +%= 1;
            if (counter == target) return finishCut(items, i);
        } else {
            // From the first marker onward: only marked rows open cuts.
            const idx = m.prompt_index orelse continue; // mid-turn phantom
            const starts_turn = m.role == .user or m.synthetic;
            if (!starts_turn) continue;
            if (idx == target) return finishCut(items, i);
        }
    }
    return .{ .kept = items, .dropped = 0 };
}

fn finishCut(items: []const Message, cut: usize) TruncateToPromptResult {
    // The cut row starts a turn (.user / synthetic) — never a tool result, so
    // the kept prefix cannot split a tool-call/result bundle.
    std.debug.assert(items[cut].role != .tool);
    return .{ .kept = items[0..cut], .dropped = items.len - cut };
}

// ── compaction-llm-001: summary serialization / prompts / cleaning / retry ──
//
// Pure helpers for LLM compaction summaries (docs/modules/compaction-llm.md):
// pi-style role-tagged serialization, INITIAL/UPDATE prompt building, Rust
// `format_compact_summary` cleaning semantics, degenerate detection, and the
// retry ladder. The provider call itself arrives via the
// `CompactionSummarizer` seam (zag-types) — Core never talks to a provider.

/// Tool-result truncation ceiling for serialized summaries (pi `TOOL_RESULT_MAX_CHARS`).
pub const TOOL_RESULT_MAX_CHARS: usize = 2000;
/// Visible-character floor below which a cleaned summary is degenerate (Rust `MIN_SUMMARY_SEED_CHARS`).
pub const MIN_SUMMARY_SEED_CHARS: usize = 500;
/// Retry ladder defaults (binding §2): at most 3 attempts, 3 s between retries.
pub const default_summary_max_attempts: u8 = 3;
pub const default_summary_retry_delay_ms: u64 = 3000;

/// Prompt bundle returned by `buildSummaryPrompts` (binding §2).
pub const SummaryPrompts = struct {
    system: []u8, // pi SUMMARIZATION_SYSTEM_PROMPT
    prompt: []u8, // INITIAL or UPDATE (prior embedded in <previous-summary>)
};

/// pi `SUMMARIZATION_SYSTEM_PROMPT` (compaction/utils.ts) — verbatim.
pub const summarization_system_prompt =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

/// pi `SUMMARIZATION_PROMPT` (compaction.ts:467-498) — structured checkpoint
/// skeleton, verbatim.
pub const summarization_prompt =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

/// pi `UPDATE_SUMMARIZATION_PROMPT` (compaction.ts:500-537) — verbatim.
pub const update_summarization_prompt =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

/// Serialize messages to role-tagged flat text for summarization (pi
/// `serializeConversation`, binding §2). Tool results truncated at
/// `TOOL_RESULT_MAX_CHARS` with `[... N more characters truncated]`; reasoning
/// emitted as `[Assistant thinking]` when set; content parts joined with `\n`,
/// images as `[image: {url}]`; empty-content rows are omitted (pi semantics).
pub fn serializeConversationForSummary(
    allocator: std.mem.Allocator,
    items: []const Message,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var need_sep = false;
    for (items) |m| {
        const content = try contentTextOwned(allocator, m);
        defer if (content.owned) allocator.free(content.text);
        const text = content.text;

        switch (m.role) {
            .system => {
                if (text.len == 0) continue;
                try appendSummaryPart(&out, &need_sep);
                try wprint(&out.writer, "[System]: {s}", .{text});
            },
            .user => {
                if (text.len == 0) continue;
                try appendSummaryPart(&out, &need_sep);
                try wprint(&out.writer, "[User]: {s}", .{text});
            },
            .assistant => {
                if (m.reasoning) |r| {
                    if (r.len > 0) {
                        try appendSummaryPart(&out, &need_sep);
                        try wprint(&out.writer, "[Assistant thinking]: {s}", .{r});
                    }
                }
                if (text.len > 0) {
                    try appendSummaryPart(&out, &need_sep);
                    try wprint(&out.writer, "[Assistant]: {s}", .{text});
                }
                if (m.tool_calls) |calls| {
                    if (calls.len > 0) {
                        try appendSummaryPart(&out, &need_sep);
                        try wprint(&out.writer, "[Assistant tool calls]: ", .{});
                        for (calls, 0..) |c, i| {
                            if (i > 0) try wprint(&out.writer, "; ", .{});
                            try wprint(&out.writer, "{s}({s}, {s})", .{ c.name, c.id, c.arguments });
                        }
                    }
                }
            },
            .tool => {
                if (text.len == 0) continue;
                try appendSummaryPart(&out, &need_sep);
                try wprint(&out.writer, "[Tool result]: ", .{});
                const keep = @min(text.len, TOOL_RESULT_MAX_CHARS);
                try wprint(&out.writer, "{s}", .{text[0..keep]});
                if (text.len > TOOL_RESULT_MAX_CHARS) {
                    try wprint(&out.writer, "\n\n[... {d} more characters truncated]", .{text.len - TOOL_RESULT_MAX_CHARS});
                }
            },
        }
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Build INITIAL or UPDATE summarization prompts (binding §2). The UPDATE
/// prompt embeds the prior summary in `<previous-summary>…</previous-summary>`
/// before the pi update prompt; the caller prepends the serialized
/// conversation (wrapped in `<conversation>` tags) as the single user message.
pub fn buildSummaryPrompts(
    allocator: std.mem.Allocator,
    prior_summary: ?[]const u8,
) error{OutOfMemory}!SummaryPrompts {
    const system = try allocator.dupe(u8, summarization_system_prompt);
    errdefer allocator.free(system);
    if (prior_summary) |prior| {
        if (prior.len > 0) {
            const prompt = try std.fmt.allocPrint(
                allocator,
                "<previous-summary>\n{s}\n</previous-summary>\n\n{s}",
                .{ prior, update_summarization_prompt },
            );
            return .{ .system = system, .prompt = prompt };
        }
    }
    return .{ .system = system, .prompt = try allocator.dupe(u8, summarization_prompt) };
}

/// Rust `format_compact_summary` semantics (binding §2):
/// - strip leading `<analysis>…</analysis>` blocks (loop; unclosed → drop to
///   the next `<summary>` or the end);
/// - convert an outer `<summary>…</summary>` wrapper to `Summary:\n{inner}`
///   (trailing content after the wrapper is dropped);
/// - neutralize control tokens: insert U+200B after `<` in
///   `<summary>/</summary>/<analysis>/</analysis>/<summary_request>/</summary_request>`;
/// - collapse runs of 3+ newlines to exactly 2; trim.
pub fn formatCompactSummary(
    allocator: std.mem.Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    // 1. Strip leading <analysis> blocks (loop; unclosed → next <summary> or end).
    var text: []const u8 = std.mem.trim(u8, buf, " \t\r\n");
    while (std.mem.startsWith(u8, text, "<analysis>")) {
        if (std.mem.indexOf(u8, text, "</analysis>")) |close| {
            text = std.mem.trim(u8, text[close + "</analysis>".len ..], " \t\r\n");
            continue;
        }
        text = if (std.mem.indexOf(u8, text, "<summary>")) |s|
            std.mem.trim(u8, text[s..], " \t\r\n")
        else
            "";
        break;
    }

    // 2. Convert the outer <summary>…</summary> wrapper to "Summary:\n{inner}".
    const inner: ?[]const u8 = if (std.mem.startsWith(u8, text, "<summary>"))
        if (std.mem.indexOf(u8, text, "</summary>")) |close|
            text["<summary>".len..close]
        else
            null
    else
        null;

    var assembled: std.Io.Writer.Allocating = .init(allocator);
    defer assembled.deinit();
    if (inner) |i| {
        try wprint(&assembled.writer, "Summary:\n{s}", .{i});
    } else {
        try wprint(&assembled.writer, "{s}", .{text});
    }

    // 3. Neutralize control tokens (insert U+200B after '<' in the six tags).
    const neutralized = try neutralizeControlTags(allocator, assembled.written());
    defer allocator.free(neutralized);

    // 4. Collapse runs of 3+ newlines to exactly 2.
    const collapsed = try collapseNewlines(allocator, neutralized);
    defer allocator.free(collapsed);

    // 5. Trim and return an owned copy.
    const trimmed = std.mem.trim(u8, collapsed, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

/// Degenerate when the whitespace-stripped visible char count is below
/// `MIN_SUMMARY_SEED_CHARS` (binding §2; Rust `is_degenerate_summary`).
pub fn isDegenerateSummary(cleaned: []const u8) bool {
    return visibleCharCount(cleaned) < MIN_SUMMARY_SEED_CHARS;
}

/// Retry ladder (binding §2): per attempt, `ok` → clean + degenerate check
/// (degenerate counts as a transient retry); `.deterministic` /
/// `.context_overflow` abort immediately; `.timeout` / `.transient` retry
/// after `delay_ms`. Returns the cleaned text on success, `null` after the
/// final failure (caller falls back to the heuristic summary).
///
/// `io` is required for the inter-attempt sleeps (`std.Io.sleep`); the
/// caller (product context layer) owns the handle.
pub fn summarizeWithRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    summarizer: ztypes.CompactionSummarizer,
    request: ztypes.SummaryRequest,
    max_attempts: u8,
    delay_ms: u64,
) error{OutOfMemory}!?[]u8 {
    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        switch (summarizer.summarize(request)) {
            .ok => |res| {
                const cleaned = try formatCompactSummary(allocator, res.text);
                if (!isDegenerateSummary(cleaned)) return cleaned;
                allocator.free(cleaned); // degenerate → transient retry
            },
            .err => |e| switch (e.kind) {
                .deterministic, .context_overflow => return null,
                .timeout, .transient => {},
            },
        }
        if (delay_ms > 0 and attempt + 1 < max_attempts) {
            const ns: i96 = @intCast(@as(u64, delay_ms) *% std.time.ns_per_ms);
            std.Io.sleep(io, .{ .nanoseconds = ns }, .real) catch {};
        }
    }
    return null;
}

// ── compaction-llm-001 internals ────────────────────────────────────────────

/// `Io.Writer.print` mapped onto the pure `{OutOfMemory}` surface: the
/// Allocating writer only reports `WriteFailed` when growing its buffer OOMs.
fn wprint(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    w.print(fmt, args) catch return error.OutOfMemory;
}

/// Joined role content: `content_parts` (text verbatim, images as
/// `[image: {url}]`, parts joined with `\n`) or plain `content`.
/// `owned` marks slices that must be freed by the caller.
fn contentTextOwned(
    allocator: std.mem.Allocator,
    m: Message,
) error{OutOfMemory}!struct { text: []const u8, owned: bool } {
    const parts = m.content_parts orelse return .{ .text = m.content, .owned = false };
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    for (parts, 0..) |p, i| {
        if (i > 0) try wprint(&buf.writer, "\n", .{});
        switch (p) {
            .text => |t| try wprint(&buf.writer, "{s}", .{t}),
            .image_url => |img| try wprint(&buf.writer, "[image: {s}]", .{img.url}),
        }
    }
    return .{ .text = try buf.toOwnedSlice(), .owned = true };
}

/// Append the "\n\n" row separator before a non-first part (pi joins parts
/// with "\n\n" — between rows and between sub-blocks of one assistant row).
fn appendSummaryPart(
    out: *std.Io.Writer.Allocating,
    need_sep: *bool,
) error{OutOfMemory}!void {
    if (need_sep.*) try wprint(&out.writer, "\n\n", .{});
    need_sep.* = true;
}

/// Insert U+200B after '<' in the six control tags so the summary text cannot
/// be re-parsed as instruction blocks.
fn neutralizeControlTags(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const tags = [_][]const u8{
        "<summary>",
        "</summary>",
        "<analysis>",
        "</analysis>",
        "<summary_request>",
        "</summary_request>",
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            for (tags) |t| {
                if (i + t.len <= text.len and std.mem.eql(u8, text[i .. i + t.len], t)) {
                    try wprint(&out.writer, "<\u{200B}{s}", .{t[1..]});
                    i += t.len;
                    break;
                }
            } else {
                try wprint(&out.writer, "{c}", .{text[i]});
                i += 1;
            }
            continue;
        }
        try wprint(&out.writer, "{c}", .{text[i]});
        i += 1;
    }
    return try out.toOwnedSlice();
}

/// Collapse runs of 3+ '\n' to exactly 2 ('\n' only; other whitespace untouched).
fn collapseNewlines(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var run: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            run += 1;
            if (run > 2) continue;
            try wprint(&out.writer, "\n", .{});
        } else {
            run = 0;
            try wprint(&out.writer, "{c}", .{c});
        }
    }
    return try out.toOwnedSlice();
}

/// Whitespace-stripped visible code-point count (Unicode White_Space).
fn visibleCharCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            n += 1; // invalid byte counts as visible (conservative)
            continue;
        };
        if (seq_len > s.len - i) {
            i += 1;
            n += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..seq_len]) catch {
            i += 1;
            n += 1;
            continue;
        };
        if (!isWhitespaceCodepoint(cp)) n += 1;
        i += seq_len;
    }
    return n;
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

// ── unit tests ──────────────────────────────────────────────────────────────

test "assignPromptIndices stamps monotone indices and returns next" {
    var items = [_]Message{
        Message.system("preamble"),
        Message.user("u1"),
        Message.assistantText("a1"),
        Message{ .role = .assistant, .content = "injected", .synthetic = true },
        Message.user("u2"),
        Message.toolResult("c1", "out"),
    };
    const next = assignPromptIndices(&items, 0);
    // Preamble: stamped without increment (shares the pre-turn counter).
    try std.testing.expectEqual(@as(?u32, 0), items[0].prompt_index);
    try std.testing.expectEqual(@as(?u32, 1), items[1].prompt_index);
    try std.testing.expectEqual(@as(?u32, 1), items[2].prompt_index);
    // Synthetic row with null index begins a new turn.
    try std.testing.expectEqual(@as(?u32, 2), items[3].prompt_index);
    try std.testing.expectEqual(@as(?u32, 3), items[4].prompt_index);
    // Tool row shares the current turn index.
    try std.testing.expectEqual(@as(?u32, 3), items[5].prompt_index);
    // Returned counter is the last assigned turn index (persist and pass back
    // as `next` so the next batch continues from 4).
    try std.testing.expectEqual(@as(u32, 3), next);
}

test "assignPromptIndices resume assigns next after persisted max" {
    var items = [_]Message{
        Message{ .role = .user, .content = "old", .prompt_index = 7 },
        Message{ .role = .assistant, .content = "old-a", .prompt_index = 7 },
        Message.user("new-u"),
    };
    // Resume: rows already stamped stay untouched; pass the persisted max so
    // new rows continue from max + 1.
    const next = assignPromptIndices(&items, 7);
    try std.testing.expectEqual(@as(?u32, 7), items[0].prompt_index);
    try std.testing.expectEqual(@as(?u32, 7), items[1].prompt_index);
    try std.testing.expectEqual(@as(?u32, 8), items[2].prompt_index);
    try std.testing.expectEqual(@as(u32, 8), next);
}

test "assignPromptIndices idempotent on fully stamped rows" {
    var items = [_]Message{
        Message{ .role = .user, .content = "u", .prompt_index = 1 },
        Message{ .role = .assistant, .content = "a", .prompt_index = 1 },
    };
    const next = assignPromptIndices(&items, 2);
    try std.testing.expectEqual(@as(?u32, 1), items[0].prompt_index);
    try std.testing.expectEqual(@as(?u32, 1), items[1].prompt_index);
    try std.testing.expectEqual(@as(u32, 2), next);
}

test "repair leaves legal bundle byte-identical (null result)" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out1"),
        Message.toolResult("c2", "out2"),
        Message.user("done"),
    };
    const repaired = try repairDanglingToolCalls(gpa, &body);
    try std.testing.expect(repaired == null);
}

test "repair drops unmatched tool result (orphan)" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantText("no tools"),
        Message.toolResult("ghost", "nope"),
        Message.user("done"),
    };
    const repaired = (try repairDanglingToolCalls(gpa, &body)).?;
    defer gpa.free(repaired);
    try std.testing.expectEqual(@as(usize, 3), repaired.len);
    try std.testing.expect(repaired[0].role == .user);
    try std.testing.expect(repaired[1].role == .assistant);
    try std.testing.expect(repaired[2].role == .user);
}

test "repair drops empty-carrier tool row (empty content AND empty id)" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("ask"),
        Message{ .role = .tool, .content = "", .tool_call_id = "" },
        Message.assistantText("ok"),
    };
    const repaired = (try repairDanglingToolCalls(gpa, &body)).?;
    defer gpa.free(repaired);
    try std.testing.expectEqual(@as(usize, 2), repaired.len);
    try std.testing.expect(repaired[0].role == .user);
    try std.testing.expect(repaired[1].role == .assistant);

    // Null tool_call_id counts as empty for the empty-carrier rule.
    const body_null = [_]Message{
        Message.user("ask"),
        Message{ .role = .tool, .content = "" },
        Message.assistantText("ok"),
    };
    const repaired2 = (try repairDanglingToolCalls(gpa, &body_null)).?;
    defer gpa.free(repaired2);
    try std.testing.expectEqual(@as(usize, 2), repaired2.len);
}

test "repair drops dangling result with content but unknown id" {
    // A tool row with non-empty content but unknown id is a dangling result:
    // it MUST be dropped (unmatched id, no preceding assistant entry).
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantText("plain"),
        Message.toolResult("unknown-id", "has content"),
    };
    const repaired = (try repairDanglingToolCalls(gpa, &body)).?;
    defer gpa.free(repaired);
    try std.testing.expectEqual(@as(usize, 2), repaired.len);
}

test "repair mixed legal bundle + orphan keeps legal bundle" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "real-out"),
        Message.toolResult("ghost", "dangling"),
        Message.user("done"),
    };
    const repaired = (try repairDanglingToolCalls(gpa, &body)).?;
    defer gpa.free(repaired);
    try std.testing.expectEqual(@as(usize, 4), repaired.len);
    // Legal bundle preserved byte-identical in order.
    try std.testing.expect(repaired[0].role == .user);
    try std.testing.expect(repaired[1].role == .assistant);
    try std.testing.expectEqualStrings("c1", repaired[1].tool_calls.?[0].id);
    try std.testing.expect(repaired[2].role == .tool);
    try std.testing.expectEqualStrings("real-out", repaired[2].content);
    try std.testing.expectEqualStrings("done", repaired[3].content);
}

test "repair recognizes ids from any preceding assistant (late result kept)" {
    const gpa = std.testing.allocator;
    const calls_a = [_]ztypes.ToolCall{.{
        .id = "a1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const calls_b = [_]ztypes.ToolCall{.{
        .id = "b1",
        .name = "grep",
        .arguments = "{}",
    }};
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantToolCalls("", &calls_a),
        Message.toolResult("a1", "a-out"),
        Message.assistantToolCalls("", &calls_b),
        Message.toolResult("b1", "b-out"),
        Message.toolResult("a1", "late-a-out"), // answered by the FIRST assistant
        Message.user("done"),
    };
    // Every tool id has a preceding assistant entry, so nothing drops.
    const repaired = try repairDanglingToolCalls(gpa, &body);
    try std.testing.expect(repaired == null);
}

test "truncate budget boundary keeps only fitting tail" {
    const gpa = std.testing.allocator;
    // 4 messages × 40 bytes → 10 tokens each = 40 tokens total.
    const body = [_]Message{
        Message.user("u" ** 40),
        Message.assistantText("a" ** 40),
        Message.user("u" ** 40),
        Message.assistantText("a" ** 40),
    };
    const r = try truncateForPrompt(gpa, &body, 20, 0);
    try std.testing.expectEqual(@as(usize, 2), r.dropped);
    try std.testing.expectEqual(@as(usize, 2), r.kept.len);
    try std.testing.expectEqualStrings("u" ** 40, r.kept[0].content);
    try std.testing.expectEqual(@as(usize, 80), r.dropped_chars);

    // Exact-fit budget keeps everything.
    const r2 = try truncateForPrompt(gpa, &body, 40, 0);
    try std.testing.expectEqual(@as(usize, 0), r2.dropped);
    try std.testing.expectEqual(@as(usize, 4), r2.kept.len);
}

test "truncate budget 0 with min_tail 0 yields empty" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("u1"),
        Message.assistantText("a1"),
    };
    const r = try truncateForPrompt(gpa, &body, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), r.kept.len);
    try std.testing.expectEqual(@as(usize, 2), r.dropped);
    try std.testing.expectEqual(@as(usize, 4), r.dropped_chars);
}

test "truncate keeps min_tail recent rows (soft budget)" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("user-message-1"),
        Message.assistantText("assistant-message-1"),
        Message.user("user-message-2"),
        Message.assistantText("assistant-message-2"),
        Message.user("user-message-3"),
        Message.assistantText("assistant-message-3"),
    };
    // Tiny budget (1 token); min_tail 2 must survive regardless.
    const r = try truncateForPrompt(gpa, &body, 1, 2);
    try std.testing.expectEqual(@as(usize, 2), r.kept.len);
    try std.testing.expectEqualStrings("user-message-3", r.kept[0].content);
    try std.testing.expectEqualStrings("assistant-message-3", r.kept[1].content);
    try std.testing.expectEqual(@as(usize, 4), r.dropped);
}

test "truncate budget 0 keeps only aligned min_tail" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    // min_tail 1 lands on the tool result → walk back to the carrier assistant
    // (bundle atomicity): kept = [assistant, tool].
    const body = [_]Message{
        Message.user("old"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out"),
    };
    const r = try truncateForPrompt(gpa, &body, 0, 1);
    try std.testing.expectEqual(@as(usize, 2), r.kept.len);
    try std.testing.expect(r.kept[0].role == .assistant);
    try std.testing.expect(r.kept[1].role == .tool);
    try std.testing.expectEqual(@as(usize, 1), r.dropped);
}

test "truncate bundle atomicity: assistant + results advance together" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.user("early"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("a1", "dir-out"),
        Message.toolResult("a2", "file-out"),
        Message.user("late"),
        Message.assistantText("done"),
    };
    // Budget 5 tokens: the first user (1 token) plus the whole 4-row bundle
    // (7 tokens) must drop as one unit, keeping exactly the last 2 rows.
    const r = try truncateForPrompt(gpa, &body, 5, 0);
    try std.testing.expectEqual(@as(usize, 4), r.dropped);
    try std.testing.expectEqual(@as(usize, 2), r.kept.len);
    try std.testing.expectEqualStrings("late", r.kept[0].content);
    // The dropped prefix is the whole 4-row bundle (assistant + both results),
    // never a split: tool results are only dropped together with their carrier.
    try std.testing.expectEqualStrings("early", body[0].content);
    try std.testing.expectEqualStrings("done", r.kept[1].content);
}

test "truncate never splits a legal bundle at the min_tail boundary" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const body = [_]Message{
        Message.user("old"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out"),
        Message.user("final"),
    };
    // min_tail 2 lands on the tool result → aligned to the carrier assistant.
    const r = try truncateForPrompt(gpa, &body, 0, 2);
    try std.testing.expectEqual(@as(usize, 3), r.kept.len);
    try std.testing.expect(r.kept[0].role == .assistant);
    try std.testing.expect(r.kept[0].tool_calls != null);
    try std.testing.expectEqualStrings("final", r.kept[2].content);
    try std.testing.expectEqual(@as(usize, 1), r.dropped);
}

test "truncate empty input" {
    const gpa = std.testing.allocator;
    const body: [0]Message = .{};
    const r = try truncateForPrompt(gpa, &body, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), r.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r.dropped);
    try std.testing.expectEqual(@as(usize, 0), r.dropped_chars);
}

// ── chat-state-prune-001 fixtures ───────────────────────────────────────────

test "dedup keeps the LAST occurrence of a repeated tool_call_id" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "first-answer"),
        Message.toolResult("c1", "last-answer"), // duplicated result row
        Message.user("done"),
    };
    const deduped = (try dedupDuplicateToolResults(gpa, &body)).?;
    defer gpa.free(deduped);
    try std.testing.expectEqual(@as(usize, 4), deduped.len);
    try std.testing.expect(deduped[0].role == .user);
    try std.testing.expect(deduped[1].role == .assistant);
    try std.testing.expect(deduped[2].role == .tool);
    try std.testing.expectEqualStrings("c1", deduped[2].tool_call_id.?);
    try std.testing.expectEqualStrings("last-answer", deduped[2].content);
    try std.testing.expectEqualStrings("done", deduped[3].content);
    // The deduped view is bundle-legal.
    try protocol_history.validateBodyHistory(deduped);
}

test "dedup preserves the order of other rows" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.user("u0"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("a1", "first"),
        Message.toolResult("a2", "mid"),
        Message.toolResult("a1", "last"),
        Message.user("u1"),
    };
    const deduped = (try dedupDuplicateToolResults(gpa, &body)).?;
    defer gpa.free(deduped);
    // Survivors keep their input order: a2 before the surviving (last) a1.
    try std.testing.expectEqual(@as(usize, 5), deduped.len);
    try std.testing.expectEqualStrings("u0", deduped[0].content);
    try std.testing.expectEqualStrings("mid", deduped[2].content);
    try std.testing.expectEqualStrings("last", deduped[3].content);
    try std.testing.expectEqualStrings("u1", deduped[4].content);
}

test "dedup leaves a single-occurrence legal view untouched (null)" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.user("ask"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out1"),
        Message.toolResult("c2", "out2"),
        Message.user("done"),
    };
    const deduped = try dedupDuplicateToolResults(gpa, &body);
    try std.testing.expect(deduped == null);
}

test "dedup + repair combined pass on mixed orphan + duplicate input" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    const body = [_]Message{
        Message.user("u0"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "first"),
        Message.toolResult("ghost", "orphan"), // dropped by repair (unknown id)
        Message.toolResult("c1", "second"), // survives dedup (last occurrence)
        Message.user("u1"),
    };
    const repaired = (try repairDanglingToolCalls(gpa, &body)).?;
    defer gpa.free(repaired);
    try std.testing.expectEqual(@as(usize, 5), repaired.len);
    const deduped = (try dedupDuplicateToolResults(gpa, repaired)).?;
    defer gpa.free(deduped);
    try std.testing.expectEqual(@as(usize, 4), deduped.len);
    try std.testing.expect(deduped[2].role == .tool);
    try std.testing.expectEqualStrings("second", deduped[2].content);
    try protocol_history.validateBodyHistory(deduped);
}

test "dedup drops empty-carrier rows per the repair rule" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user("u0"),
        Message.assistantText("a0"),
        Message{ .role = .tool, .content = "", .tool_call_id = "" },
        Message{ .role = .tool, .content = "" }, // null id counts as empty
        Message.user("u1"),
    };
    const deduped = (try dedupDuplicateToolResults(gpa, &body)).?;
    defer gpa.free(deduped);
    try std.testing.expectEqual(@as(usize, 3), deduped.len);
    try std.testing.expect(deduped[0].role == .user);
    try std.testing.expect(deduped[1].role == .assistant);
    try std.testing.expect(deduped[2].role == .user);
}

test "dedup is carrier-scoped: cross-carrier tool_call_id reuse is legal" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "list_dir",
        .arguments = "{}",
    }};
    // Carrier 2 reuses c1 from carrier 1 — ids are only meaningful within the
    // carrier bundle that declared them, so nothing may drop.
    const body = [_]Message{
        Message.user("u0"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out-1"),
        Message.user("u1"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "out-2"),
        Message.user("u2"),
    };
    const deduped = try dedupDuplicateToolResults(gpa, &body);
    try std.testing.expect(deduped == null);
    // The untouched view is bundle-legal: both bundles validate.
    try protocol_history.validateBodyHistory(&body);
}

test "dedup interleaved within-run repeats: NOT rescued (keep-last, then gate rejects)" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.user("u0"),
        Message.assistantToolCalls("", &calls),
        Message.toolResult("c1", "a"),
        Message.toolResult("c2", "b"),
        Message.toolResult("c1", "c"), // interleaved repeat
        Message.user("u1"),
    };
    // Keep-last collapses the run to r(c2), r(c1) — order no longer matches
    // the call list, so the fail-closed gate still rejects the deduped view.
    const deduped = (try dedupDuplicateToolResults(gpa, &body)).?;
    defer gpa.free(deduped);
    try std.testing.expectEqual(@as(usize, 5), deduped.len);
    try std.testing.expectEqualStrings("b", deduped[2].content);
    try std.testing.expectEqualStrings("c", deduped[3].content);
    try std.testing.expectError(
        error.InvalidContext,
        protocol_history.validateBodyHistory(deduped),
    );
}

test "truncateToPromptIndex legacy mode: first user is turn 1 (no preamble)" {
    const body = [_]Message{
        Message.user("u0"), // turn 1 — the FIRST user counts (no preamble in zag)
        Message.assistantText("a1"),
        Message.user("u1"), // turn 2
        Message.assistantText("a2"),
        Message.user("u2"), // turn 3
        Message.assistantText("a3"),
    };
    // Cut lands on the first user: nothing kept.
    const r1 = truncateToPromptIndex(&body, 1, 0);
    try std.testing.expectEqual(@as(usize, 0), r1.kept.len);
    try std.testing.expectEqual(@as(usize, 6), r1.dropped);

    const r2 = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 2), r2.kept.len);
    try std.testing.expectEqualStrings("u0", r2.kept[0].content);
    try std.testing.expectEqualStrings("a1", r2.kept[1].content);
    try std.testing.expectEqual(@as(usize, 4), r2.dropped);

    const r3 = truncateToPromptIndex(&body, 3, 0);
    try std.testing.expectEqual(@as(usize, 4), r3.kept.len);
    try std.testing.expectEqual(@as(usize, 2), r3.dropped);

    // Target beyond the last turn → keep everything.
    const r4 = truncateToPromptIndex(&body, 4, 0);
    try std.testing.expectEqual(@as(usize, 6), r4.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r4.dropped);
    // Turn indices start at 1: target 0 matches nothing.
    const r5 = truncateToPromptIndex(&body, 0, 0);
    try std.testing.expectEqual(@as(usize, 6), r5.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r5.dropped);
}

test "truncateToPromptIndex legacy mode: leading system rows consume no turn" {
    // Regression: a future "preamble" reintroduction must not make the first
    // user turn 2. System rows never open turns in zag.
    const body = [_]Message{
        Message.system("sys-preamble"),
        Message.system("more-sys"),
        Message.user("u0"), // turn 1 — first user counts despite system rows
        Message.assistantText("a1"),
        Message.user("u1"), // turn 2
        Message.assistantText("a2"),
    };
    const r1 = truncateToPromptIndex(&body, 1, 0);
    // Cut lands on u0 (turn 1): system rows before it are kept.
    try std.testing.expectEqual(@as(usize, 2), r1.kept.len);
    try std.testing.expectEqualStrings("sys-preamble", r1.kept[0].content);
    try std.testing.expectEqual(@as(usize, 4), r1.dropped);

    const r2 = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 4), r2.kept.len);
    try std.testing.expectEqualStrings("sys-preamble", r2.kept[0].content);
    try std.testing.expectEqualStrings("u0", r2.kept[2].content);
    try std.testing.expectEqual(@as(usize, 2), r2.dropped);
}

test "truncateToPromptIndex legacy mode counts null-index synthetic turn starts" {
    const body = [_]Message{
        Message.user("u0"), // turn 1
        Message.assistantText("a0"),
        Message{ .role = .assistant, .content = "s1", .synthetic = true }, // turn 2
        Message.user("u1"), // turn 3
    };
    const r1 = truncateToPromptIndex(&body, 1, 0);
    try std.testing.expectEqual(@as(usize, 0), r1.kept.len);
    try std.testing.expectEqual(@as(usize, 4), r1.dropped);
    const r2 = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 2), r2.kept.len);
    try std.testing.expectEqualStrings("s1", body[r2.kept.len].content);
    try std.testing.expectEqual(@as(usize, 2), r2.dropped);
    const r3 = truncateToPromptIndex(&body, 3, 0);
    try std.testing.expectEqual(@as(usize, 3), r3.kept.len);
    try std.testing.expectEqual(@as(usize, 1), r3.dropped);

    // No turn-start rows at all → any target keeps everything.
    const empty = [_]Message{
        Message.assistantText("a1"),
        Message.assistantText("a2"),
    };
    const r4 = truncateToPromptIndex(&empty, 1, 0);
    try std.testing.expectEqual(@as(usize, 2), r4.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r4.dropped);
}

test "truncateToPromptIndex marker mode uses contiguous marker values" {
    const body = [_]Message{
        Message{ .role = .system, .content = "sys", .prompt_index = 0 },
        Message{ .role = .user, .content = "u1", .prompt_index = 1 },
        Message{ .role = .assistant, .content = "a1", .prompt_index = 1 },
        Message{ .role = .user, .content = "u2", .prompt_index = 2 },
        Message{ .role = .assistant, .content = "a2", .prompt_index = 2 },
        Message{ .role = .user, .content = "u3", .prompt_index = 3 },
        Message{ .role = .assistant, .content = "a3", .prompt_index = 3 },
    };
    const r1 = truncateToPromptIndex(&body, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), r1.kept.len);
    try std.testing.expectEqualStrings("sys", r1.kept[0].content);
    try std.testing.expectEqual(@as(usize, 6), r1.dropped);

    const r2 = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 3), r2.kept.len);
    try std.testing.expectEqual(@as(usize, 4), r2.dropped);

    const r3 = truncateToPromptIndex(&body, 3, 0);
    try std.testing.expectEqual(@as(usize, 5), r3.kept.len);
    try std.testing.expectEqual(@as(usize, 2), r3.dropped);

    const r4 = truncateToPromptIndex(&body, 4, 0);
    try std.testing.expectEqual(@as(usize, 7), r4.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r4.dropped);
}

test "truncateToPromptIndex marker mode: mid-turn synthetics never open a cut" {
    const body = [_]Message{
        Message{ .role = .system, .content = "sys", .prompt_index = 0 },
        Message{ .role = .user, .content = "u1", .prompt_index = 1 },
        Message{ .role = .assistant, .content = "a1", .prompt_index = 1 },
        // Marked mid-turn synthetic (assistant role shares turn 1) — no cut.
        Message{ .role = .assistant, .content = "interjection", .synthetic = true, .prompt_index = 1 },
        Message{ .role = .user, .content = "u2", .prompt_index = 2 },
        Message{ .role = .assistant, .content = "a2", .prompt_index = 2 },
    };
    // Target 2 lands on u2 (index 4); the synthetic (index 3) is skipped.
    const r = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 4), r.kept.len);
    try std.testing.expectEqualStrings("u2", body[r.kept.len].content);
    try std.testing.expectEqual(@as(usize, 2), r.dropped);
}

test "truncateToPromptIndex marker+legacy mixed mode: prefix counted, phantoms ignored" {
    const body = [_]Message{
        Message.user("u0"), // unmarked, before the first marker: legacy turn 1
        Message.assistantText("a0"),
        Message{ .role = .user, .content = "u1", .prompt_index = 1 },
        Message{ .role = .assistant, .content = "a1", .prompt_index = 1 },
        Message{ .role = .user, .content = "u2", .prompt_index = 2 },
        Message{ .role = .assistant, .content = "a2", .prompt_index = 2 },
        Message.user("phantom"), // unmarked AFTER the first marker: never a cut
        Message.assistantText("a3"),
    };
    // Target 1 matches the unmarked prefix row by legacy counting (first user
    // = turn 1), which comes before the stamped u1 in transcript order.
    const r1 = truncateToPromptIndex(&body, 1, 0);
    try std.testing.expectEqual(@as(usize, 0), r1.kept.len);
    try std.testing.expectEqual(@as(usize, 8), r1.dropped);

    // Stamped rows open cuts by their stamp: target 2 lands on u2.
    const r2 = truncateToPromptIndex(&body, 2, 0);
    try std.testing.expectEqual(@as(usize, 4), r2.kept.len);
    try std.testing.expectEqualStrings("u2", body[r2.kept.len].content);
    try std.testing.expectEqual(@as(usize, 4), r2.dropped);

    // The phantom (unmarked, post-marker) opens no turn 3.
    const r3 = truncateToPromptIndex(&body, 3, 0);
    try std.testing.expectEqual(@as(usize, 8), r3.kept.len);
    try std.testing.expectEqual(@as(usize, 0), r3.dropped);
}

test "truncateToPromptIndex next_counter seeds legacy counting" {
    const body = [_]Message{
        Message.user("u0"), // first user = next_counter + 1 = 8 (no preamble)
        Message.assistantText("a0"),
        Message.user("u1"), // 9
        Message.assistantText("a1"),
    };
    const r1 = truncateToPromptIndex(&body, 8, 7);
    try std.testing.expectEqual(@as(usize, 0), r1.kept.len);
    try std.testing.expectEqual(@as(usize, 4), r1.dropped);

    const r2 = truncateToPromptIndex(&body, 9, 7);
    try std.testing.expectEqual(@as(usize, 2), r2.kept.len);
    try std.testing.expectEqualStrings("u0", r2.kept[0].content);
    try std.testing.expectEqual(@as(usize, 2), r2.dropped);
}

// ── compaction-llm-001 fixtures ─────────────────────────────────────────────

test "compaction-llm: serialize role-tagged flat text with thinking + tool calls" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{
        .{ .id = "c1", .name = "list_dir", .arguments = "{\"path\":\".\"}" },
        .{ .id = "c2", .name = "read_file", .arguments = "{}" },
    };
    const body = [_]Message{
        Message.system("sys-preamble"),
        Message.user("hello"),
        Message{ .role = .assistant, .content = "let me look", .reasoning = "user wants a listing" },
        Message.assistantToolCalls("checking", &calls),
        Message.toolResult("c1", "dir-out"),
        Message.user("done"),
    };
    const out = try serializeConversationForSummary(gpa, &body);
    defer gpa.free(out);
    const expected =
        "[System]: sys-preamble\n\n" ++
        "[User]: hello\n\n" ++
        "[Assistant thinking]: user wants a listing\n\n" ++
        "[Assistant]: let me look\n\n" ++
        "[Assistant]: checking\n\n" ++
        "[Assistant tool calls]: list_dir(c1, {\"path\":\".\"}); read_file(c2, {})\n\n" ++
        "[Tool result]: dir-out\n\n" ++
        "[User]: done";
    try std.testing.expectEqualStrings(expected, out);
}

test "compaction-llm: serialize empty input yields empty string" {
    const gpa = std.testing.allocator;
    const body: [0]Message = .{};
    const out = try serializeConversationForSummary(gpa, &body);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "compaction-llm: serialize omits empty-content rows (pi semantics)" {
    const gpa = std.testing.allocator;
    const body = [_]Message{
        Message.user(""),
        Message.assistantText("a1"),
        Message{ .role = .tool, .content = "", .tool_call_id = "x" },
        Message.user("u2"),
    };
    const out = try serializeConversationForSummary(gpa, &body);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("[Assistant]: a1\n\n[User]: u2", out);
}

test "compaction-llm: serialize truncates tool results at 2000 chars with marker" {
    const gpa = std.testing.allocator;
    var long: [2500]u8 = undefined;
    @memset(&long, 'x');
    const body = [_]Message{
        Message.user("u"),
        Message.toolResult("c1", &long),
    };
    const out = try serializeConversationForSummary(gpa, &body);
    defer gpa.free(out);

    const prefix = "[Tool result]: " ++ ("x" ** 2000);
    const prefix_at = std.mem.indexOf(u8, out, prefix) orelse return error.TestUnexpectedResult;
    const marker = try std.fmt.allocPrint(gpa, "[... {d} more characters truncated]", .{500});
    defer gpa.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
    // Exactly 2000 chars kept before the truncation marker.
    const marker_at = std.mem.indexOf(u8, out, "\n\n[...") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(prefix_at + prefix.len, marker_at);
    // Short content is not truncated.
    const short = [_]Message{ Message.user("u"), Message.toolResult("c1", "ok") };
    const out2 = try serializeConversationForSummary(gpa, &short);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("[User]: u\n\n[Tool result]: ok", out2);
}

test "compaction-llm: serialize images as [image: {url}] and joins text parts" {
    const gpa = std.testing.allocator;
    const parts = [_]ztypes.ContentPart{
        .{ .text = "look at this" },
        .{ .image_url = .{ .url = "https://example.com/a.png" } },
        .{ .text = "and this" },
    };
    const body = [_]Message{ Message.userMultimodal(&parts) };
    const out = try serializeConversationForSummary(gpa, &body);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        "[User]: look at this\n[image: https://example.com/a.png]\nand this",
        out,
    );
}

test "compaction-llm: serialize assistant with only reasoning or only calls" {
    const gpa = std.testing.allocator;
    const calls = [_]ztypes.ToolCall{.{
        .id = "c1",
        .name = "grep",
        .arguments = "{}",
    }};
    // Reasoning only (no text): thinking row only.
    const thinking = [_]Message{
        Message{ .role = .assistant, .content = "", .reasoning = "deep thought" },
    };
    const out1 = try serializeConversationForSummary(gpa, &thinking);
    defer gpa.free(out1);
    try std.testing.expectEqualStrings("[Assistant thinking]: deep thought", out1);

    // Tool calls only (no text): calls row only.
    const calls_only = [_]Message{ Message.assistantToolCalls("", &calls) };
    const out2 = try serializeConversationForSummary(gpa, &calls_only);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("[Assistant tool calls]: grep(c1, {})", out2);
}

test "compaction-llm: INITIAL prompt contains exact skeleton; system matches pi" {
    const gpa = std.testing.allocator;
    const prompts = try buildSummaryPrompts(gpa, null);
    defer gpa.free(prompts.system);
    defer gpa.free(prompts.prompt);

    try std.testing.expectEqualStrings(summarization_system_prompt, prompts.system);
    try std.testing.expectEqualStrings(summarization_prompt, prompts.prompt);
    for ([_][]const u8{
        "## Goal",
        "## Constraints & Preferences",
        "## Progress",
        "### Done",
        "### In Progress",
        "### Blocked",
        "## Key Decisions",
        "## Next Steps",
        "## Critical Context",
        "Preserve exact file paths, function names, and error messages",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, "<previous-summary>") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.system, "You are a context summarization assistant.") != null);
}

test "compaction-llm: UPDATE prompt carries prior in previous-summary tags" {
    const gpa = std.testing.allocator;
    const prompts = try buildSummaryPrompts(gpa, "PRIOR-SUMMARY-TEXT");
    defer gpa.free(prompts.system);
    defer gpa.free(prompts.prompt);

    try std.testing.expectEqualStrings(summarization_system_prompt, prompts.system);
    const prior_block = try std.fmt.allocPrint(gpa, "<previous-summary>\n{s}\n</previous-summary>", .{"PRIOR-SUMMARY-TEXT"});
    defer gpa.free(prior_block);
    try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, prior_block) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, "PRESERVE all existing information from the previous summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, "## Goal") != null);
    // The initial prompt is never mixed into the update prompt.
    try std.testing.expect(std.mem.indexOf(u8, prompts.prompt, "Create a structured context checkpoint summary") == null);
}

test "compaction-llm: empty prior uses INITIAL prompt" {
    const gpa = std.testing.allocator;
    const prompts = try buildSummaryPrompts(gpa, "");
    defer gpa.free(prompts.system);
    defer gpa.free(prompts.prompt);
    try std.testing.expectEqualStrings(summarization_prompt, prompts.prompt);
}

test "compaction-llm: format strips analysis blocks and converts wrapper" {
    const gpa = std.testing.allocator;

    // Single analysis block before the summary wrapper.
    const raw1 = "<analysis>scratchpad</analysis>\n<summary>## Goal\ndone</summary>";
    const out1 = try formatCompactSummary(gpa, raw1);
    defer gpa.free(out1);
    try std.testing.expectEqualStrings("Summary:\n## Goal\ndone", out1);

    // Multiple leading analysis blocks are all stripped (loop).
    const raw2 = "<analysis>a</analysis>\n<analysis>b</analysis>\n<summary>X</summary>";
    const out2 = try formatCompactSummary(gpa, raw2);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("Summary:\nX", out2);

    // Unclosed analysis: dropped up to the next <summary>.
    const raw3 = "<analysis>unclosed junk\n<summary>Y</summary>";
    const out3 = try formatCompactSummary(gpa, raw3);
    defer gpa.free(out3);
    try std.testing.expectEqualStrings("Summary:\nY", out3);

    // Unclosed analysis with no summary: everything dropped.
    const raw4 = "<analysis>only junk";
    const out4 = try formatCompactSummary(gpa, raw4);
    defer gpa.free(out4);
    try std.testing.expectEqualStrings("", out4);

    // Bare wrapper without analysis.
    const raw5 = "<summary>Z</summary>";
    const out5 = try formatCompactSummary(gpa, raw5);
    defer gpa.free(out5);
    try std.testing.expectEqualStrings("Summary:\nZ", out5);

    // Trailing content after the wrapper is dropped.
    const raw6 = "<summary>Z</summary>trailing";
    const out6 = try formatCompactSummary(gpa, raw6);
    defer gpa.free(out6);
    try std.testing.expectEqualStrings("Summary:\nZ", out6);
}

test "compaction-llm: format neutralizes control tokens with U+200B" {
    const gpa = std.testing.allocator;

    // Tags inside the converted wrapper get neutralized (U+200B after '<').
    const raw1 = "<summary>\n<analysis>y</analysis>\n<summary_request>q</summary_request>\n</summary>";
    const out1 = try formatCompactSummary(gpa, raw1);
    defer gpa.free(out1);
    try std.testing.expect(std.mem.startsWith(u8, out1, "Summary:\n"));
    try std.testing.expect(std.mem.indexOf(u8, out1, "<\u{200B}analysis>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "<\u{200B}/analysis>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "<\u{200B}summary_request>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "<\u{200B}/summary_request>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "<analysis>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "</summary_request>") == null);

    // Bare summary_request tags (no wrapper) are neutralized too.
    const raw2 = "<summary_request>q</summary_request>";
    const out2 = try formatCompactSummary(gpa, raw2);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("<\u{200B}summary_request>q<\u{200B}/summary_request>", out2);
}

test "compaction-llm: format collapses 3+ newlines and trims" {
    const gpa = std.testing.allocator;

    const raw1 = "  \n<summary>a\n\n\n\nb\n\nc</summary>\n\n  ";
    const out1 = try formatCompactSummary(gpa, raw1);
    defer gpa.free(out1);
    try std.testing.expectEqualStrings("Summary:\na\n\nb\n\nc", out1);

    // Two newlines are preserved.
    const raw2 = "a\n\nb";
    const out2 = try formatCompactSummary(gpa, raw2);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("a\n\nb", out2);
}

test "compaction-llm: degenerate boundary at 499 vs 500 visible chars" {
    const gpa = std.testing.allocator;

    // 499 visible chars → degenerate.
    const d499 = "x" ** 499;
    const clean499 = try formatCompactSummary(gpa, d499);
    defer gpa.free(clean499);
    try std.testing.expect(isDegenerateSummary(clean499));

    // 500 visible chars → healthy.
    const h500 = "y" ** 500;
    const clean500 = try formatCompactSummary(gpa, h500);
    defer gpa.free(clean500);
    try std.testing.expect(!isDegenerateSummary(clean500));

    // Whitespace and newlines do not count as visible.
    const spaced = "z" ** 490 ++ "\n\n\t   ";
    const clean_spaced = try formatCompactSummary(gpa, spaced);
    defer gpa.free(clean_spaced);
    try std.testing.expect(isDegenerateSummary(clean_spaced));

    // Empty / whitespace-only input is degenerate.
    try std.testing.expect(isDegenerateSummary(""));
    try std.testing.expect(isDegenerateSummary("   \n\n\t "));
}

// ── compaction-llm-001: retry ladder fixtures ───────────────────────────────

const FakeSummarizer = struct {
    calls: u32 = 0,
    results: []const ztypes.SummaryResult,

    fn summarize(ptr: *anyopaque, request: ztypes.SummaryRequest) ztypes.SummaryResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = request;
        self.calls += 1;
        const idx = @min(self.calls - 1, self.results.len - 1);
        return self.results[idx];
    }
};

const fake_summarizer_vtable = ztypes.CompactionSummarizerVTable{
    .summarize = FakeSummarizer.summarize,
};

test "compaction-llm: retry ladder ok healthy returns cleaned text (1 call)" {
    const gpa = std.testing.allocator;
    const healthy = ("hello world\n" ** 59) ++ "hello world";
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{.{ .ok = .{ .text = healthy } }} };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = (try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(healthy, got);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "compaction-llm: retry ladder cleans the ok text (wrapper converted)" {
    const gpa = std.testing.allocator;
    const raw = "<analysis>nope</analysis>\n<summary>" ++ ("z" ** 500) ++ "</summary>";
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{.{ .ok = .{ .text = raw } }} };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = (try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0)).?;
    defer gpa.free(got);
    const expected = "Summary:\n" ++ ("z" ** 500);
    try std.testing.expectEqualStrings(expected, got);
}

test "compaction-llm: retry ladder degenerate x3 returns null" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{ .{ .ok = .{ .text = "tiny" } }, .{ .ok = .{ .text = "tiny" } }, .{ .ok = .{ .text = "tiny" } } } };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
}

test "compaction-llm: retry ladder deterministic aborts immediately" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{.{ .err = .{ .kind = .deterministic, .message = "auth" } }} };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "compaction-llm: retry ladder context_overflow aborts immediately" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{.{ .err = .{ .kind = .context_overflow, .message = "ctx" } }} };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "compaction-llm: retry ladder transient x3 returns null after full ladder" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
    } };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
}

test "compaction-llm: retry ladder timeout x3 returns null" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{
        .{ .err = .{ .kind = .timeout, .message = "slow" } },
        .{ .err = .{ .kind = .timeout, .message = "slow" } },
        .{ .err = .{ .kind = .timeout, .message = "slow" } },
    } };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
}

test "compaction-llm: retry ladder succeeds after 2 transient retries" {
    const gpa = std.testing.allocator;
    const healthy = ("hello world\n" ** 59) ++ "hello world";
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .err = .{ .kind = .transient, .message = "net" } },
        .{ .ok = .{ .text = healthy } },
    } };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = (try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(healthy, got);
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
}

test "compaction-llm: retry ladder respects max_attempts=1" {
    const gpa = std.testing.allocator;
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{.{ .err = .{ .kind = .transient, .message = "net" } }} };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = try summarizeWithRetry(std.testing.io, gpa, seam, req, 1, 0);
    try std.testing.expect(got == null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "compaction-llm: degenerate then healthy recovers on the second attempt" {
    const gpa = std.testing.allocator;
    const healthy = ("hello world\n" ** 59) ++ "hello world";
    const req: ztypes.SummaryRequest = .{ .prompt = "p", .system = "s", .max_tokens = 100 };

    var fake = FakeSummarizer{ .results = &.{
        .{ .ok = .{ .text = "tiny" } },
        .{ .ok = .{ .text = healthy } },
    } };
    const seam = ztypes.CompactionSummarizer{ .ptr = &fake, .vtable = &fake_summarizer_vtable };
    const got = (try summarizeWithRetry(std.testing.io, gpa, seam, req, 3, 0)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(healthy, got);
    try std.testing.expectEqual(@as(u32, 2), fake.calls);
}
