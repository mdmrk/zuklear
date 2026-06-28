//! Button widget, ported from `nuklear_button.c`.
//!
//! These are the low-level, pure routines (no `Context`): behavior detection,
//! background drawing and the text-button composition. `Context.buttonLabel`
//! and friends wrap them after allocating a layout slot.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const widget = @import("widget.zig");
const text_widget = @import("text.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Color = color.Color;
const StyleButton = style_mod.StyleButton;
const StyleItem = style_mod.StyleItem;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;
const States = widget.States;
const ButtonBehavior = widget.ButtonBehavior;

/// Resolve hover/active/click state for a button rect (`nk_button_behavior`).
pub fn behavior(state: *States, r: Rect, in: ?*const Input, b: ButtonBehavior) bool {
    var ret = false;
    state.reset();
    const i = in orelse return false;

    if (i.isMouseHoveringRect(r)) {
        state.* = States.hovered;
        if (i.isMouseDown(.left)) state.* = States.active;
        if (i.hasMouseClickInButtonRect(.left, r)) {
            ret = if (b != .default) i.isMouseDown(.left) else i.isMousePressed(.left);
        }
    }

    if (state.hover and !i.isMousePrevHoveringRect(r)) {
        state.entered = true;
    } else if (i.isMousePrevHoveringRect(r)) {
        state.left = true;
    }
    return ret;
}

/// Compute the content rect and run behavior on the (touch-padded) bounds
/// (`nk_do_button`).
pub fn doButton(state: *States, r: Rect, style: *const StyleButton, in: ?*const Input, b: ButtonBehavior) struct { clicked: bool, content: Rect } {
    const inset = style.padding.x + style.border + style.rounding;
    const inset_y = style.padding.y + style.border + style.rounding;
    const content = Rect{
        .x = r.x + inset,
        .y = r.y + inset_y,
        .w = r.w - 2 * inset,
        .h = r.h - 2 * inset_y,
    };
    const touch = Rect{
        .x = r.x - style.touch_padding.x,
        .y = r.y - style.touch_padding.y,
        .w = r.w + 2 * style.touch_padding.x,
        .h = r.h + 2 * style.touch_padding.y,
    };
    return .{ .clicked = behavior(state, touch, in, b), .content = content };
}

/// Fill the button background for the current state, returning the chosen item
/// (`nk_draw_button`).
pub fn drawButton(out: *CommandBuffer, bounds: Rect, state: States, style: *const StyleButton) !StyleItem {
    const bg = if (state.hover)
        style.hover
    else if (state.actived)
        style.active
    else
        style.normal;

    switch (bg) {
        .image => |img| try out.drawImage(bounds, img, Color.white.factor(style.color_factor_background)),
        .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white.factor(style.color_factor_background)),
        .color => |col| {
            try out.fillRect(bounds, style.rounding, col.factor(style.color_factor_background));
            try out.strokeRect(bounds, style.rounding, style.border, style.border_color.factor(style.color_factor_background));
        },
    }
    return bg;
}

fn drawButtonText(out: *CommandBuffer, bounds: Rect, content: Rect, state: States, style: *const StyleButton, txt: []const u8, text_alignment: Align, font: *const UserFont) !void {
    const bg = try drawButton(out, bounds, state, style);
    const text_bg = switch (bg) {
        .color => |col| col,
        else => style.text_background,
    };
    var fg = if (state.hover)
        style.text_hover
    else if (state.actived)
        style.text_active
    else
        style.text_normal;
    fg = fg.factor(style.color_factor_text);

    try text_widget.widgetText(out, content, txt, text_alignment, Vec2.init(0, 0), text_bg, fg, font);
}

/// Draw a text button and report whether it was clicked (`nk_do_button_text`).
pub fn doButtonText(state: *States, out: *CommandBuffer, bounds: Rect, string: []const u8, text_alignment: Align, b: ButtonBehavior, style: *const StyleButton, in: ?*const Input, font: *const UserFont) !bool {
    const r = doButton(state, bounds, style, in, b);
    if (style.draw_begin) |cb| cb(out, style.userdata);
    try drawButtonText(out, bounds, r.content, state.*, style, string, text_alignment, font);
    if (style.draw_end) |cb| cb(out, style.userdata);
    return r.clicked;
}

// --- tests ---------------------------------------------------------------

fn testWidth(_: @import("handle.zig").Handle, _: f32, t: []const u8) f32 {
    return @as(f32, @floatFromInt(t.len)) * 7.0;
}
const test_font = UserFont{ .height = 13, .width = &testWidth };

test "button reports click on press inside" {
    var in: Input = .{};
    const r = Rect.init(0, 0, 100, 30);
    const style = style_mod.Style.default().button;

    in.begin();
    in.mouse.pos = .{ .x = 50, .y = 15 }; // hover inside
    in.button(.left, 50, 15, true); // press inside

    var state: States = .{};
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    const clicked = try doButtonText(&state, &buf, r, "ok", style.text_alignment, .default, &style, &in, &test_font);
    try std.testing.expect(clicked);
    try std.testing.expect(state.actived); // pressed -> active (hover bit cleared)
}

test "button does not click when not hovered" {
    var in: Input = .{};
    const r = Rect.init(0, 0, 100, 30);
    const style = style_mod.Style.default().button;
    in.begin();
    in.mouse.pos = .{ .x = 500, .y = 500 }; // far away
    in.button(.left, 500, 500, true);

    var state: States = .{};
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    const clicked = try doButtonText(&state, &buf, r, "ok", style.text_alignment, .default, &style, &in, &test_font);
    try std.testing.expect(!clicked);
    try std.testing.expect(!state.hover);
}
