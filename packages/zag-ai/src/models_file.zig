//! User / project model manifest (`models.json`) — tui-model-picker-001 Wave C.
//!
//! Search + merge:
//! 1. `$HOME/.zag/models.json` (user, base)
//! 2. `.zag/models.json` (project, cwd-relative; upserts by provider id)
//!
//! Missing files / missing `$HOME` are not errors. Invalid JSON is skipped
//! at load (picker stays catalog-only) and rejected by `parseOwned` (tests).
//!
//! Auth (pi-aligned, fail-closed):
//! - builtin preset id → that preset's `env_keys` (keyless ollama is available)
//! - new id → resolve `api_key` (`$ENV` / `${ENV}` / literal)
//! - unresolved env or missing key on a new id → models stay absent

const std = @import("std");
const Io = std.Io;
const presets = @import("presets.zig");
const auth_env = @import("auth_env.zig");
const wire = @import("wire.zig");
const config_mod = @import("config.zig");
const registry = @import("registry.zig");

pub const Error = error{
    OutOfMemory,
    IoFailed,
    InvalidConfig,
};

pub const ModelEntry = struct {
    id: []const u8,
    name: []const u8 = "",

    fn deinit(self: *ModelEntry, gpa: std.mem.Allocator) void {
        if (self.id.len > 0) gpa.free(self.id);
        if (self.name.len > 0) gpa.free(self.name);
        self.* = .{ .id = "" };
    }
};

pub const ProviderEntry = struct {
    id: []const u8,
    name: []const u8 = "",
    base_url: []const u8 = "",
    api: wire.ApiStyle = .openai_compat,
    /// Raw `api_key` field as written (`$ENV` / `${ENV}` / literal).
    api_key_raw: []const u8 = "",
    models: []ModelEntry = &.{},

    fn deinit(self: *ProviderEntry, gpa: std.mem.Allocator) void {
        if (self.id.len > 0) gpa.free(self.id);
        if (self.name.len > 0) gpa.free(self.name);
        if (self.base_url.len > 0) gpa.free(self.base_url);
        if (self.api_key_raw.len > 0) gpa.free(self.api_key_raw);
        for (self.models) |*m| m.deinit(gpa);
        if (self.models.len > 0) gpa.free(self.models);
        self.* = .{ .id = "" };
    }

    pub fn displayName(self: ProviderEntry) []const u8 {
        return if (self.name.len > 0) self.name else self.id;
    }
};

pub const Manifest = struct {
    providers: []ProviderEntry = &.{},

    pub fn deinit(self: *Manifest, gpa: std.mem.Allocator) void {
        for (self.providers) |*p| p.deinit(gpa);
        if (self.providers.len > 0) gpa.free(self.providers);
        self.* = .{};
    }

    pub fn find(self: Manifest, id: []const u8) ?*ProviderEntry {
        for (self.providers) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }
};

/// `$ENV` / `${ENV}` → env lookup; anything else is a literal key.
/// Empty / unresolved env → null (no auth).
pub fn resolveApiKeyValue(raw: []const u8, getter: anytype) ?[]const u8 {
    if (raw.len == 0) return null;
    if (raw[0] != '$') return raw;
    const name = blk: {
        if (raw.len >= 3 and raw[1] == '{') {
            if (raw[raw.len - 1] != '}') return null;
            break :blk raw[2 .. raw.len - 1];
        }
        break :blk raw[1..];
    };
    if (name.len == 0) return null;
    const val = getter.get(name) orelse return null;
    if (val.len == 0) return null;
    return val;
}

/// Whether this manifest provider's models may appear in the picker.
pub fn authResolves(entry: ProviderEntry, getter: anytype) bool {
    if (presets.find(entry.id)) |spec| {
        if (spec.env_keys.len == 0) return true;
        return auth_env.resolveApiKeySource(getter, spec.env_keys) != null;
    }
    return resolveApiKeyValue(entry.api_key_raw, getter) != null;
}

