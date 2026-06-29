//! Color picker widget, ported from `nuklear_color_picker.c`: an SV matrix plus
//! a hue bar and optional alpha bar, drawn with multi-color gradient rects.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const widget = @import("widget.zig");
const button = @import("button.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Color = color.Color;
const Colorf = color.Colorf;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;

pub const ColorFormat = enum { rgb, rgba };

fn sat(x: f32) f32 {
    return std.math.clamp(x, 0, 1);
}

fn colorPickerBehavior(state: *States, bounds: Rect, matrix: Rect, hue_bar: Rect, alpha_bar: ?Rect, col: *Colorf, in: ?*const Input) bool {
    const h = col.toHsva();
    var hsva = [4]f32{ h.h, h.s, h.v, h.a };
    var value_changed = false;
    var hsv_changed = false;

    if (button.behavior(state, matrix, in, .repeater)) {
        const p = in.?.mouse.pos;
        hsva[1] = sat((p.x - matrix.x) / (matrix.w - 1));
        hsva[2] = 1.0 - sat((p.y - matrix.y) / (matrix.h - 1));
        value_changed = true;
        hsv_changed = true;
    }
    if (button.behavior(state, hue_bar, in, .repeater)) {
        hsva[0] = sat((in.?.mouse.pos.y - hue_bar.y) / (hue_bar.h - 1));
        value_changed = true;
        hsv_changed = true;
    }
    if (alpha_bar) |ab| {
        if (button.behavior(state, ab, in, .repeater)) {
            hsva[3] = 1.0 - sat((in.?.mouse.pos.y - ab.y) / (ab.h - 1));
            value_changed = true;
        }
    }

    state.reset();
    if (hsv_changed) {
        col.* = Colorf.fromHsva(hsva[0], hsva[1], hsva[2], hsva[3]);
        state.* = States.active;
    }
    if (value_changed) {
        col.a = hsva[3];
        state.* = States.active;
    }
    if (in) |i| {
        if (i.isMouseHoveringRect(bounds)) state.* = States.hovered;
        if (state.hover and !i.isMousePrevHoveringRect(bounds)) {
            state.entered = true;
        } else if (i.isMousePrevHoveringRect(bounds)) {
            state.left = true;
        }
    }
    return value_changed;
}

fn drawColorPicker(o: *CommandBuffer, matrix: Rect, hue_bar: Rect, alpha_bar: ?Rect, col: Colorf) !void {
    const white = Color.white;
    const black = Color.black;
    const black_trans: Color = .{ .a = 0 };
    const crosshair: f32 = 7.0;

    const h = col.toHsva();
    const hsva = [4]f32{ h.h, h.s, h.v, h.a };

    // hue bar (6 vertical gradient segments)
    const hue_colors = [7]Color{
        .{ .r = 255, .a = 255 }, .{ .r = 255, .g = 255, .a = 255 },
        .{ .g = 255, .a = 255 }, .{ .g = 255, .b = 255, .a = 255 },
        .{ .b = 255, .a = 255 }, .{ .r = 255, .b = 255, .a = 255 },
        .{ .r = 255, .a = 255 },
    };
    for (0..6) |i| {
        const fi: f32 = @floatFromInt(i);
        const seg: Rect = .init(hue_bar.x, hue_bar.y + fi * (hue_bar.h / 6.0) + 0.5, hue_bar.w, hue_bar.h / 6.0 + 0.5);
        try o.fillRectMultiColor(seg, hue_colors[i], hue_colors[i], hue_colors[i + 1], hue_colors[i + 1]);
    }
    var line_y = @trunc(hue_bar.y + hsva[0] * matrix.h + 0.5);
    try o.strokeLine(hue_bar.x - 1, line_y, hue_bar.x + hue_bar.w + 2, line_y, 1, white);

    if (alpha_bar) |ab| {
        const alpha = sat(col.a);
        line_y = @trunc(ab.y + (1.0 - alpha) * matrix.h + 0.5);
        try o.fillRectMultiColor(ab, white, white, black, black);
        try o.strokeLine(ab.x - 1, line_y, ab.x + ab.w + 2, line_y, 1, white);
    }

    // SV matrix: white->hue horizontally, transparent->black vertically
    const temp: Color = .fromHsvaF(hsva[0], 1.0, 1.0, 1.0);
    try o.fillRectMultiColor(matrix, white, temp, temp, white);
    try o.fillRectMultiColor(matrix, black_trans, black_trans, black, black);

    // crosshair at (S, 1-V)
    const px = @trunc(matrix.x + hsva[1] * matrix.w);
    const py = @trunc(matrix.y + (1.0 - hsva[2]) * matrix.h);
    try o.strokeLine(px - crosshair, py, px - 2, py, 1.0, white);
    try o.strokeLine(px + crosshair + 1, py, px + 3, py, 1.0, white);
    try o.strokeLine(px, py + crosshair + 1, px, py + 3, 1.0, white);
    try o.strokeLine(px, py - crosshair, px, py - 2, 1.0, white);
}

/// Lay out, interact with and draw a color picker; updates `col`, returns
/// whether it changed (`nk_do_color_picker`).
pub fn doColorPicker(state: *States, out: *CommandBuffer, col: *Colorf, fmt: ColorFormat, bounds_in: Rect, padding: Vec2, in: ?*const Input, font: *const UserFont) !bool {
    const bar_w = font.height;
    var bounds = bounds_in;
    bounds.x += padding.x;
    bounds.y += padding.x;
    bounds.w -= 2 * padding.x;
    bounds.h -= 2 * padding.y;

    const matrix: Rect = .{
        .x = bounds.x,
        .y = bounds.y,
        .h = bounds.h,
        .w = bounds.w - (3 * padding.x + 2 * bar_w),
    };
    const hue_bar: Rect = .{
        .w = bar_w,
        .y = bounds.y,
        .h = matrix.h,
        .x = matrix.x + matrix.w + padding.x,
    };
    const alpha_bar: ?Rect = if (fmt == .rgba) Rect{
        .x = hue_bar.x + hue_bar.w + padding.x,
        .y = bounds.y,
        .w = bar_w,
        .h = matrix.h,
    } else null;

    const ret = colorPickerBehavior(state, bounds, matrix, hue_bar, alpha_bar, col, in);
    try drawColorPicker(out, matrix, hue_bar, alpha_bar, col.*);
    return ret;
}

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font: UserFont = .{ .height = 13, .width = &testWidth };

test "color picker is stable without input" {
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var state: States = .{};
    var col = Color.rgb(200, 100, 50).toColorf();
    const before = col;
    const changed = try doColorPicker(&state, &buf, &col, .rgba, .init(0, 0, 200, 150), .init(0, 0), null, &test_font);
    try std.testing.expect(!changed);
    try std.testing.expectEqual(before, col);
}

test "clicking the SV matrix changes the color" {
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 30, .y = 30 };
    in.button(.left, 30, 30, true);
    var state: States = .{};
    var col = Color.rgb(200, 100, 50).toColorf();
    const before = col;
    const changed = try doColorPicker(&state, &buf, &col, .rgba, .init(0, 0, 200, 150), .init(0, 0), &in, &test_font);
    try std.testing.expect(changed);
    try std.testing.expect(col.r != before.r or col.g != before.g or col.b != before.b);
}
