//! zuklear command-stream dumper, mirroring `dump_nk.c`. Drives `overview.zig`
//! with the same scripted input and a fixed 7px font (matching Nuklear's default
//! ProggyClean metrics) and prints each frame's command buffers in the same
//! canonical format, so the two can be diffed. Output goes to stderr; run with
//! `2>file`. Built via `zig build dump`.

const std = @import("std");
const zk = @import("zuklear");
const overview = @import("overview");

const PIXEL_HEIGHT = 13;
const WIN_W = 480;
const WIN_H = 600;

// Scripted input shared with dump_nk.c (see the note there): expand the Window,
// Widgets, Layout and Input tabs bottom-up, press/release per click.
const script = [_][3]i32{
    .{ 200, 209, 1 }, .{ 200, 209, 0 }, // Input
    .{ 200, 184, 1 }, .{ 200, 184, 0 }, // Layout
    .{ 200, 109, 1 }, .{ 200, 109, 0 }, // Widgets
    .{ 200, 84, 1 }, .{ 200, 84, 0 }, // Window
    .{ 5, 5, 0 }, // settle
};

fn fontWidth(_: zk.Handle, _: f32, text: []const u8) f32 {
    return @floatFromInt(text.len * 7); // Nuklear default font: fixed 7px advance
}

const out = std.debug.print;

fn pcol(c: zk.Color) void {
    out("{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
}

fn pstr(s: []const u8) void {
    out("\"", .{});
    for (s) |ch| {
        if (ch == '\\' or ch == '"') {
            out("\\{c}", .{ch});
        } else if (ch == '\n') {
            out("\\n", .{});
        } else out("{c}", .{ch});
    }
    out("\"", .{});
}

fn dumpCommands(cmds: []const zk.Command) void {
    for (cmds) |cmd| switch (cmd) {
        .scissor => |c| out("SCISSOR {d} {d} {d} {d}\n", .{ c.x, c.y, c.w, c.h }),
        .line => |c| {
            out("LINE {d} {d} {d} {d} {d} ", .{ c.begin.x, c.begin.y, c.end.x, c.end.y, c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .rect => |c| {
            out("RECT {d} {d} {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h, c.rounding, c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .rect_filled => |c| {
            out("FILLRECT {d} {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h, c.rounding });
            pcol(c.color);
            out("\n", .{});
        },
        .rect_multi_color => |c| {
            out("RECTMULTI {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h });
            pcol(c.left);
            out(" ", .{});
            pcol(c.top);
            out(" ", .{});
            pcol(c.bottom);
            out(" ", .{});
            pcol(c.right);
            out("\n", .{});
        },
        .circle => |c| {
            out("CIRCLE {d} {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h, c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .circle_filled => |c| {
            out("FILLCIRCLE {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h });
            pcol(c.color);
            out("\n", .{});
        },
        .triangle => |c| {
            out("TRI {d} {d} {d} {d} {d} {d} {d} ", .{ c.a.x, c.a.y, c.b.x, c.b.y, c.c.x, c.c.y, c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .triangle_filled => |c| {
            out("FILLTRI {d} {d} {d} {d} {d} {d} ", .{ c.a.x, c.a.y, c.b.x, c.b.y, c.c.x, c.c.y });
            pcol(c.color);
            out("\n", .{});
        },
        .polygon => |c| {
            out("POLY {d} ", .{c.line_thickness});
            pcol(c.color);
            out(" {d}", .{c.points.len});
            for (c.points) |p| out(" {d} {d}", .{ p.x, p.y });
            out("\n", .{});
        },
        .polygon_filled => |c| {
            out("FILLPOLY ", .{});
            pcol(c.color);
            out(" {d}", .{c.points.len});
            for (c.points) |p| out(" {d} {d}", .{ p.x, p.y });
            out("\n", .{});
        },
        .polyline => |c| {
            out("POLYLINE {d} ", .{c.line_thickness});
            pcol(c.color);
            out(" {d}", .{c.points.len});
            for (c.points) |p| out(" {d} {d}", .{ p.x, p.y });
            out("\n", .{});
        },
        .arc => |c| {
            out("ARC {d} {d} {d} {d:.3} {d:.3} {d} ", .{ c.cx, c.cy, c.r, c.a[0], c.a[1], c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .arc_filled => |c| {
            out("FILLARC {d} {d} {d} {d:.3} {d:.3} ", .{ c.cx, c.cy, c.r, c.a[0], c.a[1] });
            pcol(c.color);
            out("\n", .{});
        },
        .curve => |c| {
            out("CURVE {d} {d} {d} {d} {d} {d} {d} {d} {d} ", .{ c.begin.x, c.begin.y, c.ctrl[0].x, c.ctrl[0].y, c.ctrl[1].x, c.ctrl[1].y, c.end.x, c.end.y, c.line_thickness });
            pcol(c.color);
            out("\n", .{});
        },
        .text => |c| {
            out("TEXT {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h });
            pcol(c.foreground);
            out(" ", .{});
            pcol(c.background);
            out(" ", .{});
            pstr(c.string);
            out("\n", .{});
        },
        .image => |c| {
            out("IMAGE {d} {d} {d} {d} ", .{ c.x, c.y, c.w, c.h });
            pcol(c.col);
            out("\n", .{});
        },
        .custom => {},
    };
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const font: zk.UserFont = .{ .height = PIXEL_HEIGHT, .width = &fontWidth };
    var ctx: zk.Context = .init(gpa, &font);
    defer ctx.deinit();

    var st: overview.State = .{};

    for (script, 0..) |s, frame| {
        ctx.input.begin();
        ctx.input.motion(s[0], s[1]);
        ctx.input.button(.left, s[0], s[1], s[2] != 0);
        ctx.input.end();

        try overview.overview(&ctx, &st);

        out("FRAME {d}\n", .{frame});
        for (ctx.windows.items) |w| dumpCommands(w.buffer.items());
        ctx.clear();
    }
}
