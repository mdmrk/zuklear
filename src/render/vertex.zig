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
    /// Segments used to approximate a circle/arc.
    circle_segments: u32 = 22,
    /// Segments used to tessellate a bezier curve.
    curve_segments: u32 = 22,
    /// Anti-alias strokes (lines, outlines, curves) by feathering their edges.
    line_aa: bool = true,
    /// Anti-alias convex fills (circles, triangles, polygons, rects).
    shape_aa: bool = true,
    /// Emits glyph quads for a text command (e.g. `zuklear_font.drawListText`).
    text_hook: ?*const fn (*DrawList, command.Text) anyerror!void = null,
};

/// A 2D point used while building paths and AA fringe geometry.
const V2 = [2]f32;

fn v2add(a: V2, b: V2) V2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}
fn v2sub(a: V2, b: V2) V2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}
fn v2muls(a: V2, s: f32) V2 {
    return .{ a[0] * s, a[1] * s };
}
/// Normalized direction of `b - a` (zero-length segments map to `+x`).
fn v2dir(a: V2, b: V2) V2 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return .{ 1, 0 };
    const inv = 1.0 / @sqrt(len2);
    return .{ dx * inv, dy * inv };
}

/// Accumulated geometry. Reset and refill each frame.
pub const DrawList = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(Vertex) = .empty,
    indices: std.ArrayListUnmanaged(Index) = .empty,
    commands: std.ArrayListUnmanaged(DrawCommand) = .empty,
    path: std.ArrayListUnmanaged(V2) = .empty, // scratch path points
    scratch: std.ArrayListUnmanaged(V2) = .empty, // scratch normals + fringe temps
    cfg: ConvertConfig = .{},
    elem_offset: u32 = 0, // indices already assigned to flushed commands

    pub fn init(allocator: std.mem.Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(dl: *DrawList) void {
        dl.vertices.deinit(dl.allocator);
        dl.indices.deinit(dl.allocator);
        dl.commands.deinit(dl.allocator);
        dl.path.deinit(dl.allocator);
        dl.scratch.deinit(dl.allocator);
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

    // --- path building -----------------------------------------------------
    // Primitives are expressed as a list of points (a "path"), then stroked or
    // filled with optional anti-aliasing, mirroring Nuklear's draw-list model.

    fn pathClear(dl: *DrawList) void {
        dl.path.clearRetainingCapacity();
    }

    fn pathTo(dl: *DrawList, p: V2) !void {
        try dl.path.append(dl.allocator, p);
    }

    /// Append an arc as `segments + 1` points from `a0` to `a1`.
    fn pathArc(dl: *DrawList, cx: f32, cy: f32, radius: f32, a0: f32, a1: f32, segments: u32) !void {
        if (radius == 0) return;
        var i: u32 = 0;
        while (i <= segments) : (i += 1) {
            const a = a0 + (a1 - a0) * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)));
            try dl.pathTo(.{ cx + @cos(a) * radius, cy + @sin(a) * radius });
        }
    }

    /// Append a full ellipse (from a circle command's bounding box) as a
    /// closed path of `circle_segments` evenly spaced points.
    fn pathEllipse(dl: *DrawList, c: anytype) !void {
        const rx = @as(f32, @floatFromInt(c.w)) * 0.5;
        const ry = @as(f32, @floatFromInt(c.h)) * 0.5;
        const cx = @as(f32, @floatFromInt(c.x)) + rx;
        const cy = @as(f32, @floatFromInt(c.y)) + ry;
        const n = dl.cfg.circle_segments;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            try dl.pathTo(.{ cx + @cos(a) * rx, cy + @sin(a) * ry });
        }
    }

    /// Append a rectangle outline (optionally rounded) as a closed path.
    fn pathRect(dl: *DrawList, x: f32, y: f32, w: f32, h: f32, rounding: f32) !void {
        var r = rounding;
        r = @min(r, @abs(w));
        r = @min(r, @abs(h));
        if (r == 0) {
            try dl.pathTo(.{ x, y });
            try dl.pathTo(.{ x + w, y });
            try dl.pathTo(.{ x + w, y + h });
            try dl.pathTo(.{ x, y + h });
        } else {
            const half_pi = std.math.pi * 0.5;
            // corners: top-left, top-right, bottom-right, bottom-left
            try dl.pathArc(x + r, y + r, r, std.math.pi, std.math.pi + half_pi, 5);
            try dl.pathArc(x + w - r, y + r, r, std.math.pi + half_pi, std.math.tau, 5);
            try dl.pathArc(x + w - r, y + h - r, r, 0, half_pi, 5);
            try dl.pathArc(x + r, y + h - r, r, half_pi, std.math.pi, 5);
        }
    }

    /// Bezier curve appended to the current path (`p0` must already be on it).
    fn pathCurve(dl: *DrawList, p0: V2, c0: V2, c1: V2, p1: V2, segments: u32) !void {
        var i: u32 = 1;
        while (i <= segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const it = 1 - t;
            const w0 = it * it * it;
            const w1 = 3 * it * it * t;
            const w2 = 3 * it * t * t;
            const w3 = t * t * t;
            try dl.pathTo(.{
                w0 * p0[0] + w1 * c0[0] + w2 * c1[0] + w3 * p1[0],
                w0 * p0[1] + w1 * c0[1] + w2 * c1[1] + w3 * p1[1],
            });
        }
    }

    fn vtx(dl: *DrawList, p: V2, col: [4]u8) !Index {
        return dl.vertex(p[0], p[1], dl.cfg.white_uv[0], dl.cfg.white_uv[1], col);
    }

    /// Average two edge normals and rescale so the miter reaches the outline
    /// (the `1/|dm|^2` term, clamped, mirrors Nuklear's join handling).
    fn miter(n0: V2, n1: V2) V2 {
        var dm = v2muls(v2add(n0, n1), 0.5);
        const dmr2 = dm[0] * dm[0] + dm[1] * dm[1];
        if (dmr2 > 0.000001) {
            const scale = @min(@as(f32, 100.0), 1.0 / dmr2);
            dm = v2muls(dm, scale);
        }
        return dm;
    }

    /// Fill a convex polygon, anti-aliasing the silhouette when `aa` is set.
    fn fillPolyConvex(dl: *DrawList, points: []const V2, col: Color, aa: bool) !void {
        const n = points.len;
        if (n < 3) return;
        const c = rgba(col);

        if (!aa) {
            const base: Index = @intCast(dl.vertices.items.len);
            for (points) |p| _ = try dl.vtx(p, c);
            var i: usize = 2;
            while (i < n) : (i += 1)
                try dl.tri(base, base + @as(Index, @intCast(i - 1)), base + @as(Index, @intCast(i)));
            return;
        }

        const AA: f32 = 1.0;
        const c_trans = [4]u8{ col.r, col.g, col.b, 0 };
        const normals = try dl.scratchSlice(n);

        // edge normals (perpendicular to each prev->cur segment)
        var prev: usize = n - 1;
        var cur: usize = 0;
        while (cur < n) : ({
            prev = cur;
            cur += 1;
        }) {
            const d = v2dir(points[prev], points[cur]);
            normals[prev] = .{ d[1], -d[0] };
        }

        // two vertices per point: inner (solid) at even, outer (transparent) at odd
        const base: Index = @intCast(dl.vertices.items.len);
        prev = n - 1;
        cur = 0;
        while (cur < n) : ({
            prev = cur;
            cur += 1;
        }) {
            const dm = v2muls(miter(normals[prev], normals[cur]), AA * 0.5);
            _ = try dl.vtx(v2sub(points[cur], dm), c);
            _ = try dl.vtx(v2add(points[cur], dm), c_trans);
        }

        // interior fan over the inner ring (even vertices)
        var i: usize = 2;
        while (i < n) : (i += 1)
            try dl.tri(base, base + @as(Index, @intCast((i - 1) * 2)), base + @as(Index, @intCast(i * 2)));

        // fringe quads between inner and outer ring
        prev = n - 1;
        cur = 0;
        while (cur < n) : ({
            prev = cur;
            cur += 1;
        }) {
            const in0: Index = base + @as(Index, @intCast(prev * 2));
            const in1: Index = base + @as(Index, @intCast(cur * 2));
            try dl.tri(in1, in0, in0 + 1);
            try dl.tri(in0 + 1, in1 + 1, in1);
        }
    }

    /// Stroke a polyline, anti-aliasing the edges when `aa` is set.
    fn strokePolyLine(dl: *DrawList, points: []const V2, col: Color, closed: bool, thickness: f32, aa: bool) !void {
        const n = points.len;
        if (n < 2) return;
        const count: usize = if (closed) n else n - 1;
        const c = rgba(col);

        if (!aa) {
            const t = @max(thickness, 1.0) * 0.5;
            var seg: usize = 0;
            while (seg < count) : (seg += 1) {
                const nxt = if (seg + 1 == n) 0 else seg + 1;
                const p1 = points[seg];
                const p2 = points[nxt];
                const d = v2dir(p1, p2);
                const dx = d[0] * t;
                const dy = d[1] * t;
                const base: Index = @intCast(dl.vertices.items.len);
                _ = try dl.vtx(.{ p1[0] + dy, p1[1] - dx }, c);
                _ = try dl.vtx(.{ p2[0] + dy, p2[1] - dx }, c);
                _ = try dl.vtx(.{ p2[0] - dy, p2[1] + dx }, c);
                _ = try dl.vtx(.{ p1[0] - dy, p1[1] + dx }, c);
                try dl.tri(base, base + 1, base + 2);
                try dl.tri(base, base + 2, base + 3);
            }
            return;
        }

        const AA: f32 = 1.0;
        const c_trans = [4]u8{ col.r, col.g, col.b, 0 };
        const thick = thickness > 1.0;

        // normals[0..n] followed by fringe temps (2 per point thin, 4 thick)
        const per: usize = if (thick) 4 else 2;
        const scratch = try dl.scratchSlice(n + n * per);
        const normals = scratch[0..n];
        const temp = scratch[n..];

        var seg: usize = 0;
        while (seg < count) : (seg += 1) {
            const nxt = if (seg + 1 == n) 0 else seg + 1;
            const d = v2dir(points[seg], points[nxt]);
            normals[seg] = .{ d[1], -d[0] };
        }
        if (!closed) normals[n - 1] = normals[n - 2];

        const base: Index = @intCast(dl.vertices.items.len);

        if (!thick) {
            if (!closed) {
                temp[0] = v2add(points[0], v2muls(normals[0], AA));
                temp[1] = v2sub(points[0], v2muls(normals[0], AA));
                const d = v2muls(normals[n - 1], AA);
                temp[(n - 1) * 2 + 0] = v2add(points[n - 1], d);
                temp[(n - 1) * 2 + 1] = v2sub(points[n - 1], d);
            }
            seg = 0;
            while (seg < count) : (seg += 1) {
                const nxt = if (seg + 1 == n) 0 else seg + 1;
                const dm = v2muls(miter(normals[seg], normals[nxt]), AA);
                temp[nxt * 2 + 0] = v2add(points[nxt], dm);
                temp[nxt * 2 + 1] = v2sub(points[nxt], dm);
            }
            // 3 vertices per point: center (solid), +AA and -AA (transparent)
            var i: usize = 0;
            while (i < n) : (i += 1) {
                _ = try dl.vtx(points[i], c);
                _ = try dl.vtx(temp[i * 2 + 0], c_trans);
                _ = try dl.vtx(temp[i * 2 + 1], c_trans);
            }
            seg = 0;
            while (seg < count) : (seg += 1) {
                const idx1 = base + @as(Index, @intCast(seg * 3));
                const idx2 = if (seg + 1 == n) base else base + @as(Index, @intCast((seg + 1) * 3));
                try dl.tri(idx2 + 0, idx1 + 0, idx1 + 2);
                try dl.tri(idx1 + 2, idx2 + 2, idx2 + 0);
                try dl.tri(idx2 + 1, idx1 + 1, idx1 + 0);
                try dl.tri(idx1 + 0, idx2 + 0, idx2 + 1);
            }
        } else {
            const half_inner = (thickness - AA) * 0.5;
            if (!closed) {
                const d1a = v2muls(normals[0], half_inner + AA);
                const d2a = v2muls(normals[0], half_inner);
                temp[0] = v2add(points[0], d1a);
                temp[1] = v2add(points[0], d2a);
                temp[2] = v2sub(points[0], d2a);
                temp[3] = v2sub(points[0], d1a);
                const d1b = v2muls(normals[n - 1], half_inner + AA);
                const d2b = v2muls(normals[n - 1], half_inner);
                temp[(n - 1) * 4 + 0] = v2add(points[n - 1], d1b);
                temp[(n - 1) * 4 + 1] = v2add(points[n - 1], d2b);
                temp[(n - 1) * 4 + 2] = v2sub(points[n - 1], d2b);
                temp[(n - 1) * 4 + 3] = v2sub(points[n - 1], d1b);
            }
            seg = 0;
            while (seg < count) : (seg += 1) {
                const nxt = if (seg + 1 == n) 0 else seg + 1;
                const dm = miter(normals[seg], normals[nxt]);
                const dm_out = v2muls(dm, half_inner + AA);
                const dm_in = v2muls(dm, half_inner);
                temp[nxt * 4 + 0] = v2add(points[nxt], dm_out);
                temp[nxt * 4 + 1] = v2add(points[nxt], dm_in);
                temp[nxt * 4 + 2] = v2sub(points[nxt], dm_in);
                temp[nxt * 4 + 3] = v2sub(points[nxt], dm_out);
            }
            // 4 vertices per point: outer/inner/inner/outer (trans/solid/solid/trans)
            var i: usize = 0;
            while (i < n) : (i += 1) {
                _ = try dl.vtx(temp[i * 4 + 0], c_trans);
                _ = try dl.vtx(temp[i * 4 + 1], c);
                _ = try dl.vtx(temp[i * 4 + 2], c);
                _ = try dl.vtx(temp[i * 4 + 3], c_trans);
            }
            seg = 0;
            while (seg < count) : (seg += 1) {
                const idx1 = base + @as(Index, @intCast(seg * 4));
                const idx2 = if (seg + 1 == n) base else base + @as(Index, @intCast((seg + 1) * 4));
                try dl.tri(idx2 + 1, idx1 + 1, idx1 + 2);
                try dl.tri(idx1 + 2, idx2 + 2, idx2 + 1);
                try dl.tri(idx2 + 1, idx1 + 1, idx1 + 0);
                try dl.tri(idx1 + 0, idx2 + 0, idx2 + 1);
                try dl.tri(idx2 + 2, idx1 + 2, idx1 + 3);
                try dl.tri(idx1 + 3, idx2 + 3, idx2 + 2);
            }
        }
    }

    fn scratchSlice(dl: *DrawList, n: usize) ![]V2 {
        try dl.scratch.resize(dl.allocator, n);
        return dl.scratch.items;
    }

    /// Stroke the current path, then clear it.
    fn pathStroke(dl: *DrawList, col: Color, closed: bool, thickness: f32) !void {
        try dl.strokePolyLine(dl.path.items, col, closed, thickness, dl.cfg.line_aa);
        dl.pathClear();
    }

    /// Fill the current path as a convex polygon, then clear it.
    fn pathFill(dl: *DrawList, col: Color) !void {
        try dl.fillPolyConvex(dl.path.items, col, dl.cfg.shape_aa);
        dl.pathClear();
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
        dl.pathClear(); // drop any path left over from an interrupted conversion
        var clip = math.null_rect;
        for (commands) |cmd| {
            switch (cmd) {
                .scissor => |s| {
                    try dl.flush(clip, cfg.texture);
                    clip = Rect.initI(s.x, s.y, s.w, s.h);
                },
                .rect_filled => |c| {
                    try dl.pathRect(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), @floatFromInt(c.rounding));
                    try dl.pathFill(c.color);
                },
                .rect => |c| {
                    try dl.pathRect(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), @floatFromInt(c.rounding));
                    try dl.pathStroke(c.color, true, @floatFromInt(c.line_thickness));
                },
                .rect_multi_color => |c| try dl.rectMultiColor(c),
                .line => |c| {
                    try dl.pathTo(.{ @floatFromInt(c.begin.x), @floatFromInt(c.begin.y) });
                    try dl.pathTo(.{ @floatFromInt(c.end.x), @floatFromInt(c.end.y) });
                    try dl.pathStroke(c.color, false, @floatFromInt(c.line_thickness));
                },
                .circle_filled => |c| {
                    try dl.pathEllipse(c);
                    try dl.pathFill(c.color);
                },
                .circle => |c| {
                    try dl.pathEllipse(c);
                    try dl.pathStroke(c.color, true, @floatFromInt(c.line_thickness));
                },
                .triangle_filled => |c| {
                    try dl.pathTo(.{ @floatFromInt(c.a.x), @floatFromInt(c.a.y) });
                    try dl.pathTo(.{ @floatFromInt(c.b.x), @floatFromInt(c.b.y) });
                    try dl.pathTo(.{ @floatFromInt(c.c.x), @floatFromInt(c.c.y) });
                    try dl.pathFill(c.color);
                },
                .triangle => |c| {
                    try dl.pathTo(.{ @floatFromInt(c.a.x), @floatFromInt(c.a.y) });
                    try dl.pathTo(.{ @floatFromInt(c.b.x), @floatFromInt(c.b.y) });
                    try dl.pathTo(.{ @floatFromInt(c.c.x), @floatFromInt(c.c.y) });
                    try dl.pathStroke(c.color, true, @floatFromInt(c.line_thickness));
                },
                .polygon_filled => |c| {
                    for (c.points) |p| try dl.pathTo(.{ @floatFromInt(p.x), @floatFromInt(p.y) });
                    try dl.pathFill(c.color);
                },
                .polygon => |c| {
                    for (c.points) |p| try dl.pathTo(.{ @floatFromInt(p.x), @floatFromInt(p.y) });
                    try dl.pathStroke(c.color, true, @floatFromInt(c.line_thickness));
                },
                .polyline => |c| {
                    for (c.points) |p| try dl.pathTo(.{ @floatFromInt(p.x), @floatFromInt(p.y) });
                    try dl.pathStroke(c.color, false, @floatFromInt(c.line_thickness));
                },
                .text => |c| if (dl.cfg.text_hook) |h| try h(dl, c),
                .image => |c| {
                    try dl.flush(clip, cfg.texture); // close the pending solid/text batch
                    try dl.imageQuad(c);
                    try dl.flush(clip, c.img.handle); // the image gets its own batch + texture
                },
                .arc_filled => |c| {
                    const cx: f32 = @floatFromInt(c.cx);
                    const cy: f32 = @floatFromInt(c.cy);
                    try dl.pathTo(.{ cx, cy });
                    try dl.pathArc(cx, cy, @floatFromInt(c.r), c.a[0], c.a[1], dl.cfg.circle_segments);
                    try dl.pathFill(c.color);
                },
                .arc => |c| {
                    const cx: f32 = @floatFromInt(c.cx);
                    const cy: f32 = @floatFromInt(c.cy);
                    try dl.pathTo(.{ cx, cy });
                    try dl.pathArc(cx, cy, @floatFromInt(c.r), c.a[0], c.a[1], dl.cfg.circle_segments);
                    try dl.pathStroke(c.color, true, @floatFromInt(c.line_thickness));
                },
                .curve => |c| {
                    const p0: V2 = .{ @floatFromInt(c.begin.x), @floatFromInt(c.begin.y) };
                    try dl.pathTo(p0);
                    try dl.pathCurve(
                        p0,
                        .{ @floatFromInt(c.ctrl[0].x), @floatFromInt(c.ctrl[0].y) },
                        .{ @floatFromInt(c.ctrl[1].x), @floatFromInt(c.ctrl[1].y) },
                        .{ @floatFromInt(c.end.x), @floatFromInt(c.end.y) },
                        dl.cfg.curve_segments,
                    );
                    try dl.pathStroke(c.color, false, @floatFromInt(c.line_thickness));
                },
                .custom => {}, // renderer-defined callback; the app dispatches it
            }
        }
        try dl.flush(clip, cfg.texture);
    }
};

