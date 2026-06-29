//! Color types and conversions, ported from `nuklear_color.c`.
//!
//! Nuklear exposes many `_iv`/`_bv`/`_fv`/`_dv` variants that only differ by
//! taking a pointer to an array; those are redundant in Zig (callers pass
//! struct literals or slices), so the port keeps just the meaningful
//! constructors and conversions, expressed as methods.

const std = @import("std");

fn saturate(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

fn byteFromFloat(x: f32) u8 {
    return @intFromFloat(saturate(x) * 255.0);
}

fn clampByte(x: i32) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}

fn hexDigit(c: u8) u8 {
    return switch (c) {
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => c -% '0',
    };
}

fn parseHexPair(p: []const u8) u8 {
    return hexDigit(p[0]) *% 16 +% hexDigit(p[1]);
}

fn toHexDigit(i: u8) u8 {
    return if (i <= 9) '0' + i else 'A' - 10 + i;
}

/// HSVA color in normalized `[0,1]` floats.
pub const Hsva = struct { h: f32, s: f32, v: f32, a: f32 };

/// 8-bit-per-channel RGBA color (`nk_color`).
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    /// Clamp integer channels to `0..255` (`nk_rgba`).
    pub fn rgba(r: i32, g: i32, b: i32, a: i32) Color {
        return .{ .r = clampByte(r), .g = clampByte(g), .b = clampByte(b), .a = clampByte(a) };
    }

    /// Like `rgba` with full opacity (`nk_rgb`).
    pub fn rgb(r: i32, g: i32, b: i32) Color {
        return .{ .r = clampByte(r), .g = clampByte(g), .b = clampByte(b), .a = 255 };
    }

    /// Saturate float channels in `[0,1]` (`nk_rgba_f`).
    pub fn rgbaF(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = byteFromFloat(r), .g = byteFromFloat(g), .b = byteFromFloat(b), .a = byteFromFloat(a) };
    }

    /// Like `rgbaF` with full opacity (`nk_rgb_f`).
    pub fn rgbF(r: f32, g: f32, b: f32) Color {
        return .{ .r = byteFromFloat(r), .g = byteFromFloat(g), .b = byteFromFloat(b), .a = 255 };
    }

    /// Unpack a little-endian `0xAABBGGRR` value (`nk_rgba_u32`).
    pub fn fromU32(in: u32) Color {
        return .{
            .r = @truncate(in),
            .g = @truncate(in >> 8),
            .b = @truncate(in >> 16),
            .a = @truncate(in >> 24),
        };
    }

    /// Pack into a little-endian `0xAABBGGRR` value (`nk_color_u32`).
    pub fn toU32(c: Color) u32 {
        return @as(u32, c.r) |
            (@as(u32, c.g) << 8) |
            (@as(u32, c.b) << 16) |
            (@as(u32, c.a) << 24);
    }

    /// Parse `"RRGGBB"` (optionally `#`-prefixed); alpha is set to 255
    /// (`nk_rgb_hex`).
    pub fn fromHex(s: []const u8) Color {
        const c = if (s.len > 0 and s[0] == '#') s[1..] else s;
        return .{
            .r = parseHexPair(c[0..]),
            .g = parseHexPair(c[2..]),
            .b = parseHexPair(c[4..]),
            .a = 255,
        };
    }

    /// Parse `"RRGGBBAA"` (optionally `#`-prefixed) (`nk_rgba_hex`).
    pub fn fromHexRgba(s: []const u8) Color {
        const c = if (s.len > 0 and s[0] == '#') s[1..] else s;
        return .{
            .r = parseHexPair(c[0..]),
            .g = parseHexPair(c[2..]),
            .b = parseHexPair(c[4..]),
            .a = parseHexPair(c[6..]),
        };
    }

    /// Format as uppercase `"RRGGBB"` (`nk_color_hex_rgb`).
    pub fn toHexRgb(c: Color) [6]u8 {
        return .{
            toHexDigit(c.r >> 4), toHexDigit(c.r & 0x0F),
            toHexDigit(c.g >> 4), toHexDigit(c.g & 0x0F),
            toHexDigit(c.b >> 4), toHexDigit(c.b & 0x0F),
        };
    }

    /// Format as uppercase `"RRGGBBAA"` (`nk_color_hex_rgba`).
    pub fn toHexRgba(c: Color) [8]u8 {
        return .{
            toHexDigit(c.r >> 4), toHexDigit(c.r & 0x0F),
            toHexDigit(c.g >> 4), toHexDigit(c.g & 0x0F),
            toHexDigit(c.b >> 4), toHexDigit(c.b & 0x0F),
            toHexDigit(c.a >> 4), toHexDigit(c.a & 0x0F),
        };
    }

    /// Scale the RGB channels by `factor`, leaving alpha untouched
    /// (`nk_rgb_factor`). Used for hover/active theming.
    pub fn factor(c: Color, f: f32) Color {
        if (f == 1.0) return c;
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(c.r)) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(c.g)) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(c.b)) * f),
            .a = c.a,
        };
    }

    /// Convert to floating-point color (`nk_color_cf`).
    pub fn toColorf(c: Color) Colorf {
        const s = 1.0 / 255.0;
        return .{
            .r = @as(f32, @floatFromInt(c.r)) * s,
            .g = @as(f32, @floatFromInt(c.g)) * s,
            .b = @as(f32, @floatFromInt(c.b)) * s,
            .a = @as(f32, @floatFromInt(c.a)) * s,
        };
    }

    /// Convert to HSVA in `[0,1]` (`nk_color_hsva_f`).
    pub fn toHsva(c: Color) Hsva {
        return c.toColorf().toHsva();
    }

    /// Build from HSVA given as `0..255` integers (`nk_hsva`).
    pub fn fromHsva(h: i32, s: i32, v: i32, a: i32) Color {
        return Colorf.fromHsva(
            @as(f32, @floatFromInt(clampByte(h))) / 255.0,
            @as(f32, @floatFromInt(clampByte(s))) / 255.0,
            @as(f32, @floatFromInt(clampByte(v))) / 255.0,
            @as(f32, @floatFromInt(clampByte(a))) / 255.0,
        ).toColor();
    }

    /// Build from HSV integers with full opacity (`nk_hsv`).
    pub fn fromHsv(h: i32, s: i32, v: i32) Color {
        return fromHsva(h, s, v, 255);
    }

    /// Build from HSVA given as `[0,1]` floats (`nk_hsva_f`).
    pub fn fromHsvaF(h: f32, s: f32, v: f32, a: f32) Color {
        return Colorf.fromHsva(h, s, v, a).toColor();
    }
};

