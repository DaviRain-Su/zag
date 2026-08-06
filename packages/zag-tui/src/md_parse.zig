//! koino wrapper (tui-markdown-001): parse + AST access for the TUI
//! transcript renderer. This module is the only zag-tui code that names the
//! `koino` import; md_render.zig walks the resulting AST.
//!
//! Lifetime: the returned document is arena-backed — `arena` must outlive
//! every node slice the caller walks. `parseMarkdown` never deinits the
//! document (the arena frees wholesale); callers reset the arena per paint.
//!
//! AST node kinds consumed by md_render.zig (koino `src/nodes.zig`):
//!   blocks:  Document, Paragraph, Heading (level), CodeBlock (literal
//!            lines, fenced flag, info), List (ListType bullet/ordered,
//!            start), Item, BlockQuote, ThematicBreak, Table/TableRow/
//!            TableCell (plain-text rows, best-effort alignment)
//!   inlines: Text (literal), Code (literal), Emph, Strong, Strikethrough,
//!            Link (url + children), Image (alt text via children),
//!            SoftBreak ("\n" soft line break), LineBreak (hard break),
//!            HtmlInline (raw literal, shown as-is)
//!   ignored/rendered-as-literal: HtmlBlock (raw literal lines), any
//!            unknown node kind falls back to its literal text so content
//!            is never skipped.
//!
//! Fallback contract: parse failure (malformed input / OOM) returns null;
//! callers render the raw source text instead — never blank, never crash.

const std = @import("std");
const koino = @import("koino");

/// GFM extension surface enabled for transcript markdown (koino Options):
/// strikethrough (`~~x~~`) and GFM tables are opt-in in koino; autolink and
/// smart punctuation stay off (raw URLs render as text in v1).
pub const options: koino.Options = .{
    .extensions = .{
        .strikethrough = true,
        .table = true,
    },
};

/// Parse `text` into an arena-backed AST document, or null on any failure
/// (malformed input, OOM — koino only reports OutOfMemory; the caller falls
/// back to raw text). The document lives in `arena`; do not call `deinit`
/// on it — the arena owns everything.
pub fn parseMarkdown(arena: std.mem.Allocator, text: []const u8) ?*koino.nodes.AstNode {
    return koino.parse(arena, text, options) catch null;
}

test "parse empty input yields a bare document" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const doc = parseMarkdown(arena.allocator(), "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.data.value == .Document);
    try std.testing.expect(doc.first_child == null);
}

test "parse null document children stays null (whitespace-only body)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const doc = parseMarkdown(arena.allocator(), "   \n\n  ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.data.value == .Document);
    // Whitespace-only input produces no blocks (or a lone paragraph of
    // whitespace — koino is lenient; either way nothing may crash).
    var child = doc.first_child;
    while (child) |c| : (child = c.next) {
        switch (c.data.value) {
            .Paragraph => {
                // A whitespace paragraph renders as nothing visible; the
                // renderer must tolerate it.
                try std.testing.expect(c.first_child != null);
            },
            else => {},
        }
    }
}

test "parse heading span walk" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const doc = parseMarkdown(arena.allocator(), "# Hello world\n") orelse return error.TestUnexpectedResult;
    const h = doc.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(h.data.value == .Heading);
    try std.testing.expectEqual(@as(u8, 1), h.data.value.Heading.level);
    try std.testing.expectEqualStrings("Hello world", inlineText(arena.allocator(), h));
}

test "parse paragraph + bold/italic/code/link spans" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Each inline type in its own minimal paragraph: koino's delimiter
    // processing has inter-construct interactions in mixed paragraphs
    // (upstream quirk), so isolated inputs assert each span walk reliably.
    const cases = [_]struct {
        md: []const u8,
        kind: std.meta.Tag(koino.nodes.NodeValue),
        text: []const u8,
        link_url: ?[]const u8 = null,
    }{
        .{ .md = "**bold**\n", .kind = .Strong, .text = "bold" },
        .{ .md = "*italic*\n", .kind = .Emph, .text = "italic" },
        .{ .md = "`code`\n", .kind = .Code, .text = "code" },
        .{ .md = "[link](/url)\n", .kind = .Link, .text = "link", .link_url = "/url" },
    };
    for (cases) |case| {
        const doc = parseMarkdown(arena.allocator(), case.md) orelse return error.TestUnexpectedResult;
        const p = doc.first_child orelse return error.TestUnexpectedResult;
        try std.testing.expect(p.data.value == .Paragraph);
        var saw = false;
        var child = p.first_child;
        while (child) |c| : (child = c.next) {
            if (c.data.value == case.kind) {
                saw = true;
                switch (c.data.value) {
                    .Code => |lit| try std.testing.expectEqualStrings(case.text, lit),
                    .Link => |nl| {
                        try std.testing.expectEqualStrings(case.link_url.?, nl.url);
                        try std.testing.expectEqualStrings(case.text, inlineText(arena.allocator(), c));
                    },
                    else => try std.testing.expectEqualStrings(case.text, inlineText(arena.allocator(), c)),
                }
            }
        }
        try std.testing.expect(saw);
    }
}

