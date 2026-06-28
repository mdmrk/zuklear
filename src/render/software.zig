//! A small software rasterizer that turns a zuklear `Command` list into pixels.
//!
//! It is renderer-agnostic: it writes 24-bit `0xRRGGBB` pixels into a
//! caller-provided `Surface`. A backend (e.g. the wio example) then blits the
//! surface to the screen. Text uses the built-in bitmap font.
//!
//! Geometry is intentionally simple (square corners, point-sampled): it targets
//! the default theme (filled/stroked rects, lines, triangles, circles,
//! gradients and text), which is enough to drive a real UI.

const std = @import("std");
const math = @import("../math.zig");
const color = @import("../color.zig");
const command = @import("../command.zig");
const builtin_font = @import("../font/builtin.zig");

const Rect = math.Rect;
const Vec2i = math.Vec2i;
const Color = color.Color;
const Command = command.Command;

/// A 24-bit RGB pixel surface (`pixels[y*width + x]` = `0xRRGGBB`).
pub const Surface = struct {
    pixels: []u32,
    width: usize,
    height: usize,

    pub fn clear(s: *Surface, c: Color) void {
        @memset(s.pixels, pack(c));
    }
};

fn pack(c: Color) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

fn blend(dst: u32, c: Color) u32 {
    if (c.a == 0) return dst;
    if (c.a == 255) return pack(c);
    const a: u32 = c.a;
    const ia: u32 = 255 - a;
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const r = (@as(u32, c.r) * a + dr * ia) / 255;
    const g = (@as(u32, c.g) * a + dg * ia) / 255;
    const b = (@as(u32, c.b) * a + db * ia) / 255;
    return (r << 16) | (g << 8) | b;
}

