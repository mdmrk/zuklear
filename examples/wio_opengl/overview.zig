//! A faithful port of Nuklear's canonical `demo/common/overview.c` to zuklear.
//!
//! Persistent demo state (Nuklear's `static` locals) lives in `State`, created
//! once by the caller and threaded through. Sections that need not-yet-ported
//! subsystems (menubar, contextual, blocking popup, tooltips, style stack,
//! tree-element, edit filters, spacing) are marked `TODO` and will land as those
//! land.

const std = @import("std");
const zk = @import("zuklear");

const Color = zk.Color;
const Symbol = zk.Symbol;
const Align = zk.Align;

// window flag bits, matching `WindowFlags` packed-struct layout
const WF_BORDER: u32 = 1 << 0;
const WF_MOVABLE: u32 = 1 << 1;
const WF_SCALABLE: u32 = 1 << 2;
const WF_CLOSABLE: u32 = 1 << 3;
const WF_MINIMIZABLE: u32 = 1 << 4;
const WF_NO_SCROLLBAR: u32 = 1 << 5;
const WF_TITLE: u32 = 1 << 6;
const WF_SCROLL_AUTO_HIDE: u32 = 1 << 7;
const WF_SCALE_LEFT: u32 = 1 << 9;

pub const State = struct {
    show_menu: bool = true,
    show_app_about: bool = false,
    window_flags: u32 = WF_TITLE | WF_BORDER | WF_SCALABLE | WF_MOVABLE | WF_MINIMIZABLE | WF_SCROLL_AUTO_HIDE,
    disable_widgets: bool = false,

    // menubar
    mb_mprog: usize = 60,
    mb_mslider: i32 = 10,
    mb_mcheck: bool = true,
    mb_prog: usize = 40,
    mb_slider: i32 = 10,
    mb_check: bool = true,

    // Widgets > Basic
    checkbox_left_text_left: bool = false,
    checkbox_centered_text_right: bool = false,
    checkbox_right_text_right: bool = false,
    checkbox_right_text_left: bool = false,
    option_left: i32 = 0,
    option_right: i32 = 0,
    int_slider: i32 = 5,
    float_slider: f32 = 2.5,
    int_knob: i32 = 5,
    float_knob: f32 = 2.5,
    prog_value: usize = 40,
    property_float: f32 = 2,
    property_int: i32 = 10,
    property_neg: i32 = 10,
    range_float_min: f32 = 0,
    range_float_max: f32 = 100,
    range_float_value: f32 = 50,
    range_int_min: i32 = 0,
    range_int_value: i32 = 2048,
    range_int_max: i32 = 4096,

    // Widgets > Inactive
    inactive: bool = true,

    // Widgets > Selectable
    sel_list: [4]bool = .{ false, false, true, false },
    sel_grid: [16]bool = .{ true, false, false, false, false, true, false, false, false, false, true, false, false, false, false, true },

    // Chart
    chart_show_markers: bool = true,
    chart_col_index: i32 = -1,
    chart_line_index: i32 = -1,

    // Layout > Group
    group_titlebar: bool = false,
    group_border: bool = true,
    group_no_scrollbar: bool = false,
    group_width: i32 = 320,
    group_height: i32 = 200,
    group_selected: [16]bool = [_]bool{false} ** 16,
    complex_left: [32]bool = [_]bool{false} ** 32,
    complex_rt: [4]bool = [_]bool{false} ** 4,
    complex_rc: [4]bool = [_]bool{false} ** 4,
    complex_rb: [4]bool = [_]bool{false} ** 4,
};

const A = 0;
const B = 1;
const C = 2;