/// Floating-point RGBA color (`nk_colorf`).
pub const Colorf = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    /// Convert to 8-bit color (`nk_rgba_cf`).
    pub fn toColor(c: Colorf) Color {
        return Color.rgbaF(c.r, c.g, c.b, c.a);
    }

    /// HSVA (`[0,1]`) to RGBA float (`nk_hsva_colorf`).
    pub fn fromHsva(h: f32, s: f32, v: f32, a: f32) Colorf {
        if (s <= 0.0) return .{ .r = v, .g = v, .b = v, .a = a };

        const h6 = h / (60.0 / 360.0);
        const i: i32 = @intFromFloat(h6);
        const f = h6 - @as(f32, @floatFromInt(i));
        const p = v * (1.0 - s);
        const q = v * (1.0 - (s * f));
        const t = v * (1.0 - s * (1.0 - f));

        const rgb: [3]f32 = switch (i) {
            1 => .{ q, v, p },
            2 => .{ p, v, t },
            3 => .{ p, q, v },
            4 => .{ t, p, v },
            5 => .{ v, p, q },
            else => .{ v, t, p }, // cases 0 and 6 (default)
        };
        return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = a };
    }

    /// RGBA float to HSVA (`[0,1]`) (`nk_colorf_hsva_f`).
    pub fn toHsva(in0: Colorf) Hsva {
        var r = in0.r;
        var g = in0.g;
        var b = in0.b;
        var k: f32 = 0.0;
        if (g < b) {
            std.mem.swap(f32, &g, &b);
            k = -1.0;
        }
        if (r < g) {
            std.mem.swap(f32, &r, &g);
            k = -2.0 / 6.0 - k;
        }
        const chroma = r - @min(g, b);
        return .{
            .h = @abs(k + (g - b) / (6.0 * chroma + 1e-20)),
            .s = chroma / (r + 1e-20),
            .v = r,
            .a = in0.a,
        };
    }
};