/// Rasterizes commands into a surface, tracking the current scissor clip.
pub const Rasterizer = struct {
    surface: *Surface,
    // clip bounds in pixels, [x0,x1) x [y0,y1)
    cx0: i32 = 0,
    cy0: i32 = 0,
    cx1: i32,
    cy1: i32,

    pub fn init(surface: *Surface) Rasterizer {
        return .{ .surface = surface, .cx1 = @intCast(surface.width), .cy1 = @intCast(surface.height) };
    }

    fn put(r: *Rasterizer, x: i32, y: i32, c: Color) void {
        if (x < r.cx0 or x >= r.cx1 or y < r.cy0 or y >= r.cy1) return;
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(r.surface.width)) or y >= @as(i32, @intCast(r.surface.height))) return;
        const idx = @as(usize, @intCast(y)) * r.surface.width + @as(usize, @intCast(x));
        r.surface.pixels[idx] = blend(r.surface.pixels[idx], c);
    }

    fn setScissor(r: *Rasterizer, rect: command.Scissor) void {
        r.cx0 = rect.x;
        r.cy0 = rect.y;
        r.cx1 = @as(i32, rect.x) + rect.w;
        r.cy1 = @as(i32, rect.y) + rect.h;
    }

    fn fillRectPx(r: *Rasterizer, x: i32, y: i32, w: i32, h: i32, c: Color) void {
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) r.put(xx, yy, c);
        }
    }

    fn fillCmdRect(r: *Rasterizer, cmd: command.FillRect) void {
        r.fillRectPx(cmd.x, cmd.y, cmd.w, cmd.h, cmd.color);
    }

    fn strokeRect(r: *Rasterizer, x: i32, y: i32, w: i32, h: i32, t: i32, c: Color) void {
        const th = @max(t, 1);
        r.fillRectPx(x, y, w, th, c); // top
        r.fillRectPx(x, y + h - th, w, th, c); // bottom
        r.fillRectPx(x, y, th, h, c); // left
        r.fillRectPx(x + w - th, y, th, h, c); // right
    }

    fn line(r: *Rasterizer, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, c: Color) void {
        // Bresenham, plotting a `thickness` square at each step.
        const t = @max(thickness, 1);
        const half = @divTrunc(t, 2);
        var x = x0;
        var y = y0;
        const dx = @as(i32, @intCast(@abs(x1 - x0)));
        const dy = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            r.fillRectPx(x - half, y - half, t, t, c);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    fn fillTriangle(r: *Rasterizer, a: Vec2i, b: Vec2i, cc: Vec2i, col: Color) void {
        const minx = @min(a.x, @min(b.x, cc.x));
        const maxx = @max(a.x, @max(b.x, cc.x));
        const miny = @min(a.y, @min(b.y, cc.y));
        const maxy = @max(a.y, @max(b.y, cc.y));
        const area = edge(a, b, cc);
        if (area == 0) return;
        var y: i32 = miny;
        while (y <= maxy) : (y += 1) {
            var x: i32 = minx;
            while (x <= maxx) : (x += 1) {
                const p = Vec2i{ .x = @intCast(x), .y = @intCast(y) };
                const w0 = edge(b, cc, p);
                const w1 = edge(cc, a, p);
                const w2 = edge(a, b, p);
                // inside if all same sign as the triangle's winding
                if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0))
                    r.put(x, y, col);
            }
        }
    }

    fn edge(a: Vec2i, b: Vec2i, p: Vec2i) i32 {
        return (@as(i32, b.x) - a.x) * (@as(i32, p.y) - a.y) - (@as(i32, b.y) - a.y) * (@as(i32, p.x) - a.x);
    }

    fn fillCircle(r: *Rasterizer, x: i32, y: i32, w: i32, h: i32, c: Color) void {
        if (w <= 0 or h <= 0) return;
        const rx = @as(f32, @floatFromInt(w)) / 2.0;
        const ry = @as(f32, @floatFromInt(h)) / 2.0;
        const cx = @as(f32, @floatFromInt(x)) + rx;
        const cy = @as(f32, @floatFromInt(y)) + ry;
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) {
                const dx = (@as(f32, @floatFromInt(xx)) + 0.5 - cx) / rx;
                const dy = (@as(f32, @floatFromInt(yy)) + 0.5 - cy) / ry;
                if (dx * dx + dy * dy <= 1.0) r.put(xx, yy, c);
            }
        }
    }

    fn rectMultiColor(r: *Rasterizer, cmd: command.RectMultiColor) void {
        // bilinear interpolation of the four corner colors
        if (cmd.w == 0 or cmd.h == 0) return;
        var yy: i32 = 0;
        while (yy < cmd.h) : (yy += 1) {
            const ty = @as(f32, @floatFromInt(yy)) / @as(f32, @floatFromInt(cmd.h));
            var xx: i32 = 0;
            while (xx < cmd.w) : (xx += 1) {
                const tx = @as(f32, @floatFromInt(xx)) / @as(f32, @floatFromInt(cmd.w));
                const top = lerp(cmd.left, cmd.top, tx);
                const bot = lerp(cmd.bottom, cmd.right, tx);
                r.put(cmd.x + xx, cmd.y + yy, lerp(top, bot, ty));
            }
        }
    }

    fn lerp(a: Color, b: Color, t: f32) Color {
        return .{
            .r = lerpByte(a.r, b.r, t),
            .g = lerpByte(a.g, b.g, t),
            .b = lerpByte(a.b, b.b, t),
            .a = lerpByte(a.a, b.a, t),
        };
    }

    fn lerpByte(a: u8, b: u8, t: f32) u8 {
        return @intFromFloat(@as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t);
    }

    fn drawText(r: *Rasterizer, cmd: command.Text) void {
        const scale = builtin_font.scaleFor(cmd.height);
        var pen_x: i32 = cmd.x;
        var it = std.unicode.Utf8Iterator{ .bytes = cmd.string, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            const bmp = builtin_font.glyphBitmap(cp);
            for (bmp, 0..) |bits, row| {
                var col_i: u3 = 0;
                while (true) : (col_i += 1) {
                    if ((bits >> col_i) & 1 != 0) {
                        r.fillRectPx(pen_x + @as(i32, col_i) * scale, cmd.y + @as(i32, @intCast(row)) * scale, scale, scale, cmd.foreground);
                    }
                    if (col_i == 7) break;
                }
            }
            pen_x += builtin_font.advance * scale;
        }
    }

    /// Execute one command.
    pub fn run(r: *Rasterizer, cmd: Command) void {
        switch (cmd) {
            .scissor => |c| r.setScissor(c),
            .rect_filled => |c| r.fillCmdRect(c),
            .rect => |c| r.strokeRect(c.x, c.y, c.w, c.h, c.line_thickness, c.color),
            .rect_multi_color => |c| r.rectMultiColor(c),
            .line => |c| r.line(c.begin.x, c.begin.y, c.end.x, c.end.y, c.line_thickness, c.color),
            .circle_filled => |c| r.fillCircle(c.x, c.y, c.w, c.h, c.color),
            .circle => |c| r.fillCircle(c.x, c.y, c.w, c.h, c.color), // outline approximated as filled
            .triangle_filled => |c| r.fillTriangle(c.a, c.b, c.c, c.color),
            .triangle => |c| {
                r.line(c.a.x, c.a.y, c.b.x, c.b.y, c.line_thickness, c.color);
                r.line(c.b.x, c.b.y, c.c.x, c.c.y, c.line_thickness, c.color);
                r.line(c.c.x, c.c.y, c.a.x, c.a.y, c.line_thickness, c.color);
            },
            .polygon_filled => |c| {
                // fan triangulation
                if (c.points.len >= 3) {
                    var i: usize = 1;
                    while (i + 1 < c.points.len) : (i += 1)
                        r.fillTriangle(c.points[0], c.points[i], c.points[i + 1], c.color);
                }
            },
            .polygon, .polyline => |c| {
                var i: usize = 0;
                while (i + 1 < c.points.len) : (i += 1)
                    r.line(c.points[i].x, c.points[i].y, c.points[i + 1].x, c.points[i + 1].y, c.line_thickness, c.color);
            },
            .text => |c| r.drawText(c),
            .curve, .arc, .arc_filled, .image, .custom => {}, // TODO: curves/arcs/images
        }
    }

    /// Execute a whole command list.
    pub fn renderAll(r: *Rasterizer, commands: []const Command) void {
        for (commands) |cmd| r.run(cmd);
    }
};

test "fills a clipped rectangle" {
    var pixels: [16 * 16]u32 = undefined;
    var surface = Surface{ .pixels = &pixels, .width = 16, .height = 16 };
    surface.clear(Color.black);

    var ras = Rasterizer.init(&surface);
    ras.run(.{ .scissor = .{ .x = 0, .y = 0, .w = 8, .h = 16 } });
    ras.run(.{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 16, .h = 16, .color = Color.rgb(255, 0, 0) } });

    // inside clip -> red; outside clip -> still black
    try std.testing.expectEqual(pack(Color.rgb(255, 0, 0)), pixels[5 * 16 + 4]);
    try std.testing.expectEqual(pack(Color.black), pixels[5 * 16 + 12]);
}

test "alpha blends over the background" {
    var pixels: [4]u32 = undefined;
    var surface = Surface{ .pixels = &pixels, .width = 2, .height = 2 };
    surface.clear(Color.black);
    var ras = Rasterizer.init(&surface);
    ras.run(.{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 2, .h = 2, .color = .{ .r = 255, .g = 255, .b = 255, .a = 128 } } });
    // ~50% white over black -> grey
    const g = pixels[0] & 0xFF;
    try std.testing.expect(g > 100 and g < 160);
}
