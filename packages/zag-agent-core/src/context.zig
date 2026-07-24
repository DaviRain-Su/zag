//! Context window policy — what the model sees vs full transcript (H4 / h-context-001).
//!
//! **Transcript is authoritative.** Compaction never deletes transcript rows;
//! it only shapes the model **view** and may return a `CompactionEvent` for
//! session metadata / trace.
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
//! 1. Count-trim the tail, then align to a valid Tool boundary.
//! 2. Soft char-trim with current layer cost (prior session layer if any).
//! 3. Build a summary for the omitted body prefix (with prior-session lineage).
//! 4. Re-cost layers with that summary as the session layer.
//! 5. If over budget, advance the body start by a Tool-aligned step and
//!    rebuild summary/accounting; repeat until stable.
//! 6. Emit one final `CompactionEvent` whose `dropped` equals the final
//!    omitted body prefix length and whose summary describes that set.
//!
//! Soft budget / min-tail: when further trim would drop below
//! `min_tail_messages` or no legal Tool-aligned advance exists, the loop
//! **terminates honestly** even if still over `max_chars`. The returned view
//! may exceed the soft budget; accounting still matches the returned view.
//!
//! Iteration is bounded by `body.len + 1` (each step advances the absolute
//! start by ≥1 when progress is made) — no hidden unbounded O(n²) restarts
//! beyond a single linear walk of the body with per-step cost scans.
//!
//! Generation semantics live on Session (`compaction_gen`): exactly one
//! increment per successfully applied final event. Prior session summary text
//! is preserved inside the new summary (lineage), not silently erased.

const std = @import("std");
const message = @import("message.zig");

/// Default heuristic summary bound. Keep ≤ `trace.cap_compaction_summary` so
/// the same final summary bytes can be verified in session meta and trace.
pub const default_summary_max_chars: usize = 800;

pub const Options = struct {
    /// Max non-system history messages kept from the tail (0 = unlimited count).
    max_tail_messages: usize = 48,
    /// Soft char budget across the whole view (0 = unlimited).
    max_chars: usize = 120_000,
    /// Never drop below this many history messages from the end.
    min_tail_messages: usize = 6,
    /// Max chars kept in a heuristic compaction summary (UTF-8 bounded).
    summary_max_chars: usize = default_summary_max_chars,
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
    },
) Options {
    const defaults = Options{};
    return .{
        .max_chars = overrides.max_chars orelse (budget_chars orelse defaults.max_chars),
        .max_tail_messages = overrides.max_tail_messages orelse defaults.max_tail_messages,
        .min_tail_messages = overrides.min_tail_messages orelse defaults.min_tail_messages,
    };
}

pub const CompactionEvent = struct {
    /// Number of non-system body messages omitted from the **final** returned view.
    dropped: usize,
    /// Arena-owned summary text suitable for session meta / session layer / trace.
    summary: []const u8,
};

pub const View = struct {
    /// Borrowed / arena-owned messages for the provider call.
    messages: []const message.Message,
    /// Set when history was trimmed for the view (transcript unchanged).
    compaction: ?CompactionEvent = null,
};

