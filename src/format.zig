//! On-flash format v1: comptime layout, field codecs, status encoding.
//!
//! All multi-byte fields are little-endian. Every structural boundary is a
//! multiple of the flash write granule so that each write the library issues is
//! a whole number of granules at a granule-aligned address (required by write
//! granularities above one byte, e.g. STM32F1/F4/U5 internal flash).
//!
//! The format is described in `docs/DESIGN.md` section 3. Keep both in sync.

const std = @import("std");

/// Bytes `'F' 'D'` in little-endian order.
pub const magic: u16 = 0x4446;
pub const version: u8 = 1;

pub const Kind = enum(u8) {
    kvdb = 1,
    tsdb = 2,
};

/// Number of bytes in the fixed sector header prefix (before granule alignment).
pub const sector_header_len = 10;

/// Sector header, shared by KVDB and TSDB sectors.
pub const SectorHeader = struct {
    seq: u16,
    kind: Kind,
    gran_log2: u8,
    version: u8 = version,
    flags: u8 = 0,
};

inline fn comptimePow2(comptime n: usize) void {
    if (n == 0 or (n & (n - 1)) != 0) @compileError("alignment must be a power of two");
}

/// Round `n` up to a multiple of `alignment` (comptime power of two).
pub inline fn alignUp(comptime alignment: usize, n: usize) usize {
    comptime comptimePow2(alignment);
    return (n + alignment - 1) & ~(alignment - 1);
}

/// Round `n` down to a multiple of `alignment` (comptime power of two).
pub inline fn alignDown(comptime alignment: usize, n: usize) usize {
    comptime comptimePow2(alignment);
    return n & ~(alignment - 1);
}

// ---------------------------------------------------------------------------
// Little-endian field codecs (no std.mem.readInt: keeps the code independent of
// std API churn and lets the compiler emit single loads/stores).
// ---------------------------------------------------------------------------

pub inline fn rd16(p: [*]const u8) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}

pub inline fn rd32(p: [*]const u8) u32 {
    return @as(u32, p[0]) |
        (@as(u32, p[1]) << 8) |
        (@as(u32, p[2]) << 16) |
        (@as(u32, p[3]) << 24);
}

pub inline fn rd64(p: [*]const u8) u64 {
    return @as(u64, rd32(p)) | (@as(u64, rd32(p + 4)) << 32);
}

