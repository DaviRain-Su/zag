//! Executable entry — thin process main. CLI logic lives in `zag-cli`.

const std = @import("std");
const zag_cli = @import("zag-cli");

pub fn main(init: std.process.Init) !void {
    try zag_cli.run(init);
}