pub fn overview(ctx: *zk.Context, st: *State) !void {
    var actual = st.window_flags;
    if ((actual & WF_TITLE) == 0) actual &= ~(WF_MINIMIZABLE | WF_CLOSABLE);
    const flags: zk.WindowFlags = @bitCast(actual);

    if (try ctx.begin("Overview", .init(10, 10, 400, 600), flags)) {
        if (st.show_menu) try menubar(ctx, st);
        // TODO: About popup (needs blocking popup); `show_app_about` is tracked.

        // --- Window flags ------------------------------------------------
        if (try ctx.treePush(.tab, "Window", .minimized, 1)) {
            ctx.layoutRowDynamic(30, 2);
            _ = try ctx.checkboxLabel("Menu", &st.show_menu);
            _ = try ctx.checkboxFlagsLabel("Titlebar", &st.window_flags, WF_TITLE);
            _ = try ctx.checkboxFlagsLabel("Border", &st.window_flags, WF_BORDER);
            _ = try ctx.checkboxFlagsLabel("Resizable", &st.window_flags, WF_SCALABLE);
            _ = try ctx.checkboxFlagsLabel("Movable", &st.window_flags, WF_MOVABLE);
            _ = try ctx.checkboxFlagsLabel("No Scrollbar", &st.window_flags, WF_NO_SCROLLBAR);
            _ = try ctx.checkboxFlagsLabel("Minimizable", &st.window_flags, WF_MINIMIZABLE);
            _ = try ctx.checkboxFlagsLabel("Scale Left", &st.window_flags, WF_SCALE_LEFT);
            _ = try ctx.checkboxLabel("Disable widgets", &st.disable_widgets);
            ctx.treePop();
        }

        if (st.disable_widgets) ctx.widgetDisableBegin();

        // --- Widgets -----------------------------------------------------
        if (try ctx.treePush(.tab, "Widgets", .minimized, 2)) {
            try widgetsText(ctx);
            try widgetsButton(ctx);
            try widgetsBasic(ctx, st);
            try widgetsInactive(ctx, st);
            try widgetsSelectable(ctx, st);
            // TODO: Combo, Input, Horizontal Rule
            ctx.treePop();
        }

        // --- Chart -------------------------------------------------------
        try chart(ctx, st);

        // TODO: Popup tab (needs contextual/popup/tooltip)

        // --- Layout ------------------------------------------------------
        if (try ctx.treePush(.tab, "Layout", .minimized, 4)) {
            try layoutWidget(ctx);
            try layoutGroup(ctx, st);
            try layoutSimple(ctx, st);
            try layoutComplex(ctx, st);
            // TODO: Tree, Notebook, Splitter
            ctx.treePop();
        }

        // --- Input -------------------------------------------------------
        try inputSection(ctx);

        if (st.disable_widgets) ctx.widgetDisableEnd();
    }
    ctx.end();
}

fn menubar(ctx: *zk.Context, st: *State) !void {
    ctx.menubarBegin();

    // menu #1
    ctx.layoutRowBegin(.static, 25, 5);
    ctx.layoutRowPush(45);
    if (try ctx.menuBeginLabel("MENU", .text_left, .init(120, 200))) {
        ctx.layoutRowDynamic(25, 1);
        if (try ctx.menuItemLabel("Hide", .text_left)) st.show_menu = false;
        if (try ctx.menuItemLabel("About", .text_left)) st.show_app_about = true;
        _ = try ctx.progress(&st.mb_prog, 100, true);
        _ = try ctx.sliderInt(0, &st.mb_slider, 16, 1);
        _ = try ctx.checkboxLabel("check", &st.mb_check);
        ctx.menuEnd();
    }

    // menu #2
    ctx.layoutRowPush(60);
    if (try ctx.menuBeginLabel("ADVANCED", .text_left, .init(200, 600))) {
        if (try ctx.treePush(.tab, "FILE", .minimized, 100)) {
            inline for ([_][]const u8{ "New", "Open", "Save", "Close", "Exit" }) |it| _ = try ctx.menuItemLabel(it, .text_left);
            ctx.treePop();
        }
        if (try ctx.treePush(.tab, "EDIT", .minimized, 101)) {
            inline for ([_][]const u8{ "Copy", "Delete", "Cut", "Paste" }) |it| _ = try ctx.menuItemLabel(it, .text_left);
            ctx.treePop();
        }
        if (try ctx.treePush(.tab, "VIEW", .minimized, 102)) {
            inline for ([_][]const u8{ "About", "Options", "Customize" }) |it| _ = try ctx.menuItemLabel(it, .text_left);
            ctx.treePop();
        }
        if (try ctx.treePush(.tab, "CHART", .minimized, 103)) {
            const values = [_]f32{ 26, 13, 30, 15, 25, 10, 20, 40, 12, 8, 22, 28 };
            ctx.layoutRowDynamic(150, 1);
            if (try ctx.chartBegin(.column, values.len, 0, 50)) {
                for (values) |v| _ = ctx.chartPush(v);
                ctx.chartEnd();
            }
            ctx.treePop();
        }
        ctx.menuEnd();
    }

    // menubar widgets
    ctx.layoutRowPush(70);
    _ = try ctx.progress(&st.mb_mprog, 100, true);
    _ = try ctx.sliderInt(0, &st.mb_mslider, 16, 1);
    _ = try ctx.checkboxLabel("check", &st.mb_mcheck);
    ctx.menubarEnd();
}

