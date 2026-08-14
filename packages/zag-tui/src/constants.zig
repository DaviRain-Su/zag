//! Frozen capacity constants (tui-minimal.md §6 / §8 / §10).

pub const editor_max_bytes: usize = 65536;
pub const editor_max_lines: usize = 512;
pub const history_capacity: usize = 64;
pub const history_entry_max_bytes: usize = 8192;

pub const ordinary_card_slots: usize = 125;
pub const terminal_reserve_slots: usize = 1;
pub const host_error_reserve_slots: usize = 1;
pub const drop_note_slots: usize = 1;
pub const card_slots: usize = ordinary_card_slots + terminal_reserve_slots + host_error_reserve_slots + drop_note_slots; // 128

pub const card_title_max_bytes: usize = 128;
pub const card_body_max_bytes: usize = 4096;
/// Tool-card body lines actually painted (title + this many + optional
/// "… +N lines" footer). Estimate/measure/render must share this cap or
/// a 4 KB glob/grep dump is reserved as ~100 blank rows.
pub const tool_body_max_lines: u16 = 6;
pub const permission_tool_name_max_bytes: usize = 64;

/// Overlay (slash / model / theme / resume) line buffer cap. Collection side
/// (`tui_picker_cap` in zag-cli/tui_entry.zig) must match. Raised so a
/// models.dev-adapted multi-provider catalog + user manifest fits and is
/// reachable via the overlay scroll viewport.
pub const overlay_line_cap: usize = 512;

/// Exact 14-byte ASCII truncation marker (not U+2026).
pub const truncation_marker: []const u8 = "...[truncated]";
pub const truncation_marker_len: usize = 14;

pub const poll_timeout_ms: i32 = 250;

pub const min_cols: u16 = 20;
pub const min_rows: u16 = 5;
pub const constrained_cols: u16 = 40;
pub const constrained_rows: u16 = 10;

pub const redaction_failed: []const u8 = "redaction_failed";
pub const redaction_unavailable: []const u8 = "redaction_unavailable";
pub const invalid_utf8: []const u8 = "invalid_utf8";

comptime {
    if (truncation_marker.len != truncation_marker_len) @compileError("truncation marker length");
    if (card_slots != 128) @compileError("card_slots must be 128");
}
