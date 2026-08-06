//! Named bundles of coding tools (product layer).

const std = @import("std");
const core = @import("zag-agent-core");
const tool = core.tool;
const fs_tools = @import("runtime/fs_tools.zig");
const edit_tools = @import("runtime/edit_tools.zig");
const task_tool = @import("runtime/task_tool.zig");
const code_intel_tool = @import("runtime/code_intel_tool.zig");

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

/// Default coding toolset: explore + search + edit + apply_hunk + apply_transaction + shell + task + code_intel.
/// `apply_hunk` / `apply_transaction` share Agent-owned `ApplyHunkState` (B7);
/// `code_intel` owns the Agent-level LSP session state (lsp-001).
pub const Phase1Storage = struct {
    tools: [11]tool.Tool,

    pub fn init(apply_hunk_state: *edit_tools.ApplyHunkState, task_state: *task_tool.TaskToolState, code_intel_state: *code_intel_tool.CodeIntelState) Phase1Storage {
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
                edit_tools.makeApplyHunkTool(apply_hunk_state),
                edit_tools.makeApplyTransactionTool(apply_hunk_state),
                rw[2], // run_shell
                task_tool.makeTaskTool(task_state), // task (subagent dispatch)
                code_intel_tool.makeCodeIntelTool(code_intel_state), // code_intel (LSP-backed)
            },
        };
    }

    pub fn toolset(self: *Phase1Storage) Toolset {
        return .{ .tools = &self.tools };
    }
};

test "every built-in declares complete descriptor capabilities" {
    const gpa = std.testing.allocator;
    var apply_state: edit_tools.ApplyHunkState = .{};
    var task_state: task_tool.TaskToolState = undefined;
    var code_intel_state: code_intel_tool.CodeIntelState = .{ .gpa = gpa, .io = std.testing.io };
    defer code_intel_state.deinit();
    const storage = Phase1Storage.init(&apply_state, &task_state, &code_intel_state);
    const tools = storage.tools;
    try tool.validateTools(gpa, &tools);

    const expected = [_]struct {
        name: []const u8,
        risk: tool.ToolRisk,
        uses_path: bool,
        shell: tool.ShellPolicyKind,
        default_path: ?[]const u8 = null,
        stateful: bool = false,
    }{
        .{ .name = "list_dir", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "read_file", .risk = .read, .uses_path = true, .shell = .none },
        .{ .name = "grep", .risk = .read, .uses_path = true, .shell = .none, .default_path = "." },
        .{ .name = "glob", .risk = .read, .uses_path = true, .shell = .none, .default_path = "." },
        .{ .name = "search_replace", .risk = .write, .uses_path = true, .shell = .none },
        .{ .name = "write_file", .risk = .write, .uses_path = true, .shell = .none },
        .{ .name = "apply_hunk", .risk = .write, .uses_path = true, .shell = .none, .stateful = true },
        .{ .name = "apply_transaction", .risk = .write, .uses_path = false, .shell = .none, .stateful = true },
        .{ .name = "run_shell", .risk = .execute, .uses_path = false, .shell = .command_argument },
        .{ .name = "task", .risk = .execute, .uses_path = false, .shell = .none },
        .{ .name = "code_intel", .risk = .read, .uses_path = true, .shell = .none },
    };

    try std.testing.expectEqual(expected.len, tools.len);
    for (expected, tools) |exp, t| {
        try std.testing.expectEqualStrings(exp.name, t.descriptor.definition.name);
        try std.testing.expect(t.descriptor.capabilities.risk == exp.risk);
        try std.testing.expect(t.descriptor.capabilities.workspace.usesPath() == exp.uses_path);
        if (exp.default_path) |default_path| {
            try std.testing.expectEqualStrings(default_path, t.descriptor.capabilities.workspace.defaultPath().?);
        } else {
            try std.testing.expect(t.descriptor.capabilities.workspace.defaultPath() == null);
        }
        try std.testing.expect(t.descriptor.capabilities.shell == exp.shell);
        if (std.mem.eql(u8, exp.name, "task")) {
            // The task tool is cooperatively cancellable (child-agent cancel).
            try std.testing.expect(t.descriptor.capabilities.cancellation == .cooperative);
        } else {
            try std.testing.expect(t.descriptor.capabilities.cancellation == .none);
        }
        if (exp.stateful) {
            try std.testing.expect(t.instance == @as(?*anyopaque, @ptrCast(&apply_state)));
        } else if (std.mem.eql(u8, exp.name, "task")) {
            // The task tool's instance is the Agent-owned TaskToolState
            // (non-null, but not apply_state).
            try std.testing.expect(t.instance != null);
        } else if (std.mem.eql(u8, exp.name, "code_intel")) {
            // The code_intel tool's instance is the Agent-owned
            // CodeIntelState (non-null, but not apply_state).
            try std.testing.expect(t.instance == @as(?*anyopaque, @ptrCast(&code_intel_state)));
        } else {
            try std.testing.expect(t.instance == null);
        }
        // Name never substitutes for risk: each capability field is set explicitly.
        try std.testing.expect(t.descriptor.definition.name.len > 0);
        try std.testing.expect(t.descriptor.definition.parameters_json.len > 0);
    }
}