fn widgetsText(ctx: *zk.Context) !void {
    if (try ctx.treePush(.node, "Text", .minimized, 10)) {
        ctx.layoutRowDynamic(20, 1);
        try ctx.label("Label aligned left", .text_left);
        try ctx.label("Label aligned centered", .text_centered);
        try ctx.label("Label aligned right", .text_right);
        try ctx.textColored("Blue text", .text_left, Color.rgb(0, 0, 255));
        try ctx.textColored("Yellow text", .text_left, Color.rgb(255, 255, 0));
        try ctx.label("Text without /0", .text_right);

        ctx.layoutRowStatic(100, 200, 1);
        try ctx.labelWrap("This is a very long line to hopefully get this text to be wrapped into multiple lines to show line wrapping");
        ctx.layoutRowDynamic(100, 1);
        try ctx.labelWrap("This is another long text to show dynamic window changes on multiline text");
        ctx.treePop();
    }
}

fn widgetsButton(ctx: *zk.Context) !void {
    if (try ctx.treePush(.node, "Button", .minimized, 11)) {
        ctx.layoutRowStatic(30, 100, 3);
        if (try ctx.buttonLabel("Button")) std.debug.print("Button pressed!\n", .{});
        ctx.buttonSetBehavior(.repeater);
        if (try ctx.buttonLabel("Repeater")) std.debug.print("Repeater is being pressed!\n", .{});
        ctx.buttonSetBehavior(.default);
        _ = try ctx.buttonColor(Color.rgb(0, 0, 255));

        ctx.layoutRowStatic(25, 25, 8);
        const syms = [_]Symbol{
            .circle_solid,        .rect_solid,             .circle_outline,        .rect_outline,
            .triangle_up,         .triangle_right,         .triangle_down,         .triangle_left,
            .triangle_up_outline, .triangle_right_outline, .triangle_down_outline, .triangle_left_outline,
            .chevron_up,          .chevron_right,          .chevron_down,          .chevron_left,
            .hamburger,           .x,                      .underscore,            .plus,
            .minus,
        };
        for (syms) |s| _ = try ctx.buttonSymbol(s);

        ctx.layoutRowStatic(30, 100, 2);
        _ = try ctx.buttonSymbolLabel(.triangle_left, "prev", .text_right);
        _ = try ctx.buttonSymbolLabel(.triangle_right, "next", .text_left);
        ctx.treePop();
    }
}

