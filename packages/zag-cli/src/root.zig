//! zag-cli — product shell (args, REPL, one-shot).
//!
//! Executable entry is a thin `main` that calls `run`.

const std = @import("std");

pub const cli = @import("cli.zig");
pub const run = cli.run;

pub const version = "0.5.0";

test {
    std.testing.refAllDecls(@This());
}
