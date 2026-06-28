//! Selectable widget, ported from `nuklear_selectable.c`. A toggleable labelled
//! row (used by lists, combos and menus) with separate inactive/active color
//! sets. The image/symbol-icon variants are deferred; this covers the text
//! selectable.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const widget = @import("widget.zig");
const button = @import("button.zig");
const text_widget = @import("text.zig");

const Rect = math.Rect;
const Color = color.Color;
const StyleSelectable = style_mod.StyleSelectable;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;

fn drawSelectable(out: *CommandBuffer, state: States, style: *const StyleSelectable, active: bool, bounds: Rect, string: []const u8, alignment: Align, font: *const UserFont) !void {
    const bg = if (!active)
        (if (state.actived) style.pressed else if (state.hover) style.hover else style.normal)
    else
        (if (state.actived) style.pressed_active else if (state.hover) style.hover_active else style.normal_active);

    var fg = if (!active)
        (if (state.actived) style.text_pressed else if (state.hover) style.text_hover else style.text_normal)
    else
        (if (state.actived) style.text_pressed_active else if (state.hover) style.text_hover_active else style.text_normal_active);
    fg = fg.factor(style.color_factor);

    var text_bg: Color = .{ .a = 0 };
    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white.factor(style.color_factor)),
        .color => |col| {
            text_bg = col;
            try out.fillRect(bounds, style.rounding, col);
        },
    }
    try text_widget.widgetText(out, bounds, string, alignment, style.padding, text_bg, fg, font);
}

/// Lay out, interact with and draw a text selectable; toggles `value`, returns
/// whether it changed (`nk_do_selectable`).
pub fn doSelectable(state: *States, out: *CommandBuffer, bounds: Rect, str: []const u8, alignment: Align, value: *bool, style: *const StyleSelectable, in: ?*const Input, font: *const UserFont) !bool {
    const old = value.*;
    const touch = Rect{
        .x = bounds.x - style.touch_padding.x,
        .y = bounds.y - style.touch_padding.y,
        .w = bounds.w + style.touch_padding.x * 2,
        .h = bounds.h + style.touch_padding.y * 2,
    };
    if (button.behavior(state, touch, in, .default)) value.* = !value.*;

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawSelectable(out, state.*, style, value.*, bounds, str, alignment, font);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return old != value.*;
}

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font = UserFont{ .height = 13, .width = &testWidth };

test "selectable toggles on click" {
    const style = style_mod.Style.default().selectable;
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 20, .y = 10 };
    in.button(.left, 20, 10, true);

    var state: States = .{};
    var value = false;
    const changed = try doSelectable(&state, &buf, Rect.init(0, 0, 100, 20), "item", Align.text_left, &value, &style, &in, &test_font);
    try std.testing.expect(changed);
    try std.testing.expect(value);
}
