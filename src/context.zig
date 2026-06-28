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
const toggle_widget = @import("toggle.zig");
const slider_widget = @import("slider.zig");
const progress_widget = @import("progress.zig");
const scrollbar_widget = @import("scrollbar.zig");
const selectable_widget = @import("selectable.zig");
const image_mod = @import("image.zig");
const knob_widget = @import("knob.zig");
const color_picker_widget = @import("color_picker.zig");
const text_editor = @import("text_editor.zig");

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

/// Collapsed/expanded state of a tree node (`nk_collapse_states`).
pub const CollapseState = enum { minimized, maximized };

/// Tree node visual style (`nk_tree_type`).
pub const TreeType = enum { node, tab };

/// Text-edit option flags (`enum nk_edit_flags`).
pub const EditFlags = packed struct(u32) {
    read_only: bool = false,
    auto_select: bool = false,
    sig_enter: bool = false,
    allow_tab: bool = false,
    no_cursor: bool = false,
    selectable: bool = false,
    clipboard: bool = false,
    ctrl_enter_newline: bool = false,
    no_horizontal_scroll: bool = false,
    always_insert_mode: bool = false,
    multiline: bool = false,
    goto_end_on_activate: bool = false,
    _pad: u20 = 0,

    pub const simple: EditFlags = .{ .always_insert_mode = true };
    pub const field: EditFlags = .{ .always_insert_mode = true, .selectable = true, .clipboard = true };
    pub const box: EditFlags = .{ .always_insert_mode = true, .selectable = true, .multiline = true, .allow_tab = true, .clipboard = true };
    pub const editor: EditFlags = .{ .selectable = true, .multiline = true, .allow_tab = true, .clipboard = true };
};

/// Result of an edit widget for the frame (`enum nk_edit_events`).
pub const EditEvents = struct {
    active: bool = false,
    inactive: bool = false,
    activated: bool = false,
    deactivated: bool = false,
    committed: bool = false,
};

/// Chart plot style (`nk_chart_type`).
pub const ChartType = enum { lines, column };

/// Result of pushing a chart data point (`nk_chart_event`).
pub const ChartEvent = struct { hovering: bool = false, clicked: bool = false };

const chart_max_slot = 4;

const ChartSlot = struct {
    type: ChartType = .lines,
    color: Color = .{},
    highlight: Color = .{},
    min: f32 = 0,
    max: f32 = 0,
    range: f32 = 0,
    count: i32 = 0,
    last: Vec2 = .{},
    index: i32 = 0,
    show_markers: bool = false,
};

/// Per-panel chart state (`nk_chart`).
pub const Chart = struct {
    slot: i32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    slots: [chart_max_slot]ChartSlot = [_]ChartSlot{.{}} ** chart_max_slot,
};

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
    chart: Chart = .{},
    buffer: *CommandBuffer = undefined,
    parent: ?*Panel = null,
    /// Panel-local scroll storage that `offset_x`/`offset_y` point at for groups.
    scroll: Scroll = .{},
    /// For a group panel: the parent-window `WidgetState` key its scroll offset
    /// is loaded from / stored to across frames (0 = none).
    scroll_key: u32 = 0,
};

