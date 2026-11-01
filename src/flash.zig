//! Flash device protocol and partition adapter.
//!
//! A flash device type `F` must declare:
//!
//! ```zig
//! pub const Error = error{ ... };      // driver error set (may be error{})
//! pub const write_gran_bits: u16;      // 1 | 8 | 32 | 64 | 128 | 256
//! pub const erase_block_size: u32;     // minimum erasable unit in bytes
//! pub fn read(self: *F, addr: u32, buf: []u8) Error!void;
//! pub fn write(self: *F, addr: u32, data: []const u8) Error!void; // aligned!
//! pub fn erase(self: *F, addr: u32, len: u32) Error!void;
//! ```
//!
//! `write` is only ever called with `addr` a multiple of the write granule and
//! `data.len` a multiple of the write granule; the library pads internally.
//! `erase` is only ever called with `addr`/`len` multiples of
//! `erase_block_size` (which must not exceed the configured sector size).

/// Write granule of `F` in bytes (at least 1).
pub fn granBytes(comptime F: type) usize {
    const bits = F.write_gran_bits;
    comptime {
        if (bits != 1 and bits != 8 and bits != 32 and bits != 64 and bits != 128 and bits != 256) {
            @compileError("write_gran_bits must be 1, 8, 32, 64, 128 or 256");
        }
    }
    return if (bits == 1) 1 else bits / 8;
}

/// log2 of the write granule in bytes, stored in the sector header so that a
/// database mounted with the wrong granularity is detected instead of corrupted.
pub fn granLog2(comptime F: type) u8 {
    return switch (granBytes(F)) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        16 => 4,
        32 => 5,
        else => unreachable,
    };
}

/// A byte range of a larger flash device, presented as a standalone `Flash`.
/// This replaces FlashDB's FAL partition registry with a plain value.
pub fn Partition(comptime Dev: type) type {
    return struct {
        const Self = @This();

        dev: *Dev,
        offset: u32,
        len: u32,

        pub const Error = Dev.Error || error{OutOfBounds};
        pub const write_gran_bits = Dev.write_gran_bits;
        pub const erase_block_size = Dev.erase_block_size;

        pub inline fn read(self: *Self, addr: u32, buf: []u8) Error!void {
            if (@as(u64, addr) + buf.len > self.len) return error.OutOfBounds;
            try self.dev.read(self.offset + addr, buf);
        }

        pub inline fn write(self: *Self, addr: u32, data: []const u8) Error!void {
            if (@as(u64, addr) + data.len > self.len) return error.OutOfBounds;
            try self.dev.write(self.offset + addr, data);
        }

        pub inline fn erase(self: *Self, addr: u32, len: u32) Error!void {
            if (@as(u64, addr) + len > self.len) return error.OutOfBounds;
            try self.dev.erase(self.offset + addr, len);
        }
    };
}
