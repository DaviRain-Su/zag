//! Theme catalog + role → vaxis.Style (theme-001).
//!
//! Fail-closed: missing/invalid selection → built-in `zag-default`.
//! Owner: zag-tui only. See docs/modules/theme.md.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

pub const schema_version: []const u8 = "zag-theme-v1";
pub const builtin_id: []const u8 = "zag-default";
/// All built-in themes (default first). `/theme` lists these before any
/// user themes from themes_root.
pub const builtin_ids = [_][]const u8{ "zag-default", "zag-ocean", "zag-mint", "zag-light" };

fn rgbf(r: u8, g: u8, b: u8) vaxis.Color {
    return .{ .rgb = .{ r, g, b } };
}

fn styleFg(color: vaxis.Color) vaxis.Style {
    return .{ .fg = color };
}

fn styleBg(color: vaxis.Color) vaxis.Style {
    return .{ .bg = color };
}

/// Assemble a palette from explicit per-role colors (fg roles → .fg,
/// `*_bg`/`bg` roles → .bg).
fn buildPalette(
    id: []const u8,
    fg: vaxis.Color,
    bg: vaxis.Color,
    status_fg: vaxis.Color,
    status_bg: vaxis.Color,
    card_fg: vaxis.Color,
    card_border: vaxis.Color,
    editor_fg: vaxis.Color,
    editor_bg: vaxis.Color,
    modal_fg: vaxis.Color,
    modal_border: vaxis.Color,
    error_fg: vaxis.Color,
    muted_fg: vaxis.Color,
    accent_fg: vaxis.Color,
) Palette {
    var styles: [Role.count]vaxis.Style = undefined;
    styles[@intFromEnum(Role.fg)] = styleFg(fg);
    styles[@intFromEnum(Role.bg)] = styleBg(bg);
    styles[@intFromEnum(Role.status_fg)] = styleFg(status_fg);
    styles[@intFromEnum(Role.status_bg)] = styleBg(status_bg);
    styles[@intFromEnum(Role.card_fg)] = styleFg(card_fg);
    styles[@intFromEnum(Role.card_border)] = styleFg(card_border);
    styles[@intFromEnum(Role.editor_fg)] = styleFg(editor_fg);
    styles[@intFromEnum(Role.editor_bg)] = styleBg(editor_bg);
    styles[@intFromEnum(Role.modal_fg)] = styleFg(modal_fg);
    styles[@intFromEnum(Role.modal_border)] = styleFg(modal_border);
    styles[@intFromEnum(Role.error_fg)] = styleFg(error_fg);
    styles[@intFromEnum(Role.muted_fg)] = styleFg(muted_fg);
    styles[@intFromEnum(Role.accent_fg)] = styleFg(accent_fg);
    return .{ .id = id, .styles = styles };
}

pub const ThemeHostOptions = struct {
    themes_root: ?[]const u8 = null,
    selected_id: ?[]const u8 = null,
};

pub const Role = enum {
    fg,
    bg,
    status_fg,
    status_bg,
    card_fg,
    card_border,
    editor_fg,
    editor_bg,
    modal_fg,
    modal_border,
    error_fg,
    muted_fg,
    accent_fg,

    pub const count = @typeInfo(Role).@"enum".fields.len;
};

pub const ColorSpec = union(enum) {
    named: []const u8,
    hex: [3]u8,
};

pub const Palette = struct {
    id: []const u8,
    styles: [Role.count]vaxis.Style,

    pub fn style(self: *const Palette, role: Role) vaxis.Style {
        return self.styles[@intFromEnum(role)];
    }
};

