//! zuklear — an idiomatic Zig port of the Nuklear immediate-mode GUI library.
//!
//! This is the public entry point. As the port progresses, each module is
//! re-exported here so consumers can reach the whole API through
//! `@import("zuklear")`. See `PLAN.md` for the porting roadmap.

const std = @import("std");

pub const math = @import("math.zig");
pub const color = @import("color.zig");
pub const utf8 = @import("utf8.zig");
pub const Buffer = @import("Buffer.zig");
pub const String = @import("String.zig");
pub const command = @import("command.zig");
pub const input = @import("input.zig");
pub const font = @import("font.zig");
pub const image = @import("image.zig");
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

test {
    // Pull in every module's tests.
    _ = math;
    _ = color;
    _ = utf8;
    _ = Buffer;
    _ = String;
    _ = command;
    _ = input;
    _ = font;
    _ = image;
    _ = @import("handle.zig");
}
