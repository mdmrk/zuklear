//! Scrollbar widget, ported from `nuklear_scrollbar.c`. Drives the window/group
//! scroll offsets: drag the cursor, click the empty track to page, mouse-wheel,
//! or use the optional inc/dec buttons. Vertical and horizontal variants.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const widget = @import("widget.zig");
const button = @import("button.zig");

const Rect = math.Rect;
const Color = color.Color;
const StyleScrollbar = style_mod.StyleScrollbar;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;

pub const Orientation = enum { vertical, horizontal };

fn scrollbarBehavior(state: *States, in: ?*Input, has_scrolling: bool, scroll: Rect, cursor: Rect, empty0: Rect, empty1: Rect, offset_in: f32, target: f32, scroll_step: f32, o: Orientation) f32 {
    var scroll_offset = offset_in;
    state.reset();
    const i = in orelse return scroll_offset;

    const left_down = i.mouse.buttons[@intFromEnum(input_mod.Button.left)].down;
    const left_clicked = i.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked != 0;
    const click_in_cursor = i.hasMouseClickDownInRect(.left, cursor, true);
    if (i.isMouseHoveringRect(scroll)) state.* = States.hovered;

    const scroll_delta = if (o == .vertical) i.mouse.scroll_delta.y else i.mouse.scroll_delta.x;
    var ws: States = .{};

    if (left_down and click_in_cursor and !left_clicked) {
        state.* = States.active;
        if (o == .vertical) {
            const delta = (i.mouse.delta.y / scroll.h) * target;
            scroll_offset = std.math.clamp(scroll_offset + delta, 0, target - scroll.h);
            const cursor_y = scroll.y + (scroll_offset / target) * scroll.h;
            i.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.y = cursor_y + cursor.h / 2.0;
        } else {
            const delta = (i.mouse.delta.x / scroll.w) * target;
            scroll_offset = std.math.clamp(scroll_offset + delta, 0, target - scroll.w);
            const cursor_x = scroll.x + (scroll_offset / target) * scroll.w;
            i.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.x = cursor_x + cursor.w / 2.0;
        }
    } else if ((i.isKeyPressed(.scroll_up) and o == .vertical and has_scrolling) or button.behavior(&ws, empty0, in, .default)) {
        scroll_offset = @max(0, scroll_offset - (if (o == .vertical) scroll.h else scroll.w));
    } else if ((i.isKeyPressed(.scroll_down) and o == .vertical and has_scrolling) or button.behavior(&ws, empty1, in, .default)) {
        scroll_offset = @min(scroll_offset + (if (o == .vertical) scroll.h else scroll.w), target - (if (o == .vertical) scroll.h else scroll.w));
    } else if (has_scrolling) {
        if (scroll_delta != 0) {
            scroll_offset = scroll_offset + scroll_step * (-scroll_delta);
            scroll_offset = std.math.clamp(scroll_offset, 0, target - (if (o == .vertical) scroll.h else scroll.w));
        } else if (i.isKeyPressed(.scroll_start)) {
            if (o == .vertical) scroll_offset = 0;
        } else if (i.isKeyPressed(.scroll_end)) {
            if (o == .vertical) scroll_offset = target - scroll.h;
        }
    }

    if (state.hover and !i.isMousePrevHoveringRect(scroll)) {
        state.entered = true;
    } else if (i.isMousePrevHoveringRect(scroll)) {
        state.left = true;
    }
    return scroll_offset;
}

fn drawScrollbar(out: *CommandBuffer, state: States, style: *const StyleScrollbar, bounds: Rect, scroll: Rect) !void {
    const bg = if (state.actived) style.active else if (state.hover) style.hover else style.normal;
    const cursor = if (state.actived) style.cursor_active else if (state.hover) style.cursor_hover else style.cursor_normal;

    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white),
        .color => |col| {
            try out.fillRect(bounds, style.rounding, col);
            try out.strokeRect(bounds, style.rounding, style.border, style.border_color);
        },
    }
    switch (cursor) {
        .image => |img| try out.drawImage(scroll, img, Color.white),
        .nine_slice => |sl| try out.drawNineSlice(scroll, sl, Color.white),
        .color => |col| {
            try out.fillRect(scroll, style.rounding_cursor, col);
            try out.strokeRect(scroll, style.rounding_cursor, style.border_cursor, style.cursor_border_color);
        },
    }
}

