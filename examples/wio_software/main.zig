//! A software-rendered zuklear demo using wio for the window, input and
//! framebuffer. Run with `zig build example`.

const std = @import("std");
const wio = @import("wio");
const zk = @import("zuklear");
const zkfont = @import("zuklear_font");
const software = zk.render.software;

/// Map a wio button to either a zuklear mouse button or a logical key.
const Mapped = union(enum) { mouse: zk.Button, key: zk.Key, none };

fn mapButton(b: wio.Button) Mapped {
    return switch (b) {
        .mouse_left => .{ .mouse = .left },
        .mouse_right => .{ .mouse = .right },
        .mouse_middle => .{ .mouse = .middle },
        .enter, .kp_enter => .{ .key = .enter },
        .backspace => .{ .key = .backspace },
        .tab => .{ .key = .tab },
        .delete => .{ .key = .del },
        .left => .{ .key = .left },
        .right => .{ .key = .right },
        .up => .{ .key = .up },
        .down => .{ .key = .down },
        .home => .{ .key = .text_line_start },
        .end => .{ .key = .text_line_end },
        .left_shift, .right_shift => .{ .key = .shift },
        .left_control, .right_control => .{ .key = .ctrl },
        else => .none,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try wio.init(gpa, init.io, wio.EventQueue.eventFn, .{});
    defer wio.deinit();

    var events: wio.EventQueue = .empty;
    defer events.deinit();

    var window = try wio.Window.create(.{
        .event_fn_data = &events,
        .title = "zuklear demo",
        .size = .{ .width = 480, .height = 520 },
    });
    defer window.destroy();
    window.enableTextInput(.{});

    var width: usize = 480;
    var height: usize = 520;
    var fb = try window.createFramebuffer(.{ .width = @intCast(width), .height = @intCast(height) });
    defer fb.destroy();
    var pixels = try gpa.alloc(u32, width * height);
    defer gpa.free(pixels);

    // bake a real TTF; fall back to the built-in bitmap font on failure
    var atlas = try zkfont.bake(gpa, @import("assets").ttf, 18, 512, 512);
    defer atlas.deinit();
    const font = atlas.userFont();
    var ctx: zk.Context = .init(gpa, &font);
    defer ctx.deinit();

    // demo state
    var clicks: u32 = 0;
    var checked = false;
    var option: usize = 0;
    var slider: f32 = 0.5;
    var prop: f32 = 25;
    var prog: usize = 40;
    const items = [_][]const u8{ "Red", "Green", "Blue" };
    var selected: usize = 0;
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;

    while (true) {
        wio.update();

        ctx.input.begin();
        var closed = false;
        while (events.pop()) |event| switch (event) {
            .close => closed = true,
            .size_physical => |sz| {
                width = sz.width;
                height = sz.height;
                fb.destroy();
                fb = try window.createFramebuffer(.{ .width = sz.width, .height = sz.height });
                pixels = try gpa.realloc(pixels, width * height);
            },
            .mouse => |p| {
                mouse_x = p.x;
                mouse_y = p.y;
                ctx.input.motion(p.x, p.y);
            },
            .button_press => |b| switch (mapButton(b)) {
                .mouse => |m| ctx.input.button(m, mouse_x, mouse_y, true),
                .key => |k| ctx.input.key(k, true),
                .none => {},
            },
            .button_release => |b| switch (mapButton(b)) {
                .mouse => |m| ctx.input.button(m, mouse_x, mouse_y, false),
                .key => |k| ctx.input.key(k, false),
                .none => {},
            },
            .char => |cp| ctx.input.unicode(cp),
            .scroll_vertical => |v| ctx.input.scroll(.{ .x = 0, .y = -v }),
            else => {},
        };
        ctx.input.end();
        if (closed) break;

        // --- build the UI -------------------------------------------------
        if (try ctx.begin("Demo", .init(20, 20, 440, 480), .{
            .border = true,
            .title = true,
            .movable = true,
            .scalable = true,
        })) {
            ctx.layoutRowDynamic(0, 1);
            try ctx.label("Hello from zuklear!", .{ .left = true, .middle = true });

            ctx.layoutRowDynamic(30, 1);
            if (try ctx.buttonLabel("Click me")) clicks += 1;

            var buf: [64]u8 = undefined;
            ctx.layoutRowDynamic(0, 1);
            try ctx.label(try std.fmt.bufPrint(&buf, "clicks: {d}", .{clicks}), .{ .left = true, .middle = true });

            _ = try ctx.checkboxLabel("Enable feature", &checked);
            if (try ctx.optionLabel("Option A", option == 0)) option = 0;
            if (try ctx.optionLabel("Option B", option == 1)) option = 1;

            ctx.layoutRowDynamic(24, 1);
            _ = try ctx.sliderFloat(0, &slider, 1, 0.01);
            _ = try ctx.progress(&prog, 100, true);
            _ = try ctx.propertyFloat("Value", 0, &prop, 100, 1, 1);

            ctx.layoutRowDynamic(28, 1);
            if (try ctx.comboBeginLabel(items[selected], .init(400, 120))) {
                ctx.layoutRowDynamic(25, 1);
                for (items, 0..) |it, idx| {
                    if (try ctx.comboItemLabel(it, .{ .left = true, .middle = true })) selected = idx;
                }
                ctx.comboEnd();
            }
        }
        ctx.end();

        // --- render -------------------------------------------------------
        var surface: software.Surface = .{ .pixels = pixels, .width = width, .height = height };
        surface.clear(.rgb(28, 28, 28));
        for (ctx.windows.items) |w| {
            var ras: software.Rasterizer = .init(&surface);
            ras.text_fn = &zkfont.renderText; // render the baked TTF glyphs
            ras.renderAll(w.buffer.items());
        }
        for (0..height) |y| {
            for (0..width) |x| fb.setPixel(x, y, pixels[y * width + x]);
        }
        window.presentFramebuffer(&fb);

        ctx.clear();
    }
}