/// Non-blocking popup state held on the parent window (`nk_popup_state`).
pub const PopupState = struct {
    win: ?*Window = null,
    type: PanelType = .none,
    name: u32 = 0,
    active: bool = false,
    combo_count: u32 = 0,
    header: Rect = .{},
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
    popup: PopupState = .{},
    parent: ?*Window = null,
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
        if (w.popup.win) |p| ctx.destroyWindow(p);
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
                // free a popup window that was not shown this frame
                if (w.popup.win) |p| {
                    if (p.seq != ctx.seq) {
                        ctx.destroyWindow(p);
                        w.popup.win = null;
                        w.popup.active = false;
                    }
                }
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

        win.popup.combo_count = 0;
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

    fn layoutSetMinRowHeight(ctx: *Context, height: f32) void {
        ctx.current.?.layout.?.row.min_height = height;
    }

    fn panelBegin(ctx: *Context, title: []const u8, panel_type: PanelType) bool {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const font = s.font.?;
        // Draw through the panel's buffer pointer (a sub-panel/group aliases the
        // parent window's buffer), not `win.layout.?.buffer`.
        const out = layout.buffer;

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

            // close / minimize buttons
            const hdr_in: ?*const Input = if (win.flags.no_input) null else &ctx.input;
            var btn = Rect{
                .y = header.y + s.window.header.padding.y,
                .h = header.h - 2 * s.window.header.padding.y,
            };
            btn.w = btn.h;
            if (win.flags.closable) {
                if (s.window.header.@"align" == .right) {
                    btn.x = header.w + header.x - (btn.w + s.window.header.padding.x);
                    header.w -= btn.w + s.window.header.spacing.x + s.window.header.padding.x;
                } else {
                    btn.x = header.x + s.window.header.padding.x;
                    header.x += btn.w + s.window.header.spacing.x + s.window.header.padding.x;
                }
                const hit = button_widget.doButtonSymbol(&ctx.last_widget_state, out, btn, s.window.header.close_symbol, .default, &s.window.header.close_button, hdr_in, font) catch false;
                if (hit and !win.flags.rom) {
                    layout.flags.hidden = true;
                    layout.flags.minimized = false;
                }
            }
            if (win.flags.minimizable) {
                if (s.window.header.@"align" == .right) {
                    btn.x = header.w + header.x - btn.w;
                    if (!win.flags.closable) {
                        btn.x -= s.window.header.padding.x;
                        header.w -= s.window.header.padding.x;
                    }
                    header.w -= btn.w + s.window.header.spacing.x;
                } else {
                    btn.x = header.x;
                    header.x += btn.w + s.window.header.spacing.x + s.window.header.padding.x;
                }
                const sym = if (layout.flags.minimized) s.window.header.maximize_symbol else s.window.header.minimize_symbol;
                const hit = button_widget.doButtonSymbol(&ctx.last_widget_state, out, btn, sym, .default, &s.window.header.minimize_button, hdr_in, font) catch false;
                if (hit and !win.flags.rom) layout.flags.minimized = !layout.flags.minimized;
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
        const clip = out.clip.unify(
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
        const out = layout.buffer;

        const font = s.font.?;
        const scrollbar_size = s.window.scrollbar_size;
        const panel_padding = panelGetPadding(s, layout.type);

        if (!layout.type.isSub()) out.pushScissor(math.null_rect) catch {};
        layout.at_y += layout.row.height;

        // scrollbars (top-level windows, groups and scrollable popups)
        if (!layout.flags.no_scrollbar and !layout.flags.minimized) {
            const in_sb: ?*Input = if (layout.flags.rom or layout.flags.no_input) null else &ctx.input;
            const has_scrolling = if (layout.type.isSub())
                (layout.has_scrolling and in_sb != null and ctx.input.isMouseHoveringRect(layout.bounds))
            else
                (ctx.active == win and layout.has_scrolling);

            // vertical
            const vscroll = Rect{
                .x = layout.bounds.x + layout.bounds.w + panel_padding.x,
                .y = layout.bounds.y,
                .w = scrollbar_size.x,
                .h = layout.bounds.h,
            };
            const voff: f32 = @floatFromInt(layout.offset_y.*);
            const vtarget = @trunc(layout.at_y - vscroll.y);
            const vnew = scrollbar_widget.doScrollbarV(&ctx.last_widget_state, out, vscroll, has_scrolling, voff, vtarget, vscroll.h * 0.10, vscroll.h * 0.01, &s.scrollv, in_sb, font) catch voff;
            layout.offset_y.* = @intFromFloat(@max(0, vnew));
            if (in_sb != null and has_scrolling) ctx.input.mouse.scroll_delta.y = 0;

            // horizontal
            const hscroll = Rect{
                .x = layout.bounds.x,
                .y = layout.bounds.y + layout.bounds.h,
                .w = layout.bounds.w,
                .h = scrollbar_size.y,
            };
            const hoff: f32 = @floatFromInt(layout.offset_x.*);
            const htarget = @trunc(layout.max_x - hscroll.x);
            const hnew = scrollbar_widget.doScrollbarH(&ctx.last_widget_state, out, hscroll, has_scrolling, hoff, htarget, layout.max_x * 0.05, layout.max_x * 0.005, &s.scrollh, in_sb, font) catch hoff;
            layout.offset_x.* = @intFromFloat(@max(0, hnew));
        }

        // window resize scaler (bottom-right grip)
        if (layout.flags.scalable and !layout.flags.minimized and !layout.flags.no_input) {
            var scaler = Rect{
                .w = scrollbar_size.x,
                .h = scrollbar_size.y,
                .y = layout.bounds.y + layout.bounds.h,
            };
            scaler.x = if (layout.flags.scale_left)
                layout.bounds.x - panel_padding.x * 0.5
            else
                layout.bounds.x + layout.bounds.w + panel_padding.x;
            if (layout.flags.no_scrollbar) scaler.x -= scaler.w;

            switch (s.window.scaler) {
                .image => |img| out.drawImage(scaler, img, Color.white) catch {},
                .nine_slice => |sl| out.drawNineSlice(scaler, sl, Color.white) catch {},
                .color => |col| if (layout.flags.scale_left)
                    out.fillTriangle(scaler.x, scaler.y, scaler.x, scaler.y + scaler.h, scaler.x + scaler.w, scaler.y + scaler.h, col) catch {}
                else
                    out.fillTriangle(scaler.x + scaler.w, scaler.y, scaler.x + scaler.w, scaler.y + scaler.h, scaler.x, scaler.y + scaler.h, col) catch {},
            }

            if (!layout.flags.rom) {
                const in = &ctx.input;
                const min_size = s.window.min_size;
                if (in.mouse.buttons[@intFromEnum(input_mod.Button.left)].down and in.hasMouseClickDownInRect(.left, scaler, true)) {
                    var delta_x = in.mouse.delta.x;
                    if (layout.flags.scale_left) {
                        delta_x = -delta_x;
                        win.bounds.x += in.mouse.delta.x;
                    }
                    if (win.bounds.w + delta_x >= min_size.x) {
                        if (delta_x < 0 or (delta_x > 0 and in.mouse.pos.x >= scaler.x)) {
                            win.bounds.w += delta_x;
                            scaler.x += in.mouse.delta.x;
                        }
                    }
                    if (!layout.flags.dynamic and min_size.y < win.bounds.h + in.mouse.delta.y) {
                        if (in.mouse.delta.y < 0 or (in.mouse.delta.y > 0 and in.mouse.pos.y >= scaler.y)) {
                            win.bounds.h += in.mouse.delta.y;
                            scaler.y += in.mouse.delta.y;
                        }
                    }
                    s.cursor_active = s.cursors[@intFromEnum(style_mod.CursorType.resize_top_right_down_left)];
                    in.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.x = scaler.x + scaler.w / 2.0;
                    in.mouse.buttons[@intFromEnum(input_mod.Button.left)].clicked_pos.y = scaler.y + scaler.h / 2.0;
                }
            }
        }

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

        // a hidden window clears its command buffer for the frame
        if (!layout.type.isSub() and layout.flags.hidden) win.buffer.reset();

        if (layout.flags.remove_rom) {
            layout.flags.rom = false;
            layout.flags.remove_rom = false;
        }
        // propagate panel flag changes (close/minimize) back to the window
        win.flags = layout.flags;
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
            layout.buffer.fillRect(background, 0, s.window.background) catch {};
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

    /// Begin a row with per-column widths given by `ratio` (fractions of the row
    /// for `.dynamic`, pixels for `.static`); a negative entry means "share the
    /// remaining space" (`nk_layout_row`). `ratio` must outlive the row.
    pub fn layoutRow(ctx: *Context, fmt: LayoutFormat, height: f32, ratio: []const f32) void {
        const layout = ctx.current.?.layout.?;
        ctx.panelLayout(height, @intCast(ratio.len));
        if (fmt == .dynamic) {
            var r: f32 = 0;
            var n_undef: i32 = 0;
            layout.row.ratio = ratio;
            for (ratio) |x| {
                if (x < 0) n_undef += 1 else r += x;
            }
            r = std.math.clamp(1.0 - r, 0, 1);
            layout.row.type = .dynamic;
            layout.row.item_width = if (r > 0 and n_undef > 0) r / @as(f32, @floatFromInt(n_undef)) else 0;
        } else {
            layout.row.ratio = ratio;
            layout.row.type = .static;
            layout.row.item_width = 0;
        }
        layout.row.item_offset = 0;
        layout.row.filled = 0;
    }

    /// Begin a row whose column widths are supplied one at a time with
    /// `layoutRowPush` (`nk_layout_row_begin`).
    pub fn layoutRowBegin(ctx: *Context, fmt: LayoutFormat, row_height: f32, cols: i32) void {
        const layout = ctx.current.?.layout.?;
        ctx.panelLayout(row_height, cols);
        layout.row.type = if (fmt == .dynamic) .dynamic_row else .static_row;
        layout.row.ratio = null;
        layout.row.filled = 0;
        layout.row.item_width = 0;
        layout.row.item_offset = 0;
        layout.row.columns = cols;
    }

    /// Set the width of the next column in a `layoutRowBegin` row (fraction for
    /// dynamic, pixels for static) (`nk_layout_row_push`).
    pub fn layoutRowPush(ctx: *Context, ratio_or_width: f32) void {
        const layout = ctx.current.?.layout.?;
        if (layout.row.type == .dynamic_row) {
            if (ratio_or_width + layout.row.filled > 1.0) return;
            layout.row.item_width = if (ratio_or_width > 0) std.math.clamp(ratio_or_width, 0, 1) else 1.0 - layout.row.filled;
        } else {
            layout.row.item_width = ratio_or_width;
        }
    }

    /// Finish a `layoutRowBegin` row (`nk_layout_row_end`).
    pub fn layoutRowEnd(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        layout.row.item_width = 0;
        layout.row.item_offset = 0;
    }

    /// Begin free widget placement; positions are set per widget with
    /// `layoutSpacePush` (`nk_layout_space_begin`).
    pub fn layoutSpaceBegin(ctx: *Context, fmt: LayoutFormat, height: f32, widget_count: i32) void {
        const layout = ctx.current.?.layout.?;
        ctx.panelLayout(height, widget_count);
        layout.row.type = if (fmt == .static) .static_free else .dynamic_free;
        layout.row.ratio = null;
        layout.row.filled = 0;
        layout.row.item_width = 0;
        layout.row.item_offset = 0;
    }

    /// Position the next free-placed widget (`nk_layout_space_push`).
    pub fn layoutSpacePush(ctx: *Context, rect: Rect) void {
        ctx.current.?.layout.?.row.item = rect;
    }

    /// Finish free placement (`nk_layout_space_end`).
    pub fn layoutSpaceEnd(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        layout.row.item_width = 0;
        layout.row.item_height = 0;
        layout.row.item_offset = 0;
        layout.row.item = .{};
    }

    /// Begin a template row mixing dynamic/variable/static columns
    /// (`nk_layout_row_template_begin`).
    pub fn layoutRowTemplateBegin(ctx: *Context, height: f32) void {
        const layout = ctx.current.?.layout.?;
        ctx.panelLayout(height, 1);
        layout.row.type = .template;
        layout.row.columns = 0;
        layout.row.ratio = null;
        layout.row.item_width = 0;
        layout.row.item_height = 0;
        layout.row.item_offset = 0;
        layout.row.filled = 0;
        layout.row.item = .{};
    }

    fn templatePush(ctx: *Context, value: f32) void {
        const layout = ctx.current.?.layout.?;
        if (layout.row.columns >= layout.row.templates.len) return;
        layout.row.templates[@intCast(layout.row.columns)] = value;
        layout.row.columns += 1;
    }

    /// A column that shares leftover space equally (`..._push_dynamic`).
    pub fn layoutRowTemplatePushDynamic(ctx: *Context) void {
        ctx.templatePush(-1.0);
    }
    /// A column at least `min_width` px, growing into leftover space
    /// (`..._push_variable`).
    pub fn layoutRowTemplatePushVariable(ctx: *Context, min_width: f32) void {
        ctx.templatePush(-min_width);
    }
    /// A fixed-width column (`..._push_static`).
    pub fn layoutRowTemplatePushStatic(ctx: *Context, width: f32) void {
        ctx.templatePush(width);
    }

    /// Resolve template column widths (`nk_layout_row_template_end`).
    pub fn layoutRowTemplateEnd(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        var variable_count: i32 = 0;
        var min_variable_count: i32 = 0;
        var min_fixed_width: f32 = 0;
        var total_fixed_width: f32 = 0;
        var max_variable_width: f32 = 0;

        const cols: usize = @intCast(layout.row.columns);
        for (layout.row.templates[0..cols]) |w| {
            if (w >= 0) {
                total_fixed_width += w;
                min_fixed_width += w;
            } else if (w < -1.0) {
                const width = -w;
                total_fixed_width += width;
                max_variable_width = @max(max_variable_width, width);
                variable_count += 1;
            } else {
                min_variable_count += 1;
                variable_count += 1;
            }
        }
        if (variable_count == 0) return;

        const space = usableSpace(&ctx.style, layout.bounds.w, layout.row.columns);
        var var_width = @max(space - min_fixed_width, 0) / @as(f32, @floatFromInt(variable_count));
        const enough_space = var_width >= max_variable_width;
        if (!enough_space) var_width = @max(space - total_fixed_width, 0) / @as(f32, @floatFromInt(min_variable_count));
        for (layout.row.templates[0..cols]) |*w| {
            w.* = if (w.* >= 0) w.* else if (w.* < -1.0 and !enough_space) -w.* else var_width;
        }
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
            win.layout.?.buffer,
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
            win.layout.?.buffer,
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

    // --- toggle widgets ---------------------------------------------------

    fn widgetInput(ctx: *Context, state: WidgetLayoutState) ?*const Input {
        const layout = ctx.current.?.layout.?;
        return if (state == .rom or state == .disabled or layout.flags.rom) null else &ctx.input;
    }

    /// Mutable variant for widgets that update input state during interaction
    /// (e.g. the slider rewrites the click position while dragging).
    fn widgetInputMut(ctx: *Context, state: WidgetLayoutState) ?*Input {
        const layout = ctx.current.?.layout.?;
        return if (state == .rom or state == .disabled or layout.flags.rom) null else &ctx.input;
    }

    /// A labelled checkbox; toggles `active` on click, returns whether it
    /// changed (`nk_checkbox_label`).
    pub fn checkboxLabel(ctx: *Context, lbl: []const u8, active: *bool) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        return toggle_widget.doToggle(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, active, lbl, .check, &ctx.style.checkbox, ctx.widgetInput(w.state), ctx.style.font.?, Align.text_left, Align.text_left);
    }

    /// A labelled radio option; returns the new selected state
    /// (`nk_option_label`).
    pub fn optionLabel(ctx: *Context, lbl: []const u8, active: bool) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return active;
        var a = active;
        _ = try toggle_widget.doToggle(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, &a, lbl, .option, &ctx.style.option, ctx.widgetInput(w.state), ctx.style.font.?, Align.text_left, Align.text_left);
        return a;
    }

    // --- slider -----------------------------------------------------------

    /// A float slider; updates `value` and returns whether it changed
    /// (`nk_slider_float`).
    pub fn sliderFloat(ctx: *Context, min: f32, value: *f32, max: f32, step: f32) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const old = value.*;
        value.* = try slider_widget.doSlider(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, min, value.*, max, step, &ctx.style.slider, ctx.widgetInputMut(w.state), ctx.style.font.?);
        return value.* != old;
    }

    // --- progress bar -----------------------------------------------------

    /// A progress bar; when `modifiable`, dragging updates `cur`. Returns
    /// whether the value changed (`nk_progress`).
    pub fn progress(ctx: *Context, cur: *usize, max: usize, modifiable: bool) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const old = cur.*;
        cur.* = try progress_widget.doProgress(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, cur.*, max, modifiable, &ctx.style.progress, ctx.widgetInputMut(w.state));
        return cur.* != old;
    }

    // --- image ------------------------------------------------------------

    /// Draw an image in the next layout slot, tinted by `col` (`nk_image_color`).
    pub fn imageColor(ctx: *Context, img: image_mod.Image, col: Color) !void {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return;
        try win.layout.?.buffer.drawImage(w.bounds, img, col);
    }

    /// Draw an image in the next layout slot (`nk_image`).
    pub fn image(ctx: *Context, img: image_mod.Image) !void {
        try ctx.imageColor(img, Color.white);
    }

    // --- knob -------------------------------------------------------------

    /// A rotary knob; updates `value`, returns whether it changed
    /// (`nk_knob_float`).
    pub fn knobFloat(ctx: *Context, min: f32, value: *f32, max: f32, step: f32, zero_direction: math.Heading, dead_zone_percent: f32) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const old = value.*;
        value.* = try knob_widget.doKnob(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, min, value.*, max, step, zero_direction, dead_zone_percent, &ctx.style.knob, ctx.widgetInputMut(w.state));
        return value.* != old;
    }

    // --- selectable -------------------------------------------------------

    /// A toggleable labelled row; updates `value`, returns whether it changed
    /// (`nk_selectable_label`).
    pub fn selectableLabel(ctx: *Context, str: []const u8, alignment: Align, value: *bool) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        return selectable_widget.doSelectable(&ctx.last_widget_state, win.layout.?.buffer, w.bounds, str, alignment, value, &ctx.style.selectable, ctx.widgetInput(w.state), ctx.style.font.?);
    }

    // --- color picker -----------------------------------------------------

    /// A color picker (SV matrix + hue/alpha bars); updates `col`, returns
    /// whether it changed (`nk_color_pick`).
    pub fn colorPick(ctx: *Context, col: *color.Colorf, fmt: color_picker_widget.ColorFormat) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        return color_picker_widget.doColorPicker(&ctx.last_widget_state, win.layout.?.buffer, col, fmt, w.bounds, math.Vec2.init(0, 0), ctx.widgetInput(w.state), ctx.style.font.?);
    }

    // --- edit (text input) ------------------------------------------------

    /// A text input field driven by a caller-owned `TextEdit`
    /// (`nk_edit_buffer`). Returns the frame's edit events.
    ///
    /// Single-line editing is fully supported, including horizontal scrolling to
    /// keep the cursor visible. Multi-line layout (`EditFlags.multiline`) is TODO.
    pub fn editBuffer(ctx: *Context, flags: EditFlags, editor: *text_editor.TextEdit) !EditEvents {
        const win = ctx.current.?;
        const s = &ctx.style.edit;
        const font = ctx.style.font.?;
        const out = win.layout.?.buffer;
        const left = @intFromEnum(input_mod.Button.left);

        const w = ctx.widget();
        if (w.state == .invalid) return .{ .inactive = true };
        const bounds = w.bounds;
        const in: ?*Input = if (w.state == .rom or w.state == .disabled or win.layout.?.flags.rom) null else &ctx.input;

        const area = Rect{
            .x = bounds.x + s.padding.x + s.border,
            .y = bounds.y + s.padding.y + s.border,
            .w = bounds.w - 2 * (s.padding.x + s.border),
            .h = bounds.h - 2 * (s.padding.y + s.border),
        };

        editor.single_line = !flags.multiline;

        // focus: clicking inside activates, clicking outside deactivates
        const prev_active = editor.active;
        if (in) |i| {
            if (i.mouse.buttons[left].clicked != 0 and i.mouse.buttons[left].down) {
                editor.active = bounds.contains(i.mouse.pos);
            }
        }
        if (!prev_active and editor.active) {
            if (flags.auto_select) editor.selectAll();
            if (flags.goto_end_on_activate) editor.cursor = editor.string.glyphLen();
        } else if (!editor.active) {
            editor.mode = .view;
        }
        if (flags.read_only) {
            editor.mode = .view;
        } else if (flags.always_insert_mode) {
            editor.mode = .insert;
        }

        var events = EditEvents{ .active = editor.active, .inactive = !editor.active };
        if (prev_active != editor.active) {
            if (editor.active) events.activated = true else events.deactivated = true;
        }

        // input
        if (editor.active and in != null and editor.mode != .view) {
            const i = in.?;
            const shift = i.isKeyDown(.shift);
            inline for (std.meta.fields(input_mod.Key)) |f| {
                const k: input_mod.Key = @enumFromInt(f.value);
                if (k != .enter and k != .tab and i.isKeyPressed(k)) editor.key(k, shift);
            }
            if (i.keyboard.text_len > 0) {
                try editor.insert(i.text());
                i.keyboard.text_len = 0;
            }
            if (i.isKeyPressed(.enter)) {
                if (flags.sig_enter) {
                    events.committed = true;
                } else if (!editor.single_line) {
                    try editor.insert("\n");
                }
            }
        }

        // widget interaction state for styling
        var wstate: widget_mod.States = .{};
        if (editor.active) {
            wstate = widget_mod.States.active;
        } else if (in != null and in.?.isMouseHoveringRect(bounds)) {
            wstate = widget_mod.States.hovered;
        }
        ctx.last_widget_state = wstate;

        // draw background + border
        const bg = if (wstate.actived) s.active else if (wstate.hover) s.hover else s.normal;
        const text_color = if (wstate.actived) s.text_active else if (wstate.hover) s.text_hover else s.text_normal;
        var text_bg: Color = .{ .a = 0 };
        switch (bg) {
            .image => |img| try out.drawImage(bounds, img, Color.white),
            .nine_slice => |sl| try out.drawNineSlice(bounds, sl, Color.white),
            .color => |col| {
                text_bg = col;
                try out.fillRect(bounds, s.rounding, col);
                try out.strokeRect(bounds, s.rounding, s.border, s.border_color);
            },
        }

        // clip to the text area
        const old_clip = out.clip;
        try out.pushScissor(old_clip.unify(area.x, area.y, area.x + area.w, area.y + area.h));

        const bytes = editor.string.bytes();

        // keep the cursor visible by scrolling the text horizontally
        const cursor_x = font.textWidth(bytes[0..(editor.string.atRune(editor.cursor).?.offset)]);
        if (editor.active) {
            if (cursor_x < editor.scroll_x) editor.scroll_x = cursor_x;
            if (cursor_x > editor.scroll_x + area.w - s.cursor_size) editor.scroll_x = cursor_x - area.w + s.cursor_size;
        }
        editor.scroll_x = @max(0, editor.scroll_x);
        const ox = area.x - editor.scroll_x;

        // selection highlight
        if (editor.hasSelection()) {
            var a = editor.select_start;
            var b = editor.select_end;
            if (b < a) {
                const t = a;
                a = b;
                b = t;
            }
            const ax = font.textWidth(bytes[0..(editor.string.atRune(a).?.offset)]);
            const bx = font.textWidth(bytes[0..(editor.string.atRune(b).?.offset)]);
            try out.fillRect(Rect.init(ox + ax, area.y, bx - ax, area.h), 0, s.selected_normal);
        }

        // text (drawn at the scrolled origin; the scissor clips it to the field)
        const text_rect = Rect{ .x = ox, .y = area.y, .w = font.textWidth(bytes) + s.cursor_size, .h = area.h };
        try text_widget.widgetText(out, text_rect, bytes, Align{ .left = true, .middle = true }, math.Vec2.init(0, 0), text_bg, text_color, font);

        // cursor
        if (editor.active and !flags.no_cursor and !editor.hasSelection()) {
            const cursor_color = if (wstate.actived) s.cursor_hover else s.cursor_normal;
            try out.fillRect(Rect.init(ox + cursor_x, area.y, s.cursor_size, area.h), 0, cursor_color);
        }

        try out.pushScissor(old_clip);
        return events;
    }

    // --- property (numeric field) -----------------------------------------

    /// A labelled numeric field: drag the middle to change the value, or click
    /// the −/+ buttons by `step`. Returns whether it changed (`nk_property_float`).
    /// NOTE: click-to-type editing of the value is a TODO; drag + buttons work.
    pub fn propertyFloat(ctx: *Context, name: []const u8, min: f32, value: *f32, max: f32, step: f32, inc_per_pixel: f32) !bool {
        const win = ctx.current.?;
        const s = &ctx.style.property;
        const font = ctx.style.font.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const property = w.bounds;
        const out = win.layout.?.buffer;
        const in = ctx.widgetInputMut(w.state);
        const old = value.*;

        const hovered = if (in) |i| i.isMouseHoveringRect(property) else false;
        switch (if (hovered) s.hover else s.normal) {
            .color => |col| {
                try out.fillRect(property, s.rounding, col);
                try out.strokeRect(property, s.rounding, s.border, s.border_color);
            },
            .image => |img| try out.drawImage(property, img, Color.white),
            .nine_slice => |sl| try out.drawNineSlice(property, sl, Color.white),
        }

        const bh = font.height;
        const left = Rect{ .x = property.x + s.border + s.padding.x, .y = property.y + s.border + property.h / 2 - bh / 2, .w = bh, .h = bh };
        const right = Rect{ .x = property.x + property.w - (bh + s.padding.x), .y = left.y, .w = bh, .h = bh };
        var ws: widget_mod.States = .{};
        if (try button_widget.doButtonSymbol(&ws, out, left, s.sym_left, .default, &s.dec_button, in, font)) value.* -= step;
        if (try button_widget.doButtonSymbol(&ws, out, right, s.sym_right, .default, &s.inc_button, in, font)) value.* += step;

        const lw = font.textWidth(name);
        const name_rect = Rect{ .x = left.x + left.w + s.padding.x, .y = property.y + s.border + s.padding.y, .w = lw + 2 * s.padding.x, .h = property.h - 2 * (s.border + s.padding.y) };
        try text_widget.widgetText(out, name_rect, name, Align{ .left = true, .middle = true }, math.Vec2.init(0, 0), .{ .a = 0 }, s.label_normal, font);

        var nbuf: [64]u8 = undefined;
        const vstr = std.fmt.bufPrint(&nbuf, "{d:.2}", .{value.*}) catch "?";
        const vw = font.textWidth(vstr);
        const edit = Rect{ .x = right.x - (vw + 2 * s.padding.x), .y = property.y + s.border, .w = vw + 2 * s.padding.x, .h = property.h - 2 * s.border };
        try text_widget.widgetText(out, edit, vstr, Align{ .left = true, .middle = true }, math.Vec2.init(0, 0), .{ .a = 0 }, s.label_normal, font);

        const drag = Rect{ .x = name_rect.x + name_rect.w, .y = property.y, .w = edit.x - (name_rect.x + name_rect.w), .h = property.h };
        if (in) |i| {
            if (i.mouse.buttons[@intFromEnum(input_mod.Button.left)].down and i.hasMouseClickDownInRect(.left, drag, true)) {
                value.* += i.mouse.delta.x * inc_per_pixel;
            }
        }

        value.* = std.math.clamp(value.*, min, max);
        return value.* != old;
    }

    /// Integer property; see `propertyFloat` (`nk_property_int`).
    pub fn propertyInt(ctx: *Context, name: []const u8, min: i32, value: *i32, max: i32, step: i32, inc_per_pixel: f32) !bool {
        var f: f32 = @floatFromInt(value.*);
        const changed = try ctx.propertyFloat(name, @floatFromInt(min), &f, @floatFromInt(max), @floatFromInt(step), inc_per_pixel);
        value.* = @intFromFloat(@round(f));
        return changed;
    }

    // --- chart ------------------------------------------------------------

    /// Begin a chart with an explicit slot color (`nk_chart_begin_colored`).
    /// Returns false (and you must not push/end) when not visible.
    pub fn chartBeginColored(ctx: *Context, ctype: ChartType, col: Color, highlight: Color, count: i32, min_value: f32, max_value: f32) !bool {
        const win = ctx.current.?;
        const w = ctx.widget();
        const chart = &win.layout.?.chart;
        if (w.state == .invalid) {
            chart.* = .{};
            return false;
        }
        const s = &ctx.style.chart;
        chart.* = .{
            .x = w.bounds.x + s.padding.x,
            .y = w.bounds.y + s.padding.y,
            .w = @max(w.bounds.w - 2 * s.padding.x, 2 * s.padding.x),
            .h = @max(w.bounds.h - 2 * s.padding.y, 2 * s.padding.y),
        };
        chart.slots[0] = .{
            .type = ctype,
            .count = count,
            .color = col.factor(s.color_factor),
            .highlight = highlight,
            .min = @min(min_value, max_value),
            .max = @max(min_value, max_value),
            .range = @max(min_value, max_value) - @min(min_value, max_value),
            .show_markers = s.show_markers,
        };
        chart.slot = 1;

        const out = win.layout.?.buffer;
        switch (s.background) {
            .image => |img| try out.drawImage(w.bounds, img, Color.white.factor(s.color_factor)),
            .nine_slice => |sl| try out.drawNineSlice(w.bounds, sl, Color.white.factor(s.color_factor)),
            .color => |bgc| {
                try out.fillRect(w.bounds, s.rounding, s.border_color.factor(s.color_factor));
                try out.fillRect(w.bounds.shrink(s.border), s.rounding, bgc.factor(s.color_factor));
            },
        }
        return true;
    }

    /// Begin a chart using the theme's chart colors (`nk_chart_begin`).
    pub fn chartBegin(ctx: *Context, ctype: ChartType, count: i32, min_value: f32, max_value: f32) !bool {
        return ctx.chartBeginColored(ctype, ctx.style.chart.color, ctx.style.chart.selected_color, count, min_value, max_value);
    }

    /// Add another data series (`nk_chart_add_slot_colored`).
    pub fn chartAddSlotColored(ctx: *Context, ctype: ChartType, col: Color, highlight: Color, count: i32, min_value: f32, max_value: f32) void {
        const chart = &ctx.current.?.layout.?.chart;
        if (chart.slot >= chart_max_slot) return;
        chart.slots[@intCast(chart.slot)] = .{
            .type = ctype,
            .count = count,
            .color = col,
            .highlight = highlight,
            .min = @min(min_value, max_value),
            .max = @max(min_value, max_value),
            .range = @max(min_value, max_value) - @min(min_value, max_value),
            .show_markers = ctx.style.chart.show_markers,
        };
        chart.slot += 1;
    }

    pub fn chartAddSlot(ctx: *Context, ctype: ChartType, count: i32, min_value: f32, max_value: f32) void {
        ctx.chartAddSlotColored(ctype, ctx.style.chart.color, ctx.style.chart.selected_color, count, min_value, max_value);
    }

    /// Push a value into a chart series (`nk_chart_push_slot`).
    pub fn chartPushSlot(ctx: *Context, value: f32, slot: usize) ChartEvent {
        const chart = &ctx.current.?.layout.?.chart;
        if (slot >= @as(usize, @intCast(chart.slot))) return .{};
        return switch (chart.slots[slot].type) {
            .lines => ctx.chartPushLine(chart, value, slot),
            .column => ctx.chartPushColumn(chart, value, slot),
        };
    }

    /// Push a value into the first chart series (`nk_chart_push`).
    pub fn chartPush(ctx: *Context, value: f32) ChartEvent {
        return ctx.chartPushSlot(value, 0);
    }

    fn chartPushLine(ctx: *Context, chart: *Chart, value: f32, slot: usize) ChartEvent {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const out = win.layout.?.buffer;
        const in: ?*const Input = if (win.widgets_disabled) null else &ctx.input;
        const left = @intFromEnum(input_mod.Button.left);
        const sl = &chart.slots[slot];
        var ret = ChartEvent{};
        const step = chart.w / @as(f32, @floatFromInt(sl.count));
        const ratio = (value - sl.min) / (sl.max - sl.min);

        if (sl.index == 0) {
            sl.last = .{ .x = chart.x, .y = (chart.y + chart.h) - ratio * chart.h };
            const bounds = Rect.init(sl.last.x - 2, sl.last.y - 2, 4, 4);
            var col = sl.color;
            if (!layout.flags.rom) if (in) |i| if (Rect.init(sl.last.x - 3, sl.last.y - 3, 6, 6).contains(i.mouse.pos)) {
                if (i.isMouseHoveringRect(bounds)) ret.hovering = true;
                if (i.mouse.buttons[left].down and i.mouse.buttons[left].clicked != 0) ret.clicked = true;
                col = sl.highlight;
            };
            if (sl.show_markers) out.fillRect(bounds, 0, col) catch {};
            sl.index += 1;
            return ret;
        }

        var col = sl.color;
        const cur = Vec2.init(chart.x + step * @as(f32, @floatFromInt(sl.index)), (chart.y + chart.h) - ratio * chart.h);
        out.strokeLine(sl.last.x, sl.last.y, cur.x, cur.y, 1.0, col) catch {};
        const bounds = Rect.init(cur.x - 3, cur.y - 3, 6, 6);
        if (!layout.flags.rom) if (in) |i| if (i.isMouseHoveringRect(bounds)) {
            ret.hovering = true;
            if (!i.mouse.buttons[left].down and i.mouse.buttons[left].clicked != 0) ret.clicked = true;
            col = sl.highlight;
        };
        if (sl.show_markers) out.fillRect(Rect.init(cur.x - 2, cur.y - 2, 4, 4), 0, col) catch {};
        sl.last = cur;
        sl.index += 1;
        return ret;
    }

    fn chartPushColumn(ctx: *Context, chart: *Chart, value: f32, slot: usize) ChartEvent {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const out = win.layout.?.buffer;
        const in: ?*const Input = if (win.widgets_disabled) null else &ctx.input;
        const left = @intFromEnum(input_mod.Button.left);
        const sl = &chart.slots[slot];
        var ret = ChartEvent{};
        if (sl.index >= sl.count) return ret;

        var item = Rect{};
        if (sl.count != 0) {
            const padding: f32 = @floatFromInt(sl.count - 1);
            item.w = (chart.w - padding) / @as(f32, @floatFromInt(sl.count));
        }
        var col = sl.color;
        item.h = chart.h * @abs(value / sl.range);
        if (value >= 0) {
            const r = (value + @abs(sl.min)) / @abs(sl.range);
            item.y = (chart.y + chart.h) - chart.h * r;
        } else {
            const r = (value - sl.max) / sl.range;
            item.y = chart.y + chart.h * @abs(r) - item.h;
        }
        const fi: f32 = @floatFromInt(sl.index);
        item.x = chart.x + fi * item.w + fi;

        if (!layout.flags.rom) if (in) |i| if (item.contains(i.mouse.pos)) {
            ret.hovering = true;
            if (!i.mouse.buttons[left].down and i.mouse.buttons[left].clicked != 0) ret.clicked = true;
            col = sl.highlight;
        };
        out.fillRect(item, 0, col) catch {};
        sl.index += 1;
        return ret;
    }

    /// Finish a chart (`nk_chart_end`).
    pub fn chartEnd(ctx: *Context) void {
        ctx.current.?.layout.?.chart = .{};
    }

    // --- tree -------------------------------------------------------------

    fn treeStateBase(ctx: *Context, ttype: TreeType, img: ?image_mod.Image, title: []const u8, state: *bool) !bool {
        const win = ctx.current.?;
        const layout = win.layout.?;
        const s = &ctx.style;
        const out = win.layout.?.buffer;
        const font = s.font.?;
        const item_spacing = s.window.spacing;

        const row_height = font.height + 2 * s.tab.padding.y;
        ctx.layoutSetMinRowHeight(row_height);
        ctx.layoutRowDynamic(row_height, 1);
        ctx.resetMinRowHeight();

        const wr = ctx.widget();
        var header = wr.bounds;
        const text_bg = s.window.background;

        if (ttype == .tab) {
            switch (s.tab.background) {
                .image => |im| try out.drawImage(header, im, Color.white.factor(s.tab.color_factor)),
                .nine_slice => |sl| try out.drawNineSlice(header, sl, Color.white.factor(s.tab.color_factor)),
                .color => |col| {
                    try out.fillRect(header, 0, s.tab.border_color.factor(s.tab.color_factor));
                    try out.fillRect(header.shrink(s.tab.border), s.tab.rounding, col.factor(s.tab.color_factor));
                },
            }
        }

        // toggle on header click
        const in: ?*const Input = if (!layout.flags.rom and wr.state == .valid) &ctx.input else null;
        var ws: widget_mod.States = .{};
        if (button_widget.behavior(&ws, header, in, .default)) state.* = !state.*;

        const sym_type = if (state.*) s.tab.sym_maximize else s.tab.sym_minimize;
        const btn_style = if (state.*)
            (if (ttype == .tab) &s.tab.tab_maximize_button else &s.tab.node_maximize_button)
        else
            (if (ttype == .tab) &s.tab.tab_minimize_button else &s.tab.node_minimize_button);

        var sym = Rect{ .w = font.height, .h = font.height, .y = header.y + s.tab.padding.y, .x = header.x + s.tab.padding.x };
        _ = try button_widget.doButtonSymbol(&ws, out, sym, sym_type, .default, btn_style, null, font);

        if (img) |im| {
            sym.x = sym.x + sym.w + 4 * item_spacing.x;
            try out.drawImage(sym, im, Color.white);
            sym.w = font.height + s.tab.spacing.x;
        }

        // label
        header.w = @max(header.w, sym.w + item_spacing.x);
        const label_rect = Rect{
            .x = sym.x + sym.w + item_spacing.x,
            .y = sym.y,
            .w = header.w - (sym.w + item_spacing.y + s.tab.indent),
            .h = font.height,
        };
        try text_widget.widgetText(out, label_rect, title, Align.text_left, math.Vec2.init(0, 0), text_bg, s.tab.text.factor(s.tab.color_factor), font);

        if (state.*) {
            const off_x: f32 = @floatFromInt(layout.offset_x.*);
            layout.at_x = header.x + off_x + s.tab.indent;
            layout.bounds.w = @max(layout.bounds.w, s.tab.indent);
            layout.bounds.w -= s.tab.indent + s.window.padding.x;
            layout.row.tree_depth += 1;
            return true;
        }
        return false;
    }

    /// Begin a collapsible tree node. `seed` disambiguates nodes with the same
    /// title (pass e.g. `@src().line`). Returns true when expanded — only then
    /// emit the contents, and call `treePop` (`nk_tree_push_hashed`).
    pub fn treePush(ctx: *Context, ttype: TreeType, title: []const u8, initial: CollapseState, seed: u32) !bool {
        const win = ctx.current.?;
        const key = std.hash.Murmur3_32.hashWithSeed(title, seed);
        var collapse = if (win.state.find(key, ctx.seq)) |v| v != 0 else (initial == .maximized);
        const open = try ctx.treeStateBase(ttype, null, title, &collapse);
        try win.state.set(ctx.allocator, key, @intFromBool(collapse), ctx.seq);
        return open;
    }

    /// Close a tree node opened with `treePush` (`nk_tree_pop`).
    pub fn treePop(ctx: *Context) void {
        const layout = ctx.current.?.layout.?;
        const off_x: f32 = @floatFromInt(layout.offset_x.*);
        layout.at_x -= ctx.style.tab.indent + off_x;
        layout.bounds.w += ctx.style.tab.indent + ctx.style.window.padding.x;
        layout.row.tree_depth -= 1;
    }

    // --- group (sub-window) -----------------------------------------------

    /// Begin a scrollable sub-region in the current row, identified by `title`.
    /// Returns true when visible — only then emit contents and call `groupEnd`
    /// (`nk_group_begin`). Scroll position persists across frames.
    pub fn groupBegin(ctx: *Context, title: []const u8, flags: WindowFlags) !bool {
        const win = ctx.current.?;
        const bounds = ctx.panelAllocSpace();
        if (!win.layout.?.clip.intersects(bounds) and !flags.movable) return false;

        var gflags = flags;
        if (win.flags.rom) gflags.rom = true;

        const sub = try ctx.allocator.create(Panel);
        sub.* = .{ .buffer = &win.buffer };
        // load the persisted scroll offset from the parent window's state
        const key = std.hash.Murmur3_32.hashWithSeed(title, @intFromEnum(PanelType.group));
        sub.scroll_key = key;
        sub.scroll.x = win.state.find(key, ctx.seq) orelse 0;
        sub.scroll.y = win.state.find(key +% 1, ctx.seq) orelse 0;
        sub.offset_x = &sub.scroll.x;
        sub.offset_y = &sub.scroll.y;

        var fake: Window = .{
            .name = "",
            .buffer = undefined,
            .bounds = bounds,
            .flags = gflags,
            .layout = sub,
        };
        ctx.current = &fake;
        _ = ctx.panelBegin(if (gflags.title) title else "", .group);
        sub.parent = win.layout;
        win.layout = sub;
        ctx.current = win;

        if (sub.flags.closed or sub.flags.minimized) {
            ctx.groupEnd();
            return false;
        }
        return true;
    }

    /// Close a group opened with `groupBegin` (`nk_group_end`).
    pub fn groupEnd(ctx: *Context) void {
        const win = ctx.current.?;
        const g = win.layout.?;
        const parent = g.parent.?;
        const s = &ctx.style;
        const panel_padding = panelGetPadding(s, .group);

        var pb = Rect{
            .x = g.bounds.x - panel_padding.x,
            .y = g.bounds.y - g.header_height,
            .w = g.bounds.w + 2 * panel_padding.x,
            .h = g.bounds.h + g.header_height,
        };
        if (g.flags.border) {
            pb.x -= g.border;
            pb.y -= g.border;
            pb.w += 2 * g.border;
            pb.h += 2 * g.border;
        }
        if (!g.flags.no_scrollbar) {
            pb.w += s.window.scrollbar_size.x;
            pb.h += s.window.scrollbar_size.y;
        }

        var pan: Window = .{ .name = "", .buffer = undefined, .bounds = pb, .flags = g.flags, .layout = g };
        ctx.current = &pan;
        const clip = parent.clip.unify(pb.x, pb.y, pb.x + pb.w, pb.y + pb.h + panel_padding.x);
        g.buffer.pushScissor(clip) catch {};
        ctx.panelEnd();
        g.buffer.pushScissor(parent.clip) catch {};

        ctx.current = win;
        win.layout = parent;

        // persist the group's scroll offset on the parent window
        if (g.scroll_key != 0) {
            win.state.set(ctx.allocator, g.scroll_key, g.scroll.x, ctx.seq) catch {};
            win.state.set(ctx.allocator, g.scroll_key +% 1, g.scroll.y, ctx.seq) catch {};
        }
        ctx.allocator.destroy(g);
    }

    // --- popups / combo ---------------------------------------------------

    fn setParentRom(layout: ?*Panel, comptime field: enum { rom, remove_rom }) void {
        var root = layout;
        while (root) |r| {
            switch (field) {
                .rom => r.flags.rom = true,
                .remove_rom => r.flags.remove_rom = true,
            }
            root = r.parent;
        }
    }

    /// Open/refresh a non-blocking popup window (`nk_nonblock_begin`). The popup
    /// renders as an overlay into the parent window's command buffer.
    fn nonblockBegin(ctx: *Context, flags: WindowFlags, body: Rect, header: Rect, panel_type: PanelType) !bool {
        const win = ctx.current.?;
        var is_active = true;

        if (win.popup.win == null) {
            const p = try ctx.allocator.create(Window);
            p.* = .{ .name = try ctx.allocator.dupe(u8, ""), .buffer = CommandBuffer.init(ctx.allocator), .parent = win };
            win.popup.win = p;
            win.popup.type = panel_type;
        } else {
            const pressed = ctx.input.isMousePressed(.left);
            const in_body = ctx.input.isMouseHoveringRect(body);
            const in_header = ctx.input.isMouseHoveringRect(header);
            if (pressed and (!in_body or in_header)) is_active = false;
        }
        win.popup.header = header;

        if (!is_active) {
            setParentRom(win.layout, .remove_rom);
            return false;
        }

        const popup = win.popup.win.?;
        popup.bounds = body;
        popup.parent = win;
        popup.flags = flags;
        popup.flags.border = true;
        popup.flags.dynamic = true;
        popup.seq = ctx.seq;
        win.popup.active = true;

        const panel = try ctx.allocator.create(Panel);
        panel.* = .{ .buffer = &win.buffer, .offset_x = &popup.scrollbar.x, .offset_y = &popup.scrollbar.y };
        popup.layout = panel;

        win.buffer.pushScissor(math.null_rect) catch {};
        ctx.current = popup;
        _ = ctx.panelBegin("", panel_type);
        panel.parent = win.layout;

        setParentRom(win.layout, .rom);
        return true;
    }

    fn popupClose(ctx: *Context) void {
        const popup = ctx.current.?;
        popup.flags.hidden = true;
        if (popup.parent) |p| p.popup.active = false;
    }

    fn popupEnd(ctx: *Context) void {
        const popup = ctx.current.?;
        const win = popup.parent.?;
        if (popup.flags.hidden) {
            setParentRom(win.layout, .remove_rom);
            win.popup.active = false;
        }
        ctx.panelEnd();
        if (popup.layout) |l| ctx.allocator.destroy(l);
        popup.layout = null;
        ctx.current = win;
        win.buffer.pushScissor(win.layout.?.clip) catch {};
    }

    fn contextualEnd(ctx: *Context) void {
        const popup = ctx.current.?;
        const panel = popup.layout.?;
        if (panel.flags.dynamic) {
            // close on the next frame if clicked in the empty space below content
            var body = Rect{};
            if (panel.at_y < panel.bounds.y + panel.bounds.h) {
                const padding = panelGetPadding(&ctx.style, panel.type);
                body = panel.bounds;
                body.y = panel.at_y + panel.footer_height + panel.border + padding.y + panel.row.height;
                body.h = (panel.bounds.y + panel.bounds.h) - body.y;
            }
            if (ctx.input.isMousePressed(.left) and ctx.input.isMouseHoveringRect(body)) {
                popup.flags.hidden = true;
            }
        }
        if (popup.flags.hidden) popup.seq = 0;
        ctx.popupEnd();
    }

    fn comboBegin(ctx: *Context, win: *Window, size: Vec2, is_clicked: bool, header: Rect) !bool {
        const popup = win.popup.win;
        const body = Rect{
            .x = header.x,
            .w = size.x,
            .y = header.y + header.h - ctx.style.window.combo_border,
            .h = size.y,
        };
        const hash = win.popup.combo_count;
        win.popup.combo_count += 1;
        const is_open = popup != null;
        const is_active = popup != null and win.popup.name == hash and win.popup.type == .combo;
        if ((is_clicked and is_open and !is_active) or (is_open and !is_active) or (!is_open and !is_active and !is_clicked)) return false;
        if (!try ctx.nonblockBegin(.{}, body, if (is_clicked and is_open) Rect{} else header, .combo)) return false;
        win.popup.type = .combo;
        win.popup.name = hash;
        return true;
    }

    /// Begin a dropdown combo box showing `selected`; `size` is the dropdown
    /// body size. Returns true when open — then emit `comboItemLabel`s and call
    /// `comboEnd` (`nk_combo_begin_label`).
    pub fn comboBeginLabel(ctx: *Context, selected: []const u8, size: Vec2) !bool {
        const win = ctx.current.?;
        const s = &ctx.style;
        const font = s.font.?;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const header = w.bounds;
        const in = if (win.layout.?.flags.rom or w.state == .disabled or w.state == .rom) null else &ctx.input;
        const is_clicked = button_widget.behavior(&ctx.last_widget_state, header, in, .default);

        const out = win.layout.?.buffer;
        const st = ctx.last_widget_state;
        const bg = if (st.actived) s.combo.active else if (st.hover) s.combo.hover else s.combo.normal;
        const label_col = if (st.actived) s.combo.label_active else if (st.hover) s.combo.label_hover else s.combo.label_normal;
        var text_bg: Color = .{ .a = 0 };
        switch (bg) {
            .image => |img| try out.drawImage(header, img, Color.white.factor(s.combo.color_factor)),
            .nine_slice => |sl| try out.drawNineSlice(header, sl, Color.white.factor(s.combo.color_factor)),
            .color => |col| {
                text_bg = col;
                try out.fillRect(header, s.combo.rounding, col.factor(s.combo.color_factor));
                try out.strokeRect(header, s.combo.rounding, s.combo.border, s.combo.border_color.factor(s.combo.color_factor));
            },
        }

        // dropdown arrow button
        const btn = Rect{
            .w = header.h - 2 * s.combo.button_padding.y,
            .x = header.x + header.w - header.h - s.combo.button_padding.x,
            .y = header.y + s.combo.button_padding.y,
            .h = header.h - 2 * s.combo.button_padding.y,
        };
        const sym = if (st.actived) s.combo.sym_active else if (st.hover) s.combo.sym_hover else s.combo.sym_normal;
        _ = button_widget.doButtonSymbol(&ctx.last_widget_state, out, btn, sym, .default, &s.combo.button, in, font) catch false;

        // selected label
        const label_rect = Rect{
            .x = header.x + s.combo.content_padding.x,
            .y = header.y + s.combo.content_padding.y,
            .h = header.h - 2 * s.combo.content_padding.y,
            .w = btn.x - (s.combo.content_padding.x + s.combo.spacing.x) - (header.x + s.combo.content_padding.x),
        };
        try text_widget.widgetText(out, label_rect, selected, Align.text_left, math.Vec2.init(0, 0), text_bg, label_col, font);

        return ctx.comboBegin(win, size, is_clicked, header);
    }

    /// A selectable row inside an open combo/contextual popup; returns true and
    /// closes the popup when clicked (`nk_combo_item_label`).
    pub fn comboItemLabel(ctx: *Context, lbl: []const u8, alignment: Align) !bool {
        const win = ctx.current.?; // the popup window
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const out = win.layout.?.buffer;
        const in = if (w.state == .rom or win.layout.?.flags.rom) null else &ctx.input;
        if (try button_widget.doButtonText(&ctx.last_widget_state, out, w.bounds, lbl, alignment, .default, &ctx.style.contextual_button, in, ctx.style.font.?)) {
            ctx.popupClose();
            return true;
        }
        return false;
    }

    /// Close an open combo box (`nk_combo_end`).
    pub fn comboEnd(ctx: *Context) void {
        ctx.contextualEnd();
    }

    // --- menu -------------------------------------------------------------

    fn menuBegin(ctx: *Context, win: *Window, id: []const u8, is_clicked: bool, header: Rect, size: Vec2) !bool {
        const body = Rect{ .x = header.x, .w = size.x, .y = header.y + header.h, .h = size.y };
        const hash = std.hash.Murmur3_32.hashWithSeed(id, @intFromEnum(PanelType.menu));
        const popup = win.popup.win;
        const is_open = popup != null;
        const is_active = popup != null and win.popup.name == hash and win.popup.type == .menu;
        if ((is_clicked and is_open and !is_active) or (is_open and !is_active) or (!is_open and !is_active and !is_clicked)) return false;
        if (!try ctx.nonblockBegin(.{ .no_scrollbar = true }, body, header, .menu)) return false;
        win.popup.type = .menu;
        win.popup.name = hash;
        return true;
    }

    /// Begin a menu with a text-label header (e.g. a menubar entry). Returns
    /// true when open — then emit `menuItemLabel`s and call `menuEnd`
    /// (`nk_menu_begin_label`).
    pub fn menuBeginLabel(ctx: *Context, lbl: []const u8, alignment: Align, size: Vec2) !bool {
        const win = ctx.current.?;
        const s = &ctx.style;
        const w = ctx.widget();
        if (w.state == .invalid) return false;
        const header = w.bounds;
        const in = if (win.layout.?.flags.rom or w.state != .valid) null else &ctx.input;
        const is_clicked = try button_widget.doButtonText(&ctx.last_widget_state, win.layout.?.buffer, header, lbl, alignment, .default, &s.menu_button, in, s.font.?);
        return ctx.menuBegin(win, lbl, is_clicked, header, size);
    }

    /// A clickable menu entry; closes the menu on click (`nk_menu_item_label`).
    pub fn menuItemLabel(ctx: *Context, lbl: []const u8, alignment: Align) !bool {
        return ctx.comboItemLabel(lbl, alignment);
    }

    /// Close an open menu (`nk_menu_end`).
    pub fn menuEnd(ctx: *Context) void {
        ctx.contextualEnd();
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

test "clicking the close button hides the window next frame" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    // frame 1: locate where the right-aligned close button sits and click it.
    // header height = 13 + 2*4 + 2*4 = 29; close button is ~ at the top-right.
    const bounds = Rect.init(0, 0, 200, 200);
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 190, .y = 12 };
    ctx.input.button(.left, 190, 12, true); // press (default buttons trigger on press)
    _ = try ctx.begin("win", bounds, .{ .title = true, .closable = true });
    ctx.end();
    try std.testing.expect(ctx.lookup.get("win").?.flags.hidden);
    ctx.clear();

    // frame 2: window now reports not visible
    ctx.input.begin();
    const visible = try ctx.begin("win", bounds, .{ .title = true, .closable = true });
    ctx.end();
    try std.testing.expect(!visible);
}

