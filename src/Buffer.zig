//! A double-ended linear buffer, ported from `nuklear_buffer.c`.
//!
//! Memory is allocated from a single block at both ends: the *front* grows
//! upward from offset 0, the *back* grows downward from the top. The only
//! freeing policy is reset/clear. A `fixed` buffer wraps caller-provided
//! memory and never grows; a `dynamic` buffer owns an allocator and grows by
//! `grow_factor` when full.
//!
//! Nuklear's `nk_allocator` callback pair is replaced by `std.mem.Allocator`.

const std = @import("std");
const math = @import("math.zig");

const Buffer = @This();

pub const Type = enum { fixed, dynamic };

/// Which end to allocate from.
pub const Region = enum { front, back };

pub const default_initial_size = 4 * 1024;

const Marker = struct { active: bool = false, offset: usize = 0 };

/// Snapshot of buffer usage (`nk_memory_status`).
pub const Status = struct {
    size: usize,
    allocated: usize,
    needed: usize,
    calls: usize,
};

allocator: ?std.mem.Allocator,
type: Type,
/// The whole backing block; `memory.len` is the physical capacity.
memory: []u8,
/// Back-region boundary: bytes `[size, memory.len)` belong to the back region.
/// Equal to `memory.len` when nothing has been allocated from the back.
size: usize,
/// Front-region boundary: bytes `[0, allocated)` are in use at the front.
allocated: usize = 0,
/// Total bytes requested (statistics), ignoring capacity.
needed: usize = 0,
calls: usize = 0,
grow_factor: f32 = 2.0,
markers: [2]Marker = .{ .{}, .{} },

/// Wrap a fixed, caller-owned memory block (`nk_buffer_init_fixed`).
pub fn initFixed(memory: []u8) Buffer {
    return .{
        .allocator = null,
        .type = .fixed,
        .memory = memory,
        .size = memory.len,
    };
}

/// Create a growable buffer owning `initial_size` bytes (`nk_buffer_init`).
pub fn init(allocator: std.mem.Allocator, initial_size: usize) !Buffer {
    const memory = try allocator.alloc(u8, initial_size);
    return .{
        .allocator = allocator,
        .type = .dynamic,
        .memory = memory,
        .size = memory.len,
    };
}

/// Free owned memory (`nk_buffer_free`). No-op for fixed buffers.
pub fn deinit(b: *Buffer) void {
    if (b.allocator) |a| a.free(b.memory);
    b.* = undefined;
}

fn grow(b: *Buffer, min_alloc: usize) !void {
    const a = b.allocator orelse return error.OutOfMemory;
    const old_cap = b.memory.len;

    var capacity: usize = @intFromFloat(@as(f32, @floatFromInt(old_cap)) * b.grow_factor);
    capacity = @max(capacity, math.roundUpPow2(@intCast(b.allocated + min_alloc)));

    const new_mem = try a.alloc(u8, capacity);
    @memcpy(new_mem[0..old_cap], b.memory[0..old_cap]);

    if (b.size == old_cap) {
        // No back region: the back boundary simply moves to the new top.
        b.size = capacity;
    } else {
        // Relocate the back region to the end of the larger block.
        const back_size = old_cap - b.size;
        std.mem.copyBackwards(u8, new_mem[capacity - back_size ..], new_mem[b.size .. b.size + back_size]);
        b.size = capacity - back_size;
    }

    a.free(b.memory);
    b.memory = new_mem;
}

/// Reserve `size` bytes from `region` with the given power-of-two `alignment`
/// (`0` means unaligned). Returns the reserved slice (`nk_buffer_alloc`).
///
/// The returned slice is invalidated by any subsequent allocation that grows a
/// dynamic buffer; callers that must survive growth should store offsets.
pub fn alloc(b: *Buffer, region: Region, size: usize, alignment: usize) ![]u8 {
    b.needed += size;

    var base = @intFromPtr(b.memory.ptr);
    var plan = b.planAlloc(region, size, base, alignment);

    if (plan.full) {
        if (b.type != .dynamic) return error.OutOfMemory;
        try b.grow(size);
        base = @intFromPtr(b.memory.ptr);
        plan = b.planAlloc(region, size, base, alignment);
    }

    const offset = plan.aligned - base;
    switch (region) {
        .front => b.allocated += size + plan.pad,
        .back => b.size -= size + plan.pad,
    }
    b.needed += plan.pad;
    b.calls += 1;
    return b.memory[offset .. offset + size];
}

const Plan = struct { aligned: usize, pad: usize, full: bool };

