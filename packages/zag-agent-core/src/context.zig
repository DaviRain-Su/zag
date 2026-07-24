//! Context window policy — what the model sees vs full transcript (H4).
//!
//! **Transcript is authoritative.** Compaction never deletes transcript rows;
//! it only shapes the model **view** and may return a `CompactionEvent` for
//! session metadata / trace.
//!
//! Four prompt layers (assembled into leading `system` messages in the view):
//! system → project → session → ephemeral, then the selected history tail.
//! Leading `system` rows already in the transcript are skipped to avoid
//! duplicating product-layer prompts.

const std = @import("std");
const message = @import("message.zig");

pub const Options = struct {
    /// Max non-system history messages kept from the tail (0 = unlimited count).
    max_tail_messages: usize = 48,
    /// Soft char budget across the whole view (0 = unlimited).
    max_chars: usize = 120_000,
    /// Never drop below this many history messages from the end.
    min_tail_messages: usize = 6,
    /// Max chars kept in a heuristic compaction summary.
    summary_max_chars: usize = 800,
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
    dropped: usize,
    /// Arena-owned summary text suitable for session meta / session layer.
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

    var start: usize = 0;
    if (opts.max_tail_messages > 0 and body.len > opts.max_tail_messages) {
        start = body.len - opts.max_tail_messages;
    }
    start = alignToolBoundary(body, start);

    var dropped = start;
    var selected = body[start..];

    var layer_chars: usize = if (use_layers)
        layerEstimate(layers, null)
    else
        estimateChars(transcript_systems);

    if (opts.max_chars > 0) {
        while (selected.len > opts.min_tail_messages) {
            const total = layer_chars + estimateChars(selected);
            if (total <= opts.max_chars) break;
            const next = alignToolBoundary(selected, 1);
            if (next == 0 or next >= selected.len) break;
            dropped += next;
            selected = selected[next..];
        }
    }

    var compaction: ?CompactionEvent = null;
    var session_layer = layers.session;
    if (dropped > 0) {
        const summary = try buildSummary(arena, body[0..dropped], opts.summary_max_chars, dropped);
        compaction = .{ .dropped = dropped, .summary = summary };
        if (use_layers) {
            session_layer = summary;
            layer_chars = layerEstimate(layers, summary);
        } else {
            layer_chars = estimateChars(transcript_systems) + summary.len + 64;
        }
        if (opts.max_chars > 0) {
            while (selected.len > opts.min_tail_messages) {
                const total = layer_chars + estimateChars(selected);
                if (total <= opts.max_chars) break;
                const next = alignToolBoundary(selected, 1);
                if (next == 0 or next >= selected.len) break;
                selected = selected[next..];
            }
        }
    }

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

fn buildSummary(
    arena: std.mem.Allocator,
    dropped_msgs: []const message.Message,
    max_chars: usize,
    dropped_count: usize,
) error{OutOfMemory}![]const u8 {
    var body: std.Io.Writer.Allocating = .init(arena);
    errdefer body.deinit();
    body.writer.print(
        "[compaction] {d} earlier messages omitted from the model view. Highlights:\n",
        .{dropped_count},
    ) catch return error.OutOfMemory;

    for (dropped_msgs) |m| {
        if (body.written().len >= max_chars) break;
        const role = m.role.jsonName();
        const snippet = truncate(m.content, 120);
        body.writer.print("- {s}: {s}\n", .{ role, snippet }) catch return error.OutOfMemory;
    }
    body.writer.flush() catch {};

    var owned = body.toOwnedSlice() catch return error.OutOfMemory;
    if (owned.len > max_chars) {
        owned = arena.realloc(owned, max_chars) catch return error.OutOfMemory;
    }
    return owned;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

fn estimateChars(msgs: []const message.Message) usize {
    var n: usize = 0;
    for (msgs) |m| {
        n += m.estimateChars();
    }
    return n;
}

fn alignToolBoundary(body: []const message.Message, start: usize) usize {
    var s = start;
    while (s < body.len and body[s].role == .tool) {
        if (s == 0) break;
        s -= 1;
    }
    return s;
}

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
    const before_len = full.len;

    const v = try viewForModel(arena, &full, .{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 2,
    }, .{ .system = "base" });

    try std.testing.expectEqual(before_len, full.len);
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

    var saw_tool = false;
    var saw_assistant_tools = false;
    for (v.messages) |m| {
        if (m.role == .tool) saw_tool = true;
        if (m.role == .assistant and m.tool_calls != null) saw_assistant_tools = true;
    }
    if (saw_tool) try std.testing.expect(saw_assistant_tools);
}