// --- tests ---------------------------------------------------------------

test "convert emits a quad per filled rect (no AA)" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    var cmds = [_]Command{
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.rgb(255, 0, 0) } },
    };
    try dl.convert(&cmds, .{ .shape_aa = false });
    try std.testing.expectEqual(@as(usize, 4), dl.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 6), dl.indices.items.len);
    try std.testing.expectEqual(@as(usize, 1), dl.commands.items.len);
    try std.testing.expectEqual(@as(u32, 6), dl.commands.items[0].elem_count);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, dl.vertices.items[0].col);
}

test "AA fill adds a transparent fringe ring around the solid shape" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    var cmds = [_]Command{
        .{ .rect_filled = .{ .rounding = 0, .x = 0, .y = 0, .w = 10, .h = 10, .color = Color.rgb(255, 0, 0) } },
    };
    try dl.convert(&cmds, .{ .shape_aa = true });
    // 4 path points -> 2 vertices each (inner solid + outer transparent).
    try std.testing.expectEqual(@as(usize, 8), dl.vertices.items.len);
    // interior fan (2 tris) + 4 fringe quads (8 tris) = 30 indices.
    try std.testing.expectEqual(@as(usize, 30), dl.indices.items.len);
    // even vertices are solid, odd vertices are the transparent fringe.
    try std.testing.expectEqual(@as(u8, 255), dl.vertices.items[0].col[3]);
    try std.testing.expectEqual(@as(u8, 0), dl.vertices.items[1].col[3]);
}

test "AA stroke feathers a thin line into transparent edges" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    var cmds = [_]Command{
        .{ .line = .{ .line_thickness = 1, .begin = .{ .x = 0, .y = 0 }, .end = .{ .x = 10, .y = 0 }, .color = Color.rgb(0, 255, 0) } },
    };
    try dl.convert(&cmds, .{ .line_aa = true });
    // thin AA line: 2 points * 3 vertices (center solid + 2 transparent).
    try std.testing.expectEqual(@as(usize, 6), dl.vertices.items.len);
    try std.testing.expectEqual(@as(u8, 255), dl.vertices.items[0].col[3]); // center
    try std.testing.expectEqual(@as(u8, 0), dl.vertices.items[1].col[3]); // fringe
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
