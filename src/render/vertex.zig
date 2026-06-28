//! Vertex/draw-list output (the `nk_convert` equivalent): triangulate a
//! `Command` list into interleaved vertices, indices and draw batches for a
//! hardware renderer (OpenGL/Vulkan/...).
//!
//! Solid geometry samples a white texel (`white_uv`) so a single textured
//! shader handles both shapes and text; batches split only when the scissor
//! clip changes. Text geometry is emitted by an optional hook (the
//! `zuklear_font` atlas provides one) so this module stays pure Zig.

const std = @import("std");
const math = @import("../math.zig");
const color = @import("../color.zig");
const command = @import("../command.zig");
const Handle = @import("../handle.zig").Handle;

const Rect = math.Rect;
const Color = color.Color;
const Command = command.Command;

/// Interleaved vertex: position, texture coords, RGBA color.
pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    col: [4]u8,
};

pub const Index = u32;

/// A batch of triangles sharing one scissor clip and one texture.
pub const DrawCommand = struct {
    elem_count: u32,
    clip: Rect,
    texture: Handle,
};

/// Options for `DrawList.convert`.
pub const ConvertConfig = struct {
    /// UV of a fully-white texel in the bound texture (for solid fills).
    white_uv: [2]f32 = .{ 0, 0 },
    /// Texture bound for solid/text geometry (e.g. the font atlas). Image
    /// commands use their own `Image.handle` instead.
    texture: Handle = .{ .id = 0 },
    /// Segments used to approximate a circle.
    circle_segments: u32 = 22,
    /// Emits glyph quads for a text command (e.g. `zuklear_font.drawListText`).
    text_hook: ?*const fn (*DrawList, command.Text) anyerror!void = null,
};

