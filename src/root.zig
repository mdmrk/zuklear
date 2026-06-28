//! zuklear — an idiomatic Zig port of the Nuklear immediate-mode GUI library.
//!
//! This is the public entry point. As the port progresses, each module is
//! re-exported here so consumers can reach the whole API through
//! `@import("zuklear")`. See `PLAN.md` for the porting roadmap.

const std = @import("std");

pub const math = @import("math.zig");
pub const color = @import("color.zig");
pub const Buffer = @import("Buffer.zig");
pub const String = @import("String.zig");
pub const command = @import("command.zig");
pub const input = @import("input.zig");
pub const font = @import("font.zig");
pub const image = @import("image.zig");
pub const style = @import("style.zig");
pub const context = @import("context.zig");
pub const widget = @import("widget.zig");
pub const text = @import("text.zig");
pub const symbol = @import("symbol.zig");
pub const button = @import("button.zig");
pub const toggle = @import("toggle.zig");
pub const slider = @import("slider.zig");
pub const progress = @import("progress.zig");
pub const scrollbar = @import("scrollbar.zig");
pub const selectable = @import("selectable.zig");
pub const knob = @import("knob.zig");
pub const color_picker = @import("color_picker.zig");
pub const text_editor = @import("text_editor.zig");
pub const builtin_font = @import("font/builtin.zig");
pub const render = struct {
    pub const software = @import("render/software.zig");
    pub const vertex = @import("render/vertex.zig");
};
pub const Handle = @import("handle.zig").Handle;

// Re-export the most-used geometry/numeric types at the top level for ergonomics.
pub const Vec2 = math.Vec2;
pub const Vec2i = math.Vec2i;
pub const Rect = math.Rect;
pub const Recti = math.Recti;
pub const Heading = math.Heading;

pub const Color = color.Color;
pub const Colorf = color.Colorf;

pub const Command = command.Command;
pub const CommandBuffer = command.CommandBuffer;

pub const Input = input.Input;
pub const Key = input.Key;
pub const Button = input.Button;

pub const UserFont = font.UserFont;
pub const Image = image.Image;
pub const NineSlice = image.NineSlice;

pub const Style = style.Style;
pub const StyleItem = style.StyleItem;
pub const Symbol = style.Symbol;
pub const Align = style.Align;

pub const Context = context.Context;
pub const Window = context.Window;
pub const Panel = context.Panel;
pub const WindowFlags = context.WindowFlags;
pub const WidgetLayoutState = context.WidgetLayoutState;

test {
    // Pull in every module's tests.
    _ = math;
    _ = color;
    _ = Buffer;
    _ = String;
    _ = command;
    _ = input;
    _ = font;
    _ = image;
    _ = style;
    _ = context;
    _ = widget;
    _ = text;
    _ = symbol;
    _ = button;
    _ = toggle;
    _ = slider;
    _ = progress;
    _ = scrollbar;
    _ = selectable;
    _ = knob;
    _ = color_picker;
    _ = text_editor;
    _ = builtin_font;
    _ = render.software;
    _ = render.vertex;
    _ = @import("handle.zig");
}
