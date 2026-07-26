//! ContextView port — required context projection gate (D-011).
//!
//! Replaces the loop's direct dependency on a product context implementation
//! with an explicit, borrowed port. The port projects the authoritative
//! transcript into a borrowed provider message view plus an optional compaction
//! fact.
//!
//! `CompactionEvent` and `View` are the **single authoritative definitions** for
//! these types across all packages (D-011 core-context-ownership-001). Product
//! layers (`zag-coding-agent`) alias these types; they do not redefine them.
//!
//! Identity projection is an explicit implementation (`identity`); missing
//! state is not silently normalized to an empty/identity view. The product
//! Session installs a layered view; a low-level host may explicitly install
//! identity.

const std = @import("std");
const message = @import("message.zig");
const transcript_mod = @import("transcript.zig");

pub const ContextViewError = error{
    OutOfMemory,
    InvalidContext,
};

/// Single authoritative compaction fact type (D-011 core-context-ownership-001).
/// Describes the **final returned view**, not an intermediate trim. Product
/// layers construct this; Core and Trace consume it.
pub const CompactionEvent = struct {
    /// Number of non-system body messages omitted from the **final** returned view.
    dropped: usize,
    /// Arena-owned summary text suitable for session meta / session layer / trace.
    /// Always valid UTF-8 and `len <= summary_cap` (product-owned constant).
    summary: []const u8,
};

/// Single authoritative context view type (D-011 core-context-ownership-001).
/// Returned by the `ContextView` port; consumed by the loop and product adapters.
pub const View = struct {
    /// Borrowed / arena-owned messages for the provider call.
    messages: []const message.Message,
    /// Set when history was trimmed for the view (transcript unchanged).
    compaction: ?CompactionEvent = null,
};

pub const ContextViewVTable = struct {
    /// Project the authoritative transcript into a borrowed view.
    /// `scratch` is the per-turn arena allocator; returned slices are borrowed
    /// from it and valid only for the synchronous turn.
    view: *const fn (
        ptr: ?*anyopaque,
        scratch: std.mem.Allocator,
        transcript_items: []const message.Message,
    ) ContextViewError!View,
};

/// Borrowed, required context projection gate.
pub const ContextView = struct {
    ptr: ?*anyopaque = null,
    vtable: *const ContextViewVTable,

    pub fn view(
        self: ContextView,
        scratch: std.mem.Allocator,
        transcript_items: []const message.Message,
    ) ContextViewError!View {
        return self.vtable.view(self.ptr, scratch, transcript_items);
    }

    /// Explicit identity view: passes the transcript through unchanged with
    /// no compaction. A low-level trusted host selects this explicitly.
    pub fn identity() ContextView {
        return .{
            .ptr = null,
            .vtable = &identity_vtable,
        };
    }
};

const identity_vtable: ContextViewVTable = .{
    .view = identityView,
};
fn identityView(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    transcript_items: []const message.Message,
) ContextViewError!View {
    return .{ .messages = transcript_items, .compaction = null };
}

test "identity view passes transcript through unchanged" {
    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const full = [_]message.Message{ .user("hi") };
    const v = try ContextView.identity().view(arena_impl.allocator(), &full);
    try std.testing.expectEqual(@as(usize, 1), v.messages.len);
    try std.testing.expectEqualStrings("hi", v.messages[0].content);
    try std.testing.expect(v.compaction == null);
}