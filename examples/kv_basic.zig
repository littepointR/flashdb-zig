//! KVDB example: a NOR flash driver stub, mount, set/get/delete, iteration.
//!
//!   .tools\zig\zig.exe build example-kv
//!
//! On a real MCU the driver talks to your flash controller; here it is a RAM
//! array so the example runs on the host.

const std = @import("std");
const flashdb = @import("flashdb");

/// Minimal NOR flash driver: declare the error set, write granularity and erase
/// block size, then implement read/write/erase. The library never calls `write`
/// with an unaligned address or a length that is not a multiple of the write
/// granule, and never calls `erase` with anything but whole erase blocks.
const NorFlash = struct {
    pub const Error = error{OutOfBounds};
    pub const write_gran_bits: u16 = 8;
    pub const erase_block_size: u32 = 4096;

    mem: []u8,

    pub fn read(self: *NorFlash, addr: u32, buf: []u8) Error!void {
        if (@as(u64, addr) + buf.len > self.mem.len) return error.OutOfBounds;
        @memcpy(buf, self.mem[addr..][0..buf.len]);
    }

    pub fn write(self: *NorFlash, addr: u32, data: []const u8) Error!void {
        if (@as(u64, addr) + data.len > self.mem.len) return error.OutOfBounds;
        for (data, 0..) |b, i| self.mem[addr + i] &= b; // NOR: only clears bits
    }

    pub fn erase(self: *NorFlash, addr: u32, len: u32) Error!void {
        if (@as(u64, addr) + len > self.mem.len) return error.OutOfBounds;
        @memset(self.mem[addr..][0..len], 0xFF);
    }
};

var flash_mem: [16 * 1024]u8 = @splat(0xFF);

pub fn main(init: std.process.Init) !void {
    _ = init;
    const flash = NorFlash{ .mem = &flash_mem };

    const Kv = flashdb.Kvdb(NorFlash, .{
        .sector_size = 4096,
        .sector_count = 4,
        .max_name_len = 32,
    });
    var db: Kv = undefined;
    try db.mount(flash);

    try db.set("boot_count", &[_]u8{ 7, 0, 0, 0 });
    try db.set("wifi_ssid", "zig-flashdb");

    var buf: [64]u8 = undefined;
    if (try db.get("boot_count", &buf)) |len| {
        std.debug.print("boot_count = {any}\n", .{buf[0..len]});
    }
    if (try db.get("wifi_ssid", &buf)) |len| {
        std.debug.print("wifi_ssid = {s}\n", .{buf[0..len]});
    }

    // A missing key returns null.
    std.debug.print("missing key -> {?d}\n", .{try db.get("nope", &buf)});

    // Iterate every live key; readValue verifies the record CRC32.
    var it = db.iterator();
    while (try it.next()) |entry| {
        const copied = try it.readValue(&buf, entry);
        std.debug.print("  {s} ({d} bytes) = {any}\n", .{ entry.name, copied, buf[0..copied] });
    }

    const deleted = try db.delete("boot_count");
    std.debug.print("delete returned {any}, boot_count -> {?d}\n", .{ deleted, try db.get("boot_count", &buf) });

    // Remount from the same bytes: data persists.
    var db2: Kv = undefined;
    try db2.mount(flash);
    try db2.check();
    std.debug.print("remount ok, live keys = {d}\n", .{try db2.count()});
}
