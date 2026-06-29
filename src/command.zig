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
const font = @import("font.zig");
const image = @import("image.zig");
const Handle = @import("handle.zig").Handle;

const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Rect = math.Rect;
const Color = color.Color;
const UserFont = font.UserFont;
const Image = image.Image;
const NineSlice = image.NineSlice;

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
/// Text run; `string` is owned by the buffer and already clamped to `w`.
pub const Text = struct {
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    height: f32,
    background: Color,
    foreground: Color,
    font: *const UserFont,
    string: []const u8,
};
pub const ImageDraw = struct { x: i16, y: i16, w: u16, h: u16, img: Image, col: Color };
/// Renderer-defined draw callback (`nk_command_custom`).
pub const CustomCallback = *const fn (canvas: ?*anyopaque, x: i16, y: i16, w: u16, h: u16, data: Handle) void;
pub const Custom = struct { x: i16, y: i16, w: u16, h: u16, callback_data: Handle, callback: CustomCallback };

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
    text: Text,
    image: ImageDraw,
    custom: Custom,
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
            .text => |t| b.allocator.free(t.string),
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

    fn rectClippedOut(b: *const CommandBuffer, r: Rect) bool {
        return b.use_clipping and (b.clip.w == 0 or b.clip.h == 0 or !b.clip.intersects(r));
    }

    /// Draw `string` clipped/clamped to `r` using `f` (`nk_draw_text`). The
    /// text is measured and truncated to fit `r.w`; the stored copy is owned by
    /// the buffer.
    pub fn drawText(b: *CommandBuffer, r: Rect, string: []const u8, f: *const UserFont, bg: Color, fg: Color) !void {
        if (string.len == 0 or (bg.a == 0 and fg.a == 0)) return;
        if (b.rectClippedOut(r)) return;

        var text = string;
        if (f.textWidth(text) > r.w) {
            const c = font.textClamp(f, text, r.w, &.{});
            text = text[0..c.len];
        }
        if (text.len == 0) return;

        const owned = try b.allocator.dupe(u8, text);
        errdefer b.allocator.free(owned);
        try b.push(.{ .text = .{
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .height = f.height,
            .background = bg,
            .foreground = fg,
            .font = f,
            .string = owned,
        } });
    }

    /// Draw an image into `r` tinted by `col` (`nk_draw_image`).
    pub fn drawImage(b: *CommandBuffer, r: Rect, img: Image, col: Color) !void {
        if (b.rectClippedOut(r)) return;
        try b.push(.{ .image = .{
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .img = img,
            .col = col,
        } });
    }

    /// Draw a nine-slice image stretched over `r` (`nk_draw_nine_slice`): the
    /// four corners keep their size, the edges stretch along one axis and the
    /// centre stretches both.
    pub fn drawNineSlice(b: *CommandBuffer, r: Rect, slc: NineSlice, col: Color) !void {
        const rx: f32 = @floatFromInt(slc.img.region[0]);
        const ry: f32 = @floatFromInt(slc.img.region[1]);
        const rw: f32 = @floatFromInt(slc.img.region[2]);
        const rh: f32 = @floatFromInt(slc.img.region[3]);
        const l: f32 = @floatFromInt(slc.l);
        const t: f32 = @floatFromInt(slc.t);
        const rr: f32 = @floatFromInt(slc.r);
        const bb: f32 = @floatFromInt(slc.b);

        // Build a sub-image of the source texture for one slice and draw it.
        const Local = struct {
            fn part(buf: *CommandBuffer, base: Image, sx: f32, sy: f32, sw: f32, sh: f32, dst: Rect, c: Color) !void {
                var img = base;
                img.region = .{ toUShort(sx), toUShort(sy), toUShort(sw), toUShort(sh) };
                try buf.drawImage(dst, img, c);
            }
        };

        // rows: top (t), middle (rh-t-b), bottom (b); cols: left (l), mid, right (r)
        try Local.part(b, slc.img, rx, ry, l, t, .init(r.x, r.y, l, t), col);
        try Local.part(b, slc.img, rx + l, ry, rw - l - rr, t, .init(r.x + l, r.y, r.w - l - rr, t), col);
        try Local.part(b, slc.img, rx + rw - rr, ry, rr, t, .init(r.x + r.w - rr, r.y, rr, t), col);

        try Local.part(b, slc.img, rx, ry + t, l, rh - t - bb, .init(r.x, r.y + t, l, r.h - t - bb), col);
        try Local.part(b, slc.img, rx + l, ry + t, rw - l - rr, rh - t - bb, .init(r.x + l, r.y + t, r.w - l - rr, r.h - t - bb), col);
        try Local.part(b, slc.img, rx + rw - rr, ry + t, rr, rh - t - bb, .init(r.x + r.w - rr, r.y + t, rr, r.h - t - bb), col);

        try Local.part(b, slc.img, rx, ry + rh - bb, l, bb, .init(r.x, r.y + r.h - bb, l, bb), col);
        try Local.part(b, slc.img, rx + l, ry + rh - bb, rw - l - rr, bb, .init(r.x + l, r.y + r.h - bb, r.w - l - rr, bb), col);
        try Local.part(b, slc.img, rx + rw - rr, ry + rh - bb, rr, bb, .init(r.x + r.w - rr, r.y + r.h - bb, rr, bb), col);
    }

    /// Record a renderer-defined custom draw callback (`nk_push_custom`).
    pub fn pushCustom(b: *CommandBuffer, r: Rect, callback: CustomCallback, data: Handle) !void {
        if (b.rectClippedOut(r)) return;
        try b.push(.{ .custom = .{
            .x = toShort(r.x),
            .y = toShort(r.y),
            .w = toUShort(r.w),
            .h = toUShort(r.h),
            .callback_data = data,
            .callback = callback,
        } });
    }
};

