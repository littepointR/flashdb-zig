//! FlashDB-Zig: a from-scratch Zig implementation of FlashDB's KVDB and TSDB.
//!
//! ```zig
//! const flashdb = @import("flashdb");
//! const sim = flashdb.sim;
//!
//! var mem: [16 * 1024]u8 = undefined;
//! const Flash = sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
//! var fl = Flash.init(&mem);
//! fl.eraseAll();
//!
//! const Db = flashdb.Kvdb(Flash, .{ .sector_size = 4096, .sector_count = 4 });
//! var db: Db = undefined;
//! try db.mount(fl);
//! try db.set("boot_count", &[_]u8{ 42, 0, 0, 0 });
//!
//! var buf: [16]u8 = undefined;
//! const n = (try db.get("boot_count", &buf)).?;
//! ```
//!
//! The library is `no_std`, allocation-free and has no global state: a database
//! owns its flash driver value, so several databases (or partitions of one
//! driver) can coexist without a registry. All geometry, write granularity,
//! timestamp width and cache sizing are compile-time parameters.

pub const format = @import("format.zig");
pub const flash = @import("flash.zig");
pub const crc = @import("crc.zig");
pub const device = @import("device.zig");
pub const sim = @import("sim.zig");

pub const Kvdb = @import("kvdb.zig").Kvdb;
pub const KvdbConfig = @import("kvdb.zig").Config;

pub const Tsdb = @import("tsdb.zig").Tsdb;
pub const TsdbConfig = @import("tsdb.zig").Config;

/// Write granularity of a flash driver in bits, for tables and docs.
pub fn writeGranBits(comptime F: type) u16 {
    return F.write_gran_bits;
}

test {
    // Pull in the unit tests of every module.
    _ = format;
    _ = crc;
    _ = device;
    _ = sim;
    _ = @import("kvdb.zig");
    _ = @import("tsdb.zig");
}
