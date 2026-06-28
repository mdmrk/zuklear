//! The immediate-mode runtime core, ported from `nuklear_context.c`,
//! `nuklear_window.c`, `nuklear_panel.c` and `nuklear_layout.c`.
//!
//! This module ties everything together: the `Context` owns persistent
//! `Window`s, drives the per-frame begin/end lifecycle, and runs the layout
//! engine that hands each widget its bounds.
//!
//! Idiomatic departures from Nuklear's memory model (see PLAN.md):
//!   * No `nk_pool`/`nk_page_element`: windows/panels are allocated directly.
//!   * Windows live in a `Context`-owned z-order list plus a name→`*Window`
//!     map, instead of the intrusive `begin/end/prev/next` list.
//!   * Each `Window` owns its `CommandBuffer`; the per-window state table is an
//!     `AutoHashMap` with per-entry `seq` GC.
//!
//! First-cut scope: window create/find/GC, panel begin/end (header background +
//! title; window background; border; clip) and the row-layout engine
//! (`layoutRow*` + `widget`). Header close/minimize buttons, scrollbars and the
//! resize scaler are deferred to the widget phase (they need those widgets).

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const style_mod = @import("style.zig");
const command = @import("command.zig");
const input_mod = @import("input.zig");
const font_mod = @import("font.zig");
const text_widget = @import("text.zig");
const widget_mod = @import("widget.zig");
const button_widget = @import("button.zig");

const Vec2 = math.Vec2;
const Rect = math.Rect;
const Color = color.Color;
const Style = style_mod.Style;
const StyleItem = style_mod.StyleItem;
const Align = style_mod.Align;
const CommandBuffer = command.CommandBuffer;
const Input = input_mod.Input;
const UserFont = font_mod.UserFont;

pub const max_window_name = 64;

/// Scroll offset stored per window (`nk_scroll`).
pub const Scroll = struct { x: u32 = 0, y: u32 = 0 };

pub const ButtonBehavior = widget_mod.ButtonBehavior;

/// Sub-panel kind; the bit values match Nuklear so the set-membership tests
/// below work (`enum nk_panel_type`).
pub const PanelType = enum(u8) {
    none = 0,
    window = 1,
    group = 2,
    popup = 4,
    contextual = 16,
    combo = 32,
    menu = 64,
    tooltip = 128,

    const nonblock_set: u8 = 16 | 32 | 64 | 128;
    const sub_set: u8 = nonblock_set | 4 | 2;

    pub fn isNonblock(t: PanelType) bool {
        return @intFromEnum(t) & nonblock_set != 0;
    }
    pub fn isSub(t: PanelType) bool {
        return @intFromEnum(t) & sub_set != 0;
    }
};

/// How the current row computes widget widths (`enum nk_panel_row_layout_type`).
pub const RowLayoutType = enum {
    dynamic_fixed,
    dynamic_row,
    dynamic_free,
    dynamic,
    static_fixed,
    static_row,
    static_free,
    static,
    template,
};

pub const LayoutFormat = enum { dynamic, static };

pub const WidgetLayoutState = widget_mod.LayoutState;

/// Window option flags (`enum nk_window_flags`). Bits 0..10 are public options,
/// 11..16 are private/runtime state, matching upstream so the public/private
/// split in `beginTitled` works.
pub const WindowFlags = packed struct(u32) {
    border: bool = false,
    movable: bool = false,
    scalable: bool = false,
    closable: bool = false,
    minimizable: bool = false,
    no_scrollbar: bool = false,
    title: bool = false,
    scroll_auto_hide: bool = false,
    background: bool = false,
    scale_left: bool = false,
    no_input: bool = false,
    /// `NK_WINDOW_PRIVATE` / `NK_WINDOW_DYNAMIC` (bit 11).
    dynamic: bool = false,
    rom: bool = false,
    hidden: bool = false,
    closed: bool = false,
    minimized: bool = false,
    remove_rom: bool = false,
    _pad: u15 = 0,

    const private_mask: u32 = ~@as(u32, 0) << 11;

    /// Keep private/runtime bits, replace the public option bits (the
    /// `flags &= ~(NK_WINDOW_PRIVATE-1); flags |= new` update in `nk_begin`).
    pub fn replacePublic(old: WindowFlags, new: WindowFlags) WindowFlags {
        const o: u32 = @bitCast(old);
        const n: u32 = @bitCast(new);
        return @bitCast((o & private_mask) | (n & ~private_mask));
    }
};

