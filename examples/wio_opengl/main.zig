//! The zuklear wio demo, rendered with OpenGL: each frame's command buffers are
//! converted to a vertex draw list (`render.vertex`) and drawn by the
//! fixed-function GL renderer in `gl.zig`. Run with `zig build run-example`.

const std = @import("std");
const wio = @import("wio");
const zk = @import("zuklear");
const zkfont = @import("zuklear_font");
const glr = @import("gl.zig");
const overview = @import("overview.zig");

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
        .title = "zuklear demo (OpenGL)",
        .size = .{ .width = 480, .height = 520 },
        .gl_options = .{},
    });
    defer window.destroy();
    window.enableTextInput(.{});

    const gl_ctx = try window.glCreateContext(.{ .options = .{} });
    defer gl_ctx.destroy();
    window.glMakeContextCurrent(gl_ctx);
    window.glSwapInterval(1);

    var renderer: glr.Renderer = .init(&wio.glGetProcAddress);

    // Nuklear's default font (ProggyClean), so the demo matches upstream.
    var atlas = try zkfont.bakeDefault(gpa, 13);
    defer atlas.deinit();
    try renderer.uploadFont(gpa, &atlas);
    const font = atlas.userFont();

    var ctx: zk.Context = .init(gpa, &font);
    defer ctx.deinit();

    var draw_list: zk.render.vertex.DrawList = .init(gpa);
    defer draw_list.deinit();

    var fb_w: i32 = 480;
    var fb_h: i32 = 520;

    // demo state (Nuklear's overview `static` locals live here)
    var st: overview.State = .{};
    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    // vsync is on (swap interval 1), so frames pace at the display refresh; a
    // fixed ~60 Hz delta drives time-based behavior like SCROLL_AUTO_HIDE.
    ctx.delta_time_seconds = 1.0 / 60.0;

    while (true) {
        wio.update();

        ctx.input.begin();
        var closed = false;
        while (events.pop()) |event| switch (event) {
            .close => closed = true,
            .size_physical => |sz| {
                fb_w = sz.width;
                fb_h = sz.height;
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

        // --- build the UI: the canonical Nuklear overview demo ------------
        try overview.overview(&ctx, &st);

        // --- convert + draw ----------------------------------------------
        draw_list.reset();
        const cfg: zk.render.vertex.ConvertConfig = .{
            .white_uv = atlas.whiteUv(),
            .text_hook = &zkfont.drawListText,
            // both AA flags on, as Nuklear's reference backends default
            .shape_aa = true,
            .line_aa = true,
        };
        for (ctx.windows.items) |w| try draw_list.convert(w.buffer.items(), cfg);

        renderer.clear(fb_w, fb_h, .rgb(28, 28, 28));
        renderer.render(&draw_list, fb_w, fb_h);
        window.glSwapBuffers();

        ctx.clear();
    }
}
