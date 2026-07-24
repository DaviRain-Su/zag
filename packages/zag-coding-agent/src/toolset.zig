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
