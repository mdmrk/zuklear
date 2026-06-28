//! TTF font baking — the optional `zuklear_font` module.
//!
//! This is the one place zuklear uses C: it bakes a TrueType font into an alpha
//! atlas using the vendored `stb_truetype` + `stb_rect_pack` (both compiled as
//! C, per the project's font decision). The result is a coverage bitmap plus
//! per-glyph metrics and a `zuklear.UserFont` whose width callback uses the
//! baked advances. Renderers (software alpha-blit, or a GL texture) consume the
//! bitmap + `quad()` UVs.
//!
//! The core `zuklear` module stays pure Zig and dependency-free; only consumers
//! that import `zuklear_font` pull in libc + stb.

const std = @import("std");
const zk = @import("zuklear");
const UserFont = zk.UserFont;
const Handle = zk.Handle;

const c = @cImport({
    @cInclude("stb_rect_pack.h");
    @cInclude("stb_truetype.h");
});

/// First and count of the baked codepoint range (printable ASCII).
pub const first_codepoint = 32;
pub const glyph_count = 95; // 32..126

/// A baked font: an 8-bit alpha atlas plus per-glyph metrics. Owns the bitmap.
pub const Atlas = struct {
    allocator: std.mem.Allocator,
    bitmap: []u8,
    width: u32,
    height: u32,
    pixel_height: f32,
    /// Distance from the top of a line to the baseline, in pixels.
    ascent: f32,
    chars: [glyph_count]c.stbtt_packedchar,

    pub fn deinit(a: *Atlas) void {
        a.allocator.free(a.bitmap);
        a.* = undefined;
    }

    fn packed_(a: *const Atlas, cp: u21) ?c.stbtt_packedchar {
        if (cp < first_codepoint or cp >= first_codepoint + glyph_count) return null;
        return a.chars[cp - first_codepoint];
    }

    /// Pixel advance of a codepoint (0 for unsupported).
    pub fn advance(a: *const Atlas, cp: u21) f32 {
        const pc = a.packed_(cp) orelse return 0;
        return pc.xadvance;
    }

    /// Placement quad for a glyph at pen position `x,y` (top-left origin):
    /// destination rect in pixels and source UVs in `[0,1]`.
    pub const Quad = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        u0: f32,
        v0: f32,
        u1: f32,
        v1: f32,
        xadvance: f32,
    };

    pub fn quad(a: *const Atlas, cp: u21, pen_x: f32, pen_y: f32) ?Quad {
        const pc = a.packed_(cp) orelse return null;
        const w: f32 = @floatFromInt(a.width);
        const h: f32 = @floatFromInt(a.height);
        return .{
            .x0 = pen_x + pc.xoff,
            .y0 = pen_y + pc.yoff,
            .x1 = pen_x + pc.xoff2,
            .y1 = pen_y + pc.yoff2,
            .u0 = @as(f32, @floatFromInt(pc.x0)) / w,
            .v0 = @as(f32, @floatFromInt(pc.y0)) / h,
            .u1 = @as(f32, @floatFromInt(pc.x1)) / w,
            .v1 = @as(f32, @floatFromInt(pc.y1)) / h,
            .xadvance = pc.xadvance,
        };
    }

    fn widthFn(handle: Handle, height: f32, text: []const u8) f32 {
        _ = height;
        const a: *const Atlas = @ptrCast(@alignCast(handle.ptr.?));
        var total: f32 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| total += a.advance(cp);
        return total;
    }

    /// A `UserFont` backed by this atlas (its `userdata` points at the atlas, so
    /// the atlas must outlive the font).
    pub fn userFont(a: *Atlas) UserFont {
        return .{
            .userdata = Handle.fromPtr(a),
            .height = a.pixel_height,
            .width = &widthFn,
        };
    }

    /// UV of the reserved white texel (for solid fills in the vertex pipeline).
    pub fn whiteUv(a: *const Atlas) [2]f32 {
        const w: f32 = @floatFromInt(a.width);
        const h: f32 = @floatFromInt(a.height);
        return .{ (w - 0.5) / w, (h - 0.5) / h };
    }
};

const vertex = zk.render.vertex;

/// A `vertex.ConvertConfig.text_hook` that emits glyph quads (with atlas UVs)
/// into a draw list. Recovers the `Atlas` from the text command's font.
pub fn drawListText(dl: *vertex.DrawList, cmd: Text) anyerror!void {
    const a: *const Atlas = @ptrCast(@alignCast(cmd.font.userdata.ptr orelse return));
    var pen_x: f32 = @floatFromInt(cmd.x);
    const pen_y: f32 = @as(f32, @floatFromInt(cmd.y)) + a.ascent;
    var it = std.unicode.Utf8Iterator{ .bytes = cmd.string, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (a.quad(cp, pen_x, pen_y)) |q| {
            try dl.quadUV(q.x0, q.y0, q.x1, q.y1, q.u0, q.v0, q.u1, q.v1, cmd.foreground);
            pen_x += q.xadvance;
        }
    }
}

const software = zk.render.software;
const Text = zk.command.Text;