/// Build a `registry.Resolved` for a manifest-only (non-builtin) provider.
/// Builtin ids should go through `registry.resolvePreset`.
pub fn resolveCustom(
    entry: ProviderEntry,
    getter: anytype,
    model: []const u8,
) registry.Error!registry.Resolved {
    const key = resolveApiKeyValue(entry.api_key_raw, getter) orelse return error.MissingApiKey;
    if (entry.base_url.len == 0) return error.MissingBaseUrl;
    const model_id = if (model.len > 0) model else if (entry.models.len > 0) entry.models[0].id else return error.UnknownProvider;
    return .{
        .spec_id = entry.id,
        .display_name = entry.displayName(),
        .api_key_source = "models.json",
        .api_style = entry.api,
        .config = config_mod.Config{
            .api_key = key,
            .base_url = entry.base_url,
            .model = model_id,
            .api_style = entry.api,
        },
    };
}

pub fn parseOwned(gpa: std.mem.Allocator, raw: []const u8) Error!Manifest {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch
        return error.InvalidConfig;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const root = parsed.value.object;
    const providers_v = root.get("providers") orelse {
        return .{};
    };
    if (providers_v != .object) return error.InvalidConfig;

    var list: std.ArrayList(ProviderEntry) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }

    var it = providers_v.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) return error.InvalidConfig;
        const o = kv.value_ptr.*.object;
        var entry = try parseProvider(gpa, kv.key_ptr.*, o);
        errdefer entry.deinit(gpa);
        try list.append(gpa, entry);
    }

    return .{ .providers = try list.toOwnedSlice(gpa) };
}

fn parseProvider(
    gpa: std.mem.Allocator,
    id: []const u8,
    o: std.json.ObjectMap,
) Error!ProviderEntry {
    var entry: ProviderEntry = .{ .id = try gpa.dupe(u8, id) };
    errdefer entry.deinit(gpa);

    if (o.get("name")) |v| {
        if (v == .string) entry.name = try gpa.dupe(u8, v.string);
    }
    if (o.get("base_url")) |v| {
        if (v == .string) entry.base_url = try gpa.dupe(u8, v.string);
    } else if (o.get("baseUrl")) |v| {
        // Accept pi's camelCase as an alias; Zag schema is snake_case.
        if (v == .string) entry.base_url = try gpa.dupe(u8, v.string);
    }
    if (o.get("api")) |v| {
        if (v == .string) {
            entry.api = wire.ApiStyle.parse(v.string) orelse return error.InvalidConfig;
        }
    }
    if (o.get("api_key")) |v| {
        if (v == .string) entry.api_key_raw = try gpa.dupe(u8, v.string);
    } else if (o.get("apiKey")) |v| {
        if (v == .string) entry.api_key_raw = try gpa.dupe(u8, v.string);
    }

    const models_v = o.get("models") orelse return entry;
    if (models_v != .array) return error.InvalidConfig;
    var models: std.ArrayList(ModelEntry) = .empty;
    errdefer {
        for (models.items) |*m| m.deinit(gpa);
        models.deinit(gpa);
    }
    for (models_v.array.items) |item| {
        if (item != .object) return error.InvalidConfig;
        const mo = item.object;
        const id_v = mo.get("id") orelse continue;
        if (id_v != .string or id_v.string.len == 0) continue;
        var me: ModelEntry = .{ .id = try gpa.dupe(u8, id_v.string) };
        errdefer me.deinit(gpa);
        if (mo.get("name")) |nv| {
            if (nv == .string and nv.string.len > 0) me.name = try gpa.dupe(u8, nv.string);
        }
        try models.append(gpa, me);
    }
    entry.models = try models.toOwnedSlice(gpa);
    return entry;
}

