//! The draw command buffer, ported from `nuklear_draw.c`.
//!
//! Nuklear records draw commands as variable-length packed structs inside a
//! single byte `Buffer`, linked by `next` offsets and iterated with manual
//! pointer casts. The idiomatic port represents each command as a value in a
//! `Command` `union(enum)` and stores them in an `ArrayList`. Variable-length
//! payloads (polygon points) are owned slices freed on `reset`.
//!
//! Coordinates are quantized to `i16`/`u16` exactly as Nuklear does, so a
//! renderer consuming the commands sees identical pixel geometry. Geometric
//! primitives live here; text/image/custom commands arrive with the font
//! interface.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");

const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Rect = math.Rect;
const Color = color.Color;

/// `(short)v`: truncate toward zero, clamped to the `i16` range.
fn toShort(v: f32) i16 {
    return @intFromFloat(std.math.clamp(@trunc(v), -32768.0, 32767.0));
}

/// `(unsigned short)NK_MAX(0, v)`: truncate, clamped to the `u16` range.
fn toUShort(v: f32) u16 {
    return @intFromFloat(std.math.clamp(@trunc(v), 0.0, 65535.0));
}

pub const Scissor = struct { x: i16, y: i16, w: u16, h: u16 };
pub const Line = struct { line_thickness: u16, begin: Vec2i, end: Vec2i, color: Color };
pub const Curve = struct { line_thickness: u16, begin: Vec2i, end: Vec2i, ctrl: [2]Vec2i, color: Color };
pub const StrokeRect = struct { rounding: u16, line_thickness: u16, x: i16, y: i16, w: u16, h: u16, color: Color };
pub const FillRect = struct { rounding: u16, x: i16, y: i16, w: u16, h: u16, color: Color };
pub const RectMultiColor = struct { x: i16, y: i16, w: u16, h: u16, left: Color, top: Color, bottom: Color, right: Color };
pub const StrokeCircle = struct { x: i16, y: i16, line_thickness: u16, w: u16, h: u16, color: Color };
pub const FillCircle = struct { x: i16, y: i16, w: u16, h: u16, color: Color };
pub const StrokeArc = struct { cx: i16, cy: i16, r: u16, line_thickness: u16, a: [2]f32, color: Color };
pub const FillArc = struct { cx: i16, cy: i16, r: u16, a: [2]f32, color: Color };
pub const StrokeTriangle = struct { line_thickness: u16, a: Vec2i, b: Vec2i, c: Vec2i, color: Color };
pub const FillTriangle = struct { a: Vec2i, b: Vec2i, c: Vec2i, color: Color };
/// Stroked polygon or polyline (`points` owned by the buffer).
pub const PolyStroke = struct { color: Color, line_thickness: u16, points: []const Vec2i };
/// Filled polygon (`points` owned by the buffer).
pub const PolyFill = struct { color: Color, points: []const Vec2i };

/// One draw command (`nk_command` and its subtypes, minus the byte header).
pub const Command = union(enum) {
    scissor: Scissor,
    line: Line,
    curve: Curve,
    rect: StrokeRect,
    rect_filled: FillRect,
    rect_multi_color: RectMultiColor,
    circle: StrokeCircle,
    circle_filled: FillCircle,
    arc: StrokeArc,
    arc_filled: FillArc,
    triangle: StrokeTriangle,
    triangle_filled: FillTriangle,
    polygon: PolyStroke,
    polygon_filled: PolyFill,
    polyline: PolyStroke,
};

