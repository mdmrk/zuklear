//! Shared demo asset, embedded once and imported by both wio examples as the
//! `assets` module (see `build.zig`). Lives here so neither example directory
//! has to duplicate the TTF binary.

pub const ttf = @embedFile("font.ttf");