/// Vertical scrollbar; returns the new offset (`nk_do_scrollbarv`).
pub fn doScrollbarV(state: *States, out: *CommandBuffer, scroll_in: Rect, has_scrolling: bool, offset_in: f32, target: f32, step: f32, button_pixel_inc: f32, style: *const StyleScrollbar, in: ?*Input, font: *const UserFont) !f32 {
    var scroll = scroll_in;
    var offset = offset_in;
    scroll.w = @max(scroll.w, 1);
    scroll.h = @max(scroll.h, 0);
    if (target <= scroll.h) return 0;

    var scroll_step: f32 = undefined;
    if (style.show_buttons) {
        var b = Rect{ .x = scroll.x, .w = scroll.w, .h = scroll.w };
        const scroll_h = @max(scroll.h - 2 * b.h, 0);
        scroll_step = @min(step, button_pixel_inc);

        b.y = scroll.y;
        if (try button.doButtonSymbol(state, out, b, style.dec_symbol, .repeater, &style.dec_button, in, font)) offset -= scroll_step;
        b.y = scroll.y + scroll.h - b.h;
        if (try button.doButtonSymbol(state, out, b, style.inc_symbol, .repeater, &style.inc_button, in, font)) offset += scroll_step;
        scroll.y += b.h;
        scroll.h = scroll_h;
    }

    scroll_step = @min(step, scroll.h);
    var scroll_offset = std.math.clamp(offset, 0, target - scroll.h);
    const scroll_ratio = scroll.h / target;
    var scroll_off = scroll_offset / target;

    var cursor = Rect{
        .h = @max(scroll_ratio * scroll.h - (2 * style.border + 2 * style.padding.y), 0),
        .y = scroll.y + scroll_off * scroll.h + style.border + style.padding.y,
        .w = scroll.w - (2 * style.border + 2 * style.padding.x),
        .x = scroll.x + style.border + style.padding.x,
    };

    const empty_north = Rect{ .x = scroll.x, .y = scroll.y, .w = scroll.w, .h = @max(cursor.y - scroll.y, 0) };
    const empty_south = Rect{ .x = scroll.x, .y = cursor.y + cursor.h, .w = scroll.w, .h = @max((scroll.y + scroll.h) - (cursor.y + cursor.h), 0) };

    scroll_offset = scrollbarBehavior(state, in, has_scrolling, scroll, cursor, empty_north, empty_south, scroll_offset, target, scroll_step, .vertical);
    scroll_off = scroll_offset / target;
    cursor.y = scroll.y + scroll_off * scroll.h + style.border_cursor + style.padding.y;

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawScrollbar(out, state.*, style, scroll, cursor);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return scroll_offset;
}

/// Horizontal scrollbar; returns the new offset (`nk_do_scrollbarh`).
pub fn doScrollbarH(state: *States, out: *CommandBuffer, scroll_in: Rect, has_scrolling: bool, offset_in: f32, target: f32, step: f32, button_pixel_inc: f32, style: *const StyleScrollbar, in: ?*Input, font: *const UserFont) !f32 {
    var scroll = scroll_in;
    var offset = offset_in;
    scroll.h = @max(scroll.h, 1);
    scroll.w = @max(scroll.w, 2 * scroll.h);
    if (target <= scroll.w) return 0;

    var scroll_step: f32 = undefined;
    if (style.show_buttons) {
        var b = Rect{ .y = scroll.y, .w = scroll.h, .h = scroll.h };
        const scroll_w = scroll.w - 2 * b.w;
        scroll_step = @min(step, button_pixel_inc);

        b.x = scroll.x;
        if (try button.doButtonSymbol(state, out, b, style.dec_symbol, .repeater, &style.dec_button, in, font)) offset -= scroll_step;
        b.x = scroll.x + scroll.w - b.w;
        if (try button.doButtonSymbol(state, out, b, style.inc_symbol, .repeater, &style.inc_button, in, font)) offset += scroll_step;
        scroll.x += b.w;
        scroll.w = scroll_w;
    }

    scroll_step = @min(step, scroll.w);
    var scroll_offset = std.math.clamp(offset, 0, target - scroll.w);
    const scroll_ratio = scroll.w / target;
    var scroll_off = scroll_offset / target;

    var cursor = Rect{
        .w = @max(scroll_ratio * scroll.w - (2 * style.border + 2 * style.padding.x), 0),
        .x = scroll.x + scroll_off * scroll.w + style.border + style.padding.x,
        .h = scroll.h - (2 * style.border + 2 * style.padding.y),
        .y = scroll.y + style.border + style.padding.y,
    };

    const empty_west = Rect{ .x = scroll.x, .y = scroll.y, .w = @max(cursor.x - scroll.x, 0), .h = scroll.h };
    const empty_east = Rect{ .x = cursor.x + cursor.w, .y = scroll.y, .w = @max((scroll.x + scroll.w) - (cursor.x + cursor.w), 0), .h = scroll.h };

    scroll_offset = scrollbarBehavior(state, in, has_scrolling, scroll, cursor, empty_west, empty_east, scroll_offset, target, scroll_step, .horizontal);
    scroll_off = scroll_offset / target;
    cursor.x = scroll.x + scroll_off * scroll.w + style.border + style.padding.x;

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawScrollbar(out, state.*, style, scroll, cursor);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return scroll_offset;
}

// --- tests ---------------------------------------------------------------

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font = UserFont{ .height = 13, .width = &testWidth };

test "vertical scrollbar hidden when content fits" {
    const style = style_mod.Style.default().scrollv;
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;
    var state: States = .{};
    // target (50) <= height (100): nothing to scroll
    const off = try doScrollbarV(&state, &buf, Rect.init(0, 0, 10, 100), false, 0, 50, 10, 1, &style, null, &test_font);
    try std.testing.expectEqual(@as(f32, 0), off);
    try std.testing.expectEqual(@as(usize, 0), buf.items().len);
}

test "mouse wheel advances the scroll offset" {
    const style = style_mod.Style.default().scrollv;
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 5, .y = 50 }; // hover the scrollbar
    in.scroll(.{ .x = 0, .y = -1 }); // wheel down

    var state: States = .{};
    const off = try doScrollbarV(&state, &buf, Rect.init(0, 0, 10, 100), true, 0, 400, 30, 3, &style, &in, &test_font);
    try std.testing.expect(off > 0);
}
