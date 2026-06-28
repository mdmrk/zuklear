//! 32-bit MurmurHash3, ported from `nk_murmur_hash` (`nuklear_util.c`).
//!
//! Nuklear hashes window names and widget identifiers to stable `u32` keys for
//! its persistent per-window state tables. The algorithm is reproduced exactly
//! so ids match across the port.

const std = @import("std");

/// MurmurHash3 x86_32 of `key` with `seed` (`nk_murmur_hash`).
pub fn murmur(key: []const u8, seed: u32) u32 {
    const c1: u32 = 0xcc9e2d51;
    const c2: u32 = 0x1b873593;

    var h1: u32 = seed;
    const nblocks = key.len / 4;

    // body
    var i: usize = 0;
    while (i < nblocks) : (i += 1) {
        var k1 = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
        k1 *%= c1;
        k1 = std.math.rotl(u32, k1, 15);
        k1 *%= c2;

        h1 ^= k1;
        h1 = std.math.rotl(u32, h1, 13);
        h1 = h1 *% 5 +% 0xe6546b64;
    }

    // tail
    const tail = key[nblocks * 4 ..];
    var k1: u32 = 0;
    switch (key.len & 3) {
        3 => {
            k1 ^= @as(u32, tail[2]) << 16;
            k1 ^= @as(u32, tail[1]) << 8;
            k1 ^= tail[0];
            k1 *%= c1;
            k1 = std.math.rotl(u32, k1, 15);
            k1 *%= c2;
            h1 ^= k1;
        },
        2 => {
            k1 ^= @as(u32, tail[1]) << 8;
            k1 ^= tail[0];
            k1 *%= c1;
            k1 = std.math.rotl(u32, k1, 15);
            k1 *%= c2;
            h1 ^= k1;
        },
        1 => {
            k1 ^= tail[0];
            k1 *%= c1;
            k1 = std.math.rotl(u32, k1, 15);
            k1 *%= c2;
            h1 ^= k1;
        },
        else => {},
    }

    // finalization
    h1 ^= @as(u32, @intCast(key.len));
    h1 ^= h1 >> 16;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    h1 *%= 0xc2b2ae35;
    h1 ^= h1 >> 16;
    return h1;
}

test "murmur empty string is zero with seed 0" {
    // MurmurHash3 x86_32 of an empty key with seed 0 is defined to be 0.
    try std.testing.expectEqual(@as(u32, 0), murmur("", 0));
}

test "murmur is deterministic and seed-sensitive" {
    try std.testing.expectEqual(murmur("widget_id", 0), murmur("widget_id", 0));
    try std.testing.expect(murmur("widget_id", 0) != murmur("widget_id", 1));
    try std.testing.expect(murmur("a", 0) != murmur("b", 0));
}

test "murmur handles all tail lengths" {
    // Just exercise lengths 0..7 to cover every tail branch without panicking.
    const s = "abcdefg";
    var prev: u32 = 0;
    for (0..s.len) |n| {
        const h = murmur(s[0..n], 7);
        if (n > 0) try std.testing.expect(h != prev);
        prev = h;
    }
}