test "records a filled rect with quantized geometry" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    try b.fillRect(.init(10.7, 20.2, 100, 50), 4, .rgb(255, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), b.items().len);
    const c = b.items()[0].rect_filled;
    try std.testing.expectEqual(@as(i16, 10), c.x);
    try std.testing.expectEqual(@as(i16, 20), c.y);
    try std.testing.expectEqual(@as(u16, 100), c.w);
    try std.testing.expectEqual(@as(u16, 4), c.rounding);
}

test "transparent and degenerate shapes are dropped" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    try b.fillRect(.init(0, 0, 100, 50), 0, .{ .r = 1, .g = 2, .b = 3, .a = 0 });
    try b.fillRect(.init(0, 0, 0, 50), 0, .rgb(1, 2, 3));
    try b.strokeLine(0, 0, 10, 10, 0, .rgb(1, 2, 3)); // zero thickness
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}

test "clipping drops out-of-bounds shapes" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    try b.pushScissor(.init(0, 0, 50, 50));
    try b.fillRect(.init(100, 100, 10, 10), 0, .rgb(1, 2, 3)); // outside clip
    try b.fillRect(.init(10, 10, 10, 10), 0, .rgb(1, 2, 3)); // inside clip
    // scissor + the one inside rect.
    try std.testing.expectEqual(@as(usize, 2), b.items().len);
    try std.testing.expect(b.items()[0] == .scissor);
}

fn testWidth(_: Handle, _: f32, text: []const u8) f32 {
    return @as(f32, @floatFromInt(text.len)) * 10.0;
}

test "drawText clamps to width and owns its copy" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    const f: UserFont = .{ .height = 12, .width = &testWidth };
    // "hello" is 50px; a 25px-wide rect keeps a 3-char prefix.
    try b.drawText(.init(0, 0, 25, 14), "hello", &f, .{}, .rgb(255, 255, 255));
    const t = b.items()[0].text;
    try std.testing.expectEqualStrings("hel", t.string);
    try std.testing.expectEqual(@as(f32, 12), t.height);
}

test "drawText with fully transparent colors is dropped" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    const f: UserFont = .{ .height = 12, .width = &testWidth };
    const transparent: Color = .{ .a = 0 };
    try b.drawText(.init(0, 0, 100, 14), "hi", &f, transparent, transparent);
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}

test "drawImage records tinted image" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    try b.drawImage(.init(1, 2, 3, 4), .fromId(9), .rgb(10, 20, 30));
    const c = b.items()[0].image;
    try std.testing.expectEqual(@as(i32, 9), c.img.handle.id);
    try std.testing.expectEqual(@as(u16, 3), c.w);
}

test "polygon owns its points and reset frees them" {
    var b: CommandBuffer = .init(std.testing.allocator);
    defer b.deinit();
    const pts = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 8 } };
    try b.fillPolygon(&pts, .rgb(1, 2, 3));
    try std.testing.expectEqual(@as(usize, 3), b.items()[0].polygon_filled.points.len);
    b.reset(); // frees the points slice; no leak under testing.allocator
    try std.testing.expectEqual(@as(usize, 0), b.items().len);
}
