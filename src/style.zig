//! Widget styling and the default dark theme, ported from `nuklear_style.c`.
//!
//! Nuklear's largest data structure. Fields constant across every instance in
//! `nk_style_from_table` (`color_factor*` = 1.0, `disabled_factor` = 0.5, null
//! draw callbacks, zero touch padding, centered button text) become Zig struct
//! defaults, so `fromTable` only sets what varies. `nk_style_item` becomes a
//! tagged union; the bitflag text alignment becomes a packed struct.

const std = @import("std");
const math = @import("math.zig");
const color = @import("color.zig");
const image = @import("image.zig");
const font = @import("font.zig");
const command = @import("command.zig");
const Handle = @import("handle.zig").Handle;

const Vec2 = math.Vec2;
const Color = color.Color;
const Image = image.Image;
const NineSlice = image.NineSlice;

/// `NK_WIDGET_DISABLED_FACTOR`: brightness multiplier for disabled widgets.
pub const disabled_factor = 0.5;

const DrawFn = *const fn (*command.CommandBuffer, Handle) void;

/// Text/widget alignment flags (`enum nk_text_align`), as a packed bitset.
pub const Align = packed struct(u6) {
    left: bool = false,
    centered: bool = false,
    right: bool = false,
    top: bool = false,
    middle: bool = false,
    bottom: bool = false,

    pub const text_left: Align = .{ .middle = true, .left = true };
    pub const text_centered: Align = .{ .middle = true, .centered = true };
    pub const text_right: Align = .{ .middle = true, .right = true };
};

/// Built-in symbols drawn by widgets (`enum nk_symbol_type`).
pub const Symbol = enum {
    none,
    x,
    underscore,
    circle_solid,
    circle_outline,
    rect_solid,
    rect_outline,
    triangle_up,
    triangle_down,
    triangle_left,
    triangle_right,
    plus,
    minus,
    triangle_up_outline,
    triangle_down_outline,
    triangle_left_outline,
    triangle_right_outline,
    chevron_up,
    chevron_right,
    chevron_down,
    chevron_left,
    hamburger,
};

/// Standard mouse cursor shapes (`enum nk_style_cursor`).
pub const CursorType = enum {
    arrow,
    text,
    move,
    resize_vertical,
    resize_horizontal,
    resize_top_left_down_right,
    resize_top_right_down_left,
};
const cursor_count = @typeInfo(CursorType).@"enum".fields.len;

/// A mouse cursor image (`nk_cursor`).
pub const Cursor = struct { img: Image, size: Vec2, offset: Vec2 };