test "rgba/rgb clamp" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 128, .a = 255 }, Color.rgba(300, -5, 128, 1000));
    try std.testing.expectEqual(Color{ .r = 10, .g = 20, .b = 30, .a = 255 }, Color.rgb(10, 20, 30));
}

test "rgbaF saturates and scales" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 127, .b = 0, .a = 255 }, Color.rgbaF(2.0, 0.5, -1.0, 1.0));
}

test "u32 roundtrip" {
    const c: Color = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 };
    try std.testing.expectEqual(@as(u32, 0x78563412), c.toU32());
    try std.testing.expectEqual(c, Color.fromU32(c.toU32()));
}

test "hex parse and format" {
    try std.testing.expectEqual(Color{ .r = 0xFF, .g = 0x80, .b = 0x00, .a = 255 }, Color.fromHex("#FF8000"));
    try std.testing.expectEqual(Color{ .r = 0xFF, .g = 0x80, .b = 0x00, .a = 255 }, Color.fromHex("ff8000"));
    try std.testing.expectEqual(Color{ .r = 0x0A, .g = 0x0B, .b = 0x0C, .a = 0x0D }, Color.fromHexRgba("0A0B0C0D"));
    try std.testing.expectEqualStrings("FF8000", &Color.rgb(0xFF, 0x80, 0).toHexRgb());
    try std.testing.expectEqualStrings("0A0B0C0D", &Color.rgba(0x0A, 0x0B, 0x0C, 0x0D).toHexRgba());
}

test "rgb factor" {
    try std.testing.expectEqual(Color{ .r = 100, .g = 50, .b = 0, .a = 200 }, (Color{ .r = 200, .g = 100, .b = 0, .a = 200 }).factor(0.5));
    const c: Color = .{ .r = 1, .g = 2, .b = 3, .a = 4 };
    try std.testing.expectEqual(c, c.factor(1.0));
}

test "hsv to rgb primaries" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0, .a = 255 }, Color.fromHsvaF(0.0, 1.0, 1.0, 1.0));
    try std.testing.expectEqual(Color{ .r = 0, .g = 255, .b = 0, .a = 255 }, Color.fromHsvaF(1.0 / 3.0, 1.0, 1.0, 1.0));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 255, .a = 255 }, Color.fromHsvaF(2.0 / 3.0, 1.0, 1.0, 1.0));
    // Saturation 0 yields gray.
    try std.testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128, .a = 255 }, Color.fromHsvaF(0.5, 0.0, 0.5019608, 1.0));
}

test "rgb<->hsv roundtrip stays close" {
    const original: Color = .{ .r = 200, .g = 120, .b = 40, .a = 255 };
    const hsva = original.toHsva();
    const back = Colorf.fromHsva(hsva.h, hsva.s, hsva.v, hsva.a).toColor();
    try std.testing.expectApproxEqAbs(@as(f32, 200), @as(f32, @floatFromInt(back.r)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 120), @as(f32, @floatFromInt(back.g)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 40), @as(f32, @floatFromInt(back.b)), 1.5);
}