fn widgetsBasic(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.node, "Basic", .minimized, 12)) {
        const ratio = [_]f32{ 120, 150 };

        ctx.layoutRowDynamic(0, 1);
        _ = try ctx.checkboxLabel("CheckLeft TextLeft", &st.checkbox_left_text_left);
        _ = try ctx.checkboxLabelAlign("CheckCenter TextRight", &st.checkbox_centered_text_right, .{ .centered = true, .middle = true }, .text_right);
        _ = try ctx.checkboxLabelAlign("CheckRight TextRight", &st.checkbox_right_text_right, .{ .left = true, .middle = true }, .text_right);
        _ = try ctx.checkboxLabelAlign("CheckRight TextLeft", &st.checkbox_right_text_left, .{ .right = true, .middle = true }, .text_left);

        ctx.layoutRowStatic(30, 80, 3);
        if (try ctx.optionLabel("optionA", st.option_left == A)) st.option_left = A;
        if (try ctx.optionLabel("optionB", st.option_left == B)) st.option_left = B;
        if (try ctx.optionLabel("optionC", st.option_left == C)) st.option_left = C;

        ctx.layoutRowStatic(30, 80, 3);
        const wr: Align = .{ .right = true, .middle = true };
        if (try ctx.optionLabelAlign("optionA", st.option_right == A, wr, .text_right)) st.option_right = A;
        if (try ctx.optionLabelAlign("optionB", st.option_right == B, wr, .text_right)) st.option_right = B;
        if (try ctx.optionLabelAlign("optionC", st.option_right == C, wr, .text_right)) st.option_right = C;

        var buf: [64]u8 = undefined;
        ctx.layoutRow(.static, 30, &ratio);
        try ctx.label("Slider int", .text_left);
        _ = try ctx.sliderInt(0, &st.int_slider, 10, 1);
        try ctx.label("Slider float", .text_left);
        _ = try ctx.sliderFloat(0, &st.float_slider, 5.0, 0.5);
        try ctx.label(try std.fmt.bufPrint(&buf, "Progressbar: {d}", .{st.prog_value}), .text_left);
        _ = try ctx.progress(&st.prog_value, 100, true);

        ctx.layoutRow(.static, 40, &ratio);
        try ctx.label(try std.fmt.bufPrint(&buf, "Knob int: {d}", .{st.int_knob}), .text_left);
        _ = try ctx.knobInt(0, &st.int_knob, 10, 1, .down, 60.0);
        try ctx.label(try std.fmt.bufPrint(&buf, "Knob float: {d:.2}", .{st.float_knob}), .text_left);
        _ = try ctx.knobFloat(0, &st.float_knob, 5.0, 0.5, .down, 60.0);

        ctx.layoutRow(.static, 25, &ratio);
        try ctx.label("Property float:", .text_left);
        _ = try ctx.propertyFloat("Float:", 0, &st.property_float, 64.0, 0.1, 0.2);
        try ctx.label("Property int:", .text_left);
        _ = try ctx.propertyInt("Int:", 0, &st.property_int, 100, 1, 1);
        try ctx.label("Property neg:", .text_left);
        _ = try ctx.propertyInt("Neg:", -10, &st.property_neg, 10, 1, 1);

        ctx.layoutRowDynamic(25, 1);
        try ctx.label("Range:", .text_left);
        ctx.layoutRowDynamic(25, 3);
        _ = try ctx.propertyFloat("#min:", 0, &st.range_float_min, st.range_float_max, 1.0, 0.2);
        _ = try ctx.propertyFloat("#float:", st.range_float_min, &st.range_float_value, st.range_float_max, 1.0, 0.2);
        _ = try ctx.propertyFloat("#max:", st.range_float_min, &st.range_float_max, 100, 1.0, 0.2);
        _ = try ctx.propertyInt("#min:", std.math.minInt(i32), &st.range_int_min, st.range_int_max, 1, 10);
        _ = try ctx.propertyInt("#neg:", st.range_int_min, &st.range_int_value, st.range_int_max, 1, 10);
        _ = try ctx.propertyInt("#max:", st.range_int_min, &st.range_int_max, std.math.maxInt(i32), 1, 10);
        ctx.treePop();
    }
}

fn widgetsInactive(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.node, "Inactive", .minimized, 13)) {
        ctx.layoutRowDynamic(30, 1);
        _ = try ctx.checkboxLabel("Inactive", &st.inactive);

        ctx.layoutRowStatic(30, 80, 1);
        if (st.inactive) ctx.widgetDisableBegin();
        if (try ctx.buttonLabel("button")) std.debug.print("button pressed\n", .{});
        ctx.widgetDisableEnd();
        ctx.treePop();
    }
}

