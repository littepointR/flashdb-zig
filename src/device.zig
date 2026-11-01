//! Device: bounds-checked access to a flash partition plus granule-level write
//! primitives and sector-header helpers. KVDB and TSDB share this layer; the
//! record formats stay in their own modules.

const std = @import("std");
const format = @import("format.zig");
const flash = @import("flash.zig");

pub fn Device(comptime F: type, comptime sector_size: u32, comptime sector_count: u16) type {
    comptime {
        if (sector_size == 0 or (sector_size & (sector_size - 1)) != 0)
            @compileError("sector_size must be a power of two");
        if (sector_count < 2) @compileError("at least two sectors are required");
        if (sector_size < F.erase_block_size or sector_size % F.erase_block_size != 0)
            @compileError("sector_size must be a multiple of the flash erase block size");
        if (@as(u64, sector_size) * sector_count > 0xFFFFFFFF)
            @compileError("partition size does not fit in u32 addresses");
    }

    return struct {
        const Self = @This();

        pub const gran = flash.granBytes(F);
        pub const gran_log2 = flash.granLog2(F);
        pub const Error = F.Error || error{ OutOfBounds, Misaligned };
        pub const sector_size_bytes = sector_size;
        pub const sector_num = sector_count;
        pub const total_size = @as(u32, sector_size) * @as(u32, sector_count);

        flash: F,

        pub inline fn init(f: F) Self {
            return .{ .flash = f };
        }

        pub inline fn sectorAddr(self: *const Self, index: u16) u32 {
            _ = self;
            return @as(u32, index) * sector_size;
        }


        pub fn read(self: *Self, addr: u32, buf: []u8) Error!void {
            if (@as(u64, addr) + buf.len > total_size) return error.OutOfBounds;
            try self.flash.read(addr, buf);
        }

        /// Write `data` at `addr`; both must be granule aligned.
        pub fn writeAligned(self: *Self, addr: u32, data: []const u8) Error!void {
            if (data.len == 0) return;
            if (addr % gran != 0 or data.len % gran != 0) return error.Misaligned;
            try self.flash.write(addr, data);
        }

        /// Write `data` at a granule-aligned `addr`, padding the tail of the last
        /// granule with the erased value.
        pub fn writePadded(self: *Self, addr: u32, data: []const u8) Error!void {
            const full = format.alignDown(gran, data.len);
            if (full > 0) try self.writeAligned(addr, data[0..full]);
            const rem = data.len - full;
            if (rem > 0) {
                var tmp: [32]u8 = @splat(0xFF);
                @memcpy(tmp[0..rem], data[full..]);
                try self.writeAligned(addr + @as(u32, @intCast(full)), tmp[0..gran]);
            }
        }

        /// Clear one granule to all-zero (a status marker write).
        pub fn mark(self: *Self, addr: u32) Error!void {
            if (addr % gran != 0) return error.Misaligned;
            var tmp: [32]u8 = @splat(0);
            try self.writeAligned(addr, tmp[0..gran]);
        }

        pub fn eraseSector(self: *Self, index: u16) Error!void {
            try self.flash.erase(self.sectorAddr(index), sector_size);
        }

        /// Read and validate a sector header. `null` means "not formatted".
        pub fn readHeader(self: *Self, index: u16, comptime kind: format.Kind) Error!?format.SectorHeader {
            var buf: [format.sector_header_len]u8 = undefined;
            try self.read(self.sectorAddr(index), &buf);
            return format.decodeSectorHeader(&buf, kind, gran_log2);
        }

        /// Write a sector header (the caller must have erased the sector).
        pub fn writeHeader(self: *Self, index: u16, h: format.SectorHeader) Error!void {
            const len = comptime format.alignUp(gran, format.sector_header_len);
            var buf: [len]u8 = @splat(0xFF);
            format.encodeSectorHeader(buf[0..format.sector_header_len], h);
            try self.writeAligned(self.sectorAddr(index), &buf);
        }

        /// Read `n` status granules at `addr`; true = marker set (all-zero).
        pub fn readMarks(self: *Self, addr: u32, comptime n: usize) Error![n]bool {
            var buf: [n * gran]u8 = undefined;
            try self.read(addr, &buf);
            var out: [n]bool = undefined;
            inline for (0..n) |i| {
                out[i] = format.granuleIsZero(gran, buf[i * gran ..].ptr);
            }
            return out;
        }
    };
}

test "device rejects misaligned and out of range access" {
    const sim = @import("sim.zig");
    const F = sim.RamFlash(.{ .write_gran_bits = 32, .block_size = 4096 });
    var buf: [16384]u8 = undefined;
    var fl = F.init(&buf);
    fl.eraseAll();
    const D = Device(F, 4096, 4);
    var dev = D.init(fl);

    try dev.writeAligned(0, &[_]u8{ 1, 2, 3, 4 });
    try std.testing.expectError(error.Misaligned, dev.writeAligned(2, &[_]u8{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.Misaligned, dev.writeAligned(4, &[_]u8{ 1, 2, 3 }));
    var small: [4]u8 = undefined;
    try dev.read(0, &small);
    try std.testing.expectEqual(@as(u8, 1), small[0]);

    // Padded writes fill the tail with 0xFF.
    try dev.writePadded(8, "abcd");
    try dev.read(8, &small);
    try std.testing.expectEqual(@as(u8, 'd'), small[3]);
    var tail: [4]u8 = undefined;
    try dev.read(12, &tail);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }, &tail);

    // Header round trip.
    try dev.eraseSector(1);
    try dev.writeHeader(1, .{ .seq = 7, .kind = .kvdb, .gran_log2 = D.gran_log2 });
    const h = (try dev.readHeader(1, .kvdb)).?;
    try std.testing.expectEqual(@as(u16, 7), h.seq);
    try std.testing.expectEqual(@as(?format.SectorHeader, null), try dev.readHeader(1, .tsdb));
    try std.testing.expectEqual(@as(?format.SectorHeader, null), try dev.readHeader(0, .kvdb));

    // Status marks.
    const marks_addr = 16;
    try dev.mark(marks_addr + 4);
    const marks = try dev.readMarks(marks_addr, 3);
    try std.testing.expectEqualSlices(bool, &[_]bool{ false, true, false }, &marks);
}
