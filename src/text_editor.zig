//! Text editor state, ported from `nuklear_text_editor.c` (itself derived from
//! stb_textedit). This is a functional editor covering insertion, deletion,
//! cursor movement, selection, word motion and clipboard cut/copy/paste.
//!
//! Deferred (TODO, marked below): the undo/redo stack and multi-line
//! pixel-coordinate row layout (vertical click positioning). Single-line
//! editing — the common text field — is fully supported.

const std = @import("std");
const unicode = std.unicode;
const String = @import("String.zig");
const Key = @import("input.zig").Key;

pub const Mode = enum { view, insert, replace };
pub const Type = enum { single_line, multi_line };

/// A text-input filter: return false to reject a codepoint (`nk_plugin_filter`).
pub const Filter = *const fn (rune: u21) bool;

pub const TextEdit = struct {
    string: String,
    filter: ?Filter = null,
    cursor: usize = 0,
    select_start: usize = 0,
    select_end: usize = 0,
    mode: Mode = .insert,
    single_line: bool = false,
    active: bool = false,
    has_preferred_x: bool = false,
    /// Horizontal pixel scroll so the cursor stays visible in a single-line edit.
    scroll_x: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, size: usize) !TextEdit {
        return .{ .string = try String.init(allocator, size) };
    }

    pub fn deinit(e: *TextEdit) void {
        e.string.deinit();
        e.* = undefined;
    }

    pub fn hasSelection(e: *const TextEdit) bool {
        return e.select_start != e.select_end;
    }

    fn len(e: *const TextEdit) usize {
        return e.string.glyphLen();
    }

    pub fn clear(e: *TextEdit) void {
        e.string.clear();
        e.cursor = 0;
        e.select_start = 0;
        e.select_end = 0;
        e.has_preferred_x = false;
    }

    /// The edited text (`nk_str_get`).
    pub fn text(e: *const TextEdit) []const u8 {
        return e.string.bytes();
    }

    pub fn selectAll(e: *TextEdit) void {
        e.select_start = 0;
        e.select_end = e.len();
    }

    fn clamp(e: *TextEdit) void {
        const n = e.len();
        if (e.hasSelection()) {
            if (e.select_start > n) e.select_start = n;
            if (e.select_end > n) e.select_end = n;
            if (e.select_start == e.select_end) e.cursor = e.select_start;
        }
        if (e.cursor > n) e.cursor = n;
    }

    fn deleteRunes(e: *TextEdit, where: usize, count: usize) void {
        // TODO: record undo here.
        e.string.deleteRunes(where, count);
        e.has_preferred_x = false;
    }

    fn deleteSelection(e: *TextEdit) void {
        e.clamp();
        if (!e.hasSelection()) return;
        if (e.select_start < e.select_end) {
            e.deleteRunes(e.select_start, e.select_end - e.select_start);
            e.cursor = e.select_start;
            e.select_end = e.select_start;
        } else {
            e.deleteRunes(e.select_end, e.select_start - e.select_end);
            e.cursor = e.select_end;
            e.select_start = e.select_end;
        }
        e.has_preferred_x = false;
    }

    fn sortSelection(e: *TextEdit) void {
        if (e.select_end < e.select_start) {
            const t = e.select_end;
            e.select_end = e.select_start;
            e.select_start = t;
        }
    }

    fn moveToFirst(e: *TextEdit) void {
        if (!e.hasSelection()) return;
        e.sortSelection();
        e.cursor = e.select_start;
        e.select_end = e.select_start;
        e.has_preferred_x = false;
    }

    fn moveToLast(e: *TextEdit) void {
        if (!e.hasSelection()) return;
        e.sortSelection();
        e.clamp();
        e.cursor = e.select_end;
        e.select_start = e.select_end;
        e.has_preferred_x = false;
    }

    fn prepSelection(e: *TextEdit) void {
        if (!e.hasSelection()) {
            e.select_start = e.cursor;
            e.select_end = e.cursor;
        } else {
            e.cursor = e.select_end;
        }
    }

    fn isSpace(rune: u21) bool {
        return rune == ' ' or rune == '\t' or rune == '\n' or rune == '\r';
    }

    fn wordPrevious(e: *TextEdit) usize {
        if (e.cursor == 0) return 0;
        var c = e.cursor - 1;
        while (c > 0 and isSpace(e.string.runeAt(c - 1))) c -= 1;
        while (c > 0 and !isSpace(e.string.runeAt(c - 1))) c -= 1;
        return c;
    }

    fn wordNext(e: *TextEdit) usize {
        const n = e.len();
        var c = e.cursor;
        while (c < n and !isSpace(e.string.runeAt(c))) c += 1;
        while (c < n and isSpace(e.string.runeAt(c))) c += 1;
        return c;
    }

    /// Insert/replace `input` (UTF-8) at the cursor (`nk_textedit_text`).
    pub fn insert(e: *TextEdit, input: []const u8) !void {
        var it = unicode.Utf8Iterator{ .bytes = input, .i = 0 };
        while (it.nextCodepointSlice()) |glyph| {
            const rune = unicode.utf8Decode(glyph) catch 0xFFFD;
            const allowed = rune != 127 and
                !(rune == '\n' and e.single_line) and
                (e.filter == null or e.filter.?(rune));
            if (allowed) {
                if (!e.hasSelection() and e.mode == .replace and e.cursor < e.len()) {
                    e.string.deleteRunes(e.cursor, 1);
                    try e.string.insertAtRune(e.cursor, glyph);
                    e.cursor += 1;
                } else {
                    e.deleteSelection();
                    try e.string.insertAtRune(e.cursor, glyph);
                    e.cursor = @min(e.cursor + 1, e.len());
                }
                e.has_preferred_x = false;
            }
        }
    }

    /// Process an editor key (`nk_textedit_key`). Up/Down behave as Left/Right
    /// in single-line mode; multi-line vertical motion is TODO.
    pub fn key(e: *TextEdit, key_in: Key, shift: bool) void {
        var k = key_in;
        if (e.single_line and k == .up) k = .left;
        if (e.single_line and k == .down) k = .right;

        switch (k) {
            .text_select_all => e.selectAll(),
            .text_insert_mode => e.mode = .insert,
            .text_replace_mode => e.mode = .replace,
            .text_reset_mode => e.mode = .view,

            .left => if (shift) {
                e.clamp();
                e.prepSelection();
                if (e.select_end > 0) e.select_end -= 1;
                e.cursor = e.select_end;
            } else if (e.hasSelection()) {
                e.moveToFirst();
            } else if (e.cursor > 0) {
                e.cursor -= 1;
            },

            .right => if (shift) {
                e.prepSelection();
                e.select_end += 1;
                e.clamp();
                e.cursor = e.select_end;
            } else if (e.hasSelection()) {
                e.moveToLast();
            } else {
                e.cursor += 1;
                e.clamp();
            },

            .text_word_left => if (shift) {
                if (!e.hasSelection()) e.prepSelection();
                e.cursor = e.wordPrevious();
                e.select_end = e.cursor;
                e.clamp();
            } else if (e.hasSelection()) {
                e.moveToFirst();
            } else {
                e.cursor = e.wordPrevious();
                e.clamp();
            },

            .text_word_right => if (shift) {
                if (!e.hasSelection()) e.prepSelection();
                e.cursor = e.wordNext();
                e.select_end = e.cursor;
                e.clamp();
            } else if (e.hasSelection()) {
                e.moveToLast();
            } else {
                e.cursor = e.wordNext();
                e.clamp();
            },

            .del => if (e.mode != .view) {
                if (e.hasSelection()) {
                    e.deleteSelection();
                } else if (e.cursor < e.len()) {
                    e.deleteRunes(e.cursor, 1);
                }
            },

            .backspace => if (e.mode != .view) {
                if (e.hasSelection()) {
                    e.deleteSelection();
                } else {
                    e.clamp();
                    if (e.cursor > 0) {
                        e.deleteRunes(e.cursor - 1, 1);
                        e.cursor -= 1;
                    }
                }
            },

            .text_start, .text_line_start => if (shift) {
                e.prepSelection();
                e.cursor = 0;
                e.select_end = 0;
            } else {
                e.cursor = 0;
                e.select_start = 0;
                e.select_end = 0;
            },

            .text_end, .text_line_end => if (shift) {
                e.prepSelection();
                e.cursor = e.len();
                e.select_end = e.cursor;
            } else {
                e.cursor = e.len();
                e.select_start = 0;
                e.select_end = 0;
            },

            else => {},
        }
    }

    /// Replace the selection (or insert) with `paste_text` (`nk_textedit_paste`).
    pub fn paste(e: *TextEdit, paste_text: []const u8) !void {
        e.clamp();
        e.deleteSelection();
        try e.string.insertAtRune(e.cursor, paste_text);
        e.cursor += unicode.utf8CountCodepoints(paste_text) catch 0;
        e.has_preferred_x = false;
    }

    /// The currently selected text, or empty (`nk_textedit_*` copy/cut helpers).
    pub fn selection(e: *const TextEdit) []const u8 {
        if (!e.hasSelection()) return "";
        var a = e.select_start;
        var b = e.select_end;
        if (b < a) {
            const t = a;
            a = b;
            b = t;
        }
        const begin = e.string.atRune(a) orelse return "";
        const end = e.string.atRune(b) orelse return "";
        return e.string.bytes()[begin.offset..end.offset];
    }
};