fn widgetsSelectable(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.node, "Selectable", .minimized, 14)) {
        if (try ctx.treePush(.node, "List", .minimized, 15)) {
            ctx.layoutRowStatic(18, 100, 1);
            _ = try ctx.selectableLabel("Selectable", .text_left, &st.sel_list[0]);
            _ = try ctx.selectableLabel("Selectable", .text_left, &st.sel_list[1]);
            try ctx.label("Not Selectable", .text_left);
            _ = try ctx.selectableLabel("Selectable", .text_left, &st.sel_list[2]);
            _ = try ctx.selectableLabel("Selectable", .text_left, &st.sel_list[3]);
            ctx.treePop();
        }
        if (try ctx.treePush(.node, "Grid", .minimized, 16)) {
            ctx.layoutRowStatic(50, 50, 4);
            for (0..16) |i| {
                if (try ctx.selectableLabel("Z", .text_centered, &st.sel_grid[i])) {
                    const x = i % 4;
                    const y = i / 4;
                    if (x > 0) st.sel_grid[i - 1] = !st.sel_grid[i - 1];
                    if (x < 3) st.sel_grid[i + 1] = !st.sel_grid[i + 1];
                    if (y > 0) st.sel_grid[i - 4] = !st.sel_grid[i - 4];
                    if (y < 3) st.sel_grid[i + 4] = !st.sel_grid[i + 4];
                }
            }
            ctx.treePop();
        }
        ctx.treePop();
    }
}

fn chart(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.tab, "Chart", .minimized, 3)) {
        const step = (2.0 * std.math.pi) / 32.0;
        var buf: [64]u8 = undefined;

        ctx.layoutRowDynamic(15, 1);
        _ = try ctx.checkboxLabel("Show markers", &st.chart_show_markers);
        ctx.style.chart.show_markers = st.chart_show_markers;

        // line chart
        ctx.layoutRowDynamic(100, 1);
        var id: f32 = 0;
        if (try ctx.chartBegin(.lines, 32, -1.0, 1.0)) {
            for (0..32) |i| {
                const res = ctx.chartPush(@cos(id));
                if (res.clicked) st.chart_line_index = @intCast(i);
                id += step;
            }
            ctx.chartEnd();
        }
        // TODO: hover tooltip (needs tooltip subsystem)
        if (st.chart_line_index != -1) {
            ctx.layoutRowDynamic(20, 1);
            try ctx.label(try std.fmt.bufPrint(&buf, "Selected value: {d:.2}", .{@cos(@as(f32, @floatFromInt(st.chart_line_index)) * step)}), .text_left);
        }

        // column chart
        ctx.layoutRowDynamic(100, 1);
        if (try ctx.chartBegin(.column, 32, 0.0, 1.0)) {
            id = 0;
            for (0..32) |i| {
                const res = ctx.chartPush(@abs(@sin(id)));
                if (res.clicked) st.chart_col_index = @intCast(i);
                id += step;
            }
            ctx.chartEnd();
        }
        if (st.chart_col_index != -1) {
            ctx.layoutRowDynamic(20, 1);
            try ctx.label(try std.fmt.bufPrint(&buf, "Selected value: {d:.2}", .{@abs(@sin(step * @as(f32, @floatFromInt(st.chart_col_index))))}), .text_left);
        }
        ctx.treePop();
    }
}

fn layoutWidget(ctx: *zk.Context) !void {
    if (try ctx.treePush(.node, "Widget", .minimized, 40)) {
        const ratio_two = [_]f32{ 0.2, 0.6, 0.2 };
        const width_two = [_]f32{ 100, 200, 50 };

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Dynamic fixed column layout with generated position and size:", .text_left);
        ctx.layoutRowDynamic(30, 3);
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("static fixed column layout with generated position and size:", .text_left);
        ctx.layoutRowStatic(30, 100, 3);
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Dynamic array-based custom column layout:", .text_left);
        ctx.layoutRow(.dynamic, 30, &ratio_two);
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Static array-based custom column layout:", .text_left);
        ctx.layoutRow(.static, 30, &width_two);
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Dynamic immediate mode custom column layout:", .text_left);
        ctx.layoutRowBegin(.dynamic, 30, 3);
        ctx.layoutRowPush(0.2);
        _ = try ctx.buttonLabel("button");
        ctx.layoutRowPush(0.6);
        _ = try ctx.buttonLabel("button");
        ctx.layoutRowPush(0.2);
        _ = try ctx.buttonLabel("button");
        ctx.layoutRowEnd();

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Static free space:", .text_left);
        ctx.layoutSpaceBegin(.static, 60, 4);
        ctx.layoutSpacePush(.init(100, 0, 100, 30));
        _ = try ctx.buttonLabel("button");
        ctx.layoutSpacePush(.init(0, 15, 100, 30));
        _ = try ctx.buttonLabel("button");
        ctx.layoutSpacePush(.init(200, 15, 100, 30));
        _ = try ctx.buttonLabel("button");
        ctx.layoutSpacePush(.init(100, 30, 100, 30));
        _ = try ctx.buttonLabel("button");
        ctx.layoutSpaceEnd();

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Row template:", .text_left);
        ctx.layoutRowTemplateBegin(30);
        ctx.layoutRowTemplatePushDynamic();
        ctx.layoutRowTemplatePushVariable(80);
        ctx.layoutRowTemplatePushStatic(80);
        ctx.layoutRowTemplateEnd();
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        _ = try ctx.buttonLabel("button");
        ctx.treePop();
    }
}

