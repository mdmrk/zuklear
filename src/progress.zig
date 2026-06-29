//! Progress bar widget, ported from `nuklear_progress.c`. When `modifiable`,
//! dragging sets the value like a slider.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const widget = @import("widget.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Color = color.Color;
const StyleProgress = style_mod.StyleProgress;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const States = widget.States;

fn progressBehavior(state: *States, in: ?*Input, r: Rect, cursor: Rect, max: usize, value_in: usize, modifiable: bool) usize {
    var value = value_in;
    state.reset();
    const i = in orelse return value;
    if (!modifiable) return value;

    const left_down = i.mouse.buttons[@intFromEnum(input_mod.Button.left)].down;
    const in_cursor = i.hasMouseClickDownInRect(.left, cursor, true);
    if (i.isMouseHoveringRect(r)) state.* = States.hovered;

    if (left_down and in_cursor) {
        const max_f: f32 = @floatFromInt(max);
        const ratio = @max(0, i.mouse.pos.x - cursor.x) / cursor.w;
        value = @intFromFloat(std.math.clamp(max_f * ratio, 0, max_f));
        i.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.x = cursor.x + cursor.w / 2.0;
        state.actived = true;
        state.modified = true;
    }

    if (state.hover and !i.isMousePrevHoveringRect(r)) {
        state.entered = true;
    } else if (i.isMousePrevHoveringRect(r)) {
        state.left = true;
    }
    return value;
}

fn drawProgress(out: *CommandBuffer, state: States, style: *const StyleProgress, bounds: Rect, scursor: Rect) !void {
    const bg = if (state.actived) style.active else if (state.hover) style.hover else style.normal;
    const cursor = if (state.actived) style.cursor_active else if (state.hover) style.cursor_hover else style.cursor_normal;

    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white.factor(style.color_factor)),
        .color => |col| {
            try out.fillRect(bounds, style.rounding, col.factor(style.color_factor));
            try out.strokeRect(bounds, style.rounding, style.border, style.border_color.factor(style.color_factor));
        },
    }
    switch (cursor) {
        .image => |img| try out.drawImage(scursor, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(scursor, sl, Color.white.factor(style.color_factor)),
        .color => |col| {
            try out.fillRect(scursor, style.rounding, col.factor(style.color_factor));
            try out.strokeRect(scursor, style.rounding, style.border, style.border_color.factor(style.color_factor));
        },
    }
}

/// Lay out, interact with and draw a progress bar, returning the value
/// (`nk_do_progress`).
pub fn doProgress(state: *States, out: *CommandBuffer, bounds: Rect, value: usize, max: usize, modifiable: bool, style: *const StyleProgress, in: ?*Input) !usize {
    var cursor = bounds.pad(.init(style.padding.x + style.border, style.padding.y + style.border));
    const prog_scale: f32 = if (max == 0) 0 else @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max));

    const prog_value = progressBehavior(state, in, bounds, cursor, max, @min(value, max), modifiable);
    cursor.w = cursor.w * prog_scale;

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawProgress(out, state.*, style, bounds, cursor);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return prog_value;
}

test "progress reports value clamped to max" {
    const style = style_mod.Style.default().progress;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var state: States = .{};
    const v = try doProgress(&state, &buf, .init(0, 0, 200, 20), 150, 100, false, &style, null);
    try std.testing.expectEqual(@as(usize, 100), v);
}

test "non-modifiable progress ignores input" {
    const style = style_mod.Style.default().progress;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 100, .y = 10 };
    in.button(.left, 100, 10, true);
    var state: States = .{};
    const v = try doProgress(&state, &buf, .init(0, 0, 200, 20), 30, 100, false, &style, &in);
    try std.testing.expectEqual(@as(usize, 30), v);
}