test "tree node persists collapse state and toggles on click" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    // frame 1: starts minimized -> not open
    ctx.input.begin();
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 200), .{});
    const open1 = try ctx.treePush(.tab, "Section", .minimized, 1);
    if (open1) ctx.treePop();
    ctx.end();
    try std.testing.expect(!open1);
    ctx.clear();

    // frame 2: click the tree header to expand it
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 20, .y = 20 };
    ctx.input.button(.left, 20, 20, true);
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 200), .{});
    const open2 = try ctx.treePush(.tab, "Section", .minimized, 1);
    if (open2) ctx.treePop();
    ctx.end();
    try std.testing.expect(open2);
    ctx.clear();

    // frame 3: state persisted -> still open without further input
    ctx.input.begin();
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 200), .{});
    const open3 = try ctx.treePush(.tab, "Section", .minimized, 1);
    if (open3) ctx.treePop();
    ctx.end();
    try std.testing.expect(open3);
}

test "group scroll offset persists across frames" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    const drawGroup = struct {
        fn run(c: *Context) !void {
            _ = try c.begin("w", Rect.init(0, 0, 300, 300), .{});
            c.layoutRowDynamic(120, 1);
            if (try c.groupBegin("g", .{ .border = true })) {
                c.layoutRowDynamic(20, 1);
                for (0..30) |_| try c.label("row", .{ .left = true });
                c.groupEnd();
            }
            c.end();
        }
    }.run;

    // frame 1: hover the group and wheel down to scroll it
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 40, .y = 80 };
    ctx.input.scroll(.{ .x = 0, .y = -3 });
    try drawGroup(&ctx);
    const win = ctx.lookup.get("w").?;
    const key = std.hash.Murmur3_32.hashWithSeed("g", @intFromEnum(PanelType.group));
    const scrolled = win.state.find(key +% 1, ctx.seq).?;
    try std.testing.expect(scrolled > 0); // scrolled down
    ctx.clear();

    // frame 2: no input — the stored offset is still there
    ctx.input.begin();
    try drawGroup(&ctx);
    try std.testing.expectEqual(scrolled, ctx.lookup.get("w").?.state.find(key +% 1, ctx.seq).?);
}

