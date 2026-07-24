//! Model catalog ↔ JSON via [comptime-serde](https://github.com/jiacai2050/comptime-serde).
//!
//! The **runtime / comptime table** stays in `catalog_data.zig` (Python freeze): Zig 0.16
//! `std.json` still needs a real allocator, so we do not parse the catalog at comptime.
//!
//! This module uses comptime-serde for:
//! 1. **Serialize** `ModelInfo` → JSON (inspect / tooling)
//! 2. **Deserialize** `data/catalog.json` → compare against the frozen table
//!
//! Type dispatch for Serde is comptime; parse/alloc of JSON is still runtime.

const std = @import("std");
const serde = @import("comptime_serde");
const catalog = @import("catalog.zig");

pub const CostRates = catalog.CostRates;
pub const ModelInfo = catalog.ModelInfo;

/// Shape of `data/catalog.json` (merged tooling view).
pub const CatalogFile = struct {
    version: u32,
    generated_note: []const u8,
    models: []const ModelInfo,
};

const model_json = serde.Serde(.json, ModelInfo);
const catalog_json = serde.Serde(.json, CatalogFile);

/// Serialize one model to JSON (caller owns `out` buffer via Writer).
pub fn serializeModel(writer: *std.Io.Writer, model: ModelInfo) !void {
    try model_json.serialize(writer, model);
}

/// Serialize the full frozen table as a CatalogFile document.
pub fn serializeCatalog(writer: *std.Io.Writer) !void {
    try catalog_json.serialize(writer, .{
        .version = 1,
        .generated_note = "Serialized from frozen catalog_data.zig via comptime-serde",
        .models = catalog.models,
    });
}

/// Parse merged catalog JSON (e.g. `@embedFile` of `data/catalog.json`).
pub fn parseCatalogJson(allocator: std.mem.Allocator, input: []const u8) !serde.Parsed(CatalogFile) {
    return catalog_json.deserialize(allocator, input);
}

fn modelsEqual(a: ModelInfo, b: ModelInfo) bool {
    if (!std.mem.eql(u8, a.id, b.id)) return false;
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (!std.mem.eql(u8, a.provider, b.provider)) return false;
    if (a.context_window != b.context_window) return false;
    if (a.max_output_tokens != b.max_output_tokens) return false;
    if (a.reasoning != b.reasoning) return false;
    if (a.vision != b.vision) return false;
    if (a.cost == null and b.cost == null) return true;
    if (a.cost == null or b.cost == null) return false;
    const ac = a.cost.?;
    const bc = b.cost.?;
    return ac.input == bc.input and ac.output == bc.output and
        ac.cache_read == bc.cache_read and ac.cache_write == bc.cache_write;
}

test "serialize ModelInfo to JSON" {
    const m = catalog.find("openai", "gpt-4o-mini").?;
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeModel(&writer, m);
    const json = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"gpt-4o-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"vision\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cost\":") != null);
}

test "ModelInfo JSON roundtrip via comptime-serde" {
    const gpa = std.testing.allocator;
    const m = catalog.find("deepseek", "deepseek-v4-flash").?;
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try serializeModel(&writer, m);

    var parsed = try model_json.deserialize(gpa, writer.buffered());
    defer parsed.deinit();
    try std.testing.expect(modelsEqual(m, parsed.value));
}

test "serialize full catalog roundtrips and matches frozen table" {
    const gpa = std.testing.allocator;
    var list: std.Io.Writer.Allocating = .init(gpa);
    defer list.deinit();
    try serializeCatalog(&list.writer);
    try list.writer.flush();

    var parsed = try parseCatalogJson(gpa, list.written());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(catalog.models.len, parsed.value.models.len);
    for (catalog.models, parsed.value.models) |frozen, from_json| {
        try std.testing.expect(modelsEqual(frozen, from_json));
    }
}

test "data/catalog.json matches frozen table via comptime-serde" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // `zig build test` cwd is the monorepo (or package) root.
    const candidates = [_][]const u8{
        "packages/zag-ai/data/catalog.json",
        "data/catalog.json",
    };
    const file_bytes = blk: {
        for (candidates) |path| {
            break :blk std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(2 << 20)) catch continue;
        }
        return error.FileNotFound;
    };
    defer gpa.free(file_bytes);

    var parsed = try parseCatalogJson(gpa, file_bytes);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(catalog.models.len, parsed.value.models.len);
    for (catalog.models, parsed.value.models) |frozen, from_json| {
        try std.testing.expect(modelsEqual(frozen, from_json));
    }
}
