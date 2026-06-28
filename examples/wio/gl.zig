//! A minimal fixed-function (OpenGL 1.1) renderer for a zuklear vertex draw
//! list. Functions are loaded via a caller-provided `getProcAddress` (wio's),
//! so no GL bindings library is needed. The font atlas is uploaded as an RGBA
//! texture (white RGB + glyph coverage in alpha) so a single `GL_MODULATE`
//! pass renders both solid shapes and text with per-vertex color.

const std = @import("std");
const zk = @import("zuklear");
const zkfont = @import("zuklear_font");
const vertex = zk.render.vertex;

// GL constants
const TRIANGLES: u32 = 0x0004;
const BLEND: u32 = 0x0BE2;
const SRC_ALPHA: u32 = 0x0302;
const ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
const TEXTURE_2D: u32 = 0x0DE1;
const SCISSOR_TEST: u32 = 0x0C11;
const CULL_FACE: u32 = 0x0B44;
const DEPTH_TEST: u32 = 0x0B71;
const PROJECTION: u32 = 0x1701;
const MODELVIEW: u32 = 0x1700;
const VERTEX_ARRAY: u32 = 0x8074;
const COLOR_ARRAY: u32 = 0x8076;
const TEXTURE_COORD_ARRAY: u32 = 0x8078;
const FLOAT: u32 = 0x1406;
const UNSIGNED_BYTE: u32 = 0x1401;
const UNSIGNED_INT: u32 = 0x1405;
const COLOR_BUFFER_BIT: u32 = 0x4000;
const RGBA: u32 = 0x1908;
const TEXTURE_MIN_FILTER: u32 = 0x2801;
const TEXTURE_MAG_FILTER: u32 = 0x2800;
const LINEAR: u32 = 0x2601;
const UNPACK_ALIGNMENT: u32 = 0x0CF5;

/// Matches `wio.glGetProcAddress`.
pub const GetProc = *const fn ([*:0]const u8) ?*const fn () void;

const Gl = struct {
    Viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    ClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    Clear: *const fn (u32) callconv(.c) void,
    Enable: *const fn (u32) callconv(.c) void,
    Disable: *const fn (u32) callconv(.c) void,
    BlendFunc: *const fn (u32, u32) callconv(.c) void,
    MatrixMode: *const fn (u32) callconv(.c) void,
    LoadIdentity: *const fn () callconv(.c) void,
    Ortho: *const fn (f64, f64, f64, f64, f64, f64) callconv(.c) void,
    EnableClientState: *const fn (u32) callconv(.c) void,
    DisableClientState: *const fn (u32) callconv(.c) void,
    VertexPointer: *const fn (i32, u32, i32, ?*const anyopaque) callconv(.c) void,
    ColorPointer: *const fn (i32, u32, i32, ?*const anyopaque) callconv(.c) void,
    TexCoordPointer: *const fn (i32, u32, i32, ?*const anyopaque) callconv(.c) void,
    DrawElements: *const fn (u32, i32, u32, ?*const anyopaque) callconv(.c) void,
    Scissor: *const fn (i32, i32, i32, i32) callconv(.c) void,
    GenTextures: *const fn (i32, [*]u32) callconv(.c) void,
    BindTexture: *const fn (u32, u32) callconv(.c) void,
    TexImage2D: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void,
    TexParameteri: *const fn (u32, u32, i32) callconv(.c) void,
    PixelStorei: *const fn (u32, i32) callconv(.c) void,

    fn load(getProc: GetProc) Gl {
        var gl: Gl = undefined;
        inline for (@typeInfo(Gl).@"struct".fields) |f| {
            const proc = getProc("gl" ++ f.name) orelse std.debug.panic("missing GL function gl{s}", .{f.name});
            @field(gl, f.name) = @ptrCast(proc);
        }
        return gl;
    }
};