/// Per-window persistent widget state (`nk_table`): hash → value, with a `seq`
/// per entry for end-of-frame garbage collection.
pub const WidgetState = struct {
    const Entry = struct { value: u32, seq: u32 };
    map: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

    pub fn deinit(s: *WidgetState, allocator: std.mem.Allocator) void {
        s.map.deinit(allocator);
    }

    /// Look up a value, marking it live for this frame.
    pub fn find(s: *WidgetState, name: u32, seq: u32) ?u32 {
        if (s.map.getPtr(name)) |e| {
            e.seq = seq;
            return e.value;
        }
        return null;
    }

    /// Insert or update a value, marking it live for this frame.
    pub fn set(s: *WidgetState, allocator: std.mem.Allocator, name: u32, value: u32, seq: u32) !void {
        try s.map.put(allocator, name, .{ .value = value, .seq = seq });
    }

    /// Drop entries not touched during the frame identified by `seq`.
    pub fn gc(s: *WidgetState, allocator: std.mem.Allocator, seq: u32) void {
        var stale: [32]u32 = undefined;
        while (true) {
            var n: usize = 0;
            var it = s.map.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.seq != seq) {
                    stale[n] = kv.key_ptr.*;
                    n += 1;
                    if (n == stale.len) break;
                }
            }
            if (n == 0) break;
            for (stale[0..n]) |k| _ = s.map.remove(k);
            _ = allocator;
        }
    }
};

/// The current row-layout state (`nk_row_layout`).
pub const RowLayout = struct {
    type: RowLayoutType = .dynamic_fixed,
    index: i32 = 0,
    height: f32 = 0,
    min_height: f32 = 0,
    columns: i32 = 0,
    ratio: ?[]const f32 = null,
    item_width: f32 = 0,
    item_height: f32 = 0,
    item_offset: f32 = 0,
    filled: f32 = 0,
    item: Rect = .{},
    tree_depth: i32 = 0,
    templates: [16]f32 = [_]f32{0} ** 16,
};

/// A layout region inside a window (`nk_panel`).
pub const Panel = struct {
    type: PanelType = .none,
    flags: WindowFlags = .{},
    bounds: Rect = .{},
    offset_x: *u32 = undefined,
    offset_y: *u32 = undefined,
    at_x: f32 = 0,
    at_y: f32 = 0,
    max_x: f32 = 0,
    footer_height: f32 = 0,
    header_height: f32 = 0,
    border: f32 = 0,
    has_scrolling: bool = false,
    clip: Rect = .{},
    row: RowLayout = .{},
    buffer: *CommandBuffer = undefined,
    parent: ?*Panel = null,
};

/// A persistent window (`nk_window`). Created on first `begin`, reused across
/// frames, GC'd by `clear` when no longer drawn.
pub const Window = struct {
    seq: u32 = 0,
    name: []const u8,
    flags: WindowFlags = .{},
    bounds: Rect = .{},
    scrollbar: Scroll = .{},
    buffer: CommandBuffer,
    layout: ?*Panel = null,
    scrollbar_hiding_timer: f32 = 0,
    scrolled: bool = false,
    widgets_disabled: bool = false,
    state: WidgetState = .{},
};

/// Hash seed Nuklear uses for window names (`NK_WINDOW_TITLE`).
const window_title_seed: u32 = 0x77696e64; // 'wind'

