//! zuklear — an idiomatic Zig port of the Nuklear immediate-mode GUI library.
//!
//! This is the public entry point. As the port progresses, each module is
//! re-exported here so consumers can reach the whole API through
//! `@import("zuklear")`. See `PLAN.md` for the porting roadmap.

const std = @import("std");
