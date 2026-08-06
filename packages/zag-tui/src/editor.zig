//! Bounded multiline editor + process-only history ring.

const std = @import("std");
const c = @import("constants.zig");
const present = @import("present.zig");

pub const Editor = struct {
    buf: []u8,
    len: usize = 0,
    cursor: usize = 0,

    pub fn init(storage: []u8) Editor {
        std.debug.assert(storage.len >= c.editor_max_bytes);
        return .{ .buf = storage[0..c.editor_max_bytes] };
    }

    pub fn clear(self: *Editor) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn slice(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn lineCount(self: *const Editor) usize {
        if (self.len == 0) return 1;
        var lines: usize = 1;
        for (self.buf[0..self.len]) |b| {
            if (b == '\n') lines += 1;
        }
        return lines;
    }

    /// Reject oversize insert/paste entirely. Returns false if rejected.
    pub fn insert(self: *Editor, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (self.len + bytes.len > c.editor_max_bytes) return false;
        // Line cap: count newlines that would be added.
        var add_nl: usize = 0;
        for (bytes) |b| {
            if (b == '\n') add_nl += 1;
        }
        const new_lines = self.lineCount() + add_nl;
        if (new_lines > c.editor_max_lines) return false;

        // Make room at cursor.
        const after = self.len - self.cursor;
        if (after > 0) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + bytes.len ..][0..after], self.buf[self.cursor..][0..after]);
        }
        @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
        return true;
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        const after = self.len - self.cursor;
        if (after > 0) {
            std.mem.copyForwards(u8, self.buf[self.cursor - 1 ..][0..after], self.buf[self.cursor..][0..after]);
        }
        self.cursor -= 1;
        self.len -= 1;
    }

    pub fn deleteForward(self: *Editor) void {
        if (self.cursor >= self.len) return;
        const after = self.len - self.cursor - 1;
        if (after > 0) {
            std.mem.copyForwards(u8, self.buf[self.cursor..][0..after], self.buf[self.cursor + 1 ..][0..after]);
        }
        self.len -= 1;
    }

    pub fn moveLeft(self: *Editor) void {
        if (self.cursor > 0) self.cursor -= 1;
    }
    pub fn moveRight(self: *Editor) void {
        if (self.cursor < self.len) self.cursor += 1;
    }

    /// Home: first byte of the current line (after the previous `\n`).
    pub fn moveHome(self: *Editor) void {
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf[0..self.cursor], '\n')) |i| i + 1 else 0;
        self.cursor = line_start;
    }

    /// End: first byte of the next `\n` at/after the cursor, else buffer end.
    pub fn moveEnd(self: *Editor) void {
        const nl = std.mem.indexOfScalarPos(u8, self.buf[0..self.len], self.cursor, '\n');
        self.cursor = nl orelse self.len;
    }

    /// Ctrl+W: delete the word (plus trailing whitespace) before the cursor.
    pub fn deleteWordBack(self: *Editor) void {
        var start = self.cursor;
        while (start > 0 and isWordSeparator(self.buf[start - 1])) start -= 1;
        while (start > 0 and !isWordSeparator(self.buf[start - 1])) start -= 1;
        self.deleteRange(start, self.cursor);
    }

    /// Ctrl+U: kill from the current line start to the cursor.
    pub fn killToStart(self: *Editor) void {
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf[0..self.cursor], '\n')) |i| i + 1 else 0;
        self.deleteRange(line_start, self.cursor);
    }

    /// Ctrl+K: kill from the cursor to the end of the current line.
    pub fn killToEnd(self: *Editor) void {
        const nl = std.mem.indexOfScalarPos(u8, self.buf[0..self.len], self.cursor, '\n');
        self.deleteRange(self.cursor, nl orelse self.len);
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) void {
        if (end <= start) return;
        const after = self.len - end;
        if (after > 0) {
            std.mem.copyForwards(u8, self.buf[start..][0..after], self.buf[end..][0..after]);
        }
        self.len -= end - start;
        self.cursor = start;
    }

    pub fn submitValidUtf8(self: *const Editor) bool {
        if (self.len == 0) return false;
        return present.isValidUtf8(self.slice());
    }
};

fn isWordSeparator(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n';
}