/// Records draw commands for later consumption by a renderer
/// (`nk_command_buffer`).
pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(Command) = .empty,
    /// Current clip rectangle; primitives outside it are dropped when
    /// `use_clipping` is set.
    clip: Rect = math.null_rect,
    use_clipping: bool = true,

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(b: *CommandBuffer) void {
        b.freePayloads();
        b.commands.deinit(b.allocator);
        b.* = undefined;
    }

    fn freePayloads(b: *CommandBuffer) void {
        for (b.commands.items) |cmd| switch (cmd) {
            .polygon, .polyline => |p| b.allocator.free(p.points),
            .polygon_filled => |p| b.allocator.free(p.points),
            else => {},
        };
    }

    /// Drop all recorded commands and reset the clip (`nk_command_buffer_reset`).
    pub fn reset(b: *CommandBuffer) void {
        b.freePayloads();
        b.commands.clearRetainingCapacity();
        b.clip = math.null_rect;
    }

    /// The recorded commands, in submission order.
    pub fn items(b: *const CommandBuffer) []const Command {
        return b.commands.items;
    }

    fn push(b: *CommandBuffer, cmd: Command) !void {
        try b.commands.append(b.allocator, cmd);
    }

    fn dupePoints(b: *CommandBuffer, points: []const Vec2) ![]Vec2i {
        const out = try b.allocator.alloc(Vec2i, points.len);
        for (points, out) |p, *o| o.* = .{ .x = toShort(p.x), .y = toShort(p.y) };
        return out;
    }

    fn clippedOut(b: *const CommandBuffer, r: Rect) bool {
        return b.use_clipping and !b.clip.intersects(r);
    }

    /// Set the clip rectangle and record it (`nk_push_scissor`).
    pub fn pushScissor(b: *CommandBuffer, r: Rect) !void {
        b.clip = r;
        try b.push(.{ .scissor = .{ .x = toShort(r.x), .y = toShort(r.y), .w = toUShort(r.w), .h = toUShort(r.h) } });
    }

    pub fn strokeLine(b: *CommandBuffer, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, c: Color) !void {
        if (thickness <= 0) return;
        try b.push(.{ .line = .{
            .line_thickness = toUShort(thickness),
            .begin = .{ .x = toShort(x0), .y = toShort(y0) },
            .end = .{ .x = toShort(x1), .y = toShort(y1) },
            .color = c,
        } });
    }

    pub fn strokeCurve(b: *CommandBuffer, ax: f32, ay: f32, c0x: f32, c0y: f32, c1x: f32, c1y: f32, bx: f32, by: f32, thickness: f32, c: Color) !void {
        if (c.a == 0 or thickness <= 0) return;
        try b.push(.{ .curve = .{
            .line_thickness = toUShort(thickness),
            .begin = .{ .x = toShort(ax), .y = toShort(ay) },
            .ctrl = .{ .{ .x = toShort(c0x), .y = toShort(c0y) }, .{ .x = toShort(c1x), .y = toShort(c1y) } },
            .end = .{ .x = toShort(bx), .y = toShort(by) },
            .color = c,
        } });
    }

    pub fn strokeRect(b: *CommandBuffer, r: Rect, rounding: f32, thickness: f32, c: Color) !void {
        if (c.a == 0 or r.w == 0 or r.h == 0 or thickness <= 0) return;
        if (b.clippedOut(r)) return;
        try b.push(.{ .rect = .{
            .rounding = toUShort(rounding),
            .line_thickness = toUShort(thickness),
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .color = c,
        } });
    }

    pub fn fillRect(b: *CommandBuffer, r: Rect, rounding: f32, c: Color) !void {
        if (c.a == 0 or r.w == 0 or r.h == 0) return;
        if (b.clippedOut(r)) return;
        try b.push(.{ .rect_filled = .{
            .rounding = toUShort(rounding),
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .color = c,
        } });
    }

    pub fn fillRectMultiColor(b: *CommandBuffer, r: Rect, left: Color, top: Color, right: Color, bottom: Color) !void {
        if (r.w == 0 or r.h == 0) return;
        if (b.clippedOut(r)) return;
        try b.push(.{ .rect_multi_color = .{
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .left = left,
            .top = top,
            .right = right,
            .bottom = bottom,
        } });
    }

    pub fn strokeCircle(b: *CommandBuffer, r: Rect, thickness: f32, c: Color) !void {
        if (r.w == 0 or r.h == 0 or thickness <= 0) return;
        if (b.clippedOut(r)) return;
        try b.push(.{ .circle = .{
            .line_thickness = toUShort(thickness),
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .color = c,
        } });
    }

    pub fn fillCircle(b: *CommandBuffer, r: Rect, c: Color) !void {
        if (c.a == 0 or r.w == 0 or r.h == 0) return;
        if (b.clippedOut(r)) return;
        try b.push(.{ .circle_filled = .{
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .color = c,
        } });
    }

    pub fn strokeArc(b: *CommandBuffer, cx: f32, cy: f32, radius: f32, a_min: f32, a_max: f32, thickness: f32, c: Color) !void {
        if (c.a == 0 or thickness <= 0) return;
        try b.push(.{ .arc = .{
            .line_thickness = toUShort(thickness),
            .cx = toShort(cx),
            .cy = toShort(cy),
            .r = toUShort(radius),
            .a = .{ a_min, a_max },
            .color = c,
        } });
    }

    pub fn fillArc(b: *CommandBuffer, cx: f32, cy: f32, radius: f32, a_min: f32, a_max: f32, c: Color) !void {
        if (c.a == 0) return;
        try b.push(.{ .arc_filled = .{
            .cx = toShort(cx),
            .cy = toShort(cy),
            .r = toUShort(radius),
            .a = .{ a_min, a_max },
            .color = c,
        } });
    }

    /// True if none of the three points fall inside the clip box (the triangle
    /// clipping test Nuklear uses).
    fn triangleClippedOut(b: *const CommandBuffer, p0: Vec2, p1: Vec2, p2: Vec2) bool {
        return b.use_clipping and
            !b.clip.contains(p0) and !b.clip.contains(p1) and !b.clip.contains(p2);
    }

    pub fn strokeTriangle(b: *CommandBuffer, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, c: Color) !void {
        if (c.a == 0 or thickness <= 0) return;
        if (b.triangleClippedOut(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 })) return;
        try b.push(.{ .triangle = .{
            .line_thickness = toUShort(thickness),
            .a = .{ .x = toShort(x0), .y = toShort(y0) },
            .b = .{ .x = toShort(x1), .y = toShort(y1) },
            .c = .{ .x = toShort(x2), .y = toShort(y2) },
            .color = c,
        } });
    }

    pub fn fillTriangle(b: *CommandBuffer, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, c: Color) !void {
        if (c.a == 0) return;
        if (b.triangleClippedOut(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 })) return;
        try b.push(.{ .triangle_filled = .{
            .a = .{ .x = toShort(x0), .y = toShort(y0) },
            .b = .{ .x = toShort(x1), .y = toShort(y1) },
            .c = .{ .x = toShort(x2), .y = toShort(y2) },
            .color = c,
        } });
    }

    pub fn strokePolygon(b: *CommandBuffer, points: []const Vec2, thickness: f32, c: Color) !void {
        if (c.a == 0 or thickness <= 0) return;
        const pts = try b.dupePoints(points);
        errdefer b.allocator.free(pts);
        try b.push(.{ .polygon = .{ .color = c, .line_thickness = toUShort(thickness), .points = pts } });
    }

    pub fn fillPolygon(b: *CommandBuffer, points: []const Vec2, c: Color) !void {
        if (c.a == 0) return;
        const pts = try b.dupePoints(points);
        errdefer b.allocator.free(pts);
        try b.push(.{ .polygon_filled = .{ .color = c, .points = pts } });
    }

    pub fn strokePolyline(b: *CommandBuffer, points: []const Vec2, thickness: f32, c: Color) !void {
        if (c.a == 0 or thickness <= 0) return;
        const pts = try b.dupePoints(points);
        errdefer b.allocator.free(pts);
        try b.push(.{ .polyline = .{ .color = c, .line_thickness = toUShort(thickness), .points = pts } });
    }
};