pub fn builtinDefault() Palette {
    var styles: [Role.count]vaxis.Style = undefined;
    styles[@intFromEnum(Role.fg)] = .{ .fg = .{ .index = 7 } };
    styles[@intFromEnum(Role.bg)] = .{};
    styles[@intFromEnum(Role.status_fg)] = .{ .fg = .{ .index = 6 } }; // cyan
    styles[@intFromEnum(Role.status_bg)] = .{};
    styles[@intFromEnum(Role.card_fg)] = .{ .fg = .{ .index = 7 } };
    styles[@intFromEnum(Role.card_border)] = .{ .fg = .{ .index = 8 } }; // brightBlack — muted border vs content fg
    styles[@intFromEnum(Role.editor_fg)] = .{ .fg = .{ .index = 2 } }; // green
    styles[@intFromEnum(Role.editor_bg)] = .{};
    styles[@intFromEnum(Role.modal_fg)] = .{ .fg = .{ .index = 5 } }; // magenta
    styles[@intFromEnum(Role.modal_border)] = .{ .fg = .{ .index = 8 } }; // brightBlack — muted border vs content fg
    styles[@intFromEnum(Role.error_fg)] = .{ .fg = .{ .index = 1 } };
    styles[@intFromEnum(Role.muted_fg)] = .{ .fg = .{ .index = 8 } };
    styles[@intFromEnum(Role.accent_fg)] = .{ .fg = .{ .index = 3 } }; // yellow — distinct from status cyan
    return .{ .id = builtin_id, .styles = styles };
}

/// One Dark-inspired cool palette (truecolor).
pub fn builtinOcean() Palette {
    return buildPalette(
        "zag-ocean",
        rgbf(0xAB, 0xB2, 0xBF), // fg
        rgbf(0x28, 0x2C, 0x34), // bg
        rgbf(0x61, 0xAF, 0xEF), // status_fg (blue)
        rgbf(0x28, 0x2C, 0x34), // status_bg
        rgbf(0xAB, 0xB2, 0xBF), // card_fg
        rgbf(0x3E, 0x44, 0x51), // card_border
        rgbf(0x98, 0xC3, 0x79), // editor_fg (green)
        rgbf(0x28, 0x2C, 0x34), // editor_bg
        rgbf(0xC6, 0x78, 0xDD), // modal_fg (purple)
        rgbf(0x3E, 0x44, 0x51), // modal_border
        rgbf(0xE0, 0x6C, 0x75), // error_fg (red)
        rgbf(0x5C, 0x63, 0x70), // muted_fg
        rgbf(0xE5, 0xC0, 0x7B), // accent_fg (yellow)
    );
}

/// Solarized-dark warm palette (truecolor).
pub fn builtinMint() Palette {
    return buildPalette(
        "zag-mint",
        rgbf(0x83, 0x94, 0x96), // fg
        rgbf(0x00, 0x2B, 0x36), // bg
        rgbf(0x2A, 0xA1, 0x98), // status_fg (cyan)
        rgbf(0x00, 0x2B, 0x36), // status_bg
        rgbf(0x93, 0xA1, 0xA1), // card_fg
        rgbf(0x07, 0x36, 0x42), // card_border
        rgbf(0x85, 0x99, 0x00), // editor_fg (olive green)
        rgbf(0x00, 0x2B, 0x36), // editor_bg
        rgbf(0xD3, 0x36, 0x82), // modal_fg (magenta)
        rgbf(0x07, 0x36, 0x42), // modal_border
        rgbf(0xDC, 0x32, 0x2F), // error_fg (red)
        rgbf(0x58, 0x6E, 0x75), // muted_fg
        rgbf(0xB5, 0x89, 0x00), // accent_fg (yellow)
    );
}

/// Solarized-light palette (truecolor, light background).
pub fn builtinLight() Palette {
    return buildPalette(
        "zag-light",
        rgbf(0x65, 0x7B, 0x83), // fg
        rgbf(0xFD, 0xF6, 0xE3), // bg
        rgbf(0x26, 0x8B, 0xD2), // status_fg (blue)
        rgbf(0xFD, 0xF6, 0xE3), // status_bg
        rgbf(0x58, 0x6E, 0x75), // card_fg
        rgbf(0xEE, 0xE8, 0xD5), // card_border
        rgbf(0x85, 0x99, 0x00), // editor_fg (olive)
        rgbf(0xFD, 0xF6, 0xE3), // editor_bg
        rgbf(0xD3, 0x36, 0x82), // modal_fg (magenta)
        rgbf(0xEE, 0xE8, 0xD5), // modal_border
        rgbf(0xDC, 0x32, 0x2F), // error_fg (red)
        rgbf(0x93, 0xA1, 0xA1), // muted_fg
        rgbf(0xB5, 0x89, 0x00), // accent_fg (yellow)
    );
}

