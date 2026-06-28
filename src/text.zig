//! Text/label rendering, ported from `nk_widget_text` (`nuklear_text.c`).
//!
//! `widgetText` aligns a string within a bounding box (horizontally and
//! vertically per `Align`) and emits a draw-text command. The `Context`-level
//! `label`/`text` helpers that allocate a layout slot and call this live in
//! `context.zig`.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const font_mod = @import("font.zig");

const Rect = math.Rect;
const Vec2 = math.Vec2;
const Color = color.Color;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const UserFont = font_mod.UserFont;

/// Draw `string` aligned inside `b` (`nk_widget_text`). `padding` insets the
/// box; `background`/`foreground` are the text colors.
pub fn widgetText(
    out: *CommandBuffer,
    b_in: Rect,
    string: []const u8,
    a_in: Align,
    padding: Vec2,
    background: Color,
    foreground: Color,
    font: *const UserFont,
) !void {
    var b = b_in;
    b.h = @max(b.h, 2 * padding.y);

    const text_width = font.textWidth(string) + 2.0 * padding.x;

    // default to top-left when no axis is specified
    var a = a_in;
    if (!a.left and !a.centered and !a.right) a.left = true;
    if (!a.top and !a.middle and !a.bottom) a.top = true;

    var label = Rect{};

    // horizontal
    if (a.left) {
        label.x = b.x + padding.x;
        label.w = @max(0, b.w - 2 * padding.x);
    } else if (a.centered) {
        label.w = @max(1, 2 * padding.x + text_width);
        label.x = b.x + padding.x + ((b.w - 2 * padding.x) - label.w) / 2;
        label.x = @max(b.x + padding.x, label.x);
        label.w = @min(b.x + b.w, label.x + label.w);
        if (label.w >= label.x) label.w -= label.x;
    } else { // right
        label.x = @max(b.x + padding.x, (b.x + b.w) - (2 * padding.x + text_width));
        label.w = text_width + 2 * padding.x;
    }

    // vertical
    if (a.top) {
        label.y = b.y + padding.y;
        label.h = @min(font.height, b.h - 2 * padding.y);
    } else if (a.middle) {
        label.y = b.y + b.h / 2.0 - font.height / 2.0;
        label.h = @max(b.h / 2.0, b.h - (b.h / 2.0 + font.height / 2.0));
    } else { // bottom
        label.y = b.y + b.h - font.height;
        label.h = font.height;
    }

    try out.drawText(label, string, font, background, foreground);
}

test "widgetText emits a left-aligned label" {
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    const Handle = @import("handle.zig").Handle;
    const widthFn = struct {
        fn f(_: Handle, _: f32, t: []const u8) f32 {
            return @as(f32, @floatFromInt(t.len)) * 7.0;
        }
    }.f;
    const font = UserFont{ .height = 13, .width = &widthFn };

    try widgetText(&buf, Rect.init(0, 0, 100, 20), "hi", .{ .left = true, .middle = true }, Vec2.init(2, 2), Color{ .a = 0 }, Color.white, &font);
    const t = buf.items()[0].text;
    try std.testing.expectEqualStrings("hi", t.string);
    try std.testing.expectEqual(@as(i16, 2), t.x); // left padding
}

test "widgetText centers horizontally" {
    var buf = CommandBuffer.init(std.testing.allocator);
    defer buf.deinit();
    buf.use_clipping = false;

    const Handle = @import("handle.zig").Handle;
    const widthFn = struct {
        fn f(_: Handle, _: f32, t: []const u8) f32 {
            return @as(f32, @floatFromInt(t.len)) * 10.0;
        }
    }.f;
    const font = UserFont{ .height = 13, .width = &widthFn };

    // "ab" is 20px wide in a 100px box -> roughly centered (x > left edge)
    try widgetText(&buf, Rect.init(0, 0, 100, 20), "ab", .{ .centered = true, .middle = true }, Vec2.init(0, 0), Color{ .a = 0 }, Color.white, &font);
    const t = buf.items()[0].text;
    try std.testing.expect(t.x > 30 and t.x < 50);
}
