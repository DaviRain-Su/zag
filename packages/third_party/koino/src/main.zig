const std = @import("std");
const koino = @import("./koino.zig");

// Zag deviation (tui-markdown-001): upstream `main.zig` is the koino CLI
// (clap arg parsing + stdin/file markdown → HTML) plus the `testMarkdownToHtml`
// helper that `parser.zig`'s tests reference. Zag never builds or runs the
// CLI, but the vendored parser's tests are analyzed in zag's test builds, so
// the CLI (which does not compile under zig 0.16's std.Io-era APIs without a
// full port) is replaced by this stub. The test helper is kept, ported to
// zig 0.16 (std.Io.Writer.Allocating). See README.zag.
pub fn main() !void {
    // CLI intentionally omitted in the zag vendored copy.
}

/// Uses an ArenaAllocator for scratch work instead of a GeneralPurposeAllocator
/// to keep the parse path allocation-light. Result HTML is allocated by
/// std.testing.allocator (same ownership contract as upstream).
pub fn testMarkdownToHtml(options: koino.Options, markdown: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const doc = try koino.parse(arena.allocator(), markdown, options);

    var w = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer w.deinit();
    try koino.html.print(&w.writer, arena.allocator(), options, doc);
    return w.toOwnedSlice();
}

test {
    std.testing.refAllDecls(@This());
}
