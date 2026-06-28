//! A dynamic UTF-8 string, ported from `nuklear_string.c`. It is backed by a
//! `Buffer` (front region) and tracks the glyph count alongside the byte
//! length. Used by the text editor and edit widget.
//!
//! Nuklear exposes many near-duplicate entry points (`_char`/`_utf8`/`_runes`
//! and `str_`/`text_` pairs). Since Zig works with byte slices directly, the
//! port keeps a focused set: byte-slice and rune operations, with byte- and
//! rune-indexed insertion/deletion.

const std = @import("std");
const utf8 = @import("utf8.zig");
const Buffer = @import("Buffer.zig");

const String = @This();

buffer: Buffer,
/// Length in glyphs/runes (`nk_str.len`).
glyphs: usize = 0,

/// A located glyph: its byte offset plus decoded rune/length. When `pos`
/// equals the glyph count, `offset` is the end of the string and `len` is 0.
pub const Located = struct { offset: usize, rune: u21, len: usize };

pub fn init(allocator: std.mem.Allocator, size: usize) !String {
    return .{ .buffer = try Buffer.init(allocator, size) };
}

pub fn initFixed(memory: []u8) String {
    return .{ .buffer = Buffer.initFixed(memory) };
}

pub fn deinit(s: *String) void {
    s.buffer.deinit();
    s.* = undefined;
}

pub fn clear(s: *String) void {
    s.buffer.clear();
    s.glyphs = 0;
}

/// The current contents as a byte slice (`nk_str_get`).
pub fn bytes(s: *const String) []u8 {
    return s.buffer.memory[0..s.buffer.allocated];
}

/// Length in bytes (`nk_str_len_char`).
pub fn byteLen(s: *const String) usize {
    return s.buffer.allocated;
}

/// Length in glyphs (`nk_str_len`).
pub fn glyphLen(s: *const String) usize {
    return s.glyphs;
}

/// Append raw UTF-8 bytes (`nk_str_append_text_char`).
pub fn appendBytes(s: *String, str: []const u8) !void {
    if (str.len == 0) return;
    try s.buffer.push(.front, str, 0);
    s.glyphs += utf8.count(str);
}

/// Append a single rune (`nk_str_append_text_runes` for one rune).
pub fn appendRune(s: *String, rune: u21) !void {
    var glyph: [utf8.max_size]u8 = undefined;
    const n = utf8.encode(rune, &glyph);
    if (n == 0) return;
    try s.appendBytes(glyph[0..n]);
}

/// Append a slice of runes (`nk_str_append_text_runes`).
pub fn appendRunes(s: *String, runes: []const u21) !void {
    for (runes) |r| try s.appendRune(r);
}

/// Insert bytes at a byte position (`nk_str_insert_at_char`).
pub fn insertAt(s: *String, pos: usize, str: []const u8) !void {
    if (pos > s.buffer.allocated or str.len == 0) return;
    const copylen = s.buffer.allocated - pos;
    if (copylen == 0) return s.appendBytes(str);

    // Grow the front region; this may relocate the backing memory.
    _ = try s.buffer.alloc(.front, str.len, 0);
    const mem = s.buffer.memory;
    std.mem.copyBackwards(u8, mem[pos + str.len ..][0..copylen], mem[pos..][0..copylen]);
    @memcpy(mem[pos..][0..str.len], str);
    s.glyphs = utf8.count(s.bytes());
}

/// Insert bytes before the glyph at rune position `pos`
/// (`nk_str_insert_at_rune`).
pub fn insertAtRune(s: *String, pos: usize, str: []const u8) !void {
    if (str.len == 0) return;
    if (s.glyphs == 0) return s.appendBytes(str);
    const loc = s.atRune(pos) orelse return;
    try s.insertAt(loc.offset, str);
}

/// Truncate `len` bytes from the end (`nk_str_remove_chars`).
pub fn removeChars(s: *String, len: usize) void {
    if (len > s.buffer.allocated) return;
    s.buffer.allocated -= len;
    s.glyphs = utf8.count(s.bytes());
}

/// Truncate `n` runes from the end (`nk_str_remove_runes`).
pub fn removeRunes(s: *String, n: usize) void {
    if (n >= s.glyphs) {
        s.buffer.allocated = 0;
        s.glyphs = 0;
        return;
    }
    const loc = s.atRune(s.glyphs - n) orelse return;
    s.buffer.allocated = loc.offset;
    s.glyphs -= n;
}

/// Delete `len` bytes starting at byte position `pos` (`nk_str_delete_chars`).
pub fn deleteChars(s: *String, pos: usize, len: usize) void {
    if (len == 0 or pos > s.buffer.allocated or pos + len > s.buffer.allocated) return;
    if (pos + len < s.buffer.allocated) {
        const mem = s.buffer.memory;
        const tail = s.buffer.allocated - (pos + len);
        std.mem.copyForwards(u8, mem[pos..][0..tail], mem[pos + len ..][0..tail]);
        s.buffer.allocated -= len;
    } else {
        s.removeChars(len);
    }
    s.glyphs = utf8.count(s.bytes());
}