pub const Context = struct {
    allocator: std.mem.Allocator,
    input: Input = .{},
    style: Style,
    last_widget_state: widget_mod.States = .{},
    button_behavior: ButtonBehavior = .default,
    delta_time_seconds: f32 = 0,
    seq: u32 = 1,

    /// Windows in z-order (index 0 = bottom, last = top).
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    lookup: std.StringHashMapUnmanaged(*Window) = .empty,
    current: ?*Window = null,
    active: ?*Window = null,

    pub fn init(allocator: std.mem.Allocator, font: ?*const UserFont) Context {
        var s = Style.default();
        if (font) |f| s.font = f;
        return .{ .allocator = allocator, .style = s };
    }

    pub fn deinit(ctx: *Context) void {
        for (ctx.windows.items) |w| ctx.destroyWindow(w);
        ctx.windows.deinit(ctx.allocator);
        ctx.lookup.deinit(ctx.allocator);
        ctx.* = undefined;
    }

    fn destroyWindow(ctx: *Context, w: *Window) void {
        if (w.layout) |p| ctx.allocator.destroy(p);
        w.buffer.deinit();
        w.state.deinit(ctx.allocator);
        ctx.allocator.free(w.name);
        ctx.allocator.destroy(w);
    }

    /// End-of-frame reset: garbage-collect windows not drawn this frame and
    /// advance the sequence counter (`nk_clear`).
    pub fn clear(ctx: *Context) void {
        ctx.last_widget_state = .{};
        var i: usize = 0;
        while (i < ctx.windows.items.len) {
            const w = ctx.windows.items[i];
            if (w.seq != ctx.seq or w.flags.closed) {
                if (ctx.active == w) ctx.active = null;
                _ = ctx.lookup.remove(w.name);
                _ = ctx.windows.orderedRemove(i);
                ctx.destroyWindow(w);
            } else {
                w.state.gc(ctx.allocator, ctx.seq);
                i += 1;
            }
        }
        ctx.seq +%= 1;
    }

    // --- window lifecycle -------------------------------------------------

    pub fn begin(ctx: *Context, title: []const u8, bounds: Rect, flags: WindowFlags) !bool {
        return ctx.beginTitled(title, title, bounds, flags);
    }

    pub fn beginTitled(ctx: *Context, name: []const u8, title: []const u8, bounds: Rect, flags: WindowFlags) !bool {
        std.debug.assert(ctx.current == null); // forgot a matching end()?
        std.debug.assert(ctx.style.font != null); // forgot to set a font?

        var win: *Window = undefined;
        if (ctx.lookup.get(name)) |existing| {
            win = existing;
            std.debug.assert(win.seq != ctx.seq); // window begun twice this frame
            win.flags = WindowFlags.replacePublic(win.flags, flags);
            if (!(win.flags.movable or win.flags.scalable)) win.bounds = bounds;
            win.seq = ctx.seq;
            if (ctx.active == null and !win.flags.hidden) ctx.active = win;
        } else {
            win = try ctx.allocator.create(Window);
            const name_copy = try ctx.allocator.dupe(u8, name[0..@min(name.len, max_window_name - 1)]);
            win.* = .{
                .name = name_copy,
                .flags = flags,
                .bounds = bounds,
                .buffer = CommandBuffer.init(ctx.allocator),
                .seq = ctx.seq,
            };
            errdefer ctx.destroyWindow(win);
            if (flags.background) {
                try ctx.windows.insert(ctx.allocator, 0, win); // bottom
            } else {
                try ctx.windows.append(ctx.allocator, win); // top
            }
            try ctx.lookup.put(ctx.allocator, name_copy, win);
            if (ctx.active == null) ctx.active = win;
        }

        if (win.flags.hidden) {
            ctx.current = win;
            win.layout = null;
            return false;
        }

        win.buffer.reset(); // nk_start: fresh command buffer for the frame

        const panel = try ctx.allocator.create(Panel);
        panel.* = .{
            .buffer = &win.buffer,
            .offset_x = &win.scrollbar.x,
            .offset_y = &win.scrollbar.y,
        };
        win.layout = panel;
        ctx.current = win;
        return ctx.panelBegin(title, .window);
    }

    pub fn end(ctx: *Context) void {
        std.debug.assert(ctx.current != null); // forgot begin()?
        const win = ctx.current.?;
        const layout = win.layout orelse {
            ctx.current = null;
            return;
        };
        if (layout.type == .window and win.flags.hidden) {
            ctx.current = null;
            return;
        }
        ctx.panelEnd();
        ctx.allocator.destroy(layout);
        win.layout = null;
        ctx.current = null;
    }

    /// The command list produced for `name` this frame, or null.
    pub fn windowCommands(ctx: *Context, name: []const u8) ?[]const command.Command {
        const w = ctx.lookup.get(name) orelse return null;
        return w.buffer.items();
    }

    // --- panel ------------------------------------------------------------

    fn panelGetPadding(s: *const Style, t: PanelType) Vec2 {
        return switch (t) {
            .group => s.window.group_padding,
            .popup => s.window.popup_padding,
            .contextual => s.window.contextual_padding,
            .combo => s.window.combo_padding,
            .menu, .tooltip => s.window.menu_padding,
            else => s.window.padding,
        };
    }

    fn panelGetBorder(s: *const Style, flags: WindowFlags, t: PanelType) f32 {
        if (!flags.border) return 0;
        return switch (t) {
            .group => s.window.group_border,
            .popup => s.window.popup_border,
            .contextual => s.window.contextual_border,
            .combo => s.window.combo_border,
            .menu, .tooltip => s.window.menu_border,
            else => s.window.border,
        };
    }

    fn panelGetBorderColor(s: *const Style, t: PanelType) Color {
        return switch (t) {
            .group => s.window.group_border_color,
            .popup => s.window.popup_border_color,
            .contextual => s.window.contextual_border_color,
            .combo => s.window.combo_border_color,
            .menu, .tooltip => s.window.menu_border_color,
            else => s.window.border_color,
        };
    }

    fn panelHasHeader(flags: WindowFlags, title: ?[]const u8) bool {
        const active = flags.closable or flags.minimizable or flags.title;
        return active and !flags.hidden and title != null;
    }

    fn resetMinRowHeight(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        const s = &ctx.style;
        layout.row.min_height = s.font.?.height + s.text.padding.y * 2 + s.window.min_row_height_padding * 2;
    }

    fn panelBegin(ctx: *Context, title: []const u8, panel_type: PanelType) bool {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const font = s.font.?;
        const out = &win.buffer;

        if (win.flags.hidden or win.flags.closed) {
            layout.* = .{ .buffer = out, .offset_x = layout.offset_x, .offset_y = layout.offset_y, .type = panel_type };
            return false;
        }

        const scrollbar_size = s.window.scrollbar_size;
        const panel_padding = panelGetPadding(s, panel_type);

        // window movement by dragging the header
        if (win.flags.movable and !win.flags.rom and !win.flags.no_input) {
            const in = &ctx.input;
            var header = win.bounds;
            if (panelHasHeader(win.flags, title)) {
                header.h = font.height + 2.0 * s.window.header.padding.y + 2.0 * s.window.header.label_padding.y;
            } else header.h = panel_padding.y;

            const down = in.mouse.buttons[@intFromEnum(input_mod.Button.left)].down;
            const clicked = in.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked != 0;
            if (down and in.hasMouseClickDownInRect(.left, header, true) and !clicked) {
                win.bounds.x += in.mouse.delta.x;
                win.bounds.y += in.mouse.delta.y;
            }
        }

        // set up the panel region
        layout.type = panel_type;
        layout.flags = win.flags;
        layout.bounds = win.bounds;
        layout.bounds.x += panel_padding.x;
        layout.bounds.w -= 2 * panel_padding.x;
        if (win.flags.border) {
            layout.border = panelGetBorder(s, win.flags, panel_type);
            layout.bounds = layout.bounds.shrink(layout.border);
        } else layout.border = 0;
        layout.at_y = layout.bounds.y;
        layout.at_x = layout.bounds.x;
        layout.max_x = 0;
        layout.header_height = 0;
        layout.footer_height = 0;
        ctx.resetMinRowHeight();
        layout.row.index = 0;
        layout.row.columns = 0;
        layout.row.ratio = null;
        layout.row.item_width = 0;
        layout.row.tree_depth = 0;
        layout.row.height = panel_padding.y;
        layout.has_scrolling = true;
        if (!win.flags.no_scrollbar) layout.bounds.w -= scrollbar_size.x;
        if (!panel_type.isNonblock()) {
            layout.footer_height = 0;
            if (!win.flags.no_scrollbar or win.flags.scalable) layout.footer_height = scrollbar_size.y;
            layout.bounds.h -= layout.footer_height;
        }

        // header (background + title; close/minimize buttons deferred to Phase 4)
        if (panelHasHeader(win.flags, title)) {
            var header = win.bounds;
            header.h = font.height + 2.0 * s.window.header.padding.y + 2.0 * s.window.header.label_padding.y;

            layout.header_height = header.h;
            layout.bounds.y += header.h;
            layout.bounds.h -= header.h;
            layout.at_y += header.h;

            var bg: StyleItem = undefined;
            var text_color: Color = undefined;
            if (ctx.active == win) {
                bg = s.window.header.active;
                text_color = s.window.header.label_active;
            } else if (ctx.input.isMouseHoveringRect(header)) {
                bg = s.window.header.hover;
                text_color = s.window.header.label_hover;
            } else {
                bg = s.window.header.normal;
                text_color = s.window.header.label_normal;
            }

            header.h += 1.0;
            var text_bg: Color = .{ .a = 0 };
            switch (bg) {
                .image => |img| out.drawImage(header, img, Color.white) catch {},
                .nine_slice => |sl| out.drawNineSlice(header, sl, Color.white) catch {},
                .color => |col| {
                    text_bg = col;
                    out.fillRect(header, 0, col) catch {};
                },
            }

            // title label
            var title_label = Rect{};
            const t = font.textWidth(title);
            title_label.x = header.x + s.window.header.padding.x + s.window.header.label_padding.x;
            title_label.y = header.y + s.window.header.label_padding.y;
            title_label.h = font.height + 2 * s.window.header.label_padding.y;
            title_label.w = std.math.clamp(t + 2 * s.window.header.spacing.x, 0, header.x + header.w - title_label.x);
            out.drawText(title_label, title, font, text_bg, text_color) catch {};
        }

        // window background
        if (!layout.flags.minimized and !layout.flags.dynamic) {
            var body = win.bounds;
            body.y = win.bounds.y + layout.header_height;
            body.h = win.bounds.h - layout.header_height;
            switch (s.window.fixed_background) {
                .image => |img| out.drawImage(body, img, Color.white) catch {},
                .nine_slice => |sl| out.drawNineSlice(body, sl, Color.white) catch {},
                .color => |col| out.fillRect(body, s.window.rounding, col) catch {},
            }
        }

        // clip rectangle
        const clip = win.buffer.clip.unify(
            layout.bounds.x,
            layout.bounds.y,
            layout.bounds.x + layout.bounds.w,
            layout.bounds.y + layout.bounds.h,
        );
        out.pushScissor(clip) catch {};
        layout.clip = clip;
        return !layout.flags.hidden and !layout.flags.minimized;
    }

    fn panelEnd(ctx: *Context) void {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const out = &win.buffer;

        if (!layout.type.isSub()) out.pushScissor(math.null_rect) catch {};
        layout.at_y += layout.row.height;

        // NOTE: scrollbars, the resize scaler and scroll-auto-hide are deferred
        // to the widget phase (they require the scrollbar/button widgets).

        if (layout.flags.border) {
            const border_color = panelGetBorderColor(s, layout.type);
            const padding_y = if (layout.flags.minimized)
                s.window.border + win.bounds.y + layout.header_height
            else if (layout.flags.dynamic)
                layout.bounds.y + layout.bounds.h + layout.footer_height
            else
                win.bounds.y + win.bounds.h;
            var b = win.bounds;
            b.h = padding_y - win.bounds.y;
            out.strokeRect(b, s.window.rounding, layout.border, border_color) catch {};
        }
    }

    // --- layout engine ----------------------------------------------------

    fn usableSpace(s: *const Style, total: f32, columns: i32) f32 {
        const panel_spacing = @as(f32, @floatFromInt(@max(columns - 1, 0))) * s.window.spacing.x;
        return total - panel_spacing;
    }

    fn panelLayout(ctx: *Context, height: f32, cols: i32) void {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const item_spacing = s.window.spacing;

        layout.row.index = 0;
        layout.at_y += layout.row.height;
        layout.row.columns = cols;
        layout.row.height = (if (height == 0) @max(height, layout.row.min_height) else height) + item_spacing.y;
        layout.row.item_offset = 0;

        if (layout.flags.dynamic) {
            var background = win.bounds;
            background.y = layout.at_y - 1.0;
            background.h = layout.row.height + 1.0;
            win.buffer.fillRect(background, 0, s.window.background) catch {};
        }
    }

    fn rowLayout(ctx: *Context, fmt: LayoutFormat, height: f32, cols: i32, width: f32) void {
        const layout = ctx.current.?.layout.?;
        ctx.panelLayout(height, cols);
        layout.row.type = if (fmt == .dynamic) .dynamic_fixed else .static_fixed;
        layout.row.ratio = null;
        layout.row.filled = 0;
        layout.row.item_offset = 0;
        layout.row.item_width = width;
    }

    /// Begin a row of `cols` equal-width, panel-relative columns
    /// (`nk_layout_row_dynamic`).
    pub fn layoutRowDynamic(ctx: *Context, height: f32, cols: i32) void {
        ctx.rowLayout(.dynamic, height, cols, 0);
    }

    /// Begin a row of `cols` fixed-`item_width`-pixel columns
    /// (`nk_layout_row_static`).
    pub fn layoutRowStatic(ctx: *Context, height: f32, item_width: f32, cols: i32) void {
        ctx.rowLayout(.static, height, cols, item_width);
    }

    fn frac(x: f32) f32 {
        return x - @round(x);
    }

    fn layoutWidgetSpace(ctx: *Context, modify: bool) Rect {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const spacing = s.window.spacing;
        const panel_space = usableSpace(s, layout.bounds.w, layout.row.columns);
        const off_x: f32 = @floatFromInt(layout.offset_x.*);
        const off_y: f32 = @floatFromInt(layout.offset_y.*);
        const idx: f32 = @floatFromInt(layout.row.index);

        var item_offset: f32 = 0;
        var item_width: f32 = 0;
        var item_spacing: f32 = 0;
        var bounds = Rect{};

        switch (layout.row.type) {
            .dynamic_fixed => {
                const w = @max(1.0, panel_space) / @as(f32, @floatFromInt(layout.row.columns));
                item_offset = idx * w;
                item_width = w + frac(item_offset);
                item_spacing = idx * spacing.x;
            },
            .dynamic_row => {
                const w = layout.row.item_width * panel_space;
                item_offset = layout.row.item_offset;
                item_width = w + frac(item_offset);
                item_spacing = 0;
                if (modify) {
                    layout.row.item_offset += w + spacing.x;
                    layout.row.filled += layout.row.item_width;
                    layout.row.index = 0;
                }
            },
            .dynamic_free => {
                bounds.x = layout.at_x + layout.bounds.w * layout.row.item.x - off_x;
                bounds.y = layout.at_y + layout.row.height * layout.row.item.y - off_y;
                bounds.w = layout.bounds.w * layout.row.item.w + frac(bounds.x);
                bounds.h = layout.row.height * layout.row.item.h + frac(bounds.y);
                return bounds;
            },
            .dynamic => {
                const r = layout.row.ratio.?;
                const ratio = if (r[@intCast(layout.row.index)] < 0) layout.row.item_width else r[@intCast(layout.row.index)];
                const w = ratio * panel_space;
                item_spacing = idx * spacing.x;
                item_offset = layout.row.item_offset;
                item_width = w + frac(item_offset);
                if (modify) {
                    layout.row.item_offset += w;
                    layout.row.filled += ratio;
                }
            },
            .static_fixed => {
                item_width = layout.row.item_width;
                item_offset = idx * item_width;
                item_spacing = idx * spacing.x;
            },
            .static_row => {
                item_width = layout.row.item_width;
                item_offset = layout.row.item_offset;
                item_spacing = idx * spacing.x;
                if (modify) layout.row.item_offset += item_width;
            },
            .static_free => {
                bounds.x = layout.at_x + layout.row.item.x;
                bounds.w = layout.row.item.w;
                if (bounds.x + bounds.w > layout.max_x and modify) layout.max_x = bounds.x + bounds.w;
                bounds.x -= off_x;
                bounds.y = layout.at_y + layout.row.item.y - off_y;
                bounds.h = layout.row.item.h;
                return bounds;
            },
            .static => {
                item_spacing = idx * spacing.x;
                item_width = layout.row.ratio.?[@intCast(layout.row.index)];
                item_offset = layout.row.item_offset;
                if (modify) layout.row.item_offset += item_width;
            },
            .template => {
                const w = layout.row.templates[@intCast(layout.row.index)];
                item_offset = layout.row.item_offset;
                item_width = w + frac(item_offset);
                item_spacing = idx * spacing.x;
                if (modify) layout.row.item_offset += w;
            },
        }

        bounds.w = item_width;
        bounds.h = layout.row.height - spacing.y;
        bounds.y = layout.at_y - off_y;
        bounds.x = layout.at_x + item_offset + item_spacing;
        if (bounds.x + bounds.w > layout.max_x and modify) layout.max_x = bounds.x + bounds.w;
        bounds.x -= off_x;
        return bounds;
    }

    fn panelAllocRow(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        const row_height = layout.row.height - ctx.style.window.spacing.y;
        ctx.panelLayout(row_height, layout.row.columns);
    }

    fn panelAllocSpace(ctx: *Context) Rect {
        const layout = ctx.current.?.layout.?;
        if (layout.row.index >= layout.row.columns) ctx.panelAllocRow();
        const bounds = ctx.layoutWidgetSpace(true);
        layout.row.index += 1;
        return bounds;
    }

    pub const WidgetResult = struct { state: WidgetLayoutState, bounds: Rect };

    /// Allocate the next widget slot and report its visibility/interactivity
    /// (`nk_widget`).
    pub fn widget(ctx: *Context) WidgetResult {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const in = &ctx.input;

        var bounds = ctx.panelAllocSpace();
        var c = layout.clip;

        // truncate to integers to avoid floating point seams
        bounds.x = @trunc(bounds.x);
        bounds.y = @trunc(bounds.y);
        bounds.w = @trunc(bounds.w);
        bounds.h = @trunc(bounds.h);
        c.x = @trunc(c.x);
        c.y = @trunc(c.y);
        c.w = @trunc(c.w);
        c.h = @trunc(c.h);

        const v = c.unify(bounds.x, bounds.y, bounds.x + bounds.w, bounds.y + bounds.h);
        if (!c.intersects(bounds)) return .{ .state = .invalid, .bounds = bounds };
        if (win.widgets_disabled) return .{ .state = .disabled, .bounds = bounds };
        if (!v.contains(in.mouse.pos)) return .{ .state = .rom, .bounds = bounds };
        return .{ .state = .valid, .bounds = bounds };
    }

    // --- text widgets -----------------------------------------------------

    /// Draw a text label in color `col` in the next layout slot
    /// (`nk_text_colored`).
    pub fn textColored(ctx: *Context, str: []const u8, alignment: Align, col: Color) !void {
        const win = ctx.current.?;
        const s = &ctx.style;
        const bounds = ctx.panelAllocSpace();
        try text_widget.widgetText(
            &win.buffer,
            bounds,
            str,
            alignment,
            s.text.padding,
            s.window.background,
            col.factor(s.text.color_factor),
            s.font.?,
        );
    }

    /// Draw a text label in the default text color (`nk_text` / `nk_label`).
    pub fn label(ctx: *Context, str: []const u8, alignment: Align) !void {
        try ctx.textColored(str, alignment, ctx.style.text.color);
    }

    // --- button widgets ---------------------------------------------------

    /// A text button using an explicit style (`nk_button_text_styled`).
    pub fn buttonTextStyled(ctx: *Context, btn_style: *const style_mod.StyleButton, title: []const u8) !bool {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const in: ?*const Input = if (w.state == .rom or w.state == .disabled or layout.flags.rom) null else &ctx.input;
        return button_widget.doButtonText(
            &ctx.last_widget_state,
            &win.buffer,
            w.bounds,
            title,
            btn_style.text_alignment,
            ctx.button_behavior,
            btn_style,
            in,
            ctx.style.font.?,
        );
    }

    /// A text button in the default style (`nk_button_label` / `nk_button_text`).
    pub fn buttonLabel(ctx: *Context, title: []const u8) !bool {
        return ctx.buttonTextStyled(&ctx.style.button, title);
    }
};

