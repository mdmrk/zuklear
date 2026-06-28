//! `nk_handle`: an opaque user reference passed through the library — either a
//! pointer or an integer id (e.g. a texture name). Ported from the BASIC
//! section of `nuklear.h`.

const std = @import("std");

pub const Handle = extern union {
    ptr: ?*anyopaque,
    id: i32,

    pub fn fromId(id: i32) Handle {
        return .{ .id = id };
    }

    pub fn fromPtr(ptr: ?*anyopaque) Handle {
        return .{ .ptr = ptr };
    }
};

test "handle stores id or pointer" {
    try std.testing.expectEqual(@as(i32, 42), Handle.fromId(42).id);
    var x: u32 = 0;
    try std.testing.expectEqual(@as(?*anyopaque, &x), Handle.fromPtr(&x).ptr);
}