pub const History = struct {
    entries: [][c.history_entry_max_bytes]u8,
    lens: []usize,
    count: usize = 0,
    /// Next write index (ring).
    head: usize = 0,
    /// Browse offset: 0 = not browsing; 1 = most recent.
    browse: usize = 0,

    pub fn init(entries: [][c.history_entry_max_bytes]u8, lens: []usize) History {
        std.debug.assert(entries.len >= c.history_capacity);
        std.debug.assert(lens.len >= c.history_capacity);
        return .{
            .entries = entries[0..c.history_capacity],
            .lens = lens[0..c.history_capacity],
        };
    }

    /// Push only on accepted root submit dispatch. Truncate >8192 valid UTF-8 prefix;
    /// empty prefix → skip.
    pub fn pushAccepted(self: *History, text: []const u8) void {
        if (text.len == 0) return;
        var store_len = text.len;
        if (store_len > c.history_entry_max_bytes) {
            // Valid UTF-8 prefix ≤ 8192.
            store_len = c.history_entry_max_bytes;
            while (store_len > 0 and (text[store_len - 1] & 0xC0) == 0x80) store_len -= 1;
            if (store_len == 0) return;
            if (!present.isValidUtf8(text[0..store_len])) {
                // Walk back to last valid boundary.
                while (store_len > 0 and !present.isValidUtf8(text[0..store_len])) store_len -= 1;
                if (store_len == 0) return;
            }
        } else if (!present.isValidUtf8(text)) {
            return;
        }
        @memcpy(self.entries[self.head][0..store_len], text[0..store_len]);
        self.lens[self.head] = store_len;
        self.head = (self.head + 1) % c.history_capacity;
        if (self.count < c.history_capacity) self.count += 1;
        self.browse = 0;
    }

    pub fn up(self: *History) ?[]const u8 {
        if (self.count == 0) return null;
        if (self.browse < self.count) self.browse += 1;
        return self.browseEntry();
    }

    pub fn down(self: *History) ?[]const u8 {
        if (self.browse == 0) return null;
        self.browse -= 1;
        if (self.browse == 0) return null;
        return self.browseEntry();
    }

    fn browseEntry(self: *const History) ?[]const u8 {
        if (self.browse == 0 or self.browse > self.count) return null;
        // browse=1 → most recent = head-1
        const idx = (self.head + c.history_capacity - self.browse) % c.history_capacity;
        return self.entries[idx][0..self.lens[idx]];
    }
};

test "editor rejects oversize insert" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    const big = [_]u8{'x'} ** (c.editor_max_bytes + 1);
    try std.testing.expect(!ed.insert(&big));
    try std.testing.expectEqual(@as(usize, 0), ed.len);
    try std.testing.expect(ed.insert("ok"));
    try std.testing.expectEqualStrings("ok", ed.slice());
}

test "editor line cap" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    var i: usize = 0;
    while (i < c.editor_max_lines - 1) : (i += 1) {
        try std.testing.expect(ed.insert("a\n"));
    }
    // Now at max lines; another newline must reject entirely.
    try std.testing.expect(!ed.insert("\n"));
}

test "editor moveHome/moveEnd are line-aware" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    _ = ed.insert("one\ntwo");
    // Cursor in the middle of the second line.
    ed.cursor = 5;
    ed.moveHome();
    try std.testing.expectEqual(@as(usize, 4), ed.cursor); // after the '\n'
    ed.moveEnd();
    try std.testing.expectEqual(@as(usize, 7), ed.cursor); // buffer end
    // First line from cursor 0.
    ed.cursor = 0;
    ed.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor); // at the '\n'
    ed.moveHome();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "editor deleteWordBack removes word plus whitespace" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    _ = ed.insert("abc def");
    ed.cursor = 7; // end
    ed.deleteWordBack();
    try std.testing.expectEqualStrings("abc ", ed.slice());
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    ed.deleteWordBack();
    try std.testing.expectEqualStrings("", ed.slice());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "editor killToStart kills to line start" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    _ = ed.insert("abc def");
    ed.cursor = 7;
    ed.killToStart();
    try std.testing.expectEqualStrings("", ed.slice());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    // Multi-line: kills only the current line's prefix (cursor at line end).
    _ = ed.insert("one\ntwo");
    ed.cursor = 7;
    ed.killToStart();
    try std.testing.expectEqualStrings("one\n", ed.slice());
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
}

test "editor killToEnd kills to line end" {
    var storage: [c.editor_max_bytes]u8 = undefined;
    var ed = Editor.init(&storage);
    _ = ed.insert("one\ntwo");
    ed.cursor = 0;
    ed.killToEnd();
    try std.testing.expectEqualStrings("\ntwo", ed.slice());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    ed.killToEnd(); // at '\n' — nothing on this line to kill
    try std.testing.expectEqualStrings("\ntwo", ed.slice());
    ed.cursor = 1;
    ed.killToEnd();
    try std.testing.expectEqualStrings("\n", ed.slice());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}

test "history push only stores; ring 64" {
    var entries: [c.history_capacity][c.history_entry_max_bytes]u8 = undefined;
    var lens: [c.history_capacity]usize = .{0} ** c.history_capacity;
    var h = History.init(&entries, &lens);
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "e{d}", .{i});
        h.pushAccepted(s);
    }
    try std.testing.expectEqual(@as(usize, 64), h.count);
    const recent = h.up().?;
    try std.testing.expectEqualStrings("e69", recent);
}
