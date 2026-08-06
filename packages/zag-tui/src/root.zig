//! zag-tui — minimal host TUI product package (tui-minimal-001).
//!
//! Owns terminal channel, editor, history, card ring, permission modal,
//! reply-worker rendezvous, and the product-internal SignalHost port type.
//! Assembles public zag-coding-agent APIs only. Must not import zag-cli/sigint.

const std = @import("std");

pub const constants = @import("constants.zig");
pub const signal_host = @import("signal_host.zig");
pub const SignalHost = signal_host.SignalHost;
pub const present = @import("present.zig");
pub const cards = @import("cards.zig");
pub const editor = @import("editor.zig");
pub const permission = @import("permission.zig");
pub const keys = @import("keys.zig");
pub const terminal = @import("terminal.zig");
pub const theme = @import("theme.zig");
pub const overlay = @import("overlay.zig");
pub const slash_route = @import("slash_route.zig");
pub const layout = @import("layout.zig");
pub const md_parse = @import("md_parse.zig");
pub const md_render = @import("md_render.zig");
pub const scrollback = @import("scrollback.zig");
pub const render = @import("render.zig");
pub const app = @import("app.zig");
pub const App = app.App;
pub const OpenDisplay = app.OpenDisplay;
pub const TeardownProbe = app.TeardownProbe;
pub const ThemeHostOptions = theme.ThemeHostOptions;

pub const version = "0.5.0";

// §11 gate fixtures (named mapping).
test {
    _ = @import("tests_gate.zig");
}

test {
    std.testing.refAllDecls(@This());
}
