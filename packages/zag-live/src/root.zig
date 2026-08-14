//! zag-live — supervised live Scheme image (policy layer; Gambit binding).
//! Binding contract: docs/modules/zag-live.md (zag-live-001, D-014 Route A).

pub const Live = @import("live.zig").Live;
pub const Error = @import("live.zig").Error;
pub const Config = @import("live.zig").Config;
pub const EnvPair = @import("live.zig").EnvPair;
pub const WatchdogConfig = @import("live.zig").WatchdogConfig;
pub const RecoverSummary = Live.RecoverSummary;

pub const frame = @import("frame.zig");
pub const journal = @import("journal.zig");
pub const generations = @import("generations.zig");
pub const ports = @import("ports.zig");

pub const ProviderPort = ports.ProviderPort;
pub const ToolPort = ports.ToolPort;
pub const FsReadPort = ports.FsReadPort;
pub const fsReadPort = ports.fsReadPort;
pub const max_frame_bytes = frame.max_frame_bytes;

test {
    _ = @import("frame.zig");
    _ = @import("journal.zig");
    _ = @import("generations.zig");
    _ = @import("ports.zig");
    _ = @import("live.zig");
    _ = @import("acceptance.zig");
}