/// Accumulated geometry. Reset and refill each frame.
pub const DrawList = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(Vertex) = .empty,
    indices: std.ArrayListUnmanaged(Index) = .empty,
    commands: std.ArrayListUnmanaged(DrawCommand) = .empty,
    cfg: ConvertConfig = .{},
    elem_offset: u32 = 0, // indices already assigned to flushed commands

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(dl: *DrawList) void {
        dl.vertices.deinit(dl.allocator);
        dl.indices.deinit(dl.allocator);
        dl.commands.deinit(dl.allocator);
        dl.* = undefined;
    }

    pub fn reset(dl: *DrawList) void {
        dl.vertices.clearRetainingCapacity();
        dl.indices.clearRetainingCapacity();
        dl.commands.clearRetainingCapacity();
        dl.elem_offset = 0;
    }

    fn rgba(c: Color) [4]u8 {
        return .{ c.r, c.g, c.b, c.a };
    }

    fn vertex(dl: *DrawList, x: f32, y: f32, u: f32, v: f32, col: [4]u8) !Index {
        const idx: Index = @intCast(dl.vertices.items.len);
        try dl.vertices.append(dl.allocator, .{ .pos = .{ x, y }, .uv = .{ u, v }, .col = col });
        return idx;
    }

    fn tri(dl: *DrawList, a: Index, b: Index, c: Index) !void {
        try dl.indices.append(dl.allocator, a);
        try dl.indices.append(dl.allocator, b);
        try dl.indices.append(dl.allocator, c);
    }

    /// Append a textured quad (used for text glyphs).
    pub fn quadUV(dl: *DrawList, x0: f32, y0: f32, x1: f32, y1: f32, s0: f32, t0: f32, s1: f32, t1: f32, col: Color) !void {
        const c = rgba(col);
        const ia = try dl.vertex(x0, y0, s0, t0, c);
        const ib = try dl.vertex(x1, y0, s1, t0, c);
        const ic = try dl.vertex(x1, y1, s1, t1, c);
        const id = try dl.vertex(x0, y1, s0, t1, c);
        try dl.tri(ia, ib, ic);
        try dl.tri(ia, ic, id);
    }

    fn solidRect(dl: *DrawList, x: f32, y: f32, w: f32, h: f32, col: Color) !void {
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        try dl.quadUV(x, y, x + w, y + h, u, v, u, v, col);
    }

    fn rectMultiColor(dl: *DrawList, c: command.RectMultiColor) !void {
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const x: f32 = @floatFromInt(c.x);
        const y: f32 = @floatFromInt(c.y);
        const w: f32 = @floatFromInt(c.w);
        const h: f32 = @floatFromInt(c.h);
        const ia = try dl.vertex(x, y, u, v, rgba(c.top));
        const ib = try dl.vertex(x + w, y, u, v, rgba(c.right));
        const ic = try dl.vertex(x + w, y + h, u, v, rgba(c.bottom));
        const id = try dl.vertex(x, y + h, u, v, rgba(c.left));
        try dl.tri(ia, ib, ic);
        try dl.tri(ia, ic, id);
    }

    fn solidTri(dl: *DrawList, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, col: Color) !void {
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const c = rgba(col);
        const ia = try dl.vertex(ax, ay, u, v, c);
        const ib = try dl.vertex(bx, by, u, v, c);
        const ic = try dl.vertex(cx, cy, u, v, c);
        try dl.tri(ia, ib, ic);
    }

    fn line(dl: *DrawList, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, col: Color) !void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (len == 0) return;
        const t = @max(thickness, 1) * 0.5;
        const nx = -dy / len * t;
        const ny = dx / len * t;
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const c = rgba(col);
        const ia = try dl.vertex(x0 + nx, y0 + ny, u, v, c);
        const ib = try dl.vertex(x1 + nx, y1 + ny, u, v, c);
        const ic = try dl.vertex(x1 - nx, y1 - ny, u, v, c);
        const id = try dl.vertex(x0 - nx, y0 - ny, u, v, c);
        try dl.tri(ia, ib, ic);
        try dl.tri(ia, ic, id);
    }

    fn circle(dl: *DrawList, x: f32, y: f32, w: f32, h: f32, col: Color) !void {
        const rx = w / 2;
        const ry = h / 2;
        const cx = x + rx;
        const cy = y + ry;
        const n = dl.cfg.circle_segments;
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const c = rgba(col);
        const center = try dl.vertex(cx, cy, u, v, c);
        var prev: Index = undefined;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
            const vx = cx + @cos(a) * rx;
            const vy = cy + @sin(a) * ry;
            const cur = try dl.vertex(vx, vy, u, v, c);
            if (i > 0) try dl.tri(center, prev, cur);
            prev = cur;
        }
    }

    fn arcFill(dl: *DrawList, cx: f32, cy: f32, radius: f32, a0: f32, a1: f32, col: Color) !void {
        const n = dl.cfg.circle_segments;
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const c = rgba(col);
        const center = try dl.vertex(cx, cy, u, v, c);
        var prev: Index = undefined;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const a = a0 + (a1 - a0) * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
            const cur = try dl.vertex(cx + @cos(a) * radius, cy + @sin(a) * radius, u, v, c);
            if (i > 0) try dl.tri(center, prev, cur);
            prev = cur;
        }
    }

    fn arcStroke(dl: *DrawList, cx: f32, cy: f32, radius: f32, a0: f32, a1: f32, thickness: f32, col: Color) !void {
        const n = dl.cfg.circle_segments;
        var px: f32 = 0;
        var py: f32 = 0;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const a = a0 + (a1 - a0) * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
            const nx = cx + @cos(a) * radius;
            const ny = cy + @sin(a) * radius;
            if (i > 0) try dl.line(px, py, nx, ny, thickness, col);
            px = nx;
            py = ny;
        }
    }

    fn curve(dl: *DrawList, p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32, thickness: f32, col: Color) !void {
        const segs = 24;
        var prev = p0;
        var i: u32 = 1;
        while (i <= segs) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / segs;
            const it = 1 - t;
            const w0 = it * it * it;
            const w1 = 3 * it * it * t;
            const w2 = 3 * it * t * t;
            const w3 = t * t * t;
            const cur = [2]f32{
                w0 * p0[0] + w1 * c0[0] + w2 * c1[0] + w3 * p1[0],
                w0 * p0[1] + w1 * c0[1] + w2 * c1[1] + w3 * p1[1],
            };
            try dl.line(prev[0], prev[1], cur[0], cur[1], thickness, col);
            prev = cur;
        }
    }

    fn polyFill(dl: *DrawList, points: []const math.Vec2i, col: Color) !void {
        if (points.len < 3) return;
        const u = dl.cfg.white_uv[0];
        const v = dl.cfg.white_uv[1];
        const c = rgba(col);
        const origin = try dl.vertex(@floatFromInt(points[0].x), @floatFromInt(points[0].y), u, v, c);
        var i: usize = 1;
        while (i + 1 < points.len) : (i += 1) {
            const ia = try dl.vertex(@floatFromInt(points[i].x), @floatFromInt(points[i].y), u, v, c);
            const ib = try dl.vertex(@floatFromInt(points[i + 1].x), @floatFromInt(points[i + 1].y), u, v, c);
            try dl.tri(origin, ia, ib);
        }
    }

    fn flush(dl: *DrawList, clip: Rect, texture: Handle) !void {
        const total: u32 = @intCast(dl.indices.items.len);
        const count = total - dl.elem_offset;
        if (count == 0) return;
        try dl.commands.append(dl.allocator, .{ .elem_count = count, .clip = clip, .texture = texture });
        dl.elem_offset = total;
    }

    fn imageQuad(dl: *DrawList, c: command.ImageDraw) !void {
        const img = c.img;
        const tw: f32 = @floatFromInt(@max(img.w, 1));
        const th: f32 = @floatFromInt(@max(img.h, 1));
        const s0 = @as(f32, @floatFromInt(img.region[0])) / tw;
        const t0 = @as(f32, @floatFromInt(img.region[1])) / th;
        const s1 = @as(f32, @floatFromInt(img.region[0] + img.region[2])) / tw;
        const t1 = @as(f32, @floatFromInt(img.region[1] + img.region[3])) / th;
        const x: f32 = @floatFromInt(c.x);
        const y: f32 = @floatFromInt(c.y);
        try dl.quadUV(x, y, x + @as(f32, @floatFromInt(c.w)), y + @as(f32, @floatFromInt(c.h)), s0, t0, s1, t1, c.col);
    }

    /// Triangulate a command list into this draw list (`nk_convert`).
    pub fn convert(dl: *DrawList, commands: []const Command, cfg: ConvertConfig) !void {
        dl.cfg = cfg;
        var clip = math.null_rect;
        for (commands) |cmd| {
            switch (cmd) {
                .scissor => |s| {
                    try dl.flush(clip, cfg.texture);
                    clip = Rect.initI(s.x, s.y, s.w, s.h);
                },
                .rect_filled => |c| try dl.solidRect(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), c.color),
                .rect => |c| {
                    const x: f32 = @floatFromInt(c.x);
                    const y: f32 = @floatFromInt(c.y);
                    const w: f32 = @floatFromInt(c.w);
                    const h: f32 = @floatFromInt(c.h);
                    const t: f32 = @floatFromInt(@max(c.line_thickness, 1));
                    try dl.solidRect(x, y, w, t, c.color);
                    try dl.solidRect(x, y + h - t, w, t, c.color);
                    try dl.solidRect(x, y, t, h, c.color);
                    try dl.solidRect(x + w - t, y, t, h, c.color);
                },
                .rect_multi_color => |c| try dl.rectMultiColor(c),
                .line => |c| try dl.line(@floatFromInt(c.begin.x), @floatFromInt(c.begin.y), @floatFromInt(c.end.x), @floatFromInt(c.end.y), @floatFromInt(c.line_thickness), c.color),
                .circle_filled => |c| try dl.circle(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), c.color),
                .circle => |c| try dl.circle(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), c.color),
                .triangle_filled => |c| try dl.solidTri(@floatFromInt(c.a.x), @floatFromInt(c.a.y), @floatFromInt(c.b.x), @floatFromInt(c.b.y), @floatFromInt(c.c.x), @floatFromInt(c.c.y), c.color),
                .triangle => |c| {
                    try dl.line(@floatFromInt(c.a.x), @floatFromInt(c.a.y), @floatFromInt(c.b.x), @floatFromInt(c.b.y), @floatFromInt(c.line_thickness), c.color);
                    try dl.line(@floatFromInt(c.b.x), @floatFromInt(c.b.y), @floatFromInt(c.c.x), @floatFromInt(c.c.y), @floatFromInt(c.line_thickness), c.color);
                    try dl.line(@floatFromInt(c.c.x), @floatFromInt(c.c.y), @floatFromInt(c.a.x), @floatFromInt(c.a.y), @floatFromInt(c.line_thickness), c.color);
                },
                .polygon_filled => |c| try dl.polyFill(c.points, c.color),
                .polygon, .polyline => |c| {
                    var i: usize = 0;
                    while (i + 1 < c.points.len) : (i += 1)
                        try dl.line(@floatFromInt(c.points[i].x), @floatFromInt(c.points[i].y), @floatFromInt(c.points[i + 1].x), @floatFromInt(c.points[i + 1].y), @floatFromInt(c.line_thickness), c.color);
                },
                .text => |c| if (dl.cfg.text_hook) |h| try h(dl, c),
                .image => |c| {
                    try dl.flush(clip, cfg.texture); // close the pending solid/text batch
                    try dl.imageQuad(c);
                    try dl.flush(clip, c.img.handle); // the image gets its own batch + texture
                },
                .arc_filled => |c| try dl.arcFill(@floatFromInt(c.cx), @floatFromInt(c.cy), @floatFromInt(c.r), c.a[0], c.a[1], c.color),
                .arc => |c| try dl.arcStroke(@floatFromInt(c.cx), @floatFromInt(c.cy), @floatFromInt(c.r), c.a[0], c.a[1], @floatFromInt(c.line_thickness), c.color),
                .curve => |c| try dl.curve(
                    .{ @floatFromInt(c.begin.x), @floatFromInt(c.begin.y) },
                    .{ @floatFromInt(c.ctrl[0].x), @floatFromInt(c.ctrl[0].y) },
                    .{ @floatFromInt(c.ctrl[1].x), @floatFromInt(c.ctrl[1].y) },
                    .{ @floatFromInt(c.end.x), @floatFromInt(c.end.y) },
                    @floatFromInt(c.line_thickness),
                    c.color,
                ),
                .custom => {}, // renderer-defined callback; the app dispatches it
            }
        }
        try dl.flush(clip, cfg.texture);
    }
};

