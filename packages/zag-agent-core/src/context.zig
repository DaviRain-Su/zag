//! Context window policy — what the model sees vs full transcript.
//!
//! Full history stays in Session (for resume / audit). Before each `provider.chat`,
//! build a **view**: keep system messages + a recent tail under size limits.
//! Phase 2 is deliberately rough (drop oldest, no LLM summary yet).
//! Char budgets are computed by the product shell (via zag-ai catalog) and
//! passed in — core does not depend on zag-ai.

const std = @import("std");
const message = @import("message.zig");

pub const Options = struct {
    /// Max non-system messages kept from the tail (0 = unlimited count).
    max_tail_messages: usize = 48,
    /// Soft char budget across the whole view (0 = unlimited).
    max_chars: usize = 120_000,
    /// Never drop below this many non-system messages from the end.
    min_tail_messages: usize = 6,
};

/// Build context options from a char budget + optional file overrides.
/// Shell typically passes `resolve_result.contextCharBudget(defaults.max_chars)`.
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

pub const View = struct {
    /// Borrowed message pointers into the transcript (and optional note).
    messages: []const message.Message,
};

/// Build a model-facing view. Allocates only the message **slice** (and optional
/// synthetic system note) on `arena`; message string bodies stay in the transcript.
pub fn viewForModel(
    arena: std.mem.Allocator,
    full: []const message.Message,
    opts: Options,
) error{OutOfMemory}!View {
    if (full.len == 0) {
        return .{ .messages = &.{} };
    }

    // Partition: leading system block vs rest.
    var sys_end: usize = 0;
    while (sys_end < full.len and full[sys_end].role == .system) : (sys_end += 1) {}

    const systems = full[0..sys_end];
    const body = full[sys_end..];

    var start: usize = 0;
    if (opts.max_tail_messages > 0 and body.len > opts.max_tail_messages) {
        start = body.len - opts.max_tail_messages;
    }

    // Align start so we don't orphan tool results without their assistant tool_calls.
    start = alignToolBoundary(body, start);

    var dropped = start;
    var selected = body[start..];

    // Char budget: shrink from the front of the tail.
    if (opts.max_chars > 0) {
        while (selected.len > opts.min_tail_messages) {
            const total = estimateChars(systems) + estimateChars(selected);
            if (total <= opts.max_chars) break;
            const next = alignToolBoundary(selected, 1);
            if (next == 0 or next >= selected.len) break;
            dropped += next;
            selected = selected[next..];
        }
    }

    const need_note = dropped > 0;
    const out_len = systems.len + selected.len + @as(usize, if (need_note) 1 else 0);
    const out = try arena.alloc(message.Message, out_len);

    var i: usize = 0;
    for (systems) |m| {
        out[i] = m;
        i += 1;
    }
    if (need_note) {
        const note = try std.fmt.allocPrint(
            arena,
            "[context] {d} earlier non-system messages were omitted to fit the context window.",
            .{dropped},
        );
        out[i] = message.Message.system(note);
        i += 1;
    }
    for (selected) |m| {
        out[i] = m;
        i += 1;
    }

    return .{ .messages = out };
}

fn estimateChars(msgs: []const message.Message) usize {
    var n: usize = 0;
    for (msgs) |m| {
        n += m.estimateChars();
    }
    return n;
}

/// Move `start` backward so we never begin on a bare `tool` without its assistant.
fn alignToolBoundary(body: []const message.Message, start: usize) usize {
    var s = start;
    while (s < body.len and body[s].role == .tool) {
        if (s == 0) break;
        s -= 1;
    }
    return s;
}

test "view keeps systems and trims old user messages" {
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

    const v = try viewForModel(arena, &full, .{
        .max_tail_messages = 4,
        .max_chars = 0,
        .min_tail_messages = 2,
    });

    // system + note + last 4
    try std.testing.expect(v.messages.len >= 5);
    try std.testing.expect(v.messages[0].role == .system);
    try std.testing.expectEqualStrings("sys", v.messages[0].content);
    // last message still a3
    try std.testing.expectEqualStrings("a3", v.messages[v.messages.len - 1].content);
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
    });
    // Should include assistant tool_calls if tool is in the window.
    var saw_tool = false;
    var saw_assistant_tools = false;
    for (v.messages) |m| {
        if (m.role == .tool) saw_tool = true;
        if (m.role == .assistant and m.tool_calls != null) saw_assistant_tools = true;
    }
    if (saw_tool) try std.testing.expect(saw_assistant_tools);
}
