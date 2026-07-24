//! Tool definitions + local dispatch.
//!
//! Model-visible schema (`ToolDefinition`) is separate from local runtime
//! capabilities (`ToolDescriptor` / `ToolCapabilities`). Permission, workspace
//! jail, shell policy, and tracing consume the descriptor — never tool names.
//!
//! ## Lifetime / ownership
//!
//! - **Instance** (`?*anyopaque`): borrowed. The caller owns the pointed-to
//!   state; it must outlive every `handler` invocation for this `Tool`.
//! - **Descriptor strings** (name, description, schema, `path_field` name):
//!   borrowed. They must remain valid for the lifetime of every copy of the
//!   `Tool` / `Toolset` that references them (typically static or arena-owned).
//! - **`Tool` is copyable** (move-friendly by value). Copies share the same
//!   borrowed instance pointer and string slices; there is no deep clone.
//! - **Registration does not take ownership** of strings or the instance.

const std = @import("std");
const Io = std.Io;
const zt = @import("zag-types");

pub const max_result_bytes: usize = 64 * 1024;

/// Function tool definition (canonical; from zag-types).
pub const Definition = zt.ToolDefinition;
pub const ToolRisk = zt.ToolRisk;
pub const WorkspaceAccess = zt.WorkspaceAccess;
pub const CancellationCapability = zt.CancellationCapability;
pub const ShellPolicyKind = zt.ShellPolicyKind;
pub const ToolCapabilities = zt.ToolCapabilities;
pub const ToolDescriptor = zt.ToolDescriptor;

pub const HandlerError = error{
    InvalidArguments,
    ToolFailed,
    OutOfMemory,
};

/// Typed failures at the public registration / toolset validation boundary.
pub const RegistrationError = error{
    /// Dynamic adapter omitted capabilities (fail closed — never default risk).
    MissingCapabilities,
    InvalidName,
    InvalidSchema,
    DuplicateName,
};

/// Context passed into every tool handler.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Working directory for relative paths (Phase 0: process cwd).
    cwd: Io.Dir,
};

/// Instance-aware handler. Stateless built-ins receive `instance == null`.
pub const Handler = *const fn (
    ctx: Context,
    instance: ?*anyopaque,
    arguments_json: []const u8,
) HandlerError![]u8;

/// Validated local tool: mandatory descriptor + borrowed instance + handler.
/// Capabilities are never optional on a registered Tool.
pub const Tool = struct {
    descriptor: ToolDescriptor,
    instance: ?*anyopaque = null,
    handler: Handler,

    pub fn name(self: Tool) []const u8 {
        return self.descriptor.definition.name;
    }

    pub fn definition(self: Tool) Definition {
        return self.descriptor.definition;
    }

    pub fn capabilities(self: Tool) ToolCapabilities {
        return self.descriptor.capabilities;
    }
};

/// Public fallible registration input for dynamic adapters (MCP/plugins).
/// `capabilities` is optional only at this boundary; missing → typed error.
pub const Registration = struct {
    definition: Definition,
    /// Required at validation time. Omitted/null fails closed.
    capabilities: ?ToolCapabilities = null,
    instance: ?*anyopaque = null,
    handler: Handler,
};

/// Build a validated `Tool` from a registration. Fail closed on missing metadata.
pub fn buildTool(allocator: std.mem.Allocator, reg: Registration) RegistrationError!Tool {
    const caps = reg.capabilities orelse return error.MissingCapabilities;
    try validateDefinition(allocator, reg.definition);
    return .{
        .descriptor = .{
            .definition = reg.definition,
            .capabilities = caps,
        },
        .instance = reg.instance,
        .handler = reg.handler,
    };
}

/// Convenience: stateless tool with a fully-specified descriptor (built-ins).
pub fn stateless(descriptor: ToolDescriptor, handler: Handler) Tool {
    return .{
        .descriptor = descriptor,
        .instance = null,
        .handler = handler,
    };
}

fn validateDefinition(allocator: std.mem.Allocator, def: Definition) RegistrationError!void {
    const name = std.mem.trim(u8, def.name, " \t\r\n");
    if (name.len == 0) return error.InvalidName;
    if (def.parameters_json.len == 0) return error.InvalidSchema;

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        def.parameters_json,
        .{},
    ) catch return error.InvalidSchema;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSchema;
}

/// Validate a tool slice before the first provider call (fail closed).
pub fn validateTools(allocator: std.mem.Allocator, tools: []const Tool) RegistrationError!void {
    for (tools, 0..) |t, i| {
        try validateDefinition(allocator, t.descriptor.definition);
        const name = t.descriptor.definition.name;
        for (tools[0..i]) |prev| {
            if (std.mem.eql(u8, prev.descriptor.definition.name, name)) {
                return error.DuplicateName;
            }
        }
    }
}

/// Slice of tools exposed to the model + local handlers (core type; product bundles live in coding-agent).
pub const Toolset = struct {
    tools: []const Tool,

    pub fn registry(self: Toolset) Registry {
        return .{ .tools = self.tools };
    }
};

