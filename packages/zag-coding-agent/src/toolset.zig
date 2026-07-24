//! Named bundles of coding tools (product layer).

const std = @import("std");
const core = @import("zag-agent-core");
const tool = core.tool;
const fs_tools = @import("runtime/fs_tools.zig");
const edit_tools = @import("runtime/edit_tools.zig");

pub const Toolset = tool.Toolset;

/// Phase 0 read-only tools only (kept for narrow tests).
pub const Phase0Storage = struct {
    tools: [2]tool.Tool,

    pub fn init() Phase0Storage {
        return .{ .tools = fs_tools.phase0Tools() };
    }

    pub fn toolset(self: *Phase0Storage) Toolset {
        return .{ .tools = &self.tools };
    }
};

/// Default coding toolset: explore + search + edit + shell.
pub const Phase1Storage = struct {
    tools: [7]tool.Tool,

    pub fn init() Phase1Storage {
        const ro = fs_tools.phase0Tools();
        const search = fs_tools.searchTools();
        const rw = edit_tools.phase1ExtraTools();
        return .{
            .tools = .{
                ro[0], // list_dir
                ro[1], // read_file
                search[0], // grep
                search[1], // glob
                rw[0], // search_replace (preferred edit)
                rw[1], // write_file
                rw[2], // run_shell
            },
        };
    }

    pub fn toolset(self: *Phase1Storage) Toolset {
        return .{ .tools = &self.tools };
    }
};

test "every built-in declares complete descriptor capabilities" {
    const gpa = std.testing.allocator;
    const storage = Phase1Storage.init();
    const tools = storage.tools;
    try tool.validateTools(gpa, &tools);

    const expected = [_]struct {
        name: []const u8,
        risk: tool.ToolRisk,
        uses_path: bool,
        shell: tool.ShellPolicyKind,
    }{
        .{ .name = "list_dir", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "read_file", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "grep", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "glob", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "search_replace", .risk = .write, .uses_path = true, .shell = .none },
        .{ .name = "write_file", .risk = .write, .uses_path = true, .shell = .none },
        .{ .name = "run_shell", .risk = .execute, .uses_path = false, .shell = .command_argument },
    };

    try std.testing.expectEqual(expected.len, tools.len);
    for (expected, tools) |exp, t| {
        try std.testing.expectEqualStrings(exp.name, t.descriptor.definition.name);
        try std.testing.expect(t.descriptor.capabilities.risk == exp.risk);
        try std.testing.expect(t.descriptor.capabilities.workspace.usesPath() == exp.uses_path);
        try std.testing.expect(t.descriptor.capabilities.shell == exp.shell);
        try std.testing.expect(t.descriptor.capabilities.cancellation == .none);
        try std.testing.expect(t.instance == null);
        // Name never substitutes for risk: each capability field is set explicitly.
        try std.testing.expect(t.descriptor.definition.name.len > 0);
        try std.testing.expect(t.descriptor.definition.parameters_json.len > 0);
    }
}
