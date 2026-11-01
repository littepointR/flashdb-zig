//! CRC32 (IEEE 802.3, reflected poly 0xEDB88320) and FNV-1a helpers.
//!
//! The 256-entry table is generated at comptime: it costs 1 KiB of `.rodata`
//! (exactly like FlashDB-C's static table) and no RAM or startup code.
//! `update` is a plain streaming accumulator so callers can verify a record's
//! CRC while copying its payload out of flash in one pass.

const crc32_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if ((c & 1) != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        table[i] = c;
    }
    break :blk table;
};

/// Streaming CRC32. Start with 0; chain calls with the previous result.
pub inline fn crc32(prev: u32, data: []const u8) u32 {
    var c = prev ^ 0xFFFFFFFF;
    for (data) |b| {
        c = crc32_table[@as(u8, @truncate(c)) ^ b] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

/// Streaming FNV-1a 32 (used for the key hash; cheap and allocation-free).
pub inline fn fnv1a32(prev: u32, data: []const u8) u32 {
    var h = prev;
    for (data) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

pub const fnv_offset_basis: u32 = 0x811C9DC5;

/// Avalanche finalizer (Murmur3-style) applied to the FNV hash. Raw FNV-1a of
/// similar short keys clusters in a few bits, which makes a 2-way set
/// associative cache thrash; five ALU ops per lookup buy a uniform set/tag
/// distribution.
pub inline fn mix32(x: u32) u32 {
    var h = x;
    h ^= h >> 16;
    h *%= 0x7FEB352D;
    h ^= h >> 15;
    h *%= 0x846CA68B;
    h ^= h >> 16;
    return h;
}

/// Cache/index hash for a key name.
pub inline fn hashName(name: []const u8) u32 {
    return mix32(fnv1a32(fnv_offset_basis, name));
}

const std = @import("std");

test "crc32 known vectors" {
    // Standard check value for "123456789".
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32(0, "123456789"));
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(0, ""));
    // Streaming must equal one-shot.
    const a = crc32(0, "1234");
    const b = crc32(a, "56789");
    try std.testing.expectEqual(@as(u32, 0xCBF43926), b);
}

test "fnv1a32 known vectors" {
    try std.testing.expectEqual(@as(u32, 0x811C9DC5), fnv1a32(fnv_offset_basis, ""));
    try std.testing.expectEqual(@as(u32, 0xE40C292C), fnv1a32(fnv_offset_basis, "a"));
}