/// Delete `len` runes starting at rune position `pos` (`nk_str_delete_runes`).
pub fn deleteRunes(s: *String, pos: usize, len_in: usize) void {
    var len = len_in;
    if (s.glyphs < pos + len) len = if (s.glyphs > pos) s.glyphs - pos else 0;
    if (len == 0) return;
    const begin = s.atRune(pos) orelse return;
    const end = s.atRune(pos + len) orelse return;
    s.deleteChars(begin.offset, end.offset - begin.offset);
}

/// Locate the glyph at rune position `pos` (`nk_str_at_rune`). Returns an
/// end-of-string locator when `pos == glyphLen()`, or null when out of range.
pub fn atRune(s: *const String, pos: usize) ?Located {
    const text = s.bytes();
    var i: usize = 0;
    var src: usize = 0;
    var d = utf8.decode(text);
    while (d.len != 0) {
        if (i == pos) return .{ .offset = src, .rune = d.rune, .len = d.len };
        i += 1;
        src += d.len;
        d = utf8.decode(text[src..]);
    }
    if (i == pos) return .{ .offset = src, .rune = 0, .len = 0 };
    return null;
}

/// The rune at glyph position `pos`, or 0 if out of range (`nk_str_rune_at`).
pub fn runeAt(s: *const String, pos: usize) u21 {
    const loc = s.atRune(pos) orelse return 0;
    return loc.rune;
}

test "append bytes and runes" {
    var s = try String.init(std.testing.allocator, 8);
    defer s.deinit();
    try s.appendBytes("ab");
    try s.appendRune(0x20AC); // euro sign, 3 bytes
    try std.testing.expectEqualStrings("ab\u{20AC}", s.bytes());
    try std.testing.expectEqual(@as(usize, 3), s.glyphLen());
    try std.testing.expectEqual(@as(usize, 5), s.byteLen());
}

test "insertAt bytes" {
    var s = try String.init(std.testing.allocator, 8);
    defer s.deinit();
    try s.appendBytes("hello");
    try s.insertAt(2, "XYZ");
    try std.testing.expectEqualStrings("heXYZllo", s.bytes());
    try s.insertAt(s.byteLen(), "!"); // at end -> append
    try std.testing.expectEqualStrings("heXYZllo!", s.bytes());
}

test "insertAtRune respects glyph boundaries" {
    var s = try String.init(std.testing.allocator, 16);
    defer s.deinit();
    try s.appendBytes("a\u{20AC}b"); // a, euro, b
    try s.insertAtRune(2, "-"); // before 'b'
    try std.testing.expectEqualStrings("a\u{20AC}-b", s.bytes());
    try std.testing.expectEqual(@as(usize, 4), s.glyphLen());
}

test "deleteChars and deleteRunes" {
    var s = try String.init(std.testing.allocator, 16);
    defer s.deinit();
    try s.appendBytes("hello world");
    s.deleteChars(5, 6); // remove " world"
    try std.testing.expectEqualStrings("hello", s.bytes());

    s.clear();
    try s.appendBytes("a\u{20AC}b\u{20AC}c");
    s.deleteRunes(1, 2); // remove euro and 'b'
    try std.testing.expectEqualStrings("a\u{20AC}c", s.bytes());
    try std.testing.expectEqual(@as(usize, 3), s.glyphLen());
}

test "removeChars and removeRunes from end" {
    var s = try String.init(std.testing.allocator, 16);
    defer s.deinit();
    try s.appendBytes("abc\u{20AC}");
    s.removeRunes(1); // drop euro
    try std.testing.expectEqualStrings("abc", s.bytes());
    s.removeChars(1);
    try std.testing.expectEqualStrings("ab", s.bytes());
    s.removeRunes(5); // more than present -> empty
    try std.testing.expectEqual(@as(usize, 0), s.byteLen());
}

test "atRune and runeAt" {
    var s = try String.init(std.testing.allocator, 16);
    defer s.deinit();
    try s.appendBytes("a\u{20AC}b");
    try std.testing.expectEqual(@as(u21, 0x20AC), s.runeAt(1));
    try std.testing.expectEqual(Located{ .offset = 1, .rune = 0x20AC, .len = 3 }, s.atRune(1).?);
    // pos == glyph count -> end-of-string locator.
    try std.testing.expectEqual(Located{ .offset = 5, .rune = 0, .len = 0 }, s.atRune(3).?);
    try std.testing.expectEqual(@as(?Located, null), s.atRune(4));
}
