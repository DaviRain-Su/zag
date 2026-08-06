//! Theme catalog + role → vaxis.Style (theme-001).
//!
//! Fail-closed: missing/invalid selection → built-in `zag-default`.
//! Owner: zag-tui only. See docs/modules/theme.md.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

pub const schema_version: []const u8 = "zag-theme-v1";
pub const builtin_id: []const u8 = "zag-default";

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
    card_bg,
    editor_fg,
    editor_bg,
    modal_fg,
    modal_bg,
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
    styles[@intFromEnum(Role.card_bg)] = .{};
    styles[@intFromEnum(Role.editor_fg)] = .{ .fg = .{ .index = 2 } }; // green
    styles[@intFromEnum(Role.editor_bg)] = .{};
    styles[@intFromEnum(Role.modal_fg)] = .{ .fg = .{ .index = 5 } }; // magenta
    styles[@intFromEnum(Role.modal_bg)] = .{};
    styles[@intFromEnum(Role.error_fg)] = .{ .fg = .{ .index = 1 } };
    styles[@intFromEnum(Role.muted_fg)] = .{ .fg = .{ .index = 8 } };
    styles[@intFromEnum(Role.accent_fg)] = .{ .fg = .{ .index = 6 } };
    return .{ .id = builtin_id, .styles = styles };
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
    .{ "card_bg", .card_bg },
    .{ "editor_fg", .editor_fg },
    .{ "editor_bg", .editor_bg },
    .{ "modal_fg", .modal_fg },
    .{ "modal_bg", .modal_bg },
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
        styles[idx] = .{ .fg = color };
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

/// Resolve active palette: selected user theme if valid under themes_root, else builtin.
pub fn resolveActive(gpa: std.mem.Allocator, io: Io, opts: ThemeHostOptions) Palette {
    const sel = opts.selected_id orelse return builtinDefault();
    if (std.mem.eql(u8, sel, builtin_id)) return builtinDefault();
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

/// List theme ids available under root (basename without .json) + builtin. Cap 64.
pub fn listThemeIds(gpa: std.mem.Allocator, io: Io, root: ?[]const u8, out: *std.ArrayList([]const u8)) !void {
    try out.append(gpa, builtin_id);
    const r = root orelse return;
    var dir = Io.Dir.cwd().openDir(io, r, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        if (stem.len == 0) continue;
        if (std.mem.eql(u8, stem, builtin_id)) continue;
        const owned = try gpa.dupe(u8, stem);
        try out.append(gpa, owned);
        if (out.items.len >= 64) break;
    }
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
        \\"card_fg":"white","card_bg":"black","editor_fg":"green","editor_bg":"black",
        \\"modal_fg":"magenta","modal_bg":"black","error_fg":"red","muted_fg":"brightBlack",
        \\"accent_fg":"#33aaff"}}
    ;
    const parsed = parseThemeJson(gpa, raw) orelse return error.TestUnexpectedResult;
    defer gpa.free(parsed.id);
    try std.testing.expectEqualStrings("demo", parsed.palette.id);
    try std.testing.expect(parsed.palette.style(.accent_fg).fg == .rgb);
}