// --- tests ---------------------------------------------------------------

test "insert, cursor and backspace" {
    var e = try TextEdit.init(std.testing.allocator, 16);
    defer e.deinit();
    e.single_line = true;
    try e.insert("hello");
    try std.testing.expectEqualStrings("hello", e.text());
    try std.testing.expectEqual(@as(usize, 5), e.cursor);

    e.key(.left, false);
    e.key(.left, false); // cursor at index 3 (between 'l' and 'l')
    try e.insert("X");
    try std.testing.expectEqualStrings("helXlo", e.text());

    e.key(.backspace, false);
    try std.testing.expectEqualStrings("hello", e.text());
}

test "selection delete and select-all" {
    var e = try TextEdit.init(std.testing.allocator, 16);
    defer e.deinit();
    e.single_line = true;
    try e.insert("abcdef");

    // select the whole string and check selection text
    e.key(.text_select_all, false);
    try std.testing.expectEqualStrings("abcdef", e.selection());

    // typing replaces the selection
    try e.insert("Z");
    try std.testing.expectEqualStrings("Z", e.text());
}

test "shift+left extends selection, then delete" {
    var e = try TextEdit.init(std.testing.allocator, 16);
    defer e.deinit();
    e.single_line = true;
    try e.insert("hello");
    e.key(.left, true); // select 'o'
    e.key(.left, true); // select 'lo'
    try std.testing.expectEqualStrings("lo", e.selection());
    e.key(.backspace, false);
    try std.testing.expectEqualStrings("hel", e.text());
}

test "single line ignores newline" {
    var e = try TextEdit.init(std.testing.allocator, 16);
    defer e.deinit();
    e.single_line = true;
    try e.insert("a\nb");
    try std.testing.expectEqualStrings("ab", e.text());
}