test "group lays out a nested sub-panel" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    _ = try ctx.begin("w", Rect.init(0, 0, 300, 300), .{});
    ctx.layoutRowDynamic(200, 1);
    const open = try ctx.groupBegin("g", .{ .border = true });
    try std.testing.expect(open);
    // the window's layout is now the group's sub-panel (parent chained)
    try std.testing.expect(ctx.current.?.layout.?.parent != null);
    ctx.layoutRowDynamic(20, 1);
    const a = ctx.widget();
    try std.testing.expect(a.bounds.w > 0);
    ctx.groupEnd();
    // back to the window's own panel
    try std.testing.expect(ctx.current.?.layout.?.parent == null);
    ctx.end();
}

test "edit scrolls horizontally to keep the cursor visible" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    var editor = try text_editor.TextEdit.init(std.testing.allocator, 128);
    defer editor.deinit();
    editor.active = true;
    editor.single_line = true;
    try editor.insert("a long line of text that does not fit in the field");

    _ = try ctx.begin("w", Rect.init(0, 0, 120, 60), .{});
    ctx.layoutRowDynamic(30, 1);
    _ = try ctx.editBuffer(EditFlags.field, &editor);
    ctx.end();
    // cursor is at the end, far past the field width, so the text scrolled
    try std.testing.expect(editor.scroll_x > 0);
}

