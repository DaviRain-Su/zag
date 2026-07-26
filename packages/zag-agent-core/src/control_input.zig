//! Explicit borrowed ControlInput seam (harness-steering-001).
//!
//! Core polls only at protocol-safe boundaries and commits only after the
//! authoritative Transcript owns the accepted user row. Product queues, mutexes,
//! capacity, retention, and persistence remain outside Core (D-011).
//!
//! Low-level hosts must write `.control_input = .none()` when no control source
//! exists. There is no hidden missing-to-none fallback on `loop.Deps`.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    steering,
    follow_up,
};

pub const Boundary = enum {
    pre_turn,
    between_tools,
    would_complete,
};

pub const Item = struct {
    kind: Kind,
    text: []const u8,
};

pub const ControlInputVTable = struct {
    /// Non-destructive atomic selection under the product lock.
    /// `pre_turn` / `between_tools` may return only steering.
    /// `would_complete` returns steering first, otherwise follow-up.
    peek: *const fn (ptr: ?*anyopaque, boundary: Boundary) ?Item,
    /// Infallible removal of the current head of `kind` after a matching peek.
    /// Wrong-kind / no-peek commit is a programming error (Debug assert in product).
    commit: *const fn (ptr: ?*anyopaque, kind: Kind) void,
};

/// Borrowed control source. Required composition field of `loop.Deps`.
pub const ControlInput = struct {
    ptr: ?*anyopaque = null,
    vtable: *const ControlInputVTable,

    pub fn peek(self: ControlInput, boundary: Boundary) ?Item {
        return self.vtable.peek(self.ptr, boundary);
    }

    pub fn commit(self: ControlInput, kind: Kind) void {
        self.vtable.commit(self.ptr, kind);
    }

    /// Explicit empty control source. Low-level hosts select this; product
    /// `Agent.reply` always installs a Session-bound adapter instead.
    pub fn none() ControlInput {
        return .{
            .ptr = null,
            .vtable = &none_vtable,
        };
    }
};

const none_vtable: ControlInputVTable = .{
    .peek = nonePeek,
    .commit = noneCommit,
};

fn nonePeek(_: ?*anyopaque, _: Boundary) ?Item {
    return null;
}

fn noneCommit(_: ?*anyopaque, _: Kind) void {
    if (builtin.mode == .Debug) {
        // Matching peeks never return items under `.none()`; a commit is a bug.
        std.debug.assert(false);
    }
}

test "ControlInput.none never yields items" {
    const c = ControlInput.none();
    try std.testing.expect(c.peek(.pre_turn) == null);
    try std.testing.expect(c.peek(.between_tools) == null);
    try std.testing.expect(c.peek(.would_complete) == null);
}
