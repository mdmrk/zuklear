//! Mouse and keyboard input state, ported from `nuklear_input.c`.
//!
//! In Nuklear the input lives inside `nk_context` and the feed functions take
//! the context; here `Input` is self-contained with methods. The few
//! hover-delay helpers that needed `ctx->delta_time_seconds` take an explicit
//! `delta_time` argument instead.

const std = @import("std");
const math = @import("math.zig");
const utf8 = @import("utf8.zig");

const Vec2 = math.Vec2;
const Rect = math.Rect;

/// Maximum bytes of text input buffered per frame (`NK_INPUT_MAX`).
pub const input_max = 16;

/// Logical keys and editor shortcuts (`enum nk_keys`).
pub const Key = enum {
    none,
    shift,
    ctrl,
    del,
    enter,
    tab,
    backspace,
    copy,
    cut,
    paste,
    up,
    down,
    left,
    right,
    text_insert_mode,
    text_replace_mode,
    text_reset_mode,
    text_line_start,
    text_line_end,
    text_start,
    text_end,
    text_undo,
    text_redo,
    text_select_all,
    text_word_left,
    text_word_right,
    scroll_start,
    scroll_end,
    scroll_down,
    scroll_up,
    alt,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// Mouse buttons (`enum nk_buttons`).
pub const Button = enum {
    left,
    middle,
    right,
    /// Double click of the left button.
    double,
    /// Mouse button 4 ("back").
    x1,
    /// Mouse button 5 ("forward").
    x2,
};

const key_count = @typeInfo(Key).@"enum".fields.len;
const button_count = @typeInfo(Button).@"enum".fields.len;

const KeyState = struct { down: bool = false, clicked: u32 = 0 };
const MouseButton = struct { down: bool = false, clicked: u32 = 0, clicked_pos: Vec2 = .{} };

pub const Mouse = struct {
    buttons: [button_count]MouseButton = [_]MouseButton{.{}} ** button_count,
    pos: Vec2 = .{},
    prev: Vec2 = .{},
    delta: Vec2 = .{},
    scroll_delta: Vec2 = .{},
    grab: bool = false,
    grabbed: bool = false,
    ungrab: bool = false,
};

pub const Keyboard = struct {
    keys: [key_count]KeyState = [_]KeyState{.{}} ** key_count,
    text: [input_max]u8 = undefined,
    text_len: usize = 0,
};

pub const Input = struct {
    keyboard: Keyboard = .{},
    mouse: Mouse = .{},

    fn btn(in: anytype, id: Button) @TypeOf(&in.mouse.buttons[0]) {
        return &in.mouse.buttons[@intFromEnum(id)];
    }

    // --- frame feed -------------------------------------------------------

    /// Begin a new input frame, clearing per-frame state (`nk_input_begin`).
    pub fn begin(in: *Input) void {
        for (&in.mouse.buttons) |*b| b.clicked = 0;
        in.keyboard.text_len = 0;
        in.mouse.scroll_delta = .{};
        in.mouse.prev = in.mouse.pos;
        in.mouse.delta = .{};
        for (&in.keyboard.keys) |*k| k.clicked = 0;
    }

    /// End an input frame, resolving grab state (`nk_input_end`).
    pub fn end(in: *Input) void {
        in.mouse.grab = false;
        if (in.mouse.ungrab) {
            in.mouse.grabbed = false;
            in.mouse.ungrab = false;
        }
    }

    /// Report a new mouse position (`nk_input_motion`).
    pub fn motion(in: *Input, x: i32, y: i32) void {
        in.mouse.pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
        in.mouse.delta = in.mouse.pos.sub(in.mouse.prev);
    }

    /// Report a key state change (`nk_input_key`).
    pub fn key(in: *Input, k: Key, down: bool) void {
        const s = &in.keyboard.keys[@intFromEnum(k)];
        s.clicked += 1;
        s.down = down;
    }

    /// Report a mouse button state change at a position (`nk_input_button`).
    pub fn button(in: *Input, id: Button, x: i32, y: i32, down: bool) void {
        const b = in.btn(id);
        if (b.down == down) return;
        b.clicked_pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
        b.down = down;
        b.clicked += 1;
        in.mouse.delta = .{};
    }

    /// Accumulate scroll wheel movement (`nk_input_scroll`).
    pub fn scroll(in: *Input, val: Vec2) void {
        in.mouse.scroll_delta = in.mouse.scroll_delta.add(val);
    }

    /// Buffer one Unicode codepoint of text input (`nk_input_unicode`).
    pub fn unicode(in: *Input, rune: u21) void {
        var tmp: [utf8.max_size]u8 = undefined;
        const n = utf8.encode(rune, &tmp);
        if (n == 0 or in.keyboard.text_len + n >= input_max) return;
        @memcpy(in.keyboard.text[in.keyboard.text_len..][0..n], tmp[0..n]);
        in.keyboard.text_len += n;
    }

    /// Buffer one ASCII character (`nk_input_char`).
    pub fn char(in: *Input, c: u8) void {
        in.unicode(c);
    }

    /// Buffer the first glyph of a UTF-8 byte sequence (`nk_input_glyph`).
    pub fn glyph(in: *Input, bytes: []const u8) void {
        const d = utf8.decode(bytes);
        if (d.len != 0) in.unicode(d.rune);
    }

    /// The text buffered this frame.
    pub fn text(in: *const Input) []const u8 {
        return in.keyboard.text[0..in.keyboard.text_len];
    }

    // --- mouse queries ----------------------------------------------------

    pub fn hasMouseClick(in: *const Input, id: Button) bool {
        const b = in.mouse.buttons[@intFromEnum(id)];
        return b.clicked != 0 and !b.down;
    }

    pub fn hasMouseClickInRect(in: *const Input, id: Button, r: Rect) bool {
        return r.contains(in.mouse.buttons[@intFromEnum(id)].clicked_pos);
    }

    pub fn hasMouseClickDownInRect(in: *const Input, id: Button, r: Rect, down: bool) bool {
        return in.hasMouseClickInRect(id, r) and in.mouse.buttons[@intFromEnum(id)].down == down;
    }

    pub fn isMouseClickInRect(in: *const Input, id: Button, r: Rect) bool {
        return in.hasMouseClickDownInRect(id, r, false) and in.mouse.buttons[@intFromEnum(id)].clicked != 0;
    }

    pub fn isMouseClickDownInRect(in: *const Input, id: Button, r: Rect, down: bool) bool {
        return in.hasMouseClickDownInRect(id, r, down) and in.mouse.buttons[@intFromEnum(id)].clicked != 0;
    }

    pub fn anyMouseClickInRect(in: *const Input, r: Rect) bool {
        inline for (std.meta.fields(Button)) |f| {
            if (in.isMouseClickInRect(@enumFromInt(f.value), r)) return true;
        }
        return false;
    }

    pub fn isMouseHoveringRect(in: *const Input, r: Rect) bool {
        return r.contains(in.mouse.pos);
    }

    pub fn isMouseHoveringStillRect(in: *const Input, r: Rect) bool {
        return r.contains(in.mouse.pos) and !in.isMouseMoved();
    }

    pub fn isMousePrevHoveringRect(in: *const Input, r: Rect) bool {
        return r.contains(in.mouse.prev);
    }

    pub fn mouseClicked(in: *const Input, id: Button, r: Rect) bool {
        return in.isMouseHoveringRect(r) and in.isMouseClickInRect(id, r);
    }

    pub fn isMouseDown(in: *const Input, id: Button) bool {
        return in.mouse.buttons[@intFromEnum(id)].down;
    }

    pub fn isMousePressed(in: *const Input, id: Button) bool {
        const b = in.mouse.buttons[@intFromEnum(id)];
        return b.down and b.clicked != 0;
    }

    pub fn isMouseReleased(in: *const Input, id: Button) bool {
        const b = in.mouse.buttons[@intFromEnum(id)];
        return !b.down and b.clicked != 0;
    }

    pub fn isMouseMoved(in: *const Input) bool {
        return in.mouse.delta.x != 0 or in.mouse.delta.y != 0;
    }

    /// True after the mouse has hovered `r` for `delay` seconds. `timer`
    /// accumulates across frames (`nk_input_is_mouse_hovering_delay_rect`).
    pub fn isMouseHoveringDelayRect(in: *const Input, r: Rect, timer: *f32, delay: f32, delta_time: f32) bool {
        if (r.contains(in.mouse.pos)) {
            timer.* += delta_time;
            return timer.* >= delay;
        } else if (r.contains(in.mouse.prev)) {
            timer.* = 0;
        }
        return false;
    }

    // --- keyboard queries -------------------------------------------------

    pub fn isKeyPressed(in: *const Input, k: Key) bool {
        const s = in.keyboard.keys[@intFromEnum(k)];
        return (s.down and s.clicked != 0) or (!s.down and s.clicked >= 2);
    }

    pub fn isKeyReleased(in: *const Input, k: Key) bool {
        const s = in.keyboard.keys[@intFromEnum(k)];
        return (!s.down and s.clicked != 0) or (s.down and s.clicked >= 2);
    }

    pub fn isKeyDown(in: *const Input, k: Key) bool {
        return in.keyboard.keys[@intFromEnum(k)].down;
    }
};

test "mouse motion tracks delta across frames" {
    var in: Input = .{};
    in.begin();
    in.motion(10, 20);
    try std.testing.expectEqual(Vec2.init(10, 20), in.mouse.pos);
    try std.testing.expectEqual(Vec2.init(10, 20), in.mouse.delta);
    in.end();

    in.begin(); // prev <- pos, delta reset
    in.motion(15, 20);
    try std.testing.expectEqual(Vec2.init(5, 0), in.mouse.delta);
    try std.testing.expect(in.isMouseMoved());
}

test "click detection in rect" {
    var in: Input = .{};
    const r = Rect.init(0, 0, 100, 100);
    in.begin();
    in.button(.left, 50, 50, true); // press inside
    try std.testing.expect(in.isMouseDown(.left));
    try std.testing.expect(in.isMousePressed(.left));
    in.button(.left, 50, 50, false); // release inside
    try std.testing.expect(in.isMouseReleased(.left));
    try std.testing.expect(in.isMouseClickInRect(.left, r));
    try std.testing.expect(in.mouseClicked(.left, r) == in.isMouseHoveringRect(r));
}

test "click outside rect is not detected" {
    var in: Input = .{};
    const r = Rect.init(0, 0, 10, 10);
    in.begin();
    in.button(.left, 50, 50, true);
    in.button(.left, 50, 50, false);
    try std.testing.expect(!in.isMouseClickInRect(.left, r));
    try std.testing.expect(in.anyMouseClickInRect(Rect.init(0, 0, 100, 100)));
}

test "key press and release semantics" {
    var in: Input = .{};
    in.begin();
    in.key(.enter, true);
    try std.testing.expect(in.isKeyDown(.enter));
    try std.testing.expect(in.isKeyPressed(.enter));
    in.begin(); // clicked counters reset
    in.key(.enter, false);
    try std.testing.expect(in.isKeyReleased(.enter));
    try std.testing.expect(!in.isKeyDown(.enter));
}

test "scroll accumulates and text input buffers" {
    var in: Input = .{};
    in.begin();
    in.scroll(Vec2.init(0, 1));
    in.scroll(Vec2.init(0, 2));
    try std.testing.expectEqual(Vec2.init(0, 3), in.mouse.scroll_delta);
    in.char('h');
    in.char('i');
    in.unicode(0x20AC);
    try std.testing.expectEqualStrings("hi\u{20AC}", in.text());
}

test "text input respects buffer limit" {
    var in: Input = .{};
    in.begin();
    for (0..20) |_| in.char('x');
    try std.testing.expect(in.text().len < input_max);
}