// --- tests ---------------------------------------------------------------

fn testWidth(_: @import("handle.zig").Handle, _: f32, text: []const u8) f32 {
    return @as(f32, @floatFromInt(text.len)) * 7.0;
}
const test_font = UserFont{ .height = 13, .width = &testWidth };

test "begin/layout/widget/end produces commands and lays out a row" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    // place the cursor inside the first widget so it reports as interactive
    ctx.input.mouse.pos = .{ .x = 20, .y = 50 };

    const visible = try ctx.begin("win", Rect.init(0, 0, 200, 200), .{ .border = true, .title = true });
    try std.testing.expect(visible);

    ctx.layoutRowDynamic(30, 2);
    const a = ctx.widget();
    const b = ctx.widget();
    try std.testing.expectEqual(WidgetLayoutState.valid, a.state);
    // two columns: second widget is to the right of the first
    try std.testing.expect(b.bounds.x > a.bounds.x);
    try std.testing.expectApproxEqAbs(a.bounds.h, 30, 0.001);
    ctx.end();

    // header background, title text, body background, scissor, border, etc.
    const cmds = ctx.windowCommands("win").?;
    try std.testing.expect(cmds.len > 0);
}

test "window is reused across frames and GC'd when dropped" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    // frame 1: two windows
    _ = try ctx.begin("a", Rect.init(0, 0, 100, 100), .{ .title = true });
    ctx.end();
    _ = try ctx.begin("b", Rect.init(0, 0, 100, 100), .{ .title = true });
    ctx.end();
    const win_a = ctx.lookup.get("a").?;
    try std.testing.expectEqual(@as(usize, 2), ctx.windows.items.len);
    ctx.clear();

    // frame 2: only "a" — "b" should be collected
    _ = try ctx.begin("a", Rect.init(0, 0, 100, 100), .{ .title = true });
    ctx.end();
    try std.testing.expectEqual(win_a, ctx.lookup.get("a").?); // same window reused
    ctx.clear();
    try std.testing.expectEqual(@as(usize, 1), ctx.windows.items.len);
    try std.testing.expect(ctx.lookup.get("b") == null);
}

