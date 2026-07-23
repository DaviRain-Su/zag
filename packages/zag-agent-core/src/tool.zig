//! Tool definitions + local dispatch.
//!
//! A tool is what the model *sees* (name, description, JSON schema) plus a
//! local handler that turns arguments into a string result for the transcript.

const std = @import("std");
const Io = std.Io;
const ai = @import("zag-ai");

pub const max_result_bytes: usize = 64 * 1024;

/// OpenAI-style function tool definition (from zag-ai).
pub const Definition = ai.ToolDefinition;

pub const HandlerError = error{
    InvalidArguments,
    ToolFailed,
    OutOfMemory,
};

/// Context passed into every tool handler.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Working directory for relative paths (Phase 0: process cwd).
    cwd: Io.Dir,
};

pub const Handler = *const fn (ctx: Context, arguments_json: []const u8) HandlerError![]u8;

pub const Tool = struct {
    definition: Definition,
    handler: Handler,
};

/// Slice of tools exposed to the model + local handlers (core type; product bundles live in coding-agent).
pub const Toolset = struct {
    tools: []const Tool,

    pub fn registry(self: Toolset) Registry {
        return .{ .tools = self.tools };
    }
};

pub const Registry = struct {
    tools: []const Tool,

    pub fn find(self: Registry, name: []const u8) ?Tool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.definition.name, name)) return t;
        }
        return null;
    }

    /// Run a tool by name. On unknown tools or handler errors, returns an
    /// allocated error string the model can read (never hard-fails the loop).
    pub fn execute(
        self: Registry,
        ctx: Context,
        name: []const u8,
        arguments_json: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        const tool = self.find(name) orelse {
            return std.fmt.allocPrint(
                ctx.allocator,
                "error: unknown tool '{s}'",
                .{name},
            );
        };
        return tool.handler(ctx, arguments_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArguments => std.fmt.allocPrint(
                ctx.allocator,
                "error: invalid arguments for '{s}': {s}",
                .{ name, arguments_json },
            ),
            error.ToolFailed => std.fmt.allocPrint(
                ctx.allocator,
                "error: tool '{s}' failed",
                .{name},
            ),
        };
    }

    pub fn definitions(self: Registry) []const Definition {
        // Callers usually iterate tools; keep a convenience if needed later.
        _ = self;
        return &.{};
    }
};

/// Parse a required string field from a flat JSON object.
pub fn requireStringField(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
) HandlerError![]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        arguments_json,
        .{},
    ) catch return error.InvalidArguments;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return error.InvalidArguments;
    if (val != .string) return error.InvalidArguments;

    // Copy out: Value strings are owned by the parse arena and freed on deinit.
    return allocator.dupe(u8, val.string) catch return error.OutOfMemory;
}

/// Optional string field; returns null if missing.
pub fn optionalStringField(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    field: []const u8,
) HandlerError!?[]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        arguments_json,
        .{},
    ) catch return error.InvalidArguments;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(field) orelse return null;
    if (val != .string) return error.InvalidArguments;
    return allocator.dupe(u8, val.string) catch return error.OutOfMemory;
}

test "requireStringField" {
    const gpa = std.testing.allocator;
    const path = try requireStringField(gpa, "{\"path\":\".\"}", "path");
    defer gpa.free(path);
    try std.testing.expectEqualStrings(".", path);

    try std.testing.expectError(
        error.InvalidArguments,
        requireStringField(gpa, "{}", "path"),
    );
}
