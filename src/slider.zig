//! Slider widget, ported from `nuklear_slider.c`.
//!
//! The optional inc/dec buttons (`style.show_buttons`, off by default) are
//! deferred until the symbol-button widget exists; the core drag/value logic is
//! complete.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const widget = @import("widget.zig");

const Rect = math.Rect;
const Color = color.Color;
const StyleSlider = style_mod.StyleSlider;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;

fn sliderBehavior(state: *States, logical_cursor: *Rect, visual_cursor: *Rect, in: ?*Input, bounds: Rect, slider_min: f32, slider_max: f32, value_in: f32, slider_step: f32, slider_steps: f32) f32 {
    var slider_value = value_in;
    state.reset();

    const left_down = if (in) |i| i.mouse.buttons[@intFromEnum(input_mod.Button.left)].down else false;
    const in_cursor = if (in) |i| i.hasMouseClickDownInRect(.left, visual_cursor.*, true) else false;

    if (left_down and in_cursor) {
        const i = in.?;
        const d = i.mouse.pos.x - (visual_cursor.x + visual_cursor.w * 0.5);
        const pxstep = bounds.w / slider_steps;
        state.* = States.active;
        if (@abs(d) >= pxstep) {
            const steps = @trunc(@abs(d) / pxstep);
            slider_value += if (d > 0) slider_step * steps else -(slider_step * steps);
            slider_value = std.math.clamp(slider_value, slider_min, slider_max);
            const ratio = (slider_value - slider_min) / slider_step;
            logical_cursor.x = bounds.x + logical_cursor.w * ratio;
            i.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.x = logical_cursor.x;
        }
    }

    if (in) |i| {
        if (i.isMouseHoveringRect(bounds)) state.* = States.hovered;
        if (state.hover and !i.isMousePrevHoveringRect(bounds)) {
            state.entered = true;
        } else if (i.isMousePrevHoveringRect(bounds)) {
            state.left = true;
        }
    }
    return slider_value;
}

fn drawSlider(out: *CommandBuffer, state: States, style: *const StyleSlider, bounds: Rect, visual_cursor: Rect) !void {
    const bg = if (state.actived) style.active else if (state.hover) style.hover else style.normal;
    const bar_color = if (state.actived) style.bar_active else if (state.hover) style.bar_hover else style.bar_normal;
    const cursor = if (state.actived) style.cursor_active else if (state.hover) style.cursor_hover else style.cursor_normal;

    const bar: Rect = .{
        .x = bounds.x,
        .y = bounds.y + bounds.h * 0.5 - style.bar_height * 0.5,
        .w = bounds.w,
        .h = style.bar_height,
    };
    const fill: Rect = .{
        .x = bar.x,
        .y = bar.y,
        .w = visual_cursor.x + 0.5 * visual_cursor.w - bar.x,
        .h = bar.h,
    };

    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white.factor(style.color_factor)),
        .color => |col| {
            try out.fillRect(bounds, style.rounding, col.factor(style.color_factor));
            try out.strokeRect(bounds, style.rounding, style.border, style.border_color.factor(style.color_factor));
        },
    }

    try out.fillRect(bar, style.rounding, bar_color.factor(style.color_factor));
    try out.fillRect(fill, style.rounding, style.bar_filled.factor(style.color_factor));

    switch (cursor) {
        .image => |img| try out.drawImage(visual_cursor, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(visual_cursor, sl, Color.white.factor(style.color_factor)),
        .color => |col| try out.fillCircle(visual_cursor, col.factor(style.color_factor)),
    }
}

/// Lay out, interact with and draw a slider, returning the new value
/// (`nk_do_slider`).
pub fn doSlider(state: *States, out: *CommandBuffer, bounds_in: Rect, min: f32, val: f32, max: f32, step: f32, style: *const StyleSlider, in: ?*Input, font: *const UserFont) !f32 {
    _ = font;
    var bounds = bounds_in;
    bounds.x += style.padding.x;
    bounds.y += style.padding.y;
    bounds.h = @max(bounds.h, 2 * style.padding.y);
    bounds.w = @max(bounds.w, 2 * style.padding.x + style.cursor_size.x);
    bounds.w -= 2 * style.padding.x;
    bounds.h -= 2 * style.padding.y;

    // NOTE: style.show_buttons (inc/dec) deferred until the symbol button widget.

    const slider_max = @max(min, max);
    const slider_min = @min(min, max);
    const slider_value = std.math.clamp(val, slider_min, slider_max);
    const slider_range = slider_max - slider_min;
    const slider_steps = slider_range / step;
    const cursor_offset = (slider_value - slider_min) / step;

    var logical_cursor: Rect = .{
        .h = bounds.h,
        .w = bounds.w / slider_steps,
        .y = bounds.y,
    };
    logical_cursor.x = bounds.x + logical_cursor.w * cursor_offset;

    var visual_cursor: Rect = .{
        .h = style.cursor_size.y,
        .w = style.cursor_size.x,
        .y = bounds.y + bounds.h * 0.5 - style.cursor_size.y * 0.5,
    };
    visual_cursor.x = logical_cursor.x - visual_cursor.w * 0.5;

    const result = sliderBehavior(state, &logical_cursor, &visual_cursor, in, bounds, slider_min, slider_max, slider_value, step, slider_steps);
    visual_cursor.x = logical_cursor.x - visual_cursor.w * 0.5;

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawSlider(out, state.*, style, bounds, visual_cursor);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return result;
}

// --- tests ---------------------------------------------------------------

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font: UserFont = .{ .height = 13, .width = &testWidth };

test "slider clamps value and is stable without input" {
    const style = style_mod.Style.default().slider;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    var state: States = .{};
    const v = try doSlider(&state, &buf, .init(0, 0, 200, 20), 0, 200, 10, 1, &style, null, &test_font);
    try std.testing.expectEqual(@as(f32, 10), v); // clamped to max
}

test "dragging the slider cursor changes the value" {
    const style = style_mod.Style.default().slider;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    // value 0 at the far left; press on the cursor then move right
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 8, .y = 10 };
    in.button(.left, 8, 10, true); // press near the left cursor
    in.mouse.pos = .{ .x = 150, .y = 10 }; // drag right
    in.mouse.delta = .{ .x = 142, .y = 0 };

    var state: States = .{};
    const v = try doSlider(&state, &buf, .init(0, 0, 200, 20), 0, 0, 10, 1, &style, &in, &test_font);
    try std.testing.expect(v > 0);
}