fn layoutGroup(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.node, "Group", .minimized, 41)) {
        var gf: u32 = 0;
        if (st.group_border) gf |= WF_BORDER;
        if (st.group_no_scrollbar) gf |= WF_NO_SCROLLBAR;
        if (st.group_titlebar) gf |= WF_TITLE;

        ctx.layoutRowDynamic(30, 3);
        _ = try ctx.checkboxLabel("Titlebar", &st.group_titlebar);
        _ = try ctx.checkboxLabel("Border", &st.group_border);
        _ = try ctx.checkboxLabel("No Scrollbar", &st.group_no_scrollbar);

        ctx.layoutRowBegin(.static, 22, 3);
        ctx.layoutRowPush(50);
        try ctx.label("size:", .text_left);
        ctx.layoutRowPush(130);
        _ = try ctx.propertyInt("#Width:", 100, &st.group_width, 500, 10, 1);
        ctx.layoutRowPush(130);
        _ = try ctx.propertyInt("#Height:", 100, &st.group_height, 500, 10, 1);
        ctx.layoutRowEnd();

        ctx.layoutRowStatic(@floatFromInt(st.group_height), @floatFromInt(st.group_width), 2);
        if (try ctx.groupBegin("Group", @bitCast(gf))) {
            ctx.layoutRowStatic(18, 100, 1);
            for (0..16) |i| {
                _ = try ctx.selectableLabel(if (st.group_selected[i]) "Selected" else "Unselected", .text_centered, &st.group_selected[i]);
            }
            ctx.groupEnd();
        }
        ctx.treePop();
    }
}

fn layoutSimple(ctx: *zk.Context, st: *State) !void {
    _ = st;
    if (try ctx.treePush(.node, "Simple", .minimized, 42)) {
        var buf: [64]u8 = undefined;
        ctx.layoutRowDynamic(300, 2);
        if (try ctx.groupBegin("Group_Without_Border", @bitCast(@as(u32, 0)))) {
            ctx.layoutRowStatic(18, 150, 1);
            for (0..64) |i| {
                try ctx.label(try std.fmt.bufPrint(&buf, "0x{x:0>2}: scrollable region", .{i}), .text_left);
            }
            ctx.groupEnd();
        }
        if (try ctx.groupBegin("Group_With_Border", @bitCast(WF_BORDER))) {
            ctx.layoutRowDynamic(25, 2);
            for (0..64) |i| {
                const v = (((i % 7) * 10) ^ 32) + (64 + (i % 2) * 2);
                _ = try ctx.buttonLabel(try std.fmt.bufPrint(&buf, "{d:0>8}", .{v}));
            }
            ctx.groupEnd();
        }
        ctx.treePop();
    }
}