/// Build a model-facing view with four layers + history tail.
/// Allocates synthetic system strings and the message slice on `arena`.
///
/// When all layer strings are empty, falls back to keeping leading transcript
/// `system` rows (compat with tests / callers that only seed the transcript).
pub fn viewForModel(
    arena: std.mem.Allocator,
    full: []const message.Message,
    opts: Options,
    layers: Layers,
) error{OutOfMemory}!View {
    const use_layers = layers.system.len > 0 or layers.project.len > 0 or
        layers.session.len > 0 or layers.ephemeral.len > 0;

    var hist_start: usize = 0;
    while (hist_start < full.len and full[hist_start].role == .system) : (hist_start += 1) {}
    const transcript_systems = full[0..hist_start];
    const body = full[hist_start..];

    // --- Stage A: count trim + Tool-boundary align ---
    var start: usize = 0;
    if (opts.max_tail_messages > 0 and body.len > opts.max_tail_messages) {
        start = body.len - opts.max_tail_messages;
    }
    start = alignToolBoundary(body, start);

    // Layer cost without a new compaction summary (prior session layer may exist).
    var layer_chars: usize = if (use_layers)
        layerEstimate(layers, null)
    else
        estimateChars(transcript_systems);

    // --- Stage B: soft char trim under current layer cost ---
    start = charTrimStart(body, start, layer_chars, opts);

    // Snapshot after initial stages — used by tests / docs to prove two-stage growth.
    const initial_dropped = start;

    // --- Stage C: fixed-point — summary insertion may force further legal trims ---
    var compaction: ?CompactionEvent = null;
    var session_layer = layers.session;

    if (start > 0) {
        // Bound iterations: each successful advance moves `start` forward by ≥1.
        const max_iters = body.len + 1;
        var iter: usize = 0;
        while (iter < max_iters) : (iter += 1) {
            const dropped = start;
            const summary = try buildSummary(
                arena,
                body[0..dropped],
                opts.summary_max_chars,
                dropped,
                layers.session,
            );

            if (use_layers) {
                layer_chars = layerEstimate(layers, summary);
            } else {
                // Compat path adds a session-context note (~header overhead).
                layer_chars = estimateChars(transcript_systems) + summary.len + 64;
            }

            const before = start;
            start = charTrimStart(body, start, layer_chars, opts);
            if (start == before) {
                // Stable final view.
                compaction = .{ .dropped = dropped, .summary = summary };
                session_layer = summary;
                break;
            }
            // Else: summary/layer growth forced more trim — rebuild accounting.
            // Intermediate summary is abandoned (arena-owned; freed with turn).
        } else {
            // Exhausted bound without stability (should not happen with ≥1 advance).
            // Emit honest final accounting for the last start.
            const dropped = start;
            const summary = try buildSummary(
                arena,
                body[0..dropped],
                opts.summary_max_chars,
                dropped,
                layers.session,
            );
            compaction = .{ .dropped = dropped, .summary = summary };
            session_layer = summary;
        }
    }

    // Silence unused when not debugging; available for tests via recompute.
    _ = initial_dropped;

    const selected = body[start..];

    if (use_layers) {
        const layer_msgs = try buildLayerMessages(arena, layers, session_layer);
        const out_len = layer_msgs.len + selected.len;
        const out = try arena.alloc(message.Message, out_len);
        @memcpy(out[0..layer_msgs.len], layer_msgs);
        @memcpy(out[layer_msgs.len..], selected);
        return .{ .messages = out, .compaction = compaction };
    }

    // Compat path: keep transcript systems + optional compaction note.
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

/// Soft char-trim: advance absolute `start` while over budget, respecting
/// `min_tail_messages` and Tool boundaries. Returns the new start (may equal
/// input when no legal further trim exists — soft budget may still be exceeded).
fn charTrimStart(
    body: []const message.Message,
    start_in: usize,
    layer_chars: usize,
    opts: Options,
) usize {
    var start = start_in;
    if (opts.max_chars == 0) return start;
    while (body.len - start > opts.min_tail_messages) {
        const selected = body[start..];
        const total = layer_chars + estimateChars(selected);
        if (total <= opts.max_chars) break;
        const next = alignToolBoundary(selected, 1);
        if (next == 0 or next >= selected.len) break;
        start += next;
    }
    return start;
}

/// Compute the body start after count trim + Tool align only (no char/summary).
/// Exposed for fixtures that prove two-stage growth vs the final fixed-point.
pub fn initialCountTrimStart(body: []const message.Message, opts: Options) usize {
    var start: usize = 0;
    if (opts.max_tail_messages > 0 and body.len > opts.max_tail_messages) {
        start = body.len - opts.max_tail_messages;
    }
    return alignToolBoundary(body, start);
}

/// Count-trim + first-pass char trim without summary re-cost (legacy intermediate).
/// Used by tests to show the old intermediate `dropped` can under-count the final view.
pub fn intermediateDroppedBeforeSummary(
    full: []const message.Message,
    opts: Options,
    layers: Layers,
) usize {
    const use_layers = layers.system.len > 0 or layers.project.len > 0 or
        layers.session.len > 0 or layers.ephemeral.len > 0;
    var hist_start: usize = 0;
    while (hist_start < full.len and full[hist_start].role == .system) : (hist_start += 1) {}
    const body = full[hist_start..];
    const start = initialCountTrimStart(body, opts);
    const layer_chars: usize = if (use_layers)
        layerEstimate(layers, null)
    else
        estimateChars(full[0..hist_start]);
    return charTrimStart(body, start, layer_chars, opts);
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

/// Build a bounded UTF-8-safe summary for the final omitted set.
/// When `prior_session` is non-empty (previous compaction / session layer),
/// its text is retained under a lineage section rather than silently dropped.
fn buildSummary(
    arena: std.mem.Allocator,
    dropped_msgs: []const message.Message,
    max_chars: usize,
    dropped_count: usize,
    prior_session: []const u8,
) error{OutOfMemory}![]const u8 {
    var body: std.Io.Writer.Allocating = .init(arena);
    errdefer body.deinit();
    body.writer.print(
        "[compaction] {d} earlier messages omitted from the model view.\n",
        .{dropped_count},
    ) catch return error.OutOfMemory;

    // Lineage first so repeated compaction cannot silently erase prior session
    // context when highlights fill the bound.
    if (prior_session.len > 0 and body.written().len < max_chars) {
        body.writer.print("Prior session context:\n", .{}) catch return error.OutOfMemory;
        const room = if (body.written().len < max_chars) max_chars - body.written().len else 0;
        // Reserve roughly half the budget for lineage; leave room for highlights.
        const prior_budget = @min(room, @max(max_chars / 3, @min(room, 120)));
        const prior_snip = truncateUtf8(prior_session, prior_budget);
        body.writer.print("{s}\n", .{prior_snip}) catch return error.OutOfMemory;
    }

    if (body.written().len < max_chars) {
        body.writer.print("Highlights:\n", .{}) catch return error.OutOfMemory;
    }
    for (dropped_msgs) |m| {
        if (body.written().len >= max_chars) break;
        const role = m.role.jsonName();
        const snippet = truncateUtf8(m.content, 120);
        body.writer.print("- {s}: {s}\n", .{ role, snippet }) catch return error.OutOfMemory;
    }
    body.writer.flush() catch {};

    var owned = body.toOwnedSlice() catch return error.OutOfMemory;
    if (owned.len > max_chars) {
        const cut = truncateUtf8(owned, max_chars);
        if (cut.len < owned.len) {
            owned = arena.realloc(owned, cut.len) catch return error.OutOfMemory;
        }
    }
    // Final UTF-8 validity for session/trace consumers.
    if (!std.unicode.utf8ValidateSlice(owned)) {
        // Should not happen with valid inputs + codepoint truncation; fail closed.
        return error.OutOfMemory;
    }
    return owned;
}

/// Truncate on a UTF-8 codepoint boundary (keeps valid UTF-8 when input is valid).
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

/// If `start` lands on a tool result, walk back to the preceding assistant
/// (tool_calls carrier) so the selected tail never orphans tool results.
fn alignToolBoundary(body: []const message.Message, start: usize) usize {
    var s = start;
    while (s < body.len and body[s].role == .tool) {
        if (s == 0) break;
        s -= 1;
    }
    return s;
}

/// True when the first non-system history message in `view` is not an orphan tool.
fn historyStartIsValid(msgs: []const message.Message) bool {
    var i: usize = 0;
    while (i < msgs.len and msgs[i].role == .system) : (i += 1) {}
    if (i >= msgs.len) return true;
    return msgs[i].role != .tool;
}

/// Snapshot roles/content for transcript-immutability checks.
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

    const v = try viewForModel(arena, &full, .{
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
    // History starts at u1 (old system skipped).
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

    const v = try viewForModel(arena, &full, .{
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
    // Session layer carries the summary.
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

    const v = try viewForModel(arena, &full, .{
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

test "h-context: two-stage trim final dropped equals omitted prefix and summary names them" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Long early messages force char trim; summary insertion then forces more.
    // Each body message is large so layer+summary growth is measurable.
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

    var roles_before: [32]u8 = undefined;
    const nrb = snapshotRoles(&full, &roles_before);

    const opts = Options{
        .max_tail_messages = 0, // count unlimited — char budget drives trim
        .max_chars = 420, // tight: forces multi-stage after summary insertion
        .min_tail_messages = 2,
        .summary_max_chars = 400,
    };
    const layers = Layers{ .system = "base-system-prompt" };

    const intermediate = intermediateDroppedBeforeSummary(&full, opts, layers);
    try std.testing.expect(intermediate > 0);

    const v = try viewForModel(arena, &full, opts, layers);
    try std.testing.expect(v.compaction != null);
    const ev = v.compaction.?;

    // Final dropped must be the full omitted body prefix (body starts after system).
    const body = full[1..];
    try std.testing.expect(ev.dropped > 0);
    try std.testing.expect(ev.dropped >= intermediate);
    // Prove the old intermediate under-count bug case when summary forces growth:
    // when final > intermediate, the buggy algorithm would have reported intermediate.
    // Construct so final exceeds intermediate when possible; always require exact match
    // between final.dropped and actual omitted set.
    const omitted = body[0..ev.dropped];
    const kept = body[ev.dropped..];
    try std.testing.expectEqual(kept.len, body.len - ev.dropped);

    // View history (after system layers) equals kept tail.
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const view_hist = v.messages[hist_i..];
    try std.testing.expectEqual(kept.len, view_hist.len);
    for (kept, view_hist) |k, vm| {
        try std.testing.expectEqualStrings(k.content, vm.content);
        try std.testing.expectEqual(k.role, vm.role);
    }

    // Summary header count matches final dropped; names at least the first omitted role snippets.
    try std.testing.expect(std.mem.indexOf(u8, ev.summary, "compaction") != null);
    var count_buf: [32]u8 = undefined;
    const count_needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{ev.dropped});
    try std.testing.expect(std.mem.indexOf(u8, ev.summary, count_needle) != null);
    // First omitted message content appears (or its truncate) in highlights.
    if (omitted.len > 0) {
        const snip = omitSnippet(omitted[0].content, 20);
        try std.testing.expect(std.mem.indexOf(u8, ev.summary, snip) != null);
    }

    // Transcript immutable.
    var roles_after: [32]u8 = undefined;
    const nra = snapshotRoles(&full, &roles_after);
    try std.testing.expectEqualStrings(roles_before[0..nrb], roles_after[0..nra]);
    try std.testing.expectEqualStrings("early-user-1 " ++ pad, full[1].content);
}

fn omitSnippet(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

test "h-context: summary growth triggers multiple fixed-point iterations" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Many medium messages: initial char trim drops some; summary (~few hundred
    // chars) then exceeds budget so more must drop; eventually stabilizes.
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

    const intermediate = intermediateDroppedBeforeSummary(&msgs, opts, layers);
    const v = try viewForModel(arena, &msgs, opts, layers);
    try std.testing.expect(v.compaction != null);
    const final_dropped = v.compaction.?.dropped;

    // Fixed-point advanced past the pre-summary intermediate in this fixture.
    try std.testing.expect(final_dropped > intermediate);

    // Final accounting matches view.
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    const body_len = msgs.len - 1;
    try std.testing.expectEqual(body_len - final_dropped, v.messages.len - hist_i);

    var count_buf: [32]u8 = undefined;
    const count_needle = try std.fmt.bufPrint(&count_buf, "{d} earlier", .{final_dropped});
    try std.testing.expect(std.mem.indexOf(u8, v.compaction.?.summary, count_needle) != null);
}

test "h-context: multi-tool sequences never orphan tool results at selected start" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const calls_a = [_]message.ToolCall{
        .{ .id = "a1", .name = "list_dir", .arguments = "{}" },
        .{ .id = "a2", .name = "read_file", .arguments = "{\"path\":\"x\"}" },
    };
    const calls_b = [_]message.ToolCall{
        .{ .id = "b1", .name = "grep", .arguments = "{}" },
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

    // max_tail that would land inside tool results without alignment.
    const opts = Options{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 1,
    };
    const v = try viewForModel(arena, &full, opts, .{ .system = "base" });
    try std.testing.expect(historyStartIsValid(v.messages));

    // Every tool in the view has a preceding assistant with tool_calls.
    var last_assistant_tools = false;
    for (v.messages) |m| {
        switch (m.role) {
            .assistant => last_assistant_tools = m.tool_calls != null,
            .tool => try std.testing.expect(last_assistant_tools),
            else => last_assistant_tools = false,
        }
    }

    // Also force post-summary trim path with a tight char budget.
    const pad = "Z" ** 60;
    const full2 = [_]message.Message{
        .system("sys"),
        .user(pad),
        .assistantText(pad),
        .user("ask"),
        .assistantToolCalls("t", &calls_a),
        .toolResult("a1", pad),
        .toolResult("a2", pad),
        .user("tail-u"),
        .assistantText("tail-a"),
    };
    const v2 = try viewForModel(arena, &full2, .{
        .max_tail_messages = 0,
        .max_chars = 280,
        .min_tail_messages = 2,
        .summary_max_chars = 200,
    }, .{ .system = "base" });
    try std.testing.expect(historyStartIsValid(v2.messages));
    last_assistant_tools = false;
    for (v2.messages) |m| {
        switch (m.role) {
            .assistant => last_assistant_tools = m.tool_calls != null,
            .tool => try std.testing.expect(last_assistant_tools),
            else => last_assistant_tools = false,
        }
    }
}

test "h-context: min_tail soft budget terminates honestly without further legal trim" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Two huge messages; min_tail=2 means we cannot drop either; soft budget
    // remains exceeded but algorithm terminates with dropped=0 or only
    // pre-min-tail omissions, never loops.
    const huge = "H" ** 500;
    const full = [_]message.Message{
        .system("sys"),
        .user(huge),
        .assistantText(huge),
    };
    const opts = Options{
        .max_tail_messages = 0,
        .max_chars = 100, // far below content
        .min_tail_messages = 2,
        .summary_max_chars = 80,
    };
    const v = try viewForModel(arena, &full, opts, .{ .system = "base" });
    // Cannot drop below min_tail=2 body messages.
    var hist_i: usize = 0;
    while (hist_i < v.messages.len and v.messages[hist_i].role == .system) : (hist_i += 1) {}
    try std.testing.expectEqual(@as(usize, 2), v.messages.len - hist_i);
    // No compaction when nothing was dropped.
    try std.testing.expect(v.compaction == null);

    // With older messages that can be dropped down to min_tail, stop at min_tail
    // even if still over budget after summary.
    const full2 = [_]message.Message{
        .system("sys"),
        .user(huge),
        .assistantText(huge),
        .user("keep-u"),
        .assistantText("keep-a"),
    };
    const v2 = try viewForModel(arena, &full2, .{
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

test "h-context: repeated compaction preserves prior summary lineage" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const pad = "L" ** 50;
    const full = [_]message.Message{
        .system("sys"),
        .user("first-wave " ++ pad),
        .assistantText("a1 " ++ pad),
        .user("second-wave " ++ pad),
        .assistantText("a2 " ++ pad),
        .user("third-wave " ++ pad),
        .assistantText("a3 " ++ pad),
        .user("now"),
        .assistantText("here"),
    };

    // First compaction.
    const v1 = try viewForModel(arena, &full, .{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 400,
    }, .{ .system = "base" });
    try std.testing.expect(v1.compaction != null);
    const first_summary = try arena.dupe(u8, v1.compaction.?.summary);

    // Second compaction with prior session lineage present.
    const v2 = try viewForModel(arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 2,
        .summary_max_chars = 500,
    }, .{
        .system = "base",
        .session = first_summary,
    });
    try std.testing.expect(v2.compaction != null);
    try std.testing.expect(std.mem.indexOf(u8, v2.compaction.?.summary, "Prior session context") != null);
    // Prior content should not be fully erased — at least a marker or snippet survives.
    try std.testing.expect(std.mem.indexOf(u8, v2.compaction.?.summary, "compaction") != null);
    try std.testing.expect(v2.compaction.?.dropped >= 2);
}

test "h-context: summary is UTF-8 safe when truncating multi-byte content" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Multi-byte UTF-8 (emoji / CJK) that would split under naive byte cut.
    const uni = "用户请求：你好世界 🌍✨";
    const full = [_]message.Message{
        .system("sys"),
        .user(uni),
        .assistantText(uni),
        .user(uni),
        .assistantText(uni),
        .user("tail"),
        .assistantText("ok"),
    };
    const v = try viewForModel(arena, &full, .{
        .max_tail_messages = 2,
        .max_chars = 0,
        .min_tail_messages = 1,
        .summary_max_chars = 60,
    }, .{ .system = "base" });
    try std.testing.expect(v.compaction != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(v.compaction.?.summary));
}