/// Builtin by id; unknown ids fall back to the default.
pub fn builtinById(id: []const u8) Palette {
    if (std.mem.eql(u8, id, "zag-ocean")) return builtinOcean();
    if (std.mem.eql(u8, id, "zag-mint")) return builtinMint();
    if (std.mem.eql(u8, id, "zag-light")) return builtinLight();
    return builtinDefault();
}

fn namedToColor(name: []const u8) ?vaxis.Color {
    const table = [_]struct { []const u8, u8 }{
        .{ "black", 0 },
        .{ "red", 1 },
        .{ "green", 2 },
        .{ "yellow", 3 },
        .{ "blue", 4 },
        .{ "magenta", 5 },
        .{ "cyan", 6 },
        .{ "white", 7 },
        .{ "brightBlack", 8 },
        .{ "brightRed", 9 },
        .{ "brightGreen", 10 },
        .{ "brightYellow", 11 },
        .{ "brightBlue", 12 },
        .{ "brightMagenta", 13 },
        .{ "brightCyan", 14 },
        .{ "brightWhite", 15 },
        .{ "default", 7 },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row[0], name)) return .{ .index = row[1] };
    }
    return null;
}

fn parseHexColor(raw: []const u8) ?[3]u8 {
    if (raw.len != 7 or raw[0] != '#') return null;
    var out: [3]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        out[i] = std.fmt.parseInt(u8, raw[1 + i * 2 ..][0..2], 16) catch return null;
    }
    return out;
}

fn colorToVaxis(spec: ColorSpec) vaxis.Color {
    return switch (spec) {
        .named => |n| namedToColor(n) orelse .{ .index = 7 },
        .hex => |rgb| .{ .rgb = rgb },
    };
}

fn parseColorValue(v: std.json.Value) ?ColorSpec {
    return switch (v) {
        .string => |s| {
            if (s.len > 0 and s[0] == '#') {
                const rgb = parseHexColor(s) orelse return null;
                return .{ .hex = rgb };
            }
            if (namedToColor(s) == null) return null;
            return .{ .named = s };
        },
        else => null,
    };
}

const role_names = [_]struct { []const u8, Role }{
    .{ "fg", .fg },
    .{ "bg", .bg },
    .{ "status_fg", .status_fg },
    .{ "status_bg", .status_bg },
    .{ "card_fg", .card_fg },
    .{ "card_border", .card_border },
    .{ "editor_fg", .editor_fg },
    .{ "editor_bg", .editor_bg },
    .{ "modal_fg", .modal_fg },
    .{ "modal_border", .modal_border },
    .{ "error_fg", .error_fg },
    .{ "muted_fg", .muted_fg },
    .{ "accent_fg", .accent_fg },
};

