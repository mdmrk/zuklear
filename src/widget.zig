//! Shared widget primitives, ported from the widget-state helpers in
//! `nuklear_internal.h` / `nuklear.h`. Kept in their own module so both the
//! context and the individual widget modules can use them without an import
//! cycle.

const std = @import("std");

/// Whether a widget slot is visible/interactive (`nk_widget_layout_states`).
pub const LayoutState = enum { invalid, valid, rom, disabled };

/// Button activation timing (`nk_button_behavior`).
pub const ButtonBehavior = enum { default, repeater };

/// Interaction state flags for a widget (`enum nk_widget_states`). Bit
/// positions match Nuklear (`NK_FLAG(1..6)`).
pub const States = packed struct(u32) {
    _bit0: bool = false,
    modified: bool = false,
    inactive: bool = false,
    entered: bool = false,
    hover: bool = false,
    actived: bool = false,
    left: bool = false,
    _pad: u25 = 0,

    /// `NK_WIDGET_STATE_HOVERED` = hover | modified.
    pub const hovered: States = .{ .hover = true, .modified = true };
    /// `NK_WIDGET_STATE_ACTIVE` = actived | modified.
    pub const active: States = .{ .actived = true, .modified = true };

    /// `nk_widget_state_reset`: clear to inactive, preserving the modified bit.
    pub fn reset(s: *States) void {
        if (s.modified) {
            s.* = .{ .inactive = true, .modified = true };
        } else {
            s.* = .{ .inactive = true };
        }
    }
};

test "States reset keeps modified bit" {
    var s = States.hovered;
    s.reset();
    try std.testing.expect(s.inactive);
    try std.testing.expect(s.modified);

    var s2 = States{ .hover = true };
    s2.reset();
    try std.testing.expect(s2.inactive);
    try std.testing.expect(!s2.modified);
}

test "composite state bit values match nuklear" {
    try std.testing.expectEqual(@as(u32, 18), @as(u32, @bitCast(States.hovered))); // hover(16)|modified(2)
    try std.testing.expectEqual(@as(u32, 34), @as(u32, @bitCast(States.active))); // actived(32)|modified(2)
}