pub const TooltipPos = enum {
    top_left,
    top_center,
    top_right,
    middle_left,
    middle_center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const HeaderAlign = enum { left, right };

/// A widget-background brush: a flat color, an image, or a nine-slice
/// (`nk_style_item`).
pub const StyleItem = union(enum) {
    color: Color,
    image: Image,
    nine_slice: NineSlice,

    pub fn fromColor(c: Color) StyleItem {
        return .{ .color = c };
    }
    pub fn fromImage(img: Image) StyleItem {
        return .{ .image = img };
    }
    pub fn fromNineSlice(s: NineSlice) StyleItem {
        return .{ .nine_slice = s };
    }
    /// A fully transparent color item (`nk_style_item_hide`).
    pub fn hide() StyleItem {
        return .{ .color = Color.rgba(0, 0, 0, 0) };
    }
};

pub const StyleText = struct {
    color: Color,
    padding: Vec2 = .{},
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
};

pub const StyleButton = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    color_factor_background: f32 = 1.0,
    text_background: Color,
    text_normal: Color,
    text_hover: Color,
    text_active: Color,
    text_alignment: Align = Align.text_centered,
    color_factor_text: f32 = 1.0,
    border: f32,
    rounding: f32,
    padding: Vec2,
    image_padding: Vec2 = .{},
    touch_padding: Vec2 = .{},
    disabled_factor: f32 = disabled_factor,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleToggle = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    cursor_normal: StyleItem,
    cursor_hover: StyleItem,
    text_normal: Color,
    text_hover: Color,
    text_active: Color,
    text_background: Color,
    text_alignment: Align = .{},
    padding: Vec2,
    touch_padding: Vec2 = .{},
    spacing: f32,
    border: f32 = 0,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleSelectable = struct {
    normal: StyleItem,
    hover: StyleItem,
    pressed: StyleItem,
    normal_active: StyleItem,
    hover_active: StyleItem,
    pressed_active: StyleItem,
    text_normal: Color,
    text_hover: Color,
    text_pressed: Color,
    text_normal_active: Color,
    text_hover_active: Color,
    text_pressed_active: Color,
    text_background: Color = .{ .a = 0 },
    text_alignment: Align = .{},
    rounding: f32,
    padding: Vec2,
    touch_padding: Vec2 = .{},
    image_padding: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleSlider = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color = .{ .a = 0 },
    bar_normal: Color,
    bar_hover: Color,
    bar_active: Color,
    bar_filled: Color,
    cursor_normal: StyleItem,
    cursor_hover: StyleItem,
    cursor_active: StyleItem,
    border: f32 = 0,
    rounding: f32,
    bar_height: f32,
    padding: Vec2,
    spacing: Vec2,
    cursor_size: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    show_buttons: bool = false,
    inc_button: StyleButton,
    dec_button: StyleButton,
    inc_symbol: Symbol,
    dec_symbol: Symbol,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleKnob = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color = .{ .a = 0 },
    knob_normal: Color,
    knob_hover: Color,
    knob_active: Color,
    knob_border_color: Color,
    cursor_normal: Color,
    cursor_hover: Color,
    cursor_active: Color,
    border: f32 = 0,
    knob_border: f32,
    padding: Vec2,
    spacing: Vec2,
    cursor_width: f32,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleProgress = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color = .{ .a = 0 },
    cursor_normal: StyleItem,
    cursor_hover: StyleItem,
    cursor_active: StyleItem,
    cursor_border_color: Color = .{ .a = 0 },
    rounding: f32,
    border: f32,
    cursor_border: f32,
    cursor_rounding: f32,
    padding: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleScrollbar = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    cursor_normal: StyleItem,
    cursor_hover: StyleItem,
    cursor_active: StyleItem,
    cursor_border_color: Color,
    border: f32,
    rounding: f32,
    border_cursor: f32,
    rounding_cursor: f32,
    padding: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    show_buttons: bool = false,
    inc_button: StyleButton,
    dec_button: StyleButton,
    inc_symbol: Symbol,
    dec_symbol: Symbol,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleEdit = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    scrollbar: StyleScrollbar,
    cursor_normal: Color,
    cursor_hover: Color,
    cursor_text_normal: Color,
    cursor_text_hover: Color,
    text_normal: Color,
    text_hover: Color,
    text_active: Color,
    selected_normal: Color,
    selected_hover: Color,
    selected_text_normal: Color,
    selected_text_hover: Color,
    border: f32,
    rounding: f32,
    cursor_size: f32,
    scrollbar_size: Vec2 = .{},
    padding: Vec2,
    row_padding: f32 = 0,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
};

pub const StyleProperty = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    label_normal: Color,
    label_hover: Color,
    label_active: Color,
    sym_left: Symbol,
    sym_right: Symbol,
    border: f32,
    rounding: f32,
    padding: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    edit: StyleEdit,
    inc_button: StyleButton,
    dec_button: StyleButton,
    userdata: Handle = .{ .id = 0 },
    draw_begin: ?DrawFn = null,
    draw_end: ?DrawFn = null,
};

pub const StyleChart = struct {
    background: StyleItem,
    border_color: Color,
    selected_color: Color,
    color: Color,
    border: f32,
    rounding: f32,
    padding: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
    show_markers: bool,
};

