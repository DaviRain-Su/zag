//! ANSI layout renderer (allocation-light; uses stack buffers).

const std = @import("std");
const c = @import("constants.zig");
const cards = @import("cards.zig");
const editor = @import("editor.zig");
const permission = @import("permission.zig");
const terminal = @import("terminal.zig");

pub const UiState = enum {
    idle,
    busy,
    closing,
    @"error",
    closed,
};

pub const StatusFacts = struct {
    id_display: []const u8,
    open_display: []const u8,
    session_configured: bool,
    perm: []const u8,
    shell: []const u8,
    state: UiState,
    status_note: []const u8 = "",
    steering_pending: u32 = 0,
    followup_pending: u32 = 0,
};

pub fn stateName(s: UiState) []const u8 {
    return switch (s) {
        .idle => "idle",
        .busy => "busy",
        .closing => "closing",
        .@"error" => "error",
        .closed => "closed",
    };
}

/// Render full frame. Permission modal fields come from a lock-safe snapshot.
pub fn renderFrame(
    term: *terminal.Terminal,
    size: terminal.Size,
    facts: StatusFacts,
    snap: []const cards.CardSlot,
    ed: *const editor.Editor,
    modal: permission.ModalSnapshot,
) error{WriteFailed}!void {
    var buf: [16 * 1024]u8 = undefined;
    var list = std.ArrayList(u8).initBuffer(&buf);

    // Clear + home.
    list.appendSliceBounded("\x1b[H\x1b[2J") catch return error.WriteFailed;

    if (size.isConstrained()) {
        try appendFmt(&list, "[zag tui · constrained]\r\nstate={s} id={s}\r\n", .{
            stateName(facts.state),
            facts.id_display,
        });
        // One-line card summaries.
        var i: usize = 0;
        while (i < snap.len and i < 3) : (i += 1) {
            const card = snap[snap.len - 1 - i];
            try appendFmt(&list, "· {s}\r\n", .{card.titleSlice()});
        }
        try appendFmt(&list, "> {s}\r\n", .{singleLine(ed.slice())});
    } else {
        try appendFmt(&list, "┌─ zag  tui ─\r\n", .{});
        try appendFmt(&list, "│ id: {s}  open:{s} cfg:{s}\r\n", .{
            facts.id_display,
            facts.open_display,
            if (facts.session_configured) "y" else "n",
        });
        try appendFmt(&list, "│ perm:{s}  shell:{s}  state:{s}", .{
            facts.perm,
            facts.shell,
            stateName(facts.state),
        });
        if (facts.steering_pending > 0 or facts.followup_pending > 0) {
            try appendFmt(&list, "  S:{d} F:{d}", .{ facts.steering_pending, facts.followup_pending });
        }
        try appendFmt(&list, "\r\n", .{});
        if (facts.status_note.len > 0) {
            try appendFmt(&list, "│ note: {s}\r\n", .{facts.status_note});
        }
        try appendFmt(&list, "├─ cards ─\r\n", .{});
        if (snap.len == 0) {
            try appendFmt(&list, "│ (no events yet)\r\n", .{});
        } else {
            // Show last rows fitting roughly.
            const max_cards = if (size.rows > 12) size.rows - 10 else 3;
            const start = if (snap.len > max_cards) snap.len - max_cards else 0;
            for (snap[start..]) |card| {
                try appendFmt(&list, "│ · {s}\r\n", .{card.titleSlice()});
                if (card.body_len > 0) {
                    const body = card.bodySlice();
                    const preview = if (body.len > 120) body[0..120] else body;
                    try appendFmt(&list, "│   {s}\r\n", .{preview});
                }
            }
        }
        try appendFmt(&list, "├─ editor ─\r\n", .{});
        try appendEditor(&list, ed);
        try appendFmt(&list, "│ [{d}/{d}]  [submit:Enter · nl:Alt+Enter]\r\n", .{
            ed.len,
            c.editor_max_bytes,
        });
        if (modal.pending) {
            try appendFmt(&list, "┌─ permission (modal) ─\r\n", .{});
            try appendFmt(&list, "│ risk:{s}  args_len:{d}  tool:{s}\r\n", .{
                modal.riskSlice(),
                modal.args_len,
                if (modal.tool_name_len == 0) "—" else modal.toolNameSlice(),
            });
            try appendFmt(&list, "│ [a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny\r\n", .{});
            try appendFmt(&list, "└─\r\n", .{});
        }
    }

    try term.writeAll(list.items);
}

fn appendFmt(list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    var tmp: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return error.WriteFailed;
    list.appendSliceBounded(s) catch return error.WriteFailed;
}

fn appendEditor(list: *std.ArrayList(u8), ed: *const editor.Editor) error{WriteFailed}!void {
    const s = ed.slice();
    if (s.len == 0) {
        try appendFmt(list, "│ > \r\n", .{});
        return;
    }
    var start: usize = 0;
    var first = true;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '\n') {
            const line = s[start..i];
            if (first) {
                try appendFmt(list, "│ > {s}\r\n", .{line});
                first = false;
            } else {
                try appendFmt(list, "│ . {s}\r\n", .{line});
            }
            start = i + 1;
        }
    }
}

fn singleLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}