/// A `software.Rasterizer.text_fn` that alpha-blits baked glyphs. It recovers
/// the `Atlas` from the text command's font userdata, so any baked `UserFont`
/// works. Assign it to `rasterizer.text_fn`.
pub fn renderText(r: *software.Rasterizer, cmd: Text) void {
    const a: *const Atlas = @ptrCast(@alignCast(cmd.font.userdata.ptr orelse return));
    var pen_x: f32 = @floatFromInt(cmd.x);
    // baseline: stb glyph quads are baseline-relative, so drop by the ascent
    const pen_y: f32 = @as(f32, @floatFromInt(cmd.y)) + a.ascent;
    var it = std.unicode.Utf8Iterator{ .bytes = cmd.string, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (a.quad(cp, pen_x, pen_y)) |q| {
            blitQuad(r, a, q, cmd.foreground);
            pen_x += q.xadvance;
        }
    }
}

fn blitQuad(r: *software.Rasterizer, a: *const Atlas, q: Atlas.Quad, color: zk.Color) void {
    const x0: i32 = @intFromFloat(@floor(q.x0));
    const y0: i32 = @intFromFloat(@floor(q.y0));
    const x1: i32 = @intFromFloat(@ceil(q.x1));
    const y1: i32 = @intFromFloat(@ceil(q.y1));
    const sx0 = q.u0 * @as(f32, @floatFromInt(a.width));
    const sy0 = q.v0 * @as(f32, @floatFromInt(a.height));
    const dw = @max(q.x1 - q.x0, 1);
    const dh = @max(q.y1 - q.y0, 1);
    const sw = (q.u1 - q.u0) * @as(f32, @floatFromInt(a.width));
    const sh = (q.v1 - q.v0) * @as(f32, @floatFromInt(a.height));

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5 - q.x0) / dw;
            const fy = (@as(f32, @floatFromInt(y)) + 0.5 - q.y0) / dh;
            const sxi: i32 = @intFromFloat(sx0 + fx * sw);
            const syi: i32 = @intFromFloat(sy0 + fy * sh);
            if (sxi < 0 or syi < 0 or sxi >= @as(i32, @intCast(a.width)) or syi >= @as(i32, @intCast(a.height))) continue;
            const cov = a.bitmap[@as(usize, @intCast(syi)) * a.width + @as(usize, @intCast(sxi))];
            if (cov == 0) continue;
            var col = color;
            col.a = @intCast((@as(u16, color.a) * cov) / 255);
            r.plot(x, y, col);
        }
    }
}

/// Bake `ttf` at `pixel_height` into a `width`x`height` alpha atlas
/// (`stbtt_PackFontRange`).
pub fn bake(allocator: std.mem.Allocator, ttf: []const u8, pixel_height: f32, width: u32, height: u32) !Atlas {
    const bitmap = try allocator.alloc(u8, width * height);
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0);

    var atlas = Atlas{
        .allocator = allocator,
        .bitmap = bitmap,
        .width = width,
        .height = height,
        .pixel_height = pixel_height,
        .chars = undefined,
        .ascent = pixel_height,
    };

    // baseline: place glyph quads at top + ascent (stb quads are baseline-relative)
    var info: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&info, ttf.ptr, c.stbtt_GetFontOffsetForIndex(ttf.ptr, 0)) != 0) {
        const scale = c.stbtt_ScaleForPixelHeight(&info, pixel_height);
        var ascent: c_int = undefined;
        var descent: c_int = undefined;
        var line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        atlas.ascent = @as(f32, @floatFromInt(ascent)) * scale;
    }

    var spc: c.stbtt_pack_context = undefined;
    if (c.stbtt_PackBegin(&spc, bitmap.ptr, @intCast(width), @intCast(height), 0, 1, null) == 0)
        return error.PackBeginFailed;
    if (c.stbtt_PackFontRange(&spc, ttf.ptr, 0, pixel_height, first_codepoint, glyph_count, &atlas.chars) == 0) {
        c.stbtt_PackEnd(&spc);
        return error.PackFontRangeFailed;
    }
    c.stbtt_PackEnd(&spc);
    // reserve a white texel in the (typically unused) bottom-right corner for
    // solid fills in the vertex/GL pipeline.
    bitmap[width * height - 1] = 255;
    return atlas;
}

// --- tests ---------------------------------------------------------------

const proggy = @embedFile("ProggyClean.ttf");

test "bakes a TTF into a non-empty atlas with sane metrics" {
    var atlas = try bake(std.testing.allocator, proggy, 16, 256, 256);
    defer atlas.deinit();

    // some glyph coverage was written into the atlas
    var nonzero: usize = 0;
    for (atlas.bitmap) |px| {
        if (px != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 0);

    // the baseline ascent is set and sits within the line box
    try std.testing.expect(atlas.ascent > 0 and atlas.ascent < atlas.pixel_height);

    // 'M' should have a positive advance and a valid quad
    try std.testing.expect(atlas.advance('M') > 0);
    const q = atlas.quad('M', 0, 0).?;
    try std.testing.expect(q.u1 > q.u0 and q.v1 > q.v0);

    // the UserFont measures text via baked advances
    const font = atlas.userFont();
    try std.testing.expect(font.textWidth("Hello") > 0);
}
