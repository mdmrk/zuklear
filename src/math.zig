//! Geometry primitives and a few numeric helpers, ported from
//! `nuklear_math.c`. Nuklear shipped its own sqrt/sin/cos approximations to
//! avoid depending on libm; the Zig port uses `std.math`, which is both
//! freestanding-friendly and more accurate.

const std = @import("std");

/// Cardinal direction, used by widgets that draw a pointing triangle
/// (combo arrows, tree toggles, scrollbar buttons).
pub const Heading = enum { up, right, down, left };

/// Floating-point 2D vector.
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn initI(x: i32, y: i32) Vec2 {
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn len(a: Vec2) f32 {
        return @sqrt(a.dot(a));
    }
};

/// Integer 2D vector (`nk_vec2i`), backed by `i16` to match Nuklear's layout.
pub const Vec2i = struct {
    x: i16 = 0,
    y: i16 = 0,

    pub fn init(x: i16, y: i16) Vec2i {
        return .{ .x = x, .y = y };
    }
};

/// Floating-point axis-aligned rectangle.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn initI(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
        };
    }

    /// Build a rect from a position and a size (`nk_recta`).
    pub fn fromPosSize(p: Vec2, s: Vec2) Rect {
        return .{ .x = p.x, .y = p.y, .w = s.x, .h = s.y };
    }

    pub fn pos(r: Rect) Vec2 {
        return .{ .x = r.x, .y = r.y };
    }

    pub fn size(r: Rect) Vec2 {
        return .{ .x = r.w, .y = r.h };
    }

    /// Inset on all four sides by `amount` (`nk_shrink_rect`). Width/height are
    /// first clamped so the result never inverts.
    pub fn shrink(r: Rect, amount: f32) Rect {
        const w = @max(r.w, 2 * amount);
        const h = @max(r.h, 2 * amount);
        return .{
            .x = r.x + amount,
            .y = r.y + amount,
            .w = w - 2 * amount,
            .h = h - 2 * amount,
        };
    }

    /// Inset by a per-axis padding (`nk_pad_rect`).
    pub fn pad(r: Rect, p: Vec2) Rect {
        const w = @max(r.w, 2 * p.x);
        const h = @max(r.h, 2 * p.y);
        return .{
            .x = r.x + p.x,
            .y = r.y + p.y,
            .w = w - 2 * p.x,
            .h = h - 2 * p.y,
        };
    }

    /// Intersection of `r` with the box `[x0,x1] x [y0,y1]`, clamped to a
    /// non-negative size (`nk_unify`).
    pub fn unify(r: Rect, x0: f32, y0: f32, x1: f32, y1: f32) Rect {
        const x = @max(r.x, x0);
        const y = @max(r.y, y0);
        return .{
            .x = x,
            .y = y,
            .w = @max(0, @min(r.x + r.w, x1) - x),
            .h = @max(0, @min(r.y + r.h, y1) - y),
        };
    }

    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.x < r.x + r.w and
            p.y >= r.y and p.y < r.y + r.h;
    }

    /// True if the two rectangles overlap (`NK_INTERSECT`).
    pub fn intersects(a: Rect, b: Rect) bool {
        return b.x < a.x + a.w and a.x < b.x + b.w and
            b.y < a.y + a.h and a.y < b.y + b.h;
    }
};

/// Integer rectangle (`nk_recti`).
pub const Recti = struct {
    x: i16 = 0,
    y: i16 = 0,
    w: i16 = 0,
    h: i16 = 0,
};

/// Sentinel "infinite" rect used as the default clip region (`nk_null_rect`).
pub const null_rect: Rect = .{ .x = -8192.0, .y = -8192.0, .w = 16384.0, .h = 16384.0 };