/// Parse a theme JSON object. On any schema/role failure returns null (caller falls back).
pub fn parseThemeJson(allocator: std.mem.Allocator, bytes: []const u8) ?struct { id: []u8, palette: Palette } {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const obj = root.object;

    const ver = obj.get("schemaVersion") orelse return null;
    if (ver != .string or !std.mem.eql(u8, ver.string, schema_version)) return null;

    const id_v = obj.get("id") orelse return null;
    if (id_v != .string or id_v.string.len == 0) return null;

    const colors_v = obj.get("colors") orelse return null;
    if (colors_v != .object) return null;
    const colors = colors_v.object;

    var styles: [Role.count]vaxis.Style = undefined;
    const base = builtinDefault();
    styles = base.styles;

    var seen: [Role.count]bool = [_]bool{false} ** Role.count;
    for (role_names) |rn| {
        const raw = colors.get(rn[0]) orelse continue;
        const spec = parseColorValue(raw) orelse return null;
        const color = colorToVaxis(spec);
        const idx = @intFromEnum(rn[1]);
        // `*_bg` roles (and the `bg` role itself) paint the background; all
        // other roles paint the foreground (tui-polish-001 bg-parse fix).
        const is_bg_role = std.mem.eql(u8, rn[0], "bg") or std.mem.endsWith(u8, rn[0], "_bg");
        styles[idx] = if (is_bg_role) .{ .bg = color } else .{ .fg = color };
        seen[idx] = true;
    }
    for (role_names) |rn| {
        if (!seen[@intFromEnum(rn[1])]) return null;
    }

    const id_owned = allocator.dupe(u8, id_v.string) catch return null;
    return .{
        .id = id_owned,
        .palette = .{ .id = id_owned, .styles = styles },
    };
}

fn pathUnderRoot(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    return candidate[root.len] == std.fs.path.sep;
}

/// Resolve active palette: built-in or selected user theme under
/// themes_root, else builtin default (fail-closed).
pub fn resolveActive(gpa: std.mem.Allocator, io: Io, opts: ThemeHostOptions) Palette {
    const sel = opts.selected_id orelse return builtinDefault();
    for (builtin_ids) |bid| {
        if (std.mem.eql(u8, sel, bid)) return builtinById(bid);
    }
    const root = opts.themes_root orelse return builtinDefault();
    if (root.len == 0) return builtinDefault();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ root, sel }) catch return builtinDefault();
    if (!pathUnderRoot(root, path)) return builtinDefault();

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return builtinDefault();
    defer gpa.free(bytes);

    const parsed = parseThemeJson(gpa, bytes) orelse return builtinDefault();
    return parsed.palette;
}

/// List theme ids: all built-ins first, then user themes under root
/// (basename without .json, deduped against builtins). Cap 64.
pub fn listThemeIds(gpa: std.mem.Allocator, io: Io, root: ?[]const u8, out: *std.ArrayList([]const u8)) !void {
    for (builtin_ids) |bid| try out.append(gpa, bid);
    const r = root orelse return;
    var dir = Io.Dir.cwd().openDir(io, r, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        if (stem.len == 0) continue;
        var is_builtin = false;
        for (builtin_ids) |bid| {
            if (std.mem.eql(u8, stem, bid)) {
                is_builtin = true;
                break;
            }
        }
        if (is_builtin) continue;
        const owned = try gpa.dupe(u8, stem);
        try out.append(gpa, owned);
        if (out.items.len >= 64) break;
    }
}

test "builtinById dispatches the four builtins" {
    const o = builtinById("zag-ocean");
    try std.testing.expectEqualStrings("zag-ocean", o.id);
    try std.testing.expect(o.style(.card_fg).fg == .rgb);
    try std.testing.expect(o.style(.bg).bg == .rgb);
    const m = builtinById("zag-mint");
    try std.testing.expectEqualStrings("zag-mint", m.id);
    const l = builtinById("zag-light");
    try std.testing.expectEqualStrings("zag-light", l.id);
    try std.testing.expect(l.style(.bg).bg == .rgb); // light background
    // Unknown ids fail closed to the default.
    const d = builtinById("nope");
    try std.testing.expectEqualStrings(builtin_id, d.id);
    // Distinct accent/status per theme.
    try std.testing.expect(!std.mem.eql(u8, &o.style(.status_fg).fg.rgb, &o.style(.accent_fg).fg.rgb));
}

