//! Named bundles of tools. Phase 0 = read-only filesystem tools.

const tool = @import("tool.zig");
const fs_tools = @import("../runtime/fs_tools.zig");

pub const Toolset = struct {
    tools: []const tool.Tool,

    pub fn registry(self: Toolset) tool.Registry {
        return .{ .tools = self.tools };
    }
};

/// Storage for the Phase 0 built-in tools (must outlive any Toolset slice into it).
pub const Phase0Storage = struct {
    tools: [2]tool.Tool,

    pub fn init() Phase0Storage {
        return .{ .tools = fs_tools.phase0Tools() };
    }

    pub fn toolset(self: *Phase0Storage) Toolset {
        return .{ .tools = &self.tools };
    }
};