fn planAlloc(b: *const Buffer, region: Region, size: usize, base: usize, alignment: usize) Plan {
    switch (region) {
        .front => {
            const unaligned = base + b.allocated;
            const aligned = if (alignment != 0) std.mem.alignForward(usize, unaligned, alignment) else unaligned;
            const pad = aligned - unaligned;
            return .{ .aligned = aligned, .pad = pad, .full = (b.allocated + size + pad) > b.size };
        },
        .back => {
            if (size > b.size) return .{ .aligned = base, .pad = 0, .full = true };
            const unaligned = base + (b.size - size);
            const aligned = if (alignment != 0) std.mem.alignBackward(usize, unaligned, alignment) else unaligned;
            const pad = unaligned - aligned;
            const full = (b.size - @min(b.size, size + pad)) <= b.allocated;
            return .{ .aligned = aligned, .pad = pad, .full = full };
        },
    }
}

/// Copy `bytes` into a freshly reserved region (`nk_buffer_push`).
pub fn push(b: *Buffer, region: Region, bytes: []const u8, alignment: usize) !void {
    const dst = try b.alloc(region, bytes.len, alignment);
    @memcpy(dst, bytes);
}

/// Record the current boundary of `region` so a later `reset` can return to it
/// (`nk_buffer_mark`).
pub fn mark(b: *Buffer, region: Region) void {
    const idx = @intFromEnum(region);
    b.markers[idx].active = true;
    b.markers[idx].offset = switch (region) {
        .front => b.allocated,
        .back => b.size,
    };
}

/// Free a region back to its marker, or fully if no marker is set
/// (`nk_buffer_reset`).
pub fn reset(b: *Buffer, region: Region) void {
    const idx = @intFromEnum(region);
    const m = b.markers[idx];
    switch (region) {
        .back => {
            b.needed -= b.memory.len - m.offset;
            b.size = if (m.active) m.offset else b.memory.len;
        },
        .front => {
            b.needed -= b.allocated - m.offset;
            b.allocated = if (m.active) m.offset else 0;
        },
    }
    b.markers[idx].active = false;
}

/// Drop all allocations from both ends (`nk_buffer_clear`).
pub fn clear(b: *Buffer) void {
    b.allocated = 0;
    b.size = b.memory.len;
    b.calls = 0;
    b.needed = 0;
}

/// The front-region contents as a slice.
pub fn data(b: *const Buffer) []u8 {
    return b.memory[0..b.allocated];
}

/// Physical capacity (`nk_buffer_total`).
pub fn total(b: *const Buffer) usize {
    return b.memory.len;
}

pub fn info(b: *const Buffer) Status {
    return .{ .size = b.memory.len, .allocated = b.allocated, .needed = b.needed, .calls = b.calls };
}

test "fixed buffer front alloc and overflow" {
    var mem: [16]u8 = undefined;
    var b = Buffer.initFixed(&mem);
    const a = try b.alloc(.front, 8, 0);
    try std.testing.expectEqual(@as(usize, 8), a.len);
    _ = try b.alloc(.front, 8, 0);
    try std.testing.expectError(error.OutOfMemory, b.alloc(.front, 1, 0));
    try std.testing.expectEqual(@as(usize, 16), b.allocated);
}

test "dynamic buffer grows" {
    var b = try Buffer.init(std.testing.allocator, 8);
    defer b.deinit();
    try b.push(.front, "hello ", 0);
    try b.push(.front, "world", 0);
    try std.testing.expect(b.memory.len >= 11);
    try std.testing.expectEqualStrings("hello world", b.data());
}

test "back allocation grows downward" {
    var mem: [32]u8 = undefined;
    var b = Buffer.initFixed(&mem);
    const front = try b.alloc(.front, 8, 0);
    const back = try b.alloc(.back, 8, 0);
    try std.testing.expectEqual(@as(usize, 8), b.allocated);
    try std.testing.expectEqual(@as(usize, 24), b.size);
    // Front starts at 0, back sits at the top of the block.
    try std.testing.expectEqual(@intFromPtr(&mem[0]), @intFromPtr(front.ptr));
    try std.testing.expectEqual(@intFromPtr(&mem[24]), @intFromPtr(back.ptr));
}

test "alignment pads allocation" {
    var mem: [64]u8 = undefined;
    var b = Buffer.initFixed(&mem);
    _ = try b.alloc(.front, 1, 0); // offset 0..1
    const aligned = try b.alloc(.front, 4, 16);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 16);
}

test "mark and reset" {
    var mem: [32]u8 = undefined;
    var b = Buffer.initFixed(&mem);
    _ = try b.alloc(.front, 4, 0);
    b.mark(.front);
    _ = try b.alloc(.front, 4, 0);
    try std.testing.expectEqual(@as(usize, 8), b.allocated);
    b.reset(.front);
    try std.testing.expectEqual(@as(usize, 4), b.allocated);
    // Reset with no marker clears the region.
    b.reset(.front);
    try std.testing.expectEqual(@as(usize, 0), b.allocated);
}

test "clear resets both ends" {
    var mem: [32]u8 = undefined;
    var b = Buffer.initFixed(&mem);
    _ = try b.alloc(.front, 4, 0);
    _ = try b.alloc(.back, 4, 0);
    b.clear();
    try std.testing.expectEqual(@as(usize, 0), b.allocated);
    try std.testing.expectEqual(@as(usize, 32), b.size);
}