pub const StyleCombo = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    border_color: Color,
    label_normal: Color,
    label_hover: Color,
    label_active: Color,
    symbol_normal: Color = .{ .a = 0 },
    symbol_hover: Color = .{ .a = 0 },
    symbol_active: Color = .{ .a = 0 },
    button: StyleButton,
    sym_normal: Symbol,
    sym_hover: Symbol,
    sym_active: Symbol,
    border: f32,
    rounding: f32,
    content_padding: Vec2,
    button_padding: Vec2,
    spacing: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
};

pub const StyleTab = struct {
    background: StyleItem,
    border_color: Color,
    text: Color,
    tab_maximize_button: StyleButton,
    tab_minimize_button: StyleButton,
    node_maximize_button: StyleButton,
    node_minimize_button: StyleButton,
    sym_minimize: Symbol,
    sym_maximize: Symbol,
    border: f32,
    rounding: f32,
    indent: f32,
    padding: Vec2,
    spacing: Vec2,
    color_factor: f32 = 1.0,
    disabled_factor: f32 = disabled_factor,
};

pub const StyleWindowHeader = struct {
    normal: StyleItem,
    hover: StyleItem,
    active: StyleItem,
    close_button: StyleButton,
    minimize_button: StyleButton,
    close_symbol: Symbol,
    minimize_symbol: Symbol,
    maximize_symbol: Symbol,
    label_normal: Color,
    label_hover: Color,
    label_active: Color,
    @"align": HeaderAlign,
    padding: Vec2,
    label_padding: Vec2,
    spacing: Vec2,
};

pub const StyleWindow = struct {
    header: StyleWindowHeader,
    fixed_background: StyleItem,
    background: Color,
    border_color: Color,
    popup_border_color: Color,
    combo_border_color: Color,
    contextual_border_color: Color,
    menu_border_color: Color,
    group_border_color: Color,
    tooltip_border_color: Color,
    scaler: StyleItem,
    border: f32,
    combo_border: f32,
    contextual_border: f32,
    menu_border: f32,
    group_border: f32,
    tooltip_border: f32,
    popup_border: f32,
    min_row_height_padding: f32,
    rounding: f32,
    spacing: Vec2,
    scrollbar_size: Vec2,
    min_size: Vec2,
    padding: Vec2,
    group_padding: Vec2,
    popup_padding: Vec2,
    combo_padding: Vec2,
    contextual_padding: Vec2,
    menu_padding: Vec2,
    tooltip_padding: Vec2,
    tooltip_origin: TooltipPos,
    tooltip_offset: Vec2,
    tooltip_delay: f32,
};

