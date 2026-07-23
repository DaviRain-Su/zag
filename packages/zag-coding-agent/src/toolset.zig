//! Named bundles of coding tools (product layer).

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

/// Phase 1 full coding toolset: list/read/write/shell.
pub const Phase1Storage = struct {
    tools: [4]tool.Tool,

    pub fn init() Phase1Storage {
        const ro = fs_tools.phase0Tools();
        const rw = edit_tools.phase1ExtraTools();
        return .{
            .tools = .{
                ro[0],
                ro[1],
                rw[0],
                rw[1],
            },
        };
    }

    pub fn toolset(self: *Phase1Storage) Toolset {
        return .{ .tools = &self.tools };
    }
};