fn loadPath(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
) Error!?Manifest {
    const raw = cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(raw);
    return parseOwned(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

/// Load user then project; project upserts by provider id. Missing = empty.
pub fn loadMerged(
    gpa: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    user_path: ?[]const u8,
    project_path: []const u8,
) Error!Manifest {
    var user_m = if (user_path) |p|
        (try loadPath(gpa, io, cwd, p)) orelse Manifest{}
    else
        Manifest{};
    defer user_m.deinit(gpa);
    var proj_m = (try loadPath(gpa, io, cwd, project_path)) orelse Manifest{};
    defer proj_m.deinit(gpa);

    var list: std.ArrayList(ProviderEntry) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }

    for (user_m.providers) |p| {
        try list.append(gpa, try cloneProvider(gpa, p));
    }
    for (proj_m.providers) |p| {
        var cloned = try cloneProvider(gpa, p);
        upsertCloned(gpa, &list, &cloned) catch |err| {
            cloned.deinit(gpa);
            return err;
        };
    }

    return .{ .providers = try list.toOwnedSlice(gpa) };
}

fn cloneProvider(gpa: std.mem.Allocator, src: ProviderEntry) Error!ProviderEntry {
    var dst: ProviderEntry = .{
        .id = try gpa.dupe(u8, src.id),
        .api = src.api,
    };
    errdefer dst.deinit(gpa);
    if (src.name.len > 0) dst.name = try gpa.dupe(u8, src.name);
    if (src.base_url.len > 0) dst.base_url = try gpa.dupe(u8, src.base_url);
    if (src.api_key_raw.len > 0) dst.api_key_raw = try gpa.dupe(u8, src.api_key_raw);
    if (src.models.len == 0) return dst;
    const models = try gpa.alloc(ModelEntry, src.models.len);
    var n: usize = 0;
    errdefer {
        for (models[0..n]) |*m| m.deinit(gpa);
        gpa.free(models);
    }
    for (src.models) |m| {
        var copy: ModelEntry = .{ .id = try gpa.dupe(u8, m.id) };
        errdefer copy.deinit(gpa);
        if (m.name.len > 0) copy.name = try gpa.dupe(u8, m.name);
        models[n] = copy;
        n += 1;
    }
    dst.models = models;
    return dst;
}

fn upsertCloned(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(ProviderEntry),
    incoming: *ProviderEntry,
) !void {
    for (list.items, 0..) |*existing, i| {
        if (std.mem.eql(u8, existing.id, incoming.id)) {
            existing.deinit(gpa);
            list.items[i] = incoming.*;
            incoming.* = .{ .id = "" };
            return;
        }
    }
    try list.append(gpa, incoming.*);
    incoming.* = .{ .id = "" };
}

const TestEnv = struct {
    pairs: []const struct { []const u8, []const u8 },
    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| {
            if (std.mem.eql(u8, p[0], key)) return p[1];
        }
        return null;
    }
};