pub const Registry = struct {
    tools: []const Tool,

    /// Find by name; returns a pointer into the toolset slice (borrowed).
    pub fn find(self: Registry, name: []const u8) ?*const Tool {
        for (self.tools) |*t| {
            if (std.mem.eql(u8, t.descriptor.definition.name, name)) return t;
        }
        return null;
    }

    /// Arena-allocate model-visible definitions only (no capabilities/instance).
    pub fn definitions(self: Registry, arena: std.mem.Allocator) std.mem.Allocator.Error![]const Definition {
        const out = try arena.alloc(Definition, self.tools.len);
        for (self.tools, 0..) |t, i| {
            out[i] = t.descriptor.definition;
        }
        return out;
    }

    /// Run a tool by name. On unknown tools or handler errors, returns an
    /// allocated soft-fail string (`error: code=… message=…`) so the loop never
    /// hard-fails on tool mistakes.
    pub fn execute(
        self: Registry,
        ctx: Context,
        name: []const u8,
        arguments_json: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        const tool_error = @import("tool_error.zig");
        const found = self.find(name) orelse {
            const msg = try std.fmt.allocPrint(ctx.allocator, "unknown tool '{s}'", .{name});
            defer ctx.allocator.free(msg);
            return tool_error.format(ctx.allocator, .unknown_tool, msg);
        };
        return self.executeTool(ctx, found, arguments_json);
    }

    /// Execute a resolved tool (instance passed to handler).
    pub fn executeTool(
        self: Registry,
        ctx: Context,
        found: *const Tool,
        arguments_json: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        _ = self;
        const tool_error = @import("tool_error.zig");
        const name = found.descriptor.definition.name;
        return found.handler(ctx, found.instance, arguments_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidArguments => {
                const msg = try std.fmt.allocPrint(
                    ctx.allocator,
                    "invalid arguments for '{s}'",
                    .{name},
                );
                defer ctx.allocator.free(msg);
                return tool_error.format(ctx.allocator, .invalid_arguments, msg);
            },
            error.ToolFailed => {
                const msg = try std.fmt.allocPrint(
                    ctx.allocator,
                    "tool '{s}' failed",
                    .{name},
                );
                defer ctx.allocator.free(msg);
                return tool_error.format(ctx.allocator, .tool_failed, msg);
            },
        };
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

test "buildTool requires capabilities" {
    const gpa = std.testing.allocator;
    const noop = struct {
        fn h(_: Context, _: ?*anyopaque, _: []const u8) HandlerError![]u8 {
            return error.ToolFailed;
        }
    }.h;

    const missing = buildTool(gpa, .{
        .definition = .{
            .name = "custom_write",
            .description = "x",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = null,
        .handler = noop,
    });
    try std.testing.expectError(error.MissingCapabilities, missing);

    const ok = try buildTool(gpa, .{
        .definition = .{
            .name = "custom_write",
            .description = "x",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .none,
            .shell = .none,
        },
        .handler = noop,
    });
    try std.testing.expect(ok.capabilities().risk == .write);
    try std.testing.expect(ok.instance == null);
}

test "buildTool rejects empty name and non-object schema" {
    const gpa = std.testing.allocator;
    const noop = struct {
        fn h(_: Context, _: ?*anyopaque, _: []const u8) HandlerError![]u8 {
            return error.ToolFailed;
        }
    }.h;
    const caps: ToolCapabilities = .{
        .risk = .read,
        .workspace = .none,
        .cancellation = .none,
        .shell = .none,
    };

    try std.testing.expectError(error.InvalidName, buildTool(gpa, .{
        .definition = .{ .name = "  ", .description = "", .parameters_json = "{}" },
        .capabilities = caps,
        .handler = noop,
    }));
    try std.testing.expectError(error.InvalidSchema, buildTool(gpa, .{
        .definition = .{ .name = "t", .description = "", .parameters_json = "[]" },
        .capabilities = caps,
        .handler = noop,
    }));
}

test "validateTools detects duplicates" {
    const gpa = std.testing.allocator;
    const noop = struct {
        fn h(_: Context, _: ?*anyopaque, _: []const u8) HandlerError![]u8 {
            return error.ToolFailed;
        }
    }.h;
    const caps: ToolCapabilities = .{
        .risk = .read,
        .workspace = .none,
        .cancellation = .none,
        .shell = .none,
    };
    const t = try buildTool(gpa, .{
        .definition = .{ .name = "dup", .description = "", .parameters_json = "{}" },
        .capabilities = caps,
        .handler = noop,
    });
    const tools = [_]Tool{ t, t };
    try std.testing.expectError(error.DuplicateName, validateTools(gpa, &tools));
}

test "registry definitions exclude runtime fields" {
    const gpa = std.testing.allocator;
    const Counter = struct {
        n: u32 = 0,
        fn h(ctx: Context, instance: ?*anyopaque, _: []const u8) HandlerError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(instance.?));
            self.n += 1;
            return std.fmt.allocPrint(ctx.allocator, "{d}", .{self.n}) catch return error.OutOfMemory;
        }
    };
    var counter: Counter = .{};
    const t = try buildTool(gpa, .{
        .definition = .{
            .name = "counter",
            .description = "inc",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .execute,
            .workspace = .none,
            .cancellation = .none,
            .shell = .none,
        },
        .instance = &counter,
        .handler = Counter.h,
    });
    const reg: Registry = .{ .tools = &[_]Tool{t} };
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    const defs = try reg.definitions(arena_impl.allocator());
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("counter", defs[0].name);
    // Type-level: Definition has only name/description/parameters_json.
    try std.testing.expectEqualStrings("inc", defs[0].description);

    const ctx: Context = .{
        .allocator = gpa,
        .io = std.testing.io,
        .cwd = Io.Dir.cwd(),
    };
    const r1 = try reg.execute(ctx, "counter", "{}");
    defer gpa.free(r1);
    const r2 = try reg.execute(ctx, "counter", "{}");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("1", r1);
    try std.testing.expectEqualStrings("2", r2);
    try std.testing.expectEqual(@as(u32, 2), counter.n);
}

test "unknown tool soft-fails" {
    const gpa = std.testing.allocator;
    const reg: Registry = .{ .tools = &.{} };
    const ctx: Context = .{
        .allocator = gpa,
        .io = std.testing.io,
        .cwd = Io.Dir.cwd(),
    };
    const body = try reg.execute(ctx, "nope", "{}");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=unknown_tool") != null);
}