test "combo opens a popup on click and lays out items" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();

    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 20, .y = 20 };
    ctx.input.button(.left, 20, 20, true); // click the combo header

    _ = try ctx.begin("w", Rect.init(0, 0, 200, 200), .{});
    ctx.layoutRowStatic(25, 180, 1);
    const open = try ctx.comboBeginLabel("A", Vec2.init(180, 100));
    try std.testing.expect(open);
    if (open) {
        ctx.layoutRowDynamic(20, 1);
        _ = try ctx.comboItemLabel("Item 1", Align.text_left);
        _ = try ctx.comboItemLabel("Item 2", Align.text_left);
        ctx.comboEnd();
    }
    ctx.end();

    // the popup window now exists on the parent
    try std.testing.expect(ctx.lookup.get("w").?.popup.win != null);
    ctx.clear();
}

test "edit field activates on click and accepts typed text" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    var editor = try text_editor.TextEdit.init(std.testing.allocator, 32);
    defer editor.deinit();

    // frame 1: click inside the field to focus it
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 20, .y = 20 };
    ctx.input.button(.left, 20, 20, true);
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 100), .{});
    ctx.layoutRowDynamic(30, 1);
    const e1 = try ctx.editBuffer(EditFlags.field, &editor);
    ctx.end();
    try std.testing.expect(e1.activated);
    try std.testing.expect(editor.active);
    ctx.clear();

    // frame 2: type "hi"
    ctx.input.begin();
    ctx.input.char('h');
    ctx.input.char('i');
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 100), .{});
    ctx.layoutRowDynamic(30, 1);
    _ = try ctx.editBuffer(EditFlags.field, &editor);
    ctx.end();
    try std.testing.expectEqualStrings("hi", editor.text());
    ctx.clear();
}