test "parse models.json providers and models" {
    const gpa = std.testing.allocator;
    var m = try parseOwned(gpa,
        \\{
        \\  "providers": {
        \\    "my-ollama": {
        \\      "name": "Ollama (home)",
        \\      "base_url": "http://192.168.1.10:11434/v1",
        \\      "api": "openai_compat",
        \\      "api_key": "$OLLAMA_API_KEY",
        \\      "models": [
        \\        { "id": "qwen2.5-coder:7b", "name": "Qwen Coder 7B" },
        \\        { "id": "deepseek-v4-flash:0731" }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), m.providers.len);
    const p = m.providers[0];
    try std.testing.expectEqualStrings("my-ollama", p.id);
    try std.testing.expectEqualStrings("Ollama (home)", p.name);
    try std.testing.expectEqualStrings("http://192.168.1.10:11434/v1", p.base_url);
    try std.testing.expect(p.api == .openai_compat);
    try std.testing.expectEqualStrings("$OLLAMA_API_KEY", p.api_key_raw);
    try std.testing.expectEqual(@as(usize, 2), p.models.len);
    try std.testing.expectEqualStrings("qwen2.5-coder:7b", p.models[0].id);
    try std.testing.expectEqualStrings("Qwen Coder 7B", p.models[0].name);
    try std.testing.expectEqualStrings("deepseek-v4-flash:0731", p.models[1].id);
}

test "resolveApiKeyValue env dollar and literal" {
    const env = TestEnv{ .pairs = &.{
        .{ "OLLAMA_API_KEY", "sk-ol" },
    } };
    try std.testing.expectEqualStrings("sk-ol", resolveApiKeyValue("$OLLAMA_API_KEY", env).?);
    try std.testing.expectEqualStrings("sk-ol", resolveApiKeyValue("${OLLAMA_API_KEY}", env).?);
    try std.testing.expectEqualStrings("literal-key", resolveApiKeyValue("literal-key", env).?);
    try std.testing.expect(resolveApiKeyValue("$MISSING", env) == null);
    try std.testing.expect(resolveApiKeyValue("${MISSING}", env) == null);
    try std.testing.expect(resolveApiKeyValue("", env) == null);
}

test "authResolves: new provider needs key; builtin uses env_keys" {
    const keyed = TestEnv{ .pairs = &.{
        .{ "OPENAI_API_KEY", "sk-oai" },
        .{ "HOME_KEY", "sk-home" },
    } };
    const empty = TestEnv{ .pairs = &.{} };

    var custom = try parseOwned(std.testing.allocator,
        \\{"providers":{"my-ollama":{"api_key":"$HOME_KEY","models":[{"id":"x"}]}}}
    );
    defer custom.deinit(std.testing.allocator);
    try std.testing.expect(authResolves(custom.providers[0], keyed));
    try std.testing.expect(!authResolves(custom.providers[0], empty));

    var openai = try parseOwned(std.testing.allocator,
        \\{"providers":{"openai":{"models":[{"id":"gpt-4o"}]}}}
    );
    defer openai.deinit(std.testing.allocator);
    try std.testing.expect(authResolves(openai.providers[0], keyed));
    try std.testing.expect(!authResolves(openai.providers[0], empty));

    var ollama = try parseOwned(std.testing.allocator,
        \\{"providers":{"ollama":{"models":[{"id":"llama3.2"}]}}}
    );
    defer ollama.deinit(std.testing.allocator);
    try std.testing.expect(authResolves(ollama.providers[0], empty));
}

test "loadMerged: project upserts user by provider id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "user.json",
        .data =
            \\{"providers":{"a":{"name":"User A","api_key":"ua","models":[{"id":"m1"}]},"b":{"name":"User B","api_key":"ub","models":[{"id":"m2"}]}}}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "project.json",
        .data =
            \\{"providers":{"a":{"name":"Project A","api_key":"pa","models":[{"id":"m9"}]}}}
        ,
    });

    var m = try loadMerged(gpa, io, tmp.dir, "user.json", "project.json");
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), m.providers.len);
    const a = m.find("a").?;
    try std.testing.expectEqualStrings("Project A", a.name);
    try std.testing.expectEqualStrings("m9", a.models[0].id);
    const b = m.find("b").?;
    try std.testing.expectEqualStrings("User B", b.name);
}

test "loadMerged: missing files are empty" {
    const gpa = std.testing.allocator;
    var m = try loadMerged(gpa, std.testing.io, Io.Dir.cwd(), null, "no-such-zag-models.json");
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), m.providers.len);
}

test "unknown fields ignored; models without id skipped" {
    const gpa = std.testing.allocator;
    var m = try parseOwned(gpa,
        \\{"providers":{"x":{"compat":"x","models":[{"name":"no-id"},{"id":"ok"}],"headers":{}}}}
    );
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), m.providers[0].models.len);
    try std.testing.expectEqualStrings("ok", m.providers[0].models[0].id);
}