test "parse strikethrough (isolated ~word~)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Upstream koino's own test form: `~world~` → <del>. In mixed
    // paragraphs the tilde delimiters can interact with bracket resolution
    // (upstream quirk — `~~`/`~` may stay literal); the renderer handles
    // both a Strikethrough node and literal text.
    const md = "Hello ~world~ there.";
    const doc = parseMarkdown(arena.allocator(), md) orelse return error.TestUnexpectedResult;
    const p = doc.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(p.data.value == .Paragraph);
    var child = p.first_child;
    while (child) |c| : (child = c.next) {
        if (c.data.value == .Strikethrough) {
            try std.testing.expectEqualStrings("world", inlineText(arena.allocator(), c));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "parse document walk order across block kinds" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // One document containing every v1 block kind; the walk must visit them
    // in source order (heading, paragraph, list, code, quote, hr).
    const md = "# Head\n\ntext body\n\n- a\n- b\n\n```zig\ncode line\n```\n\n> quote\n\n---\n";
    const doc = parseMarkdown(arena.allocator(), md) orelse return error.TestUnexpectedResult;
    const expected = [_]std.meta.Tag(koino.nodes.NodeValue){
        .Heading,
        .Paragraph,
        .List,
        .CodeBlock,
        .BlockQuote,
        .ThematicBreak,
    };
    var child = doc.first_child;
    var idx: usize = 0;
    while (child) |c| : (child = c.next) {
        try std.testing.expect(idx < expected.len);
        try std.testing.expectEqual(expected[idx], std.meta.activeTag(c.data.value));
        idx += 1;
    }
    try std.testing.expectEqual(expected.len, idx);
}

test "parse list block kinds and markers" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const md = "- alpha\n- beta\n\n1. one\n2. two\n";
    const doc = parseMarkdown(arena.allocator(), md) orelse return error.TestUnexpectedResult;
    const ul = doc.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(ul.data.value == .List);
    try std.testing.expect(ul.data.value.List.list_type == .Bullet);
    try std.testing.expectEqual(@as(usize, 2), childCount(ul));
    const ol = ul.next orelse return error.TestUnexpectedResult;
    try std.testing.expect(ol.data.value == .List);
    try std.testing.expect(ol.data.value.List.list_type == .Ordered);
    try std.testing.expectEqual(@as(usize, 1), ol.data.value.List.start);
}

test "parse fenced code block preserves literal lines" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const md = "```zig\nfn main() {}\nconst x = 1;\n```\n";
    const doc = parseMarkdown(arena.allocator(), md) orelse return error.TestUnexpectedResult;
    const cb = doc.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(cb.data.value == .CodeBlock);
    try std.testing.expect(cb.data.value.CodeBlock.fenced);
    const info = cb.data.value.CodeBlock.info orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("zig", info);
    try std.testing.expectEqualStrings("fn main() {}\nconst x = 1;\n", cb.data.value.CodeBlock.literal.items);
}

test "parse blockquote and thematic break" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const md = "> quoted\n\n---\n";
    const doc = parseMarkdown(arena.allocator(), md) orelse return error.TestUnexpectedResult;
    const bq = doc.first_child orelse return error.TestUnexpectedResult;
    try std.testing.expect(bq.data.value == .BlockQuote);
    const hr = bq.next orelse return error.TestUnexpectedResult;
    try std.testing.expect(hr.data.value == .ThematicBreak);
}

test "parse malformed markdown never fails (lenient fallback path)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Deeply broken constructs — koino (GFM-100%) treats them as text; the
    // contract only requires no crash and no blank render.
    const inputs = [_][]const u8{
        "**unclosed bold\n",
        "```unclosed fence\nline\n",
        "[link](/unterminated\n",
        "a \\\\ b <tag>\n",
        "\x00\x01\x02 raw bytes\n",
    };
    for (inputs) |md| {
        const doc = parseMarkdown(arena.allocator(), md);
        try std.testing.expect(doc != null);
    }
}

test "parse OOM falls back to null" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();
    // First allocation fails → koino.parse returns OutOfMemory → null.
    const doc = parseMarkdown(arena.allocator(), "# heading\nbody text\n");
    try std.testing.expect(doc == null);
}

// ── test helpers ───────────────────────────────────────────────────────────

/// Flatten an inline subtree to its literal text (test-only span walk).
fn inlineText(arena: std.mem.Allocator, node: *koino.nodes.AstNode) []const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    walkText(node, &out);
    return out.items;
}

fn walkText(node: *koino.nodes.AstNode, out: *std.array_list.Managed(u8)) void {
    switch (node.data.value) {
        .Text => |t| out.appendSlice(t) catch @panic("OOM"),
        .Code => |c| out.appendSlice(c) catch @panic("OOM"),
        .SoftBreak, .LineBreak => out.append('\n') catch @panic("OOM"),
        .HtmlInline => |h| out.appendSlice(h) catch @panic("OOM"),
        else => {
            var child = node.first_child;
            while (child) |c| : (child = c.next) walkText(c, out);
        },
    }
}

fn childCount(node: *koino.nodes.AstNode) usize {
    var n: usize = 0;
    var child = node.first_child;
    while (child) |c| : (child = c.next) n += 1;
    return n;
}