test "property inc/dec buttons change the value" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    // click on the far-right inc button
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 175, .y = 16 };
    ctx.input.button(.left, 175, 16, true);
    _ = try ctx.begin("w", Rect.init(0, 0, 200, 100), .{});
    ctx.layoutRowDynamic(25, 1);
    var v: f32 = 5;
    _ = try ctx.propertyFloat("X", 0, &v, 10, 1, 0.5);
    ctx.end();
    try std.testing.expectEqual(@as(f32, 6), v);
}

test "line chart emits markers and lines" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    _ = try ctx.begin("w", Rect.init(0, 0, 300, 200), .{});
    ctx.layoutRowDynamic(100, 1);
    const ok = try ctx.chartBegin(.lines, 4, 0, 10);
    try std.testing.expect(ok);
    _ = ctx.chartPush(1);
    _ = ctx.chartPush(5);
    _ = ctx.chartPush(3);
    _ = ctx.chartPush(8);
    ctx.chartEnd();
    ctx.end();
    var lines: usize = 0;
    for (ctx.windowCommands("w").?) |c| if (c == .line) {
        lines += 1;
    };
    try std.testing.expect(lines >= 3); // 4 points -> 3 connecting lines
}

test "ratio row sizes columns proportionally" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    ctx.input.mouse.pos = .{ .x = 20, .y = 50 };
    _ = try ctx.begin("w", Rect.init(0, 0, 300, 200), .{});
    ctx.layoutRow(.dynamic, 30, &.{ 0.25, 0.75 });
    const a = ctx.widget();
    const b = ctx.widget();
    // second column ~3x the width of the first
    try std.testing.expect(b.bounds.w > a.bounds.w * 2);
    ctx.end();
}