/// The full widget theme (`nk_style`).
pub const Style = struct {
    font: ?*const font.UserFont = null,
    cursors: [cursor_count]?*const Cursor = [_]?*const Cursor{null} ** cursor_count,
    cursor_active: ?*const Cursor = null,
    cursor_last: ?*const Cursor = null,
    cursor_visible: bool = false,

    text: StyleText,
    button: StyleButton,
    contextual_button: StyleButton,
    menu_button: StyleButton,
    option: StyleToggle,
    checkbox: StyleToggle,
    selectable: StyleSelectable,
    slider: StyleSlider,
    knob: StyleKnob,
    progress: StyleProgress,
    property: StyleProperty,
    edit: StyleEdit,
    chart: StyleChart,
    scrollh: StyleScrollbar,
    scrollv: StyleScrollbar,
    tab: StyleTab,
    combo: StyleCombo,
    window: StyleWindow,

    /// The default dark theme (`nk_style_default`).
    pub fn default() Style {
        return fromTable(default_color_table);
    }

    /// Build a theme from a color table (`nk_style_from_table`).
    pub fn fromTable(table: [color_count]Color) Style {
        const sc = StyleItem.fromColor;
        const hide = StyleItem.hide;

        // A button styled like a slider/scrollbar increment button (literal
        // greys, not table-derived, matching upstream).
        const small_button: StyleButton = .{
            .normal = sc(.rgb(40, 40, 40)),
            .hover = sc(.rgb(42, 42, 42)),
            .active = sc(.rgb(44, 44, 44)),
            .border_color = Color.rgb(65, 65, 65),
            .text_background = Color.rgb(40, 40, 40),
            .text_normal = Color.rgb(175, 175, 175),
            .text_hover = Color.rgb(175, 175, 175),
            .text_active = Color.rgb(175, 175, 175),
            .border = 1.0,
            .rounding = 0.0,
            .padding = Vec2.init(8, 8),
        };
        var scroll_button = small_button;
        scroll_button.padding = Vec2.init(4, 4);

        const scrollbar: StyleScrollbar = .{
            .normal = sc(col(table, .scrollbar)),
            .hover = sc(col(table, .scrollbar)),
            .active = sc(col(table, .scrollbar)),
            .cursor_normal = sc(col(table, .scrollbar_cursor)),
            .cursor_hover = sc(col(table, .scrollbar_cursor_hover)),
            .cursor_active = sc(col(table, .scrollbar_cursor_active)),
            .dec_symbol = .circle_solid,
            .inc_symbol = .circle_solid,
            .border_color = col(table, .scrollbar),
            .cursor_border_color = col(table, .scrollbar),
            .padding = Vec2.init(0, 0),
            .border = 0,
            .rounding = 0,
            .border_cursor = 0,
            .rounding_cursor = 0,
            .inc_button = scroll_button,
            .dec_button = scroll_button,
        };

        const edit: StyleEdit = .{
            .normal = sc(col(table, .edit)),
            .hover = sc(col(table, .edit)),
            .active = sc(col(table, .edit)),
            .cursor_normal = col(table, .text),
            .cursor_hover = col(table, .text),
            .cursor_text_normal = col(table, .edit),
            .cursor_text_hover = col(table, .edit),
            .border_color = col(table, .border),
            .text_normal = col(table, .text),
            .text_hover = col(table, .text),
            .text_active = col(table, .text),
            .selected_normal = col(table, .text),
            .selected_hover = col(table, .text),
            .selected_text_normal = col(table, .edit),
            .selected_text_hover = col(table, .edit),
            .scrollbar_size = Vec2.init(10, 10),
            .scrollbar = scrollbar,
            .padding = Vec2.init(4, 4),
            .row_padding = 2,
            .cursor_size = 4,
            .border = 1,
            .rounding = 0,
        };

        const property_button: StyleButton = .{
            .normal = sc(col(table, .property)),
            .hover = sc(col(table, .property)),
            .active = sc(col(table, .property)),
            .border_color = Color.rgba(0, 0, 0, 0),
            .text_background = col(table, .property),
            .text_normal = col(table, .text),
            .text_hover = col(table, .text),
            .text_active = col(table, .text),
            .padding = Vec2.init(0, 0),
            .border = 0,
            .rounding = 0,
        };

        var property_edit = edit;
        property_edit.normal = sc(col(table, .property));
        property_edit.hover = sc(col(table, .property));
        property_edit.active = sc(col(table, .property));
        property_edit.border_color = Color.rgba(0, 0, 0, 0);
        property_edit.padding = Vec2.init(0, 0);
        property_edit.cursor_size = 8;
        property_edit.border = 0;

        const tab_button: StyleButton = .{
            .normal = sc(col(table, .tab_header)),
            .hover = sc(col(table, .tab_header)),
            .active = sc(col(table, .tab_header)),
            .border_color = Color.rgba(0, 0, 0, 0),
            .text_background = col(table, .tab_header),
            .text_normal = col(table, .text),
            .text_hover = col(table, .text),
            .text_active = col(table, .text),
            .padding = Vec2.init(2, 2),
            .border = 0,
            .rounding = 0,
        };
        var node_button = tab_button;
        node_button.normal = sc(col(table, .window));
        node_button.hover = sc(col(table, .window));
        node_button.active = sc(col(table, .window));

        const header_button: StyleButton = .{
            .normal = sc(col(table, .header)),
            .hover = sc(col(table, .header)),
            .active = sc(col(table, .header)),
            .border_color = Color.rgba(0, 0, 0, 0),
            .text_background = col(table, .header),
            .text_normal = col(table, .text),
            .text_hover = col(table, .text),
            .text_active = col(table, .text),
            .padding = Vec2.init(0, 0),
            .border = 0,
            .rounding = 0,
        };

        return .{
            .text = .{ .color = col(table, .text) },
            .button = .{
                .normal = sc(col(table, .button)),
                .hover = sc(col(table, .button_hover)),
                .active = sc(col(table, .button_active)),
                .border_color = col(table, .border),
                .text_background = col(table, .button),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_active = col(table, .text),
                .border = 1.0,
                .rounding = 4.0,
                .padding = Vec2.init(2, 2),
            },
            .contextual_button = .{
                .normal = sc(col(table, .window)),
                .hover = sc(col(table, .button_hover)),
                .active = sc(col(table, .button_active)),
                .border_color = col(table, .window),
                .text_background = col(table, .window),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_active = col(table, .text),
                .border = 0.0,
                .rounding = 0.0,
                .padding = Vec2.init(2, 2),
            },
            .menu_button = .{
                .normal = sc(col(table, .window)),
                .hover = sc(col(table, .window)),
                .active = sc(col(table, .window)),
                .border_color = col(table, .window),
                .text_background = col(table, .window),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_active = col(table, .text),
                .border = 0.0,
                .rounding = 1.0,
                .padding = Vec2.init(2, 2),
            },
            .checkbox = .{
                .normal = sc(col(table, .toggle)),
                .hover = sc(col(table, .toggle_hover)),
                .active = sc(col(table, .toggle_hover)),
                .cursor_normal = sc(col(table, .toggle_cursor)),
                .cursor_hover = sc(col(table, .toggle_cursor)),
                .border_color = Color.rgba(0, 0, 0, 0),
                .text_background = col(table, .window),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_active = col(table, .text),
                .padding = Vec2.init(2, 2),
                .spacing = 4,
            },
            .option = .{
                .normal = sc(col(table, .toggle)),
                .hover = sc(col(table, .toggle_hover)),
                .active = sc(col(table, .toggle_hover)),
                .cursor_normal = sc(col(table, .toggle_cursor)),
                .cursor_hover = sc(col(table, .toggle_cursor)),
                .border_color = Color.rgba(0, 0, 0, 0),
                .text_background = col(table, .window),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_active = col(table, .text),
                .padding = Vec2.init(3, 3),
                .spacing = 4,
            },
            .selectable = .{
                .normal = sc(col(table, .select)),
                .hover = sc(col(table, .select)),
                .pressed = sc(col(table, .select)),
                .normal_active = sc(col(table, .select_active)),
                .hover_active = sc(col(table, .select_active)),
                .pressed_active = sc(col(table, .select_active)),
                .text_normal = col(table, .text),
                .text_hover = col(table, .text),
                .text_pressed = col(table, .text),
                .text_normal_active = col(table, .text),
                .text_hover_active = col(table, .text),
                .text_pressed_active = col(table, .text),
                .padding = Vec2.init(2, 2),
                .image_padding = Vec2.init(2, 2),
                .rounding = 0.0,
            },
            .slider = .{
                .normal = hide(),
                .hover = hide(),
                .active = hide(),
                .bar_normal = col(table, .slider),
                .bar_hover = col(table, .slider),
                .bar_active = col(table, .slider),
                .bar_filled = col(table, .slider_cursor),
                .cursor_normal = sc(col(table, .slider_cursor)),
                .cursor_hover = sc(col(table, .slider_cursor_hover)),
                .cursor_active = sc(col(table, .slider_cursor_active)),
                .inc_symbol = .triangle_right,
                .dec_symbol = .triangle_left,
                .cursor_size = Vec2.init(16, 16),
                .padding = Vec2.init(2, 2),
                .spacing = Vec2.init(2, 2),
                .bar_height = 4,
                .rounding = 0,
                .inc_button = small_button,
                .dec_button = small_button,
            },
            .knob = .{
                .normal = hide(),
                .hover = hide(),
                .active = hide(),
                .knob_normal = col(table, .knob),
                .knob_hover = col(table, .knob),
                .knob_active = col(table, .knob),
                .cursor_normal = col(table, .knob_cursor),
                .cursor_hover = col(table, .knob_cursor_hover),
                .cursor_active = col(table, .knob_cursor_active),
                .knob_border_color = col(table, .border),
                .knob_border = 1.0,
                .padding = Vec2.init(2, 2),
                .spacing = Vec2.init(2, 2),
                .cursor_width = 2,
            },
            .progress = .{
                .normal = sc(col(table, .slider)),
                .hover = sc(col(table, .slider)),
                .active = sc(col(table, .slider)),
                .cursor_normal = sc(col(table, .slider_cursor)),
                .cursor_hover = sc(col(table, .slider_cursor_hover)),
                .cursor_active = sc(col(table, .slider_cursor_active)),
                .padding = Vec2.init(4, 4),
                .rounding = 0,
                .border = 0,
                .cursor_rounding = 0,
                .cursor_border = 0,
            },
            .property = .{
                .normal = sc(col(table, .property)),
                .hover = sc(col(table, .property)),
                .active = sc(col(table, .property)),
                .border_color = col(table, .border),
                .label_normal = col(table, .text),
                .label_hover = col(table, .text),
                .label_active = col(table, .text),
                .sym_left = .triangle_left,
                .sym_right = .triangle_right,
                .padding = Vec2.init(4, 4),
                .border = 1,
                .rounding = 10,
                .edit = property_edit,
                .inc_button = property_button,
                .dec_button = property_button,
            },
            .edit = edit,
            .chart = .{
                .background = sc(col(table, .chart)),
                .border_color = col(table, .border),
                .selected_color = col(table, .chart_color_highlight),
                .color = col(table, .chart_color),
                .padding = Vec2.init(4, 4),
                .border = 0,
                .rounding = 0,
                .show_markers = true,
            },
            .scrollh = scrollbar,
            .scrollv = scrollbar,
            .tab = .{
                .background = sc(col(table, .tab_header)),
                .border_color = col(table, .border),
                .text = col(table, .text),
                .sym_minimize = .triangle_right,
                .sym_maximize = .triangle_down,
                .padding = Vec2.init(4, 4),
                .spacing = Vec2.init(4, 4),
                .indent = 10.0,
                .border = 1,
                .rounding = 0,
                .tab_maximize_button = tab_button,
                .tab_minimize_button = tab_button,
                .node_maximize_button = node_button,
                .node_minimize_button = node_button,
            },
            .combo = .{
                .normal = sc(col(table, .combo)),
                .hover = sc(col(table, .combo)),
                .active = sc(col(table, .combo)),
                .border_color = col(table, .border),
                .label_normal = col(table, .text),
                .label_hover = col(table, .text),
                .label_active = col(table, .text),
                .sym_normal = .triangle_down,
                .sym_hover = .triangle_down,
                .sym_active = .triangle_down,
                .button = .{
                    .normal = sc(col(table, .combo)),
                    .hover = sc(col(table, .combo)),
                    .active = sc(col(table, .combo)),
                    .border_color = Color.rgba(0, 0, 0, 0),
                    .text_background = col(table, .combo),
                    .text_normal = col(table, .text),
                    .text_hover = col(table, .text),
                    .text_active = col(table, .text),
                    .padding = Vec2.init(2, 2),
                    .border = 0,
                    .rounding = 0,
                },
                .content_padding = Vec2.init(4, 4),
                .button_padding = Vec2.init(0, 4),
                .spacing = Vec2.init(4, 0),
                .border = 1,
                .rounding = 0,
            },
            .window = .{
                .header = .{
                    .@"align" = .right,
                    .close_symbol = .x,
                    .minimize_symbol = .minus,
                    .maximize_symbol = .plus,
                    .normal = sc(col(table, .header)),
                    .hover = sc(col(table, .header)),
                    .active = sc(col(table, .header)),
                    .label_normal = col(table, .text),
                    .label_hover = col(table, .text),
                    .label_active = col(table, .text),
                    .label_padding = Vec2.init(4, 4),
                    .padding = Vec2.init(4, 4),
                    .spacing = Vec2.init(0, 0),
                    .close_button = header_button,
                    .minimize_button = header_button,
                },
                .fixed_background = sc(col(table, .window)),
                .background = col(table, .window),
                .border_color = col(table, .border),
                .popup_border_color = col(table, .border),
                .combo_border_color = col(table, .border),
                .contextual_border_color = col(table, .border),
                .menu_border_color = col(table, .border),
                .group_border_color = col(table, .border),
                .tooltip_border_color = col(table, .border),
                .scaler = sc(col(table, .text)),
                .rounding = 0.0,
                .spacing = Vec2.init(4, 4),
                .scrollbar_size = Vec2.init(10, 10),
                .min_size = Vec2.init(64, 64),
                .combo_border = 1.0,
                .contextual_border = 1.0,
                .menu_border = 1.0,
                .group_border = 1.0,
                .tooltip_border = 1.0,
                .popup_border = 1.0,
                .border = 2.0,
                .min_row_height_padding = 8,
                .padding = Vec2.init(4, 4),
                .group_padding = Vec2.init(4, 4),
                .popup_padding = Vec2.init(4, 4),
                .combo_padding = Vec2.init(4, 4),
                .contextual_padding = Vec2.init(4, 4),
                .menu_padding = Vec2.init(4, 4),
                .tooltip_padding = Vec2.init(4, 4),
                .tooltip_origin = .top_left,
                .tooltip_offset = Vec2.init(12, 12),
                .tooltip_delay = 0.5,
            },
        };
    }
};