pub const Renderer = struct {
    gl: Gl,
    texture: u32 = 0,

    pub fn init(getProc: GetProc) Renderer {
        return .{ .gl = Gl.load(getProc) };
    }

    /// Upload a baked font atlas as an RGBA texture (white + coverage-as-alpha).
    pub fn uploadFont(r: *Renderer, allocator: std.mem.Allocator, atlas: *const zkfont.Atlas) !void {
        const n = atlas.width * atlas.height;
        const rgba = try allocator.alloc(u8, n * 4);
        defer allocator.free(rgba);
        for (atlas.bitmap, 0..) |a, i| {
            rgba[i * 4 + 0] = 255;
            rgba[i * 4 + 1] = 255;
            rgba[i * 4 + 2] = 255;
            rgba[i * 4 + 3] = a;
        }
        r.gl.GenTextures(1, @ptrCast(&r.texture));
        r.gl.BindTexture(TEXTURE_2D, r.texture);
        r.gl.PixelStorei(UNPACK_ALIGNMENT, 1);
        r.gl.TexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, LINEAR);
        r.gl.TexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, LINEAR);
        r.gl.TexImage2D(TEXTURE_2D, 0, RGBA, @intCast(atlas.width), @intCast(atlas.height), 0, RGBA, UNSIGNED_BYTE, rgba.ptr);
    }

    pub fn clear(r: *Renderer, fb_w: i32, fb_h: i32, c: zk.Color) void {
        r.gl.Viewport(0, 0, fb_w, fb_h);
        r.gl.ClearColor(@as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255, 1);
        r.gl.Clear(COLOR_BUFFER_BIT);
    }

    /// Draw a converted draw list. `fb_h` is the framebuffer height (for the
    /// top-left → bottom-left scissor flip).
    pub fn render(r: *Renderer, dl: *const vertex.DrawList, fb_w: i32, fb_h: i32) void {
        const gl = &r.gl;
        gl.Enable(BLEND);
        gl.BlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA);
        gl.Disable(CULL_FACE);
        gl.Disable(DEPTH_TEST);
        gl.Enable(SCISSOR_TEST);
        gl.Enable(TEXTURE_2D);
        gl.BindTexture(TEXTURE_2D, r.texture);

        gl.MatrixMode(PROJECTION);
        gl.LoadIdentity();
        gl.Ortho(0, @floatFromInt(fb_w), @floatFromInt(fb_h), 0, -1, 1);
        gl.MatrixMode(MODELVIEW);
        gl.LoadIdentity();

        if (dl.vertices.items.len == 0) return;
        const base = dl.vertices.items.ptr;
        const stride: i32 = @sizeOf(vertex.Vertex);
        gl.EnableClientState(VERTEX_ARRAY);
        gl.EnableClientState(TEXTURE_COORD_ARRAY);
        gl.EnableClientState(COLOR_ARRAY);
        gl.VertexPointer(2, FLOAT, stride, &base[0].pos);
        gl.TexCoordPointer(2, FLOAT, stride, &base[0].uv);
        gl.ColorPointer(4, UNSIGNED_BYTE, stride, &base[0].col);

        var offset: usize = 0;
        for (dl.commands.items) |cmd| {
            const cx: i32 = @intFromFloat(cmd.clip.x);
            const cy: i32 = fb_h - @as(i32, @intFromFloat(cmd.clip.y + cmd.clip.h));
            const cw: i32 = @intFromFloat(@max(cmd.clip.w, 0));
            const ch: i32 = @intFromFloat(@max(cmd.clip.h, 0));
            gl.Scissor(cx, cy, cw, ch);
            gl.DrawElements(TRIANGLES, @intCast(cmd.elem_count), UNSIGNED_INT, &dl.indices.items[offset]);
            offset += cmd.elem_count;
        }

        gl.DisableClientState(VERTEX_ARRAY);
        gl.DisableClientState(TEXTURE_COORD_ARRAY);
        gl.DisableClientState(COLOR_ARRAY);
        gl.Disable(SCISSOR_TEST);
    }
};