test "records a filled rect with quantized geometry" {
    var b = CommandBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.fillRect(Rect.init(10.7, 20.2, 100, 50), 4, Color.rgb(255, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), b.items().len);
    const c = b.items()[0].rect_filled;
    try std.testing.expectEqual(@as(i16, 10), c.x);
    try std.testing.expectEqual(@as(i16, 20), c.y);
    try std.testing.expectEqual(@as(u16, 100), c.w);
    try std.testing.expectEqual(@as(u16, 4), c.rounding);
}

test "transparent and degenerate shapes are dropped" {
    var b = CommandBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.fillRect(Rect.init(0, 0, 100, 50), 0, Color{ .r = 1, .g = 2, .b = 3, .a = 0 });
    try b.fillRect(Rect.init(0, 0, 0, 50), 0, Color.rgb(1, 2, 3));
    try b.strokeLine(0, 0, 10, 10, 0, Color.rgb(1, 2, 3)); // zero thickness
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}

test "clipping drops out-of-bounds shapes" {
    var b = CommandBuffer.init(std.testing.allocator);
    defer b.deinit();
    try b.pushScissor(Rect.init(0, 0, 50, 50));
    try b.fillRect(Rect.init(100, 100, 10, 10), 0, Color.rgb(1, 2, 3)); // outside clip
    try b.fillRect(Rect.init(10, 10, 10, 10), 0, Color.rgb(1, 2, 3)); // inside clip
    // scissor + the one inside rect.
    try std.testing.expectEqual(@as(usize, 2), b.items().len);
    try std.testing.expect(b.items()[0] == .scissor);
}

test "polygon owns its points and reset frees them" {
    var b = CommandBuffer.init(std.testing.allocator);
    defer b.deinit();
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 8 } };
    try b.fillPolygon(&pts, Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 3), b.items()[0].polygon_filled.points.len);
    b.reset(); // frees the points slice; no leak under testing.allocator
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}
