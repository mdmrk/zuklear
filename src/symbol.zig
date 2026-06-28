//! Symbol drawing (`nk_draw_symbol`, from `nuklear_button.c`): the little
//! glyphs widgets use — close X, +/- , triangles, chevrons, the hamburger, etc.
//! Used by symbol buttons, combo/tree arrows and scrollbar buttons.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const font_mod = @import("font.zig");
const text_widget = @import("text.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Color = color.Color;
const Symbol = style_mod.Symbol;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const UserFont = font_mod.UserFont;

/// Draw `sym` inside `content` (`nk_draw_symbol`). `border_width` doubles as the
/// stroke thickness for outline/line symbols.
pub fn drawSymbol(out: *CommandBuffer, sym: Symbol, content: Rect, background: Color, foreground: Color, border_width_in: f32, font: *const UserFont) !void {
    const border_width = if (border_width_in <= 0) 1.0 else border_width_in;

    switch (sym) {
        .none => {},
        .x => {
            const pad_x = content.w * 0.2;
            const pad_y = content.h * 0.2;
            const x0 = content.x + pad_x;
            const y0 = content.y + pad_y;
            const x1 = content.x + content.w - pad_x;
            const y1 = content.y + content.h - pad_y;
            try out.strokeLine(x0, y0, x1, y1, border_width, foreground);
            try out.strokeLine(x1, y0, x0, y1, border_width, foreground);
        },
        .underscore, .plus, .minus => {
            const character = switch (sym) {
                .underscore => "_",
                .plus => "+",
                else => "-",
            };
            try text_widget.widgetText(out, content, character, Align.text_centered, Vec2.init(0, 0), background, foreground, font);
        },
        .rect_solid, .rect_outline => {
            try out.fillRect(content, 0, foreground);
            if (sym == .rect_outline) try out.fillRect(content.shrink(border_width), 0, background);
        },
        .circle_solid, .circle_outline => {
            try out.fillCircle(content, foreground);
            if (sym == .circle_outline) try out.fillCircle(content.shrink(border_width), background);
        },
        .triangle_up, .triangle_down, .triangle_left, .triangle_right => {
            const heading: math.Heading = switch (sym) {
                .triangle_right => .right,
                .triangle_left => .left,
                .triangle_up => .up,
                else => .down,
            };
            const p = math.triangleFromDirection(content, 0, 0, heading);
            try out.fillTriangle(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y, foreground);
        },
        .triangle_up_outline, .triangle_down_outline, .triangle_left_outline, .triangle_right_outline => {
            const heading: math.Heading = switch (sym) {
                .triangle_right_outline => .right,
                .triangle_left_outline => .left,
                .triangle_up_outline => .up,
                else => .down,
            };
            const p = math.triangleFromDirection(content, 0, 0, heading);
            try out.strokeTriangle(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y, border_width, foreground);
        },
        .chevron_up, .chevron_down, .chevron_left, .chevron_right => {
            const p: [3]Vec2 = switch (sym) {
                .chevron_right => .{
                    Vec2.init(content.x, content.y),
                    Vec2.init(content.x + content.w, content.y + content.h * 0.5),
                    Vec2.init(content.x, content.y + content.h),
                },
                .chevron_left => .{
                    Vec2.init(content.x + content.w, content.y),
                    Vec2.init(content.x, content.y + content.h * 0.5),
                    Vec2.init(content.x + content.w, content.y + content.h),
                },
                .chevron_up => .{
                    Vec2.init(content.x, content.y + content.h),
                    Vec2.init(content.x + content.w * 0.5, content.y),
                    Vec2.init(content.x + content.w, content.y + content.h),
                },
                else => .{ // chevron_down
                    Vec2.init(content.x, content.y),
                    Vec2.init(content.x + content.w * 0.5, content.y + content.h),
                    Vec2.init(content.x + content.w, content.y),
                },
            };
            try out.strokeLine(p[0].x, p[0].y, p[1].x, p[1].y, border_width, foreground);
            try out.strokeLine(p[1].x, p[1].y, p[2].x, p[2].y, border_width, foreground);
        },
        .hamburger => {
            const y2 = content.y + content.h * 0.5;
            const y3 = content.y + content.h - border_width;
            const x1 = content.x + content.w;
            try out.strokeLine(content.x, content.y, x1, content.y, border_width, foreground);
            try out.strokeLine(content.x, y2, x1, y2, border_width, foreground);
            try out.strokeLine(content.x, y3, x1, y3, border_width, foreground);
        },
    }
}

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font = UserFont{ .height = 13, .width = &testWidth };

test "drawSymbol emits geometry for each family" {
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    const r = Rect.init(0, 0, 16, 16);

    try drawSymbol(&buf, .x, r, Color.black, Color.white, 1, &test_font);
    try drawSymbol(&buf, .triangle_down, r, Color.black, Color.white, 1, &test_font);
    try drawSymbol(&buf, .circle_solid, r, Color.black, Color.white, 1, &test_font);
    try drawSymbol(&buf, .plus, r, Color.black, Color.white, 1, &test_font);
    try drawSymbol(&buf, .none, r, Color.black, Color.white, 1, &test_font);

    // X = 2 lines, triangle = 1 fill, circle = 1 fill, plus = 1 text, none = 0
    try std.testing.expectEqual(@as(usize, 5), buf.items().len);
    try std.testing.expect(buf.items()[2] == .triangle_filled);
}
