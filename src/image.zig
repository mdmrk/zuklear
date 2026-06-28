//! Image and nine-slice types, ported from the BASIC section of `nuklear.h`.
//! (The `nuklear_image.c` constructors/sub-image helpers land in the widget
//! phase; this module currently provides the types and basic constructors the
//! draw layer needs.)

const std = @import("std");
const Handle = @import("handle.zig").Handle;

/// A (sub)image referencing a user texture (`nk_image`). `region` is the
/// sub-rectangle `[x, y, w, h]` inside the texture.
pub const Image = struct {
    handle: Handle,
    w: u16 = 0,
    h: u16 = 0,
    region: [4]u16 = .{ 0, 0, 0, 0 },

    pub fn fromId(id: i32) Image {
        return .{ .handle = Handle.fromId(id) };
    }

    pub fn fromPtr(ptr: ?*anyopaque) Image {
        return .{ .handle = Handle.fromPtr(ptr) };
    }
};

/// A nine-slice scalable image: the border insets `l`/`t`/`r`/`b` stay fixed
/// while the centre stretches (`nk_nine_slice`).
pub const NineSlice = struct {
    img: Image,
    l: u16 = 0,
    t: u16 = 0,
    r: u16 = 0,
    b: u16 = 0,
};

test "image constructors set the handle" {
    try std.testing.expectEqual(@as(i32, 7), Image.fromId(7).handle.id);
}
