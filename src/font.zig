//! The user-font interface and text measurement, ported from the font section
//! of `nuklear.h` and `nk_text_clamp` (`nuklear_util.c`).
//!
//! `UserFont` is the minimal contract the GUI needs from a font: its height
//! and a width-measuring callback. The optional glyph-query/texture fields used
//! by the vertex-buffer renderer arrive in the vertex phase. Font *baking* (the
//! stb-based atlas builder) is a separate later phase.

const std = @import("std");
const utf8 = @import("utf8.zig");
const Handle = @import("handle.zig").Handle;

/// Measures the pixel width of a UTF-8 string at a given font height
/// (`nk_text_width_f`).
pub const WidthFn = *const fn (userdata: Handle, height: f32, text: []const u8) f32;

/// A caller-provided font (`nk_user_font`).
pub const UserFont = struct {
    userdata: Handle = .{ .id = 0 },
    /// Maximum glyph height in pixels.
    height: f32,
    width: WidthFn,

    /// Pixel width of `text` in this font.
    pub fn textWidth(font: *const UserFont, text: []const u8) f32 {
        return font.width(font.userdata, font.height, text);
    }
};

/// Result of clamping text to a width budget.
pub const Clamped = struct {
    /// Number of bytes that fit.
    len: usize,
    /// Number of glyphs that fit.
    glyphs: usize,
    /// Pixel width of the fitting prefix.
    width: f32,
};

/// Find how much of `text` fits in `space` pixels (`nk_text_clamp`). If any
/// codepoint in `sep_list` is encountered, the clamp prefers to break there
/// (used for word wrapping); pass an empty list for a hard character clamp.
pub fn textClamp(font: *const UserFont, text: []const u8, space: f32, sep_list: []const u21) Clamped {
    var len: usize = 0;
    var g: usize = 0;
    var width: f32 = 0;
    var last_width: f32 = 0;
    var sep_width: f32 = 0;
    var sep_g: usize = 0;
    var sep_len: usize = 0;

    var d = utf8.decode(text);
    while (d.len != 0 and width < space and len < text.len) {
        len += d.len;
        const s = font.textWidth(text[0..len]);

        var matched = false;
        for (sep_list) |sep| {
            if (d.rune == sep) {
                sep_width = width;
                last_width = width;
                sep_g = g + 1;
                sep_len = len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            last_width = width;
            sep_width = width;
            sep_g = g + 1;
        }

        width = s;
        d = utf8.decode(text[len..]);
        g += 1;
    }

    if (len >= text.len) {
        return .{ .len = len, .glyphs = g, .width = last_width };
    }
    return .{ .len = if (sep_len == 0) len else sep_len, .glyphs = sep_g, .width = sep_width };
}

// --- tests ---------------------------------------------------------------

/// Fixed-width test font: every glyph is 10px wide.
fn mockWidth(_: Handle, _: f32, text: []const u8) f32 {
    return @as(f32, @floatFromInt(utf8.count(text))) * 10.0;
}
const mock_font = UserFont{ .height = 12, .width = &mockWidth };

test "textWidth uses the callback" {
    try std.testing.expectEqual(@as(f32, 50), mock_font.textWidth("hello"));
}

test "textClamp hard character clamp" {
    // "hello" is 50px wide; budget 25px fits 3 glyphs (per Nuklear's loop).
    const c = textClamp(&mock_font, "hello", 25, &.{});
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqual(@as(usize, 3), c.glyphs);

    // Everything fits when the budget is large.
    const all = textClamp(&mock_font, "hello", 1000, &.{});
    try std.testing.expectEqual(@as(usize, 5), all.len);
}

test "textClamp breaks on separator" {
    // With a 35px budget "ab cd" would hard-clamp after 4 chars, but a space
    // separator pulls the break back to just after the space (3 bytes).
    try std.testing.expectEqual(@as(usize, 4), textClamp(&mock_font, "ab cd", 35, &.{}).len);
    try std.testing.expectEqual(@as(usize, 3), textClamp(&mock_font, "ab cd", 35, &.{' '}).len);
}