pub inline fn wr16(p: [*]u8, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

pub inline fn wr32(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

pub inline fn wr64(p: [*]u8, v: u64) void {
    wr32(p, @truncate(v));
    wr32(p + 4, @truncate(v >> 32));
}

/// Read an unsigned integer of `n` bytes (1, 2, 4 or 8) at `p`.
pub fn UInt(comptime n: usize) type {
    return if (n == 1) u8 else if (n == 2) u16 else if (n == 4) u32 else if (n == 8) u64 else @compileError("unsupported field width");
}

pub inline fn rdN(comptime n: usize, p: [*]const u8) UInt(n) {
    return switch (n) {
        1 => p[0],
        2 => rd16(p),
        4 => rd32(p),
        8 => rd64(p),
        else => @compileError("unsupported field width"),
    };
}

pub inline fn wrN(comptime n: usize, p: [*]u8, v: UInt(n)) void {
    switch (n) {
        1 => p[0] = v,
        2 => wr16(p, v),
        4 => wr32(p, v),
        8 => wr64(p, v),
        else => @compileError("unsupported field width"),
    }
}

// ---------------------------------------------------------------------------
// Granule helpers. A status granule is written exactly once, either as all-zero
// (marker set) or left erased (all-ones = marker clear).
// ---------------------------------------------------------------------------

pub inline fn granuleIsZero(comptime g: usize, p: [*]const u8) bool {
    comptime comptimePow2(g);
    var i: usize = 0;
    while (i < g) : (i += 1) {
        if (p[i] != 0) return false;
    }
    return true;
}

pub inline fn granuleIsErased(comptime g: usize, p: [*]const u8) bool {
    comptime comptimePow2(g);
    var i: usize = 0;
    while (i < g) : (i += 1) {
        if (p[i] != 0xFF) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Sector sequence numbers: unsigned 16-bit with wrap-around ordering.
// ---------------------------------------------------------------------------

/// Return true when `a` is newer than `b` in sequence order.
pub inline fn seqAfter(a: u16, b: u16) bool {
    return @as(i16, @bitCast(a -% b)) > 0;
}

// ---------------------------------------------------------------------------
// Sector header encode / decode.
// ---------------------------------------------------------------------------

/// Encode the fixed sector header prefix into `buf` (at least
/// `sector_header_len` bytes). The caller pads the remainder of the
/// granule-aligned write buffer with 0xFF.
pub fn encodeSectorHeader(buf: []u8, h: SectorHeader) void {
    wr16(buf.ptr, magic);
    buf[2] = h.version;
    buf[3] = h.gran_log2;
    buf[4] = @intFromEnum(h.kind);
    buf[5] = h.flags;
    wr16(buf.ptr + 6, h.seq);
    const crc = crc16(0, buf[0..8]);
    wr16(buf.ptr + 8, crc);
}

/// Decode and validate a sector header prefix. Returns null when the sector is
/// not formatted (erased), belongs to another format version/granularity/kind,
/// or the header checksum does not match.
pub fn decodeSectorHeader(buf: []const u8, kind: Kind, gran_log2: u8) ?SectorHeader {
    if (buf.len < sector_header_len) return null;
    if (rd16(buf.ptr) != magic) return null;
    if (buf[2] != version) return null;
    if (buf[3] != gran_log2) return null;
    if (buf[4] != @intFromEnum(kind)) return null;
    const crc = crc16(0, buf[0..8]);
    if (rd16(buf.ptr + 8) != crc) return null;
    return .{
        .seq = rd16(buf.ptr + 6),
        .kind = kind,
        .gran_log2 = gran_log2,
        .version = version,
        .flags = buf[5],
    };
}

// CRC16-CCITT (polynomial 0x1021, init 0). Only ever applied to the 8-byte
// sector header, but that happens on every mount and on every sector-info read,
// so a 16-entry nibble table (32 B of `.rodata`) replaces the bitwise loop:
// identical CRC values, ~4x fewer operations.
const crc16_nibble_table = blk: {
    var table: [16]u16 = undefined;
    for (0..16) |i| {
        var c: u16 = @as(u16, @intCast(i)) << 12;
        for (0..4) |_| {
            c = if ((c & 0x8000) != 0) (c << 1) ^ 0x1021 else c << 1;
        }
        table[i] = c;
    }
    break :blk table;
};

pub fn crc16(prev: u16, data: []const u8) u16 {
    var c = prev;
    for (data) |b| {
        c ^= @as(u16, b) << 8;
        c = (c << 4) ^ crc16_nibble_table[(c >> 12) & 0xF];
        c = (c << 4) ^ crc16_nibble_table[(c >> 12) & 0xF];
    }
    return c;
}

// ---------------------------------------------------------------------------
// KVDB layout.
// ---------------------------------------------------------------------------

pub fn KvLayout(comptime g: usize, comptime wide_value: bool) type {
    comptime comptimePow2(g);
    const vw: usize = if (wide_value) 4 else 2;
    return struct {
        pub const gran = g;

        // Sector header. KVDB needs no persistent sector-state markers: mount
        // rescans the records anyway (to rebuild free offsets, dirty flags and
        // pending-recovery state), so `using`/`full`/`dirty`/GC-progress are all
        // derived, not stored.
        pub const header_len = alignUp(g, sector_header_len);
        pub const data_off = header_len;

        // Record header (offsets from the record start).
        pub const commit_off = 0;
        pub const pending_off = g;
        pub const deleted_off = 2 * g;
        pub const name_len_off = 3 * g;
        pub const value_len_off = name_len_off + 1;
        pub const crc_off = value_len_off + vw;
        pub const name_off = crc_off + 4;
        /// Bytes preceding the name in a record.
        pub const fixed_len = name_off;
        pub const value_len_bytes = vw;
        pub const ValueLen = if (vw == 2) u16 else u32;

        /// Offset of the value inside a record (name is padded up to a granule).
        pub inline fn valueOff(name_len: usize) usize {
            return alignUp(g, fixed_len + name_len);
        }

        /// Length of the header+name write: bytes from the first status granule's
        /// end up to the value offset.
        pub inline fn hdrNameLen(name_len: usize) usize {
            return alignUp(g, 7 + name_len);
        }

        /// Total on-flash size of a record with the given payload sizes.
        pub inline fn recordLen(name_len: usize, value_len: usize) usize {
            return valueOff(name_len) + alignUp(g, value_len);
        }

    };
}

// ---------------------------------------------------------------------------
// TSDB layout.
// ---------------------------------------------------------------------------

pub fn TsLayout(comptime g: usize, comptime time_bytes: usize) type {
    comptime comptimePow2(g);
    comptime {
        if (time_bytes != 4 and time_bytes != 8) @compileError("timestamp width must be 4 or 8 bytes");
    }
    const time_slot = alignUp(g, time_bytes);
    const half_slot = alignUp(g, 2);
    return struct {
        pub const gran = g;
        pub const time_len = time_bytes;
        pub const Time = if (time_bytes == 4) i32 else i64;

        // Sector header.
        pub const header_len = alignUp(g, sector_header_len);
        pub const state_off = header_len;
        pub const state_len = 2 * g; // using, full
        pub const state_using = 0;
        pub const state_full = 1;
        pub const start_time_off = state_off + state_len;
        pub const end_time_off = start_time_off + time_slot;
        pub const end_offsets_off = end_time_off + time_slot;
        pub const end_offsets_slot = alignUp(g, 4);
        pub const data_off = end_offsets_off + end_offsets_slot;

        // Index record (offsets from the index start).
        pub const commit_off = 0;
        pub const user1_off = g;
        pub const deleted_off = 2 * g;
        pub const user2_off = 3 * g;
        pub const time_off = 4 * g;
        pub const len_off = time_off + time_slot;
        pub const off_off = len_off + half_slot;
        pub const index_len = off_off + half_slot;


    };
}

// ---------------------------------------------------------------------------
// Format tests: layout invariants that the rest of the library relies on.
// ---------------------------------------------------------------------------

test "sector header codec round trip" {
    var buf: [sector_header_len]u8 = undefined;
    encodeSectorHeader(&buf, .{ .seq = 0x1234, .kind = .kvdb, .gran_log2 = 0 });
    const h = decodeSectorHeader(&buf, .kvdb, 0).?;
    try std.testing.expectEqual(@as(u16, 0x1234), h.seq);
    try std.testing.expectEqual(Kind.kvdb, h.kind);
    // Wrong kind / granularity / corrupted checksum must be rejected.
    try std.testing.expectEqual(@as(?SectorHeader, null), decodeSectorHeader(&buf, .tsdb, 0));
    try std.testing.expectEqual(@as(?SectorHeader, null), decodeSectorHeader(&buf, .kvdb, 1));
    buf[6] ^= 0x01;
    try std.testing.expectEqual(@as(?SectorHeader, null), decodeSectorHeader(&buf, .kvdb, 0));
}

test "kv layout is granule aligned" {
    @setEvalBranchQuota(200000);
    inline for ([_]usize{ 1, 4, 8, 16, 32 }) |g| {
        const L = KvLayout(g, false);
        try std.testing.expectEqual(@as(usize, 0), L.data_off % g);
        try std.testing.expectEqual(@as(usize, 0), (L.valueOff(11) - 3 * g) % g);
        inline for ([_]usize{ 1, 5, 11, 64, 1024 }) |name_len| {
            inline for ([_]usize{ 0, 1, 32, 1024 }) |value_len| {
                const len = L.recordLen(name_len, value_len);
                try std.testing.expectEqual(@as(usize, 0), len % g);
                try std.testing.expect(len >= L.fixed_len + name_len + value_len);
                // The three write regions tile the record without overlap.
                try std.testing.expectEqual(len, 3 * g + L.hdrNameLen(name_len) + alignUp(g, value_len));
            }
        }
    }
}

test "ts layout offsets" {
    const L = TsLayout(1, 4);
    try std.testing.expectEqual(@as(usize, 10), L.header_len);
    try std.testing.expectEqual(@as(usize, 12), L.state_off + L.state_len);
    try std.testing.expectEqual(@as(usize, 24), L.data_off);
    try std.testing.expectEqual(@as(usize, 12), L.index_len);
    inline for ([_]usize{ 1, 4, 8, 16, 32 }) |g| {
        inline for ([_]usize{ 4, 8 }) |tb| {
            const T = TsLayout(g, tb);
            try std.testing.expectEqual(@as(usize, 0), T.data_off % g);
            try std.testing.expectEqual(@as(usize, 0), T.index_len % g);
            try std.testing.expect(T.data_off + T.index_len < 4096);
        }
    }
}

test "seq ordering" {
    try std.testing.expect(seqAfter(2, 1));
    try std.testing.expect(!seqAfter(1, 2));
    try std.testing.expect(seqAfter(0, 0xFFFE));
    try std.testing.expect(!seqAfter(0xFFFE, 0));
}

test "crc16 matches the bitwise definition" {
    // Reference bitwise implementation (polynomial 0x1021, init 0).
    const Nibble = struct {
        fn bitwise(prev: u16, data: []const u8) u16 {
            var c = prev;
            for (data) |b| {
                c ^= @as(u16, b) << 8;
                for (0..8) |_| {
                    c = if ((c & 0x8000) != 0) (c << 1) ^ 0x1021 else c << 1;
                }
            }
            return c;
        }
    };
    var buf: [sector_header_len]u8 = undefined;
    encodeSectorHeader(&buf, .{ .seq = 0xBEEF, .kind = .tsdb, .gran_log2 = 3 });
    try std.testing.expectEqual(Nibble.bitwise(0, buf[0..8]), crc16(0, buf[0..8]));
    try std.testing.expectEqual(Nibble.bitwise(0x1234, "12345678"), crc16(0x1234, "12345678"));
    try std.testing.expectEqual(@as(u16, 0), crc16(0, ""));
}