// --- tests ---------------------------------------------------------------

test "convert emits a quad per filled rect" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    var cmds = [_]Command{
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.rgb(255, 0, 0) } },
    };
    try dl.convert(&cmds, .{});
    try std.testing.expectEqual(@as(usize, 4), dl.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6), dl.indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), dl.commands.items.len);
    try std.testing.expectEqual(@as(u32, 6), dl.commands.items[0].elem_count);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, dl.vertices.items[0].col);
}

test "image gets its own batch with its texture" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    const image_mod = @import("../image.zig");
    var img = image_mod.Image.fromId(7);
    img.w = 64;
    img.h = 64;
    img.region = .{ 0, 0, 32, 32 };
    var cmds = [_]Command{
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.rgb(1, 2, 3) } },
        .{ .image = .{ .x = 0, .y = 0, .w = 32, .h = 32, .img = img, .col = Color.white } },
    };
    try dl.convert(&cmds, .{ .texture = .{ .id = 1 } });
    // two batches: the solid (texture 1) and the image (texture 7)
    try std.testing.expectEqual(@as(usize, 2), dl.commands.items.len);
    try std.testing.expectEqual(@as(i32, 1), dl.commands.items[0].texture.id);
    try std.testing.expectEqual(@as(i32, 7), dl.commands.items[1].texture.id);
}

test "scissor splits into separate draw commands" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    var cmds = [_]Command{
        .{ .scissor = .{ .x = 0, .y = 0, .w = 50, .h = 50 } },
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 5, .h = 5, .color = Color.rgb(1, 2, 3) } },
        .{ .scissor = .{ .x = 0, .y = 0, .w = 20, .h = 20 } },
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 5, .h = 5, .color = Color.rgb(1, 2, 3) } },
    };
    try dl.convert(&cmds, .{});
    try std.testing.expectEqual(@as(usize, 2), dl.commands.items.len);
    try std.testing.expectEqual(Rect.init(0, 0, 50, 50), dl.commands.items[0].clip);
    try std.testing.expectEqual(Rect.init(0, 0, 20, 20), dl.commands.items[1].clip);
}
