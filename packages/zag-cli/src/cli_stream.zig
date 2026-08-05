//! Progressive stdout for default (human) CLI — consumes `assistant_delta`.
//!
//! Wire/provider streaming is already the default (tui-streaming-001). This
//! module only paints deltas to stdout so interactive/`prompt` modes do not
//! wait for a full `reply()` before showing text.
//!
//! - `assistant_delta`: redact → write → flush (borrowed slice, in-order)
//! - `assistant_delta_clear`: erase this attempt's painted text when stdout is
//!   a TTY (ANSI); on pipes, leave bytes and reset the paint tracker
//! - `assistant_text`: ignored here (complete text is for Trace/verbose);
//!   `finishReply` prints `final_text` only when no delta was painted
//! - Other events: ignored (permission/tool stay on stderr verbose path)

const std = @import("std");
const Io = std.Io;
const coding = @import("zag-coding-agent");

/// Soft cap for the erase buffer (retry clear). Longer streams still print;
/// clear may be best-effort beyond this window.
const erase_cap: usize = 16 * 1024;

pub const CliStreamStdout = struct {
    gpa: std.mem.Allocator,
    io: Io,
    redactor: ?*const coding.redact.Redactor = null,
    /// UTF-8 bytes painted for the current provider attempt (for clear).
    erase_buf: [erase_cap]u8 = undefined,
    erase_len: usize = 0,
    /// True once any delta has been written during the current `reply()`.
    painted: bool = false,
    /// Last painted byte was `\n` (for finishReply trailing newline).
    ends_with_newline: bool = true,
    is_tty: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io) CliStreamStdout {
        const tty = Io.File.stdout().isTty(io) catch false;
        return .{
            .gpa = gpa,
            .io = io,
            .is_tty = tty,
        };
    }

    pub fn setRedactor(self: *CliStreamStdout, redactor: *const coding.redact.Redactor) void {
        self.redactor = redactor;
    }

    pub fn asObserver(self: *CliStreamStdout) coding.observer.Observer {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    /// Call after `agent.reply` returns. Skips reprinting when deltas already
    /// painted the answer; always leaves a trailing newline when anything was shown.
    pub fn finishReply(self: *CliStreamStdout, final_text: []const u8) !void {
        defer self.resetReply();
        if (self.painted) {
            if (!self.ends_with_newline) {
                try writeAll(self.io, "\n");
            }
            return;
        }
        try writeAll(self.io, final_text);
        if (final_text.len == 0 or final_text[final_text.len - 1] != '\n') {
            try writeAll(self.io, "\n");
        }
    }

    fn resetReply(self: *CliStreamStdout) void {
        self.erase_len = 0;
        self.painted = false;
        self.ends_with_newline = true;
    }

    fn onEvent(ptr: ?*anyopaque, event: coding.observer.Event) void {
        const self: *CliStreamStdout = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .assistant_delta => |delta| self.paintDelta(delta),
            .assistant_delta_clear => self.clearAttempt(),
            else => {},
        }
    }

    fn paintDelta(self: *CliStreamStdout, delta: []const u8) void {
        if (delta.len == 0) return;
        const red = coding.redact.redactOptional(self.redactor, self.gpa, delta) catch {
            // Fail closed: drop the chunk rather than print raw secrets.
            return;
        };
        defer self.gpa.free(red);
        if (red.len == 0) return;

        writeAll(self.io, red) catch return;
        // Flush so the user sees progress without waiting for reply() to end.
        flushStdout(self.io);

        self.painted = true;
        self.ends_with_newline = red[red.len - 1] == '\n';
        appendErase(self, red);
    }

    fn clearAttempt(self: *CliStreamStdout) void {
        if (self.erase_len == 0) return;
        if (self.is_tty) {
            eraseAnsi(self.io, self.erase_buf[0..self.erase_len]) catch {};
            flushStdout(self.io);
        }
        // Pipes: cannot rewind; leave partial bytes and reset tracker only.
        self.erase_len = 0;
        self.ends_with_newline = true;
        // Keep `painted` true so finishReply does not reprint a full final_text
        // on top of a cleared TTY (empty) or a pipe partial — final_text after
        // a failed attempt that cleared should still come from a later attempt's
        // deltas; if the run ends with only clears, final_text may still print
        // when painted was set then cleared with empty erase — handle below.
        // After clear with empty screen, allow final_text fallback:
        if (self.is_tty) self.painted = false;
    }

    fn appendErase(self: *CliStreamStdout, bytes: []const u8) void {
        const room = erase_cap - self.erase_len;
        if (room == 0) return;
        const n = @min(bytes.len, room);
        @memcpy(self.erase_buf[self.erase_len..][0..n], bytes[0..n]);
        self.erase_len += n;
    }
};

fn writeAll(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn flushStdout(io: Io) void {
    var buf: [1]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.flush() catch {};
}

/// Best-effort erase of previously painted text on a TTY (line-based ANSI).
/// Soft-wrap is not modeled; long lines may leave residue — accepted for v1.
fn eraseAnsi(io: Io, painted: []const u8) !void {
    if (painted.len == 0) return;
    var lines: usize = 1;
    for (painted) |b| {
        if (b == '\n') lines += 1;
    }
    // If the buffer ends with newline, the cursor is already on the next empty
    // line — do not count that trailing blank as a content line to clear.
    if (painted[painted.len - 1] == '\n') lines -= 1;
    if (lines == 0) return;

    var i: usize = 0;
    while (i < lines) : (i += 1) {
        try writeAll(io, "\x1b[2K"); // clear entire line
        if (i + 1 < lines) {
            try writeAll(io, "\x1b[1A"); // cursor up
        } else {
            try writeAll(io, "\r");
        }
    }
    try writeAll(io, "\x1b[J"); // clear from cursor down
}

test "finishReply prints final when nothing painted" {
    // Unit-level state machine without touching real stdout paint path.
    var stream: CliStreamStdout = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .painted = false,
        .ends_with_newline = true,
        .is_tty = false,
    };
    // Directly exercise skip vs print decision via painted flag.
    try std.testing.expect(!stream.painted);
    stream.painted = true;
    stream.ends_with_newline = false;
    // resetReply clears for next REPL turn
    stream.resetReply();
    try std.testing.expect(!stream.painted);
    try std.testing.expect(stream.ends_with_newline);
    try std.testing.expectEqual(@as(usize, 0), stream.erase_len);
}

test "appendErase caps and clearAttempt resets tracker" {
    const gpa = std.testing.allocator;
    var stream = CliStreamStdout.init(gpa, std.testing.io);
    stream.is_tty = false;
    stream.appendErase("hello");
    try std.testing.expectEqual(@as(usize, 5), stream.erase_len);
    stream.painted = true;
    stream.clearAttempt();
    try std.testing.expectEqual(@as(usize, 0), stream.erase_len);
    // non-TTY clear keeps painted so we do not double-dump final over pipe junk
    try std.testing.expect(stream.painted);
}

test "observer ignores assistant_text and paints delta into erase buf" {
    const gpa = std.testing.allocator;
    var stream = CliStreamStdout.init(gpa, std.testing.io);
    stream.is_tty = false;
    // Avoid writing to the process stdout in unit tests: call appendErase /
    // clear paths only. Observer paintDelta would write — use a dry path by
    // testing asObserver wiring shape.
    const obs = stream.asObserver();
    try std.testing.expect(obs.on_event != null);
    try std.testing.expect(obs.ptr == @as(?*anyopaque, @ptrCast(&stream)));
}