test "template row gives variable column the leftover space" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    _ = try ctx.begin("w", Rect.init(0, 0, 300, 200), .{});
    ctx.layoutRowTemplateBegin(30);
    ctx.layoutRowTemplatePushStatic(40);
    ctx.layoutRowTemplatePushDynamic();
    ctx.layoutRowTemplateEnd();
    const fixed = ctx.widget();
    const dynamic = ctx.widget();
    try std.testing.expectApproxEqAbs(fixed.bounds.w, 40, 0.5);
    try std.testing.expect(dynamic.bounds.w > 100);
    ctx.end();
}

test "scaler drag grows a scalable window" {
    var ctx = Context.init(std.testing.allocator, &test_font);
    defer ctx.deinit();
    const w0: f32 = 200;
    // press on the bottom-right scaler grip, then drag right+down
    ctx.input.begin();
    ctx.input.mouse.pos = .{ .x = 195, .y = 195 };
    ctx.input.button(.left, 195, 195, true);
    ctx.input.mouse.pos = .{ .x = 230, .y = 230 };
    ctx.input.mouse.delta = .{ .x = 35, .y = 35 };
    _ = try ctx.begin("w", Rect.init(0, 0, w0, 200), .{ .scalable = true });
    ctx.end();
    try std.testing.expect(ctx.lookup.get("w").?.bounds.w > w0);
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