/// Compute the three corner points of a triangle pointing in `direction`,
/// inscribed in `r` after applying padding (`nk_triangle_from_direction`).
pub fn triangleFromDirection(r: Rect, pad_x: f32, pad_y: f32, direction: Heading) [3]Vec2 {
    var box = r;
    box.w = @max(2 * pad_x, box.w) - 2 * pad_x;
    box.h = @max(2 * pad_y, box.h) - 2 * pad_y;
    box.x += pad_x;
    box.y += pad_y;

    const w_half = box.w / 2.0;
    const h_half = box.h / 2.0;

    return switch (direction) {
        .up => .{
            Vec2.init(box.x + w_half, box.y),
            Vec2.init(box.x + box.w, box.y + box.h),
            Vec2.init(box.x, box.y + box.h),
        },
        .right => .{
            Vec2.init(box.x, box.y),
            Vec2.init(box.x + box.w, box.y + h_half),
            Vec2.init(box.x, box.y + box.h),
        },
        .down => .{
            Vec2.init(box.x, box.y),
            Vec2.init(box.x + box.w, box.y),
            Vec2.init(box.x + w_half, box.y + box.h),
        },
        .left => .{
            Vec2.init(box.x, box.y + h_half),
            Vec2.init(box.x + box.w, box.y),
            Vec2.init(box.x + box.w, box.y + box.h),
        },
    };
}

/// Round `v` up to the next power of two (`nk_round_up_pow2`). `0` maps to `0`,
/// matching the upstream bit-twiddle.
pub fn roundUpPow2(v: u32) u32 {
    if (v == 0) return 0;
    return @as(u32, 1) << @intCast(32 - @clz(v - 1));
}

test "Vec2 arithmetic" {
    const a = Vec2.init(1, 2);
    const b = Vec2.init(3, 4);
    try std.testing.expectEqual(Vec2.init(4, 6), a.add(b));
    try std.testing.expectEqual(Vec2.init(-2, -2), a.sub(b));
    try std.testing.expectEqual(Vec2.init(2, 4), a.scale(2));
    try std.testing.expectEqual(@as(f32, 11), a.dot(b));
    try std.testing.expectEqual(@as(f32, 5), Vec2.init(3, 4).len());
}

test "Rect shrink and pad" {
    const r = Rect.init(10, 10, 100, 80);
    try std.testing.expectEqual(Rect.init(15, 15, 90, 70), r.shrink(5));
    try std.testing.expectEqual(Rect.init(12, 13, 96, 74), r.pad(Vec2.init(2, 3)));
    // Degenerate input clamps instead of inverting.
    try std.testing.expectEqual(Rect.init(15, 15, 0, 0), Rect.init(10, 10, 4, 4).shrink(5));
}

test "Rect pos/size/contains" {
    const r = Rect.init(10, 20, 30, 40);
    try std.testing.expectEqual(Vec2.init(10, 20), r.pos());
    try std.testing.expectEqual(Vec2.init(30, 40), r.size());
    try std.testing.expect(r.contains(Vec2.init(15, 25)));
    try std.testing.expect(!r.contains(Vec2.init(40, 25))); // right edge exclusive
}

test "Rect unify intersects and clamps" {
    const r = Rect.init(0, 0, 100, 100);
    try std.testing.expectEqual(Rect.init(20, 20, 30, 30), r.unify(20, 20, 50, 50));
    // Disjoint region clamps to zero size.
    try std.testing.expectEqual(Rect.init(200, 200, 0, 0), r.unify(200, 200, 300, 300));
}

test "triangleFromDirection points" {
    const r = Rect.init(0, 0, 10, 10);
    const up = triangleFromDirection(r, 0, 0, .up);
    try std.testing.expectEqual(Vec2.init(5, 0), up[0]);
    try std.testing.expectEqual(Vec2.init(10, 10), up[1]);
    try std.testing.expectEqual(Vec2.init(0, 10), up[2]);
}

test "roundUpPow2" {
    try std.testing.expectEqual(@as(u32, 0), roundUpPow2(0));
    try std.testing.expectEqual(@as(u32, 1), roundUpPow2(1));
    try std.testing.expectEqual(@as(u32, 8), roundUpPow2(5));
    try std.testing.expectEqual(@as(u32, 8), roundUpPow2(8));
    try std.testing.expectEqual(@as(u32, 1024), roundUpPow2(513));
}
