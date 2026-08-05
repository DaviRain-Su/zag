//! zag-cli — product shell (args, REPL, one-shot, optional TUI wire).
//!
//! Executable entry is a thin `main` that calls `run`.
//! Product TUI lives only in `packages/zag-tui/`; this package wires flags /
//! Guard / Agent when built with `-Dtui=true` (see `tui_entry.zig`).

const std = @import("std");

pub const cli = @import("cli.zig");
pub const run = cli.run;
pub const sigint = @import("sigint.zig");
pub const cli_stream = @import("cli_stream.zig");

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}

test "build_options tui_enabled is bool" {
    const build_options = @import("build_options");
    try std.testing.expect(@TypeOf(build_options.tui_enabled) == bool);
}