fn layoutComplex(ctx: *zk.Context, st: *State) !void {
    if (try ctx.treePush(.node, "Complex", .minimized, 43)) {
        ctx.layoutSpaceBegin(.static, 500, 64);

        ctx.layoutSpacePush(.init(0, 0, 150, 500));
        if (try ctx.groupBegin("Group_left", @bitCast(WF_BORDER))) {
            ctx.layoutRowStatic(18, 100, 1);
            for (0..32) |i| _ = try ctx.selectableLabel(if (st.complex_left[i]) "Selected" else "Unselected", .text_centered, &st.complex_left[i]);
            ctx.groupEnd();
        }

        ctx.layoutSpacePush(.init(160, 0, 150, 240));
        if (try ctx.groupBegin("Group_top", @bitCast(WF_BORDER))) {
            ctx.layoutRowDynamic(25, 1);
            inline for ([_][]const u8{ "#FFAA", "#FFBB", "#FFCC", "#FFDD", "#FFEE", "#FFFF" }) |t| _ = try ctx.buttonLabel(t);
            ctx.groupEnd();
        }

        ctx.layoutSpacePush(.init(160, 250, 150, 250));
        if (try ctx.groupBegin("Group_buttom", @bitCast(WF_BORDER))) {
            ctx.layoutRowDynamic(25, 1);
            inline for ([_][]const u8{ "#FFAA", "#FFBB", "#FFCC", "#FFDD", "#FFEE", "#FFFF" }) |t| _ = try ctx.buttonLabel(t);
            ctx.groupEnd();
        }

        ctx.layoutSpacePush(.init(320, 0, 150, 150));
        if (try ctx.groupBegin("Group_right_top", @bitCast(WF_BORDER))) {
            ctx.layoutRowStatic(18, 100, 1);
            for (0..4) |i| _ = try ctx.selectableLabel(if (st.complex_rt[i]) "Selected" else "Unselected", .text_centered, &st.complex_rt[i]);
            ctx.groupEnd();
        }

        ctx.layoutSpacePush(.init(320, 160, 150, 150));
        if (try ctx.groupBegin("Group_right_center", @bitCast(WF_BORDER))) {
            ctx.layoutRowStatic(18, 100, 1);
            for (0..4) |i| _ = try ctx.selectableLabel(if (st.complex_rc[i]) "Selected" else "Unselected", .text_centered, &st.complex_rc[i]);
            ctx.groupEnd();
        }

        ctx.layoutSpacePush(.init(320, 320, 150, 150));
        if (try ctx.groupBegin("Group_right_bottom", @bitCast(WF_BORDER))) {
            ctx.layoutRowStatic(18, 100, 1);
            for (0..4) |i| _ = try ctx.selectableLabel(if (st.complex_rb[i]) "Selected" else "Unselected", .text_centered, &st.complex_rb[i]);
            ctx.groupEnd();
        }

        ctx.layoutSpaceEnd();
        ctx.treePop();
    }
}

fn inputSection(ctx: *zk.Context) !void {
    if (try ctx.treePush(.tab, "Input", .minimized, 5)) {
        const in = &ctx.input;
        const names = [_][]const u8{ "Left", "Middle", "Right", "Double Click", "X1", "X2" };
        const buttons = [_]zk.Button{ .left, .middle, .right, .double, .x1, .x2 };

        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Mouse Buttons", .text_left);
        ctx.layoutRowDynamic(20, 2);
        for (names, buttons) |name, b| {
            try ctx.label(name, .text_left);
            if (in.isMousePressed(b)) {
                try ctx.label("Pressed", .text_left);
            } else if (in.isMouseDown(b)) {
                try ctx.label("Down", .text_left);
            } else if (in.isMouseReleased(b)) {
                try ctx.label("Released", .text_left);
            } else {
                try ctx.label("Up", .text_left);
            }
        }

        var buf: [64]u8 = undefined;
        ctx.layoutRowDynamic(30, 1);
        try ctx.label("Mouse Wheel", .text_left);
        ctx.layoutRowDynamic(20, 2);
        try ctx.label(try std.fmt.bufPrint(&buf, "X: {d:.2}", .{in.mouse.scroll_delta.x}), .text_left);
        var buf2: [64]u8 = undefined;
        try ctx.label(try std.fmt.bufPrint(&buf2, "Y: {d:.2}", .{in.mouse.scroll_delta.y}), .text_left);
        ctx.treePop();
    }
}