test "label emits a text command in the current row" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    _ = try ctx.begin("win", Rect.init(0, 0, 200, 100), .{});
    ctx.layoutRowDynamic(20, 1);
    try ctx.label("hello", .{ .left = true, .middle = true });
    ctx.end();
    const cmds = ctx.windowCommands("win").?;
    var found = false;
    for (cmds) |c| if (c == .text) {
        try std.testing.expectEqualStrings("hello", c.text.string);
        found = true;
    };
    try std.testing.expect(found);
}

test "button click is detected through the context" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    // place cursor and press inside where the button will be laid out
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 30, .y = 30 };
    ctx.input.button(.left, 30, 30, true);

    _ = try ctx.begin("win", Rect.init(0, 0, 200, 200), .{});
    ctx.layoutRowDynamic(40, 1);
    const clicked = try ctx.buttonLabel("press");
    ctx.end();
    try std.testing.expect(clicked);
}

test "hidden window reports not visible" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    const visible = try ctx.begin("h", Rect.init(0, 0, 100, 100), .{ .hidden = true });
    try std.testing.expect(!visible);
    ctx.end();
}

test "WindowFlags.replacePublic keeps private bits" {
    const old = WindowFlags{ .minimized = true, .border = true };
    const new = WindowFlags{ .title = true, .movable = true };
    const merged = WindowFlags.replacePublic(old, new);
    try std.testing.expect(merged.minimized); // private bit kept
    try std.testing.expect(merged.title); // new public bit
    try std.testing.expect(!merged.border); // old public bit cleared
}

test "PanelType set membership" {
    try std.testing.expect(PanelType.menu.isNonblock());
    try std.testing.expect(!PanelType.window.isNonblock());
    try std.testing.expect(PanelType.group.isSub());
    try std.testing.expect(!PanelType.window.isSub());
}
