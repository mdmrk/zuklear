//! Checkbox / radio (option) widgets, ported from `nuklear_toggle.c`.
//! The checkbox draws a square selector + square cursor; the option draws a
//! circular selector + circular cursor. Otherwise they share all logic.

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
const Vec2 = math.Vec2;
const Color = color.Color;
const StyleToggle = style_mod.StyleToggle;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;

pub const ToggleType = enum { check, option };

fn toggleBehavior(in: ?*const Input, select: Rect, state: *States, active_in: bool) bool {
    var active = active_in;
    state.reset();
    if (button.behavior(state, select, in, .default)) {
        state.* = States.active;
        active = !active;
    }
    const i = in orelse return active;
    if (state.hover and !i.isMousePrevHoveringRect(select)) {
        state.entered = true;
    } else if (i.isMousePrevHoveringRect(select)) {
        state.left = true;
    }
    return active;
}

fn drawToggle(out: *CommandBuffer, t: ToggleType, state: States, style: *const StyleToggle, active: bool, label: Rect, selector: Rect, cursor: Rect, string: []const u8, font: *const UserFont, text_alignment: Align) !void {
    const bg = if (state.hover or state.actived) style.hover else style.normal;
    const cur = if (state.hover or state.actived) style.cursor_hover else style.cursor_normal;
    var txt = if (state.hover)
        style.text_hover
    else if (state.actived)
        style.text_active
    else
        style.text_normal;
    txt = txt.factor(style.color_factor);

    try text_widget.widgetText(out, label, string, text_alignment, .init(0, 0), style.text_background, txt, font);

    // selector background
    switch (bg) {
        .color => |col| {
            const border = style.border_color.factor(style.color_factor);
            const fill = col.factor(style.color_factor);
            switch (t) {
                .check => {
                    try out.fillRect(selector, 0, border);
                    try out.fillRect(selector.shrink(style.border), 0, fill);
                },
                .option => {
                    try out.fillCircle(selector, border);
                    try out.fillCircle(selector.shrink(style.border), fill);
                },
            }
        },
        .image => |img| try out.drawImage(selector, img, Color.white.factor(style.color_factor)),
        .nine_slice => |sl| try out.drawNineSlice(selector, sl, Color.white.factor(style.color_factor)),
    }

    // cursor (the check mark / filled dot) when active
    if (active) {
        switch (cur) {
            .image => |img| try out.drawImage(cursor, img, Color.white.factor(style.color_factor)),
            .nine_slice => |sl| try out.drawNineSlice(cursor, sl, Color.white.factor(style.color_factor)),
            .color => |col| switch (t) {
                .check => try out.fillRect(cursor, 0, col),
                .option => try out.fillCircle(cursor, col),
            },
        }
    }
}

/// Lay out and draw a toggle; updates `active` and returns whether it changed
/// (`nk_do_toggle`).
pub fn doToggle(state: *States, out: *CommandBuffer, r_in: Rect, active: *bool, str: []const u8, t: ToggleType, style: *const StyleToggle, in: ?*const Input, font: *const UserFont, widget_alignment: Align, text_alignment: Align) !bool {
    var r = r_in;
    r.w = @max(r.w, font.height + 2 * style.padding.x);
    r.h = @max(r.h, font.height + 2 * style.padding.y);

    const bounds: Rect = .{
        .x = r.x - style.touch_padding.x,
        .y = r.y - style.touch_padding.y,
        .w = r.w + 2 * style.touch_padding.x,
        .h = r.h + 2 * style.touch_padding.y,
    };

    var select: Rect = .{ .w = font.height, .h = font.height };
    var label: Rect = .{};
    if (widget_alignment.right) {
        select.x = r.x + r.w - font.height;
        label.x = r.x;
        label.w = r.w - select.w - style.spacing * 2;
    } else if (widget_alignment.centered) {
        select.x = r.x + (r.w - select.w) / 2;
        label.x = r.x;
        label.w = (r.w - select.w - style.spacing * 2) / 2;
    } else { // left
        select.x = r.x;
        label.x = select.x + select.w + style.spacing;
        label.w = @max(r.x + r.w, label.x) - label.x;
    }

    if (widget_alignment.top) {
        select.y = r.y;
    } else if (widget_alignment.bottom) {
        select.y = r.y + r.h - select.h - 2 * style.padding.y;
    } else { // middle
        select.y = r.y + r.h / 2.0 - select.h / 2.0;
    }
    label.y = select.y;
    label.h = select.w;

    const cursor: Rect = .{
        .x = select.x + style.padding.x + style.border,
        .y = select.y + style.padding.y + style.border,
        .w = select.w - (2 * style.padding.x + 2 * style.border),
        .h = select.h - (2 * style.padding.y + 2 * style.border),
    };

    const was_active = active.*;
    active.* = toggleBehavior(in, bounds, state, active.*);

    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawToggle(out, t, state.*, style, active.*, label, select, cursor, str, font, text_alignment);
    if (style.draw_end) |cb| cb(out, style.userdata);

    return was_active != active.*;
}

// --- tests ---------------------------------------------------------------

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font: UserFont = .{ .height = 13, .width = &testWidth };

test "checkbox toggles on click" {
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 6, .y = 6 }; // over the selector at the left
    in.button(.left, 6, 6, true);

    const style = style_mod.Style.default().checkbox;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    var state: States = .{};
    var active = false;
    const changed = try doToggle(&state, &buf, .init(0, 0, 120, 20), &active, "on", .check, &style, &in, &test_font, Align.text_left, Align.text_left);
    try std.testing.expect(changed);
    try std.testing.expect(active);
}

test "checkbox unchanged when not clicked" {
    var in: Input = .{};
    in.begin();
    in.mouse.pos = .{ .x = 500, .y = 500 };

    const style = style_mod.Style.default().checkbox;
    var buf: CommandBuffer = .init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    var state: States = .{};
    var active = true;
    const changed = try doToggle(&state, &buf, .init(0, 0, 120, 20), &active, "on", .check, &style, &in, &test_font, Align.text_left, Align.text_left);
    try std.testing.expect(!changed);
    try std.testing.expect(active);
}
