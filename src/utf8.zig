//! UTF-8 decoding/encoding, ported from `nuklear_utf8.c`.
//!
//! The algorithm and its quirks are preserved faithfully (including the
//! replacement-character fallback and the strict upper-bound `between` test
//! Nuklear uses), but the API is idiomatic: results are returned as values
//! rather than through out-parameters.

const std = @import("std");

/// Replacement character emitted for malformed input (`NK_UTF_INVALID`).
pub const invalid: u21 = 0xFFFD;
/// Maximum number of bytes in an encoded glyph (`NK_UTF_SIZE`).
pub const max_size = 4;

const utfbyte = [max_size + 1]u8{ 0x80, 0, 0xC0, 0xE0, 0xF0 };
const utfmask = [max_size + 1]u8{ 0xC0, 0x80, 0xE0, 0xF0, 0xF8 };
const utfmin = [max_size + 1]u32{ 0, 0, 0x80, 0x800, 0x10000 };
const utfmax = [max_size + 1]u32{ 0x10FFFF, 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };

/// `NK_BETWEEN`: closed lower, open upper bound.
fn between(x: u32, a: u32, b: u32) bool {
    return a <= x and x < b;
}

/// Result of decoding one glyph. `len` is the number of bytes consumed; it can
/// be 0 when the input was empty or truncated mid-glyph.
pub const Decoded = struct {
    rune: u21,
    len: usize,
};

/// Clamp `u` to the replacement character if it is out of range or a surrogate,
/// then return how many bytes its encoding occupies (`nk_utf_validate`).
fn validate(u: *u32, index: usize) usize {
    if (!between(u.*, utfmin[index], utfmax[index]) or between(u.*, 0xD800, 0xDFFF))
        u.* = invalid;
    var i: usize = 1;
    while (u.* > utfmax[i]) : (i += 1) {}
    return i;
}

const Byte = struct { rune: u32, index: usize };

/// Strip the leading marker bits of one byte and report which marker matched
/// (`nk_utf_decode_byte`). `index` is `utfmask.len` when nothing matched.
fn decodeByte(c: u8) Byte {
    var i: usize = 0;
    while (i < utfmask.len) : (i += 1) {
        if ((c & utfmask[i]) == utfbyte[i])
            return .{ .rune = c & ~utfmask[i], .index = i };
    }
    return .{ .rune = 0, .index = utfmask.len };
}

fn encodeByte(u: u32, i: usize) u8 {
    return utfbyte[i] | (@as(u8, @truncate(u)) & ~utfmask[i]);
}

/// Decode the first glyph in `bytes` (`nk_utf_decode`).
pub fn decode(bytes: []const u8) Decoded {
    if (bytes.len == 0) return .{ .rune = invalid, .len = 0 };

    const first = decodeByte(bytes[0]);
    const total = first.index;
    if (!between(@intCast(total), 1, max_size + 1))
        return .{ .rune = invalid, .len = 1 };

    var udecoded: u32 = first.rune;
    var i: usize = 1;
    var j: usize = 1;
    while (i < bytes.len and j < total) : ({
        i += 1;
        j += 1;
    }) {
        const cont = decodeByte(bytes[i]);
        udecoded = (udecoded << 6) | cont.rune;
        if (cont.index != 0) return .{ .rune = invalid, .len = j };
    }
    if (j < total) return .{ .rune = invalid, .len = 0 };

    _ = validate(&udecoded, total);
    return .{ .rune = @intCast(udecoded), .len = total };
}

/// Encode `rune` into `buf`, returning the number of bytes written, or 0 if
/// `buf` is too small (`nk_utf_encode`).
pub fn encode(rune: u21, buf: []u8) usize {
    var u: u32 = rune;
    const total = validate(&u, 0);
    if (buf.len < total or total == 0 or total > max_size) return 0;

    var i = total - 1;
    while (i != 0) : (i -= 1) {
        buf[i] = encodeByte(u, 0);
        u >>= 6;
    }
    buf[0] = encodeByte(u, total);
    return total;
}

/// Count the glyphs in `s` (`nk_utf_len`).
pub fn count(s: []const u8) usize {
    var glyphs: usize = 0;
    var off: usize = 0;
    var d = decode(s);
    while (d.len != 0 and off < s.len) {
        glyphs += 1;
        off += d.len;
        d = decode(s[off..]);
    }
    return glyphs;
}

/// A glyph located within a string by index.
pub const Glyph = struct {
    rune: u21,
    /// Byte offset of the glyph in the source string.
    offset: usize,
    len: usize,
};

/// Return the glyph at the given glyph `index`, or null if out of range
/// (`nk_utf_at`).
pub fn at(buffer: []const u8, index: usize) ?Glyph {
    var i: usize = 0;
    var off: usize = 0;
    var d = decode(buffer);
    while (d.len != 0) {
        if (i == index) return .{ .rune = d.rune, .offset = off, .len = d.len };
        i += 1;
        off += d.len;
        d = decode(buffer[off..]);
    }
    return null;
}

test "decode 1..4 byte glyphs" {
    try std.testing.expectEqual(Decoded{ .rune = 'A', .len = 1 }, decode("A"));
    try std.testing.expectEqual(Decoded{ .rune = 0x00F8, .len = 2 }, decode("\u{00F8}"));
    try std.testing.expectEqual(Decoded{ .rune = 0x20AC, .len = 3 }, decode("\u{20AC}"));
    try std.testing.expectEqual(Decoded{ .rune = 0x1F600, .len = 4 }, decode("\u{1F600}"));
    try std.testing.expectEqual(Decoded{ .rune = invalid, .len = 0 }, decode(""));
}

test "decode rejects truncated and stray continuation" {
    // Truncated 3-byte sequence -> len 0.
    try std.testing.expectEqual(Decoded{ .rune = invalid, .len = 0 }, decode("\xE2\x82"));
    // Lone continuation byte -> consumes 1, replacement char.
    try std.testing.expectEqual(Decoded{ .rune = invalid, .len = 1 }, decode("\x82"));
}

test "encode roundtrips with decode" {
    const runes = [_]u21{ 'A', 0x00F8, 0x20AC, 0x1F600 };
    for (runes) |r| {
        var buf: [max_size]u8 = undefined;
        const n = encode(r, &buf);
        try std.testing.expect(n != 0);
        try std.testing.expectEqual(Decoded{ .rune = r, .len = n }, decode(buf[0..n]));
    }
}

test "encode into too-small buffer fails" {
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), encode(0x20AC, &buf));
}

test "count glyphs" {
    try std.testing.expectEqual(@as(usize, 0), count(""));
    try std.testing.expectEqual(@as(usize, 5), count("hello"));
    try std.testing.expectEqual(@as(usize, 4), count("a\u{20AC}b\u{1F600}"));
}

test "at returns glyph and offset" {
    const s = "a\u{20AC}b";
    try std.testing.expectEqual(Glyph{ .rune = 'a', .offset = 0, .len = 1 }, at(s, 0).?);
    try std.testing.expectEqual(Glyph{ .rune = 0x20AC, .offset = 1, .len = 3 }, at(s, 1).?);
    try std.testing.expectEqual(Glyph{ .rune = 'b', .offset = 4, .len = 1 }, at(s, 2).?);
    try std.testing.expectEqual(@as(?Glyph, null), at(s, 3));
}