test "listThemeIds includes all builtins first" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |it| {
            if (!std.mem.eql(u8, it, "zag-default") and !std.mem.eql(u8, it, "zag-ocean") and !std.mem.eql(u8, it, "zag-mint") and !std.mem.eql(u8, it, "zag-light")) gpa.free(it);
        }
        list.deinit(gpa);
    }
    try listThemeIds(gpa, std.testing.io, null, &list);
    try std.testing.expectEqual(@as(usize, builtin_ids.len), list.items.len);
    try std.testing.expectEqualStrings("zag-default", list.items[0]);
    try std.testing.expectEqualStrings("zag-ocean", list.items[1]);
    try std.testing.expectEqualStrings("zag-light", list.items[3]);
}

test "builtinDefault has expected accents" {
    const p = builtinDefault();
    try std.testing.expectEqualStrings(builtin_id, p.id);
    try std.testing.expect(p.style(.status_fg).fg == .index);
}

test "parseThemeJson rejects wrong schema" {
    const gpa = std.testing.allocator;
    const bad =
        \\{"schemaVersion":"nope","id":"x","colors":{}}
    ;
    try std.testing.expect(parseThemeJson(gpa, bad) == null);
}

test "parseThemeJson accepts full role set" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"schemaVersion":"zag-theme-v1","id":"demo","colors":{
        \\"fg":"white","bg":"black","status_fg":"cyan","status_bg":"black",
        \\"card_fg":"white","card_border":"brightBlack","editor_fg":"green","editor_bg":"black",
        \\"modal_fg":"magenta","modal_border":"brightBlack","error_fg":"red","muted_fg":"brightBlack",
        \\"accent_fg":"#33aaff"}}
    ;
    const parsed = parseThemeJson(gpa, raw) orelse return error.TestUnexpectedResult;
    defer gpa.free(parsed.id);
    try std.testing.expectEqualStrings("demo", parsed.palette.id);
    try std.testing.expect(parsed.palette.style(.accent_fg).fg == .rgb);
}

test "parseThemeJson maps bg roles to .bg and fg roles to .fg" {
    const gpa = std.testing.allocator;
    const raw =
        \\{"schemaVersion":"zag-theme-v1","id":"roles","colors":{
        \\"fg":"white","bg":"black","status_fg":"cyan","status_bg":"blue",
        \\"card_fg":"white","card_border":"brightBlack","editor_fg":"green","editor_bg":"red",
        \\"modal_fg":"magenta","modal_border":"brightBlack","error_fg":"red","muted_fg":"brightBlack",
        \\"accent_fg":"yellow"}}
    ;
    const parsed = parseThemeJson(gpa, raw) orelse return error.TestUnexpectedResult;
    defer gpa.free(parsed.id);
    const p = &parsed.palette;
    // `*_bg` roles (and bare `bg`) land on `.bg`…
    try std.testing.expect(p.style(.bg).bg == .index);
    try std.testing.expect(p.style(.status_bg).bg == .index);
    try std.testing.expect(p.style(.editor_bg).bg == .index);
    // …foreground roles land on `.fg`.
    try std.testing.expect(p.style(.fg).fg == .index);
    try std.testing.expect(p.style(.status_fg).fg == .index);
    try std.testing.expect(p.style(.card_fg).fg == .index);
    try std.testing.expect(p.style(.editor_fg).fg == .index);
    // Border roles parse and apply as foreground styles.
    try std.testing.expect(p.style(.card_border).fg == .index);
    try std.testing.expect(p.style(.modal_border).fg == .index);
}

test "builtinDefault has distinct status and accent roles" {
    const p = builtinDefault();
    try std.testing.expect(p.style(.status_fg).fg == .index);
    try std.testing.expect(p.style(.accent_fg).fg == .index);
    const status_idx = p.style(.status_fg).fg.index;
    const accent_idx = p.style(.accent_fg).fg.index;
    try std.testing.expect(status_idx != accent_idx);
    // Border roles default to the muted ramp (brightBlack).
    try std.testing.expectEqual(@as(u8, 8), p.style(.card_border).fg.index);
    try std.testing.expectEqual(@as(u8, 8), p.style(.modal_border).fg.index);
}
