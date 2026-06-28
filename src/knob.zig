//! Rotary knob widget, ported from `nuklear_knob.c`. Click-drag around the
//! center, scroll, or arrow keys adjust the value; a cursor line shows the
//! angle. `zero_direction` chooses where 0 points; `dead_zone_percent` reserves
//! a gap at the bottom of the sweep.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const widget = @import("widget.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Heading = math.Heading;
const Color = color.Color;
const StyleKnob = style_mod.StyleKnob;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const States = widget.States;

const pi: f32 = std.math.pi;
const pi_half: f32 = pi / 2.0;

fn boolf(b: bool) f32 {
    return if (b) 1.0 else 0.0;
}

fn knobBehavior(state: *States, in: ?*Input, bounds: Rect, knob_min: f32, knob_max: f32, value_in: f32, knob_step: f32, knob_steps: f32, zero_direction: Heading, dead_zone_percent: f32) f32 {
    var knob_value = value_in;
    const origin = Vec2.init(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    state.reset();

    const i = in orelse return knob_value;

    if (i.mouse.buttons[@intFromEnum(input_mod.Button.left)].down and i.hasMouseClickDownInRect(.left, bounds, true)) {
        const direction_rads = [4]f32{ pi * 2.5, pi * 2.0, pi * 1.5, pi };
        state.* = States.active;
        var angle = std.math.atan2(i.mouse.pos.y - origin.y, i.mouse.pos.x - origin.x) + direction_rads[@intFromEnum(zero_direction)];
        angle -= if (angle > pi * 2) pi * 3 else pi;
        angle *= 1.0 / (1.0 - dead_zone_percent);
        angle = std.math.clamp(angle, -pi, pi);
        angle = (angle + pi) / (pi * 2);
        const steps_i: i32 = @intFromFloat(angle * knob_steps + knob_step / 2);
        knob_value = knob_min + @as(f32, @floatFromInt(steps_i)) * knob_step;
        knob_value = std.math.clamp(knob_value, knob_min, knob_max);
    }

    if (i.isMouseHoveringRect(bounds)) {
        state.hover = true;
        state.modified = true;
        const up = &i.keyboard.keys[@intFromEnum(input_mod.Key.up)];
        const down = &i.keyboard.keys[@intFromEnum(input_mod.Key.down)];
        if (i.mouse.scroll_delta.y > 0 or (up.down and up.clicked != 0)) knob_value += knob_step;
        if (i.mouse.scroll_delta.y < 0 or (down.down and down.clicked != 0)) knob_value -= knob_step;
        i.mouse.scroll_delta.y = 0; // knob eats scrolling
        knob_value = std.math.clamp(knob_value, knob_min, knob_max);
    }

    if (state.hover and !i.isMousePrevHoveringRect(bounds)) {
        state.entered = true;
    } else if (i.isMousePrevHoveringRect(bounds)) {
        state.left = true;
    }
    return knob_value;
}

fn drawKnob(out: *CommandBuffer, state: States, style: *const StyleKnob, bounds: Rect, min: f32, value: f32, max: f32, zero_direction: Heading, dead_zone_percent: f32) !void {
    const bg = if (state.actived) style.active else if (state.hover) style.hover else style.normal;
    const knob_color = if (state.actived) style.knob_active else if (state.hover) style.knob_hover else style.knob_normal;
    const cursor = if (state.actived) style.cursor_active else if (state.hover) style.cursor_hover else style.cursor_normal;

    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white.factor(style.color_factor)),
        .color => |col| {
            try out.fillRect(bounds, 0, col.factor(style.color_factor));
            try out.strokeRect(bounds, 0, style.border, style.border_color.factor(style.color_factor));
        },
    }

    try out.fillCircle(bounds, knob_color.factor(style.color_factor));
    if (style.knob_border > 0) {
        var bb = bounds;
        bb.x += style.knob_border / 2;
        bb.y += style.knob_border / 2;
        bb.w -= style.knob_border;
        bb.h -= style.knob_border;
        try out.strokeCircle(bb, style.knob_border, style.knob_border_color.factor(style.color_factor));
    }

    const half = bounds.w / 2;
    const alive = 1.0 - dead_zone_percent;
    const direction_rads = [4]f32{ pi * 1.5, 0.0, pi * 0.5, pi };
    var angle = (value - min) / (max - min);
    angle = angle * alive + dead_zone_percent / 2;
    angle *= pi * 2;
    angle += direction_rads[@intFromEnum(zero_direction)];
    if (angle > pi * 2) angle -= pi * 2;

    var start = Vec2.init(bounds.x + half + boolf(angle > pi), bounds.y + half + boolf(angle < pi_half or angle > pi * 1.5));
    const end = Vec2.init(start.x + half * std.math.cos(angle), start.y + half * std.math.sin(angle));
    start.x = (start.x + end.x) / 2;
    start.y = (start.y + end.y) / 2;
    try out.strokeLine(start.x, start.y, end.x, end.y, style.cursor_width, cursor.factor(style.color_factor));
}

/// Lay out, interact with and draw a knob, returning the value (`nk_do_knob`).
pub fn doKnob(state: *States, out: *CommandBuffer, bounds_in: Rect, min: f32, val: f32, max: f32, step: f32, zero_direction: Heading, dead_zone_percent: f32, style: *const StyleKnob, in: ?*Input) !f32 {
    var bounds = bounds_in;
    bounds.y += style.padding.y;
    bounds.x += style.padding.x;
    bounds.h = @max(bounds.h, 2 * style.padding.y);
    bounds.w = @max(bounds.w, 2 * style.padding.x);
    bounds.w -= 2 * style.padding.x;
    bounds.h -= 2 * style.padding.y;
    if (bounds.h < bounds.w) {
        bounds.x += (bounds.w - bounds.h) / 2;
        bounds.w = bounds.h;
    }

    const knob_max = @max(min, max);
    const knob_min = @min(min, max);
    const knob_value = std.math.clamp(val, knob_min, knob_max);
    const knob_steps = (knob_max - knob_min) / step;

    const result = knobBehavior(state, in, bounds, knob_min, knob_max, knob_value, step, knob_steps, zero_direction, dead_zone_percent);

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawKnob(out, state.*, style, bounds, knob_min, result, knob_max, zero_direction, dead_zone_percent);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return result;
}

test "knob is stable without input and clamps" {
    const style = style_mod.Style.default().knob;
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var state: States = .{};
    const v = try doKnob(&state, &buf, Rect.init(0, 0, 40, 40), 0, 5, 10, 1, .up, 0.2, &style, null);
    try std.testing.expectEqual(@as(f32, 5), v);
}

test "scrolling over the knob changes the value" {
    const style = style_mod.Style.default().knob;
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 20, .y = 20 }; // over the knob center
    in.scroll(.{ .x = 0, .y = 1 }); // wheel up
    var state: States = .{};
    const v = try doKnob(&state, &buf, Rect.init(0, 0, 40, 40), 0, 5, 10, 1, .up, 0.2, &style, &in);
    try std.testing.expectEqual(@as(f32, 6), v);
}