/// Indices into a style color table (`enum nk_style_colors`).
pub const ColorId = enum {
    text,
    window,
    header,
    border,
    button,
    button_hover,
    button_active,
    toggle,
    toggle_hover,
    toggle_cursor,
    select,
    select_active,
    slider,
    slider_cursor,
    slider_cursor_hover,
    slider_cursor_active,
    property,
    edit,
    edit_cursor,
    combo,
    chart,
    chart_color,
    chart_color_highlight,
    scrollbar,
    scrollbar_cursor,
    scrollbar_cursor_hover,
    scrollbar_cursor_active,
    tab_header,
    knob,
    knob_cursor,
    knob_cursor_hover,
    knob_cursor_active,
};
pub const color_count = @typeInfo(ColorId).@"enum".fields.len;

fn col(table: [color_count]Color, id: ColorId) Color {
    return table[@intFromEnum(id)];
}

/// The default dark color table (`nk_default_color_style`).
pub const default_color_table: [color_count]Color = blk: {
    var t: [color_count]Color = undefined;
    const rgb = struct {
        fn f(r: u8, g: u8, b: u8) Color {
            return .{ .r = r, .g = g, .b = b, .a = 255 };
        }
    }.f;
    t[@intFromEnum(ColorId.text)] = rgb(175, 175, 175);
    t[@intFromEnum(ColorId.window)] = rgb(45, 45, 45);
    t[@intFromEnum(ColorId.header)] = rgb(40, 40, 40);
    t[@intFromEnum(ColorId.border)] = rgb(65, 65, 65);
    t[@intFromEnum(ColorId.button)] = rgb(50, 50, 50);
    t[@intFromEnum(ColorId.button_hover)] = rgb(40, 40, 40);
    t[@intFromEnum(ColorId.button_active)] = rgb(35, 35, 35);
    t[@intFromEnum(ColorId.toggle)] = rgb(100, 100, 100);
    t[@intFromEnum(ColorId.toggle_hover)] = rgb(120, 120, 120);
    t[@intFromEnum(ColorId.toggle_cursor)] = rgb(45, 45, 45);
    t[@intFromEnum(ColorId.select)] = rgb(45, 45, 45);
    t[@intFromEnum(ColorId.select_active)] = rgb(35, 35, 35);
    t[@intFromEnum(ColorId.slider)] = rgb(38, 38, 38);
    t[@intFromEnum(ColorId.slider_cursor)] = rgb(100, 100, 100);
    t[@intFromEnum(ColorId.slider_cursor_hover)] = rgb(120, 120, 120);
    t[@intFromEnum(ColorId.slider_cursor_active)] = rgb(150, 150, 150);
    t[@intFromEnum(ColorId.property)] = rgb(38, 38, 38);
    t[@intFromEnum(ColorId.edit)] = rgb(38, 38, 38);
    t[@intFromEnum(ColorId.edit_cursor)] = rgb(175, 175, 175);
    t[@intFromEnum(ColorId.combo)] = rgb(45, 45, 45);
    t[@intFromEnum(ColorId.chart)] = rgb(120, 120, 120);
    t[@intFromEnum(ColorId.chart_color)] = rgb(45, 45, 45);
    t[@intFromEnum(ColorId.chart_color_highlight)] = rgb(255, 0, 0);
    t[@intFromEnum(ColorId.scrollbar)] = rgb(40, 40, 40);
    t[@intFromEnum(ColorId.scrollbar_cursor)] = rgb(100, 100, 100);
    t[@intFromEnum(ColorId.scrollbar_cursor_hover)] = rgb(120, 120, 120);
    t[@intFromEnum(ColorId.scrollbar_cursor_active)] = rgb(150, 150, 150);
    t[@intFromEnum(ColorId.tab_header)] = rgb(40, 40, 40);
    t[@intFromEnum(ColorId.knob)] = rgb(38, 38, 38);
    t[@intFromEnum(ColorId.knob_cursor)] = rgb(100, 100, 100);
    t[@intFromEnum(ColorId.knob_cursor_hover)] = rgb(120, 120, 120);
    t[@intFromEnum(ColorId.knob_cursor_active)] = rgb(150, 150, 150);
    break :blk t;
};

test "default theme derives colors from the table" {
    const s: Style = .default();
    try std.testing.expectEqual(Color.rgb(175, 175, 175), s.text.color);
    try std.testing.expectEqual(Color.rgb(50, 50, 50), s.button.normal.color);
    try std.testing.expectEqual(@as(f32, 4.0), s.button.rounding);
    try std.testing.expectEqual(Align.text_centered, s.button.text_alignment);
    try std.testing.expectEqual(@as(f32, 0.5), s.button.disabled_factor);
    // Slider backgrounds are hidden (transparent color items).
    try std.testing.expectEqual(Color.rgba(0, 0, 0, 0), s.slider.normal.color);
    try std.testing.expectEqual(@as(f32, 2.0), s.window.border);
}

test "Align packs to nuklear bit values" {
    try std.testing.expectEqual(@as(u6, 0x01), @as(u6, @bitCast(Align{ .left = true })));
    try std.testing.expectEqual(@as(u6, 0x10), @as(u6, @bitCast(Align{ .middle = true })));
    try std.testing.expectEqual(@as(u6, 0x12), @as(u6, @bitCast(Align.text_centered)));
}
